// Phase 4 route + D1 tests: crash recovery lookup, audited recovery claims, durable print-outbox
// replay semantics (DELIVERED / UNCERTAIN), and migration 0005 data preservation.
import test from "node:test";
import assert from "node:assert/strict";
import { createHarness, activePaidEvent, newOrder, signedWebhook, paidEvent, applyMigrations, TOKENS } from "./support/harness.js";

async function withHarness(options, body) {
    if (typeof options === "function") { body = options; options = {}; }
    const h = await createHarness(options);
    try { await body(h); } finally { await h.dispose(); }
}

async function paidQR(h, event, options) {
    const created = await newOrder(h, event, options);
    await h.request("POST", `/v1/orders/${created.order.id}/qrph`);
    const intentId = (await h.one("SELECT provider_payment_intent_id id FROM payment_attempts WHERE order_id=?", created.order.id)).id;
    h.provider.markPaid(intentId);
    await signedWebhook(h, paidEvent(intentId, created.order.totalCentavos));
    return created;
}

const FP = "f".repeat(64);
const print = (h, batchId, body) => h.request("POST", `/v1/prints/${batchId}/progress`, { body: { transport: "bluetooth", ...body } });

test("crash before the order ID reached the iPad: the checkout is found by session, not recreated", () => withHarness(async h => {
    const event = await activePaidEvent(h);
    const { order, session } = await paidQR(h, event);
    const view = await h.request("GET", `/v1/checkouts/${session}`);
    assert.equal(view.status, 200);
    assert.equal(view.json.orders.length, 1);
    assert.equal(view.json.openOrderId, order.id);
    assert.equal(view.json.orders[0].attempt.state, "PAID_VERIFIED");
    assert.equal(view.json.orders[0].entitlement.state, "AUTHORIZED");
    assert.deepEqual(view.json.orders[0].printOutcomes, []);
    assert.equal((await h.one("SELECT COUNT(*) c FROM orders")).c, 1, "lookup never creates an order");
    assert.equal(h.provider.count("POST /payment_intents"), 1, "lookup never creates a charge");
    assert.doesNotMatch(view.text, /data:image|qrImage":"data/);
}));

test("recovery lookup is device- and account-scoped and returns nothing for unknown sessions", () => withHarness(async h => {
    const event = await activePaidEvent(h);
    const { session } = await paidQR(h, event);
    assert.deepEqual((await h.request("GET", `/v1/checkouts/${session}`, { token: TOKENS.booth2 })).json.orders, []);
    assert.deepEqual((await h.request("GET", `/v1/checkouts/${session}`, { token: TOKENS.otherAccount })).json.orders, []);
    assert.equal((await h.request("GET", `/v1/checkouts/${session}`, { token: TOKENS.operator })).status, 403, "booth scope required");
    assert.equal((await h.request("GET", "/v1/checkouts/PP-never")).json.openOrderId, null);
    assert.equal((await h.request("GET", "/v1/checkouts/..%2F..")).status, 400);
}));

test("recovery lookup shows the full supersede history of one session", () => withHarness(async h => {
    const event = await activePaidEvent(h);
    const first = await newOrder(h, event);
    h.provider.fault(/^POST \/payment_intents$/, 400);
    await h.request("POST", `/v1/orders/${first.order.id}/qrph`);
    const second = await newOrder(h, event, { session: first.session, key: `${first.session}-1`, supersedesOrderId: first.order.id });
    await h.request("POST", `/v1/orders/${second.order.id}/cash-declaration`);
    const view = await h.request("GET", `/v1/checkouts/${first.session}`);
    assert.deepEqual(view.json.orders.map(o => o.order.state), ["SUPERSEDED", "AUTHORIZED"]);
    assert.equal(view.json.openOrderId, second.order.id);
    assert.equal(view.json.orders[1].attempt.verification, "UNVERIFIED_SELF_REPORTED", "cash stays unverified in recovery");
}));

