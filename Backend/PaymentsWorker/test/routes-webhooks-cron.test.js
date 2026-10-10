// Signed webhook and scheduled reconciliation tests through the real Worker and D1.
import test from "node:test";
import assert from "node:assert/strict";
import { createHarness, activePaidEvent, newOrder, signedWebhook, paidEvent, TOKENS, WEBHOOK_SECRET } from "./support/harness.js";

async function withHarness(options, body) {
    if (typeof options === "function") { body = options; options = {}; }
    const h = await createHarness(options);
    try { await body(h); } finally { await h.dispose(); }
}

async function qrOrder(h, event, options) {
    const created = await newOrder(h, event, options);
    await h.request("POST", `/v1/orders/${created.order.id}/qrph`);
    const attempt = await h.one("SELECT * FROM payment_attempts WHERE order_id=?", created.order.id);
    return { ...created, intentId: attempt.provider_payment_intent_id };
}

const entitlementCount = (h, orderId) => h.one("SELECT COUNT(*) c FROM entitlements WHERE order_id=?", orderId).then(r => r.c);

test("verified paid webhook authorizes exactly one entitlement after server-to-server confirmation", () => withHarness(async h => {
    const event = await activePaidEvent(h);
    const { order, intentId } = await qrOrder(h, event);
    h.provider.markPaid(intentId);
    const response = await signedWebhook(h, paidEvent(intentId, order.totalCentavos));
    assert.equal(response.status, 200);
    assert.equal(response.json.outcome, "PAID_VERIFIED");
    assert.equal(h.provider.count(`GET /payment_intents/${intentId}`), 1, "intent independently re-read");
    const status = await h.request("GET", `/v1/orders/${order.id}/status`);
    assert.equal(status.json.attempt.verification, "PROVIDER_VERIFIED");
    assert.equal(status.json.entitlement.authorizationSource, "VERIFIED_QRPH");
    assert.equal(status.json.entitlement.purchasedCopies, 2);
}));

test("paid webhook whose intent the provider does not confirm creates no entitlement and defers", () => withHarness(async h => {
    const event = await activePaidEvent(h);
    const { order, intentId } = await qrOrder(h, event);
    const response = await signedWebhook(h, paidEvent(intentId, order.totalCentavos));
    assert.equal(response.json.outcome, "DEFERRED_PROVIDER_PENDING");
    assert.equal(await entitlementCount(h, order.id), 0);
    h.provider.fault(/^GET/, 503);
    const second = await signedWebhook(h, paidEvent(intentId, order.totalCentavos));
    assert.equal(second.json.outcome, "DEFERRED_PROVIDER_UNAVAILABLE");
    assert.equal((await h.one("SELECT state FROM payment_attempts WHERE order_id=?", order.id)).state, "UNKNOWN_RECONCILIATION");
}));

test("duplicate webhook deliveries (same event ID, concurrent) are processed once", () => withHarness(async h => {
    const event = await activePaidEvent(h);
    const { order, intentId } = await qrOrder(h, event);
    h.provider.markPaid(intentId);
    const payload = paidEvent(intentId, order.totalCentavos, { id: "evt_duplicate_1" });
    const responses = await Promise.all(Array.from({ length: 6 }, () => signedWebhook(h, payload)));
    assert.ok(responses.every(r => r.status === 200));
    assert.equal(responses.filter(r => r.json.duplicate).length, 5);
    assert.equal(await entitlementCount(h, order.id), 1);
    assert.equal((await h.one("SELECT COUNT(*) c FROM payment_webhook_events")).c, 1);
    const summary = await h.request("GET", `/v1/admin/events/${event.eventId}/summary`, { token: TOKENS.operator });
    assert.equal(summary.json.verifiedQRPhTestCentavos, order.totalCentavos, "revenue counted once");
    assert.equal(summary.json.qrSessions, 1);
}));

