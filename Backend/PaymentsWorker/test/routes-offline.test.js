// Signed offline policy issuance and offline cash sync tests through the real Worker and D1.
import test from "node:test";
import assert from "node:assert/strict";
import { webcrypto } from "node:crypto";
import { createHarness, activePaidEvent, newOrder, PAID_POLICY, TOKENS } from "./support/harness.js";

async function withHarness(options, body) {
    if (typeof options === "function") { body = options; options = {}; }
    const h = await createHarness(options);
    try { await body(h); } finally { await h.dispose(); }
}

const OFFLINE_POLICY = { ...PAID_POLICY, offlineValidUntil: new Date(Date.now() + 24 * 3_600_000).toISOString() };

async function grant(h, token = TOKENS.booth) {
    const response = await h.request("GET", "/v1/events/active", { token });
    return response.json;
}

function decode(grantValue) { return JSON.parse(Buffer.from(grantValue.payload, "base64").toString("utf8")); }

function record(payload, overrides = {}) {
    return {
        localId: `local-${Math.random().toString(36).slice(2)}`, localSequence: 1, snapshotId: payload.snapshotId, eventId: payload.eventId,
        policyRevisionId: payload.policyRevisionId, sessionId: `offline-${Math.random().toString(36).slice(2)}`, format: "solo", copies: 2,
        unitPriceCentavos: payload.unitPriceCentavos, totalCentavos: payload.unitPriceCentavos * 2, declaredAt: new Date().toISOString(), ...overrides
    };
}

const sync = (h, records, token = TOKENS.booth) => h.request("POST", "/v1/sync/offline-cash", { token, body: { records } });

test("active event carries an Ed25519-signed, device/account/event-bound offline policy", () => withHarness(async h => {
    await activePaidEvent(h, { policy: OFFLINE_POLICY });
    const body = await grant(h);
    assert.equal(body.offlinePolicyStatus, "issued");
    const { offlinePolicy } = body;
    const valid = await webcrypto.subtle.verify({ name: "Ed25519" }, h.signing.publicKey, Buffer.from(offlinePolicy.signature, "base64"), Buffer.from(offlinePolicy.payload, "base64"));
    assert.equal(valid, true);
    const payload = decode(offlinePolicy);
    assert.equal(payload.deviceId, "dev-booth");
    assert.equal(payload.accountId, "acct-a");
    assert.equal(payload.env, "test");
    assert.equal(payload.kid, "test-k1");
    assert.deepEqual(payload.paymentMethods, ["CASH_DECLARED"]);
    const windowMs = Date.parse(payload.expiresAt) - Date.parse(payload.issuedAt);
    assert.ok(windowMs <= 4 * 3_600_000 && windowMs > 3 * 3_600_000, "bounded by OFFLINE_MAX_WINDOW_SECONDS, not the operator's 24h limit");
    const tampered = Buffer.from(JSON.stringify({ ...payload, unitPriceCentavos: 1 }));
    assert.equal(await webcrypto.subtle.verify({ name: "Ed25519" }, h.signing.publicKey, Buffer.from(offlinePolicy.signature, "base64"), tampered), false);
    assert.equal((await grant(h)).offlinePolicy.snapshotId, payload.snapshotId, "reused while comfortably valid");
    assert.notEqual(decode((await grant(h, TOKENS.booth2)).offlinePolicy).snapshotId, payload.snapshotId, "each device gets its own snapshot");
}));

test("no signed offline policy without operator opt-in or signing key", () => withHarness({ bindings: { OFFLINE_POLICY_SIGNING_KEY: "" } }, async h => {
    await activePaidEvent(h, { policy: OFFLINE_POLICY });
    const body = await grant(h);
    assert.equal(body.offlinePolicy, null);
    assert.equal(body.offlinePolicyStatus, "offline_signing_not_configured");
}));

test("offline cash not enabled when policy lacks offline validity", () => withHarness(async h => {
    await activePaidEvent(h);
    assert.equal((await grant(h)).offlinePolicyStatus, "offline_cash_not_enabled");
}));

test("valid offline declaration syncs once as unverified offline cash", () => withHarness(async h => {
    const event = await activePaidEvent(h, { policy: OFFLINE_POLICY });
    const payload = decode((await grant(h)).offlinePolicy);
    const item = record(payload);
    const first = await sync(h, [item]);
    assert.equal(first.json.results[0].result, "synced");
    const replay = await sync(h, [item]);
    assert.equal(replay.json.results[0].result, "duplicate");
    const concurrent = await Promise.all([sync(h, [item]), sync(h, [item])]);
    assert.ok(concurrent.every(r => r.json.results[0].result === "duplicate"));
    assert.equal((await h.one("SELECT COUNT(*) c FROM offline_cash_sync_records")).c, 1);
    const attempt = await h.one("SELECT a.state, e.authorization_source, e.state ent_state FROM payment_attempts a JOIN entitlements e ON e.order_id=a.order_id");
    assert.deepEqual(attempt, { state: "SELF_REPORTED_OFFLINE", authorization_source: "UNVERIFIED_CASH_DECLARED", ent_state: "CONSUMED" });
    const summary = await h.request("GET", `/v1/admin/events/${event.eventId}/summary`, { token: TOKENS.operator });
    assert.equal(summary.json.cashSelfReportedOfflineSyncedCentavos, 10_000);
    assert.equal(summary.json.verifiedQRPhTestCentavos, 0);
}));

