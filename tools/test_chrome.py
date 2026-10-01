#!/usr/bin/env python3
"""Opt-in live Chrome Stable test using a private CDP pipe and a dedicated disposable profile.

No listening debug port, working profile, remote sites or per-tab memory estimation.
The unsafe-extension-debugging flag is used only to load our own unpacked test extension.
"""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import select
import socket
import struct
import subprocess
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
LOCAL = ROOT / ".local"

class CDP:
    def __init__(self, command, log):
        incoming_read, self.write_fd = os.pipe()
        self.read_fd, outgoing_write = os.pipe()
        # Chrome's private pipe protocol expects inherited descriptors 3 and 4.
        def child_descriptors():
            os.dup2(incoming_read, 3)
            os.dup2(outgoing_write, 4)
        keep = tuple(set((incoming_read, outgoing_write, 3, 4)))
        self.process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=log, stderr=log,
            pass_fds=keep, preexec_fn=child_descriptors)
        os.close(incoming_read); os.close(outgoing_write)
        self.sequence = 0; self.buffer = b""; self.messages = []

    def call(self, method, params=None, session=None, timeout=10):
        self.sequence += 1
        command = {"id": self.sequence, "method": method, "params": params or {}}
        if session:
            command["sessionId"] = session
        encoded = json.dumps(command).encode() + b"\0"
        offset = 0
        while offset < len(encoded):
            offset += os.write(self.write_fd, encoded[offset:])
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            for index, reply in enumerate(self.messages):
                if reply.get("id") == self.sequence:
                    self.messages.pop(index)
                    if "error" in reply:
                        raise RuntimeError(f"{method}: {reply['error']}")
                    return reply.get("result", {})
            ready, _, _ = select.select([self.read_fd], [], [], max(0, deadline - time.monotonic()))
            if not ready:
                break
            data = os.read(self.read_fd, 65536)
            if not data:
                raise RuntimeError(f"Chrome pipe closed during {method}")
            self.buffer += data
            if len(self.buffer) > 8 * 1024 * 1024:
                raise RuntimeError("Unexpectedly large CDP message")
            while b"\0" in self.buffer:
                message, self.buffer = self.buffer.split(b"\0", 1)
                if message:
                    value = json.loads(message)
                    if "id" in value:
                        self.messages.append(value)
        raise TimeoutError(method)

    def evaluate(self, session, expression, gesture=False):
        result = self.call("Runtime.evaluate", {"expression": expression, "awaitPromise": True,
            "returnByValue": True, "userGesture": gesture}, session=session)
        if "exceptionDetails" in result:
            raise RuntimeError(str(result["exceptionDetails"]))
        return result.get("result", {}).get("value")

    def attach(self, target):
        return self.call("Target.attachToTarget", {"targetId": target, "flatten": True})["sessionId"]

    def close(self):
        if self.process.poll() is None:
            try:
                self.call("Browser.close", timeout=3)
            except (RuntimeError, TimeoutError, BrokenPipeError):
                pass
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                # Only this fresh subprocess, never an existing user's Chrome.
                self.process.terminate(); self.process.wait(timeout=5)
        os.close(self.write_fd); os.close(self.read_fd)

def rpc(path, request):
    request = {"version": 1, "requestID": str(uuid.uuid4()), **request}
    data = json.dumps(request).encode()
    def read(client, count):
        result = b""
        while len(result) < count:
            value = client.recv(count - len(result))
            if not value:
                raise RuntimeError("IPC closed")
            result += value
        return result
    with socket.socket(socket.AF_UNIX) as client:
        client.settimeout(6); client.connect(str(path))
        client.sendall(struct.pack("<I", len(data)) + data)
        length = struct.unpack("<I", read(client, 4))[0]
        result = json.loads(read(client, length))
    if result.get("requestID") != request["requestID"]:
        raise RuntimeError("IPC correlation mismatch")
    return result

def wait_until(read, predicate, timeout=15):
    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        last = read()
        if predicate(last):
            return last
        time.sleep(.3)
    raise RuntimeError(f"Timed out waiting for state: {last}")

