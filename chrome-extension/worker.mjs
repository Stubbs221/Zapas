import { isOwnedFixture, snapshot, executeTestDiscard } from "./policy.mjs";

const HOST = "com.zapas.stage_a";
const fixtureURL = chrome.runtime.getURL("fixture.html");
const owned = new Map();
const pending = new Map();
let port = null;
let sessionID = null;
let timer = null;
let requested = false;
let busy = false;
let lastIssue = null;
let lastResult = null;

function rejectPending(message) {
  for (const { reject, timeout } of pending.values()) { clearTimeout(timeout); reject(new Error(message)); }
  pending.clear();
}
function send(operation, extra = {}) {
  if (!port) return Promise.reject(new Error("native_host_disconnected"));
  const requestID = crypto.randomUUID();
  return new Promise((resolve, reject) => {
    const timeout = setTimeout(() => { pending.delete(requestID); reject(new Error("native_host_timeout")); }, 4500);
    pending.set(requestID, { resolve, reject, timeout });
    try { port.postMessage({ version: 1, requestID, operation, ...extra }); }
    catch (error) { clearTimeout(timeout); pending.delete(requestID); reject(error); }
  });
}
async function connect() {
  requested = true;
  if (port) return;
  const connection = chrome.runtime.connectNative(HOST);
  port = connection;
  connection.onMessage.addListener(reply => {
    const item = pending.get(reply.requestID);
    if (!item) return;
    pending.delete(reply.requestID); clearTimeout(item.timeout);
    if (reply.version !== 1) item.reject(new Error("protocol_version"));
    else if (!reply.ok) item.reject(new Error(`${reply.issue?.code}: ${reply.issue?.message}`));
    else { if (reply.sessionID) sessionID = reply.sessionID; item.resolve(reply); }
  });
  connection.onDisconnect.addListener(() => {
    lastIssue = chrome.runtime.lastError?.message ?? "native_host_disconnected";
    if (port === connection) { port = null; sessionID = null; }
    rejectPending(lastIssue);
    if (requested) schedule();
  });
  try { await send("hello"); lastIssue = null; await tick(); }
  catch (error) { lastIssue = error.message; schedule(); }
}
function schedule() {
  clearTimeout(timer);
  if (requested) timer = setTimeout(() => { if (port) tick(); else connect(); }, 3000);
}
async function currentTabs() {
  const tabs = await chrome.tabs.query({});
  return tabs.filter(tab => Number.isInteger(tab.id)).map(tab => snapshot(tab, isOwnedFixture(tab, owned, fixtureURL)));
}
async function tick() {
  if (busy) return;
  busy = true;
  try {
    await send("publishTabs", { tabs: await currentTabs() });
    const reply = await send("pollTestAction");
    if (reply.action) {
      if (reply.action.sessionID !== sessionID) throw new Error("session_mismatch");
      lastResult = await executeTestDiscard(reply.action, { tabs: chrome.tabs, owned, fixtureURL });
      await send("submitResult", { result: lastResult });
      await send("publishTabs", { tabs: await currentTabs() });
    }
    lastIssue = null;
  } catch (error) { lastIssue = error.message; }
  finally { busy = false; schedule(); }
}
function disconnect() {
  requested = false; clearTimeout(timer); timer = null;
  const connection = port; port = null; sessionID = null;
  rejectPending("disconnected_by_user"); connection?.disconnect();
}
chrome.runtime.onMessage.addListener((message, sender, respond) => {
  // Only this extension's control page can start a connection or create fixtures.
  if (sender.id !== chrome.runtime.id || sender.url !== chrome.runtime.getURL("control.html")) return false;
  (async () => {
    switch (message.type) {
      case "connect": await connect(); return { ok: true };
      case "disconnect": disconnect(); return { ok: true };
      case "status": return { ok: true, connected: !!port && !!sessionID, sessionID, lastIssue, lastResult, tabs: await currentTabs() };
      case "create-fixture": {
        const token = crypto.randomUUID();
        const tab = await chrome.tabs.create({ url: `${fixtureURL}?token=${encodeURIComponent(token)}`, windowId: sender.tab.windowId, active: false });
        owned.set(tab.id, token); return { ok: true, tabID: tab.id };
      }
      default: throw new Error("unsupported_control_message");
    }
  })().then(respond, error => respond({ ok: false, issue: error.message }));
  return true;
});
chrome.tabs.onRemoved.addListener(id => owned.delete(id));
chrome.tabs.onReplaced.addListener(async (added, removed) => {
  const token = owned.get(removed);
  owned.delete(removed);
  if (!token) return;
  try {
    const tab = await chrome.tabs.get(added);
    if (isOwnedFixture(tab, new Map([[added, token]]), fixtureURL)) owned.set(added, token);
  } catch { /* Missing or changed replacement is not an owned fixture. */ }
});
chrome.action.onClicked.addListener(() => chrome.tabs.create({ url: chrome.runtime.getURL("control.html") }));
