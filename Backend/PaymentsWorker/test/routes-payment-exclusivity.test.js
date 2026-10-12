// Route + D1 tests for the single payment-method lock. Every test runs the real Worker in workerd
// against a freshly migrated D1 database; concurrent cases issue truly parallel HTTP requests.
import test from "node:test";
import assert from "node:assert/strict";
import { createHarness, activePaidEvent, newOrder, signedWebhook, paidEvent, TOKENS } from "./support/harness.js";

async function withHarness(options, body) {
    if (typeof options === "function") { body = options; options = {}; }
    const h = await createHarness(options);
    try { await body(h); } finally { await h.dispose(); }
}

async function ledger(h, orderId) {
    return {
        order: await h.one("SELECT * FROM orders WHERE id=?", orderId),
        attempts: await h.all("SELECT * FROM payment_attempts WHERE order_id=?", orderId),
        entitlements: await h.all("SELECT * FROM entitlements WHERE order_id=?", orderId)
    };
}

test("QR then cash: cash declaration is refused and creates no entitlement", () => withHarness(async h => {
    const event = await activePaidEvent(h);
    const { order } = await newOrder(h, event);
    assert.equal((await h.request("POST", `/v1/orders/${order.id}/qrph`)).status, 201);
    const cash = await h.request("POST", `/v1/orders/${order.id}/cash-declaration`);
    assert.equal(cash.status, 409);
    assert.equal(cash.json.error, "payment_method_locked");
    assert.equal(cash.json.lockedMethod, "QRPH");
    const state = await ledger(h, order.id);
    assert.equal(state.order.payment_method, "QRPH");
    assert.equal(state.attempts.length, 1);
    assert.equal(state.entitlements.length, 0);
}));

test("cash then QR: QR creation is refused before any provider call", () => withHarness(async h => {
    const event = await activePaidEvent(h);
    const { order } = await newOrder(h, event);
    const cash = await h.request("POST", `/v1/orders/${order.id}/cash-declaration`);
    assert.equal(cash.status, 200);
    assert.equal(cash.json.entitlement.authorizationSource, "UNVERIFIED_CASH_DECLARED");
    assert.equal(cash.json.attempt.verification, "UNVERIFIED_SELF_REPORTED");
    const qr = await h.request("POST", `/v1/orders/${order.id}/qrph`);
    assert.equal(qr.status, 409);
    assert.equal(qr.json.error, "payment_method_locked");
    assert.equal(h.provider.count("POST /payment_intents"), 0);
    assert.equal((await ledger(h, order.id)).attempts.length, 1);
}));

test("simultaneous cash and QR requests: exactly one method wins, never both", () => withHarness(async h => {
    const event = await activePaidEvent(h);
    for (let round = 0; round < 6; round++) {
        const { order } = await newOrder(h, event);
        const requests = [];
        for (let i = 0; i < 4; i++) {
            requests.push(h.request("POST", `/v1/orders/${order.id}/cash-declaration`));
            requests.push(h.request("POST", `/v1/orders/${order.id}/qrph`));
        }
        const responses = await Promise.all(requests);
        const state = await ledger(h, order.id);
        assert.equal(state.attempts.length, 1, "one payment attempt per order");
        assert.equal(state.attempts[0].method, state.order.payment_method);
        if (state.order.payment_method === "CASH_DECLARED") {
            assert.equal(state.entitlements.length, 1);
            assert.ok(responses.filter((_, i) => i % 2 === 1).every(r => r.status === 409), "every QR request refused");
        } else {
            assert.equal(state.entitlements.length, 0, "QR has not been paid; no entitlement");
            assert.ok(responses.filter((_, i) => i % 2 === 0).every(r => r.status === 409), "every cash request refused");
        }
    }
}));

