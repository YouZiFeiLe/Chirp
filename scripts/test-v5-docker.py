#!/usr/bin/env python3
"""Disposable Docker deployment checks; never reads production config or keys."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import urllib.request
import uuid
import base64
import urllib.error

ROOT = Path(__file__).resolve().parents[1]
HTTP = urllib.request.build_opener(urllib.request.ProxyHandler({}))
HELPER = 'docker-proxy.youzifeile.cn/golang:1.27.4-alpine3.24'

def run(*args, check=True):
    return subprocess.run(args, cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=check)

def main():
    client_trust = json.loads((ROOT/'Client/apple/Shared/Resources/AuthorizationTrust.json').read_text())
    assert client_trust, 'The Apple client needs a preconfigured public key'
    origin = 'https://independent-deployment.test:443'
    expected_public = client_trust['public_key']
    key_source = Path(os.environ.get('CHIRP_AUTHORIZATION_KEY_SOURCE', str(ROOT/'deploy/authorization-key.default')))
    name = 'chirp-v5-check-' + uuid.uuid4().hex[:10]
    volumes = {kind:name+'-'+kind for kind in ('app','log','authorization','keys')}
    with tempfile.TemporaryDirectory(prefix='chirp-v5-docker-') as directory:
        folder=Path(directory)
        env=folder/'env'
        env.write_text('LIVEKIT_API_SECRET='+'x'*64+'\nCHIRP_IMAGE=chirp-server:v5-local\nCHIRP_PUBLIC_ORIGIN='+origin+'\n')
        config=folder/'livekit.yaml'
        config.write_text('port: 7880\nrtc:\n  udp_port: 7882\n  use_external_ip: false\n  enable_loopback_candidate: true\nlogging:\n  level: error\n')
        config.chmod(0o444)
        override=folder/'override.yaml'
        override.write_text(f'''services:
  app:
    secrets: !reset []
    volumes: !override
      - {volumes['app']}:/data
      - {volumes['log']}:/app/log
      - {volumes['authorization']}:/authorization
      - {volumes['keys']}:/run/secrets:ro
    ports: !override ["127.0.0.1::18115"]
  livekit:
    volumes: !override ["{config}:/etc/livekit.yaml:ro"]
    ports: !override ["127.0.0.1::7880", "127.0.0.1::7882/udp"]
volumes:
'''+''.join(f'  {volume}:\n    external: true\n' for volume in volumes.values()))
        compose=['docker','compose','--project-name',name,'--env-file',str(env),'-f',str(ROOT/'deploy/compose.yaml'),'-f',str(override)]
        try:
            for volume in volumes.values(): run('docker','volume','create',volume)
            for kind,uid in [('app','65532'),('log','65532'),('authorization','65532'),('keys','65532')]:
                run('docker','run','--rm','--platform','linux/amd64','--mount',f'type=volume,src={volumes[kind]},dst=/setup',HELPER,'sh','-c',f'chown {uid}:{uid} /setup && chmod 700 /setup')
            run('docker','run','--rm','--platform','linux/amd64',
                '--mount',f'type=bind,src={key_source},dst=/preset,readonly',
                '--mount',f'type=volume,src={volumes["keys"]},dst=/setup',HELPER,'sh','-c',
                'cp /preset /setup/authorization-key && chown 65532:65532 /setup/authorization-key && chmod 400 /setup/authorization-key')
            # Real scratch image: derive only public material and reject absent
            # or substituted pins, without opening a DB or enabling networking.
            trust_tool=['docker','run','--rm','--platform','linux/amd64','--network','none','--read-only','--cap-drop','ALL',
                        '--security-opt','no-new-privileges','--mount',f'type=volume,src={volumes["keys"]},dst=/run/secrets,readonly',
                        '--mount',f'type=bind,src={folder},dst=/release,readonly',
                        'chirp-server:v5-local','authorization']
            folder.chmod(0o755)
            exported=run(*trust_tool,'-export-trust').stdout
            entry=json.loads(exported)
            assert entry['public_key']==expected_public and set(entry)=={'public_key'}
            pin=folder/'trust.json'; pin.write_text(json.dumps(client_trust)); pin.chmod(0o444)
            run(*trust_tool,'-verify-trust','/release/trust.json')
            pin.chmod(0o600); pin.write_text('{}'); pin.chmod(0o444)
            assert run(*trust_tool,'-verify-trust','/release/trust.json',check=False).returncode != 0
            run(*compose,'config','--quiet')
            run(*compose,'up','-d','--no-build','--wait','--wait-timeout','90')
            for service in ('app','livekit'):
                identifier=run(*compose,'ps','-q',service).stdout.strip()
                inspected=json.loads(run('docker','inspect',identifier).stdout)[0]
                host=inspected['HostConfig']
                assert host['ReadonlyRootfs'] and host['CapDrop']==['ALL']
                assert 'no-new-privileges:true' in host['SecurityOpt']
                assert inspected['Config']['User'] in ('65532:65532','65534:65534')
                assert all('/var/run/docker.sock' != mount['Destination'] for mount in inspected['Mounts'])
                if service == 'app':
                    assert run('docker','exec',identifier,'/bin/sh','-c','true',check=False).returncode != 0
                    marker=folder/'marker'; marker.write_text('test')
                    assert run('docker','cp',str(marker),identifier+':/tamper-test',check=False).returncode != 0
            for service,port in [('app','18115')]:
                endpoint=run(*compose,'port',service,port).stdout.strip()
                print('Checking',service,endpoint,flush=True)
                with HTTP.open('http://'+endpoint+'/healthz',timeout=5) as response: assert response.status in (200,204)
            endpoint=run(*compose,'port','app','18115').stdout.strip()
            request=urllib.request.Request('http://'+endpoint+'/authorization/v5/snapshot',method='POST',data=json.dumps({'origin':origin,'nonce':expected_public,'roots':[expected_public]}).encode(),headers={'Content-Type':'application/json'})
            with HTTP.open(request,timeout=5) as response:
                body=json.load(response); assert set(body)=={'payload','signature'}
            app=run(*compose,'ps','-q','app').stdout.strip()
            mounts=json.loads(run('docker','inspect',app).stdout)[0]['Mounts']
            assert any(mount['Destination']=='/run/secrets' and not mount['RW'] for mount in mounts)
            # The same app process owns the durable authorization state and API.
            with HTTP.open('http://'+endpoint+'/authorization/healthz',timeout=5) as response: assert response.status==204
            run(*compose,'restart','app')
            # An ephemeral published port may be reallocated on container restart.
            endpoint=run(*compose,'port','app','18115').stdout.strip()
            request=urllib.request.Request('http://'+endpoint+'/authorization/v5/snapshot',method='POST',data=request.data,headers={'Content-Type':'application/json'})
            for attempt in range(100):
                try:
                    with HTTP.open(request,timeout=5) as response: assert set(json.load(response))=={'payload','signature'}
                    break
                except OSError: time.sleep(.1)
            else: raise RuntimeError('authorization did not return after app restart')
            # The same key-only client resource also supports a different deployment.
            next_origin='https://another-deployment.test:8443'
            env.write_text(env.read_text().replace('CHIRP_PUBLIC_ORIGIN='+origin, 'CHIRP_PUBLIC_ORIGIN='+next_origin))
            run(*compose,'up','-d','--no-build','--wait','--wait-timeout','90','app')
            endpoint=run(*compose,'port','app','18115').stdout.strip()
            request=urllib.request.Request('http://'+endpoint+'/authorization/v5/snapshot',method='POST',data=json.dumps({'origin':next_origin,'nonce':expected_public,'roots':[expected_public]}).encode(),headers={'Content-Type':'application/json'})
            with HTTP.open(request,timeout=5) as response:
                envelope=json.load(response)
                assert json.loads(base64.b64decode(envelope['payload']))['origin']==next_origin
            old_request=urllib.request.Request(request.full_url,method='POST',data=json.dumps({'origin':origin,'nonce':expected_public,'roots':[expected_public]}).encode(),headers={'Content-Type':'application/json'})
            try:
                HTTP.open(old_request,timeout=5)
            except urllib.error.HTTPError as error:
                assert error.code==400
            else:
                raise AssertionError('the new origin accepted an old-origin authorization request')
            print('PASS: key-only Apple resource matches the preset seed across two deployment origins; wrong key and old origin rejected; two non-root read-only containers; no shell; read-only signing key; authorization survives restart.')
        finally:
            result=run(*compose,'down','--remove-orphans',check=False)
            if result.returncode: print(result.stderr)
            for volume in volumes.values(): run('docker','volume','rm',volume,check=False)

if __name__=='__main__':
    main()
