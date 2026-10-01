import { test } from 'node:test';
import assert from 'node:assert/strict';
import { exclusion, snapshot, TabIdentities, execute, RECENT_MS, redactedText } from './policy.mjs';
const time = 1800000000000;
const freshTab = () => ({ id: 7, windowId: 3, title: 'Own test', url: 'https://example.test/private?q=secret', active: false, pinned: false, audible: false, incognito: false, discarded: false, lastAccessed: time - RECENT_MS - 1 });
function fixture() {
  const tracker = new TabIdentities(() => `token-${++counter}`); let counter = 0;
  let live = freshTab(), calls = [];
  const state = { profileID: 'profile', sessionID: 'session', serviceID: 'service' };
  const tabs = { get: async id => { if (!live || id !== live.id) throw new Error('missing https://private.test'); return { ...live }; }, query: async () => live ? [{ ...live }] : [],
    discard: async id => { calls.push(['discard',id]); live.discarded=true; return { ...live }; },
    remove: async id => { calls.push(['close',id]); tracker.remove(id); live=null; } };
  const expected = snapshot(live, tracker);
  const command = { id: 'command', kind: 'discard', target: { selection: { profileID:'profile',sessionID:'session',tabID:7,token:expected.token }, expected }, expiresAt: new Date(time + 20000).toISOString(), policy:{excludedDomains:[]} };
  const context = { tabs, identities:tracker, ...state, currentIdentity:()=>state, policy:{excludedDomains:[]}, now:()=>time };
  return { command,context,calls,tracker,state,live,tabs };
}
for (const [flag, value, code] of [['active',true,'active'],['pinned',true,'pinned'],['audible',true,'audible'],['incognito',true,'incognito'],['pending',true,'navigation_pending'],['splitView',true,'split_view'],['lastAccessedMilliseconds',null,'activity_unknown'],['lastAccessedMilliseconds',time+1,'activity_unknown'],['lastAccessedMilliseconds',time-599999,'recently_active'],['domain',null,'domain_unknown'],['domain','meet.google.com','user_excluded'],['discarded',true,'already_discarded']]) {
  test(`protect ${code}`,()=> { const f=fixture(); const tab={...f.command.target.expected,[flag]:value}; assert.equal(exclusion(tab,'discard',['meet.google.com'],time),code); });
}
test('approved production threshold, inclusive boundary and close already discarded',()=> { const f=fixture(); const tab={...f.command.target.expected,lastAccessedMilliseconds:time-600000,discarded:true}; assert.equal(RECENT_MS,600000); assert.equal(exclusion(tab,'close',[],time),null); });
test('no full URL or incognito metadata in snapshot',()=> { const f=fixture(); assert.ok(!JSON.stringify(f.command.target.expected).includes('secret')); const privateTab=snapshot({...f.live,incognito:true},f.tracker); assert.equal(privateTab.domain,null); assert.equal(privateTab.title,'Приватная вкладка'); });
test('titles containing addresses are redacted',()=> { const f=fixture(); assert.ok(!snapshot({...f.live,title:f.live.url},f.tracker).title.includes('secret')); });
test('discard exactly one explicit ID and verify state',async()=> { const f=fixture(); const r=await execute(f.command,f.context); assert.equal(r.status,'confirmed'); assert.equal(r.resultingTabID,7); assert.deepEqual(f.calls,[['discard',7]]); });
test('close separate operation verifies removal event and actual absence',async()=> { const f=fixture(); f.command.kind='close'; const r=await execute(f.command,f.context); assert.equal(r.status,'confirmed'); assert.deepEqual(f.calls,[['close',7]]); });
for (const flag of ['active','pinned','audible','incognito']) test(`fresh ${flag} prevents invocation`,async()=> { const f=fixture(); f.live[flag]=true; const r=await execute(f.command,f.context); assert.equal(r.status,'failed'); assert.equal(f.calls.length,0); });
test('navigation, reused ID and window movement invalidate identity',async()=> { for(const change of [{url:'https://example.test/different'},{windowId:9}]) { const f=fixture(); Object.assign(f.live,change); assert.equal((await execute(f.command,f.context)).status,'failed'); assert.equal(f.calls.length,0); } const f=fixture(); f.tracker.remove(7); f.tracker.observe(f.live); assert.equal((await execute(f.command,f.context)).status,'failed'); });
test('session/profile mismatch and connection change refuse',async()=> { for(const key of ['profileID','sessionID']) { const f=fixture(); f.command.target.selection[key]='other'; assert.equal((await execute(f.command,f.context)).status,'failed'); assert.equal(f.calls.length,0); } const f=fixture(); f.state.serviceID='new'; assert.equal((await execute(f.command,f.context)).status,'failed'); assert.equal(f.calls.length,0); });
test('expiry before call refuses',async()=> { const f=fixture(); f.command.expiresAt=new Date(time).toISOString(); assert.equal((await execute(f.command,f.context)).status,'failed'); assert.equal(f.calls.length,0); });
test('policy exclusion immediately before action refuses',async()=> { const f=fixture(); f.context.policy.excludedDomains=['example.test']; assert.equal((await execute(f.command,f.context)).issue,'user_excluded'); assert.equal(f.calls.length,0); });
test('tab disappears before call failed; after submission unknown',async()=> { const f=fixture(); f.tabs.get=async()=>{throw Error('missing')}; assert.equal((await execute(f.command,f.context)).status,'failed'); assert.equal(f.calls.length,0); const g=fixture(); g.tabs.discard=async()=>{throw Error('refused https://secret.test')}; const r=await execute(g.command,g.context); assert.equal(r.status,'unknown'); assert.ok(!JSON.stringify(r).includes('secret')); });
test('replacement needs matching event, response URL, window and discarded reread',async()=> { const f=fixture(); f.tabs.discard=async()=>{f.tracker.replace(9,7); f.live.id=9; f.live.discarded=true; return {...f.live};}; assert.equal((await execute(f.command,f.context)).status,'confirmed'); const g=fixture(); g.tabs.discard=async()=>{g.live.id=9; g.live.discarded=true;return {...g.live};}; assert.equal((await execute(g.command,g.context)).status,'unknown'); });
test('unconfirmed discard and close remain unknown',async()=> { const f=fixture(); f.tabs.discard=async()=>({...f.live}); assert.equal((await execute(f.command,f.context)).status,'unknown'); const g=fixture();g.command.kind='close';g.tabs.remove=async()=>{};assert.equal((await execute(g.command,g.context)).status,'unknown'); });
test('connection replaced after send cannot confirm old command',async()=> { const f=fixture(); f.tabs.discard=async()=>{f.state.sessionID='new'; f.live.discarded=true; return {...f.live};};assert.equal((await execute(f.command,f.context)).status,'unknown'); });

test('all URL schemes are redacted and unsupported IPv6 hosts remain unknown', () => {
  assert.equal(redactedText('Page custom+app://host/private?q=secret ftp://host/private'), 'Page [адрес скрыт] [адрес скрыт]');
  assert.equal(redactedText('a'.repeat(100), 80).length, 80);
  assert.ok(new TextEncoder().encode(redactedText('界'.repeat(80), 80, 200)).length <= 200);
  assert.ok(!redactedText('😀'.repeat(80), 80, 200).includes('\uFFFD'));
  const tab = freshTab(); tab.url = 'http://[::1]/private'; tab.title = 'chrome-extension://private/path';
  const value = snapshot(tab, new TabIdentities());
  assert.equal(value.domain, null); assert.equal(value.title, '[адрес скрыт]');
  assert.equal(exclusion(value, 'close', [], time), 'domain_unknown');
  assert.ok(!JSON.stringify(value).includes('/private'));
});
