#!/usr/bin/env python3
"""Opt-in final packaged extension smoke check. Own IPv6 page, fresh profile, no tab actions."""
import argparse
import functools
import http.server
import json
import os
from pathlib import Path
import socket
import subprocess
import threading
import uuid
from test_chrome import CDP, rpc, wait_until

ROOT = Path(__file__).resolve().parents[1]

def run(app, runtime):
    if not app.is_relative_to(ROOT / '.local') or not runtime.is_relative_to(ROOT / '.local'):
        raise ValueError('Explicit test app and runtime inside .local required')
    directory = ROOT / '.local' / ('c-smoke-' + uuid.uuid4().hex[:8]); directory.mkdir(mode=0o700)
    profile = directory / 'profile'; profile.mkdir(mode=0o700)
    pages = directory / 'pages'; pages.mkdir()
    (pages / 'own.html').write_text('<!doctype html><meta charset="utf-8"><title>Own custom+app://localhost/private?synthetic</title><h1>Own C privacy test</h1>')
    class OwnServer(http.server.ThreadingHTTPServer):
        address_family = socket.AF_INET6
    class Quiet(http.server.SimpleHTTPRequestHandler):
        def log_message(self, *args): pass
    server = OwnServer(('::1', 0), functools.partial(Quiet, directory=str(pages)))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    env = dict(os.environ, ZAPAS_RUNTIME=str(runtime), ZAPAS_EPHEMERAL='1')
    report = {'checks': {}, 'status': 'RUNNING'}
    log = (directory / 'runtime.log').open('ab'); chrome = None
    try:
        installed = subprocess.run([str(app / 'Contents/MacOS/zapas'), 'native', 'install', '--user-data-dir', str(profile), '--apply', '--json'], env=env, capture_output=True, text=True)
        assert installed.returncode == 0, installed.stdout
        chrome = CDP(['/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', '--user-data-dir='+str(profile), '--no-first-run', '--no-default-browser-check', '--disable-sync', '--remote-debugging-pipe', '--enable-unsafe-extension-debugging', 'about:blank'], log)
        report['version'] = chrome.call('Browser.getVersion')
        loaded = chrome.call('Extensions.loadUnpacked', {'path': str(app / 'Contents/Resources/chrome-extension')})
        origin = 'chrome-extension://' + loaded['id'] + '/'
        url = f'http://[::1]:{server.server_port}/own.html'
        target = chrome.call('Target.createTarget', {'url': url})['targetId']; page = chrome.attach(target)
        wait_until(lambda: chrome.evaluate(page, 'location.href === '+json.dumps(url)+" && document.readyState === 'complete'"), bool)
        chrome.call('Target.detachFromTarget', {'sessionId': page})
        target = chrome.call('Target.createTarget', {'url': origin+'control.html'})['targetId']; control = chrome.attach(target)
        wait_until(lambda: chrome.evaluate(control, 'location.href === '+json.dumps(origin+'control.html')+" && typeof chrome.runtime?.sendMessage === 'function' && document.readyState === 'complete'"), bool)
        assert chrome.evaluate(control, "document.querySelectorAll('.card').length") == 2
        report['checks']['packaged_control_page_loaded'] = 'PASS'
        label = 'C privacy custom+app://localhost/private?synthetic'
        chrome.evaluate(control, 'chrome.runtime.sendMessage('+json.dumps({'type':'connect', 'label':label})+')')
        status = wait_until(lambda: chrome.evaluate(control, "chrome.runtime.sendMessage({type:'status'})"), lambda r: r.get('connected'))
        assert status['label'] == 'C privacy [адрес скрыт]'
        report['checks']['profile_label_address_redacted'] = 'PASS'
        def observed():
            profiles = rpc(runtime / 'gui.sock', {'operation':'tabsList'}).get('profiles', [])
            return next((p for p in profiles if p['id'] == status['profileID'] and any(t['title'] == 'Own [адрес скрыт]' for t in p['tabs'])), None)
        value = wait_until(observed, bool)
        tab = next(t for t in value['tabs'] if t['title'] == 'Own [адрес скрыт]')
        assert tab.get('domain') is None
        assert 'private?synthetic' not in json.dumps(value)
        report['checks']['ipv6_unknown_does_not_reject_profile'] = 'PASS'
        report['checks']['tab_title_address_redacted'] = 'PASS'
        result = subprocess.run([str(app / 'Contents/MacOS/zapas'), 'status', '--json'], env=env, capture_output=True, text=True)
        assert result.returncode == 0 and json.loads(result.stdout)['schemaVersion'] == 1
        report['checks']['same_gui_system_diagnostics_available'] = 'PASS'
        chrome.evaluate(control, "chrome.runtime.sendMessage({type:'disconnect'})")
        report['status'] = 'PASS'
        print(json.dumps({'status': report['status'], 'checks': report['checks'], 'evidence': str(directory)}, ensure_ascii=False))
    except Exception as error:
        report['status'] = 'FAIL'; report['error'] = repr(error); raise
    finally:
        if chrome:
            if chrome.process.poll() is None:
                chrome.call('Browser.close', timeout=5); chrome.process.wait(timeout=10)
            os.close(chrome.write_fd); os.close(chrome.read_fd)
        server.shutdown(); log.close()
        (directory / 'report.json').write_text(json.dumps(report, indent=2))

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True); parser.add_argument('--runtime', type=Path, required=True)
    parser.add_argument('--run', action='store_true'); args = parser.parse_args()
    if not args.run: parser.error('Explicit --run required')
    run(args.app.resolve(), args.runtime.resolve())
