// Migration tests: fresh install, 0001 → 0002 → 0003 → 0004 upgrade with legacy data, and the
// same migrations applied by Wrangler's own D1 migration runner against a local database.
import test from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { createHarness, applyMigrations, migrationFiles, splitSQL } from "./support/harness.js";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

test("migration files are ordered and contiguous", () => {
    assert.deepEqual(migrationFiles().map(name => name.slice(0, 4)), ["0001", "0002", "0003", "0004", "0005", "0006", "0007", "0008"]);
});

test("health index upgrade preserves history and bounds reads as reconciliation history grows", async () => {
    const time = Date.parse("2026-11-11T00:00:00.000Z");
    const monitorToken = "monitor-read-test-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
    const h = await createHarness({ migrateUpTo: 7, fixedTime: time, bindings: { MONITOR_READ_TOKEN: monitorToken } });
    try {
        await h.db.prepare(`WITH RECURSIVE history(n) AS (
            SELECT 1 UNION ALL SELECT n+1 FROM history WHERE n<10000
        ) INSERT INTO reconciliation_runs(id,environment,started_at,finished_at)
          SELECT 'history-' || n,CASE WHEN n%2=0 THEN 'test' ELSE 'live' END,
            strftime('%Y-%m-%dT%H:%M:%fZ',? + n*300,'unixepoch'),
            strftime('%Y-%m-%dT%H:%M:%fZ',? + n*300+1,'unixepoch') FROM history`)
            .bind(time/1000-4000000, time/1000-4000000).run();
        const sql = "SELECT finished_at FROM reconciliation_runs WHERE environment=? ORDER BY started_at DESC LIMIT 1";
        const before = await h.db.prepare(sql).bind("test").all();
        assert.ok(before.meta.rows_read >= 10000, "reproduces the full-history scan before upgrade");
        await applyMigrations(h.db, ["0008_reconciliation_health_index.sql"]);
        const after = await h.db.prepare(sql).bind("test").all();
        assert.deepEqual(after.results, before.results, "latest-run result is unchanged");
        assert.ok(after.meta.rows_read <= 2, `indexed lookup read ${after.meta.rows_read} rows`);
        const plan = await h.all(`EXPLAIN QUERY PLAN ${sql}`, "test");
        assert.ok(plan.some(row => /SEARCH.*COVERING INDEX reconciliation_runs_environment_started_idx/.test(row.detail)));
        assert.ok(plan.every(row => !/SCAN reconciliation_runs|TEMP B-TREE/.test(row.detail)));
        assert.equal((await h.one("SELECT COUNT(*) c FROM reconciliation_runs")).c, 10000, "all history retained");

        const health = async () => {
            const response = await h.request("GET", "/v1/monitor-health", { token: monitorToken });
            assert.equal(response.status, 200);
            return response.json.reconciliationFresh;
        };
        assert.equal((await h.request("GET", "/v1/monitor-health", { token: null })).status, 401);
        assert.equal(await health(), false, "old completed history is stale");
        await h.db.prepare("INSERT INTO reconciliation_runs(id,environment,started_at,finished_at) VALUES('recent-test','test',?,?)")
            .bind(new Date(time-60000).toISOString(), new Date(time-30000).toISOString()).run();
        assert.equal(await health(), true, "a recent completed run is fresh");
        await h.db.prepare("INSERT INTO reconciliation_runs(id,environment,started_at) VALUES('unfinished-test','test',?)")
            .bind(new Date(time-10000).toISOString()).run();
        assert.equal(await health(), false, "newest unfinished run is not hidden by an older success");
        await h.db.prepare("UPDATE reconciliation_runs SET finished_at=? WHERE id='unfinished-test'")
            .bind(new Date(time).toISOString()).run();
        await h.db.prepare("INSERT INTO reconciliation_runs(id,environment,started_at) VALUES('unfinished-live','live',?)")
            .bind(new Date(time+10000).toISOString()).run();
        assert.equal(await health(), true, "another environment cannot mask this environment's latest completion");
        assert.equal((await h.all("PRAGMA foreign_key_check")).length, 0);
    } finally { await h.dispose(); }
});

test("SQL splitter keeps trigger bodies intact", () => {
    const statements = splitSQL("CREATE TABLE a(x);\nCREATE TRIGGER t BEFORE INSERT ON a\nBEGIN SELECT RAISE(ABORT, 'x'); END;\n-- c\nSELECT 1;");
    assert.equal(statements.length, 3);
    assert.match(statements[1], /RAISE\(ABORT, 'x'\); END;$/);
});

test("fresh install: schema, foreign keys, unique indexes and triggers exist", async () => {
    const h = await createHarness();
    try {
        const objects = await h.all("SELECT type, name FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' AND name NOT LIKE '_cf_%'");
        const names = new Set(objects.map(o => o.name));
        for (const name of ["orders", "payment_attempts", "entitlements", "offline_policy_snapshots", "offline_cash_sync_conflicts", "legacy_payment_conflicts",
            "orders_one_open_checkout", "payment_attempts_single_per_order", "payment_attempts_match_order_lock", "payment_attempts_paid_is_final",
            "entitlements_require_payment", "print_batches_one_per_entitlement", "events_single_active_per_account", "events_lifecycle_transitions", "policy_revisions_immutable"]) {
            assert.ok(names.has(name), `missing ${name}`);
        }
        assert.equal((await h.all("PRAGMA foreign_key_check")).length, 0);
        const fk = await h.all("PRAGMA foreign_key_list(orders)");
        assert.ok(fk.some(row => row.from === "supersedes_order_id" && row.table === "orders"));
    } finally { await h.dispose(); }
});

