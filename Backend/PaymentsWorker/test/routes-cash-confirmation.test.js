// Route + D1 tests for attendant-confirmed cash. The confirmation route is operator-scoped: the
// booth app releases its operator credential only after local operator authentication.
import test from "node:test";
import assert from "node:assert/strict";
import { createHarness, activePaidEvent, newOrder, TOKENS, PAID_POLICY } from "./support/harness.js";

async function withHarness(body) {
    const h = await createHarness();
    try { await body(h); } finally { await h.dispose(); }
}

async function ledger(h, orderId) {
    return {
        order: await h.one("SELECT * FROM orders WHERE id=?", orderId),
        attempts: await h.all("SELECT * FROM payment_attempts WHERE order_id=?", orderId),
        entitlements: await h.all("SELECT * FROM entitlements WHERE order_id=?", orderId)
    };
}

const confirm = (h, order, { token = TOKENS.operator, total = order.totalCentavos } = {}) =>
    h.request("POST", `/v1/admin/orders/${order.id}/cash-confirmation`, { token, body: { expectedTotalCentavos: total } });

test("operator confirms cash: one entitlement for the booth, recorded as operator-confirmed", () => withHarness(async h => {
    const event = await activePaidEvent(h);
    const { order } = await newOrder(h, event);
    const response = await confirm(h, order);
    assert.equal(response.status, 200);
    assert.equal(response.json.attempt.verification, "OPERATOR_CONFIRMED");
    assert.equal(response.json.attempt.method, "CASH_DECLARED");
    assert.equal(response.json.entitlement.purchasedCopies, 2);
    assert.equal(response.json.entitlement.state, "AUTHORIZED");
    const state = await ledger(h, order.id);
    assert.equal(state.order.payment_method, "CASH_DECLARED");
    assert.equal(state.attempts[0].state, "OPERATOR_CONFIRMED");
    // The entitlement belongs to the booth that created the order, so the booth can claim it.
    assert.equal(state.entitlements[0].device_id, "dev-booth");
    const audit = await h.one("SELECT * FROM operator_audit_log WHERE order_id=? AND action='CASH_OPERATOR_CONFIRMED'", order.id);
    assert.equal(audit.actor_device_id, "dev-operator");
    // The booth sees the same verified provenance through its own status route and can claim.
    const status = await h.request("GET", `/v1/orders/${order.id}/status`);
    assert.equal(status.json.attempt.verification, "OPERATOR_CONFIRMED");
    const claim = await h.request("POST", `/v1/entitlements/${status.json.entitlement.id}/claim`, { headers: { "idempotency-key": "claim-1" }, body: { sessionId: order.checkoutSessionId, idempotencyKey: "claim-1" } });
    assert.equal(claim.status, 200);
}));

test("a booth-only credential cannot confirm cash", () => withHarness(async h => {
    const event = await activePaidEvent(h);
    const { order } = await newOrder(h, event, { token: TOKENS.boothOnly });
    const response = await confirm(h, order, { token: TOKENS.boothOnly });
    assert.equal(response.status, 403);
    assert.equal((await ledger(h, order.id)).entitlements.length, 0);
}));

test("another account's operator cannot confirm this account's order", () => withHarness(async h => {
    const event = await activePaidEvent(h);
    const { order } = await newOrder(h, event);
    const response = await confirm(h, order, { token: TOKENS.otherAccount });
    assert.equal(response.status, 404);
    assert.equal((await ledger(h, order.id)).attempts.length, 0);
}));

test("a mismatched or missing amount is refused and creates nothing", () => withHarness(async h => {
    const event = await activePaidEvent(h);
    const { order } = await newOrder(h, event);
    const wrong = await confirm(h, order, { total: order.totalCentavos - 100 });
    assert.equal(wrong.status, 409);
    assert.equal(wrong.json.error, "cash_amount_mismatch");
    const missing = await h.request("POST", `/v1/admin/orders/${order.id}/cash-confirmation`, { token: TOKENS.operator, body: {} });
    assert.equal(missing.status, 409);
    const state = await ledger(h, order.id);
    assert.equal(state.order.payment_method, null);
    assert.equal(state.attempts.length, 0);
}));