test("recovery claim of the original session is idempotent, audited, and cannot rebind to another session", () => withHarness(async h => {
    const event = await activePaidEvent(h);
    const { session } = await paidQR(h, event);
    const entitlementId = (await h.request("GET", `/v1/checkouts/${session}`)).json.orders[0].entitlement.id;
    const resumed = await h.request("POST", `/v1/entitlements/${entitlementId}/claim`, { body: { sessionId: session, idempotencyKey: "claim-r1", recovery: true } });
    assert.equal(resumed.status, 200);
    const again = await h.request("POST", `/v1/entitlements/${entitlementId}/claim`, { body: { sessionId: session, idempotencyKey: "claim-r2", recovery: true } });
    assert.equal(again.json.replay, true);
    const audits = await h.all("SELECT action FROM operator_audit_log WHERE action='ENTITLEMENT_RECOVERY_CLAIM'");
    assert.equal(audits.length, 2);
    const other = await h.request("POST", `/v1/entitlements/${entitlementId}/claim`, { body: { sessionId: "PP-other-guest", idempotencyKey: "x", recovery: true } });
    assert.equal(other.status, 409);
    assert.equal(other.json.error, "entitlement_session_mismatch");
}));

test("a paid entitlement survives pause and end and is still recoverable for its original session", () => withHarness(async h => {
    const event = await activePaidEvent(h);
    const { session } = await paidQR(h, event);
    const paused = await h.request("POST", `/v1/admin/events/${event.eventId}/pause`, { token: TOKENS.operator, headers: { "if-match": String(event.version) } });
    await h.request("POST", `/v1/admin/events/${event.eventId}/end`, { token: TOKENS.operator, headers: { "if-match": String(paused.json.version) } });
    const view = await h.request("GET", `/v1/checkouts/${session}`);
    const entitlement = view.json.orders[0].entitlement;
    assert.equal(entitlement.state, "AUTHORIZED");
    assert.equal((await h.request("POST", `/v1/entitlements/${entitlement.id}/claim`, { body: { sessionId: session, idempotencyKey: "k", recovery: true } })).status, 200);
    const outstanding = await h.request("GET", `/v1/admin/events/${event.eventId}/orders?filter=outstanding`, { token: TOKENS.operator });
    assert.equal(outstanding.json.orders.length, 1, "operator can list outstanding paid entitlements");
}));

test("print outbox replay: DELIVERED and UNCERTAIN accepted once, exact replays succeed, conflicts refused", () => withHarness(async h => {
    const event = await activePaidEvent(h);
    const { session } = await paidQR(h, event, { copies: 3 });
    const entitlementId = (await h.request("GET", `/v1/checkouts/${session}`)).json.orders[0].entitlement.id;
    await h.request("POST", `/v1/entitlements/${entitlementId}/claim`, { body: { sessionId: session, idempotencyKey: "c" } });
    const base = { entitlementId, sessionId: session, receiptFingerprint: FP };
    const copy1 = { ...base, copyIndex: 1, outcome: "DELIVERED", idempotencyKey: "print-b1-1" };
    // App sent, server committed, app crashed before the local ACK: the replay must succeed.
    assert.equal((await print(h, "b1", copy1)).json.replay, false);
    assert.equal((await print(h, "b1", copy1)).json.replay, true);
    const concurrent = await Promise.all([print(h, "b1", copy1), print(h, "b1", copy1), print(h, "b1", copy1)]);
    assert.ok(concurrent.every(r => r.status === 200));
    // Copy 2 was in flight when the app was killed: recorded once as UNCERTAIN.
    assert.equal((await print(h, "b1", { ...base, copyIndex: 2, outcome: "UNCERTAIN", idempotencyKey: "print-b1-2" })).status, 200);
    // A later attempt to upgrade the ambiguous copy is refused, never silently accepted.
    const upgrade = await print(h, "b1", { ...base, copyIndex: 2, outcome: "DELIVERED", idempotencyKey: "print-b1-2-retry" });
    assert.equal(upgrade.status, 409);
    assert.equal(upgrade.json.recordedOutcome, "UNCERTAIN");
    // A retry after relaunch must reuse the batch; a new batch for the same entitlement is refused.
    assert.equal((await print(h, "b2", { ...base, copyIndex: 3, outcome: "DELIVERED", idempotencyKey: "print-b2-3" })).json.error, "print_batch_conflict");
    assert.equal((await print(h, "b1", { ...base, copyIndex: 3, outcome: "DELIVERED", idempotencyKey: "print-b1-3" })).status, 200);
    assert.deepEqual((await h.request("GET", `/v1/checkouts/${session}`)).json.orders[0].printOutcomes,
        [{ copy_index: 1, outcome: "DELIVERED" }, { copy_index: 2, outcome: "UNCERTAIN" }, { copy_index: 3, outcome: "DELIVERED" }]);
    const done = await h.request("POST", `/v1/entitlements/${entitlementId}/complete`, { body: { sessionId: session } });
    assert.equal(done.status, 200);
    assert.equal((await h.request("POST", `/v1/entitlements/${entitlementId}/complete`, { body: { sessionId: session } })).status, 200, "completion replay is idempotent");
    const summary = await h.request("GET", `/v1/admin/events/${event.eventId}/summary`, { token: TOKENS.operator });
    assert.deepEqual(summary.json.printUtilization, { purchased: 3, confirmed: 0, delivered: 2, uncertain: 1, failed: 0, notStarted: 0 });
    assert.equal((await print(h, "b1", { ...base, copyIndex: 4, outcome: "DELIVERED", idempotencyKey: "print-b1-4" })).status, 422, "no copy beyond the paid quantity");
}));

