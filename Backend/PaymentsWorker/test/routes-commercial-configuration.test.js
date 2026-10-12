import test from "node:test";
import assert from "node:assert/strict";
import { createHarness, activePaidEvent, newOrder, PAID_POLICY, TOKENS, signedWebhook, paidEvent } from "./support/harness.js";

// Local workerd + isolated D1 + stub provider: never contacts PayMongo or deployed infrastructure.
test("regular-session quantities bind QR amounts and entitlements; revised pricing requires publication", async () => {
    const h = await createHarness();
    try {
        const policy = { ...PAID_POLICY, unitPriceCentavos: 2500, maxCopies: 3, cashEnabled: false };
        const event = await activePaidEvent(h, { policy });
        const orders = [];
        for (const copies of [1, 2, 3]) {
            const created = await newOrder(h, event, { copies });
            assert.equal(created.status, 201);
            assert.equal(created.order.totalCentavos, 2500 * copies);
            assert.equal(created.order.copies, copies);
            const qr = await h.request("POST", `/v1/orders/${created.order.id}/qrph`);
            assert.equal(qr.status, 201);
            const call = h.provider.calls.filter(c => c.route === "POST /payment_intents").at(-1);
            assert.equal(call.body.data.attributes.amount, 2500 * copies);
            assert.equal((await h.all("SELECT * FROM entitlements WHERE order_id=?", created.order.id)).length, 0);
            orders.push(created);
        }
        assert.equal((await newOrder(h, event, { copies: 4 })).status, 422);
        const revised = { ...policy, unitPriceCentavos: 3500, maxCopies: 5 };
        const saved = await h.request("PATCH", `/v1/admin/events/${event.eventId}`, {
            token: TOKENS.operator, headers: { "if-match": String(event.version) }, body: { policy: revised }
        });
        assert.equal(saved.status, 200);
        assert.equal((await h.request("GET", "/v1/events/active")).json.event.unitPriceCentavos, 2500);
        assert.equal((await newOrder(h, event, { copies: 3 })).order.totalCentavos, 7500);
        const published = await h.request("POST", `/v1/admin/events/${event.eventId}/publish`, {
            token: TOKENS.operator, headers: { "if-match": String(saved.json.version) },
            body: { policyRevisionId: saved.json.draftRevision.id, acknowledgedUnitPriceCentavos: 3500 }
        });
        assert.equal(published.status, 200);
        assert.equal((await newOrder(h, event)).json.error, "policy_changed");
        const current = { ...event, revisionId: saved.json.draftRevision.id, unitPriceCentavos: 3500 };
        assert.equal((await newOrder(h, current, { copies: 5 })).order.totalCentavos, 17500);
        // An already displayed and accepted checkout retains its original price and quantity.
        const purchased = orders[2];
        const attempt = await h.one("SELECT * FROM payment_attempts WHERE order_id=?", purchased.order.id);
        h.provider.markPaid(attempt.provider_payment_intent_id);
        assert.equal((await signedWebhook(h, paidEvent(attempt.provider_payment_intent_id, 7500))).status, 200);
        const entitlement = await h.one("SELECT * FROM entitlements WHERE order_id=?", purchased.order.id);
        assert.equal(entitlement.purchased_copies, 3);
        assert.equal((await h.request("POST", `/v1/entitlements/${entitlement.id}/claim`, {
            body: { sessionId: purchased.session, idempotencyKey: "claim" }
        })).status, 200);
        const base = { entitlementId: entitlement.id, sessionId: purchased.session,
            receiptFingerprint: "a".repeat(64), transport: "bluetooth", outcome: "DELIVERED" };
        for (const copyIndex of [1, 2, 3]) {
            assert.equal((await h.request("POST", "/v1/prints/regular-batch/progress", {
                body: { ...base, copyIndex, idempotencyKey: `copy-${copyIndex}` }
            })).status, 200);
        }
        assert.equal((await h.request("POST", "/v1/prints/regular-batch/progress", {
            body: { ...base, copyIndex: 4, idempotencyKey: "extra-copy" }
        })).status, 422);
        assert.equal((await h.all("SELECT * FROM print_copy_outcomes")).length, 3);
        assert.equal((await h.one("SELECT total_centavos FROM orders WHERE id=?", purchased.order.id)).total_centavos, 7500);
    } finally { await h.dispose(); }
});
