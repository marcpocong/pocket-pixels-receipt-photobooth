// Entitlement claim and print-record tests through the real Worker and D1.
import test from "node:test";
import assert from "node:assert/strict";
import { createHarness, activePaidEvent, newOrder, TOKENS } from "./support/harness.js";

async function withHarness(body) {
    const h = await createHarness();
    try { await body(h); } finally { await h.dispose(); }
}

async function cashEntitlement(h, event, options) {
    const created = await newOrder(h, event, options);
    const cash = await h.request("POST", `/v1/orders/${created.order.id}/cash-declaration`);
    return { ...created, entitlement: cash.json.entitlement };
}

const FP = "a".repeat(64), FP2 = "b".repeat(64);
const print = (h, batchId, body, token) => h.request("POST", `/v1/prints/${batchId}/progress`, { token, body: { transport: "bluetooth", ...body } });

test("claim binds one session; the same session replays; another session is refused", () => withHarness(async h => {
    const event = await activePaidEvent(h);
    const { entitlement, session } = await cashEntitlement(h, event);
    const first = await h.request("POST", `/v1/entitlements/${entitlement.id}/claim`, { body: { sessionId: session, idempotencyKey: "k1" } });
    assert.equal(first.status, 200);
    assert.equal(first.json.entitlement.state, "IN_SESSION");
    const replay = await h.request("POST", `/v1/entitlements/${entitlement.id}/claim`, { body: { sessionId: session, idempotencyKey: "k2" } });
    assert.equal(replay.status, 200);
    assert.equal(replay.json.replay, true);
    const other = await h.request("POST", `/v1/entitlements/${entitlement.id}/claim`, { body: { sessionId: "different-session", idempotencyKey: "k3" } });
    assert.equal(other.status, 409);
    assert.equal(other.json.error, "entitlement_session_mismatch");
}));

test("concurrent claims from differing sessions: exactly one binds", () => withHarness(async h => {
    const event = await activePaidEvent(h);
    const { entitlement } = await cashEntitlement(h, event);
    // Legacy-style entitlement without a checkout session, so only the SQL guard decides.
    await h.db.prepare("UPDATE orders SET state=state WHERE id=?").bind(entitlement.orderId).run();
    const order = await h.one("SELECT * FROM orders WHERE id=?", entitlement.orderId);
    assert.ok(order.checkout_session_id);
    const sessions = [order.checkout_session_id, order.checkout_session_id, "intruder-1", "intruder-2"];
    const responses = await Promise.all(sessions.map((sessionId, i) => h.request("POST", `/v1/entitlements/${entitlement.id}/claim`, { body: { sessionId, idempotencyKey: `c${i}` } })));
    assert.deepEqual(responses.map(r => r.status), [200, 200, 409, 409]);
    assert.equal((await h.one("SELECT session_id FROM entitlements WHERE id=?", entitlement.id)).session_id, order.checkout_session_id);
}));

test("claim is device-scoped and cannot reuse a consumed entitlement", () => withHarness(async h => {
    const event = await activePaidEvent(h);
    const { entitlement, session } = await cashEntitlement(h, event);
    assert.equal((await h.request("POST", `/v1/entitlements/${entitlement.id}/claim`, { token: TOKENS.booth2, body: { sessionId: session, idempotencyKey: "x" } })).status, 404);
    await h.request("POST", `/v1/entitlements/${entitlement.id}/claim`, { body: { sessionId: session, idempotencyKey: "k" } });
    const done = await h.request("POST", `/v1/entitlements/${entitlement.id}/complete`, { body: { sessionId: session } });
    assert.equal(done.status, 200);
    assert.equal(done.json.entitlement.state, "CONSUMED");
    assert.equal((await h.one("SELECT state FROM orders WHERE id=?", entitlement.orderId)).state, "COMPLETE");
    const again = await h.request("POST", `/v1/entitlements/${entitlement.id}/claim`, { body: { sessionId: session, idempotencyKey: "k" } });
    assert.equal(again.status, 409);
    assert.equal(again.json.error, "entitlement_consumed");
    assert.equal((await print(h, "batch-late", { entitlementId: entitlement.id, sessionId: session, receiptFingerprint: FP, copyIndex: 1, outcome: "CONFIRMED", idempotencyKey: "p1" })).status, 409, "no new receipt after completion");
}));

test("outstanding entitlement remains claimable after the event is paused and ended", () => withHarness(async h => {
    const event = await activePaidEvent(h);
    const { entitlement, session } = await cashEntitlement(h, event);
    const paused = await h.request("POST", `/v1/admin/events/${event.eventId}/pause`, { token: TOKENS.operator, headers: { "if-match": String(event.version) } });
    const ended = await h.request("POST", `/v1/admin/events/${event.eventId}/end`, { token: TOKENS.operator, headers: { "if-match": String(paused.json.version) } });
    assert.equal(ended.status, 200, "a PAUSED event can be ended");
    const detail = await h.request("GET", `/v1/admin/events/${event.eventId}`, { token: TOKENS.operator });
    assert.equal(detail.json.outstandingEntitlements, 1);
    const claim = await h.request("POST", `/v1/entitlements/${entitlement.id}/claim`, { body: { sessionId: session, idempotencyKey: "k" } });
    assert.equal(claim.status, 200);
    assert.equal((await newOrder(h, event)).status, 409, "no new checkout on an ended event");
}));