test("repeated concurrent QR creation creates one provider intent and one attempt", () => withHarness(async h => {
    const event = await activePaidEvent(h);
    const { order } = await newOrder(h, event);
    const responses = await Promise.all(Array.from({ length: 6 }, () => h.request("POST", `/v1/orders/${order.id}/qrph`)));
    assert.equal(h.provider.count("POST /payment_intents"), 1);
    assert.equal((await ledger(h, order.id)).attempts.length, 1);
    assert.equal(responses.filter(r => r.status === 201).length, 1);
    for (const response of responses.filter(r => r.status !== 201)) assert.ok([200, 409].includes(response.status));
    const replay = await h.request("POST", `/v1/orders/${order.id}/qrph`);
    assert.equal(replay.status, 200);
    assert.equal(replay.json.replay, true);
}));

test("QR creation uses the configured provider expiry and returns the same local lifetime", () => withHarness(async h => {
    const event = await activePaidEvent(h);
    const { order } = await newOrder(h, event);
    const before = Date.now();
    const response = await h.request("POST", `/v1/orders/${order.id}/qrph`);
    const paymentMethodCall = h.provider.calls.find(call => call.route === "POST /payment_methods");

    assert.equal(response.status, 201);
    assert.equal(paymentMethodCall.body.data.attributes.type, "qrph");
    assert.equal(paymentMethodCall.body.data.attributes.expiry_seconds, 300);
    assert.equal(response.json.attempt.testURL, `https://test.paymongo.example/${h.provider.intents.keys().next().value}`);
    const localLifetime = Date.parse(response.json.attempt.expiresAt) - before;
    assert.ok(localLifetime > 295_000 && localLifetime <= 301_000, `unexpected local QR lifetime: ${localLifetime}`);
}));

test("repeated cash taps are idempotent and authorize one entitlement", () => withHarness(async h => {
    const event = await activePaidEvent(h);
    const { order } = await newOrder(h, event);
    const responses = await Promise.all(Array.from({ length: 8 }, () => h.request("POST", `/v1/orders/${order.id}/cash-declaration`)));
    assert.ok(responses.every(r => r.status === 200));
    const state = await ledger(h, order.id);
    assert.equal(state.entitlements.length, 1);
    assert.equal(state.attempts.length, 1);
    assert.equal(new Set(responses.map(r => r.json.entitlement.id)).size, 1);
}));

test("DB triggers reject a second attempt or a method change even if route code were bypassed", () => withHarness(async h => {
    const event = await activePaidEvent(h);
    const { order } = await newOrder(h, event);
    await h.request("POST", `/v1/orders/${order.id}/qrph`);
    const now = new Date().toISOString();
    await assert.rejects(h.db.prepare("INSERT INTO payment_attempts(id,order_id,method,livemode,state,created_at,updated_at) VALUES('x',?,'CASH_DECLARED',0,'SELF_REPORTED',?,?)").bind(order.id, now, now).run(), /payment_method_(locked|mismatch)/);
    await assert.rejects(h.db.prepare("INSERT INTO payment_attempts(id,order_id,method,livemode,state,created_at,updated_at) VALUES('y',?,'QRPH',0,'CREATING',?,?)").bind(order.id, now, now).run(), /payment_method_locked/);
    await assert.rejects(h.db.prepare("UPDATE orders SET payment_method='CASH_DECLARED' WHERE id=?").bind(order.id).run(), /payment_method_immutable/);
    await assert.rejects(h.db.prepare("INSERT INTO entitlements(id,order_id,device_id,purchased_copies,authorization_source,state,created_at,updated_at) VALUES('e',?,'dev-booth',2,'UNVERIFIED_CASH_DECLARED','AUTHORIZED',?,?)").bind(order.id, now, now).run(), /entitlement_without_payment/);
    await assert.rejects(h.db.prepare("UPDATE orders SET total_centavos=1 WHERE id=?").bind(order.id).run(), /order_snapshot_immutable/);
}));

