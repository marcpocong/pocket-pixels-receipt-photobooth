// Route-level harness: runs the real Worker module in workerd (Miniflare) against a fresh,
// fully migrated local D1 database. PayMongo is replaced by a controllable outbound stub.
import { Miniflare, convertV4MiniflareOptions } from "miniflare";
import { readFileSync, readdirSync } from "node:fs";
import { createHash, webcrypto } from "node:crypto";
import { fileURLToPath } from "node:url";
import path from "node:path";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
export const migrationsDir = path.join(root, "migrations");
export const encoder = new TextEncoder();

/// Splits a migration file into statements, keeping CREATE TRIGGER ... END; bodies intact.
export function splitSQL(text) {
    const statements = [];
    let current = [], inTrigger = false;
    for (const line of text.split("\n")) {
        const trimmed = line.trim();
        if (!current.length && (trimmed === "" || trimmed.startsWith("--"))) continue;
        current.push(line);
        if (/^CREATE TRIGGER/i.test(trimmed)) inTrigger = true;
        const ends = inTrigger ? /\bEND;\s*$/i.test(trimmed) : trimmed.endsWith(";");
        if (ends) { statements.push(current.join("\n")); current = []; inTrigger = false; }
    }
    if (current.join("").trim()) statements.push(current.join("\n"));
    return statements;
}

export function migrationFiles(upTo = Infinity) {
    return readdirSync(migrationsDir).filter(name => name.endsWith(".sql")).sort().filter(name => Number(name.slice(0, 4)) <= upTo);
}

export async function applyMigrations(db, files) {
    for (const file of files) {
        const statements = splitSQL(readFileSync(path.join(migrationsDir, file), "utf8")).filter(sql => !/^PRAGMA/i.test(sql.trim()));
        await db.batch(statements.map(sql => db.prepare(sql)));
    }
}

/// Programmable PayMongo stand-in. Tests mutate `intents` and `faults` to simulate outcomes.
export class ProviderStub {
    constructor() { this.calls = []; this.intents = new Map(); this.faults = []; this.counter = 0; }
    fault(match, behavior) { this.faults.push({ match, behavior }); }
    async handle(request) {
        const url = new URL(request.url);
        const route = `${request.method} ${url.pathname.replace(/^\/v1/, "")}`;
        const body = request.method === "POST" ? await request.json() : null;
        this.calls.push({ route, body, authorization: request.headers.get("authorization") });
        const index = this.faults.findIndex(f => route.match(f.match));
        if (index >= 0) {
            const { behavior } = this.faults.splice(index, 1)[0];
            if (behavior === "network") throw new Error("simulated network failure");
            if (typeof behavior === "number") return Response.json({ errors: [{ detail: "sk_test_SECRETLEAK should never surface" }] }, { status: behavior });
            if (behavior.delayMs) await new Promise(resolve => setTimeout(resolve, behavior.delayMs));
            if (behavior.json) return Response.json(behavior.json, { status: behavior.status || 200 });
        }
        if (route === "POST /payment_intents") {
            const id = `pi_${++this.counter}`;
            const intent = { id, type: "payment_intent", attributes: { amount: body.data.attributes.amount, currency: "PHP", livemode: false, status: "awaiting_payment_method", client_key: `${id}_client`, payments: [] } };
            this.intents.set(id, intent);
            return Response.json({ data: intent });
        }
        if (route === "POST /payment_methods") return Response.json({ data: { id: `pm_${++this.counter}`, type: "payment_method" } });
        const attach = route.match(/^POST \/payment_intents\/([^/]+)\/attach$/);
        if (attach) {
            const intent = this.intents.get(attach[1]);
            intent.attributes.status = "awaiting_next_action";
            return Response.json({ data: { ...intent, attributes: { ...intent.attributes, next_action: { type: "consume_qr", code: { image_url: "data:image/png;base64,iVBORw0KGgo=", test_url: `https://test.paymongo.example/${intent.id}` } } } } });
        }
        const read = route.match(/^GET \/payment_intents\/([^/]+)$/);
        if (read && this.intents.has(read[1])) return Response.json({ data: this.intents.get(read[1]) });
        return Response.json({ errors: [{ detail: "not found" }] }, { status: 404 });
    }
    markPaid(intentId) {
        const intent = this.intents.get(intentId);
        intent.attributes.status = "succeeded";
        intent.attributes.payments = [{ id: `pay_${intentId}` }];
    }
    count(route) { return this.calls.filter(call => call.route === route).length; }
}

