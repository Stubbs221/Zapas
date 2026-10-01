export const RECENT_MS = 60_000; // Stage A research threshold, not product policy.

export function isOwnedFixture(tab, owned, fixtureURL) {
  const token = owned.get(tab.id);
  if (!token || tab.pendingUrl) return false;
  try {
    const url = new URL(tab.url);
    const expected = new URL(fixtureURL);
    return url.protocol === expected.protocol && url.host === expected.host &&
      url.pathname === expected.pathname && url.searchParams.get("token") === token;
  } catch { return false; }
}

export function exclusion(tab, now = Date.now()) {
  if (!tab.isTestFixture) return "not_test_fixture";
  if (tab.active) return "active";
  if (tab.pinned) return "pinned";
  if (tab.audible) return "audible";
  if (tab.incognito) return "incognito";
  if (tab.discarded) return "already_discarded";
  if (Number.isInteger(tab.splitViewID) && tab.splitViewID !== -1) return "split_view";
  if (!Number.isFinite(tab.lastAccessedMilliseconds) || tab.lastAccessedMilliseconds < 0) return "activity_unknown";
  if (now - tab.lastAccessedMilliseconds < RECENT_MS) return "recently_active";
  return null;
}

export function snapshot(tab, isTestFixture) {
  let domain = null;
  try { domain = new URL(tab.url).hostname || null; } catch { /* Unknown URL is not a memory estimate. */ }
  return {
    id: tab.id, windowID: tab.windowId, title: (tab.title ?? "").slice(0, 1000), domain,
    active: !!tab.active, pinned: !!tab.pinned, audible: !!tab.audible,
    incognito: !!tab.incognito, discarded: !!tab.discarded,
    lastAccessedMilliseconds: Number.isFinite(tab.lastAccessed) ? tab.lastAccessed : null,
    splitViewID: Number.isInteger(tab.splitViewId) ? tab.splitViewId : null,
    isTestFixture
  };
}

export async function executeTestDiscard(action, { tabs, owned, fixtureURL, now = () => Date.now() }) {
  const result = { id: action.id, tabID: action.tabID, status: "refused", discarded: false,
    measuredAt: new Date(now()).toISOString().replace(/\.\d{3}Z$/, "Z") };
  try {
    if (!Number.isInteger(action.tabID) || action.tabID < 0 || !Number.isFinite(Date.parse(action.expiresAt)) ||
      now() >= Date.parse(action.expiresAt)) throw new Error("action_expired_or_invalid");
    const fresh = await tabs.get(action.tabID);
    if (fresh.windowId !== action.expectedWindowID || fresh.lastAccessed !== action.expectedLastAccessedMilliseconds)
      throw new Error("tab_state_changed");
    const reason = exclusion(snapshot(fresh, isOwnedFixture(fresh, owned, fixtureURL)), now());
    if (reason) throw new Error(reason);
    const token = owned.get(action.tabID);
    // Always explicit ID. Omitting it would let Chrome choose an unrelated tab.
    result.status = "unknown"; // After submission, a missing confirmation is not proof that nothing happened.
    const discarded = await tabs.discard(action.tabID);
    const resultingID = discarded?.id ?? action.tabID;
    if (!Number.isInteger(resultingID) || resultingID < 0) throw new Error("chrome_discard_invalid_result_id");
    const confirmed = await tabs.get(resultingID);
    const expectedOwnership = new Map([[resultingID, token]]);
    if (confirmed.windowId !== action.expectedWindowID || !isOwnedFixture(confirmed, expectedOwnership, fixtureURL))
      throw new Error("discard_result_identity_mismatch");
    if (!confirmed.discarded) throw new Error("discard_state_unconfirmed");
    // Chrome may replace WebContents and tab ID on discard. Verify the fixture nonce before transferring ownership.
    owned.delete(action.tabID); owned.set(resultingID, token);
    result.resultingTabID = resultingID;
    result.status = "confirmed"; result.discarded = true;
  } catch (error) { result.issue = String(error.message ?? error).slice(0, 512); }
  return result;
}