test("replayed and concurrent confirmations create exactly one entitlement", () => withHarness(async h => {
    const event = await activePaidEvent(h);
    const { order } = await newOrder(h, event);
    const responses = await Promise.all(Array.from({ length: 5 }, () => confirm(h, order)));
    assert.ok(responses.every(r => r.status === 200), responses.map(r => r.text).join("\n"));
    const ids = new Set(responses.map(r => r.json.entitlement.id));
    assert.equal(ids.size, 1);
    const state = await ledger(h, order.id);
    assert.equal(state.attempts.length, 1);
    assert.equal(state.entitlements.length, 1);
    assert.equal((await h.all("SELECT * FROM operator_audit_log WHERE order_id=? AND action='CASH_OPERATOR_CONFIRMED'", order.id)).length, 1);
}));

test("an order with a QR attempt can never be confirmed as cash", () => withHarness(async h => {
    const event = await activePaidEvent(h);
    const { order } = await newOrder(h, event);
    assert.equal((await h.request("POST", `/v1/orders/${order.id}/qrph`)).status, 201);
    const response = await confirm(h, order);
    assert.equal(response.status, 409);
    assert.equal(response.json.error, "payment_method_locked");
    assert.equal(response.json.lockedMethod, "QRPH");
    assert.equal((await ledger(h, order.id)).entitlements.length, 0);
}));

test("a confirmed cash order refuses QR creation before any provider call", () => withHarness(async h => {
    const event = await activePaidEvent(h);
    const { order } = await newOrder(h, event);
    assert.equal((await confirm(h, order)).status, 200);
    const qr = await h.request("POST", `/v1/orders/${order.id}/qrph`);
    assert.equal(qr.status, 409);
    assert.equal(h.provider.count("POST /payment_intents"), 0);
}));

test("a guest self-declared order is never relabelled as operator-confirmed", () => withHarness(async h => {
    const event = await activePaidEvent(h);
    const { order } = await newOrder(h, event);
    assert.equal((await h.request("POST", `/v1/orders/${order.id}/cash-declaration`)).status, 200);
    const response = await confirm(h, order);
    assert.equal(response.status, 409);
    assert.equal(response.json.attemptState, "SELF_REPORTED");
    assert.equal((await ledger(h, order.id)).attempts[0].state, "SELF_REPORTED");
}));

test("cash confirmation is refused when the event does not accept cash", () => withHarness(async h => {
    const event = await activePaidEvent(h, { policy: { ...PAID_POLICY, cashEnabled: false } });
    const { order } = await newOrder(h, event);
    const response = await confirm(h, order);
    assert.equal(response.status, 409);
    assert.equal(response.json.error, "cash_disabled");
}));

test("reports keep operator-confirmed cash separate from historical self-reported cash", () => withHarness(async h => {
    const event = await activePaidEvent(h);
    const first = await newOrder(h, event);
    const second = await newOrder(h, event, { copies: 1 });
    assert.equal((await h.request("POST", `/v1/orders/${first.order.id}/cash-declaration`)).status, 200);
    assert.equal((await confirm(h, second.order)).status, 200);
    const summary = await h.request("GET", `/v1/admin/events/${event.eventId}/summary`, { token: TOKENS.operator });
    assert.equal(summary.json.cashSelfReportedCentavos, 10_000);
    assert.equal(summary.json.cashOperatorConfirmedCentavos, 5_000);
    assert.equal(summary.json.verifiedQRPhTestCentavos, 0);
    assert.ok(summary.json.categories.includes("CASH_OPERATOR_CONFIRMED"));
    const orders = await h.request("GET", `/v1/admin/events/${event.eventId}/orders?filter=cash`, { token: TOKENS.operator });
    const categories = Object.fromEntries(orders.json.orders.map(row => [row.id, row.category]));
    assert.equal(categories[first.order.id], "CASH_SELF_REPORTED");
    assert.equal(categories[second.order.id], "CASH_OPERATOR_CONFIRMED");
    // A physical count is compared with all cash orders.
    await h.request("POST", `/v1/admin/events/${event.eventId}/cash-counts`, { token: TOKENS.operator, body: { countedCentavos: 15_000, reason: "close" } });
    const counted = await h.request("GET", `/v1/admin/events/${event.eventId}/summary`, { token: TOKENS.operator });
    assert.equal(counted.json.physicalCashCount.varianceCentavos, 0);
}));