test("print records: one receipt per entitlement, copy bounds, replay and conflicts", () => withHarness(async h => {
    const event = await activePaidEvent(h);
    const { entitlement, session } = await cashEntitlement(h, event, { copies: 2 });
    const base = { entitlementId: entitlement.id, sessionId: session, receiptFingerprint: FP };
    assert.equal((await print(h, "batch-1", { ...base, copyIndex: 1, outcome: "CONFIRMED", idempotencyKey: "p1" })).status, 403, "must claim first");
    await h.request("POST", `/v1/entitlements/${entitlement.id}/claim`, { body: { sessionId: session, idempotencyKey: "k" } });

    const first = await print(h, "batch-1", { ...base, copyIndex: 1, outcome: "CONFIRMED", idempotencyKey: "p1" });
    assert.equal(first.status, 200);
    assert.equal(first.json.reprintAuthorized, false);
    const replay = await print(h, "batch-1", { ...base, copyIndex: 1, outcome: "CONFIRMED", idempotencyKey: "p1" });
    assert.equal(replay.json.replay, true);
    assert.equal((await print(h, "batch-1", { ...base, copyIndex: 1, outcome: "FAILED", idempotencyKey: "p1" })).json.error, "print_idempotency_conflict");
    const changed = await print(h, "batch-1", { ...base, copyIndex: 1, outcome: "FAILED", idempotencyKey: "p1b" });
    assert.equal(changed.status, 409);
    assert.equal(changed.json.error, "copy_outcome_conflict");
    assert.equal(changed.json.recordedOutcome, "CONFIRMED");
    assert.equal((await print(h, "batch-1", { ...base, copyIndex: 3, outcome: "CONFIRMED", idempotencyKey: "p3" })).status, 422, "copy beyond purchased quantity");
    assert.equal((await print(h, "batch-1", { ...base, receiptFingerprint: FP2, copyIndex: 2, outcome: "CONFIRMED", idempotencyKey: "p2" })).json.error, "print_batch_conflict", "fingerprint is bound");
    assert.equal((await print(h, "batch-2", { ...base, copyIndex: 2, outcome: "CONFIRMED", idempotencyKey: "p2x" })).json.error, "print_batch_conflict", "second batch for one entitlement refused");
    assert.equal((await print(h, "batch-1", { ...base, sessionId: "other", copyIndex: 2, outcome: "CONFIRMED", idempotencyKey: "p2y" })).status, 403);
    const uncertain = await print(h, "batch-1", { ...base, copyIndex: 2, outcome: "UNCERTAIN", idempotencyKey: "p2" });
    assert.equal(uncertain.status, 200);
    assert.equal(uncertain.json.reprintAuthorized, false, "ambiguous physical output never authorizes another copy");
    const rows = await h.all("SELECT copy_index,outcome FROM print_copy_outcomes ORDER BY copy_index");
    assert.deepEqual(rows, [{ copy_index: 1, outcome: "CONFIRMED" }, { copy_index: 2, outcome: "UNCERTAIN" }]);
    await assert.rejects(h.db.prepare("UPDATE print_copy_outcomes SET outcome='CONFIRMED' WHERE copy_index=2").run(), /print_outcome_append_only/);
    const summary = await h.request("GET", `/v1/admin/events/${event.eventId}/summary`, { token: TOKENS.operator });
    assert.deepEqual(summary.json.printUtilization, { purchased: 2, confirmed: 1, delivered: 0, uncertain: 1, failed: 0, notStarted: 0 });
}));

test("concurrent first print records with different fingerprints bind exactly one receipt", () => withHarness(async h => {
    const event = await activePaidEvent(h);
    const { entitlement, session } = await cashEntitlement(h, event, { copies: 3 });
    await h.request("POST", `/v1/entitlements/${entitlement.id}/claim`, { body: { sessionId: session, idempotencyKey: "k" } });
    const fingerprints = ["c", "d", "e"].map(ch => ch.repeat(64));
    const responses = await Promise.all(fingerprints.map((fp, i) => print(h, `batch-${i}`, { entitlementId: entitlement.id, sessionId: session, receiptFingerprint: fp, copyIndex: 1, outcome: "CONFIRMED", idempotencyKey: `p${i}` })));
    assert.equal(responses.filter(r => r.status === 200).length, 1);
    assert.equal((await h.one("SELECT COUNT(*) c FROM print_batches")).c, 1);
    assert.equal((await h.one("SELECT COUNT(*) c FROM print_copy_outcomes")).c, 1);
}));