export const WEBHOOK_SECRET = "whsk_test_harness_only_value";
export const TOKENS = {
    booth: "booth-token-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
    booth2: "booth-token-BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB",
    operator: "operator-token-CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC",
    otherAccount: "other-account-DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD",
    boothOnly: "booth-only-EEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEE",
    revoked: "revoked-token-FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF"
};

export async function generateSigningKey() {
    const pair = await webcrypto.subtle.generateKey({ name: "Ed25519" }, true, ["sign", "verify"]);
    const pkcs8 = Buffer.from(await webcrypto.subtle.exportKey("pkcs8", pair.privateKey)).toString("base64");
    const raw = Buffer.from(await webcrypto.subtle.exportKey("raw", pair.publicKey));
    return { pkcs8, publicKey: pair.publicKey, publicRaw: raw };
}

export async function createHarness({ bindings = {}, migrateUpTo = Infinity, seedDevices = true } = {}) {
    const provider = new ProviderStub();
    const signing = await generateSigningKey();
    const mf = new Miniflare(convertV4MiniflareOptions({
        modulesRoot: root,
        modules: ["src/index.js", "src/domain.js"].map(file => ({ type: "ESModule", path: path.join(root, file) })),
        compatibilityDate: "2026-10-01",
        d1Databases: ["DB"],
        bindings: {
            PAYMENTS_ENVIRONMENT: "test", LIVE_PAYMENTS_ENABLED: "false", PAYMONGO_API_BASE: "https://paymongo.stub/v1",
            QR_EXPIRY_SECONDS: "300", RECONCILIATION_BATCH_SIZE: "25", PROVIDER_TIMEOUT_MS: "2000",
            PAYMONGO_SECRET_KEY_TEST: "sk_test_harnessSecretValue", PAYMONGO_PUBLIC_KEY_TEST: "pk_test_harnessPublicValue",
            PAYMONGO_WEBHOOK_SECRET_TEST: WEBHOOK_SECRET, OFFLINE_POLICY_SIGNING_KEY: signing.pkcs8, OFFLINE_POLICY_KEY_ID: "test-k1",
            ...bindings
        },
        outboundService: request => provider.handle(request)
    }));
    const db = await mf.getD1Database("DB");
    await applyMigrations(db, migrationFiles(migrateUpTo));
    if (seedDevices) await seed(db);
    const harness = {
        mf, db, provider, signing,
        async request(method, pathname, { token = TOKENS.booth, body, headers = {} } = {}) {
            const init = { method, headers: { ...(token ? { authorization: `Bearer ${token}` } : {}), ...headers } };
            if (body !== undefined) { init.body = typeof body === "string" ? body : JSON.stringify(body); init.headers["content-type"] = "application/json"; }
            const response = await mf.dispatchFetch(`https://payments.test${pathname}`, init);
            const text = await response.text();
            let json = null;
            try { json = JSON.parse(text); } catch {}
            return { status: response.status, json, text, headers: response.headers };
        },
        async scheduled(time = Date.now()) {
            const worker = await mf.getWorker();
            return worker.scheduled({ cron: "*/5 * * * *", scheduledTime: new Date(time) });
        },
        async one(sql, ...values) { return db.prepare(sql).bind(...values).first(); },
        async all(sql, ...values) { return (await db.prepare(sql).bind(...values).all()).results; },
        async dispose() { await mf.dispose(); }
    };
    return harness;
}

export function sha256(value) { return createHash("sha256").update(value).digest("hex"); }

