#!/usr/bin/env python3
"""Production host boundaries against a bounded local test peer; no Chrome required."""
import argparse
import json
import os
from pathlib import Path
import select
import socket
import struct
import subprocess
import tempfile
import threading
import unittest
import uuid

ORIGIN='chrome-extension://'+'a'*32+'/'
def frame(value):
    data=json.dumps(value).encode();return struct.pack('<I',len(data))+data

def exact(stream,n):
    data=b''
    while len(data)<n:
        part=stream.read(n-len(data)) if hasattr(stream,'read') else stream.recv(n-len(data))
        if not part: raise EOFError()
        data+=part
    return data

def read(stream): return json.loads(exact(stream,struct.unpack('<I',exact(stream,4))[0]))

class HostTests(unittest.TestCase):
    def setUp(self):
        self.directory=tempfile.TemporaryDirectory(prefix='c-ipc-',dir=ROOT/'.local')
        self.path=str(Path(self.directory.name)/'gui.sock')
        self.server=socket.socket(socket.AF_UNIX);self.server.bind(self.path);os.chmod(self.path,0o600);self.server.listen(8);self.server.settimeout(.1)
        self.requests=[];self.done=threading.Event()
        def peer():
            while not self.done.is_set():
                try: client,_=self.server.accept()
                except socket.timeout: continue
                with client:
                    request=read(client);self.requests.append(request)
                    client.sendall(frame({'version':1,'requestID':request['requestID'],'ok':True,'serviceID':str(uuid.uuid4())}))
        self.thread=threading.Thread(target=peer);self.thread.start()
        self.hosts=[]
    def tearDown(self):
        for p in self.hosts:
            if p.poll() is None: p.stdin.close();p.wait(timeout=5)
            p.stdout.close();p.stderr.close()
        self.done.set();self.thread.join(timeout=2);self.server.close();self.directory.cleanup()
    def host(self,origin=ORIGIN):
        p=subprocess.Popen([str(BINARY),origin],env=dict(os.environ,ZAPAS_PRODUCTION='1',ZAPAS_ALLOWED_ORIGIN=ORIGIN,ZAPAS_SOCKET=self.path),stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        self.hosts.append(p);return p
    def send(self,p,op,**fields):
        request={'version':1,'requestID':str(uuid.uuid4()),'operation':op,**fields};p.stdin.write(frame(request));p.stdin.flush()
        self.assertTrue(select.select([p.stdout],[],[],5)[0]);reply=read(p.stdout);self.assertEqual(reply['requestID'],request['requestID']);return reply
    def test_origin_and_extension_cannot_enqueue_actions(self):
        p=self.host('chrome-extension://'+'b'*32+'/');p.stdin.close();p.wait(timeout=5);self.assertEqual(p.returncode,1)
        p=self.host();r=self.send(p,'tabsApply',profileID=str(uuid.uuid4()),planID=str(uuid.uuid4()));self.assertFalse(r['ok']);self.assertEqual(len(self.requests),0)
    def test_extension_cannot_read_or_execute_development_operations(self):
        p=self.host()
        for operation in ('simulatorsList', 'debuggersList', 'simulatorsPreview', 'developmentApply'):
            reply=self.send(p,operation,profileID=str(uuid.uuid4()),planID=str(uuid.uuid4()),apply=True,developmentKind='simulatorShutdown')
            self.assertFalse(reply['ok']);self.assertEqual(reply['issue']['code'],'host_operation_denied')
        self.assertEqual(self.requests,[])
    def test_stamps_native_session_and_immutable_profile(self):
        p=self.host();profile=str(uuid.uuid4());forged=str(uuid.uuid4())
        hello=self.send(p,'chromeHello',profileID=profile,sessionID=forged,origin='forged')
        self.assertTrue(hello['ok']);self.assertNotEqual(hello['sessionID'],forged)
        self.assertEqual(self.requests[-1]['origin'],ORIGIN);self.assertEqual(self.requests[-1]['sessionID'],hello['sessionID'])
        self.assertFalse(self.send(p,'chromePublish',profileID=str(uuid.uuid4()),tabs=[])['ok'])
        self.assertTrue(self.send(p,'chromePublish',profileID=profile,tabs=[])['ok'])
    def test_profiles_have_distinct_host_sessions_and_eof_disconnect(self):
        profiles=[str(uuid.uuid4()),str(uuid.uuid4())];hosts=[self.host(),self.host()]
        replies=[self.send(p,'chromeHello',profileID=id) for p,id in zip(hosts,profiles)]
        self.assertNotEqual(replies[0]['sessionID'],replies[1]['sessionID'])
        hosts[0].stdin.close();hosts[0].wait(timeout=5)
        self.assertTrue(any(r['operation']=='chromeDisconnect' and r['profileID']==profiles[0] for r in self.requests))
    def test_invalid_version_uuid_and_broker_unavailable_are_errors(self):
        p=self.host();self.assertFalse(self.send(p,'chromeHello',profileID='invalid')['ok'])
        self.assertFalse(self.send(p,'chromeHello',profileID=str(uuid.uuid4()),version=2)['ok'])
        self.assertFalse(self.send(p,'chromeHello',profileID=str(uuid.uuid4()),requestID='not-a-uuid')['ok'])
        self.done.set();self.thread.join(timeout=2);self.server.close()
        # A closed peer cannot produce a fake successful handshake.
        r=self.send(p,'chromeHello',profileID=str(uuid.uuid4()));self.assertFalse(r['ok']);self.assertEqual(r['issue']['code'],'ipc_unavailable')

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--binary',type=Path,required=True);args=parser.parse_args()
    BINARY=args.binary.resolve();ROOT=Path(__file__).resolve().parents[1]
    unittest.main(argv=['test_ipc_c.py'],verbosity=2)
