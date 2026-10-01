#!/usr/bin/env python3
"""Exercise real broker/native-host processes without touching Chrome or simulators."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import socket
import struct
import subprocess
import tempfile
import time
import unittest
import uuid

ORIGIN = "chrome-extension://" + "a" * 32 + "/"

def message(operation, **fields):
    return {"version": 1, "requestID": str(uuid.uuid4()), "operation": operation, **fields}

def frame(value):
    data = json.dumps(value, ensure_ascii=False).encode()
    return struct.pack("<I", len(data)) + data

def read_exact(stream, length):
    data = b""
    while len(data) < length:
        part = stream.recv(length - len(data))
        if not part:
            raise AssertionError("Unexpected EOF")
        data += part
    return data

class IPCIntegration(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.folder = tempfile.TemporaryDirectory(prefix="ipc-", dir=LOCAL)
        cls.path = str(Path(cls.folder.name) / "broker.sock")
        cls.broker = subprocess.Popen([str(BIN / "zapas-probe"), "serve", "--socket", cls.path,
            "--origin", ORIGIN, "--seconds", "40"], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        for _ in range(100):
            if Path(cls.path).exists():
                break
            if cls.broker.poll() is not None:
                raise AssertionError(cls.broker.stderr.read().decode())
            time.sleep(.03)
        else:
            raise AssertionError("Broker did not bind")

    @classmethod
    def tearDownClass(cls):
        # Only the explicitly spawned test subprocess is terminated, never a user's process.
        if cls.broker.poll() is None:
            cls.broker.terminate()
        cls.broker.wait(timeout=5)
        cls.broker.stderr.close()
        cls.folder.cleanup()

    def rpc(self, request):
        with socket.socket(socket.AF_UNIX) as client:
            client.settimeout(6)
            client.connect(self.path)
            client.sendall(frame(request))
            length = struct.unpack("<I", read_exact(client, 4))[0]
            reply = json.loads(read_exact(client, length))
            self.assertEqual(reply["requestID"], request["requestID"])
            return reply

    def host(self, data, origin=ORIGIN):
        environment = {**os.environ, "ZAPAS_ALLOWED_ORIGIN": ORIGIN, "ZAPAS_SOCKET": self.path}
        return subprocess.run([str(BIN / "zapas-native-host"), origin], input=data, capture_output=True, env=environment, timeout=8)

    @staticmethod
    def replies(data):
        output = []
        while data:
            length = struct.unpack("<I", data[:4])[0]
            output.append(json.loads(data[4:4 + length]))
            data = data[4 + length:]
        return output

    def test_socket_and_directory_permissions(self):
        self.assertEqual(Path(self.folder.name).stat().st_mode & 0o777, 0o700)
        self.assertEqual(Path(self.path).stat().st_mode & 0o777, 0o600)
        self.assertEqual(Path(self.path).stat().st_uid, os.getuid())

    def test_serve_does_not_change_nonprivate_directory_permissions(self):
        with tempfile.TemporaryDirectory(prefix="nonprivate-", dir=LOCAL) as folder:
            os.chmod(folder, 0o755)
            result = subprocess.run([str(BIN / "zapas-probe"), "serve", "--socket", str(Path(folder) / "test.sock"),
                "--origin", ORIGIN, "--seconds", "1"], capture_output=True, timeout=5)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(json.loads(result.stderr)["code"], "ipc_directory")
            self.assertEqual(Path(folder).stat().st_mode & 0o777, 0o755)
            self.assertFalse((Path(folder) / "test.sock").exists())

    def test_multiple_clients_and_request_correlation(self):
        with ThreadPoolExecutor(max_workers=4) as pool:
            replies = list(pool.map(self.rpc, [message("listTabs") for _ in range(12)]))
        self.assertTrue(all(reply["ok"] for reply in replies))

    def test_bad_version_and_origin(self):
        request = message("hello", origin=ORIGIN, sessionID=str(uuid.uuid4()))
        request["version"] = 99
        self.assertEqual(self.rpc(request)["issue"]["code"], "protocol_version")
        request["version"] = 1; request["origin"] = "https://example.test"
        self.assertEqual(self.rpc(request)["issue"]["code"], "origin_denied")

    def test_malformed_and_truncated_frame_then_reconnect(self):
        for payload in [b"\x01\x00", struct.pack("<I", 2) + b"{", struct.pack("<I", 2) + b"{}", struct.pack("<I", 0xffffffff)]:
            with socket.socket(socket.AF_UNIX) as client:
                client.settimeout(6); client.connect(self.path); client.sendall(payload); client.shutdown(socket.SHUT_WR)
                response = read_exact(client, 4)
                length = struct.unpack("<I", response)[0]
                reply = json.loads(read_exact(client, length))
                self.assertFalse(reply["ok"])
        self.assertTrue(self.rpc(message("listTabs"))["ok"])

    def test_idle_socket_times_out_and_broker_recovers(self):
        with socket.socket(socket.AF_UNIX) as client:
            client.settimeout(6); client.connect(self.path)
            length = struct.unpack("<I", read_exact(client, 4))[0]
            self.assertFalse(json.loads(read_exact(client, length))["ok"])
        self.assertTrue(self.rpc(message("listTabs"))["ok"])

    def test_existing_socket_is_not_replaced(self):
        old_inode = Path(self.path).stat().st_ino
        other = subprocess.run([str(BIN / "zapas-probe"), "serve", "--socket", self.path, "--origin", ORIGIN,
            "--seconds", "1"], capture_output=True, timeout=5)
        self.assertNotEqual(other.returncode, 0)
        self.assertEqual(Path(self.path).stat().st_ino, old_inode)
        self.assertTrue(self.rpc(message("listTabs"))["ok"])

    def test_slow_partial_header_has_total_deadline(self):
        with socket.socket(socket.AF_UNIX) as client:
            client.settimeout(6); client.connect(self.path)
            started = time.monotonic()
            client.sendall(b"\x01")
            time.sleep(1.5)
            client.sendall(b"\x00")
            length = struct.unpack("<I", read_exact(client, 4))[0]
            self.assertFalse(json.loads(read_exact(client, length))["ok"])
            self.assertLess(time.monotonic() - started, 4.5)
        self.assertTrue(self.rpc(message("listTabs"))["ok"])

    def test_native_host_framing_multiple_messages_and_profile_identity(self):
        hello = message("hello")
        first = self.host(frame(hello) + frame(message("publishTabs", tabs=[])))
        self.assertEqual(first.returncode, 0, first.stderr.decode())
        replies = self.replies(first.stdout)
        self.assertEqual(len(replies), 2)
        self.assertEqual(replies[0]["requestID"], hello["requestID"])
        self.assertEqual(replies[0]["sessionID"], replies[1]["sessionID"])
        second = self.replies(self.host(frame(message("hello"))).stdout)
        self.assertNotEqual(replies[0]["sessionID"], second[0]["sessionID"])

    def test_native_host_denies_wrong_origin_and_bad_frames(self):
        wrong = self.host(frame(message("hello")), origin="chrome-extension://" + "b" * 32 + "/")
        self.assertNotEqual(wrong.returncode, 0)
        self.assertEqual(wrong.stdout, b"")
        self.assertEqual(json.loads(wrong.stderr)["code"], "origin_denied")
        for data in [struct.pack("<I", 0xffffffff), b"\x01\x00", struct.pack("<I", 2) + b"{"]:
            result = self.host(data)
            self.assertNotEqual(result.returncode, 0)

    def test_native_host_denies_action_enqueue_and_invalid_json(self):
        denied = self.host(frame(message("discardTestTab", sessionID=str(uuid.uuid4()), tabID=1)))
        self.assertEqual(self.replies(denied.stdout)[0]["issue"]["code"], "host_operation_denied")
        broken = self.host(struct.pack("<I", 2) + b"{}")
        self.assertFalse(self.replies(broken.stdout)[0]["ok"])

    def test_cli_rejects_socket_with_public_permissions(self):
        os.chmod(self.path, 0o644)
        try:
            result = subprocess.run([str(BIN / "zapas-probe"), "tabs", "--socket", self.path], capture_output=True, timeout=5)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(json.loads(result.stderr)["code"], "ipc_unavailable")
        finally:
            os.chmod(self.path, 0o600)

    def test_missing_broker_and_apply_flag_fail_without_action(self):
        missing = subprocess.run([str(BIN / "zapas-probe"), "tabs", "--socket", self.path + ".missing"], capture_output=True, timeout=5)
        self.assertNotEqual(missing.returncode, 0)
        refused = subprocess.run([str(BIN / "zapas-probe"), "discard-test-tab", "--socket", self.path,
            "--session", str(uuid.uuid4()), "--id", "1"], capture_output=True, timeout=5)
        self.assertEqual(json.loads(refused.stderr)["code"], "apply_required")

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--bin-dir", required=True)
    args = parser.parse_args()
    BIN = Path(args.bin_dir).resolve()
    LOCAL = Path(__file__).resolve().parents[1] / ".local"
    LOCAL.mkdir(exist_ok=True)
    unittest.main(argv=[__file__], verbosity=2)
