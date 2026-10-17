import test from 'node:test';
import assert from 'node:assert/strict';
import { createHarness, activePaidEvent, newOrder, TOKENS, paidEvent, signedWebhook } from './support/harness.js';

async function fixture(body) {
    const h = await createHarness();
    try {
        const event = await activePaidEvent(h);
        const { order } = await newOrder(h, event);
        await h.request('POST', `/v1/orders/${order.id}/qrph`);
        const attempt = await h.one('SELECT * FROM payment_attempts WHERE order_id=?', order.id);
        await body(h, order, attempt.provider_payment_intent_id);
    } finally { await h.dispose(); }
}
const recheck = (h, id, options) => h.request('POST', `/v1/orders/${id}/reconcile`, options);

test('on-demand verifies original paid intent without webhook or replacement checkout', () => fixture(async (h, order, intent) => {
    h.provider.markPaid(intent);
    const result = await recheck(h, order.id);
    assert.equal(result.status, 200);
    assert.equal(result.json.entitlement.authorizationSource, 'VERIFIED_QRPH');
    assert.equal((await h.one('SELECT COUNT(*) c FROM orders')).c, 1);
    assert.equal(h.provider.count('POST /payment_intents'), 1);
    assert.equal(h.provider.count(`GET /payment_intents/${intent}`), 1);
}));

test('concurrent rechecks and delayed webhook yield one entitlement', () => fixture(async (h, order, intent) => {
    h.provider.markPaid(intent);
    await Promise.all([recheck(h, order.id), recheck(h, order.id), signedWebhook(h, paidEvent(intent, order.totalCentavos))]);
    assert.equal((await h.one('SELECT COUNT(*) c FROM entitlements WHERE order_id=?', order.id)).c, 1);
    assert.equal((await h.request('GET', `/v1/orders/${order.id}/status`)).json.attempt.state, 'PAID_VERIFIED');
}));

test('provider outage remains unknown and cooldown bounds retries', () => fixture(async (h, order, intent) => {
    h.provider.fault(/^GET/, 429);
    const first = await recheck(h, order.id);
    assert.equal(first.json.attempt.state, 'UNKNOWN_RECONCILIATION');
    assert.equal(first.json.entitlement, null);
    await recheck(h, order.id);
    assert.equal(h.provider.count(`GET /payment_intents/${intent}`), 1);
    await h.db.prepare('UPDATE payment_attempts SET last_on_demand_at=NULL').run();
    h.provider.markPaid(intent);
    const recovered = await recheck(h, order.id);
    assert.equal(recovered.json.entitlement.authorizationSource, 'VERIFIED_QRPH');
}));

test('another device cannot reconcile the original order', () => fixture(async (h, order, intent) => {
    const response = await recheck(h, order.id, { token: TOKENS.booth2 });
    assert.equal(response.status, 404);
    assert.equal(h.provider.count(`GET /payment_intents/${intent}`), 0);
}));

test('conflicting provider amount holds manual review without entitlement', () => fixture(async (h, order, intent) => {
    h.provider.markPaid(intent);
    h.provider.intents.get(intent).attributes.amount += 1;
    const result = await recheck(h, order.id);
    assert.equal(result.json.attempt.state, 'MANUAL_REVIEW');
    assert.equal(result.json.entitlement, null);
}));