test("distinct paid notifications for one intent still yield one entitlement", () => withHarness(async h => {
    const event = await activePaidEvent(h);
    const { order, intentId } = await qrOrder(h, event);
    h.provider.markPaid(intentId);
    await Promise.all(Array.from({ length: 5 }, () => signedWebhook(h, paidEvent(intentId, order.totalCentavos))));
    assert.equal(await entitlementCount(h, order.id), 1);
}));

test("Cron and webhook racing on the same paid intent converge to one entitlement", () => withHarness(async h => {
    const event = await activePaidEvent(h);
    for (let round = 0; round < 4; round++) {
        const { order, intentId } = await qrOrder(h, event);
        h.provider.markPaid(intentId);
        await Promise.all([signedWebhook(h, paidEvent(intentId, order.totalCentavos)), h.scheduled(), signedWebhook(h, paidEvent(intentId, order.totalCentavos)), h.scheduled()]);
        assert.equal(await entitlementCount(h, order.id), 1);
        assert.equal((await h.one("SELECT state FROM payment_attempts WHERE order_id=?", order.id)).state, "PAID_VERIFIED");
    }
}));

test("failure or expiry evidence never regresses a verified payment", () => withHarness(async h => {
    const event = await activePaidEvent(h);
    const { order, intentId } = await qrOrder(h, event);
    h.provider.markPaid(intentId);
    await signedWebhook(h, paidEvent(intentId, order.totalCentavos));
    for (const type of ["payment.failed", "qrph.expired"]) {
        const response = await signedWebhook(h, { data: { id: `evt_${type}`, type: "event", attributes: { type, livemode: false, created_at: 1, data: { id: "x", type: "payment", attributes: { payment_intent_id: intentId } } } } });
        assert.equal(response.json.outcome, "IGNORED_FINAL");
    }
    assert.equal((await h.one("SELECT state FROM payment_attempts WHERE order_id=?", order.id)).state, "PAID_VERIFIED");
    await assert.rejects(h.db.prepare("UPDATE payment_attempts SET state='PAYMENT_FAILED' WHERE order_id=?").bind(order.id).run(), /paid_state_is_final/);
}));

for (const [name, mutate, expected] of [
    ["wrong amount", p => { p.data.attributes.data.attributes.amount -= 1; }, "REJECTED_MISMATCH"],
    ["wrong currency", p => { p.data.attributes.data.attributes.currency = "USD"; }, "REJECTED_MISMATCH"],
    ["unknown intent", p => { p.data.attributes.data.attributes.payment_intent_id = "pi_unknown"; }, "REJECTED_MISMATCH"],
    ["resource livemode mismatch", p => { p.data.attributes.data.attributes.livemode = true; }, "REJECTED_MISMATCH"],
    ["status not paid", p => { p.data.attributes.data.attributes.status = "pending"; }, "REJECTED_MISMATCH"],
    ["resource type not payment", p => { p.data.attributes.data.type = "refund"; }, "REJECTED_MISMATCH"],
    ["unrelated event type", p => { p.data.attributes.type = "source.chargeable"; }, "IGNORED"]
]) {
    test(`webhook ${name} never authorizes`, () => withHarness(async h => {
        const event = await activePaidEvent(h);
        const { order, intentId } = await qrOrder(h, event);
        h.provider.markPaid(intentId);
        const payload = paidEvent(intentId, order.totalCentavos);
        mutate(payload);
        const response = await signedWebhook(h, payload);
        assert.equal(response.status, 200);
        assert.equal(response.json.outcome, expected);
        assert.equal(await entitlementCount(h, order.id), 0);
    }));
}

