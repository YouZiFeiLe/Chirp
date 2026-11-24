#!/usr/bin/env python3
"""Real encrypted Swift/MLS audio and data packets through a disposable local SFU.

No microphone, production accounts, deployment config, the deployment database or external ICE.
"""
import base64
import argparse
import hashlib
import hmac
import http.client
import ipaddress
import json
import os
from pathlib import Path
import secrets
import subprocess
import tempfile
import time
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parents[1]


def jwt(identity, secret):
    def encode(value):
        return base64.urlsafe_b64encode(json.dumps(value, separators=(",", ":")).encode()).rstrip(b"=")
    now = int(time.time())
    body = b".".join([encode({"alg": "HS256", "typ": "JWT"}), encode({
        "iss": "chat-test", "sub": identity, "name": identity, "nbf": now - 5, "exp": now + 300,
        "video": {"roomJoin": True, "room": "chat-test", "canPublish": True,
                  "canSubscribe": True, "canPublishData": True, "canPublishSources": ["microphone"]},
    })])
    signature = base64.urlsafe_b64encode(hmac.new(secret.encode(), body, hashlib.sha256).digest()).rstrip(b"=")
    return (body + b"." + signature).decode()


def main(ios_simulator=None):
    build = ROOT / ".build"
    build.mkdir(exist_ok=True)
    container = "chirp-chat-test-" + secrets.token_hex(5)
    with tempfile.TemporaryDirectory(prefix="chat-transport-", dir=build) as temp:
        work = Path(temp)
        secret = secrets.token_hex(32)
        subprocess.run(["docker", "network", "create", container], check=True, stdout=subprocess.DEVNULL)
        try:
            network = json.loads(subprocess.check_output(["docker", "network", "inspect", container], text=True))[0]
            subnet = next(item["Subnet"] for item in network["IPAM"]["Config"] if ":" not in item["Subnet"])
            server_ip = str(ipaddress.ip_network(subnet).network_address + 2)
            # Native WebRTC excludes loopback candidates. Use the disposable
            # bridge IP (routable from Linux hosts / OrbStack), with no public UDP mapping.
            (work / "livekit.yaml").write_text(json.dumps({
                "port": 7880, "bind_addresses": ["0.0.0.0"], "keys": {"chat-test": secret},
                "rtc": {"node_ip": server_ip, "udp_port": 7882, "tcp_port": 0,
                        "use_external_ip": False, "allow_tcp_fallback": False,
                        "allow_udp_unstable_fallback": False},
                "turn": {"enabled": False}, "logging": {"level": "info"},
            }))
            subprocess.run(["docker", "run", "-d", "--platform", "linux/amd64", "--name", container,
                "--network", container, "--ip", server_ip, "-p", "127.0.0.1::7880",
                "-v", f"{work}:/test:ro", "livekit/livekit-server:v1.13.11",
                "--config", "/test/livekit.yaml"], check=True, stdout=subprocess.DEVNULL)
            address = subprocess.check_output(["docker", "port", container, "7880/tcp"], text=True).strip()
            for attempt in range(60):
                try:
                    with urllib.request.urlopen("http://" + address, timeout=1):
                        break
                except (urllib.error.URLError, OSError, http.client.HTTPException):
                    if attempt == 59:
                        raise RuntimeError("Disposable LiveKit did not become healthy")
                    time.sleep(0.5)
            identities = ["a.login.entry1", "b.login.entry1", "c.login.entry1", "c.login.entry2", "a.login.entry2"]
            fixture = work / "clients.json"
            fixture_info = {"url": "ws://" + address, "tokens": {identity: jwt(identity, secret) for identity in identities}}
            fixture.touch(mode=0o600)
            fixture.write_text(json.dumps(fixture_info))
            env = dict(os.environ, CHIRP_CHAT_TEST_CONFIG=str(fixture))
            for test in ("subscribedVoiceWaitsForLeaseAcrossRekey", "chatLiveKitTransportIntegration"):
                if ios_simulator:
                    env["TEST_RUNNER_CHIRP_CHAT_TEST_CONFIG"] = str(fixture)
                    subprocess.run(["xcodebuild", "-scheme", "ChirpMediaChecks-Package", "-destination",
                        f"platform=iOS Simulator,id={ios_simulator}", "-derivedDataPath", str(build / "voice-sim"),
                        "-clonedSourcePackagesDirPath", str(build / "apple-packages"), "-parallel-testing-enabled", "NO",
                        f"-only-testing:ChirpMediaTests/{test}()", "test"], cwd=ROOT / "Client/apple/MediaChecks", env=env, check=True)
                else:
                    subprocess.run(["swift", "test", "--package-path", "Client/apple/MediaChecks",
                        "--scratch-path", ".build/media-checks", "--filter", test], cwd=ROOT, env=env, check=True)
        except Exception:
            subprocess.run(["docker", "logs", "--tail", "35", container], check=False)
            raise
        finally:
            subprocess.run(["docker", "rm", "-f", container], check=False, stdout=subprocess.DEVNULL)
            subprocess.run(["docker", "network", "rm", container], check=False, stdout=subprocess.DEVNULL)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ios-simulator", metavar="UDID", help="run the Apple audio and chat fixtures on an iOS Simulator")
    options = parser.parse_args()
    main(options.ios_simulator)
