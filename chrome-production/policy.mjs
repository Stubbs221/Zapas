export const RECENT_MS = 600_000; // User approved on 2026-10-01 for discard and close.
export function redactedText(text, limit = 1000, byteLimit = 4096) {
  const characters = Array.from(String(text ?? "").replace(/[a-z][a-z0-9+.-]*:\/\/\S+/gi, "[адрес скрыт]")).slice(0, limit);
  while (new TextEncoder().encode(characters.join("")).length > byteLimit) characters.pop();
  return characters.join("");
}
export function exclusion(tab, kind, domains = [], now = Date.now()) {
  for (const [flag, reason] of [["active", "active"], ["pinned", "pinned"], ["audible", "audible"], ["incognito", "incognito"], ["pending", "navigation_pending"], ["splitView", "split_view"]])
    if (tab[flag]) return reason;
  if (!tab.domain) return "domain_unknown";
  if (domains.includes(tab.domain)) return "user_excluded";
  if (kind === "discard" && tab.discarded) return "already_discarded";
  const access = tab.lastAccessedMilliseconds;
  if (!Number.isFinite(access) || access < 0 || access > now) return "activity_unknown";
  if (now - access < RECENT_MS) return "recently_active";
  return null;
}
export class TabIdentities {
  constructor(uuid = () => crypto.randomUUID()) { this.uuid = uuid; this.live = new Map(); this.removed = new Map(); this.replacements = new Map(); }
  observe(tab) {
    let identity = this.live.get(tab.id);
    const key = JSON.stringify([tab.url ?? null, tab.windowId, tab.pendingUrl ?? null]);
    if (!identity || identity.key !== key) {
      identity = { key, token: this.uuid() }; this.live.set(tab.id, identity);
    }
    return identity.token;
  }
  remove(id) {
    const token = this.live.get(id)?.token;
    if (token) this.removed.set(id, token);
    this.live.delete(id);
    if (this.removed.size > 2000) this.removed.delete(this.removed.keys().next().value);
  }
  replace(added, removed) { this.remove(removed); this.replacements.set(removed, added); if (this.replacements.size > 2000) this.replacements.delete(this.replacements.keys().next().value); }
  prune(tabs) { const ids = new Set(tabs.map(t => t.id)); for (const id of this.live.keys()) if (!ids.has(id)) this.remove(id); }
}
export function snapshot(tab, identities) {
  let domain = null;
  try { const url = new URL(tab.url); if (["http:", "https:"].includes(url.protocol) && /^[a-z0-9.-]{1,253}$/i.test(url.hostname)) domain = url.hostname; } catch { }
  return { id: tab.id, token: identities.observe(tab), windowID: tab.windowId,
    title: tab.incognito ? "Приватная вкладка" : redactedText(tab.title),
    domain: tab.incognito ? null : domain, active: !!tab.active, pinned: !!tab.pinned, audible: !!tab.audible,
    incognito: !!tab.incognito, discarded: !!tab.discarded, pending: !!tab.pendingUrl,
    splitView: Number.isInteger(tab.splitViewId) && tab.splitViewId !== -1,
    lastAccessedMilliseconds: Number.isFinite(tab.lastAccessed) ? tab.lastAccessed : null };
}
export function sameState(a, b) {
  return ["id", "token", "windowID", "domain", "active", "pinned", "audible", "incognito", "discarded", "pending", "splitView", "lastAccessedMilliseconds", "title"].every(key => a[key] === b[key]);
}
export async function execute(command, context) {
  const { tabs, identities, profileID, sessionID, serviceID, currentIdentity, policy, now = () => Date.now() } = context;
  const result = { id: command.id, status: "failed", measuredAt: new Date(now()).toISOString().replace(/\.\d{3}Z$/, "Z") };
  let sent = false;
  let fresh;
  const assertConnection = () => {
    const current = currentIdentity();
    if (current.profileID !== profileID || current.sessionID !== sessionID || current.serviceID !== serviceID) throw new Error("connection_identity_changed");
  };
  try {
    const target = command.target;
    if (!command.id || !["discard", "close"].includes(command.kind) || !Number.isFinite(Date.parse(command.expiresAt)) || now() >= Date.parse(command.expiresAt)) throw new Error("command_expired");
    if (target.selection.profileID !== profileID || target.selection.sessionID !== sessionID || target.selection.tabID !== target.expected.id || target.selection.token !== target.expected.token) throw new Error("selection_identity_mismatch");
    assertConnection();
    fresh = await tabs.get(target.selection.tabID);
    const observed = snapshot(fresh, identities);
    if (!sameState(observed, target.expected)) throw new Error("tab_state_changed");
    const domains = [...new Set([...(policy.excludedDomains ?? []), ...(command.policy.excludedDomains ?? [])])];
    const reason = exclusion(observed, command.kind, domains, now());
    if (reason) throw new Error(reason);
    // No await between this final connection/deadline check and the explicit single-tab API call.
    assertConnection();
    if (now() >= Date.parse(command.expiresAt)) throw new Error("command_expired");
    sent = true; result.status = "unknown";
    if (command.kind === "discard") {
      const returned = await tabs.discard(observed.id);
      assertConnection();
      if (!Number.isInteger(returned?.id) || returned.windowId !== fresh.windowId || returned.url !== fresh.url) throw new Error("discard_response_identity");
      const verified = await tabs.get(returned.id);
      assertConnection();
      if (returned.id !== observed.id && identities.replacements.get(observed.id) !== returned.id) throw new Error("replacement_unverified");
      if (returned.id === observed.id && identities.live.get(observed.id)?.token !== observed.token) throw new Error("identity_changed_after_action");
      if (verified.url !== fresh.url || verified.windowId !== fresh.windowId || verified.pendingUrl || !verified.discarded || verified.active || verified.incognito) throw new Error("discard_state_unconfirmed");
      result.resultingTabID = returned.id; result.status = "confirmed";
    } else {
      await tabs.remove(observed.id);
      assertConnection();
      const remaining = await tabs.query({});
      assertConnection();
      if (remaining.some(tab => tab.id === observed.id) || identities.removed.get(observed.id) !== observed.token) throw new Error("close_state_unconfirmed");
      result.status = "confirmed";
    }
  } catch (error) {
    // Do not copy Chrome errors: they can contain page addresses. Controlled codes only.
    const codes = new Set(["command_expired", "selection_identity_mismatch", "connection_identity_changed", "tab_state_changed", "active", "pinned", "audible", "incognito", "navigation_pending", "split_view", "domain_unknown", "user_excluded", "already_discarded", "activity_unknown", "recently_active", "discard_response_identity", "replacement_unverified", "identity_changed_after_action", "discard_state_unconfirmed", "close_state_unconfirmed"]);
    result.issue = codes.has(error.message) ? error.message : sent ? "chrome_api_or_confirmation_failed" : "tab_missing_or_api_failed";
  }
  result.measuredAt = new Date(now()).toISOString().replace(/\.\d{3}Z$/, "Z");
  return result;
}