test("webhook signature: raw-body HMAC, te/li selection, timestamp window, malformed input", () => withHarness(async h => {
    const event = await activePaidEvent(h);
    const { order, intentId } = await qrOrder(h, event);
    h.provider.markPaid(intentId);
    const payload = paidEvent(intentId, order.totalCentavos);
    assert.equal((await signedWebhook(h, payload, { secret: "whsk_wrong" })).status, 401);
    assert.equal((await signedWebhook(h, payload, { timestamp: Math.floor(Date.now() / 1000) - 301 })).status, 401);
    assert.equal((await signedWebhook(h, payload, { timestamp: Math.floor(Date.now() / 1000) + 301 })).status, 401);
    assert.equal((await signedWebhook(h, payload, { live: true, endpoint: "/v1/webhooks/paymongo/test" })).status, 401, "li signature is not accepted on the test endpoint");
    const raw = JSON.stringify(payload);
    const tampered = await h.request("POST", "/v1/webhooks/paymongo/test", { token: null, body: raw.replace(`"amount":${order.totalCentavos}`, '"amount":1'), headers: { "paymongo-signature": (await signedHeader(raw)) } });
    assert.equal(tampered.status, 401, "signature covers the exact raw body");
    assert.equal((await h.request("POST", "/v1/webhooks/paymongo/test", { token: null, body: raw })).status, 401, "missing header");
    assert.equal((await signedWebhook(h, "{not json")).status, 400);
    assert.equal((await signedWebhook(h, { data: { id: "evt_x", attributes: { type: "payment.paid", livemode: true } } })).status, 400, "test endpoint rejects livemode=true payload");
    assert.equal((await signedWebhook(h, { nothing: true })).status, 400);
    assert.equal(await entitlementCount(h, order.id), 0);
    assert.equal((await signedWebhook(h, payload)).json.outcome, "PAID_VERIFIED");
}));

