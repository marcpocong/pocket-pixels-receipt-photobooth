// Operator event lifecycle, versioning, authorization and account-isolation tests.
import test from "node:test";
import assert from "node:assert/strict";
import { createHarness, activePaidEvent, PAID_POLICY, TOKENS } from "./support/harness.js";

async function withHarness(body, options) {
    const h = await createHarness(options);
    try { await body(h); } finally { await h.dispose(); }
}

const op = (h, method, path, options = {}) => h.request(method, path, { token: TOKENS.operator, ...options });

test("authentication: missing, short, unknown and revoked credentials are refused", () => withHarness(async h => {
    assert.equal((await h.request("GET", "/v1/events/active", { token: null })).status, 401);
    assert.equal((await h.request("GET", "/v1/events/active", { token: "short" })).status, 401);
    assert.equal((await h.request("GET", "/v1/events/active", { token: "x".repeat(40) })).status, 401);
    const revoked = await h.request("GET", "/v1/events/active", { token: TOKENS.revoked });
    assert.equal(revoked.status, 401);
    assert.equal(revoked.json.error, "unauthorized");
}));

test("scopes: booth-only devices cannot use operator routes; operator-only devices cannot check out", () => withHarness(async h => {
    assert.equal((await h.request("GET", "/v1/admin/events", { token: TOKENS.boothOnly })).status, 403);
    assert.equal((await h.request("GET", "/v1/events/active", { token: TOKENS.operator })).status, 403);
    assert.equal((await h.request("POST", "/v1/orders", { token: TOKENS.operator, body: {} })).status, 403);
    const me = await h.request("GET", "/v1/device", { token: TOKENS.boothOnly });
    assert.deepEqual(me.json.device, { id: "dev-booth-only", accountId: "acct-a", displayName: "Booth only", scopes: ["booth"] });
}));

test("failed authentication is rate limited per client address", () => withHarness(async h => {
    const statuses = [];
    for (let i = 0; i < 32; i++) statuses.push((await h.request("GET", "/v1/events/active", { token: "z".repeat(40), headers: { "cf-connecting-ip": "203.0.113.9" } })).status);
    assert.equal(statuses.slice(0, 30).every(s => s === 401), true);
    assert.deepEqual(statuses.slice(30), [429, 429]);
    const bucket = await h.one("SELECT minute_window,request_count FROM request_rate_limits WHERE key=?", "authfail:203.0.113.9");
    assert.equal(bucket.minute_window, Math.floor(Date.UTC(2026, 9, 14, 13, 30, 30) / 60000));
    assert.equal(bucket.request_count, 32);
    assert.equal((await h.request("GET", "/v1/events/active", { token: "z".repeat(40), headers: { "cf-connecting-ip": "203.0.113.10" } })).status, 401);
}, { fixedTime: Date.UTC(2026, 9, 14, 13, 30, 30) }));

test("account isolation: events of another account are invisible", () => withHarness(async h => {
    const event = await activePaidEvent(h);
    assert.equal((await h.request("GET", `/v1/admin/events/${event.eventId}`, { token: TOKENS.otherAccount })).status, 404);
    assert.equal((await h.request("GET", `/v1/admin/events/${event.eventId}/summary`, { token: TOKENS.otherAccount })).status, 404);
    assert.equal((await h.request("POST", `/v1/admin/events/${event.eventId}/pause`, { token: TOKENS.otherAccount, headers: { "if-match": "3" } })).status, 404);
    assert.equal((await h.request("GET", "/v1/admin/events", { token: TOKENS.otherAccount })).json.events.length, 0);
    assert.equal((await h.request("GET", "/v1/events/active", { token: TOKENS.otherAccount })).json.event, null);
}));

