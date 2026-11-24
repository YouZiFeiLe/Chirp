#!/usr/bin/env python3
"""Run identity/recovery tests in an isolated app on an explicitly chosen iPhone/iPad.

Requires prepared Apple dependencies, a paired device in Developer Mode and an
available Apple Development signing identity. Never replaces the normal app.
"""
import argparse
from datetime import datetime
from pathlib import Path
import plistlib
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
BUNDLE_ID = "cn.youzifeile.chirp.identitycheck"


def prepare_project() -> Path:
    source = ROOT / "Client/apple"
    target = ROOT / ".build/identity-device-project"
    target.mkdir(parents=True, exist_ok=True)
    for name in ("Shared", "Tests", "Audio", "MLS", "Vendor", "Scripts", "macOS"):
        link = target / name
        if not link.exists():
            link.symlink_to(source / name, target_is_directory=True)
    shutil.copytree(source / "iOS", target / "iOS", dirs_exist_ok=True)
    info = target / "iOS/Info.plist"
    values = plistlib.loads(info.read_bytes())
    values["CFBundleDisplayName"] = "Chirp Identity Check"
    info.write_bytes(plistlib.dumps(values))
    project = target / "Chirp.xcodeproj"
    shutil.copytree(source / "Chirp.xcodeproj", project, dirs_exist_ok=True)
    pbx = project / "project.pbxproj"
    pbx.write_text(pbx.read_text().replace("cn.youzifeile.chirp", BUNDLE_ID))
    return project


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", required=True, help="Explicit paired device UDID or CoreDevice identifier")
    parser.add_argument("--team", required=True, help="Apple Development team ID")
    parser.add_argument("--keep-installed", action="store_true", help="Keep only the isolated test app for investigation")
    args = parser.parse_args()
    project = prepare_project()
    result = ROOT / (".build/identity-device-tests-" + datetime.now().strftime("%Y%m%d-%H%M%S") + ".xcresult")
    log = ROOT / ".build/identity-device-tests.log"
    command = [
        "xcodebuild", "-project", str(project), "-scheme", "Chirp-iOS", "-configuration", "Debug",
        "-destination", "platform=iOS,id=" + args.device,
        "-derivedDataPath", str(ROOT / ".build/DerivedData-identity-device"),
        "-clonedSourcePackagesDirPath", str(ROOT / ".build/apple-packages"),
        "-disableAutomaticPackageResolution", "-onlyUsePackageVersionsFromResolvedFile",
        "-allowProvisioningUpdates", "DEVELOPMENT_TEAM=" + args.team,
        "CODE_SIGN_STYLE=Automatic", "CODE_SIGN_IDENTITY=Apple Development",
        "-only-testing:Chirp-iOS-Tests/IdentityAndFriendsTests",
        "-resultBundlePath", str(result), "test",
    ]
    print("Running isolated identity tests; log:", log, flush=True)
    try:
        with log.open("w") as output:
            status = subprocess.run(command, cwd=ROOT, stdout=output, stderr=subprocess.STDOUT).returncode
    finally:
        if not args.keep_installed:
            cleanup = subprocess.run(
                ["xcrun", "devicectl", "device", "uninstall", "app", "--device", args.device, BUNDLE_ID],
                cwd=ROOT, capture_output=True, text=True,
            )
            if cleanup.returncode:
                print("Isolated app cleanup did not complete; inspect its installation with devicectl.")
    print("Result bundle:", result)
    for line in log.read_text(errors="replace").splitlines():
        if "CHIRPKEY v1 hardware:" in line or "** TEST " in line:
            print(line)
    return status


if __name__ == "__main__":
    raise SystemExit(main())