test("late outcome reports after completion are still accepted for the existing batch", () => withHarness(async h => {
    const event = await activePaidEvent(h);
    const { session } = await paidQR(h, event, { copies: 2 });
    const entitlementId = (await h.request("GET", `/v1/checkouts/${session}`)).json.orders[0].entitlement.id;
    await h.request("POST", `/v1/entitlements/${entitlementId}/claim`, { body: { sessionId: session, idempotencyKey: "c" } });
    const base = { entitlementId, sessionId: session, receiptFingerprint: FP };
    await print(h, "b1", { ...base, copyIndex: 1, outcome: "DELIVERED", idempotencyKey: "p1" });
    await h.request("POST", `/v1/entitlements/${entitlementId}/complete`, { body: { sessionId: session } });
    // Outbox delivers copy 2's outcome only after reconnecting.
    assert.equal((await print(h, "b1", { ...base, copyIndex: 2, outcome: "DELIVERED", idempotencyKey: "p2" })).status, 200);
}));

test("migration 0005 rebuilds print outcomes without losing rows and keeps them append-only", async () => {
    const h = await createHarness({ migrateUpTo: 4 });
    try {
        const event = await activePaidEvent(h);
        const { session } = await paidQR(h, event, { copies: 2 });
        const entitlementId = (await h.one("SELECT id FROM entitlements")).id;
        await h.request("POST", `/v1/entitlements/${entitlementId}/claim`, { body: { sessionId: session, idempotencyKey: "c" } });
        await print(h, "b1", { entitlementId, sessionId: session, receiptFingerprint: FP, copyIndex: 1, outcome: "CONFIRMED", idempotencyKey: "legacy-1" });
        await print(h, "b1", { entitlementId, sessionId: session, receiptFingerprint: FP, copyIndex: 2, outcome: "UNCERTAIN", idempotencyKey: "legacy-2" });
        const before = await h.all("SELECT id, batch_id, copy_index, outcome, transport, idempotency_key, created_at FROM print_copy_outcomes ORDER BY copy_index");
        await assert.rejects(h.db.prepare("INSERT INTO print_copy_outcomes(id,batch_id,copy_index,outcome,transport,idempotency_key,created_at) VALUES('x','b1',3,'DELIVERED','t','k3','t')").run(), /CHECK constraint/);
        await applyMigrations(h.db, ["0005_phase4_print_delivery.sql"]);
        assert.deepEqual(await h.all("SELECT id, batch_id, copy_index, outcome, transport, idempotency_key, created_at FROM print_copy_outcomes ORDER BY copy_index"), before);
        await assert.rejects(h.db.prepare("UPDATE print_copy_outcomes SET outcome='DELIVERED'").run(), /print_outcome_append_only/);
        await assert.rejects(h.db.prepare("DELETE FROM print_copy_outcomes").run(), /print_outcome_append_only/);
        await assert.rejects(h.db.prepare("INSERT INTO print_copy_outcomes(id,batch_id,copy_index,outcome,transport,idempotency_key,created_at) VALUES('y','b1',1,'DELIVERED','t','dup','t')").run(), /UNIQUE/);
        assert.equal((await h.all("PRAGMA foreign_key_check")).length, 0);
    } finally { await h.dispose(); }
});
