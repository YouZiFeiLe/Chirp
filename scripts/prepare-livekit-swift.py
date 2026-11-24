#!/usr/bin/env python3
"""Fetch the locked release and apply transport and group rekey patches."""

import hashlib
import io
from pathlib import Path
import re
import shutil
import subprocess
import tarfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
VERSION = "2.19.0"
SHA256 = "9d8f17e6432f31bf103ba1389a55d5c0120c8d5d518ecf8b2922c398ef200c90"

# C++ interfaces of LiveKitWebRTC 150.7871.08 and its Chromium Abseil revision.
WEBRTC = ("webrtc-sdk/webrtc", "7c1a802ab4e0d74f28ee997678346b3e753ef42a", "0bc9115936e1e88e8065f80eadd0940d7c32ea7c1d84c1edbf2900e719665718")
ABSEIL = ("abseil/abseil-cpp", "8fb4507d10a24a1204e98f77ad19c27c291e13e9", "e06bcb6dd3520e17087d4c7d403543d74fb741cc682dfd7ab1a3962e6ea02dc0")


def prepare_voice(sdk, cache):
    voice = ROOT / "Client/apple/Voice"
    target = sdk / "Sources/ChirpVoiceReceiver"
    shutil.copytree(voice / "include", target / "include", dirs_exist_ok=True)
    shutil.copy2(voice / "ChirpVoiceReceiver.mm", target)
    shutil.copy2(voice / "ChirpVoiceKeys.swift", sdk / "Sources/LiveKit/E2EE")
    headers = target / "webrtc-headers"
    for name, (repo, revision, digest) in (("webrtc", WEBRTC), ("abseil", ABSEIL)):
        archive = cache / f"{name}-{revision[:8]}.tar.gz"
        if not archive.exists():
            url = f"https://codeload.github.com/{repo}/tar.gz/{revision}"
            with urllib.request.urlopen(url, timeout=60) as response:
                archive.write_bytes(response.read())
        if hashlib.sha256(archive.read_bytes()).hexdigest() != digest:
            raise SystemExit(f"{name} header archive checksum mismatch")
        with tarfile.open(archive) as source:
            for member in source:
                _, _, path = member.name.partition("/")
                if not member.isfile() or not path:
                    continue
                if path in ("LICENSE", "PATENTS", "AUTHORS"):
                    path = f"{name}-{path}"
                elif not path.endswith((".h", ".inc")) or (name == "abseil" and not path.startswith("absl/")):
                    continue
                dest = headers / path
                if not dest.resolve().is_relative_to(headers.resolve()):
                    raise SystemExit("Header path escaped the SDK directory")
                dest.parent.mkdir(parents=True, exist_ok=True)
                dest.write_bytes(source.extractfile(member).read())


def main():
    cache = ROOT / ".build/downloads"
    cache.mkdir(parents=True, exist_ok=True)
    archive = cache / f"livekit-swift-{VERSION}.tar.gz"
    if not archive.exists():
        url = f"https://codeload.github.com/livekit/client-sdk-swift/tar.gz/refs/tags/{VERSION}"
        with urllib.request.urlopen(url, timeout=60) as response:
            archive.write_bytes(response.read())
    data = archive.read_bytes()
    if hashlib.sha256(data).hexdigest() != SHA256:
        raise SystemExit("Swift SDK release archive checksum mismatch")
    vendor = ROOT / "Client/apple/Vendor"
    vendor.mkdir(parents=True, exist_ok=True)
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as source:
        source.extractall(vendor, filter="data")
    sdk = vendor / f"client-sdk-swift-{VERSION}"
    for name in ("livekit-no-external-ice", "livekit-group-key-provider", "livekit-ephemeral-chat", "livekit-audio-devices", "livekit-smooth-rotation", "livekit-native-dependencies", "livekit-local-microphone-intent", "livekit-v5-expiry", "livekit-voice-receiver"):
        patch = ROOT / f"Client/apple/Patches/{name}.patch"
        # Extracting the upstream archive overwrites original files but leaves
        # files introduced by our previous patches. Remove only those generated
        # files before reapplying; otherwise patch can reverse and delete them.
        for relative in re.findall(r"^--- /dev/null\n\+\+\+ b/([^\n]+)$", patch.read_text(), re.MULTILINE):
            generated = (sdk / relative).resolve()
            if not generated.is_relative_to(sdk.resolve()):
                raise SystemExit("Patch path escaped the SDK directory")
            generated.unlink(missing_ok=True)
        subprocess.run(["patch", "--batch", "--forward", "-p1", "--fuzz=0", "--input", str(patch)], cwd=sdk, check=True)
    prepare_voice(sdk, cache)
    print(f"Prepared LiveKit Swift {VERSION} with authenticated voice replay protection")


if __name__ == "__main__":
    main()
