// Reporting, cash reconciliation, CSV export and redaction tests through the real Worker and D1.
import test from "node:test";
import assert from "node:assert/strict";
import { createHarness, activePaidEvent, newOrder, signedWebhook, paidEvent, TOKENS } from "./support/harness.js";

async function withHarness(body) {
    const h = await createHarness();
    try { await body(h); } finally { await h.dispose(); }
}

const op = (h, method, path, options = {}) => h.request(method, path, { token: TOKENS.operator, ...options });

async function sales(h) {
    const event = await activePaidEvent(h);
    const cash = await newOrder(h, event, { copies: 3 });
    await h.request("POST", `/v1/orders/${cash.order.id}/cash-declaration`);
    const qr = await newOrder(h, event, { copies: 1 });
    await h.request("POST", `/v1/orders/${qr.order.id}/qrph`);
    const intentId = (await h.one("SELECT provider_payment_intent_id id FROM payment_attempts WHERE order_id=?", qr.order.id)).id;
    h.provider.markPaid(intentId);
    await signedWebhook(h, paidEvent(intentId, qr.order.totalCentavos));
    const pending = await newOrder(h, event, { copies: 2 });
    await h.request("POST", `/v1/orders/${pending.order.id}/qrph`);
    return { event, cash, qr, pending };
}

test("summary keeps verified QR, self-reported cash, counted cash and variance distinct", () => withHarness(async h => {
    const { event } = await sales(h);
    let summary = (await op(h, "GET", `/v1/admin/events/${event.eventId}/summary`)).json;
    assert.equal(summary.verifiedQRPhTestCentavos, 5_000);
    assert.equal(summary.verifiedQRPhLiveCentavos, 0);
    assert.equal(summary.cashSelfReportedCentavos, 15_000);
    assert.equal(summary.cashLocalUnsyncedCentavos, null, "server cannot know device-local unsynced cash");
    assert.equal(summary.unresolvedQRCount, 1);
    assert.equal(summary.physicalCashCount, null);
    assert.equal(summary.settlementStatus, "NOT_REPORTED");
    assert.deepEqual(summary.unsupported, { refunds: "UNSUPPORTED", complimentaryPrints: "UNSUPPORTED", processorFees: "UNSUPPORTED", payouts: "UNSUPPORTED" });

    const count = await op(h, "POST", `/v1/admin/events/${event.eventId}/cash-counts`, { body: { countedCentavos: 14_000, reason: "Closing count" } });
    assert.equal(count.status, 201);
    const correction = await op(h, "POST", `/v1/admin/events/${event.eventId}/cash-counts`, { body: { countedCentavos: 15_500, reason: "Found envelope", pendingLocalCount: 2 } });
    assert.equal(correction.json.provisional, true);
    const rows = await h.all("SELECT counted_centavos, supersedes_id FROM cash_reconciliations ORDER BY created_at");
    assert.equal(rows.length, 2, "corrections append, never overwrite");
    assert.equal(rows[1].supersedes_id, count.json.id);
    await assert.rejects(h.db.prepare("UPDATE cash_reconciliations SET counted_centavos=0").run(), /cash_reconciliation_append_only/);
    summary = (await op(h, "GET", `/v1/admin/events/${event.eventId}/summary`)).json;
    assert.equal(summary.physicalCashCount.countedCentavos, 15_500);
    assert.equal(summary.physicalCashCount.varianceCentavos, 500);
    assert.equal(summary.physicalCashCount.provisional, true);
    assert.equal((await op(h, "POST", `/v1/admin/events/${event.eventId}/cash-counts`, { body: { countedCentavos: 1.5, reason: "x" } })).status, 422);
    assert.equal((await op(h, "POST", `/v1/admin/events/${event.eventId}/cash-counts`, { body: { countedCentavos: 1, reason: "" } })).status, 422);
}));

test("orders drill-down filters, categories and composite pagination", () => withHarness(async h => {
    const { event, pending } = await sales(h);
    const all = [];
    let cursor = null;
    do {
        const page = await op(h, "GET", `/v1/admin/events/${event.eventId}/orders?limit=2${cursor ? `&cursor=${encodeURIComponent(cursor)}` : ""}`);
        all.push(...page.json.orders);
        cursor = page.json.nextCursor;
    } while (cursor);
    assert.equal(all.length, 3);
    assert.deepEqual(all.map(o => o.category).sort(), ["CASH_SELF_REPORTED", "QRPH_UNRESOLVED", "QRPH_VERIFIED_TEST"]);
    const unresolved = await op(h, "GET", `/v1/admin/events/${event.eventId}/orders?filter=unresolved`);
    assert.deepEqual(unresolved.json.orders.map(o => o.id), [pending.order.id]);
    assert.equal((await op(h, "GET", `/v1/admin/events/${event.eventId}/orders?filter=nope`)).status, 422);
    assert.doesNotMatch(JSON.stringify(all), /qr_image|data:image|pi_\d|test\.paymongo/);
}));