async function seed(db) {
    const at = new Date().toISOString();
    const rows = [
        ["dev-booth", TOKENS.booth, "Booth A", "booth,operator", null, "acct-a"],
        ["dev-booth-2", TOKENS.booth2, "Booth B", "booth", null, "acct-a"],
        ["dev-operator", TOKENS.operator, "Operator", "operator", null, "acct-a"],
        ["dev-other", TOKENS.otherAccount, "Other account", "booth,operator", null, "acct-b"],
        ["dev-booth-only", TOKENS.boothOnly, "Booth only", "booth", null, "acct-a"],
        ["dev-revoked", TOKENS.revoked, "Revoked", "booth,operator", at, "acct-a"]
    ];
    await db.batch(rows.map(([id, token, name, scopes, revoked, account]) =>
        db.prepare("INSERT INTO devices(id,credential_hash,display_name,scopes,revoked_at,created_at,account_id) VALUES(?,?,?,?,?,?,?)").bind(id, sha256(token), name, scopes, revoked, at, account)));
}

export const PAID_POLICY = {
    commercialMode: "PAY_PER_PRINT", unitPriceCentavos: 5_000, maxCopies: 5, defaultCopies: 1,
    cashEnabled: true, qrphEnabled: true, prepaidGuestCopyChoice: false, supportedFormats: ["solo", "strip"], features: {}
};

/// Creates, drafts, publishes and activates a paid event; returns its active policy.
export async function activePaidEvent(h, { policy = PAID_POLICY, token = TOKENS.operator, name = "Launch Party" } = {}) {
    const created = await h.request("POST", "/v1/admin/events", { token, body: { name, venue: "Makati" } });
    const id = created.json.id;
    const draft = await h.request("PATCH", `/v1/admin/events/${id}`, { token, headers: { "if-match": "1" }, body: { policy } });
    const revision = draft.json.draftRevision;
    const activated = await h.request("POST", `/v1/admin/events/${id}/activate`, { token, headers: { "if-match": "2" }, body: { policyRevisionId: revision.id, acknowledgedUnitPriceCentavos: revision.unitPriceCentavos } });
    if (activated.status !== 200) throw new Error(`activation failed: ${activated.text}`);
    return { eventId: id, revisionId: revision.id, unitPriceCentavos: revision.unitPriceCentavos, version: activated.json.version };
}

let sessionCounter = 0;
export async function newOrder(h, event, { copies = 2, format = "solo", token = TOKENS.booth, session = `session-${++sessionCounter}`, key = `key-${session}`, supersedesOrderId } = {}) {
    const response = await h.request("POST", "/v1/orders", { token, headers: { "idempotency-key": key }, body: {
        eventId: event.eventId, format, copies, checkoutSessionId: session, expectedPolicyRevisionId: event.revisionId, expectedUnitPriceCentavos: event.unitPriceCentavos,
        ...(supersedesOrderId ? { supersedesOrderId } : {})
    } });
    return { ...response, session, order: response.json?.order };
}

export async function signedWebhook(h, payload, { secret = WEBHOOK_SECRET, live = false, timestamp = Math.floor(Date.now() / 1000), endpoint } = {}) {
    const raw = typeof payload === "string" ? payload : JSON.stringify(payload);
    const key = await webcrypto.subtle.importKey("raw", encoder.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
    const digest = Buffer.from(await webcrypto.subtle.sign("HMAC", key, encoder.encode(`${timestamp}.${raw}`))).toString("hex");
    const header = live ? `t=${timestamp},te=,li=${digest}` : `t=${timestamp},te=${digest},li=`;
    return h.request("POST", endpoint || (live ? "/v1/webhooks/paymongo/live" : "/v1/webhooks/paymongo/test"), { token: null, body: raw, headers: { "paymongo-signature": header } });
}

export function paidEvent(intentId, amount, { id = `evt_${intentId}_${Math.random().toString(36).slice(2)}`, livemode = false, currency = "PHP" } = {}) {
    return { data: { id, type: "event", attributes: { type: "payment.paid", livemode, created_at: Math.floor(Date.now() / 1000), data: {
        id: `pay_${intentId}`, type: "payment", attributes: { amount, currency, livemode, status: "paid", payment_intent_id: intentId } } } } };
}
