#!/usr/bin/env python3
"""Exercise Android group/attachment coordinators against the disposable real Go API.

Uses synthetic fixture identities. The Activity flow uses the repository's public demo authority.
The selected device must already have the current Debug app and test APK installed.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
from contextlib import ExitStack, contextmanager
import json
import os
from pathlib import Path, PurePosixPath
import re
import secrets
import shutil
import socket
import subprocess
import tempfile
import time
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parents[1]


def loopback_port(kind):
    with socket.socket(socket.AF_INET, kind) as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def stop_process(process):
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)


@contextmanager
def local_livekit(executable, work):
    if not executable:
        yield {}
        return
    port = loopback_port(socket.SOCK_STREAM)
    secret = secrets.token_hex(32)
    config = work / "livekit.yaml"
    config.touch(mode=0o600)
    # Android's virtual router maps 10.0.2.2 to the host loopback for UDP.
    # Signaling uses adb reverse; ICE must be reachable independently of ADB.
    config.write_text(json.dumps({
        "port": port, "bind_addresses": ["127.0.0.1"], "keys": {"fixture": secret},
        "rtc": {"node_ip": "10.0.2.2", "udp_port": loopback_port(socket.SOCK_DGRAM), "tcp_port": 0,
                "ips": {"includes": ["127.0.0.1/32"]}, "enable_loopback_candidate": True,
                "use_external_ip": False, "allow_tcp_fallback": False, "allow_udp_unstable_fallback": False},
        "turn": {"enabled": False},
    }), encoding="utf-8")
    log = work / "livekit.log"
    with log.open("wb") as output, subprocess.Popen([str(executable), "--config", str(config)],
            cwd=work, stdout=output, stderr=subprocess.STDOUT) as media:
        try:
            opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
            for _ in range(100):
                if media.poll() is not None:
                    raise RuntimeError("LiveKit exited during startup: " + log.read_text(errors="replace")[-2000:])
                try:
                    with opener.open(f"http://127.0.0.1:{port}/", timeout=1) as response:
                        if response.status == 200:
                            break
                except OSError:
                    pass
                time.sleep(0.1)
            else:
                raise RuntimeError("Local LiveKit did not become ready")
            yield {"CHIRP_FIXTURE_LIVEKIT_PORT": str(port), "CHIRP_FIXTURE_LIVEKIT_SECRET": secret}
        finally:
            stop_process(media)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--serial", required=True, action="append", help="Device serial; in paired mode list sender first, receiver second")
    parser.add_argument("--livekit-server", type=Path, help="LiveKit server executable for the production Activity flow on Android Emulator")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--production-only", action="store_true", help="Run only the Activity flow against the local SFU")
    mode.add_argument("--paired", action="store_true", help="Run the two-emulator peer flow in the same room on a local SFU")
    mode.add_argument("--startup-repeats", type=int, metavar="N",
        help="Time one first verification and N trusted rejoins with two emulators (joining talker first)")
    args = parser.parse_args()
    if args.startup_repeats is not None and not 0 <= args.startup_repeats <= 20:
        parser.error("--startup-repeats must be between 0 and 20")
    paired = args.paired or args.startup_repeats is not None
    if args.production_only and not args.livekit_server:
        parser.error("--production-only requires --livekit-server")
    if paired and (not args.livekit_server or len(args.serial) != 2 or len(set(args.serial)) != 2):
        parser.error("Paired tests require --livekit-server and two distinct --serial devices (sender, receiver)")
    livekit = args.livekit_server.resolve(strict=True) if args.livekit_server else None
    sdk = Path(os.environ.get("ANDROID_HOME", str(Path.home() / "Library/Android/sdk")))
    adb = shutil.which("adb") or str(sdk / "platform-tools/adb")
    go = ["go"] if os.name == "nt" else ["sh", "scripts/go.sh"]
    with tempfile.TemporaryDirectory(prefix="chirp-android-protocol-") as temporary:
        work = Path(temporary)
        binary = work / ("fixture.exe" if os.name == "nt" else "fixture")
        subprocess.run(go + ["build", "-o", str(binary), "./scripts/attachment-fixture"], cwd=ROOT, check=True)
        runs = [args.serial] if paired else [[serial] for serial in args.serial]
        for index, serials in enumerate(runs):
            print("Running Android fixture on " + ", ".join(serials), flush=True)
            directory = work / str(index)
            directory.mkdir()
            with local_livekit(livekit, directory) as media_env:
                devices = [[adb, "-s", serial] for serial in serials]
                run_fixture(devices, binary, directory, media_env, args.production_only, paired, args.startup_repeats)


def run_fixture(devices, binary, work, media_env, production_only, paired, startup_repeats):
    # On Windows terminating the fixture skips its Go defers. Keep all its data inside this run.
    env = dict(os.environ, TMPDIR=str(work), TEMP=str(work), TMP=str(work))
    env.pop("CHIRP_FIXTURE_LIVEKIT_PORT", None)
    env.pop("CHIRP_FIXTURE_LIVEKIT_SECRET", None)
    env.update(media_env)
    with subprocess.Popen([str(binary)], stdout=subprocess.PIPE, text=True, cwd=ROOT, env=env) as server, ExitStack() as cleanup:
        cleanup.callback(stop_process, server)
        fixture = json.loads(server.stdout.readline())
        if media_env and "production_flow" not in fixture:
            reason = fixture.get("production_flow_skipped")
            if not reason:
                raise RuntimeError("The fixture did not initialize the requested Activity flow")
            print(f"Skipping the default-key Activity flow. {reason}", flush=True)
            if startup_repeats is not None:
                raise RuntimeError("Startup timing requires the production Activity flow")
            if production_only or paired:
                return
        if paired and ("production_peer" not in fixture or "peer_comparison_key" not in fixture):
            raise RuntimeError("The fixture did not initialize the receiver and out-of-band SAS comparison")
        ports = [fixture["url"].rsplit(":", 1)[1]]
        if "production_flow" in fixture:
            ports.append(media_env["CHIRP_FIXTURE_LIVEKIT_PORT"])
        path = work / f"android-attachment-fixture-{secrets.token_hex(8)}.json"
        path.touch(mode=0o600)
        path.write_text(json.dumps(fixture), encoding="utf-8")
        remote = PurePosixPath("/sdcard/Android/data/cn.youzifeile.chirp.android/files") / path.name
        for device in devices:
            prepare_device(device, ports, path, remote, cleanup)
        if startup_repeats is not None:
            guest, resident = devices
            device_port = loopback_port(socket.SOCK_STREAM)
            endpoint = f"tcp:{device_port}"
            host_port = subprocess.check_output(resident + ["forward", "tcp:0", endpoint], text=True).strip()
            cleanup.callback(subprocess.run, resident + ["forward", "--remove", f"tcp:{host_port}"], check=False)
            subprocess.run(guest + ["reverse", "--no-rebind", endpoint, f"tcp:{host_port}"], check=True)
            cleanup.callback(subprocess.run, guest + ["reverse", "--remove", endpoint], check=False)
            run_peers(devices, remote, "RoomStartupLatencyTest",
                      ["-e", "timing_port", str(device_port), "-e", "startup_repeats", str(startup_repeats)])
        elif paired:
            run_peers(devices, remote)
        else:
            device, = devices
            if not production_only:
                instrument(device, remote, "cn.youzifeile.chirp.ui.IdentitySetupUiTest", expected=1)
                instrument(device, remote, "cn.youzifeile.chirp.media.GroupProtocolTest,cn.youzifeile.chirp.media.AttachmentProtocolTest", expected=4)
            if "production_flow" in fixture:
                instrument(device, remote, "cn.youzifeile.chirp.ui.ProductionFlowTest")


def prepare_device(device, ports, path, remote, cleanup):
    for port in ports:
        endpoint = f"tcp:{port}"
        subprocess.run(device + ["reverse", "--no-rebind", endpoint, endpoint], check=True, stdout=subprocess.DEVNULL)
        cleanup.callback(subprocess.run, device + ["reverse", "--remove", endpoint], check=False, stdout=subprocess.DEVNULL)
    subprocess.run(device + ["shell", "mkdir", "-p", str(remote.parent)], check=True)
    cleanup.callback(subprocess.run, device + ["shell", "rm", "-f", str(remote)], check=False, stdout=subprocess.DEVNULL)
    subprocess.run(device + ["push", str(path), str(remote)], check=True, stdout=subprocess.DEVNULL)


def run_peers(devices, remote, test="PeerFlowTest", extra=()):
    failures = []
    with ThreadPoolExecutor(max_workers=2) as pool:
        by_role = {pool.submit(instrument, device, remote, "cn.youzifeile.chirp.ui." + test, 1, role, extra): role
                   for device, role in zip(devices, ("sender", "receiver"))}
        for future in as_completed(by_role):
            try:
                future.result()
            except (OSError, subprocess.SubprocessError, RuntimeError) as error:
                failures.append(f"{by_role[future]}: {error}")
    if failures:
        raise RuntimeError("Paired Android fixture failed. " + " | ".join(failures))


def instrument(device, remote, classes, expected=None, role=None, extra=()):
    options = ["-w", "-r", "-e", "peer_role", role] if role else ["-w"]
    result = subprocess.run(device + ["shell", "am", "instrument"] + options + list(extra) + ["-e", "class", classes, "-e",
        "attachment_fixture", remote.name, "cn.youzifeile.chirp.android.test/androidx.test.runner.AndroidJUnitRunner"],
        text=True, encoding="utf-8", errors="replace", capture_output=True, timeout=420 if role else 300)
    print(f"{device[-1]}{f' ({role})' if role else ''}\n{result.stdout}", flush=True)
    successful = re.search(r"^OK \(([1-9][0-9]*) tests?\)", result.stdout, re.MULTILINE)
    if result.returncode or not successful or expected is not None and int(successful[1]) != expected:
        raise RuntimeError("Android fixture checks failed for " + classes)
    if role:
        statuses = re.findall(r"^INSTRUMENTATION_STATUS_CODE: (-?\d+)[ \t]*$", result.stdout, re.MULTILINE)
        finished = re.search(r"^INSTRUMENTATION_CODE: -1[ \t]*$", result.stdout, re.MULTILINE)
        if [status for status in statuses if status != "2"] != ["1", "0"] or not finished:
            raise RuntimeError("AndroidJUnitRunner did not report one executed and passed peer test")


if __name__ == "__main__":
    try:
        main()
    except RuntimeError as error:
        raise SystemExit(str(error))
