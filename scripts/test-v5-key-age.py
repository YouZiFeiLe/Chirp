#!/usr/bin/env python3
"""Prove client-forced rekey against a server configured for 30-minute rounds."""
import json
import os
from pathlib import Path
import subprocess
import sys
ROOT = Path(__file__).resolve().parents[1]
candidate = sys.argv[1:] == ['--candidate']
if sys.argv[1:] and not candidate: raise SystemExit('usage: test-v5-key-age.py [--candidate]')
binary = ROOT / '.build/v5/key-age-fixture'
subprocess.run(['go','build','-o',str(binary),'./internal/group/testdata/server'],cwd=ROOT,check=True)
with subprocess.Popen([str(binary)],cwd=ROOT,env=dict(os.environ,CHIRP_GROUP_TEST_ROTATION='40s' if candidate else '30m',CHIRP_GROUP_TEST_TRANSITION='30s' if candidate else '12s'),stdout=subprocess.PIPE,text=True) as server:
    try:
        endpoint=json.loads(server.stdout.readline())['url']
        env=dict(os.environ,CHIRP_GROUP_TEST_URL=endpoint,CHIRP_GROUP_TEST_FORCE_REKEY='1',CHIRP_GROUP_TEST_CANDIDATE='1' if candidate else '0')
        subprocess.run(['swift','test','--package-path','Client/apple','--scratch-path','.build/swift-v5-age','--filter','groupCandidateTimeoutRetiresMediaBeforeBlockedPreparationReturns' if candidate else 'groupForcesFreshSecretsBeforeLongServerRotationInterval'],cwd=ROOT,env=env,check=True)
    finally:
        server.terminate(); server.wait(timeout=5)
