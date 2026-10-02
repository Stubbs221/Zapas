#!/usr/bin/env python3
"""D CLI wire/argument contract against an isolated peer; never touches a simulator/debugger."""
import argparse
import json
import os
from pathlib import Path
import socket
import struct
import subprocess
import tempfile
import threading
import unittest
import uuid


def exact(stream, count):
    value = b''
    while len(value) < count:
        part = stream.recv(count - len(value))
        if not part:
            raise EOFError()
        value += part
    return value


class DevelopmentCLI(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix='d-cli-', dir=ROOT / '.local')
        self.runtime = Path(self.directory.name)
        self.server = socket.socket(socket.AF_UNIX)
        self.server.bind(str(self.runtime / 'gui.sock'))
        os.chmod(self.runtime / 'gui.sock', 0o600)
        self.server.listen(4)
        self.server.settimeout(.1)
        self.requests = []
        self.stop = threading.Event()
        def peer():
            while not self.stop.is_set():
                try:
                    client, _ = self.server.accept()
                except socket.timeout:
                    continue
                with client:
                    request = json.loads(exact(client, struct.unpack('<I', exact(client, 4))[0]))
                    self.requests.append(request)
                    reply = dict(version=1, requestID=request['requestID'], ok=True)
                    if request['operation'] == 'simulatorsList':
                        reply['simulators'] = dict(measuredAt='2026-10-02T00:00:00Z', totalDeviceCount=0, devices=[], processes=[], unassignedProcesses=[], processFailures=[])
                    elif request['operation'] == 'debuggersList':
                        reply['debuggers'] = dict(measuredAt='2026-10-02T00:00:00Z', debuggers=[], failures=[], qualification='not_run_user_deferred')
                    else:
                        reply.update(ok=False, issue=dict(code='debugger_activity_unproven', message='Fixture refusal'))
                    payload = json.dumps(reply).encode()
                    client.sendall(struct.pack('<I', len(payload)) + payload)
        self.thread = threading.Thread(target=peer)
        self.thread.start()
    def tearDown(self):
        self.stop.set()
        self.thread.join(timeout=2)
        self.server.close()
        self.directory.cleanup()
    def cli(self, *arguments):
        p = subprocess.run([str(BINARY), *arguments], env=dict(os.environ, ZAPAS_RUNTIME=str(self.runtime)), capture_output=True, text=True, timeout=5)
        self.assertEqual(p.stderr, '')
        self.assertEqual(len(p.stdout.splitlines()), 1)
        return p.returncode, json.loads(p.stdout)
    def test_lists_are_additive_v1_and_use_gui(self):
        for group in ('simulators', 'debuggers'):
            code, value = self.cli(group, 'list', '--json')
            self.assertEqual(code, 0)
            self.assertEqual(value['schemaVersion'], 1)
            self.assertEqual(value['command'], group + ' list')
            self.assertEqual(value['status'], 'available')
            self.assertEqual(self.requests[-1]['operation'], group + 'List')
    def test_apply_requires_explicit_flag_and_uuid_without_delivery(self):
        for group in ('simulators', 'debuggers'):
            for arguments in (('apply', '--plan', str(uuid.uuid4()), '--json'), ('apply', '--plan', 'all', '--apply', '--json'), ('shutdown', '--apply', '--json')):
                code, value = self.cli(group, *arguments)
                self.assertEqual(code, 2)
                self.assertEqual(value['data'], None)
                self.assertEqual(value['errors'][0]['code'], 'invalid_arguments')
        self.assertEqual(self.requests, [])
    def test_debugger_selection_transmits_only_start_identity(self):
        identity = dict(pid=123, startSeconds=456, startMicroseconds=789)
        code, value = self.cli('debuggers', 'preview', '--selection', json.dumps(identity), '--json')
        self.assertEqual(code, 1)
        self.assertEqual(value['errors'][0]['code'], 'debugger_activity_unproven')
        self.assertEqual(self.requests[0]['debuggerIdentity'], identity)
        self.assertNotIn('qualified', self.requests[0])
    def test_kind_is_bound_to_apply_and_result(self):
        for group, kind in (('simulators', 'simulatorShutdown'), ('debuggers', 'debuggerTerminate')):
            for verb in ('apply', 'result'):
                arguments = [group, verb, '--plan', str(uuid.uuid4()), '--json']
                if verb == 'apply': arguments.append('--apply')
                self.cli(*arguments)
                request = self.requests[-1]
                self.assertEqual(request['developmentKind'], kind)
                self.assertEqual(request['apply'], verb == 'apply')
    def test_invalid_selection_repeated_flags_and_shell_options_are_rejected(self):
        for arguments in (('simulators', 'preview', '--selection', '[]', '--json'), ('debuggers', 'preview', '--selection', '{}', '--json'), ('simulators', 'list', '--json', '--json'), ('simulators', 'list', '--command', 'shutdown all', '--json')):
            code, _ = self.cli(*arguments)
            self.assertEqual(code, 2)
        self.assertEqual(self.requests, [])


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    args = parser.parse_args()
    ROOT = Path(__file__).resolve().parents[1]
    BINARY = args.binary.resolve()
    unittest.main(argv=['test_cli_d.py'], verbosity=2)
