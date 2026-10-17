// Exactly-once commercial-event creation: stable operation IDs, payload consistency, lost-response
// recovery by exact lookup, account isolation and compatibility with clients that send no ID.
import test from "node:test";
import assert from "node:assert/strict";
import { createHarness, TOKENS } from "./support/harness.js";
import { applyMigrations, migrationFiles } from "./support/harness.js";

async function withHarness(body, options) {
    const h = await createHarness(options);
    try { await body(h); } finally { await h.dispose(); }
}
const op = (h, method, path, options = {}) => h.request(method, path, { token: TOKENS.operator, ...options });
const create = (h, key, body = { name: "Gala Night", venue: "Ballroom" }, token = TOKENS.operator) =>
    h.request("POST", "/v1/admin/events", { token, body, headers: key ? { "idempotency-key": key } : {} });
const eventCount = async h => (await h.one("SELECT COUNT(*) c FROM events")).c;

test("same operation ID returns the original event instead of creating another", () => withHarness(async h => {
    const before = await eventCount(h);
    const first = await create(h, "op-1");
    assert.equal(first.status, 201);
    assert.equal(first.json.operationId, "op-1");
    assert.equal(first.json.replayed, false);
    const again = await create(h, "op-1");
    assert.equal(again.status, 200);
    assert.equal(again.json.id, first.json.id);
    assert.equal(again.json.replayed, true);
    assert.equal(await eventCount(h), before + 1, "exactly one event");
    const audits = await h.all("SELECT action FROM operator_audit_log WHERE event_id=?", first.json.id);
    assert.deepEqual(audits.map(a => a.action), ["EVENT_CREATED"], "a replay writes no second audit entry");
}));

test("same operation ID with a different payload fails clearly and creates nothing", () => withHarness(async h => {
    const first = await create(h, "op-2");
    const before = await eventCount(h);
    const mismatch = await create(h, "op-2", { name: "Other Event", venue: "Ballroom" });
    assert.equal(mismatch.status, 422);
    assert.equal(mismatch.json.error, "idempotency_mismatch");
    assert.equal(await eventCount(h), before);
    // Normalization is applied before fingerprinting, so whitespace noise is the same payload.
    const normalized = await create(h, "op-2", { name: "  Gala   Night ", venue: "Ballroom" });
    assert.equal(normalized.json.id, first.json.id);
}));

test("lost response: exact lookup by operation ID finds the original event", () => withHarness(async h => {
    const created = await create(h, "op-lost");
    const lookup = await op(h, "GET", "/v1/admin/event-creations/op-lost");
    assert.equal(lookup.status, 200);
    assert.equal(lookup.json.event.id, created.json.id);
    assert.equal(lookup.json.event.lifecycle, "DRAFT");
    const missing = await op(h, "GET", "/v1/admin/event-creations/op-never-sent");
    assert.equal(missing.status, 404);
    assert.equal(missing.json.error, "creation_not_found", "distinguishable from an unknown route");
    assert.equal((await op(h, "GET", "/v1/admin/no-such-route")).json.error, "not_found");
}));

test("operation IDs are account-scoped: another account neither sees nor replays them", () => withHarness(async h => {
    const mine = await create(h, "op-shared");
    assert.equal((await h.request("GET", "/v1/admin/event-creations/op-shared", { token: TOKENS.otherAccount })).json.error, "creation_not_found");
    const theirs = await create(h, "op-shared", undefined, TOKENS.otherAccount);
    assert.equal(theirs.status, 201);
    assert.notEqual(theirs.json.id, mine.json.id, "same ID in another account is a separate creation");
}));

test("older clients without an operation ID keep the original behaviour", () => withHarness(async h => {
    const a = await create(h, null), b = await create(h, null);
    assert.equal(a.status, 201);
    assert.notEqual(a.json.id, b.json.id);
    assert.equal(a.json.operationId, undefined);
    const row = await h.one("SELECT creation_operation_id, creation_fingerprint FROM events WHERE id=?", a.json.id);
    assert.equal(row.creation_operation_id, null);
    assert.equal(row.creation_fingerprint, null);
}));

test("invalid operation IDs and booth-only credentials are refused", () => withHarness(async h => {
    assert.equal((await create(h, "bad id with spaces")).json.error, "invalid_idempotency_key");
    assert.equal((await h.request("GET", "/v1/admin/event-creations/op-1", { token: TOKENS.boothOnly })).status, 403);
}));

test("concurrent requests with the same operation ID create one event", () => withHarness(async h => {
    const results = await Promise.all([create(h, "op-race"), create(h, "op-race"), create(h, "op-race")]);
    assert.equal(new Set(results.map(r => r.json.id)).size, 1);
    assert.equal((await h.one("SELECT COUNT(*) c FROM events WHERE creation_operation_id='op-race'")).c, 1);
}));

test("upgrade 0005 → 0006 keeps every existing event and allows NULL operation IDs", async () => {
    const h = await createHarness({ migrateUpTo: 5 });
    try {
        const at = "2026-10-01T00:00:00.000Z";
        for (const id of ["legacy-a", "legacy-b"]) {
            await h.db.prepare("INSERT INTO events(id,name,venue,lifecycle,account_id,version,created_at,updated_at) VALUES(?,?,'', 'DRAFT','acct-a',1,?,?)").bind(id, id, at, at).run();
        }
        await applyMigrations(h.db, migrationFiles().filter(name => name.startsWith("0006")));
        assert.equal((await h.one("SELECT COUNT(*) c FROM events WHERE creation_operation_id IS NULL")).c, 2);
        assert.equal((await h.all("PRAGMA foreign_key_check")).length, 0);
    } finally { await h.dispose(); }
});

test("deployment order: before migration 0006, keyless creation still works and a keyed one fails without creating", async () => {
    const h = await createHarness({ migrateUpTo: 5 });
    try {
        assert.equal((await create(h, null)).status, 201, "current app builds keep working if the Worker is deployed first");
        const before = await eventCount(h);
        const keyed = await create(h, "op-early");
        assert.equal(keyed.status, 500);
        assert.equal(await eventCount(h), before, "nothing is created; the booth keeps the request for exact recovery");
    } finally { await h.dispose(); }
});
