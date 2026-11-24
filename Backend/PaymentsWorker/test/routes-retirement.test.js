import test from "node:test";
import assert from "node:assert/strict";
import { createHarness, activePaidEvent, newOrder } from "./support/harness.js";

test("default-off creation leaves method unlocked and never calls provider", async () => {
    const h = await createHarness({ bindings: { PAYMONGO_NEW_CHECKOUTS_ENABLED: "false" } });
    try {
        const event = await activePaidEvent(h), { order } = await newOrder(h, event);
        const result = await h.request("POST", `/v1/orders/${order.id}/qrph`);
        assert.equal(result.status, 410);
        assert.equal(result.json.error, "paymongo_creation_retired");
        assert.equal(h.provider.calls.length, 0);
        assert.equal((await h.one("SELECT payment_method FROM orders WHERE id=?", order.id)).payment_method, null);
        assert.equal((await h.all("SELECT id FROM payment_attempts")).length, 0);
        assert.equal((await h.request("GET", "/v1/health")).json.newPaymongoCheckoutsEnabled, false);
    } finally { await h.dispose(); }
});

test("retired creation still reads and reconciles original verified entitlement", async () => {
    const h = await createHarness({ bindings: { PAYMONGO_NEW_CHECKOUTS_ENABLED: "false" } });
    try {
        const event = await activePaidEvent(h), { order } = await newOrder(h, event);
        const timestamp = new Date().toISOString();
        await h.db.prepare("UPDATE orders SET payment_method='QRPH',state='PAYMENT_PENDING' WHERE id=?").bind(order.id).run();
        await h.db.prepare("INSERT INTO payment_attempts(id,order_id,method,livemode,state,provider_payment_intent_id,created_at,updated_at) VALUES('legacy-attempt',?,'QRPH',0,'AWAITING_PAYMENT','pi_legacy',?,?)").bind(order.id,timestamp,timestamp).run();
        h.provider.intents.set("pi_legacy", { id:"pi_legacy",type:"payment_intent",attributes:{amount:order.totalCentavos,currency:"PHP",livemode:false,status:"succeeded",payments:[{id:"pay_legacy"}]}});
        const result = await h.request("POST", `/v1/orders/${order.id}/reconcile`);
        assert.equal(result.status, 200);
        assert.equal(result.json.attempt.state, "PAID_VERIFIED");
        assert.equal(result.json.entitlement.purchasedCopies, order.copies);
        const before = h.provider.calls.length;
        assert.equal((await h.request("POST", `/v1/orders/${order.id}/qrph`)).json.replay, true);
        assert.equal(h.provider.calls.length, before);
    } finally { await h.dispose(); }
});

test("retired provider cron still prunes throttle data and retains on-demand reconciliation", async () => {
    const token = "synthetic-monitor-read-token-long-enough";
    const h = await createHarness({ bindings: { LEGACY_RECONCILIATION_ENABLED: "false", MONITOR_READ_TOKEN: token } });
    try {
        await h.db.prepare("INSERT INTO request_rate_limits(key,minute_window,request_count) VALUES('expired',1,1)").run();
        await h.scheduled();
        assert.equal(await h.one("SELECT 1 FROM request_rate_limits WHERE key='expired'"), null);
        assert.equal(await h.one("SELECT 1 FROM reconciliation_runs"), null);
        const health = await h.request("GET", "/v1/monitor-health", { token });
        assert.equal(health.json.reconciliationEnabled, false);
        assert.equal(health.json.reconciliationFresh, false);
        assert.equal(h.provider.calls.length, 0);
    } finally { await h.dispose(); }
});
