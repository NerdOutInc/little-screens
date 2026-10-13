#!/usr/bin/env python3
"""Exercise the real server with a disposable loopback-only simulated OG."""
import hashlib
import http.cookiejar
import json
import pathlib
import shutil
import socket
import struct
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
import uuid

ROOT = pathlib.Path(__file__).resolve().parents[1]


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def main():
    subprocess.run(["swift", "build"], cwd=ROOT, check=True)
    binary_dir = subprocess.check_output(["swift", "build", "--show-bin-path"], cwd=ROOT, text=True).strip()
    agent_port, device_port = free_port(), free_port()
    while agent_port == device_port:
        device_port = free_port()
    agent_url = f"http://127.0.0.1:{agent_port}"
    device_url = f"http://127.0.0.1:{device_port}"
    opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))

    def request(url, body=None, headers=None):
        encoded = None if body is None else json.dumps(body).encode()
        req = urllib.request.Request(url, data=encoded, headers=headers or {})
        with opener.open(req, timeout=3) as response:
            return response.read()

    def tool(name, arguments=None):
        return json.loads(request(agent_url + "/api/tools/" + name, arguments or {}, {
            "Content-Type": "application/json", "X-AI-TRMNL": "1", "Origin": agent_url,
        }))

    def write(tool_name, revision, **arguments):
        return tool(tool_name, dict(arguments, expected_revision=revision, request_id=str(uuid.uuid4())))

    with tempfile.TemporaryFile(mode="w+t") as output:
        process = subprocess.Popen([
            str(pathlib.Path(binary_dir) / "ai-trmnl"), "--headless", "--ephemeral",
            "--device-host", "127.0.0.1", "--agent-port", str(agent_port), "--device-port", str(device_port),
        ], cwd=ROOT, stdout=output, stderr=output)
        try:
            deadline = time.monotonic() + 10
            while True:
                if process.poll() is not None:
                    raise RuntimeError("Isolated server exited during startup")
                try:
                    request(agent_url + "/")
                    break
                except (urllib.error.URLError, ConnectionError):
                    if time.monotonic() > deadline:
                        raise RuntimeError("Isolated server did not start")
                    time.sleep(0.1)
            contracts = json.loads(request(agent_url + "/api/tools"))["tools"]
            assert len(contracts) == 13
            info = tool("get_server_info")
            write("start_pairing", info["pairing"]["revision"])
            headers = {"ID": "02:00:00:00:00:01", "FW-Version": "simulator", "Width": "800", "Height": "480"}
            setup = json.loads(request(device_url + "/api/setup", headers=headers))
            assert setup["status"] == 200
            pending = tool("get_pairing_status")["pending_devices"]
            assert len(pending) == 1
            device = pending[0]
            active = write("confirm_device", device["revision"], device_id=device["device_id"], name="Simulated OG")
            receipt = write("publish_test_screen", active["revision"], device_id=device["device_id"], message="HELLO FROM CODEX")
            headers["Access-Token"] = setup["api_key"]
            display = json.loads(request(device_url + "/api/display", headers=headers))
            assert display["status"] == 0
            assert display["filename"] != setup["filename"]
            assert not display["update_firmware"] and not display["reset_firmware"]
            bitmap = request(display["image_url"])
            assert len(bitmap) == 48062 and bitmap[:2] == b"BM"
            assert struct.unpack_from("<ii", bitmap, 18) == (800, 480)
            assert struct.unpack_from("<H", bitmap, 28)[0] == 1
            assert hashlib.sha256(bitmap).hexdigest() == receipt["publication"]["sha256"]
            assert tool("get_write_receipt", {"request_id": receipt["request_id"]}) == receipt
            status = tool("get_device_status", {"device_id": device["device_id"]})
            assert status["last_image_response_id"] == receipt["publication"]["image_id"]
            assert not status["physical_display_verified"]
            write("disconnect_device", status["revision"], device_id=device["device_id"])
            try:
                request(device_url + "/api/display", headers=headers)
                raise AssertionError("Disconnected device still has access")
            except urllib.error.HTTPError as error:
                assert error.code == 401
            print("PASS: thirteen tools; pair, confirm, publish, fetch, hash, receipt, and revoke over HTTP.")
        finally:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
            output.seek(0)
            startup = output.read()
            # Only delete the UUID directory reported by this explicitly ephemeral child.
            for line in startup.splitlines():
                if line.startswith("Data: "):
                    directory = pathlib.Path(line[6:])
                    if directory.parent.resolve() == pathlib.Path(tempfile.gettempdir()).resolve() and directory.name.startswith("ai-trmnl-"):
                        uuid.UUID(directory.name[len("ai-trmnl-"):])
                        shutil.rmtree(directory)


if __name__ == "__main__":
    main()