test("provider timeout during attach leaves QR UNKNOWN; cash and new checkout are refused; late paid reconciles to the original order", () => withHarness(async h => {
    const event = await activePaidEvent(h);
    const { order, session } = await newOrder(h, event);
    h.provider.fault(/attach$/, "network");
    const qr = await h.request("POST", `/v1/orders/${order.id}/qrph`);
    assert.equal(qr.status, 503);
    assert.equal(qr.json.error, "qr_status_unknown");
    let state = await ledger(h, order.id);
    assert.equal(state.attempts[0].state, "UNKNOWN_RECONCILIATION");
    assert.ok(state.attempts[0].provider_payment_intent_id);

    const cash = await h.request("POST", `/v1/orders/${order.id}/cash-declaration`);
    assert.equal(cash.status, 409);
    assert.equal(cash.json.error, "payment_method_locked");
    const replacement = await newOrder(h, event, { session, key: `${session}-retry`, supersedesOrderId: order.id });
    assert.equal(replacement.status, 409);
    assert.equal(replacement.json.error, "previous_payment_unresolved");
    const status = await h.request("GET", `/v1/orders/${order.id}/status`);
    assert.deepEqual(status.json.newCheckout, { allowed: false, reason: "qr_payment_unresolved" });

    // The guest's payment eventually lands; reconciliation credits the original order only.
    h.provider.markPaid(state.attempts[0].provider_payment_intent_id);
    const run = await h.scheduled();
    assert.equal(run.outcome, "ok");
    state = await ledger(h, order.id);
    assert.equal(state.attempts[0].state, "PAID_VERIFIED");
    assert.equal(state.entitlements.length, 1);
    assert.equal(state.entitlements[0].authorization_source, "VERIFIED_QRPH");
    assert.equal(h.provider.count("POST /payment_intents"), 1, "no second charge was created");
}));

test("a real provider timeout (abort) is treated as ambiguous, not as a failure", () => withHarness({ bindings: { PROVIDER_TIMEOUT_MS: "150" } }, async h => {
    const event = await activePaidEvent(h);
    const { order } = await newOrder(h, event);
    h.provider.fault(/attach$/, { delayMs: 600, json: {} });
    const qr = await h.request("POST", `/v1/orders/${order.id}/qrph`);
    assert.equal(qr.status, 503);
    assert.equal(qr.json.error, "qr_status_unknown");
    assert.equal((await ledger(h, order.id)).attempts[0].state, "UNKNOWN_RECONCILIATION");
}));

test("definitive provider rejection before a QR exists allows a deliberate new checkout, keeping history", () => withHarness(async h => {
    const event = await activePaidEvent(h);
    const { order, session } = await newOrder(h, event);
    h.provider.fault(/^POST \/payment_intents$/, 400);
    const qr = await h.request("POST", `/v1/orders/${order.id}/qrph`);
    assert.equal(qr.status, 502);
    assert.equal(qr.json.error, "qr_create_failed");
    assert.doesNotMatch(qr.text, /sk_test_/);
    assert.equal((await ledger(h, order.id)).attempts[0].state, "CREATE_FAILED_NO_QR");

    const retryOnSameOrder = await h.request("POST", `/v1/orders/${order.id}/cash-declaration`);
    assert.equal(retryOnSameOrder.status, 409, "the failed order stays locked to QR");
    const replacement = await newOrder(h, event, { session, key: `${session}-2`, supersedesOrderId: order.id });
    assert.equal(replacement.status, 201);
    assert.equal(replacement.order.supersedesOrderId, order.id);
    const cash = await h.request("POST", `/v1/orders/${replacement.order.id}/cash-declaration`);
    assert.equal(cash.status, 200);
    const old = await ledger(h, order.id);
    assert.equal(old.order.state, "SUPERSEDED");
    assert.equal(old.order.superseded_by_order_id, replacement.order.id);
    assert.equal(old.attempts.length, 1, "old attempt history retained");
}));

test("an expired QR can be superseded only after the code's expiry plus grace", () => withHarness(async h => {
    const event = await activePaidEvent(h);
    const { order, session } = await newOrder(h, event);
    await h.request("POST", `/v1/orders/${order.id}/qrph`);
    await h.db.prepare("UPDATE payment_attempts SET state='QR_EXPIRED_CONFIRMED' WHERE order_id=?").bind(order.id).run();
    const early = await newOrder(h, event, { session, key: `${session}-early`, supersedesOrderId: order.id });
    assert.equal(early.status, 409);
    assert.equal(early.json.error, "previous_payment_unresolved");
    await h.db.prepare("UPDATE payment_attempts SET expires_at=? WHERE order_id=?").bind(new Date(Date.now() - 120_000).toISOString(), order.id).run();
    const later = await newOrder(h, event, { session, key: `${session}-late`, supersedesOrderId: order.id });
    assert.equal(later.status, 201);
}));

