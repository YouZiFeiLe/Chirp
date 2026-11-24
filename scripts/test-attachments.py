#!/usr/bin/env python3
"""Run the real Swift attachment transport against an isolated Go/SQLite API."""
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    binary = ROOT / ".build/attachment-fixture"
    subprocess.run(["sh", "scripts/go.sh", "build", "-o", str(binary), "./scripts/attachment-fixture"], cwd=ROOT, check=True)
    with tempfile.TemporaryDirectory(prefix="attachment-transport-", dir=ROOT / ".build") as work:
        server = subprocess.Popen([str(binary)], stdout=subprocess.PIPE, text=True, cwd=ROOT)
        try:
            fixture = json.loads(server.stdout.readline())
            path = Path(work) / "clients.json"
            path.write_text(json.dumps(fixture))
            path.chmod(0o600)
            env = dict(os.environ, CHIRP_ATTACHMENT_TEST_CONFIG=str(path))
            subprocess.run(["swift", "test", "--package-path", "Client/apple", "--scratch-path", ".build/swift-core",
                            "--filter", "AttachmentHTTPTests"], cwd=ROOT, env=env, check=True)
        finally:
            server.terminate()
            try:
                server.wait(timeout=10)
            except subprocess.TimeoutExpired:
                server.kill()
                server.wait()


if __name__ == "__main__":
    main()
