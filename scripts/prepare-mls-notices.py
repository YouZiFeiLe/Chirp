#!/usr/bin/env python3
"""Collect locked Rust dependency notices after prepare-mls downloads sources."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
MODULE = ROOT / "Client/apple/MLS"

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--windows", action="store_true")
    args = parser.parse_args()
    if args.windows:
        manifest = MODULE / "native/Cargo.toml"
        destination = ROOT / ".build/winui-native/mls-third-party.txt"
        target = "x86_64-pc-windows-msvc"
        env = os.environ
    else:
        manifest = MODULE / "native/Cargo.toml"
        destination = MODULE / "Sources/ChirpMLS/Resources/ThirdPartyNotices.txt"
        target = "aarch64-apple-darwin"
        env = dict(os.environ, CARGO_HOME=str(ROOT / ".build/cargo-home"))
    manifests = [manifest]
    if args.windows:
        manifests.append(ROOT / "Client/windows/audio/Cargo.toml")
    resolved_packages = {}
    for path in manifests:
        result = subprocess.run(["cargo", "metadata", "--locked", "--offline", "--format-version", "1",
            "--filter-platform", target, "--manifest-path", str(path)],
            env=env, check=True, encoding="utf-8", capture_output=True)
        metadata = json.loads(result.stdout)
        resolved = {item["id"] for item in metadata["resolve"]["nodes"]}
        resolved_packages.update({p["id"]: p for p in metadata["packages"] if p["source"] and p["id"] in resolved})
    packages = sorted(resolved_packages.values(), key=lambda p: (p["name"], p["version"]))
    heading = "Chirp for Windows" if args.windows else "ChirpMLS"
    output = [heading + " — third-party notices", "", "These upstream dependencies are unmodified. Exact sources are available from the versioned crates.io download links below; Cargo.lock records registry checksums.", ""]
    texts = {}
    for package in packages:
        source = Path(package["manifest_path"]).parent
        licenses = sorted(p for p in source.iterdir() if p.is_file() and p.name.upper().startswith(("LICENSE", "LICENCE", "NOTICE", "COPYING")))
        if not licenses:
            if package["name"].startswith("openmls"):
                licenses = [MODULE / "Licenses/OpenMLS-MIT.txt"]
            elif package["name"] == "sonora-aec3":
                parent = next(p for p in packages if p["name"] == "sonora" and p["version"] == package["version"])
                licenses = [Path(parent["manifest_path"]).with_name("LICENSE")]
            elif package["license"] in ("MPL-2.0", "Apache-2.0"):
                licenses = [MODULE / "Licenses" / (package["license"] + ".txt")]
            else:
                raise RuntimeError("Missing license text for " + package["name"])
        references = []
        for path in licenses:
            content = path.read_text(encoding="utf-8").strip()
            key = hashlib.sha256(content.encode()).hexdigest()[:16]
            texts[key] = content
            references.append(key)
        name, version = package["name"], package["version"]
        output += [f"{name} {version} — {package['license']}", f"Authors: {', '.join(package['authors'])}",
            f"Repository: {package['repository'] or package['homepage'] or 'see source'}",
            f"Source: https://crates.io/api/v1/crates/{name}/{version}/download", "License texts: " + ", ".join(references), ""]
    for key, content in sorted(texts.items()): output += ["=" * 72, "License text " + key, "", content, ""]
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text("\n".join(line.rstrip() for line in output), encoding="utf-8")
    print(f"Prepared notices for {len(packages)} locked Rust packages")

if __name__ == "__main__":
    main()