test("CSV export: deterministic, escaped, no provider or media data, paginated with completion headers", () => withHarness(async h => {
    const { event } = await sales(h);
    const first = await op(h, "GET", `/v1/admin/events/${event.eventId}/export.csv`);
    const second = await op(h, "GET", `/v1/admin/events/${event.eventId}/export.csv`);
    assert.equal(first.status, 200);
    assert.equal(first.text, second.text, "deterministic");
    assert.equal(first.headers.get("x-export-complete"), "true");
    assert.equal(first.headers.get("x-export-row-count"), "3");
    assert.equal(first.headers.get("cache-control"), "no-store");
    const lines = first.text.trim().split("\r\n");
    assert.equal(lines.length, 4);
    assert.match(lines[0], /"category","provenance"/);
    assert.doesNotMatch(first.text, /pi_\d|data:image|paymongo|sk_test|whsk/);
    assert.match(first.text, /"CASH_SELF_REPORTED","UNVERIFIED_CASH_DECLARED"/);
    assert.equal((await h.request("GET", `/v1/admin/events/${event.eventId}/export.csv`, { token: TOKENS.boothOnly })).status, 403);
    assert.equal((await h.request("GET", `/v1/admin/events/${event.eventId}/export.csv`, { token: TOKENS.otherAccount })).status, 404);
}));

test("CSV pagination signals truncation and resumes from the cursor", () => withHarness(async h => {
    const event = await activePaidEvent(h);
    const at = new Date().toISOString();
    // Rows are generated inside SQLite; identical timestamps exercise the composite cursor.
    await h.db.prepare(`WITH RECURSIVE n(i) AS (SELECT 0 UNION ALL SELECT i+1 FROM n WHERE i<5002)
        INSERT INTO orders(id,event_id,policy_revision_id,device_id,booth_format,copies,unit_price_centavos,total_centavos,currency,state,idempotency_key,created_at,updated_at)
        SELECT printf('o-%05d', i),?,?,'dev-booth','solo',1,5000,5000,'PHP','AWAITING_PAYMENT','k'||i,?,? FROM n`).bind(event.eventId, event.revisionId, at, at).run();
    const page1 = await op(h, "GET", `/v1/admin/events/${event.eventId}/export.csv`);
    assert.equal(page1.headers.get("x-export-complete"), "false");
    assert.equal(page1.headers.get("x-export-row-count"), "5000");
    const cursor = page1.headers.get("x-export-next-cursor");
    const page2 = await op(h, "GET", `/v1/admin/events/${event.eventId}/export.csv?cursor=${encodeURIComponent(cursor)}`);
    assert.equal(page2.headers.get("x-export-complete"), "true");
    assert.equal(page2.headers.get("x-export-row-count"), "3");
    assert.match(page2.text, /o-05002/);
}));

test("provider error bodies and secrets never reach responses", () => withHarness(async h => {
    const event = await activePaidEvent(h);
    const { order } = await newOrder(h, event);
    h.provider.fault(/^POST \/payment_intents$/, 500);
    const response = await h.request("POST", `/v1/orders/${order.id}/qrph`);
    assert.doesNotMatch(response.text, /sk_test|SECRETLEAK|pk_test|whsk/);
    const attempt = await h.one("SELECT last_reconcile_error FROM payment_attempts WHERE order_id=?", order.id);
    assert.doesNotMatch(attempt.last_reconcile_error, /sk_test_harness/);
    const diagnostics = await op(h, "GET", "/v1/admin/diagnostics");
    assert.equal(diagnostics.json.offlineSigningConfigured, true);
    assert.doesNotMatch(diagnostics.text, /sk_test|whsk|BEGIN|pkcs8/i);
    const outbound = h.provider.calls[0];
    assert.match(outbound.authorization, /^Basic /, "provider secret is only sent outbound to PayMongo");
}));