def run(binary_dir, chrome_path):
    directory = LOCAL / "chrome-automated"
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    directory.chmod(0o700)
    # A fresh profile prevents V8/service-worker caches from hiding changes to unpacked source.
    profile = directory / ("profile-" + uuid.uuid4().hex[:8])
    profile.mkdir(mode=0o700, exist_ok=True)
    path = directory / "broker.sock"
    if path.exists():
        raise RuntimeError("Automated test socket already exists; do not replace another run")
    manifest = json.loads((ROOT / "chrome-extension/manifest.json").read_text())
    digest = hashlib.sha256(base64.b64decode(manifest["key"])).hexdigest()[:32]
    extension_id = "".join(chr(97 + int(char, 16)) for char in digest)
    origin = f"chrome-extension://{extension_id}/"
    control_url = origin + "control.html"
    import shlex
    wrapper = directory / "native-host"
    wrapper.write_text("#!/bin/sh\n" + f"export ZAPAS_ALLOWED_ORIGIN={shlex.quote(origin)}\n" +
        f"export ZAPAS_SOCKET={shlex.quote(str(path))}\n" + f"exec {shlex.quote(str(binary_dir / 'zapas-native-host'))} \"$@\"\n")
    wrapper.chmod(0o700)
    hosts = profile / "NativeMessagingHosts"
    hosts.mkdir(mode=0o700, exist_ok=True)
    native_manifest = hosts / "com.zapas.stage_a.json"
    native_manifest.write_text(json.dumps({"name": "com.zapas.stage_a", "description": "Zapas automated test host",
        "path": str(wrapper), "type": "stdio", "allowed_origins": [origin]}) + "\n")
    native_manifest.chmod(0o600)
    result = {"status": "RUNNING", "checks": {}, "versions": {}, "note": "Only isolated fixture tabs; no visible-launch claim"}
    report = LOCAL / "results/chrome-smoke.json"
    report.parent.mkdir(exist_ok=True)
    broker = None; cdp = None
    log = (LOCAL / "results/chrome-automated.log").open("ab")
    try:
        broker = subprocess.Popen([str(binary_dir / "zapas-probe"), "serve", "--socket", str(path),
            "--origin", origin, "--seconds", "300"], stdout=log, stderr=log)
        wait_until(lambda: path.exists(), bool)
        command = [str(chrome_path), "--user-data-dir=" + str(profile), "--no-first-run", "--no-default-browser-check",
            "--disable-sync", "--remote-debugging-pipe", "--enable-unsafe-extension-debugging", "about:blank"]
        cdp = CDP(command, log)
        result["versions"] = cdp.call("Browser.getVersion")
        loaded = cdp.call("Extensions.loadUnpacked", {"path": str(ROOT / "chrome-extension")})
        assert loaded["id"] == extension_id, loaded
        result["checks"]["load_unpacked_stable"] = "PASS"
        target = cdp.call("Target.createTarget", {"url": control_url})["targetId"]
        control = cdp.attach(target)
        wait_until(lambda: cdp.evaluate(control, "document.readyState"), lambda state: state == "complete")
        def send(kind, session=control):
            return cdp.evaluate(session, f"chrome.runtime.sendMessage({json.dumps({'type': kind})})")
        send("connect")
        state = wait_until(lambda: send("status"), lambda value: value and value.get("connected"))
        profile_session = state["sessionID"]
        result["checks"]["native_messaging_roundtrip"] = "PASS"
        fixture = send("create-fixture")["tabID"]
        control_tab = cdp.evaluate(control, "chrome.tabs.getCurrent()")["id"]
        def tab_from_broker(tab_id=fixture):
            reply = rpc(path, {"operation": "listTabs"})
            group = next((s for s in reply.get("sessions", []) if s["id"] == profile_session), None)
            return next((t for t in group["tabs"] if t["id"] == tab_id), None) if group else None
        def update(tab_id, properties):
            return cdp.evaluate(control, f"chrome.tabs.update({tab_id}, {json.dumps(properties)})")
        def refuse(tab_id, reason):
            reply = rpc(path, {"operation": "discardTestTab", "sessionID": profile_session, "tabID": tab_id})
            assert not reply["ok"] and reply["issue"]["message"] == reason, reply
        wait_until(tab_from_broker, lambda value: value and value["isTestFixture"])
        update(fixture, {"pinned": True})
        wait_until(tab_from_broker, lambda value: value and value["pinned"])
        refuse(fixture, "pinned"); update(fixture, {"pinned": False})
        result["checks"]["pinned_protection"] = "PASS"
        update(fixture, {"active": True})
        wait_until(tab_from_broker, lambda value: value and value["active"])
        refuse(fixture, "active")
        result["checks"]["active_protection"] = "PASS"
        update(control_tab, {"active": True})
        wait_until(tab_from_broker, lambda value: value and not value["active"])
        refuse(fixture, "recently_active")
        result["checks"]["recent_activity_protection"] = "PASS"
        fixture_url = cdp.evaluate(control, f"chrome.tabs.get({fixture})")["url"]
        fixture_target = next(t["targetId"] for t in cdp.call("Target.getTargets")["targetInfos"] if t["url"] == fixture_url)
        fixture_session = cdp.attach(fixture_target)
        initial_load = cdp.evaluate(fixture_session, "globalThis.zapasFixtureLoadID")
        assert initial_load
        cdp.evaluate(fixture_session, "document.getElementById('unsaved').value = 'Zapas test state'")
        cdp.evaluate(fixture_session, "document.getElementById('audio').click()", gesture=True)
        wait_until(tab_from_broker, lambda value: value and value["audible"])
        refuse(fixture, "audible")
        cdp.evaluate(fixture_session, "document.getElementById('stop').click()", gesture=True)
        result["checks"]["audio_protection"] = "PASS"
        # Second window: active fixtures in both windows must be protected.
        second_window = cdp.evaluate(control, f"chrome.windows.create({{url: {json.dumps(control_url)}}})")
        second_tab = second_window["tabs"][0]["id"]
        second_target = next(t["targetId"] for t in cdp.call("Target.getTargets")["targetInfos"]
            if t["url"] == control_url and t["targetId"] != target)
        second_control = cdp.attach(second_target)
        wait_until(lambda: cdp.evaluate(second_control, "document.readyState"), lambda state: state == "complete")
        second_fixture = send("create-fixture", second_control)["tabID"]
        update(fixture, {"active": True}); update(second_fixture, {"active": True})
        wait_until(lambda: tab_from_broker(fixture), lambda value: value and value["active"])
        wait_until(lambda: tab_from_broker(second_fixture), lambda value: value and value["active"])
        refuse(fixture, "active"); refuse(second_fixture, "active")
        result["checks"]["active_tabs_each_window"] = "PASS"
        update(control_tab, {"active": True}); update(second_tab, {"active": True})
        # An attached DevTools target can itself prevent discarding; detach the fixture before the action.
        cdp.call("Target.detachFromTarget", {"sessionId": fixture_session})
        print("Chrome bridge and protections PASS; waiting for the 60-second research cooldown", flush=True)
        wait_until(tab_from_broker, lambda value: value and not value["active"] and not value["audible"] and
            time.time() * 1000 - value["lastAccessedMilliseconds"] >= 61_000, timeout=75)
        queued = rpc(path, {"operation": "discardTestTab", "sessionID": profile_session, "tabID": fixture})
        assert queued["ok"], queued
        action_id = queued["action"]["id"]
        outcome = wait_until(lambda: rpc(path, {"operation": "getActionResult", "actionID": action_id}), lambda value: "result" in value)
        assert outcome["result"]["status"] == "confirmed" and outcome["result"]["discarded"], {"outcome": outcome, "actualTab": tab_from_broker()}
        resulting_fixture = outcome["result"].get("resultingTabID", fixture)
        wait_until(lambda: tab_from_broker(resulting_fixture), lambda value: value and value["discarded"])
        result["checks"]["discard_confirmed"] = "PASS"
        result["discardResult"] = outcome["result"]
        # Selecting a tab in a background window alone does not make its contents visible.
        restored_tab = cdp.evaluate(control, f"chrome.tabs.get({resulting_fixture})")
        cdp.evaluate(control, f"chrome.windows.update({restored_tab['windowId']}, {{focused: true}})")
        update(resulting_fixture, {"active": True})
        wait_until(lambda: tab_from_broker(resulting_fixture), lambda value: value and not value["discarded"])
        fixture_target = next(t["targetId"] for t in cdp.call("Target.getTargets")["targetInfos"] if t["url"] == fixture_url)
        fixture_session = cdp.attach(fixture_target)
        wait_until(lambda: cdp.evaluate(fixture_session, "document.readyState"), lambda state: state == "complete")
        restored_load = cdp.evaluate(fixture_session, "globalThis.zapasFixtureLoadID")
        assert restored_load and restored_load != initial_load
        result["checks"]["reload_on_activation"] = "PASS"
        result["stateObservation"] = {
            "javascriptHeapRecreated": True,
            "formFieldRestoredByChrome": cdp.evaluate(fixture_session, "document.getElementById('unsaved').value") == "Zapas test state",
            "note": "Browser form restoration is not a guarantee of arbitrary application state preservation"
        }
        result["checks"]["page_state_observed"] = "PASS"
        send("disconnect")
        wait_until(lambda: send("status"), lambda value: not value["connected"])
        result["checks"]["disconnect"] = "PASS"
        send("connect")
        renewed = wait_until(lambda: send("status"), lambda value: value and value.get("connected"))
        assert renewed["sessionID"] != profile_session
        result["checks"]["reconnect_new_identity"] = "PASS"
        send("disconnect")
        result["status"] = "PASS"
        print("Chrome Stable live smoke test PASS", flush=True)
    except Exception as error:
        result["status"] = "FAIL"; result["error"] = repr(error)
        raise
    finally:
        report.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
        if cdp:
            cdp.close()
        if broker:
            if broker.poll() is None:
                broker.terminate()
            broker.wait(timeout=5)
        # Only the socket created by this run, in its private dedicated directory.
        if path.exists():
            path.unlink()
        log.close()

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--bin-dir", required=True)
    parser.add_argument("--chrome", default="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
    parser.add_argument("--run", action="store_true", help="Explicitly start isolated live browser tests")
    args = parser.parse_args()
    if not args.run:
        parser.error("Supply --run to explicitly start the isolated Chrome test")
    run(Path(args.bin_dir).resolve(), Path(args.chrome).resolve())