test("full lifecycle: create, draft, publish with acknowledgement, activate, pause, resume, end, archive", () => withHarness(async h => {
    const created = await op(h, "POST", "/v1/admin/events", { body: { name: "  Gala\u0000 Night ", venue: "BGC" } });
    assert.equal(created.status, 201);
    const id = created.json.id;
    assert.equal((await op(h, "PATCH", `/v1/admin/events/${id}`, { body: { policy: PAID_POLICY } })).status, 428, "If-Match required");
    const draft = await op(h, "PATCH", `/v1/admin/events/${id}`, { headers: { "if-match": "1" }, body: { policy: PAID_POLICY } });
    assert.equal(draft.status, 200);
    assert.equal(draft.json.version, 2);
    const revisionId = draft.json.draftRevision.id;
    let detail = await op(h, "GET", `/v1/admin/events/${id}`);
    assert.equal(detail.json.event.name, "Gala Night");
    assert.equal(detail.json.hasUnpublishedRevision, true);
    assert.equal(detail.json.activePolicy, null);
    assert.equal((await op(h, "POST", `/v1/admin/events/${id}/activate`, { headers: { "if-match": "2" } })).status, 422, "no implicit latest-revision activation");
    const wrongAck = await op(h, "POST", `/v1/admin/events/${id}/activate`, { headers: { "if-match": "2" }, body: { policyRevisionId: revisionId, acknowledgedUnitPriceCentavos: 500 } });
    assert.equal(wrongAck.json.error, "acknowledgement_mismatch");
    const active = await op(h, "POST", `/v1/admin/events/${id}/activate`, { headers: { "if-match": "2" }, body: { policyRevisionId: revisionId, acknowledgedUnitPriceCentavos: 5000 } });
    assert.equal(active.json.lifecycle, "ACTIVE");
    const booth = await h.request("GET", "/v1/events/active");
    assert.equal(booth.json.event.policyRevisionId, revisionId);
    assert.equal(booth.json.event.unitPriceCentavos, 5000);
    let version = active.json.version;
    for (const [action, expected] of [["pause", "PAUSED"], ["resume", "ACTIVE"], ["pause", "PAUSED"], ["end", "ENDED"], ["archive", "ARCHIVED"]]) {
        const result = await op(h, "POST", `/v1/admin/events/${id}/${action}`, { headers: { "if-match": String(version) } });
        assert.equal(result.status, 200, `${action}: ${result.text}`);
        assert.equal(result.json.lifecycle, expected);
        version = result.json.version;
        if (action === "pause") assert.equal((await h.request("GET", "/v1/events/active")).json.event, null, "paused event is not offered to guests");
    }
    assert.equal((await op(h, "PATCH", `/v1/admin/events/${id}`, { headers: { "if-match": String(version) }, body: { name: "x" } })).json.error, "event_not_editable");
    detail = await op(h, "GET", `/v1/admin/events/${id}`);
    assert.equal(detail.json.event.lifecycle, "ARCHIVED");
}));

test("invalid lifecycle transitions are refused by route and by DB trigger", () => withHarness(async h => {
    const event = await activePaidEvent(h);
    assert.equal((await op(h, "POST", `/v1/admin/events/${event.eventId}/resume`, { headers: { "if-match": String(event.version) } })).json.error, "invalid_lifecycle_transition");
    assert.equal((await op(h, "POST", `/v1/admin/events/${event.eventId}/archive`, { headers: { "if-match": String(event.version) } })).json.error, "invalid_lifecycle_transition");
    await assert.rejects(h.db.prepare("UPDATE events SET lifecycle='DRAFT' WHERE id=?").bind(event.eventId).run(), /invalid_lifecycle_transition/);
}));

test("only one ACTIVE event per account", () => withHarness(async h => {
    await activePaidEvent(h, { name: "First" });
    await assert.rejects(activePaidEvent(h, { name: "Second" }), /another_event_active/);
    assert.equal((await activePaidEvent(h, { token: TOKENS.otherAccount, name: "Other account" })).eventId.length > 0, true, "other accounts are independent");
}));

test("stale If-Match and concurrent edits: exactly one draft revision is written", () => withHarness(async h => {
    const created = await op(h, "POST", "/v1/admin/events", { body: { name: "Race" } });
    const id = created.json.id;
    const responses = await Promise.all(Array.from({ length: 5 }, (_, i) => op(h, "PATCH", `/v1/admin/events/${id}`, { headers: { "if-match": "1" }, body: { policy: { ...PAID_POLICY, unitPriceCentavos: 1000 + i } } })));
    assert.equal(responses.filter(r => r.status === 200).length, 1);
    assert.ok(responses.filter(r => r.status !== 200).every(r => r.status === 409 && r.json.error === "version_conflict" && r.json.currentVersion === 2));
    assert.equal((await h.one("SELECT COUNT(*) c FROM event_policy_revisions WHERE event_id=?", id)).c, 1, "no orphan revisions from losing writers");
    const stale = await op(h, "POST", `/v1/admin/events/${id}/pause`, { headers: { "if-match": "1" } });
    assert.equal(stale.status, 409);
}));

