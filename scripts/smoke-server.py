#!/usr/bin/env python3
"""Exercise the unified Linux application, local CLI and real LiveKit with disposable data.

A temporary Nginx also verifies the production routing template over TLS and WSS.
No production configuration/database is read; this does not exercise real audio.
"""
import base64
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
from pathlib import Path
import secrets
import shutil
import socket
import ssl
import subprocess
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
ORIGIN = "https://chirp.youzifeile.cn"
SCHEMA = 18


def run(*args, **kwargs):
    return subprocess.run(args, text=True, capture_output=True, check=True, **kwargs).stdout.strip()


class NoRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def main():
    directory = Path(tempfile.mkdtemp(prefix="chirp-unified-smoke-", dir=ROOT / ".build"))
    project = "chirp-smoke-" + secrets.token_hex(4)
    secret = secrets.token_hex(32)
    image = os.environ.get("CHIRP_SMOKE_IMAGE", "chirp-server:0.14.0")
    proxy_image = os.environ.get("CHIRP_SMOKE_NGINX_IMAGE", "nginx:stable-alpine")
    proxy = project + "-proxy"
    compose_file = directory / "compose.yaml"
    environment = dict(os.environ, LIVEKIT_API_KEY="chirp", LIVEKIT_API_SECRET=secret, CHIRP_IMAGE=image,
                       CHIRP_PUBLIC_ORIGIN=ORIGIN, CHIRP_HTTP_PUBLISH_IP="127.0.0.1")
    (directory / ".env").write_text("LIVEKIT_API_SECRET=" + secret + "\n")
    (directory / ".env").chmod(0o600)
    checks = 0
    started = False

    def compose(*args):
        return run("docker", "compose", "--project-name", project, "--project-directory", str(directory),
                   "--env-file", str(directory / ".env"), "-f", str(compose_file), *args, env=environment)

    try:
        shutil.copyfile(ROOT / "deploy/compose.yaml", compose_file)
        (directory / "livekit.yaml").write_text((ROOT / "deploy/livekit.yaml.example").read_text().replace("REPLACE_WITH_YOUR_PUBLIC_IP", "127.0.0.1"))
        plan = json.loads(compose("config", "--format", "json"))
        assert set(plan["services"]) == {"app", "livekit"}
        app_plan = plan["services"]["app"]
        assert app_plan["environment"]["CHIRP_PUBLIC_ORIGIN"] == ORIGIN
        assert app_plan["environment"]["LIVEKIT_HTTP_URL"] == "http://livekit:7880"
        assert "CHIRP_GROUP_CONTROL_SECRET" not in app_plan["environment"]
        assert app_plan["read_only"] and app_plan["cap_drop"] == ["ALL"]
        assert app_plan["build"]["target"] == "app"
        assert app_plan["volumes"][0]["bind"]["create_host_path"] is False
        assert app_plan["logging"] == {"driver": "none"}
        assert app_plan["environment"]["CHIRP_LOG_SERVER_ENABLED"] == "false"
        app_plan["volumes"] = [{"type": "volume", "source": "sqlite-data", "target": "/data"},
                               {"type": "volume", "source": "application-logs", "target": "/app/log"}]
        app_plan.pop("build")
        plan["volumes"] = {"sqlite-data": {"driver": "local"}, "application-logs": {"driver": "local"}}
        for service in plan["services"].values():
            for port in service["ports"]:
                port["published"], port["host_ip"] = "0", "127.0.0.1"
        fixture = directory / "sqlite-fixture"
        run("sh", "scripts/go.sh", "build", "-trimpath", "-o", str(fixture), "./scripts/sqlite-fixture",
            cwd=ROOT, env=dict(os.environ, CGO_ENABLED="0", GOOS="linux", GOARCH="amd64"))
        compose_file = directory / "compose-test.json"
        compose_file.write_text(json.dumps(plan))
        compose_file.chmod(0o600)
        started = True
        compose("up", "-d", "--no-build", "--wait", "--wait-timeout", "60")
        app = compose("ps", "--quiet", "app")
        media = compose("ps", "--quiet", "livekit")
        media_started = json.loads(run("docker", "inspect", media))[0]["State"]["StartedAt"]

        def base(container, port):
            details = json.loads(run("docker", "inspect", container))[0]
            return "http://127.0.0.1:" + details["NetworkSettings"]["Ports"][f"{port}/tcp"][0]["HostPort"]

        address = base(app, 18115)
        media_address = base(media, 7880)
        opener = urllib.request.build_opener(NoRedirects())
        admin_cookie = ""

        def sql(statement):
            args = ["-query"] if statement.lstrip().upper().startswith(("SELECT", "PRAGMA")) else []
            return run("docker", "run", "--rm", "-i", "--network", "none", "--volumes-from", app + ":rw",
                       "--mount", f"type=bind,source={fixture},target=/fixture,readonly", "--entrypoint", "/fixture", image,
                       *args, input=statement)

        mac_version, mac_build = sql(
            "SELECT latest_version, latest_build FROM client_version_policies WHERE platform = 'macos'"
        ).split("\t")

        def request(path, token=None, payload=None, method=None, administrator=False, headers=None, target=None, client=None):
            nonlocal checks
            h = {"Host": "chirp.youzifeile.cn", "Content-Type": "application/json",
                 "X-Chirp-Platform": "macos", "X-Chirp-Version": mac_version, "X-Chirp-Build": mac_build}
            if token:
                h["Authorization"] = "Bearer " + token
            if administrator:
                h.update(Cookie=admin_cookie, Origin=ORIGIN)
            h.update(headers or {})
            body = payload if isinstance(payload, bytes) else (None if payload is None else json.dumps(payload).encode())
            req = urllib.request.Request((target or address) + path, data=body, headers=h, method=method)
            try:
                response = (client or opener).open(req, timeout=12)
            except urllib.error.HTTPError as error:
                response = error
            with response:
                raw = response.read()
                value = json.loads(raw) if raw and "application/json" in response.headers.get("Content-Type", "") else raw.decode()
                checks += 1
                return response.status, value, response.headers

        def manage(path, payload=None, method=None):
            return request("/admin" + path, payload=payload, method=method, administrator=True)

        def pending(name):
            account, receipt = "account_" + secrets.token_hex(12), "CHIRP-" + secrets.token_hex(12)
            sql(f"INSERT INTO passkey_accounts(id,nickname,request_id,created_at) VALUES('{account}','{name}','{receipt}','2026-10-24T00:00:00Z');"
                f"INSERT INTO passkey_credentials(id,account_id,credential_json) VALUES(X'{secrets.token_hex(32)}','{account}',X'7b7d');")
            return account, receipt

        def browser_session(account):
            value = secrets.token_urlsafe(32)
            sql(f"INSERT INTO passkey_sessions(token_hash,account_id,expires_at) VALUES(X'{hashlib.sha256(value.encode()).hexdigest()}','{account}',{int(time.time())+3600});")
            return "chirp_passkey_session=" + value

        def native_login(member):
            token, login = "chirp_" + secrets.token_urlsafe(32), "login_" + secrets.token_hex(12)
            sql(f"UPDATE members SET credential_hash=X'{hashlib.sha256(token.encode()).hexdigest()}',login_id='{login}',room_join_sequence=0,credential_expires_at={int(time.time())+72000} WHERE id='{member['id']}';")
            return token

        info = json.loads(run("docker", "inspect", app))[0]
        assert info["Config"]["User"] == "65532:65532"
        assert "TZ=Asia/Hong_Kong" in info["Config"]["Env"]
        assert run("docker", "exec", app, "date", "+%z") == "+0800"
        assert info["HostConfig"]["LogConfig"]["Type"] == "none"
        assert set(info["HostConfig"]["PortBindings"]) == {"18115/tcp"}
        assert json.loads(run("docker", "exec", app, "chirp", "version"))["schema"] == SCHEMA
        for retired in ("chirp-admin", "chirp-passkey", "chirp-group"):
            run("docker", "exec", app, "test", "!", "-e", "/usr/local/bin/" + retired)
        assert request("/healthz")[1] == {"service": "chirp", "status": "ok"}
        assert request("/admin/")[0] == 303
        assert request("/admin/api/overview")[0] == 401
        assert request("/admin/assets/app.js")[0] == 401
        assert request("/api/overview")[0] == 404
        for route in ("/internal/group/end", "/internal/group/remove"):
            assert request(route, payload={})[0] == 404
        status, manifest, _ = request("/v1/client-config")
        assert status == 200 and manifest["protocol_version"] == 5
        assert len(manifest["endpoints"]) == 10
        assert all(url.startswith(ORIGIN + "/") for url in manifest["endpoints"].values())
        status, options, _ = request("/api/auth/register/begin", payload={"nickname": "Friend"}, headers={"Origin": ORIGIN})
        assert status == 200 and options["publicKey"]["rp"]["id"] == "chirp.youzifeile.cn"
        assert request("/api/auth/register/begin", payload={"nickname": "Evil"})[0] == 403
        account, receipt = pending("Maintainer")
        administrator = json.loads(run("docker", "exec", app, "chirp", "admin", "bootstrap", "--request-id", receipt))
        assert administrator["is_admin"]
        repeated = subprocess.run(["docker", "exec", app, "chirp", "admin", "bootstrap", "--request-id", receipt], capture_output=True)
        assert repeated.returncode != 0
        admin_cookie = browser_session(account)
        assert manage("/api/overview")[0] == 200
        assert manage("/api/members/" + administrator["id"], method="DELETE")[0] == 409
        assert request("/admin/api/rooms", payload={"display_name": "Blocked"}, headers={"Cookie": admin_cookie, "Origin": "https://attacker.test"})[0] == 403
        for path in ("/", "/register", "/device", "/assets/app.js", "/admin/", "/admin/assets/app.js"):
            assert request(path, administrator=path.startswith("/admin"))[0] == 200
        other_account, other_receipt = pending("Regular")
        status, member, _ = manage("/api/registrations/" + other_receipt + "/approve", {})
        assert status == 200
        assert request("/admin/api/overview", headers={"Cookie": browser_session(other_account)})[0] == 403
        token = native_login(member)
        assert request("/v1/me", token)[0] == 200
        assert request("/admin/api/overview", token)[0] == 401
        receipts = [pending("Friend" + chr(65 + i))[1] for i in range(12)]
        with ThreadPoolExecutor(max_workers=12) as pool:
            assert all(status == 200 for status in pool.map(lambda r: manage("/api/registrations/" + r + "/approve", {})[0], receipts))
        assert manage("/api/rooms/friends", method="DELETE")[0] == 409
        status, room, _ = manage("/api/rooms", {"display_name": "Smoke room"})
        assert status == 201
        assert manage("/api/rooms/" + room["room_id"], method="DELETE")[0] == 204
        check = request("/v1/rooms/friends/preflight", token, {"join_sequence": 1})[1]
        status, admission, _ = request("/v1/rooms/friends/join", token, {"join_sequence": 1, "preflight_proof": check["preflight_proof"]})
        assert status == 200 and admission["livekit_url"] == "wss://chirp.youzifeile.cn"
        group_path = "/v1/group/rooms/friends/config"
        old_server = request(group_path, token)[1]["server_id"]
        assert request(group_path)[0] == 401
        assert request("/v1/state", token)[0] == 200
        stream_request = urllib.request.Request(address + "/v1/events", headers={"Authorization": "Bearer " + token})
        with urllib.request.urlopen(stream_request, timeout=8) as stream:
            assert stream.headers["Content-Type"].startswith("text/event-stream")
            assert stream.readline().startswith(b"event: state")
        payload = secrets.token_bytes(64 * 1024)
        attachment = secrets.token_hex(16)
        entry_header = {"X-Chirp-Entry": admission["entry_id"]}
        create = {"id": attachment, "entry_id": admission["entry_id"], "ciphertext_size": len(payload), "ciphertext_sha256": hashlib.sha256(payload).hexdigest(), "recipients": [admission["participant_identity"]]}
        path = "/v1/rooms/friends/attachments"
        assert request(path, token, create, headers=entry_header)[0] == 201
        chunk = path + "/" + attachment + "/chunks/0"
        chunk_headers = dict(entry_header, **{"Content-Type": "application/octet-stream", "X-Chirp-Chunk-SHA256": hashlib.sha256(payload).hexdigest()})
        assert request(chunk, token, payload, "PUT", headers=chunk_headers)[0] == 204
        # Validate the actual Nginx template with a disposable certificate and network.
        run("openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1", "-subj", "/CN=chirp.youzifeile.cn",
            "-addext", "subjectAltName=DNS:chirp.youzifeile.cn,IP:127.0.0.1", "-keyout", str(directory / "key.pem"), "-out", str(directory / "cert.pem"))
        template = (ROOT / "deploy/nginx-upstreams.example.conf").read_text().replace("http://127.0.0.1:18115", "http://app:18115").replace("http://127.0.0.1:7880", "http://livekit:7880")
        template = template.replace("/path/to/chirp/fullchain.pem", "/proof/cert.pem").replace("/path/to/chirp/privkey.pem", "/proof/key.pem")
        (directory / "nginx.conf").write_text("events {}\nhttp { include /etc/nginx/mime.types;\n" + template + "\n}\n")
        run("docker", "run", "-d", "--name", proxy, "--network", project + "_default", "-p", "127.0.0.1::443",
            "--mount", f"type=bind,source={directory / 'nginx.conf'},target=/etc/nginx/nginx.conf,readonly",
            "--mount", f"type=bind,source={directory},target=/proof,readonly", proxy_image)
        proxy_info = json.loads(run("docker", "inspect", proxy))[0]
        proxy_port = int(proxy_info["NetworkSettings"]["Ports"]["443/tcp"][0]["HostPort"])
        tls = ssl.create_default_context(cafile=str(directory / "cert.pem"))
        tls_client = urllib.request.build_opener(NoRedirects(), urllib.request.HTTPSHandler(context=tls))
        proxy_address = "https://127.0.0.1:" + str(proxy_port)
        for _ in range(30):
            try:
                if request("/healthz", target=proxy_address, client=tls_client)[0] == 200:
                    break
            except OSError:
                time.sleep(.2)
        else:
            raise RuntimeError("temporary Nginx did not start")
        for route in ("/rtc/validate", "/rtc/v1/validate"):
            assert request(route, target=proxy_address, client=tls_client)[0] == 401
        assert request("/twirp/livekit.RoomService/ListRooms", payload={}, target=proxy_address, client=tls_client)[0] == 404
        assert request("/admin/api/overview", administrator=True, target=proxy_address, client=tls_client)[0] == 200
        for route in ("/", "/register", "/assets/app.js", "/v1/client-config"):
            assert request(route, target=proxy_address, client=tls_client)[0] == 200
        ws_path = "/rtc?" + urllib.parse.urlencode({"access_token": admission["token"], "protocol": 16, "sdk": "python", "version": "test"})
        with socket.create_connection(("127.0.0.1", proxy_port), timeout=8) as connection:
            with tls.wrap_socket(connection, server_hostname="chirp.youzifeile.cn") as websocket:
                key = base64.b64encode(secrets.token_bytes(16)).decode()
                websocket.sendall((f"GET {ws_path} HTTP/1.1\r\nHost: chirp.youzifeile.cn\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n").encode())
                assert websocket.recv(4096).startswith(b"HTTP/1.1 101"), "same-origin WSS upgrade failed"
        # Recreate only the application: SQLite persists and group context changes.
        compose("up", "-d", "--no-build", "--force-recreate", "--wait", "--wait-timeout", "60", "app")
        app = compose("ps", "--quiet", "app")
        address = base(app, 18115)
        assert json.loads(run("docker", "inspect", media))[0]["State"]["StartedAt"] == media_started
        assert request("/healthz")[0] == 200 and manage("/api/overview")[0] == 200
        assert request(group_path, token)[1]["server_id"] != old_server
        assert request("/v1/me", token)[0] == 200
        assert sql("PRAGMA integrity_check;") == "ok"
        assert sql("PRAGMA foreign_key_check;") == ""
        assert request("/api/auth/logout", payload={}, headers={"Cookie": admin_cookie, "Origin": ORIGIN})[0] == 204
        assert manage("/api/overview")[0] == 401
        print(json.dumps({"checks": checks, "production_services": 2, "origin": ORIGIN, "schema": SCHEMA,
                          "discovery_protocol": 5, "same_origin_tls_wss": "passed", "media_preserved_on_app_recreation": True,
                          "sqlite_integrity": "ok", "real_audio": "not exercised"}, indent=2))
    except Exception:
        if started:
            logs = compose("logs", "--tail", "50")
            print(logs.replace(secret, "<test-secret>"), file=__import__('sys').stderr)
        raise
    finally:
        subprocess.run(["docker", "rm", "-f", proxy], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if started:
            compose("down", "--volumes", "--remove-orphans")
        shutil.rmtree(directory)


if __name__ == "__main__":
    main()