for (const [name, overrides, reason] of [
    ["price mismatch", { unitPriceCentavos: 1, totalCentavos: 2 }, "price_mismatch"],
    ["total mismatch", { totalCentavos: 1 }, "total_mismatch"],
    ["copies above snapshot maximum", { copies: 6, totalCentavos: 30_000 }, "copies_out_of_bounds"],
    ["format not enabled", { format: "passport" }, "format_not_enabled"],
    ["unknown snapshot", { snapshotId: "forged-snapshot" }, "unknown_snapshot"],
    ["declared in the future", { declaredAt: new Date(Date.now() + 3_600_000).toISOString() }, "declared_in_future"],
    ["declared before issuance", { declaredAt: new Date(Date.now() - 3_600_000).toISOString() }, "outside_offline_validity"],
    ["malformed timestamp", { declaredAt: "yesterday" }, "invalid_declared_at"],
    ["event mismatch", { eventId: "another-event" }, "event_mismatch"],
    ["invalid sequence", { localSequence: 0 }, "invalid_local_sequence"]
]) {
    test(`offline declaration rejected and kept as conflict: ${name}`, () => withHarness(async h => {
        await activePaidEvent(h, { policy: OFFLINE_POLICY });
        const payload = decode((await grant(h)).offlinePolicy);
        const item = record(payload, overrides);
        const response = await sync(h, [item]);
        assert.equal(response.json.results[0].result, "conflict");
        assert.equal(response.json.results[0].reason, reason);
        assert.equal((await h.one("SELECT COUNT(*) c FROM orders")).c, 0, "no order/entitlement created");
        const again = await sync(h, [item]);
        assert.equal(again.json.results[0].duplicate, true, "conflicts are replay-safe");
        assert.equal((await h.one("SELECT COUNT(*) c FROM offline_cash_sync_conflicts")).c, 1);
    }));
}

test("snapshot is bound to the issuing device and account", () => withHarness(async h => {
    await activePaidEvent(h, { policy: OFFLINE_POLICY });
    const payload = decode((await grant(h)).offlinePolicy);
    assert.equal((await sync(h, [record(payload)], TOKENS.booth2)).json.results[0].reason, "unknown_snapshot");
    assert.equal((await sync(h, [record(payload)], TOKENS.otherAccount)).json.results[0].reason, "unknown_snapshot");
}));

test("duplicate local sequence and declaration limit fail closed", () => withHarness({ bindings: { OFFLINE_MAX_DECLARATIONS: "2" } }, async h => {
    await activePaidEvent(h, { policy: OFFLINE_POLICY });
    const payload = decode((await grant(h)).offlinePolicy);
    assert.equal((await sync(h, [record(payload, { localSequence: 1 })])).json.results[0].result, "synced");
    assert.equal((await sync(h, [record(payload, { localSequence: 1 })])).json.results[0].reason, "duplicate_local_sequence");
    assert.equal((await sync(h, [record(payload, { localSequence: 2 })])).json.results[0].result, "synced");
    assert.equal((await sync(h, [record(payload, { localSequence: 3 })])).json.results[0].reason, "declaration_limit_exceeded");
}));

test("pause revokes snapshots; later declarations sync but are flagged for review", () => withHarness(async h => {
    const event = await activePaidEvent(h, { policy: OFFLINE_POLICY });
    const payload = decode((await grant(h)).offlinePolicy);
    await h.request("POST", `/v1/admin/events/${event.eventId}/pause`, { token: TOKENS.operator, headers: { "if-match": String(event.version) } });
    const revoked = await h.one("SELECT revoked_at, revoked_reason FROM offline_policy_snapshots WHERE id=?", payload.snapshotId);
    assert.equal(revoked.revoked_reason, "EVENT_PAUSE");
    const later = new Date(Date.parse(revoked.revoked_at) + 1000).toISOString();
    const response = await sync(h, [record(payload, { declaredAt: later })]);
    assert.equal(response.json.results[0].result, "synced");
    assert.equal(response.json.results[0].reviewFlag, "DECLARED_AFTER_SERVER_REVOCATION");
    assert.equal((await grant(h)).offlinePolicy, null, "no new grant while paused");
}));

test("offline declaration for a session that also has an online checkout is a conflict", () => withHarness(async h => {
    const event = await activePaidEvent(h, { policy: OFFLINE_POLICY });
    const payload = decode((await grant(h)).offlinePolicy);
    const online = await newOrder(h, event);
    const response = await sync(h, [record(payload, { sessionId: online.session })]);
    assert.equal(response.json.results[0].reason, "session_has_online_checkout");
}));

test("sync batch size is bounded and invalid IDs never 500", () => withHarness(async h => {
    assert.equal((await sync(h, Array.from({ length: 51 }, () => ({})))).status, 422);
    const response = await sync(h, [{ localId: "../bad" }, null]);
    assert.equal(response.status, 200);
    assert.deepEqual(response.json.results.map(r => r.reason), ["invalid_local_id", "invalid_local_id"]);
}));