test("upgrade 0001→0003 with legacy data, then 0004: data preserved and conflicts quarantined", async () => {
    const h = await createHarness({ migrateUpTo: 3 });
    try {
        const at = "2026-09-01T00:00:00.000Z";
        await h.db.batch([
            h.db.prepare("INSERT INTO events(id,name,venue,lifecycle,account_id,version,created_at,updated_at) VALUES('legacy-event','Legacy','', 'ACTIVE','acct-a',1,?,?)").bind(at, at),
            h.db.prepare(`INSERT INTO event_policy_revisions(id,event_id,revision,commercial_mode,unit_price_centavos,max_copies,default_copies,cash_enabled,qrph_enabled,prepaid_guest_copy_choice,supported_formats_json,features_json,created_at)
                VALUES('legacy-rev','legacy-event',1,'PAY_PER_PRINT',5000,5,1,1,1,0,'["solo"]','{}',?)`).bind(at),
            h.db.prepare("UPDATE events SET active_policy_revision_id='legacy-rev' WHERE id='legacy-event'"),
            ...["clean", "dual"].map(id => h.db.prepare(`INSERT INTO orders(id,event_id,policy_revision_id,device_id,booth_format,copies,unit_price_centavos,total_centavos,currency,state,idempotency_key,created_at,updated_at)
                VALUES(?,'legacy-event','legacy-rev','dev-booth','solo',1,5000,5000,'PHP','AUTHORIZED',?,?,?)`).bind(id, `k-${id}`, at, at)),
            h.db.prepare("INSERT INTO payment_attempts(id,order_id,method,livemode,state,created_at,updated_at) VALUES('a-clean','clean','CASH_DECLARED',0,'SELF_REPORTED',?,?)").bind(at, at),
            h.db.prepare("INSERT INTO payment_attempts(id,order_id,method,livemode,state,created_at,updated_at) VALUES('a-dual-cash','dual','CASH_DECLARED',0,'SELF_REPORTED',?,?)").bind(at, at),
            h.db.prepare("INSERT INTO payment_attempts(id,order_id,method,provider_payment_intent_id,livemode,state,created_at,updated_at) VALUES('a-dual-qr','dual','QRPH','pi_legacy',0,'AWAITING_PAYMENT',?,?)").bind(at, at),
            ...["clean", "dual"].map(id => h.db.prepare("INSERT INTO entitlements(id,order_id,device_id,purchased_copies,authorization_source,state,created_at,updated_at) VALUES(?,?,'dev-booth',1,'UNVERIFIED_CASH_DECLARED','AUTHORIZED',?,?)").bind(`e-${id}`, id, at, at))
        ]);
        await applyMigrations(h.db, ["0004_phase3_integrity.sql"]);
        assert.equal((await h.one("SELECT COUNT(*) c FROM orders")).c, 2, "no rows dropped");
        assert.equal((await h.one("SELECT COUNT(*) c FROM payment_attempts")).c, 3, "legacy attempts retained");
        assert.equal((await h.one("SELECT payment_method FROM orders WHERE id='clean'")).payment_method, "CASH_DECLARED", "single-attempt orders backfilled");
        assert.deepEqual(await h.all("SELECT order_id, reason FROM legacy_payment_conflicts"), [{ order_id: "dual", reason: "MULTIPLE_PAYMENT_ATTEMPTS" }]);
        assert.equal((await h.one("SELECT state FROM orders WHERE id='dual'")).state, "MANUAL_REVIEW");
        assert.equal((await h.one("SELECT state FROM entitlements WHERE id='e-dual'")).state, "REVIEW_REQUIRED");
        assert.equal((await h.one("SELECT state FROM entitlements WHERE id='e-clean'")).state, "AUTHORIZED");
        assert.equal((await h.all("PRAGMA foreign_key_check")).length, 0);
        await assert.rejects(h.db.prepare("INSERT INTO payment_attempts(id,order_id,method,livemode,state,created_at,updated_at) VALUES('new','clean','CASH_DECLARED',0,'SELF_REPORTED',?,?)").bind(at, at).run(), /payment_method_locked/);
    } finally { await h.dispose(); }
});

test("Wrangler's D1 migration runner applies every migration to a local TEST database", { timeout: 180_000 }, () => {
    const persist = mkdtempSync(path.join(tmpdir(), "pp-d1-"));
    try {
        const run = args => execFileSync(path.join(root, "node_modules/.bin/wrangler"), args, { cwd: root, encoding: "utf8", env: { ...process.env, WRANGLER_SEND_METRICS: "false", CI: "1" } });
        const output = run(["d1", "migrations", "apply", "pocket-pixels-payments-test", "--env", "test", "--local", "--persist-to", persist]);
        for (const name of migrationFiles()) assert.match(output, new RegExp(name.replace(".", "\\.")));
        const listed = run(["d1", "execute", "pocket-pixels-payments-test", "--env", "test", "--local", "--persist-to", persist, "--json", "--command",
            "SELECT COUNT(*) AS triggers FROM sqlite_master WHERE type='trigger'"]);
        assert.ok(JSON.parse(listed)[0].results[0].triggers >= 15);
    } finally { rmSync(persist, { recursive: true, force: true }); }
});