test("published policy revisions are immutable", () => withHarness(async h => {
    const event = await activePaidEvent(h);
    await assert.rejects(h.db.prepare("UPDATE event_policy_revisions SET unit_price_centavos=1 WHERE id=?").bind(event.revisionId).run(), /policy_revision_immutable/);
}));

for (const [name, patch] of [
    ["zero paid price", { unitPriceCentavos: 0 }], ["negative price", { unitPriceCentavos: -100 }], ["fractional centavos", { unitPriceCentavos: 50.5 }],
    ["decimal string", { unitPriceCentavos: "50.50" }], ["boolean price", { unitPriceCentavos: true }], ["over maximum", { unitPriceCentavos: 10_000_001 }],
    ["no payment method", { cashEnabled: false, qrphEnabled: false }], ["default above max", { defaultCopies: 6 }], ["max over 10", { maxCopies: 11 }],
    ["unknown format", { supportedFormats: ["poster"] }], ["no formats", { supportedFormats: [] }], ["bad offline date", { offlineValidUntil: "tomorrow" }],
    ["prepaid with price", { commercialMode: "PRIVATE_PREPAID", unitPriceCentavos: 100 }], ["QR Ph below PayMongo minimum", { unitPriceCentavos: 99 }], ["oversized features", { features: { x: "y".repeat(5000) } }]
]) {
    test(`invalid commercial policy is rejected: ${name}`, () => withHarness(async h => {
        const created = await op(h, "POST", "/v1/admin/events", { body: { name: "Validation" } });
        const response = await op(h, "PATCH", `/v1/admin/events/${created.json.id}`, { headers: { "if-match": "1" }, body: { policy: { ...PAID_POLICY, ...patch } } });
        assert.equal(response.status, 422);
        assert.equal(response.json.error, "invalid_policy");
        assert.equal((await h.one("SELECT version FROM events WHERE id=?", created.json.id)).version, 1, "rejected edit does not bump the version");
    }));
}

test("event pagination uses a composite cursor and never skips equal timestamps", () => withHarness(async h => {
    const at = "2026-10-01T00:00:00.000Z";
    await h.db.batch(Array.from({ length: 7 }, (_, i) => h.db.prepare("INSERT INTO events(id,name,venue,lifecycle,account_id,version,created_at,updated_at) VALUES(?,?,'', 'DRAFT','acct-a',1,?,?)").bind(`evt-${i}`, `E${i}`, at, at)));
    const seen = [];
    let cursor = null;
    do {
        const page = await op(h, "GET", `/v1/admin/events?limit=3${cursor ? `&cursor=${encodeURIComponent(cursor)}` : ""}`);
        seen.push(...page.json.events.map(e => e.id));
        cursor = page.json.nextCursor;
    } while (cursor);
    assert.equal(seen.length, 7);
    assert.equal(new Set(seen).size, 7);
}));

test("malformed identifiers and bodies return 4xx, never 500", () => withHarness(async h => {
    assert.equal((await op(h, "GET", "/v1/admin/events/%E0%A4%A")).status, 400);
    assert.equal((await op(h, "GET", `/v1/admin/events/${"x".repeat(101)}`)).status, 400);
    assert.equal((await op(h, "POST", "/v1/admin/events", { body: "{not json" })).status, 400);
    assert.equal((await op(h, "POST", "/v1/admin/events", { body: "[]" })).status, 400);
    assert.equal((await op(h, "POST", "/v1/admin/events", { body: { name: "" } })).status, 422);
    assert.equal((await op(h, "POST", "/v1/admin/events", { body: JSON.stringify({ name: "x".repeat(70_000) }) })).status, 413);
}));
