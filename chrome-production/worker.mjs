import { TabIdentities, snapshot, execute, redactedText } from "./policy.mjs";
const pending = new Map();
let identities = new TabIdentities();
let port = null, sessionID = null, serviceID = null, profileID = null;
let settings = { enabled: false, label: "Chrome" };
let policy = { excludedDomains: [] };
let busy = false, timer = null, lastIssue = null, lastResult = null, retry = 2000;
const ready = chrome.storage.local.get(["profileID", "enabled", "label"]).then(async stored => {
  profileID = stored.profileID ?? crypto.randomUUID();
  settings = { enabled: stored.enabled === true, label: redactedText(stored.label ?? "Chrome", 80, 200) };
  await chrome.storage.local.set({ profileID });
  if (settings.enabled) connect();
});
function clearPending() { for (const p of pending.values()) { clearTimeout(p.timeout); p.reject(new Error("native_disconnected")); } pending.clear(); }
function send(operation, fields = {}) {
  if (!port) return Promise.reject(new Error("native_disconnected"));
  const connection = port, requestID = crypto.randomUUID();
  return new Promise((resolve, reject) => {
    const timeout = setTimeout(() => { pending.delete(requestID); reject(new Error("native_timeout")); }, 5000);
    pending.set(requestID, { resolve, reject, timeout, connection });
    try {
      const message = { version: 1, requestID, operation, profileID, ...fields };
      if (new TextEncoder().encode(JSON.stringify(message)).length > 1_048_576) throw new Error("snapshot_too_large");
      connection.postMessage(message);
    }
    catch (error) { clearTimeout(timeout); pending.delete(requestID); reject(new Error(error.message === "snapshot_too_large" ? "snapshot_too_large" : "native_disconnected")); }
  });
}
function schedule(milliseconds = 3000) {
  clearTimeout(timer);
  if (settings.enabled) timer = setTimeout(() => { if (port && sessionID) tick(); else connect(); }, milliseconds);
}
async function connect() {
  if (!settings.enabled || port) return;
  identities = new TabIdentities(); // Worker/host reconnect invalidates all previously selectable tab tokens.
  const connection = chrome.runtime.connectNative("com.zapas.chrome"); port = connection;
  connection.onMessage.addListener(reply => {
    const p = pending.get(reply.requestID);
    if (!p || p.connection !== connection) return;
    pending.delete(reply.requestID); clearTimeout(p.timeout);
    if (reply.version !== 1 || typeof reply.ok !== "boolean") return p.reject(new Error("protocol_reply"));
    if (!reply.ok) return p.reject(new Error(reply.issue?.code ?? "native_error"));
    p.resolve(reply);
  });
  connection.onDisconnect.addListener(() => {
    void chrome.runtime.lastError; // Consume Chrome error without storing its potentially private text.
    if (port !== connection) return;
    port = null; sessionID = null; serviceID = null; clearPending(); lastIssue = "native_disconnected";
    retry = Math.min(30000, retry * 2); schedule(retry);
  });
  try {
    const reply = await send("chromeHello", { label: settings.label });
    if (port !== connection) return;
    sessionID = reply.sessionID; serviceID = reply.serviceID; policy = reply.policy;
    if (!sessionID || !serviceID || !policy) throw new Error("protocol_reply");
    retry = 2000; lastIssue = null; await tick();
  } catch (error) {
    lastIssue = error.message;
    if (port === connection) { port = null; sessionID = null; serviceID = null; clearPending(); connection.disconnect(); }
    retry = Math.min(30000, retry * 2); schedule(retry);
  }
}
async function currentTabs() {
  const tabs = (await chrome.tabs.query({})).filter(tab => Number.isInteger(tab.id) && !tab.incognito);
  identities.prune(tabs); return tabs.map(tab => snapshot(tab, identities));
}
async function tick() {
  if (busy || !port || !sessionID) return;
  busy = true;
  const identity = { profileID, sessionID, serviceID };
  try {
    const published = await send("chromePublish", { tabs: await currentTabs() });
    if (published.serviceID !== identity.serviceID || published.sessionID !== identity.sessionID) throw new Error("connection_identity_changed");
    policy = published.policy;
    const reply = await send("chromePoll");
    if (reply.serviceID !== identity.serviceID || reply.sessionID !== identity.sessionID) throw new Error("connection_identity_changed");
    if (reply.command) {
      lastResult = await execute(reply.command, { tabs: chrome.tabs, identities, ...identity,
        currentIdentity: () => ({ profileID, sessionID, serviceID }), policy });
      await send("chromeResult", { result: lastResult });
      await send("chromePublish", { tabs: await currentTabs() });
    }
    lastIssue = null;
  } catch (error) {
    lastIssue = error.message;
    // GUI restart also requires hello with a new native session; never replay a command.
    const connection = port; port = null; sessionID = null; serviceID = null; clearPending(); connection?.disconnect();
    retry = Math.min(30000, retry * 2);
  } finally { busy = false; schedule(lastIssue ? retry : 3000); }
}
chrome.tabs.onRemoved.addListener(id => identities.remove(id));
chrome.tabs.onReplaced.addListener((added, removed) => identities.replace(added, removed));
chrome.tabs.onUpdated.addListener((id, change, tab) => { if (change.url || change.status === "loading") identities.observe(tab); });
chrome.alarms.create("reconnect", { periodInMinutes: 0.5 });
chrome.alarms.onAlarm.addListener(async alarm => { if (alarm.name === "reconnect") { await ready; if (settings.enabled && !port) connect(); } });
chrome.runtime.onMessage.addListener((message, sender, respond) => {
  if (sender.id !== chrome.runtime.id || sender.url !== chrome.runtime.getURL("control.html")) return false;
  (async () => {
    await ready;
    if (message.type === "status") return { ok: true, connected: !!sessionID, profileID, sessionID, serviceID, label: settings.label, lastIssue, lastResult, enabled: settings.enabled };
    if (message.type === "connect") {
      settings.enabled = true; settings.label = redactedText(message.label ?? settings.label, 80, 200);
      await chrome.storage.local.set(settings); await connect(); return { ok: true };
    }
    if (message.type === "disconnect") {
      settings.enabled = false; await chrome.storage.local.set({ enabled: false }); clearTimeout(timer);
      try { if (sessionID) await send("chromeDisconnect"); } catch { }
      const connection = port; port = null; sessionID = null; serviceID = null; clearPending(); connection?.disconnect(); return { ok: true };
    }
    throw new Error("control_operation_denied");
  })().then(respond, () => respond({ ok: false, issue: "control_failed" })); return true;
});
chrome.action.onClicked.addListener(() => chrome.tabs.create({ url: chrome.runtime.getURL("control.html") }));
