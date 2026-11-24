#!/usr/bin/env python3
"""Exercise release scripts with disposable files and fake Docker/SSH/curl."""

import io
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="chirp-ci-test-")
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)
        (self.work / "scripts").mkdir()
        (self.work / "deploy").mkdir()
        (self.work / ".build").mkdir()
        self.digests = "CHIRP_IMAGE=registry.test.local:8082/chirp-server@sha256:" + "a" * 64 + "\nCHIRP_LIVEKIT_IMAGE=livekit/livekit-server@sha256:" + "c" * 64 + "\n"
        (self.work / ".build/release-images.env").write_text(self.digests)
        self.public_trust = dict(public_key="A" * 43 + "=")
        self.pin = self.work / "Client/apple/Shared/Resources/AuthorizationTrust.json"
        self.pin.parent.mkdir(parents=True)
        self.pin.write_text(json.dumps(self.public_trust))
        for name in ("ci-image.sh", "ci-build.sh", "ci-deploy.sh"):
            shutil.copyfile(ROOT / "scripts" / name, self.work / "scripts" / name)
        self.seed = b"A" * 43 + b"="
        self.default_key = self.work / "deploy/authorization-key.default"
        self.default_key.write_bytes(self.seed)
        for name in ("Dockerfile", "compose.yaml", "apply-release.sh"):
            shutil.copyfile(ROOT / "deploy" / name, self.work / "deploy" / name)
        env_text = (ROOT / "deploy/.env.example").read_text().replace("REPLACE_WITH_YOUR_RANDOM_SECRET", "x" * 64).replace("rtc.example.com", "rtc.test.local").replace("REPLACE_WITH_GROUP_CONTROL_SECRET", "g" * 64)
        (self.work / "deploy/.env").write_text(env_text)
        config = (ROOT / "deploy/livekit.yaml.example").read_text().replace("REPLACE_WITH_YOUR_PUBLIC_IP", "192.0.2.20").replace("REPLACE_WITH_THE_SAME_LIVEKIT_API_SECRET", "x" * 64)
        (self.work / "deploy/livekit.yaml").write_text(config)
        self.bin = self.work / "fake-bin"
        self.bin.mkdir()
        fake = self.bin / "fake"
        fake.write_text("#!" + sys.executable + "\n" + '''import json, os, sys
from pathlib import Path
name = Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ['CHIRP_TEST_LOG'], 'a') as stream:
    # Record names only, never inherited secret values.
    overrides = [key for key in json.loads(os.environ.get('CHIRP_TEST_COMPOSE_VARIABLES', '[]')) if key in os.environ]
    stream.write(json.dumps({'command': name, 'args': args, 'compose_overrides': overrides}) + '\\n')
if name == 'mktemp':
    import tempfile
    print(tempfile.mkdtemp(prefix='release-', dir=os.environ['CHIRP_TEST_ROOT']))
elif name == 'ssh':
    data = sys.stdin.buffer.read()
    if 'tar -xf' in args[-1]: Path(os.environ['CHIRP_TEST_BUNDLE']).write_bytes(data)
    else:
        if data != os.environ.get('CHIRP_TEST_EXPECTED_PASSWORD', 'disposable-test-password').encode(): sys.exit(2)
        sys.exit(int(os.environ.get('CHIRP_TEST_REMOTE_STATUS', '0')))
elif name == 'docker' and args[:1] == ['login']:
    sys.stdin.read()
elif name == 'docker' and os.environ.get('CHIRP_TEST_DOCKER_FAILURE') in args:
    sys.exit(1)
elif name == 'docker' and args[:2] == ['image', 'inspect']:
    print(args[-1].rsplit(':',1)[0]+'@sha256:'+'a'*64)
elif name == 'docker' and '-verify-trust' in args:
    mount = next(a for a in args if a.startswith('type=bind,src=') and 'dst=/release' in a)
    directory = Path(mount.split('src=',1)[1].split(',dst=',1)[0])
    config = directory / Path(args[args.index('-verify-trust')+1]).name
    key = directory / Path(args[args.index('-key-file')+1]).name
    if json.loads(config.read_text()) != json.loads(os.environ['CHIRP_TEST_PUBLIC_TRUST']): sys.exit(1)
    if key.read_bytes() != os.environ['CHIRP_TEST_EXPECTED_KEY'].encode(): sys.exit(1)
elif name == 'chown':
    pass
elif name == 'flock':
    pass
elif name == 'uname':
    print('Linux' if args == ['-s'] else 'x86_64')
elif name == 'curl' and os.environ.get('CHIRP_TEST_FAIL_HEALTH'):
    sys.exit(22)
elif name in ('mkdir', 'install'):
    for path in (args[-1:] if name == 'install' else args):
        if path.startswith('-'): continue
        target = Path(path).resolve()
        if not target.is_relative_to(Path(os.environ['CHIRP_TEST_ROOT']).resolve()): sys.exit(1)
        if name == 'mkdir' or '-d' in args:
            target.mkdir(parents=True, exist_ok=True)
        else:
            import shutil
            target.unlink(missing_ok=True)
            shutil.copyfile(args[-2], target)
            target.chmod(int(args[args.index('-m')+1], 8))
''')
        fake.chmod(0o700)
        for name in ("docker", "ssh", "uname", "curl", "mkdir", "mktemp", "install", "chown", "flock"):
            (self.bin / name).symlink_to(fake)
        self.log = self.work / "commands.jsonl"
        self.bundle = self.work / "bundle.tar"
        self.env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ["PATH"], TMPDIR=str(self.work),
                        QD_NEXUS_ADDRESS="registry.test.local:8082", DOCKER_IMAGE_NAME="chirp-server",
                        DOCKER_NEXUS_PASSWD="disposable-test-password", CI_COMMIT_TAG="v0.2.0-test", CI_JOB_ID="123",
                        CHIRP_DEPLOY_HOST="192.0.2.30", CHIRP_DEPLOY_USER="root", CHIRP_DEPLOY_PORT="22",
                        CHIRP_HEALTHCHECK_URL="http://127.0.0.1:18115/healthz",
                        CHIRP_TEST_LOG=str(self.log), CHIRP_TEST_BUNDLE=str(self.bundle), CHIRP_TEST_ROOT=str(self.work),
                        CHIRP_TEST_PUBLIC_TRUST=json.dumps(self.public_trust), CHIRP_TEST_EXPECTED_KEY=self.seed.decode())
        self.env.pop("CHIRP_AUTHORIZATION_KEY_SOURCE", None)

    def run_script(self, name, *args, extra=None):
        env = dict(self.env, **(extra or {}))
        return subprocess.run(["sh", str(self.work / name), *map(str, args)], cwd=self.work, env=env, text=True, input="disposable-test-password", capture_output=True)

    def commands(self, command):
        if not self.log.exists():
            return []
        return [entry["args"] for entry in map(json.loads, self.log.read_text().splitlines()) if entry["command"] == command]

    def test_builds_one_app_image_and_records_two_immutable_digests(self):
        result = self.run_script("scripts/ci-build.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.commands("docker")
        builds = [args for args in calls if args[0] == "build"]
        self.assertEqual(len(builds), 2)
        self.assertEqual([a[a.index("--target") + 1] for a in builds], ["test", "app"])
        self.assertIn("registry.test.local:8082/chirp-server:v0.2.0-test", builds[1])
        self.assertEqual(len([a for a in calls if a[0] == "push"]), 1)
        self.assertEqual(len([a for a in calls if a[0] == "run" and a[-1] == "version"]), 1)
        self.assertNotIn("disposable-test-password", result.stdout + result.stderr)

    def test_image_references_reject_invalid_input(self):
        self.assertEqual(self.run_script("scripts/ci-image.sh").returncode, 0)
        for values in ({"CI_COMMIT_TAG": "invalid/tag"}, {"QD_NEXUS_ADDRESS": "https://registry.test"}, {"DOCKER_IMAGE_NAME": "Bad Image"}):
            self.assertNotEqual(self.run_script("scripts/ci-image.sh", extra=values).returncode, 0)
        self.assertNotEqual(self.run_script("scripts/ci-image.sh", "admin").returncode, 0)

    def test_release_bundle_has_two_pinned_images(self):
        result = self.run_script("scripts/ci-deploy.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        with tarfile.open(fileobj=io.BytesIO(self.bundle.read_bytes())) as archive:
            self.assertEqual(set(archive.getnames()), {"compose.yaml", "apply-release.sh", "image.env", ".env", "livekit.yaml", "expected-trust.json", "authorization-key", "bootstrap-request-id"})
            self.assertEqual(archive.extractfile("image.env").read().decode(), self.digests)
            self.assertNotIn(b"LIVEKIT_API_SECRET=", archive.extractfile(".env").read())
        calls = self.commands("ssh")
        self.assertEqual(len(calls), 2)
        self.assertIn("http://127.0.0.1:18115/healthz", calls[1][-1])
        self.assertNotIn("disposable-test-password", self.log.read_text())
        self.assertEqual([p.name for p in (self.work / ".build/deployment").iterdir()], ["status.txt"])

    def test_deployment_requires_unique_immutable_digest_artifact(self):
        artifact = self.work / ".build/release-images.env"
        for content in (None, self.digests.replace("@sha256:" + "a" * 64, ":latest"), self.digests.replace("CHIRP_LIVEKIT_IMAGE=", "CHIRP_IMAGE=")):
            artifact.unlink(missing_ok=True)
            if content is not None: artifact.write_text(content)
            result = self.run_script("scripts/ci-deploy.sh")
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(self.commands("ssh"), [])

    def apply(self, extra=None):
        deploy = self.work / "data" / "chirp"
        incoming = deploy / ".ci-123"
        incoming.mkdir(parents=True, exist_ok=True)
        for name in ("compose.yaml", "apply-release.sh", ".env", "livekit.yaml"):
            shutil.copyfile(self.work / "deploy" / name, incoming / name)
        shutil.copyfile(self.pin, incoming / "expected-trust.json")
        if self.default_key.exists():
            shutil.copyfile(self.default_key, incoming / "authorization-key")
        (incoming / "image.env").write_text(self.digests)
        if extra and extra.get("CHIRP_BOOTSTRAP_REQUEST_ID"):
            (incoming / "bootstrap-request-id").write_text(extra["CHIRP_BOOTSTRAP_REQUEST_ID"])
        result = self.run_script("deploy/apply-release.sh", deploy, incoming, "http://127.0.0.1:18115/healthz", "registry.test.local:8082", "docker", extra=extra)
        return result, deploy

    def test_apply_pulls_two_services_and_checks_unified_authorization(self):
        result, deploy = self.apply()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(any(a[-3:] == ["pull", "app", "livekit"] for a in self.commands("docker")))
        self.assertEqual([a[-1] for a in self.commands("curl")], ["http://127.0.0.1:18115/healthz", "http://127.0.0.1:18115/authorization/healthz"])
        up = [a for a in self.commands("docker") if "up" in a]
        self.assertEqual(len(up), 1)
        self.assertIn("--remove-orphans", up[0])
        self.assertNotIn("--force-recreate", up[0])
        self.assertEqual((deploy / ".env").stat().st_mode & 0o777, 0o600)

    def test_deployment_hostname_does_not_require_changing_client_public_key(self):
        pin = self.pin.read_bytes()
        config = self.work / "deploy/.env"
        config.write_text(config.read_text().replace("https://chirp.youzifeile.cn", "https://new-deployment.test/"))
        result, deploy = self.apply()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.pin.read_bytes(), pin)
        self.assertIn("CHIRP_PUBLIC_ORIGIN=https://new-deployment.test/", (deploy / ".env").read_text())

    def test_shell_environment_cannot_override_pinned_images_or_runtime_settings(self):
        variables = sorted(set(re.findall(r"\$\{([A-Z_]+)", (self.work / "deploy/compose.yaml").read_text())))
        self.assertIn("CHIRP_IMAGE", variables)
        self.assertIn("LIVEKIT_API_SECRET", variables)
        overrides = {name: "untrusted-shell-override" for name in variables}
        overrides["CHIRP_IMAGE"] = "untrusted/image:latest"
        overrides["CHIRP_TEST_COMPOSE_VARIABLES"] = json.dumps(variables)
        result, deploy = self.apply(extra=overrides)
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = [entry for entry in map(json.loads, self.log.read_text().splitlines())
                 if entry["command"] == "docker" and entry["args"][:1] == ["compose"]]
        self.assertTrue(any("up" in entry["args"] for entry in calls))
        self.assertTrue(all(entry["compose_overrides"] == [] for entry in calls))
        self.assertEqual((deploy / ".image.env").read_text(), self.digests)
        self.assertNotIn("untrusted-shell-override", (deploy / ".livekit.env").read_text())

    def test_repeated_release_preserves_database_and_media_process(self):
        _, deploy = self.apply()
        database_files = {"chirp.db": b"database", "chirp.db-wal": b"uncheckpointed", "chirp.db-shm": b"shared-memory"}
        for name, data in database_files.items():
            (deploy / "data" / name).write_bytes(data)
        authorization_files = {"authorization.db": b"authorization", "authorization.db-wal": b"pending-authorization", "authorization.db-shm": b"authorization-locks"}
        for name, data in authorization_files.items():
            (deploy / "authorization-data" / name).write_bytes(data)
        (deploy / "operator-notes.txt").write_text("keep")
        self.log.unlink()
        result, _ = self.apply()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any("--force-recreate" in a for a in self.commands("docker")))
        self.assertEqual({n: (deploy / "data" / n).read_bytes() for n in database_files}, database_files)
        self.assertEqual((deploy / "operator-notes.txt").read_text(), "keep")
        self.assertEqual({n: (deploy / "authorization-data" / n).read_bytes() for n in authorization_files}, authorization_files)
        self.assertFalse((deploy / ".ci-123").exists())

    def test_only_media_configuration_changes_force_media_recreation(self):
        _, deploy = self.apply()
        for name, suffix in ((".env", "\nCHIRP_LOG_LEVEL=debug\n"), ("livekit.yaml", "\n# changed media configuration\n")):
            self.log.unlink()
            with (self.work / "deploy" / name).open("a") as stream:
                stream.write(suffix)
            result, _ = self.apply()
            self.assertEqual(result.returncode, 0, result.stderr)
            forced = [a for a in self.commands("docker") if "--force-recreate" in a]
            self.assertEqual(len(forced), int(name == "livekit.yaml"))
            if forced:
                self.assertEqual(forced[0][-1], "livekit")
        self.log.unlink()
        p = self.work / "deploy/.env"
        p.write_text(p.read_text().replace("LIVEKIT_API_KEY=chirp", "LIVEKIT_API_KEY=changed"))
        result, _ = self.apply()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(any("--force-recreate" in a and a[-1] == "livekit" for a in self.commands("docker")))

    def test_candidate_failure_preserves_current_configuration(self):
        deploy = self.work / "data/chirp"
        deploy.mkdir(parents=True)
        before = {".env": b"current-env", "livekit.yaml": b"current-config", "compose.yaml": b"current-compose", ".image.env": b"current-images"}
        for name, data in before.items():
            (deploy / name).write_bytes(data)
        for command in ("config", "pull"):
            with self.subTest(command=command):
                result, _ = self.apply(extra={"CHIRP_TEST_DOCKER_FAILURE": command})
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual({n: (deploy / n).read_bytes() for n in before}, before)
                self.assertFalse((deploy / ".ci-123").exists())
                self.assertEqual(self.commands("install"), [])

    def test_health_failure_fails_release(self):
        result, _ = self.apply(extra={"CHIRP_TEST_FAIL_HEALTH": "1"})
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("健康检查通过", result.stdout)

    def test_placeholder_configuration_never_reaches_docker(self):
        (self.work / "deploy/.env").write_text("LIVEKIT_API_SECRET=REPLACE_WITH_SECRET\n")
        result, _ = self.apply()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any("pull" in a or "up" in a for a in self.commands("docker")))

    def test_bootstrap_admin_requires_explicit_exact_request(self):
        result, _ = self.apply(extra={"CHIRP_BOOTSTRAP_REQUEST_ID": "request-123"})
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = [a for a in self.commands("docker") if "bootstrap" in a]
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0][-2:], ["--request-id", "request-123"])
        self.assertNotEqual(self.run_script("scripts/ci-deploy.sh", extra={"CHIRP_BOOTSTRAP_REQUEST_ID": "x;touch bad"}).returncode, 0)

    def test_fresh_install_uses_preset_key_and_starts_without_manual_gate(self):
        result, deploy = self.apply()
        self.assertEqual(result.returncode, 0, result.stderr)
        key = deploy / "secrets/authorization-key"
        self.assertEqual(key.read_bytes(), self.seed)
        self.assertEqual(key.stat().st_mode & 0o777, 0o400)
        self.assertTrue(any("up" in a for a in self.commands("docker")))
        self.assertFalse(any("-generate-key" in a or "-export-trust" in a for a in self.commands("docker")))
        self.assertFalse((deploy / ".ci-123").exists())
        self.assertNotIn(self.seed.decode(), result.stdout + result.stderr + self.log.read_text())

    def test_deploy_requires_a_regular_key_source_before_uploading(self):
        self.default_key.unlink()
        result = self.run_script("scripts/ci-deploy.sh")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.commands("ssh"), [])
        self.default_key.symlink_to(self.pin)
        result = self.run_script("scripts/ci-deploy.sh")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.commands("ssh"), [])

    def test_file_variable_overrides_default_key_without_artifacts_or_logging(self):
        custom = self.work / "custom-key"
        value = b"B" * 43 + b"="
        custom.write_bytes(value)
        result = self.run_script("scripts/ci-deploy.sh", extra={"CHIRP_AUTHORIZATION_KEY_SOURCE": str(custom)})
        self.assertEqual(result.returncode, 0, result.stderr)
        with tarfile.open(fileobj=io.BytesIO(self.bundle.read_bytes())) as archive:
            self.assertEqual(archive.extractfile("authorization-key").read(), value)
            self.assertEqual(archive.getmember("authorization-key").mode, 0o600)
        self.assertEqual(self.default_key.read_bytes(), self.seed)
        self.assertEqual([p.name for p in (self.work / ".build/deployment").iterdir()], ["status.txt"])
        self.assertNotIn(value.decode(), result.stdout + result.stderr + self.log.read_text())

    def test_wrong_public_key_or_seed_fails_before_installing_configuration(self):
        _, deploy = self.apply()
        original_config = (deploy / ".image.env").read_bytes()
        for path, replacement in ((self.pin, b"[]"), (self.default_key, b"B" * 43 + b"=")):
            with self.subTest(path=path.name):
                original = path.read_bytes()
                path.write_bytes(replacement)
                self.log.unlink()
                result, _ = self.apply()
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertFalse(any("up" in a for a in self.commands("docker")))
                self.assertEqual((deploy / "secrets/authorization-key").read_bytes(), self.seed)
                self.assertEqual((deploy / ".image.env").read_bytes(), original_config)
                self.assertFalse((deploy / ".ci-123").exists())
                path.write_bytes(original)

    def test_missing_runtime_key_is_restored_from_configured_source(self):
        _, deploy = self.apply()
        (deploy / "secrets/authorization-key").unlink()
        result, _ = self.apply()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((deploy / "secrets/authorization-key").read_bytes(), self.seed)

    def test_valid_key_replacement_recreates_app_even_with_the_same_image(self):
        _, deploy = self.apply()
        previous_images = (deploy / ".image.env").read_bytes()
        replacement = b"B" * 43 + b"="
        self.default_key.write_bytes(replacement)
        self.public_trust["public_key"] = "C" * 43 + "="
        self.pin.write_text(json.dumps(self.public_trust))
        self.env["CHIRP_TEST_PUBLIC_TRUST"] = json.dumps(self.public_trust)
        self.env["CHIRP_TEST_EXPECTED_KEY"] = replacement.decode()
        self.log.unlink()
        result, _ = self.apply()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((deploy / "secrets/authorization-key").read_bytes(), replacement)
        self.assertEqual((deploy / ".image.env").read_bytes(), previous_images)
        forced = [a for a in self.commands("docker") if "--force-recreate" in a]
        self.assertEqual(len(forced), 1)
        self.assertEqual(forced[0][-1], "app")

    def test_remote_failure_reports_status_without_a_trust_download(self):
        result = self.run_script("scripts/ci-deploy.sh", extra={"CHIRP_TEST_REMOTE_STATUS": "1"})
        self.assertEqual(result.returncode, 1)
        self.assertEqual(len(self.commands("ssh")), 2)
        output = self.work / ".build/deployment"
        self.assertEqual([p.name for p in output.iterdir()], ["status.txt"])
        self.assertIn("exit_status=1", (output / "status.txt").read_text())

    def test_remote_rejects_mutable_digest_before_registry_login(self):
        self.digests = self.digests.replace("@sha256:" + "a" * 64, ":latest")
        result, _ = self.apply()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(a[0] == "login" or "up" in a for a in self.commands("docker")))

    def test_new_media_credential_is_generated_and_never_adopts_old_env_secret(self):
        deploy = self.work / "data/chirp"
        deploy.mkdir(parents=True)
        (deploy / ".env").write_text("LIVEKIT_API_SECRET=" + "old-secret" * 8 + "\n")
        result, _ = self.apply()
        self.assertEqual(result.returncode, 0, result.stderr)
        stored = (deploy / ".livekit.env").read_text()
        self.assertRegex(stored, r"^LIVEKIT_API_SECRET=[0-9a-f]{64}\n$")
        self.assertNotIn(stored.strip().split("=", 1)[1], result.stdout + result.stderr + self.log.read_text())
        self.assertEqual((deploy / ".livekit.env").stat().st_mode & 0o777, 0o600)

    def test_separate_pull_credential_is_only_sent_over_ssh_stdin(self):
        result = self.run_script("scripts/ci-deploy.sh", extra={
            "DOCKER_NEXUS_PULL_USERNAME": "readonly", "DOCKER_NEXUS_PULL_PASSWD": "test-pull-only-password",
            "CHIRP_TEST_EXPECTED_PASSWORD": "test-pull-only-password"})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("'readonly'", self.commands("ssh")[1][-1])
        self.assertNotIn("test-pull-only-password", result.stdout + result.stderr + self.log.read_text())


if __name__ == "__main__":
    unittest.main(verbosity=2)