async function signedHeader(raw) {
    const { webcrypto } = await import("node:crypto");
    const t = Math.floor(Date.now() / 1000);
    const key = await webcrypto.subtle.importKey("raw", new TextEncoder().encode(WEBHOOK_SECRET), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
    return `t=${t},te=${Buffer.from(await webcrypto.subtle.sign("HMAC", key, new TextEncoder().encode(`${t}.${raw}`))).toString("hex")},li=`;
}

test("live webhook endpoint is inert unless live payments are explicitly enabled", () => withHarness(async h => {
    const response = await signedWebhook(h, paidEvent("pi_1", 100, { livemode: true }), { live: true });
    assert.equal(response.status, 503);
    assert.equal(response.json.error, "live_payments_disabled");
}));

test("live-configured Worker without enable flag refuses QR creation and skips Cron", () => withHarness({ bindings: { PAYMENTS_ENVIRONMENT: "live" } }, async h => {
    const event = await activePaidEvent(h);
    const { order } = await newOrder(h, event);
    const qr = await h.request("POST", `/v1/orders/${order.id}/qrph`);
    assert.equal(qr.status, 503);
    assert.equal(qr.json.error, "live_payments_disabled");
    assert.equal(h.provider.calls.length, 0);
    await h.scheduled();
    assert.equal((await h.one("SELECT COUNT(*) c FROM reconciliation_runs")).c, 0);
}));

test("test-mode payment never increments LIVE revenue", () => withHarness(async h => {
    const event = await activePaidEvent(h);
    const { order, intentId } = await qrOrder(h, event);
    h.provider.markPaid(intentId);
    await signedWebhook(h, paidEvent(intentId, order.totalCentavos));
    const summary = await h.request("GET", `/v1/admin/events/${event.eventId}/summary`, { token: TOKENS.operator });
    assert.equal(summary.json.verifiedQRPhLiveCentavos, 0);
    assert.equal(summary.json.verifiedQRPhTestCentavos, order.totalCentavos);
}));

test("webhook processing failure is retryable, not silently marked duplicate", () => withHarness(async h => {
    const event = await activePaidEvent(h);
    const { order, intentId } = await qrOrder(h, event);
    h.provider.markPaid(intentId);
    const payload = paidEvent(intentId, order.totalCentavos, { id: "evt_retry" });
    await h.db.prepare("UPDATE payment_attempts SET provider_payment_id='pay_conflict' WHERE order_id=?").bind(order.id).run();
    await h.db.prepare("INSERT INTO payment_webhook_events(provider_event_id,event_type,livemode,provider_created_at,processing_outcome,created_at) VALUES('evt_retry','payment.paid',0,1,'FAILED',?)").bind(new Date().toISOString()).run();
    const retried = await signedWebhook(h, payload);
    assert.equal(retried.status, 200);
    assert.equal(retried.json.outcome, "PAID_VERIFIED", "a FAILED delivery is reprocessed on retry");
    assert.equal(await entitlementCount(h, order.id), 1);
}));

test("Cron reconciles with bounded batches, backoff on provider failure, and no regression", () => withHarness({ bindings: { RECONCILIATION_BATCH_SIZE: "3" } }, async h => {
    const event = await activePaidEvent(h, { policy: { ...(await import("./support/harness.js")).PAID_POLICY } });
    const orders = [];
    for (let i = 0; i < 5; i++) orders.push(await qrOrder(h, event));
    for (let i = 0; i < 3; i++) h.provider.fault(/^GET/, "network");
    const first = await h.scheduled();
    assert.equal(first.outcome, "ok");
    const run = await h.one("SELECT * FROM reconciliation_runs ORDER BY started_at DESC LIMIT 1");
    assert.equal(run.inspected_count, 3, "bounded by RECONCILIATION_BATCH_SIZE");
    assert.match(run.failure_summary, /3 provider lookups failed/);
    const backedOff = await h.all("SELECT * FROM payment_attempts WHERE reconcile_after > ?", new Date().toISOString());
    assert.equal(backedOff.length, 3);
    assert.ok(backedOff.every(a => a.state === "UNKNOWN_RECONCILIATION" && a.reconcile_count === 1 && a.last_reconcile_error));
    assert.doesNotMatch(JSON.stringify(backedOff.map(a => a.last_reconcile_error)), /sk_test_/);
    h.provider.markPaid(orders[4].intentId);
    await h.scheduled();
    assert.equal(await entitlementCount(h, orders[4].order.id), 1);
}));

test("Cron settles a QR still unpaid well after its expiry, and an interrupted creation with no intent", () => withHarness(async h => {
    const event = await activePaidEvent(h);
    const { order } = await qrOrder(h, event);
    await h.db.prepare("UPDATE payment_attempts SET expires_at=? WHERE order_id=?").bind(new Date(Date.now() - 11 * 60_000).toISOString(), order.id).run();
    const stuck = await newOrder(h, event);
    const old = new Date(Date.now() - 5 * 60_000).toISOString();
    await h.db.batch([
        h.db.prepare("UPDATE orders SET payment_method='QRPH',state='PAYMENT_PENDING' WHERE id=?").bind(stuck.order.id),
        h.db.prepare("INSERT INTO payment_attempts(id,order_id,method,livemode,state,created_at,updated_at) VALUES('stuck',?,'QRPH',0,'CREATING',?,?)").bind(stuck.order.id, old, old)
    ]);
    await h.scheduled();
    assert.equal((await h.one("SELECT state FROM payment_attempts WHERE order_id=?", order.id)).state, "QR_EXPIRED_CONFIRMED");
    assert.equal((await h.one("SELECT state FROM payment_attempts WHERE id='stuck'")).state, "CREATE_FAILED_NO_QR");
    assert.equal((await h.request("GET", `/v1/orders/${stuck.order.id}/status`)).json.newCheckout.allowed, true);
}));

test("provider intent with mismatched amount is held for manual review", () => withHarness(async h => {
    const event = await activePaidEvent(h);
    const { order, intentId } = await qrOrder(h, event);
    h.provider.markPaid(intentId);
    h.provider.intents.get(intentId).attributes.amount = 1;
    await h.scheduled();
    assert.equal((await h.one("SELECT state FROM payment_attempts WHERE order_id=?", order.id)).state, "MANUAL_REVIEW");
    assert.equal(await entitlementCount(h, order.id), 0);
    const diagnostics = await h.request("GET", "/v1/admin/diagnostics", { token: TOKENS.operator });
    assert.equal(diagnostics.json.unresolvedIntentCount, 1);
}));
