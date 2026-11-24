#!/usr/bin/env python3
"""Check that both applications and their tests compile the intended files."""
import json
from pathlib import Path
import plistlib
import subprocess
import xml.etree.ElementTree as ET

APPLE = Path(__file__).resolve().parents[1]
PROJECT = APPLE / "Chirp.xcodeproj"
project = json.loads(subprocess.check_output([
    "plutil", "-convert", "json", "-o", "-", str(PROJECT / "project.pbxproj")
]))
objects = project["objects"]
paths = {}
failures = []


def require(condition, message):
    if not condition:
        failures.append(message)


def visit(identifier, directory):
    item = objects[identifier]
    if item.get("sourceTree", "<group>") != "<group>":
        return
    path = directory / item.get("path", "")
    if item["isa"] == "PBXFileReference":
        paths[identifier] = path.resolve()
    for child in item.get("children", []):
        visit(child, path)


visit(objects[project["rootObject"]]["mainGroup"], APPLE)
targets = {item["name"]: (identifier, item) for identifier, item in objects.items()
           if item["isa"] == "PBXNativeTarget"}


def phase_files(target, phase_type):
    result = []
    for phase_id in target["buildPhases"]:
        phase = objects[phase_id]
        if phase["isa"] != phase_type:
            continue
        for build_id in phase["files"]:
            reference = objects[build_id].get("fileRef")
            if reference in paths:
                result.append(paths[reference])
    require(len(result) == len(set(result)), f'{target["name"]}: duplicate files in {phase_type}')
    return set(result)


shared = set((APPLE / "Shared").rglob("*.swift"))
# Test-only helpers may be symlinked to the MLS package's shared fixtures.
tests = {path.resolve() for path in (APPLE / "Tests").glob("*.swift")}
manifest = APPLE / "Shared/Resources/PrivacyInfo.xcprivacy"
for platform in ("macOS", "iOS"):
    app_id, app = targets[f"Chirp-{platform}"]
    test_id, test = targets[f"Chirp-{platform}-Tests"]
    expected = shared - ({APPLE / "Shared/Views/MacRoomChatLayout.swift"} if platform == "iOS" else set())
    actual = phase_files(app, "PBXSourcesBuildPhase")
    require(actual == expected, f'{app["name"]}: source membership differs: {sorted(map(str, actual ^ expected))}')
    actual_tests = phase_files(test, "PBXSourcesBuildPhase")
    require(actual_tests == tests, f'{test["name"]}: test membership differs: {sorted(map(str, actual_tests ^ tests))}')
    require(manifest in phase_files(app, "PBXResourcesBuildPhase"), f'{app["name"]}: missing application privacy manifest')
    require(APPLE / "Shared/Resources/AuthorizationTrust.json" in phase_files(app, "PBXResourcesBuildPhase"),
            f'{app["name"]}: missing bundled authorization trust configuration')
    require(app["productType"] == "com.apple.product-type.application", f'{app["name"]}: must produce an app bundle')
    for configuration_id in objects[app["buildConfigurationList"]]["buildConfigurations"]:
        configuration = objects[configuration_id]
        settings = configuration["buildSettings"]
        label = f'{app["name"]} {configuration["name"]}'
        require(settings.get("SWIFT_VERSION") == "6.0", f"{label}: enable Swift 6")
        require(settings.get("SWIFT_STRICT_CONCURRENCY") == "complete", f"{label}: enable complete concurrency checking")
        require(settings.get("ENABLE_USER_SCRIPT_SANDBOXING") == "YES", f"{label}: enable script sandboxing")
        require(not settings.get("DEVELOPMENT_TEAM"), f"{label}: do not commit a personal signing team")
        if platform == "macOS":
            require(settings.get("ENABLE_HARDENED_RUNTIME") == "YES", f"{label}: enable hardened runtime")
        info = plistlib.loads((APPLE / settings["INFOPLIST_FILE"]).read_bytes())
        for key in ("NSMicrophoneUsageDescription", "NSCameraUsageDescription", "NSLocalNetworkUsageDescription"):
            require(bool(info.get(key)), f"{label}: missing {key}")
        require(not info.get("NSAppTransportSecurity", {}).get("NSAllowsArbitraryLoads"), f"{label}: unrestricted ATS exception")
    scheme = ET.parse(PROJECT / f"xcshareddata/xcschemes/Chirp-{platform}.xcscheme")
    references = scheme.findall("TestAction/Testables/TestableReference/BuildableReference")
    require(any(ref.get("BlueprintIdentifier") == test_id for ref in references), f'{app["name"]}: scheme does not run its tests')
    require(any(objects[dependency].get("target") == app_id for dependency in test["dependencies"]), f'{test["name"]}: missing app dependency')

ui_id, ui = targets["Chirp-iOS-AudioUITests"]
require(ui["productType"] == "com.apple.product-type.bundle.ui-testing", "iOS audio UI checks need a UI test runner")
require(phase_files(ui, "PBXSourcesBuildPhase") == set((APPLE / "iOS/UITests").glob("*.swift")),
        "iOS audio UI test source membership differs")
require(any(objects[dependency].get("target") == targets["Chirp-iOS"][0] for dependency in ui["dependencies"]),
        "iOS audio UI tests must target the actual iOS app")
ui_scheme = ET.parse(PROJECT / "xcshareddata/xcschemes/Chirp-iOS-AudioUI.xcscheme")
require(any(ref.get("BlueprintIdentifier") == ui_id for ref in ui_scheme.findall("TestAction/Testables/TestableReference/BuildableReference")),
        "iOS audio UI scheme does not run its tests")

# Cross-client fixture consistency belongs to full-repository checks. Backend
# Docker builds intentionally contain only go.mod, go.sum, cmd/ and internal/.
go_vectors = APPLE.parents[1] / "internal/identity/testdata/v5.json"
swift_vectors = APPLE / "MLS/Tests/ChirpMLSTests/Fixtures/v5.json"
try:
    require(go_vectors.read_bytes() == swift_vectors.read_bytes(), "Go and Swift V5 vector resources differ")
except OSError as error:
    failures.append(f"Cannot check V5 vector resources: {error}")

require((APPLE.parents[1] / "internal/identity/testdata/recovery-v1.json").read_bytes() == (APPLE / "MLS/Tests/ChirpMLSTests/Fixtures/recovery-v1.json").read_bytes(), "Go and Swift recovery v1 vectors differ")

if failures:
    raise SystemExit("\n".join(failures))
print(f"Project checks passed: 2 app targets, 2 hosted test targets, 1 iOS UI test target, {len(shared)} shared Swift files, {len(tests)} test files; V5 vector resources agree.")
