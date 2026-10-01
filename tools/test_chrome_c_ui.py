#!/usr/bin/env python3
"""Opt-in native GUI qualification companion. Own pages, one isolated Chrome and one GUI.
Waits for actual manual selection/preview/confirmation, then a normal GUI Exit/relaunch.
Markers inside .local coordinate UI checks; no process termination commands.
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

ROOT=Path(__file__).resolve().parents[1]

def run(app, window_delay=330):
    directory=ROOT/'.local'/('c-ui-'+uuid.uuid4().hex[:8]);directory.mkdir(mode=0o700)
    runtime=directory/'run';runtime.mkdir(mode=0o700)
    profile=directory/'profile';profile.mkdir(mode=0o700)
    pages=directory/'pages';pages.mkdir()
    (pages/'page.html').write_text('''<!doctype html><html lang="ru"><meta charset="utf-8"><title>Zapas C</title><h1>Собственная тестовая страница C</h1><input id="unsaved"><script>document.title='Zapas C '+new URLSearchParams(location.search).get('role');globalThis.heap=new Array(100000).fill(42);</script>''')
    class Quiet(http.server.SimpleHTTPRequestHandler):
        def log_message(self,*args):pass
    server=http.server.ThreadingHTTPServer(('127.0.0.1',0),functools.partial(Quiet,directory=str(pages)))
    threading.Thread(target=server.serve_forever,daemon=True).start()
    env=dict(os.environ,ZAPAS_RUNTIME=str(runtime),ZAPAS_EPHEMERAL='1')
    binary=app/'Contents/MacOS/zapas';gui_binary=app/'Contents/MacOS/ZapasApp'
    trace=directory/'gui-trace.ndjson';log=(directory/'runtime.log').open('ab')
    context={'directory':str(directory),'runtime':str(runtime),'app':str(app),'phase':'setup'}
    report={'checks':{},'status':'RUNNING'}
    def save():
        (ROOT/'.local/results/stage-c/ui-context.json').write_text(json.dumps(context,indent=2))
        (directory/'report.json').write_text(json.dumps(report,indent=2))
    c=None;gui=None
    try:
        listed=subprocess.check_output(['ps','-axo','args'],text=True)
        if any(line.strip().split(' ')[0].endswith('/Contents/MacOS/ZapasApp') for line in listed.splitlines()):raise RuntimeError('Existing Zapas must be exited normally before qualification')
        gui=subprocess.Popen([str(gui_binary),'--qualification-window-after',str(window_delay),'--qualification-output',str(trace)],env=env,stdout=log,stderr=log)
        context['guiPID']=gui.pid;save()
        path=runtime/'gui.sock';wait_until(lambda:path.exists(),bool)
        installed=subprocess.run([str(binary),'native','install','--user-data-dir',str(profile),'--apply','--json'],env=env,capture_output=True,text=True)
        assert installed.returncode==0,installed.stdout
        c=CDP(['/Applications/Google Chrome.app/Contents/MacOS/Google Chrome','--user-data-dir='+str(profile),'--no-first-run','--no-default-browser-check','--disable-sync','--remote-debugging-pipe','--enable-unsafe-extension-debugging','about:blank'],log)
        report['version']=c.call('Browser.getVersion')
        loaded=c.call('Extensions.loadUnpacked',{'path':str(app/'Contents/Resources/chrome-extension')})
        origin='chrome-extension://'+loaded['id']+'/'
        targets={}
        for role in ['discard','close']:
            url=f'http://127.0.0.1:{server.server_port}/page.html?role={role}&nonce={uuid.uuid4()}'
            target=c.call('Target.createTarget',{'url':url})['targetId'];session=c.attach(target)
            wait_until(lambda:c.evaluate(session,"location.href === "+json.dumps(url)+" && document.readyState === 'complete'"),bool)
            c.call('Target.detachFromTarget',{'sessionId':session});targets[role]=url
        target=c.call('Target.createTarget',{'url':origin+'control.html'})['targetId'];control=c.attach(target)
        wait_until(lambda:c.evaluate(control,"location.href === "+json.dumps(origin+'control.html')+" && document.readyState === 'complete' && typeof chrome.runtime?.sendMessage === 'function'"),bool)
        def send(kind):return c.evaluate(control,f'chrome.runtime.sendMessage({json.dumps({"type":kind,"label":"C native UI"})})')
        send('connect');state=wait_until(lambda:send('status'),lambda r:r.get('connected'))
        context.update(phase='cooldown',profileID=state['profileID'],sessionID=state['sessionID'],serviceID=state['serviceID']);save()
        print('Native UI live setup PASS; 600-second cooldown. Evidence:',directory,flush=True)
        report['checks']['installation_final_bundle']='PASS'
        # Actual tab lastAccessed determines readiness; no wall-clock manipulation.
        def eligible():
            data=rpc(path,{'operation':'tabsList'}).get('profiles',[])
            p=next((p for p in data if p['id']==state['profileID']),None)
            return p and len([t for t in p['tabs'] if t['title'] in ['Zapas C discard','Zapas C close'] and not t['active'] and t.get('lastAccessedMilliseconds') and time.time()*1000-t['lastAccessedMilliseconds']>=600000])==2
        wait_until(eligible,bool,timeout=630)
        context['phase']='ready';save();print('Ready: manually preview/cancel, then discard and close the two named own tabs in GUI',flush=True)
        wait_until(lambda:(directory/'ui-done').exists(),bool,timeout=600)
        actual=c.evaluate(control,'chrome.tabs.query({})')
        assert next(t for t in actual if t.get('url')==targets['discard'])['discarded']
        assert not any(t.get('url')==targets['close'] for t in actual)
        report['checks']['gui_discard_actual_state']='PASS';report['checks']['gui_close_actual_absence']='PASS'
        context['phase']='restart-ready';save();print('GUI actions actual state PASS. Exit own GUI normally to qualify service restart.',flush=True)
        gui.wait(timeout=600)
        old=state
        gui=subprocess.Popen([str(gui_binary),'--qualification-window','--qualification-output',str(directory/'gui-restarted-trace.ndjson')],env=env,stdout=log,stderr=log)
        context['guiPID']=gui.pid;save()
        state=wait_until(lambda:send('status'),lambda r:r.get('connected') and r['serviceID']!=old['serviceID'] and r['sessionID']!=old['sessionID'],timeout=65)
        assert state['profileID']==old['profileID']
        invalid=rpc(path,{'operation':'tabsPreview','kind':'close','selections':[{'profileID':old['profileID'],'sessionID':old['sessionID'],'tabID':0,'token':str(uuid.uuid4())}]})
        assert not invalid['ok']
        report['checks']['normal_service_exit_restart_reconnect']='PASS';report['checks']['old_service_selection_refused']='PASS'
        context['phase']='finished';report['status']='PASS';save();print('Native UI/service restart PASS. GUI left for normal Exit.',flush=True)
    except Exception as e:
        report['status']='FAIL';report['error']=repr(e);save();raise
    finally:
        if c:
            if c.process.poll() is None:
                try:c.call('Browser.close',timeout=5);c.process.wait(timeout=10)
                except Exception as e:print('Own Chrome cleanup needs attention:',type(e).__name__,flush=True)
            os.close(c.write_fd);os.close(c.read_fd)
        server.shutdown();log.close()
        save()

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--app',type=Path,required=True);parser.add_argument('--run',action='store_true');parser.add_argument('--window-delay',type=int,default=330);args=parser.parse_args()
    if not args.run:parser.error('Explicit --run required')
    if not 1 <= args.window_delay <= 600: parser.error("window-delay must be 1...600; tab protection remains 600 seconds")
    run(args.app.resolve(), args.window_delay)
