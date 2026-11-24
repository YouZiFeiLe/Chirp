#!/usr/bin/env python3
"""Run the real Swift/Rust clients against the real Go group HTTP handler.

The fixture is loopback-only, has fake members, and does not access the deployment database or audio.
Prepare the MLS XCFramework first with scripts/prepare-mls.sh.
Set CHIRP_GROUP_MEASURE to an output JSON path to run only the four-second
steady-state traffic measurement. CHIRP_GROUP_RECOVERY_METRICS optionally records
the loopback event/restart/revocation timings from the ordinary fault scenario.
CHIRP_GROUP_STARTUP_METRICS records ten solo and trusted-pair group startup samples.
"""
import json
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]

def main():
    binary = ROOT / ".build/group-protocol-fixture"
    binary.parent.mkdir(exist_ok=True)
    subprocess.run(["sh", "scripts/go.sh", "build", "-o", str(binary), "./internal/group/testdata/server"], cwd=ROOT, check=True)
    with subprocess.Popen([str(binary)], stdout=subprocess.PIPE, text=True, cwd=ROOT) as fixture:
        try:
            endpoint = json.loads(fixture.stdout.readline())["url"]
            env = dict(os.environ, CHIRP_GROUP_TEST_URL=endpoint)
            # Run separately: the existing group scenario intentionally changes
            # global fixture availability and must not overlap the call scenario.
            tests = ("groupSteadyStateTraffic",) if env.get("CHIRP_GROUP_MEASURE") else (
                "changedServerDuringMediaConnectRequiresFreshGroupConfiguration", "groupPauseErasesBothRoundsWhileMediaIsBlocked", "groupResumesOnlyAfterEveryReadyAndFirstLease",
                "groupWithoutLocalIdentityApprovalNeverInstallsContentKeys", "groupWaitsForHumanVerificationThenEstablishesFreshMutualKeys", "groupMutualContextNeedsNoOwnerInvitationAndStillRekeys", "groupTerminalFailureCannotBeClearedByALateRestartConfiguration", "groupLocallyKnownRevocationCannotBeHiddenByOldServerSnapshots", "groupIdentityExpiryRetiresMediaWhileServerSnapshotIsStalled", "groupEventRecoveryIntegration", "groupCoordinatorIntegration", "callLifecycleRealGroupIntegration",
                "groupSmoothRotationKeepsPermissionWhilePreparingAndAcrossRepeatedCutovers", "groupSmoothRotationRevocationRejectsLatePreparedInstall",
                "groupSmoothRotationRenewsPermissionAfterDelayedActivation",
                "groupCompletedRotationSurvivesALateNextLease",
                "groupLeaseExpiryPausesAndRecoversWithFreshKeys",
                "groupModernClientRejectsLegacyServer", "groupSmoothRotationUnexpectedMediaRejectionFailsClosed")
            if env.get("CHIRP_GROUP_STARTUP_METRICS"):
                tests = ("groupStartupTimings",)
            for test in tests:
                subprocess.run(["swift", "test", "--package-path", "Client/apple", "--scratch-path", ".build/swift-core", "--filter", test], cwd=ROOT, env=env, check=True)
        finally:
            fixture.terminate()
            fixture.wait(timeout=5)

if __name__ == "__main__":
    main()
