#!/usr/bin/env python3
"""Run Swift password admission, public state, and SSE against disposable Go/SQLite."""
import json
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def main():
    binary = ROOT / ".build/admission-fixture"
    binary.parent.mkdir(exist_ok=True)
    subprocess.run(["sh", "scripts/go.sh", "build", "-o", str(binary),
                    "./scripts/admission-fixture"], cwd=ROOT, check=True)
    with subprocess.Popen([str(binary)], stdout=subprocess.PIPE, text=True, cwd=ROOT) as server:
        try:
            config = json.loads(server.stdout.readline())
            env = dict(os.environ, CHIRP_PASSWORD_TEST_URL=config["url"],
                       CHIRP_PASSWORD_TEST_ROOM=config["room"],
                       CHIRP_PASSWORD_TEST_PASSWORD=config["password"],
                       CHIRP_PASSWORD_TEST_LOGIN=json.dumps(config["login"]))
            subprocess.run(["swift", "test", "--package-path", "Client/apple", "--scratch-path",
                            ".build/swift-core", "--filter", "roomPasswordAdmissionIntegration"],
                           cwd=ROOT, env=env, check=True, timeout=120)
        finally:
            server.terminate()
            try:
                server.wait(timeout=5)
            except subprocess.TimeoutExpired:
                server.kill()
                server.wait()


if __name__ == "__main__":
    main()