test("late paid evidence on a superseded order is held for review, never auto-authorized", () => withHarness(async h => {
    const event = await activePaidEvent(h);
    const { order, session } = await newOrder(h, event);
    await h.request("POST", `/v1/orders/${order.id}/qrph`);
    const intentId = (await ledger(h, order.id)).attempts[0].provider_payment_intent_id;
    await h.db.prepare("UPDATE payment_attempts SET state='QR_EXPIRED_CONFIRMED',expires_at=? WHERE order_id=?").bind(new Date(Date.now() - 120_000).toISOString(), order.id).run();
    const replacement = await newOrder(h, event, { session, key: `${session}-b`, supersedesOrderId: order.id });
    assert.equal((await h.request("POST", `/v1/orders/${replacement.order.id}/cash-declaration`)).status, 200);

    h.provider.markPaid(intentId);
    const hook = await signedWebhook(h, paidEvent(intentId, order.totalCentavos));
    assert.equal(hook.status, 200);
    const old = await ledger(h, order.id);
    assert.equal(old.attempts[0].state, "PAID_VERIFIED");
    assert.equal(old.order.state, "LATE_PAID_REVIEW");
    assert.equal(old.entitlements[0].state, "REVIEW_REQUIRED");
    const claim = await h.request("POST", `/v1/entitlements/${old.entitlements[0].id}/claim`, { body: { sessionId: session, idempotencyKey: "c1" } });
    assert.equal(claim.status, 409);
    assert.equal(claim.json.error, "entitlement_under_review");
    const summary = await h.request("GET", `/v1/admin/events/${event.eventId}/summary`, { token: TOKENS.operator });
    assert.equal(summary.json.lateQRPaidReviewCentavos, order.totalCentavos);
    assert.equal(summary.json.verifiedQRPhTestCentavos, 0, "late payment is not counted as normal verified revenue");
    assert.equal(summary.json.reviewOrderCount, 1);
}));

test("one open checkout per session; a second order needs an explicit, conclusive supersede", () => withHarness(async h => {
    const event = await activePaidEvent(h);
    const first = await newOrder(h, event);
    const second = await newOrder(h, event, { session: first.session, key: `${first.session}-other` });
    assert.equal(second.status, 409);
    assert.equal(second.json.error, "checkout_already_open");
    assert.equal(second.json.openOrder.id, first.order.id);
    const unlocked = await newOrder(h, event, { session: first.session, key: `${first.session}-replace`, supersedesOrderId: first.order.id });
    assert.equal(unlocked.status, 201, "an order with no chosen method may be replaced");
    const cashOnOld = await h.request("POST", `/v1/orders/${first.order.id}/cash-declaration`);
    assert.equal(cashOnOld.status, 409);
    assert.equal(cashOnOld.json.error, "order_superseded");
}));

test("supersede referencing another session's order is refused and inserts nothing", () => withHarness(async h => {
    const event = await activePaidEvent(h);
    const a = await newOrder(h, event);
    const b = await newOrder(h, event, { supersedesOrderId: a.order.id });
    assert.equal(b.status, 409);
    assert.equal((await h.one("SELECT COUNT(*) c FROM orders")).c, 1);
}));

test("idempotent order creation under concurrency and mismatch detection", () => withHarness(async h => {
    const event = await activePaidEvent(h);
    const responses = await Promise.all(Array.from({ length: 6 }, () => newOrder(h, event, { session: "s-idem", key: "idem-1" })));
    assert.equal(new Set(responses.map(r => r.order.id)).size, 1);
    assert.equal((await h.one("SELECT COUNT(*) c FROM orders")).c, 1);
    const mismatch = await newOrder(h, event, { session: "s-idem", key: "idem-1", copies: 3 });
    assert.equal(mismatch.status, 422);
    assert.equal(mismatch.json.error, "idempotency_mismatch");
}));

