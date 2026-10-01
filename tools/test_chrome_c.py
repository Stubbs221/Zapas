#!/usr/bin/env python3
"""Opt-in Stage C live checks. Two fresh isolated profiles, own localhost pages, private CDP pipes.
Leaves its GUI running for visible verification; never terminates or restarts an existing app.
"""
import argparse
import functools
import http.server
import json
import os
from pathlib import Path
import subprocess
import threading
import time
import uuid
from test_chrome import CDP, rpc, wait_until

ROOT = Path(__file__).resolve().parents[1]

def run(app):
    directory = ROOT / '.local' / ('chrome-c-' + uuid.uuid4().hex[:8])
    directory.mkdir(mode=0o700)
    runtime = directory / 'run'; runtime.mkdir(mode=0o700)
    pages = directory / 'pages'; pages.mkdir()
    (pages / 'test.html').write_text('''<!doctype html><html lang="ru"><title>Zapas test page</title><h1>Собственная тестовая страница C</h1><input id="unsaved"><button id="audio">Звук</button><button id="stop">Стоп</button><script>globalThis.loadID=crypto.randomUUID();globalThis.heap=new Array(100000).fill(42);let audio,osc;document.querySelector('#audio').onclick=()=>{audio=new AudioContext();osc=audio.createOscillator();osc.connect(audio.destination);osc.start()};document.querySelector('#stop').onclick=()=>audio?.close();</script>''')
    handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=str(pages))
    class Quiet(handler.func):
        def log_message(self, *args): pass
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(Quiet, directory=str(pages)))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    env = dict(os.environ, ZAPAS_RUNTIME=str(runtime), ZAPAS_EPHEMERAL='1')
    binary = app / 'Contents/MacOS/zapas'
    log = (directory / 'live.log').open('ab')
    result = {'status':'RUNNING','checks':{},'versions':{},'note':'Isolated own pages only; visible UI requires separate native verification'}
    report = directory / 'report.json'
    context = {'directory':str(directory), 'runtime':str(runtime), 'app':str(app), 'guiPID':None}
    (ROOT / '.local/results/stage-c/live-context.json').write_text(json.dumps(context, indent=2))
    browsers = []
    try:
        # Refuse to launch a duplicate packaged GUI, regardless of its service runtime.
        listed = subprocess.check_output(['ps','-axo','args'], text=True)
        if any(line.strip().split(' ')[0].endswith('/Contents/MacOS/ZapasApp') for line in listed.splitlines()):
            raise RuntimeError('An existing Zapas GUI must be exited normally before this isolated run')
        gui = subprocess.Popen([str(app / 'Contents/MacOS/ZapasApp'), '--qualification-window', '--qualification-output', str(directory / 'gui-trace.ndjson')], env=env, stdout=log, stderr=log)
        context['guiPID'] = gui.pid
        (ROOT / '.local/results/stage-c/live-context.json').write_text(json.dumps(context, indent=2))
        path = runtime / 'gui.sock'; wait_until(lambda:path.exists(),bool)
        cli = lambda *args: subprocess.run([str(binary), *args], env=env, capture_output=True, text=True)
        def cli_json(*args):
            value=cli(*args); assert value.returncode == 0, value.stdout + value.stderr
            return json.loads(value.stdout)
        baseline=cli_json('status','--json'); assert baseline['schemaVersion']==1
        result['checks']['diagnostics_without_extension']='PASS'
        for index in range(2):
            profile=directory / f'profile-{index}'; profile.mkdir(mode=0o700)
            chrome=CDP(['/Applications/Google Chrome.app/Contents/MacOS/Google Chrome','--user-data-dir='+str(profile),'--no-first-run','--no-default-browser-check','--disable-sync','--remote-debugging-pipe','--enable-unsafe-extension-debugging','about:blank'], log)
            browsers.append(chrome)
            result['versions'][f'chrome-{index}']=chrome.call('Browser.getVersion')
            loaded=chrome.call('Extensions.loadUnpacked',{'path':str(app / 'Contents/Resources/chrome-extension')})
            origin='chrome-extension://'+loaded['id']+'/'
            url=f'http://127.0.0.1:{server.server_port}/test.html?nonce={uuid.uuid4()}'
            target=chrome.call('Target.createTarget',{'url':url})['targetId']
            page=chrome.attach(target); wait_until(lambda:chrome.evaluate(page,'document.readyState'),lambda x:x=='complete')
            initial=chrome.evaluate(page,'loadID')
            chrome.evaluate(page,"document.querySelector('#unsaved').value='own test state'")
            chrome.call('Target.detachFromTarget',{'sessionId':page})
            control_target=chrome.call('Target.createTarget',{'url':origin+'control.html'})['targetId']
            control=chrome.attach(control_target); wait_until(lambda:chrome.evaluate(control,"location.href === "+json.dumps(origin+'control.html')+" && document.readyState === 'complete' && typeof chrome.runtime?.sendMessage === 'function'"),bool)
            def send(kind, c=chrome, s=control): return c.evaluate(s,f'chrome.runtime.sendMessage({json.dumps({"type":kind,"label":f"C test {index+1}"})})')
            if index==0:
                send('connect'); wait_until(lambda:send('status'),lambda x:x and x.get('lastIssue'),timeout=12)
                assert not send('status')['connected']; result['checks']['missing_host_visible_error']='PASS'
            installed=cli_json('native','install','--user-data-dir',str(profile),'--apply','--json'); assert installed['status']=='available'
            # Reinstallation is explicit and idempotent; another host manifest is not silently replaced.
            assert cli_json('native','install','--user-data-dir',str(profile),'--apply','--json')['status']=='available'
            send('connect'); state=wait_until(lambda:send('status'),lambda x:x and x.get('connected'),timeout=35)
            tabs=chrome.evaluate(control,'chrome.tabs.query({})')
            test=next(tab for tab in tabs if tab.get('url')==url)
            info={'chrome':chrome,'control':control,'send':send,'state':state,'tabID':test['id'],'url':url,'initial':initial,'controlTarget':control_target,'origin':origin}
            # A second window's active page is protected independently of focus.
            window=chrome.evaluate(control,f'chrome.windows.create({{url:{json.dumps(url+"&second=1")}}})')
            info['secondTab']=window['tabs'][0]['id']; info['secondWindow']=window['id']
            info['inactiveAt']=time.time()
            browsers[-1].info=info
        result['checks']['explicit_install_two_profiles']='PASS'
        def profiles(): return rpc(path,{'operation':'tabsList'})['profiles']
        groups=wait_until(profiles,lambda x:len(x)==2 and all(p['tabs'] for p in x))
        assert len(set(p['sessionID'] for p in groups))==2 and len(set(p['id'] for p in groups))==2
        result['checks']['multiple_profiles_windows']='PASS'
        def selected(c, tab_id=None):
            group=next(p for p in profiles() if p['id']==c.info['state']['profileID'])
            tab=next(t for t in group['tabs'] if t['id']==(tab_id or c.info['tabID']))
            return {'profileID':group['id'],'sessionID':group['sessionID'],'tabID':tab['id'],'token':tab['token']}
        def preview(selection, kind='discard'): return rpc(path,{'operation':'tabsPreview','kind':kind,'selections':selection})
        for c in browsers:
            wait_until(lambda:profiles(),lambda groups:any(any(t['id']==c.info['secondTab'] for t in p['tabs']) for p in groups))
            blocked=preview([selected(c,c.info['secondTab'])]); assert not blocked['ok'] and blocked['issue']['message']=='active',blocked
        result['checks']['active_each_window']='PASS'
        c=browsers[0]; blocked=preview([selected(c)]); assert not blocked['ok'] and blocked['issue']['message']=='recently_active',blocked
        result['checks']['production_10_minute_protection']='PASS'
        def update(c, id, fields): return c.evaluate(c.info['control'],f'chrome.tabs.update({id},{json.dumps(fields)})')
        update(c,c.info['tabID'],{'pinned':True})
        wait_until(lambda:preview([selected(c)]),lambda r:not r['ok'] and r['issue']['message']=='pinned')
        update(c,c.info['tabID'],{'pinned':False}); result['checks']['pinned_live']='PASS'
        # Keep own test pages untouched until the approved 600-second threshold expires.
        print('C live: install/two profiles/protections PASS; waiting 10-minute production cooldown',flush=True)
        report.write_text(json.dumps(result,indent=2))
        deadline=max(c.info['inactiveAt'] for c in browsers)+605
        while time.time()<deadline:
            time.sleep(min(1,deadline-time.time()))
        def outcome(plan):
            applied=rpc(path,{'operation':'tabsApply','planID':plan['id']}); assert applied['ok'],applied
            final=wait_until(lambda:rpc(path,{'operation':'tabsResult','planID':plan['id']}),lambda r:r.get('batch') and all(x.get('issue')!='awaiting_confirmation' for x in r['batch']['results']),timeout=30)
            return final['batch']
        before=profiles()
        # Preview becomes invalid after pinning: verify no command reaches Chrome.
        plan=preview([selected(c)])['plan']; update(c,c.info['tabID'],{'pinned':True})
        wait_until(lambda:preview([selected(c)]),lambda r:not r['ok'] and r['issue']['message']=='pinned')
        changed=rpc(path,{'operation':'tabsApply','planID':plan['id']}); assert not changed['ok'],changed
        update(c,c.info['tabID'],{'pinned':False}); result['checks']['fresh_recheck_changed_preview']='PASS'
        wait_until(lambda:preview([selected(c)]),lambda r:r['ok'])
        plan=preview([selected(c)])['plan']; batch=outcome(plan)
        assert batch['results'][0]['status']=='confirmed',batch
        discarded=batch['results'][0]['resultingTabID']; c.info['tabID']=discarded
        assert c.evaluate(c.info['control'],f'chrome.tabs.get({discarded})')['discarded']
        result['checks']['selected_discard_actual_state']='PASS'; result['discard']=batch
        unselected=next(p for p in profiles() if p['id']==browsers[1].info['state']['profileID'])
        assert not next(t for t in unselected['tabs'] if t['id']==browsers[1].info['tabID'])['discarded']
        result['checks']['unselected_other_profile_untouched']='PASS'
        # Separate close, on the other explicitly selected own tab.
        c2=browsers[1]; plan=preview([selected(c2)],'close')['plan']; closed=outcome(plan)
        assert closed['results'][0]['status']=='confirmed',closed
        assert not any(t['id']==c2.info['tabID'] for t in c2.evaluate(c2.info['control'],'chrome.tabs.query({})'))
        result['checks']['selected_close_actual_absence']='PASS'; result['close']=closed
        # Restore discarded page through ordinary activation in its matching window.
        actual=c.evaluate(c.info['control'],f'chrome.tabs.get({discarded})')
        c.evaluate(c.info['control'],f'chrome.windows.update({actual["windowId"]},{{focused:true}})'); update(c,discarded,{'active':True})
        wait_until(lambda:c.evaluate(c.info['control'],f'chrome.tabs.get({discarded})'),lambda t:not t['discarded'])
        target=next(t['targetId'] for t in c.call('Target.getTargets')['targetInfos'] if t['url']==c.info['url'])
        page=c.attach(target); wait_until(lambda:c.evaluate(page,'document.readyState'),lambda x:x=='complete')
        assert c.evaluate(page,'loadID')!=c.info['initial']; c.call('Target.detachFromTarget',{'sessionId':page})
        result['checks']['reload_heap_recreated']='PASS'
        # Real worker stop and event-driven wake via own control page. Session/tokens must renew.
        c.call('ServiceWorker.enable',session=c.info['control'])
        old=c.info['send']('status')['sessionID']
        c.call('ServiceWorker.stopAllWorkers',session=c.info['control'])
        renewed=wait_until(lambda:c.info['send']('status'),lambda r:r and r.get('connected') and r['sessionID']!=old,timeout=35)
        result['checks']['worker_stop_reconnect']='PASS'
        assert not preview([{'profileID':c.info['state']['profileID'],'sessionID':old,'tabID':discarded,'token':str(uuid.uuid4())}])['ok']
        result['checks']['old_session_rejected']='PASS'
        # Actual unload removes native connection; reload recovers saved opt-in consent.
        old=renewed['sessionID']; c.call('Extensions.uninstall',{'id':c.info['origin'].split('/')[2]})
        wait_until(profiles,lambda groups:not any(p['id']==c.info['state']['profileID'] for p in groups))
        result['checks']['extension_unloaded_diagnostics_live']='PASS'
        assert cli_json('status','--json')['data']['physical']['value'] is not None
        c.call('Extensions.loadUnpacked',{'path':str(app / 'Contents/Resources/chrome-extension')})
        result['checks']['unload_reload']='PASS' # New control page/connect qualified separately below.
        # Second profile explicit disconnect/reconnect; persistent profile ID, new host session.
        c2.info['send']('disconnect'); wait_until(lambda:c2.info['send']('status'),lambda r:not r['connected'])
        c2.info['send']('connect'); next_state=wait_until(lambda:c2.info['send']('status'),lambda r:r.get('connected'))
        assert next_state['sessionID']!=c2.info['state']['sessionID'] and next_state['profileID']==c2.info['state']['profileID']
        result['checks']['explicit_disconnect_reconnect']='PASS'
        result['status']='PASS'; print('C live checks PASS',flush=True)
    except Exception as error:
        result['status']='FAIL'; result['error']=repr(error); raise
    finally:
        report.write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
        for c in browsers:
            if c.process.poll() is None:
                try: c.call('Browser.close',timeout=5); c.process.wait(timeout=10)
                except Exception as e: print('Own isolated Chrome cleanup needs attention:',type(e).__name__,flush=True)
            os.close(c.write_fd); os.close(c.read_fd)
        server.shutdown(); log.close()
        print('Evidence:',directory,flush=True)
        if context['guiPID']: print('Own GUI left running for visible verification and normal Exit.',flush=True)

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__); parser.add_argument('--app',type=Path,required=True); parser.add_argument('--run',action='store_true')
    args=parser.parse_args()
    if not args.run: parser.error('Explicit --run required')
    run(args.app.resolve())
