import { test } from "node:test";
import assert from "node:assert/strict";
import { exclusion, isOwnedFixture, snapshot, executeTestDiscard } from "./policy.mjs";

const time = 1_700_000_000_000;
const fixtureURL = "chrome-extension://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/fixture.html";
const owned = new Map([[7, "nonce"]]);
const fixture = { id: 7, windowId: 2, url: `${fixtureURL}?token=nonce`, title: "Fixture",
  active: false, pinned: false, audible: false, incognito: false, discarded: false, lastAccessed: 1, splitViewId: -1 };
const action = { id: "action", sessionID: "session", tabID: 7, expectedWindowID: 2,
  expectedLastAccessedMilliseconds: 1, expiresAt: new Date(time + 10_000).toISOString() };

test("only owned exact fixture URL and token qualify", () => {
  assert.equal(isOwnedFixture(fixture, owned, fixtureURL), true);
  for (const changed of [
    { id: 8 }, { url: `${fixtureURL}?token=other` }, { pendingUrl: "https://example.test" },
    { url: fixture.url.replace("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb") },
    { url: "https://example.test/fixture.html?token=nonce" }
  ]) assert.equal(isOwnedFixture({ ...fixture, ...changed }, owned, fixtureURL), false);
});
test("snapshot does not include full URL or form contents", () => {
  const value = snapshot(fixture, true);
  assert.equal("url" in value, false);
  assert.equal("form" in value, false);
  assert.equal(value.windowID, 2);
  assert.equal(value.lastAccessedMilliseconds, 1);
});
for (const [field, value, reason] of [
  ["active", true, "active"], ["pinned", true, "pinned"], ["audible", true, "audible"],
  ["incognito", true, "incognito"], ["discarded", true, "already_discarded"],
  ["lastAccessedMilliseconds", time, "recently_active"], ["lastAccessedMilliseconds", null, "activity_unknown"],
  ["splitViewID", 3, "split_view"], ["isTestFixture", false, "not_test_fixture"]
]) test(`policy excludes ${reason}`, () => {
  assert.equal(exclusion({ ...snapshot(fixture, true), [field]: value }, time), reason);
});
test("eligible fixture is selected explicitly and confirmed", async () => {
  const calls = [];
  let done = false;
  const tabs = {
    get: async id => { calls.push(["get", id]); return { ...fixture, discarded: done }; },
    discard: async id => { calls.push(["discard", id]); done = true; return { ...fixture, discarded: true }; }
  };
  const result = await executeTestDiscard(action, { tabs, owned, fixtureURL, now: () => time });
  assert.equal(result.status, "confirmed");
  assert.equal(result.discarded, true);
  assert.deepEqual(calls, [["get", 7], ["discard", 7], ["get", 7]]);
});
for (const changed of [{ active: true }, { pinned: true }, { audible: true }, { incognito: true },
  { lastAccessed: time }, { windowId: 3 }, { url: "https://example.test" }, { pendingUrl: "https://example.test" }]) {
  test(`fresh state prevents changed tab action: ${Object.keys(changed)[0]}`, async () => {
    let discarded = false;
    const tabs = { get: async () => ({ ...fixture, ...changed }), discard: async () => { discarded = true; } };
    const result = await executeTestDiscard(action, { tabs, owned, fixtureURL, now: () => time });
    assert.equal(result.status, "refused"); assert.equal(discarded, false);
  });
}
test("expired action does not even read a tab", async () => {
  const tabs = { get: async () => assert.fail("expired action read tab") };
  const result = await executeTestDiscard({ ...action, expiresAt: new Date(time - 1).toISOString() }, { tabs, owned, fixtureURL, now: () => time });
  assert.equal(result.status, "refused");
});
test("tab disappearance, Chrome refusal and absent confirmation are reported", async () => {
  for (const mode of ["missing", "denied", "undefined", "unconfirmed"]) {
    const tabs = {
      get: async () => { if (mode === "missing") throw new Error("Tab no longer exists"); return fixture; },
      discard: async () => { if (mode === "denied") throw new Error("Chrome denied"); return mode === "undefined" ? undefined : fixture; }
    };
    const result = await executeTestDiscard(action, { tabs, owned, fixtureURL, now: () => time });
    assert.equal(result.status, mode === "missing" ? "refused" : "unknown"); assert.equal(result.discarded, false); assert.ok(result.issue);
  }
});
test("Chrome replacement tab ID is verified and ownership is transferred", async () => {
  const ownership = new Map([[7, "nonce"]]);
  const tabs = {
    get: async id => ({ ...fixture, id, discarded: id === 8 }),
    discard: async id => ({ ...fixture, id: 8, discarded: true })
  };
  const result = await executeTestDiscard(action, { tabs, owned: ownership, fixtureURL, now: () => time });
  assert.equal(result.status, "confirmed"); assert.equal(result.tabID, 7); assert.equal(result.resultingTabID, 8);
  assert.equal(ownership.has(7), false); assert.equal(ownership.get(8), "nonce");
});
test("replacement with wrong nonce cannot inherit ownership", async () => {
  const ownership = new Map([[7, "nonce"]]);
  const tabs = {
    get: async id => ({ ...fixture, id, url: id === 8 ? `${fixtureURL}?token=wrong` : fixture.url, discarded: id === 8 }),
    discard: async () => ({ ...fixture, id: 8, discarded: true })
  };
  const result = await executeTestDiscard(action, { tabs, owned: ownership, fixtureURL, now: () => time });
  assert.equal(result.status, "unknown"); assert.equal(ownership.has(8), false);
});
test("undefined return can still be confirmed by actual discarded state", async () => {
  let done = false;
  const tabs = {
    get: async () => ({ ...fixture, discarded: done }),
    discard: async () => { done = true; return undefined; }
  };
  const result = await executeTestDiscard(action, { tabs, owned: new Map([[7, "nonce"]]), fixtureURL, now: () => time });
  assert.equal(result.status, "confirmed"); assert.equal(result.resultingTabID, 7);
});