test("stale event price: order creation refuses a policy the guest was not shown", () => withHarness(async h => {
    const event = await activePaidEvent(h);
    const draft = await h.request("PATCH", `/v1/admin/events/${event.eventId}`, { token: TOKENS.operator, headers: { "if-match": String(event.version) }, body: { policy: { ...(await import("./support/harness.js")).PAID_POLICY, unitPriceCentavos: 7_500 } } });
    const publish = await h.request("POST", `/v1/admin/events/${event.eventId}/publish`, { token: TOKENS.operator, headers: { "if-match": String(draft.json.version) }, body: { policyRevisionId: draft.json.draftRevision.id, acknowledgedUnitPriceCentavos: 7_500 } });
    assert.equal(publish.status, 200);
    const stale = await newOrder(h, event);
    assert.equal(stale.status, 409);
    assert.equal(stale.json.error, "policy_changed");
    assert.equal(stale.json.currentPolicy.unitPriceCentavos, 7_500);
    const fresh = await newOrder(h, { ...event, revisionId: draft.json.draftRevision.id, unitPriceCentavos: 7_500 });
    assert.equal(fresh.status, 201);
    assert.equal(fresh.order.totalCentavos, 15_000);
}));

test("an order keeps its original price snapshot after a new revision is published", () => withHarness(async h => {
    const { PAID_POLICY } = await import("./support/harness.js");
    const event = await activePaidEvent(h);
    const { order } = await newOrder(h, event);
    const draft = await h.request("PATCH", `/v1/admin/events/${event.eventId}`, { token: TOKENS.operator, headers: { "if-match": String(event.version) }, body: { policy: { ...PAID_POLICY, unitPriceCentavos: 9_900 } } });
    await h.request("POST", `/v1/admin/events/${event.eventId}/publish`, { token: TOKENS.operator, headers: { "if-match": String(draft.json.version) }, body: { policyRevisionId: draft.json.draftRevision.id, acknowledgedUnitPriceCentavos: 9_900 } });
    const cash = await h.request("POST", `/v1/orders/${order.id}/cash-declaration`);
    assert.equal(cash.status, 200);
    assert.equal(cash.json.order.totalCentavos, 10_000);
    assert.equal(cash.json.entitlement.unitPriceCentavos, 5_000);
}));

test("payment cannot start after the event is paused or the order expired", () => withHarness(async h => {
    const event = await activePaidEvent(h);
    const a = await newOrder(h, event);
    await h.db.prepare("UPDATE orders SET expires_at=? WHERE id=?").bind(new Date(Date.now() - 1000).toISOString(), a.order.id).run();
    const expired = await h.request("POST", `/v1/orders/${a.order.id}/cash-declaration`);
    assert.equal(expired.json.error, "order_expired");
    const b = await newOrder(h, event);
    await h.request("POST", `/v1/admin/events/${event.eventId}/pause`, { token: TOKENS.operator, headers: { "if-match": String(event.version) } });
    assert.equal((await h.request("POST", `/v1/orders/${b.order.id}/qrph`)).status, 409);
    assert.equal((await h.request("POST", `/v1/orders/${b.order.id}/cash-declaration`)).status, 409);
    assert.equal(h.provider.count("POST /payment_intents"), 0);
}));

test("orders are device-scoped: another booth cannot pay, read or claim them", () => withHarness(async h => {
    const event = await activePaidEvent(h);
    const { order } = await newOrder(h, event);
    for (const [method, route] of [["POST", "qrph"], ["POST", "cash-declaration"], ["GET", "status"]]) {
        assert.equal((await h.request(method, `/v1/orders/${order.id}/${route}`, { token: TOKENS.booth2 })).status, 404);
    }
    const other = await h.request("POST", "/v1/orders", { token: TOKENS.otherAccount, headers: { "idempotency-key": "x1" }, body: { eventId: event.eventId, format: "solo", copies: 1, checkoutSessionId: "x", expectedPolicyRevisionId: event.revisionId, expectedUnitPriceCentavos: 5000 } });
    assert.equal(other.status, 409, "other account cannot see this account's event");
}));
