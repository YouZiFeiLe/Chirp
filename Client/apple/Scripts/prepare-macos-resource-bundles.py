#!/usr/bin/env python3
"""Keep codeless SwiftPM bundles in Resources covered by the app's resource seal.

Xcode may give SwiftPM resource bundles a development signature that exportArchive
does not replace. Apple treats codeless bundles embedded in Contents/Resources as
resources, not nested code. Run after copying them and before signing the app.
https://developer.apple.com/documentation/bundleresources/placing-content-in-a-bundle
"""

import plistlib
import shutil
import sys
from pathlib import Path


BUNDLES = (
    "ChirpAudio_ChirpAudio.bundle",
    "ChirpMLS_ChirpMLS.bundle",
    "LiveKit_LiveKit.bundle",
)
# Mach-O and universal binary headers, in both byte orders and word sizes.
MACHO_MAGICS = {
    bytes.fromhex(magic)
    for magic in (
        "feedface", "cefaedfe", "feedfacf", "cffaedfe",
        "cafebabe", "bebafeca", "cafebabf", "bfbafeca",
    )
}


def descendants(directory: Path):
    # Do not use rglob: it may suppress traversal errors and miss uninspected code.
    for path in sorted(directory.iterdir()):
        if path.is_symlink():
            raise ValueError(f"Resource bundle contains a symlink: {path}")
        yield path
        if path.is_dir():
            yield from descendants(path)


def prepare(resources: Path) -> None:
    signatures = []
    # Validate every bundle first. Never remove a code-bearing bundle's signature.
    for name in BUNDLES:
        bundle = resources / name
        if bundle.is_symlink() or not bundle.is_dir():
            raise ValueError(f"Expected a regular resource bundle: {bundle}")
        files = list(descendants(bundle))
        info = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())
        if info.get("CFBundlePackageType") != "BNDL" or "CFBundleExecutable" in info:
            raise ValueError(f"Resource bundle must be codeless: {bundle}")
        for path in files:
            if path.is_file():
                with path.open("rb") as stream:
                    if stream.read(4) in MACHO_MAGICS:
                        raise ValueError(f"Refusing to remove signature around Mach-O: {path}")
        signatures.append(bundle / "Contents/_CodeSignature")
    for signature in signatures:
        if signature.exists():
            shutil.rmtree(signature)
        print(f"Prepared codeless resource bundle: {signature.parent.parent.name}")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("Usage: prepare-macos-resource-bundles.py <app/Contents/Resources>")
    try:
        prepare(Path(sys.argv[1]))
    except (OSError, ValueError, plistlib.InvalidFileException) as error:
        sys.exit(f"error: {error}")
