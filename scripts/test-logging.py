#!/usr/bin/env python3
"""Check container log routing/timezone with disposable volumes and a mock collector.

Build the app image first; CHIRP_LOGGING_IMAGE overrides chirp-server:0.14.0.
No production configuration, databases, or remote log servers are used.
"""
import http.server
import json
import os
import secrets
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request


def docker(*args):
    return subprocess.run(["docker", *args], check=True, text=True, capture_output=True).stdout.strip()


def main():
    image = os.environ.get("CHIRP_LOGGING_IMAGE", "chirp-server:0.14.0")
    prefix = "chirp-logging-" + secrets.token_hex(5)
    containers, volumes = [], []
    records, requests = [], []
    lock = threading.Lock()
    fail = threading.Event()

    class Collector(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            body = self.rfile.read(int(self.headers["Content-Length"]))
            path = urllib.parse.urlparse(self.path)
            query = urllib.parse.parse_qs(path.query)
            assert path.path == "/insert/jsonline"
            assert query["_time_field"] == ["time"] and query["_msg_field"] == ["msg"]
            assert self.headers["Content-Type"] == "application/stream+json"
            with lock:
                requests.append(self.path)
                if not fail.is_set():
                    records.extend(json.loads(line) for line in body.splitlines())
            self.send_response(503 if fail.is_set() else 204)
            self.end_headers()

        def log_message(self, *_):
            pass

    collector = http.server.ThreadingHTTPServer(("0.0.0.0", 0), Collector)
    thread = threading.Thread(target=collector.serve_forever, daemon=True)
    thread.start()
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    secret = secrets.token_hex(32)

    def request(address, path):
        req = urllib.request.Request(address + path, headers={"X-Request-ID": "untrusted-logging-test-id"})
        try:
            response = opener.open(req, timeout=2)
        except urllib.error.HTTPError as error:
            response = error
        with response:
            response.read()
            return response.status, response.headers.get("X-Request-ID")

    def start(mode):
        name = prefix + "-" + mode
        data, logs = name + "-data", name + "-logs"
        containers.append(name)
        volumes.extend([data, logs])
        args = ["run", "-d", "--name", name, "--read-only", "--cap-drop", "ALL", "--security-opt", "no-new-privileges:true",
                "--log-driver", "none", "-p", "127.0.0.1::18115", "--mount", f"type=volume,source={data},target=/data",
                "--mount", f"type=volume,source={logs},target=/app/log",
                "-e", "CHIRP_PUBLIC_ORIGIN=https://logging.test", "-e", "LIVEKIT_HTTP_URL=http://127.0.0.1:1",
                "-e", "LIVEKIT_API_KEY=disposable", "-e", "LIVEKIT_API_SECRET=" + secret,
                "-e", "CHIRP_LOG_SERVER_ENABLED=" + ("true" if mode == "remote" else "false")]
        if mode == "remote":
            if sys.platform != "darwin":
                args.extend(["--add-host", "host.docker.internal:host-gateway"])
            args.extend(["-e", f"CHIRP_LOG_SERVER_URL=http://host.docker.internal:{collector.server_port}"])
        docker(*args, image)
        details = json.loads(docker("inspect", name))[0]
        assert details["HostConfig"]["LogConfig"]["Type"] == "none"
        assert details["Config"]["User"] == "65532:65532"
        assert docker("exec", name, "date", "+%z") == "+0800"
        port = details["NetworkSettings"]["Ports"]["18115/tcp"][0]["HostPort"]
        address = "http://127.0.0.1:" + port
        until = time.monotonic() + 10
        while True:
            try:
                assert request(address, "/healthz")[0] == 200
                break
            except (OSError, urllib.error.URLError):
                if time.monotonic() >= until:
                    raise
                time.sleep(0.1)
        return name, logs, address

    def read_volume(volume, *args):
        return docker("run", "--rm", "--network", "none", "--mount", f"type=volume,source={volume},target=/app/log,readonly",
                      "--entrypoint", args[0], image, *args[1:])

    try:
        name, logs, address = start("local")
        status, local_id = request(address, "/v1/me?code=secret-query-must-not-be-logged")
        assert status == 401 and local_id and local_id != "untrusted-logging-test-id"
        date = docker("exec", name, "date", "+%F")
        docker("stop", "--time", "15", name)
        raw = read_volume(logs, "cat", "/app/log/chirp-" + date + ".log")
        local = [json.loads(line) for line in raw.splitlines()]
        assert any(row.get("event") == "application.stopped" for row in local)
        assert any(row.get("request_id") == local_id and row.get("error_code") == "UNAUTHORIZED" for row in local)
        assert all(row["time"].endswith("+08:00") for row in local)
        assert secret not in raw and "secret-query-must-not-be-logged" not in raw
        assert read_volume(logs, "stat", "-c", "%a", "/app/log/chirp-" + date + ".log") == "600"

        name, logs, address = start("remote")
        assert request(address, "/v1/me")[0] == 401
        fail.set()
        with lock:
            before = len(requests)
        assert request(address, "/unknown")[0] == 404
        until = time.monotonic() + 5
        while True:
            with lock:
                attempts = len(requests) - before
            if attempts >= 3:
                break
            assert time.monotonic() < until, "remote logs did not retry"
            time.sleep(0.05)
        # Let the final failed response exhaust the retry budget before recovery.
        time.sleep(0.2)
        fail.clear()
        assert request(address, "/v1/me")[0] == 401
        docker("stop", "--time", "15", name)
        assert read_volume(logs, "ls", "-A", "/app/log") == "", "remote mode wrote local files"
        with lock:
            remote = list(records)
        assert any(row.get("event") == "application.stopped" for row in remote)
        assert any(row.get("event") == "logging.delivery_recovered" and row["dropped_records"] > 0 for row in remote)
        assert all(row["time"].endswith("+08:00") for row in remote)
        assert secret not in json.dumps(remote)
        print("Container logging checks passed: UTC+8, local files/permissions, request IDs, remote retries/recovery, shutdown flush, no remote fallback files.")
    finally:
        for name in containers:
            subprocess.run(["docker", "rm", "-f", name], capture_output=True)
        for volume in volumes:
            subprocess.run(["docker", "volume", "rm", volume], capture_output=True)
        collector.shutdown()
        collector.server_close()
        thread.join()


if __name__ == "__main__":
    main()
