import {
    boundedLimit, csvRow, decodeCursor, encodeCursor, isoTimestamp, nextProviderState, providerIntentEvidence,
    reportCategory, supersedeDecision, SUPERSEDE_GRACE_MS
} from "./domain.js";

const JSON_HEADERS = { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" };
const ALLOWED_FORMATS = new Set(["solo", "duo", "grid", "strip", "gridSix", "passport", "photoPass"]);
const ID_PATTERN = /^[A-Za-z0-9._:-]{1,100}$/;
const MAX_UNIT_PRICE_CENTAVOS = 10_000_000; // ₱100,000 per copy guards against typos.
const ORDER_PAYMENT_WINDOW_MS = 30 * 60 * 1000;
const CLOCK_SKEW_MS = 5 * 60 * 1000;
const PROVIDER_TIMEOUT_MS = 10_000;
const MAX_BODY_BYTES = 64 * 1024;
const CSV_PAGE_SIZE = 5_000;
const encoder = new TextEncoder();

export default {
    async fetch(request, env) {
        try {
            return await route(request, env);
        } catch (error) {
            const status = error.status || 500;
            if (status >= 500) console.error(JSON.stringify({ event: "request_failed", status, message: safeError(error) }));
            return json({ error: error.code || (status >= 500 ? "request_failed" : "rejected"), message: safePublicError(error), ...(error.details || {}) }, status);
        }
    },
    async scheduled(controller, env, ctx) {
        ctx.waitUntil(runScheduledReconciliation(env, controller.scheduledTime));
    }
};

export async function route(request, env) {
    const url = new URL(request.url);
    const path = url.pathname;
    if (request.method === "GET" && path === "/v1/health") {
        return json({ service: "pocket-pixels-payments", version: "3", environment: environment(env), liveEnabled: isLiveEnabled(env) });
    }
    if (request.method === "POST" && path === "/v1/webhooks/paymongo/test") return paymongoWebhook(request, env, false);
    if (request.method === "POST" && path === "/v1/webhooks/paymongo/live") return paymongoWebhook(request, env, true);

    const principal = await authenticateWithThrottle(request, env);
    await enforceRateLimit(env, principal.id, request.method === "GET" ? 240 : 60);
    if (request.method === "GET" && path === "/v1/device") return deviceInfo(env, principal);

    if (/^\/v1\/(events\/active|orders|checkouts|entitlements|prints|sync)(\/|$)/.test(path)) requireScope(principal, "booth");
    if (request.method === "GET" && path === "/v1/events/active") return getActiveEvent(env, principal);
    if (request.method === "POST" && path === "/v1/orders") return createOrder(request, env, principal);
    if (request.method === "POST" && /^\/v1\/orders\/[^/]+\/qrph$/.test(path)) return createQR(request, env, principal, segment(path, 3));
    if (request.method === "POST" && /^\/v1\/orders\/[^/]+\/cash-declaration$/.test(path)) return declareCash(request, env, principal, segment(path, 3));
    if (request.method === "GET" && /^\/v1\/orders\/[^/]+\/status$/.test(path)) return orderStatus(env, principal, segment(path, 3));
    if (request.method === "GET" && /^\/v1\/checkouts\/[^/]+$/.test(path)) return checkoutRecovery(env, principal, segment(path, 3));
    if (request.method === "POST" && /^\/v1\/entitlements\/[^/]+\/claim$/.test(path)) return claimEntitlement(request, env, principal, segment(path, 3));
    if (request.method === "POST" && /^\/v1\/entitlements\/[^/]+\/complete$/.test(path)) return completeEntitlement(request, env, principal, segment(path, 3));
    if (request.method === "POST" && /^\/v1\/prints\/[^/]+\/progress$/.test(path)) return recordPrint(request, env, principal, segment(path, 3));
    if (request.method === "POST" && path === "/v1/sync/offline-cash") return syncOfflineCash(request, env, principal);

    requireScope(principal, "operator");
    if (request.method === "GET" && path === "/v1/admin/events") return listEvents(request, env, principal);
    if (request.method === "POST" && path === "/v1/admin/events") return createEvent(request, env, principal);
    if (request.method === "GET" && /^\/v1\/admin\/events\/[^/]+$/.test(path)) return getEvent(env, principal, segment(path, 4));
    if (request.method === "PATCH" && /^\/v1\/admin\/events\/[^/]+$/.test(path)) return updateEvent(request, env, principal, segment(path, 4));
    if (request.method === "POST" && /^\/v1\/admin\/events\/[^/]+\/(activate|publish|pause|resume|end|archive)$/.test(path)) {
        return transitionEvent(request, env, principal, segment(path, 4), segment(path, 5));
    }
    if (request.method === "GET" && /^\/v1\/admin\/events\/[^/]+\/summary$/.test(path)) return eventSummary(request, env, principal, segment(path, 4));
    if (request.method === "GET" && /^\/v1\/admin\/events\/[^/]+\/orders$/.test(path)) return eventOrders(request, env, principal, segment(path, 4));
    if (request.method === "GET" && /^\/v1\/admin\/events\/[^/]+\/offline-conflicts$/.test(path)) return offlineConflicts(request, env, principal, segment(path, 4));
    if (request.method === "GET" && /^\/v1\/admin\/events\/[^/]+\/export.csv$/.test(path)) return eventCSV(request, env, principal, segment(path, 4));
    if (request.method === "POST" && /^\/v1\/admin\/events\/[^/]+\/cash-counts$/.test(path)) return recordCashCount(request, env, principal, segment(path, 4));
    if (request.method === "POST" && /^\/v1\/admin\/orders\/[^/]+\/cash-confirmation$/.test(path)) return confirmCash(request, env, principal, segment(path, 4));
    if (request.method === "GET" && path === "/v1/admin/diagnostics") return diagnostics(env, principal);
    return json({ error: "not_found" }, 404);
}

// MARK: - Authentication

async function authenticateWithThrottle(request, env) {
    try {
        return await authenticate(request, env);
    } catch (error) {
        // Failed credentials are rate limited per client address so token guessing is bounded.
        const address = request.headers.get("cf-connecting-ip") || "unknown";
        await enforceRateLimit(env, `authfail:${address}`, 30);
        throw error;
    }
}

async function authenticate(request, env) {
    const value = request.headers.get("authorization") || "";
    if (!value.startsWith("Bearer ")) throw http(401, "Authentication required.", "unauthorized");
    const token = value.slice(7).trim();
    if (token.length < 32 || token.length > 512) throw http(401, "Invalid credential.", "unauthorized");
    const hash = await sha256Hex(token);
    const device = await env.DB.prepare("SELECT id, account_id, display_name, scopes, revoked_at FROM devices WHERE credential_hash = ?").bind(hash).first();
    if (!device || device.revoked_at) throw http(401, "Credential is invalid or revoked.", "unauthorized");
    return { id: device.id, accountId: device.account_id || "default", displayName: device.display_name, scopes: new Set(device.scopes.split(",").map(value => value.trim())) };
}

function requireScope(principal, scope) {
    if (!principal.scopes.has(scope)) throw http(403, scope === "operator" ? "Operator authorization required." : "Booth authorization required.", "forbidden");
}

async function enforceRateLimit(env, key, limit) {
    const window = Math.floor(Date.now() / 60000);
    const result = await env.DB.prepare(`INSERT INTO request_rate_limits(key, minute_window, request_count)
        VALUES (?, ?, 1) ON CONFLICT(key, minute_window) DO UPDATE SET request_count = request_count + 1
        RETURNING request_count`).bind(key, window).first();
    if (result.request_count > limit) throw http(429, "Too many requests. Try again shortly.", "rate_limited");
}

function deviceInfo(env, principal) {
    return json({ device: { id: principal.id, accountId: principal.accountId, displayName: principal.displayName, scopes: [...principal.scopes].sort() }, environment: environment(env), serverTime: now() });
}

// MARK: - Events (operator)

async function listEvents(request, env, principal) {
    const url = new URL(request.url), limit = boundedLimit(url.searchParams.get("limit"), 25, 100);
    const cursor = decodeCursor(url.searchParams.get("cursor")) || { timestamp: "9999-12-31T23:59:59.999Z", id: "￿" };
    const rows = await env.DB.prepare(`SELECT e.id,e.name,e.venue,e.lifecycle,e.active_policy_revision_id,e.starts_at,e.ends_at,e.version,e.updated_at,
            p.revision active_revision,p.unit_price_centavos active_unit_price_centavos,p.commercial_mode active_commercial_mode
        FROM events e LEFT JOIN event_policy_revisions p ON p.id=e.active_policy_revision_id
        WHERE e.account_id=? AND (e.updated_at<? OR (e.updated_at=? AND e.id<?)) ORDER BY e.updated_at DESC, e.id DESC LIMIT ?`)
        .bind(principal.accountId, cursor.timestamp, cursor.timestamp, cursor.id, limit + 1).all();
    const values = rows.results || [], hasMore = values.length > limit, page = values.slice(0, limit);
    return json({ events: page, nextCursor: hasMore ? encodeCursor(page.at(-1).updated_at, page.at(-1).id) : null });
}

async function getEvent(env, principal, eventId) {
    const event = await env.DB.prepare("SELECT * FROM events WHERE id=? AND account_id=?").bind(eventId, principal.accountId).first();
    if (!event) throw http(404, "Event not found.", "event_not_found");
    const active = event.active_policy_revision_id
        ? await env.DB.prepare("SELECT * FROM event_policy_revisions WHERE id=?").bind(event.active_policy_revision_id).first()
        : null;
    const latest = await env.DB.prepare("SELECT * FROM event_policy_revisions WHERE event_id=? ORDER BY revision DESC LIMIT 1").bind(eventId).first();
    const outstanding = await env.DB.prepare(`SELECT COUNT(*) count FROM entitlements en JOIN orders o ON o.id=en.order_id
        WHERE o.event_id=? AND en.state IN ('AUTHORIZED','IN_SESSION')`).bind(eventId).first();
    return json({
        event: {
            id: event.id, name: event.name, venue: event.venue, lifecycle: event.lifecycle, version: event.version,
            startsAt: event.starts_at, endsAt: event.ends_at, updatedAt: event.updated_at,
            activePolicyRevisionId: event.active_policy_revision_id
        },
        activePolicy: active ? policyRevision(active) : null,
        latestRevision: latest ? policyRevision(latest) : null,
        hasUnpublishedRevision: !!latest && latest.id !== event.active_policy_revision_id,
        outstandingEntitlements: Number(outstanding?.count || 0),
        serverTime: now()
    });
}

async function createEvent(request, env, principal) {
    const body = await bodyJSON(request);
    const id = crypto.randomUUID();
    const timestamp = now();
    await env.DB.prepare("INSERT INTO events(id,name,venue,lifecycle,account_id,version,created_at,updated_at) VALUES(?,?,?,'DRAFT',?,1,?,?)")
        .bind(id, clean(body.name, 80), cleanOptional(body.venue, 120), principal.accountId, timestamp, timestamp).run();
    await audit(env, principal.id, id, null, "EVENT_CREATED", { name: clean(body.name, 80) });
    return json({ id, lifecycle: "DRAFT", version: 1 }, 201);
}

/// Saves name/venue and, optionally, a new *draft* policy revision. Never changes the active policy.
async function updateEvent(request, env, principal, eventId) {
    const body = await bodyJSON(request);
    const expectedVersion = expectedVersionFrom(request, body);
    const event = await env.DB.prepare("SELECT * FROM events WHERE id=? AND account_id=?").bind(eventId, principal.accountId).first();
    if (!event) throw http(404, "Event not found.", "event_not_found");
    if (["ENDED", "ARCHIVED"].includes(event.lifecycle)) throw http(409, "Ended or archived events cannot be edited.", "event_not_editable");
    if (event.version !== expectedVersion) throw versionConflict(event.version);
    const policy = body.policy === undefined ? null : validatePolicy(body.policy);
    const mutationId = crypto.randomUUID(), policyId = crypto.randomUUID(), timestamp = now();
    const statements = [
        env.DB.prepare("UPDATE events SET name=?,venue=?,version=version+1,last_mutation_id=?,updated_at=? WHERE id=? AND account_id=? AND version=? AND lifecycle IN ('DRAFT','ACTIVE','PAUSED')")
            .bind(body.name === undefined ? event.name : clean(body.name, 80), body.venue === undefined ? event.venue : cleanOptional(body.venue, 120), mutationId, timestamp, eventId, principal.accountId, expectedVersion)
    ];
    if (policy) {
        // The revision is only inserted when the guarded version bump above won (same transaction).
        statements.push(env.DB.prepare(`INSERT INTO event_policy_revisions(id,event_id,revision,commercial_mode,unit_price_centavos,max_copies,default_copies,cash_enabled,qrph_enabled,prepaid_guest_copy_choice,supported_formats_json,features_json,offline_valid_until,created_at)
            SELECT ?,?,(SELECT COALESCE(MAX(revision),0)+1 FROM event_policy_revisions WHERE event_id=?),?,?,?,?,?,?,?,?,?,?,? FROM events WHERE id=? AND last_mutation_id=?`)
            .bind(policyId, eventId, eventId, policy.commercialMode, policy.unitPriceCentavos, policy.maxCopies, policy.defaultCopies, +policy.cashEnabled, +policy.qrphEnabled, +policy.prepaidGuestCopyChoice,
                JSON.stringify(policy.supportedFormats), JSON.stringify(policy.features), policy.offlineValidUntil, timestamp, eventId, mutationId));
    }
    const results = await env.DB.batch(statements);
    if (changes(results[0]) !== 1) {
        const current = await env.DB.prepare("SELECT version FROM events WHERE id=?").bind(eventId).first();
        throw versionConflict(current?.version);
    }
    const revision = policy ? await env.DB.prepare("SELECT * FROM event_policy_revisions WHERE id=?").bind(policyId).first() : null;
    await audit(env, principal.id, eventId, null, policy ? "POLICY_DRAFTED" : "EVENT_DETAILS_UPDATED", revision ? { revision: revision.revision, commercialMode: revision.commercial_mode, unitPriceCentavos: revision.unit_price_centavos } : {});
    return json({ eventId, version: expectedVersion + 1, draftRevision: revision ? policyRevision(revision) : null });
}

async function transitionEvent(request, env, principal, eventId, action) {
    const body = await bodyJSON(request, true);
    const expectedVersion = expectedVersionFrom(request, body);
    const event = await env.DB.prepare("SELECT * FROM events WHERE id=? AND account_id=?").bind(eventId, principal.accountId).first();
    if (!event) throw http(404, "Event not found.", "event_not_found");
    if (event.version !== expectedVersion) throw versionConflict(event.version);
    const transitions = {
        activate: [["DRAFT"], "ACTIVE"], publish: [["DRAFT", "ACTIVE", "PAUSED"], null], pause: [["ACTIVE"], "PAUSED"],
        resume: [["PAUSED"], "ACTIVE"], end: [["ACTIVE", "PAUSED"], "ENDED"], archive: [["ENDED", "DRAFT"], "ARCHIVED"]
    };
    const [allowed, target] = transitions[action];
    if (!allowed.includes(event.lifecycle)) throw http(409, `Cannot ${action} an event that is ${event.lifecycle}.`, "invalid_lifecycle_transition", { lifecycle: event.lifecycle });

    let policyId = event.active_policy_revision_id;
    if (action === "publish" || (action === "activate" && body.policyRevisionId)) {
        // The operator must acknowledge the exact revision *and* its price; no "latest" fallback.
        if (!body.policyRevisionId || !ID_PATTERN.test(body.policyRevisionId)) throw http(422, "An explicit policy revision is required.", "policy_revision_required");
        const policy = await env.DB.prepare("SELECT * FROM event_policy_revisions WHERE id=? AND event_id=?").bind(body.policyRevisionId, eventId).first();
        validateStoredPolicy(policy);
        if (integer(body.acknowledgedUnitPriceCentavos) !== policy.unit_price_centavos) {
            throw http(409, "The acknowledged price does not match this revision. Review it again before publishing.", "acknowledgement_mismatch");
        }
        policyId = policy.id;
    }
    if (target === "ACTIVE") {
        if (!policyId) throw http(422, "Publish a valid policy revision before activating.", "policy_revision_required");
        validateStoredPolicy(await env.DB.prepare("SELECT * FROM event_policy_revisions WHERE id=?").bind(policyId).first());
    }
    const timestamp = now(), nextLifecycle = target || event.lifecycle;
    const statements = [
        env.DB.prepare("UPDATE events SET lifecycle=?,active_policy_revision_id=?,version=version+1,updated_at=? WHERE id=? AND account_id=? AND version=? AND lifecycle=?")
            .bind(nextLifecycle, policyId, timestamp, eventId, principal.accountId, expectedVersion, event.lifecycle),
        env.DB.prepare("UPDATE event_policy_revisions SET activated_at=? WHERE id=? AND activated_at IS NULL").bind(timestamp, policyId)
    ];
    if (action !== "resume" && action !== "activate") {
        // Pausing, ending, archiving or republishing stops reuse of previously issued offline policy.
        statements.push(env.DB.prepare("UPDATE offline_policy_snapshots SET revoked_at=?,revoked_reason=? WHERE event_id=? AND revoked_at IS NULL").bind(timestamp, `EVENT_${action.toUpperCase()}`, eventId));
    }
    let results;
    try {
        results = await env.DB.batch(statements);
    } catch (error) {
        if (/another_event_active/.test(error.message)) throw http(409, "Another event is already active for this account. Pause or end it first.", "another_event_active");
        if (/invalid_lifecycle_transition/.test(error.message)) throw http(409, "That lifecycle change is not allowed.", "invalid_lifecycle_transition");
        throw error;
    }
    if (changes(results[0]) !== 1) {
        const current = await env.DB.prepare("SELECT version FROM events WHERE id=?").bind(eventId).first();
        throw versionConflict(current?.version);
    }
    await audit(env, principal.id, eventId, null, `EVENT_${action.toUpperCase()}`, { from: event.lifecycle, to: nextLifecycle, policyRevisionId: policyId });
    return json({ id: eventId, lifecycle: nextLifecycle, activePolicyRevisionId: policyId, version: expectedVersion + 1 });
}

// MARK: - Booth: active policy and offline grant

async function getActiveEvent(env, principal) {
    const rows = await env.DB.prepare(`SELECT e.id event_id, e.name, e.venue, e.lifecycle, e.ends_at, e.version event_version, p.*
        FROM events e JOIN event_policy_revisions p ON p.id = e.active_policy_revision_id
        WHERE e.lifecycle = 'ACTIVE' AND e.account_id=? ORDER BY e.updated_at DESC LIMIT 2`).bind(principal.accountId).all();
    const active = rows.results || [];
    const device = { id: principal.id, accountId: principal.accountId };
    if (active.length > 1) throw http(409, "More than one event is active for this account. Operator action is required.", "ambiguous_active_event");
    if (active.length === 0) {
        const inactive = await env.DB.prepare("SELECT id,name,lifecycle FROM events WHERE account_id=? AND lifecycle IN ('PAUSED','ENDED') ORDER BY updated_at DESC LIMIT 1").bind(principal.accountId).first();
        return json({ event: null, inactiveEvent: inactive || null, offlinePolicy: null, offlinePolicyStatus: "no_active_event", device, serverTime: now() });
    }
    const row = active[0];
    const { grant, status } = await offlineGrantFor(env, principal, row);
    return json({ event: publicPolicy(row), offlinePolicy: grant, offlinePolicyStatus: status, device, serverTime: now() });
}

async function offlineGrantFor(env, principal, row) {
    if (row.commercial_mode !== "PAY_PER_PRINT" || !row.cash_enabled || !row.offline_valid_until) return { grant: null, status: "offline_cash_not_enabled" };
    const signer = await offlineSigner(env);
    if (!signer) return { grant: null, status: "offline_signing_not_configured" };
    const nowMs = Date.now(), operatorLimit = Date.parse(row.offline_valid_until);
    if (!(operatorLimit > nowMs)) return { grant: null, status: "offline_window_elapsed" };
    const window = Math.min(43_200, Math.max(300, integer(env.OFFLINE_MAX_WINDOW_SECONDS || 14_400))) * 1000;
    const existing = await env.DB.prepare(`SELECT * FROM offline_policy_snapshots WHERE device_id=? AND policy_revision_id=? AND key_id=? AND revoked_at IS NULL AND expires_at>?
        ORDER BY issued_at DESC LIMIT 1`).bind(principal.id, row.id, signer.keyId, new Date(nowMs + window / 2).toISOString()).first();
    if (existing) return { grant: { snapshotId: existing.id, keyId: existing.key_id, payload: existing.payload_b64, signature: existing.signature_b64 }, status: "issued" };

    const endsAt = row.ends_at ? Date.parse(row.ends_at) : Infinity;
    const expiresMs = Math.min(nowMs + window, operatorLimit, Number.isFinite(endsAt) ? endsAt : Infinity);
    if (!(expiresMs > nowMs + 60_000)) return { grant: null, status: "offline_window_elapsed" };
    const maxDeclarations = Math.min(500, Math.max(1, integer(env.OFFLINE_MAX_DECLARATIONS || 40)));
    const snapshotId = crypto.randomUUID(), issuedAt = new Date(nowMs).toISOString(), expiresAt = new Date(expiresMs).toISOString();
    const formats = JSON.parse(row.supported_formats_json);
    const payload = {
        v: 1, kid: signer.keyId, env: environment(env), snapshotId, accountId: principal.accountId, deviceId: principal.id,
        eventId: row.event_id, eventName: row.name, eventLifecycle: "ACTIVE", policyRevisionId: row.id, revision: row.revision,
        commercialMode: "PAY_PER_PRINT", currency: "PHP", unitPriceCentavos: row.unit_price_centavos, maxCopies: row.max_copies,
        defaultCopies: row.default_copies, paymentMethods: ["CASH_DECLARED"], supportedFormats: formats,
        maxDeclarations, issuedAt, notBefore: issuedAt, expiresAt
    };
    const payloadBytes = encoder.encode(JSON.stringify(payload));
    const signature = new Uint8Array(await crypto.subtle.sign({ name: "Ed25519" }, signer.key, payloadBytes));
    const payloadB64 = base64(payloadBytes), signatureB64 = base64(signature);
    await env.DB.prepare(`INSERT INTO offline_policy_snapshots(id,account_id,device_id,event_id,policy_revision_id,key_id,environment,unit_price_centavos,max_copies,supported_formats_json,max_declarations,payload_b64,signature_b64,issued_at,expires_at)
        VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)`).bind(snapshotId, principal.accountId, principal.id, row.event_id, row.id, signer.keyId, environment(env), row.unit_price_centavos, row.max_copies,
        JSON.stringify(formats), maxDeclarations, payloadB64, signatureB64, issuedAt, expiresAt).run();
    return { grant: { snapshotId, keyId: signer.keyId, payload: payloadB64, signature: signatureB64 }, status: "issued" };
}

let cachedSigner = null;
async function offlineSigner(env) {
    const raw = env.OFFLINE_POLICY_SIGNING_KEY, keyId = env.OFFLINE_POLICY_KEY_ID;
    if (!raw || !keyId || !ID_PATTERN.test(keyId)) return null;
    if (cachedSigner?.raw === raw && cachedSigner.keyId === keyId) return cachedSigner;
    try {
        const key = await crypto.subtle.importKey("pkcs8", unbase64(raw), { name: "Ed25519" }, false, ["sign"]);
        cachedSigner = { raw, keyId, key };
        return cachedSigner;
    } catch {
        console.error(JSON.stringify({ event: "offline_signing_key_invalid" }));
        return null;
    }
}

// MARK: - Booth: orders and payment method lock

async function createOrder(request, env, principal) {
    const body = await bodyJSON(request);
    if (!ALLOWED_FORMATS.has(body.format)) throw http(422, "Unsupported format.", "invalid_format");
    const copies = integer(body.copies);
    const checkoutSessionId = typeof body.checkoutSessionId === "string" && ID_PATTERN.test(body.checkoutSessionId) ? body.checkoutSessionId : null;
    if (!checkoutSessionId) throw http(422, "A checkout session ID is required.", "checkout_session_required");
    const idempotency = request.headers.get("idempotency-key") || body.idempotencyKey;
    if (!idempotency || !ID_PATTERN.test(idempotency)) throw http(422, "Idempotency-Key is required.", "idempotency_required");
    const supersedesOrderId = body.supersedesOrderId == null ? null : body.supersedesOrderId;
    if (supersedesOrderId !== null && !ID_PATTERN.test(String(supersedesOrderId))) throw http(422, "Invalid superseded order.", "invalid_supersede");

    const existing = await env.DB.prepare("SELECT * FROM orders WHERE device_id=? AND idempotency_key=?").bind(principal.id, idempotency).first();
    if (existing) return idempotentOrderReplay(existing, body, copies, checkoutSessionId);

    const active = await env.DB.prepare(`SELECT e.id event_id,e.lifecycle,p.* FROM events e JOIN event_policy_revisions p ON p.id=e.active_policy_revision_id WHERE e.id=? AND e.account_id=?`).bind(body.eventId, principal.accountId).first();
    if (!active || active.lifecycle !== "ACTIVE" || active.commercial_mode !== "PAY_PER_PRINT") throw http(409, "Paid event is not active.", "event_not_active");
    // The guest must be charged exactly the policy the iPad displayed.
    if (body.expectedPolicyRevisionId !== active.id || integer(body.expectedUnitPriceCentavos) !== active.unit_price_centavos) {
        throw http(409, "The event price changed. Please review the new price.", "policy_changed", { currentPolicy: publicPolicy(active) });
    }
    if (copies < 1 || copies > active.max_copies) throw http(422, "Copy quantity is outside the event limit.", "invalid_copies");
    if (!JSON.parse(active.supported_formats_json).includes(body.format)) throw http(422, "Format is not enabled for this event.", "format_not_enabled");
    const total = checkedMultiply(active.unit_price_centavos, copies);
    const orderId = crypto.randomUUID(), timestamp = now(), nowMs = Date.now();
    const statements = [];
    if (supersedesOrderId) {
        // Replace an older order for the same session only when no payment can still arrive for it.
        statements.push(env.DB.prepare(`UPDATE orders SET superseded_by_order_id=?,state='SUPERSEDED',updated_at=?
            WHERE id=? AND device_id=? AND checkout_session_id=? AND superseded_by_order_id IS NULL AND state IN ('AWAITING_PAYMENT','PAYMENT_PENDING')
              AND NOT EXISTS (SELECT 1 FROM entitlements en WHERE en.order_id=orders.id)
              AND (payment_method IS NULL OR (payment_method='QRPH' AND EXISTS (SELECT 1 FROM payment_attempts a WHERE a.order_id=orders.id AND a.method='QRPH'
                    AND (a.state='CREATE_FAILED_NO_QR' OR (a.state IN ('PAYMENT_FAILED','QR_EXPIRED_CONFIRMED') AND a.expires_at IS NOT NULL AND a.expires_at<?)))))`)
            .bind(orderId, timestamp, supersedesOrderId, principal.id, checkoutSessionId, new Date(nowMs - SUPERSEDE_GRACE_MS).toISOString()));
    }
    statements.push(env.DB.prepare(`INSERT INTO orders(id,event_id,policy_revision_id,device_id,booth_format,copies,unit_price_centavos,total_centavos,currency,state,idempotency_key,checkout_session_id,supersedes_order_id,expires_at,created_at,updated_at)
        SELECT ?,?,?,?,?,?,?,?,'PHP','AWAITING_PAYMENT',?,?,?,?,?,? WHERE ? IS NULL OR EXISTS (SELECT 1 FROM orders WHERE id=? AND superseded_by_order_id=?)`)
        .bind(orderId, active.event_id, active.id, principal.id, body.format, copies, active.unit_price_centavos, total, idempotency, checkoutSessionId, supersedesOrderId,
            new Date(nowMs + ORDER_PAYMENT_WINDOW_MS).toISOString(), timestamp, timestamp, supersedesOrderId, supersedesOrderId, orderId));
    try {
        await env.DB.batch(statements);
    } catch (error) {
        // A concurrent request with the same key may surface as either unique index, so the
        // idempotency key is always re-checked first.
        if (/UNIQUE constraint failed: orders\./.test(error.message)) {
            const replay = await env.DB.prepare("SELECT * FROM orders WHERE device_id=? AND idempotency_key=?").bind(principal.id, idempotency).first();
            if (replay) return idempotentOrderReplay(replay, body, copies, checkoutSessionId);
        }
        if (/orders\.device_id, orders\.checkout_session_id/.test(error.message)) {
            const open = await env.DB.prepare("SELECT o.*, a.state attempt_state, a.expires_at attempt_expires_at FROM orders o LEFT JOIN payment_attempts a ON a.order_id=o.id WHERE o.device_id=? AND o.checkout_session_id=? AND o.superseded_by_order_id IS NULL")
                .bind(principal.id, checkoutSessionId).first();
            throw http(409, supersedesOrderId ? "The previous payment is not conclusively unpaid. A new checkout cannot start yet." : "This session already has an open checkout.",
                supersedesOrderId ? "previous_payment_unresolved" : "checkout_already_open", { openOrder: open ? publicOrder(open) : null });
        }
        throw error;
    }
    const created = await env.DB.prepare("SELECT * FROM orders WHERE id=?").bind(orderId).first();
    if (!created) throw http(409, "The previous order cannot be replaced.", "previous_payment_unresolved");
    return json({ order: publicOrder(created) }, 201);
}

function idempotentOrderReplay(existing, body, copies, checkoutSessionId) {
    if (existing.event_id !== body.eventId || existing.booth_format !== body.format || existing.copies !== copies || existing.checkout_session_id !== checkoutSessionId) {
        throw http(422, "Idempotency key was reused for a different order.", "idempotency_mismatch");
    }
    return json({ order: publicOrder(existing), replay: true });
}

/// Atomically locks the order to QR Ph, then creates the provider QR. The lock and the attempt row
/// are written in one transaction before any provider call, so cash can never authorize this order.
async function createQR(request, env, principal, orderId) {
    const live = environment(env) === "live";
    assertPaymentsEnvironment(env, live);
    const order = await ownedOrder(env, principal.id, orderId);
    const policy = await env.DB.prepare("SELECT qrph_enabled FROM event_policy_revisions WHERE id=?").bind(order.policy_revision_id).first();
    if (!policy?.qrph_enabled) throw http(409, "QR Ph is disabled for this event.", "qrph_disabled");
    const secretKey = live ? env.PAYMONGO_SECRET_KEY_LIVE : env.PAYMONGO_SECRET_KEY_TEST;
    const publicKey = live ? env.PAYMONGO_PUBLIC_KEY_LIVE : env.PAYMONGO_PUBLIC_KEY_TEST;
    if (!secretKey || !publicKey) throw http(503, "QR Ph credentials are not configured.", "qrph_not_configured");

    const lockToken = crypto.randomUUID(), attemptId = crypto.randomUUID(), timestamp = now();
    const results = await env.DB.batch([
        lockStatement(env, "QRPH", "PAYMENT_PENDING", lockToken, timestamp, orderId, principal.id),
        env.DB.prepare(`INSERT INTO payment_attempts(id,order_id,method,livemode,state,created_at,updated_at)
            SELECT ?,id,'QRPH',?,'CREATING',?,? FROM orders WHERE id=? AND method_lock_token=?`).bind(attemptId, +live, timestamp, timestamp, orderId, lockToken)
    ]);
    if (changes(results[0]) !== 1) return existingLockResponse(env, principal.id, orderId, "QRPH");

    let intent;
    try {
        intent = await paymongo(env, secretKey, "/payment_intents", {
            data: { attributes: { amount: order.total_centavos, currency: "PHP", payment_method_allowed: ["qrph"], description: `Made to Keep Studios order ${order.id}` } }
        });
        if (!intent?.data?.id || !intent.data.attributes?.client_key) throw Object.assign(new Error("Provider returned no payment intent."), { definitive: true });
    } catch (error) {
        // No payment method was attached to any intent, so no payable QR exists.
        await setAttemptState(env, attemptId, "CREATE_FAILED_NO_QR", safeError(error));
        throw http(502, "QR Ph could not be created. No payment was taken.", "qr_create_failed", { attemptState: "CREATE_FAILED_NO_QR" });
    }
    // Persist the intent and a worst-case QR expiry before attaching, so an interrupted request
    // still leaves a record that reconciliation can settle.
    const expirySeconds = qrExpiry(env);
    const attachStartedAt = Date.now();
    const recoveryExpiresAt = new Date(attachStartedAt + (expirySeconds + 60) * 1000).toISOString();
    await env.DB.prepare("UPDATE payment_attempts SET provider_payment_intent_id=?,expires_at=?,updated_at=? WHERE id=? AND state='CREATING'").bind(intent.data.id, recoveryExpiresAt, now(), attemptId).run();

    let attributes;
    try {
        const method = await paymongo(env, publicKey, "/payment_methods", { data: { attributes: { type: "qrph", expiry_seconds: expirySeconds } } });
        const attached = await paymongo(env, publicKey, `/payment_intents/${encodeURIComponent(intent.data.id)}/attach`, {
            data: { attributes: { payment_method: method.data.id, client_key: intent.data.attributes.client_key } }
        });
        attributes = attached?.data?.attributes;
        if (attributes?.status !== "awaiting_next_action" || !attributes.next_action?.code?.image_url) throw new Error("Provider did not return a usable QR.");
        const confirmedExpiresAt = new Date(attachStartedAt + expirySeconds * 1000).toISOString();
        await env.DB.prepare(`UPDATE payment_attempts SET provider_payment_method_id=?,qr_image_data_url=?,provider_test_url=?,expires_at=?,state='AWAITING_PAYMENT',updated_at=?
            WHERE id=? AND state='CREATING'`).bind(method.data.id, attributes.next_action.code.image_url, attributes.next_action.code.test_url || attributes.next_action.test_url || null, confirmedExpiresAt, now(), attemptId).run();
    } catch (error) {
        if (error.definitive) {
            await setAttemptState(env, attemptId, "CREATE_FAILED_NO_QR", safeError(error));
            throw http(502, "QR Ph could not be created. No payment was taken.", "qr_create_failed", { attemptState: "CREATE_FAILED_NO_QR" });
        }
        // Attach outcome is ambiguous: keep the order locked to QR and let reconciliation decide.
        await env.DB.prepare(`UPDATE payment_attempts SET state='UNKNOWN_RECONCILIATION',expires_at=?,reconcile_after=?,last_reconcile_error=?,updated_at=? WHERE id=? AND state='CREATING'`)
            .bind(recoveryExpiresAt, now(), safeError(error), now(), attemptId).run();
        throw http(503, "QR Ph status is unknown. Do not pay another way; the booth is checking.", "qr_status_unknown", { attemptState: "UNKNOWN_RECONCILIATION" });
    }
    const attempt = await env.DB.prepare("SELECT * FROM payment_attempts WHERE id=?").bind(attemptId).first();
    return json({ attempt: publicAttempt(attempt) }, 201);
}

/// Guest self-attested cash. Locks the order to cash and creates the unverified entitlement in one
/// transaction; refuses any order that already has a QR attempt or another state.
async function declareCash(request, env, principal, orderId) {
    const order = await ownedOrder(env, principal.id, orderId);
    const policy = await env.DB.prepare("SELECT cash_enabled FROM event_policy_revisions WHERE id=?").bind(order.policy_revision_id).first();
    if (!policy?.cash_enabled) throw http(409, "Cash is disabled for this event.", "cash_disabled");
    const lockToken = crypto.randomUUID(), timestamp = now(), live = environment(env) === "live";
    const results = await env.DB.batch([
        lockStatement(env, "CASH_DECLARED", "AUTHORIZED", lockToken, timestamp, orderId, principal.id),
        env.DB.prepare(`INSERT INTO payment_attempts(id,order_id,method,livemode,state,created_at,updated_at)
            SELECT ?,id,'CASH_DECLARED',?,'SELF_REPORTED',?,? FROM orders WHERE id=? AND method_lock_token=?`).bind(crypto.randomUUID(), +live, timestamp, timestamp, orderId, lockToken),
        env.DB.prepare(`INSERT INTO entitlements(id,order_id,device_id,purchased_copies,authorization_source,state,created_at,updated_at)
            SELECT ?,id,device_id,copies,'UNVERIFIED_CASH_DECLARED','AUTHORIZED',?,? FROM orders WHERE id=? AND method_lock_token=?`).bind(crypto.randomUUID(), timestamp, timestamp, orderId, lockToken)
    ]);
    if (changes(results[0]) !== 1) {
        const current = await ownedOrder(env, principal.id, orderId);
        if (current.payment_method !== "CASH_DECLARED") return existingLockResponse(env, principal.id, orderId, "CASH_DECLARED");
    } else {
        await audit(env, principal.id, order.event_id, orderId, "CASH_SELF_DECLARED", { totalCentavos: order.total_centavos, verification: "UNVERIFIED_SELF_REPORTED" });
    }
    return orderStatus(env, principal, orderId);
}

/// Attendant-confirmed cash. Operator scope only: the iPad releases its operator credential just
/// after local operator authentication, so a guest tap can never reach this route. Locks the
/// booth's order to cash and creates its entitlement in one transaction, exactly like guest cash,
/// but records the attempt as `OPERATOR_CONFIRMED`. Staff-attested, never provider-verified.
/// Replays of a confirmed order return the same entitlement; nothing is created twice.
async function confirmCash(request, env, principal, orderId) {
    const body = await bodyJSON(request, true);
    const order = await env.DB.prepare("SELECT o.* FROM orders o JOIN devices d ON d.id=o.device_id WHERE o.id=? AND d.account_id=?").bind(orderId, principal.accountId).first();
    if (!order) throw http(404, "Order not found.", "order_not_found");
    // The attendant confirms the exact amount the guest was shown; a mismatch is never accepted.
    if (integer(body.expectedTotalCentavos) !== order.total_centavos) {
        throw http(409, "The cash amount does not match this order.", "cash_amount_mismatch", { totalCentavos: order.total_centavos });
    }
    const policy = await env.DB.prepare("SELECT cash_enabled FROM event_policy_revisions WHERE id=?").bind(order.policy_revision_id).first();
    if (!policy?.cash_enabled) throw http(409, "Cash is disabled for this event.", "cash_disabled");
    const lockToken = crypto.randomUUID(), timestamp = now(), live = environment(env) === "live";
    const results = await env.DB.batch([
        lockStatement(env, "CASH_DECLARED", "AUTHORIZED", lockToken, timestamp, orderId, order.device_id),
        env.DB.prepare(`INSERT INTO payment_attempts(id,order_id,method,livemode,state,created_at,updated_at)
            SELECT ?,id,'CASH_DECLARED',?,'OPERATOR_CONFIRMED',?,? FROM orders WHERE id=? AND method_lock_token=?`).bind(crypto.randomUUID(), +live, timestamp, timestamp, orderId, lockToken),
        env.DB.prepare(`INSERT INTO entitlements(id,order_id,device_id,purchased_copies,authorization_source,state,created_at,updated_at)
            SELECT ?,id,device_id,copies,'UNVERIFIED_CASH_DECLARED','AUTHORIZED',?,? FROM orders WHERE id=? AND method_lock_token=?`).bind(crypto.randomUUID(), timestamp, timestamp, orderId, lockToken)
    ]);
    if (changes(results[0]) !== 1) {
        const current = await ownedOrder(env, order.device_id, orderId);
        const attempt = await env.DB.prepare("SELECT state FROM payment_attempts WHERE order_id=?").bind(orderId).first();
        if (current.payment_method === "CASH_DECLARED" && attempt?.state !== "OPERATOR_CONFIRMED") {
            // A guest self-declaration already authorized this order; it stays reported as such.
            throw http(409, "This order was already self-declared as cash.", "payment_method_locked", { lockedMethod: "CASH_DECLARED", attemptState: attempt?.state || null });
        }
        if (current.payment_method !== "CASH_DECLARED") return existingLockResponse(env, order.device_id, orderId, "CASH_DECLARED");
    } else {
        await audit(env, principal.id, order.event_id, orderId, "CASH_OPERATOR_CONFIRMED", { totalCentavos: order.total_centavos, verification: "OPERATOR_CONFIRMED", boothDeviceId: order.device_id });
    }
    return statusResponse(env, await ownedOrder(env, order.device_id, orderId));
}

function lockStatement(env, method, nextState, lockToken, timestamp, orderId, deviceId) {
    return env.DB.prepare(`UPDATE orders SET payment_method=?,method_lock_token=?,state=?,updated_at=?
        WHERE id=? AND device_id=? AND state='AWAITING_PAYMENT' AND payment_method IS NULL AND superseded_by_order_id IS NULL
          AND (expires_at IS NULL OR expires_at>?)
          AND EXISTS (SELECT 1 FROM events e WHERE e.id=orders.event_id AND e.lifecycle='ACTIVE')`)
        .bind(method, lockToken, nextState, timestamp, orderId, deviceId, timestamp);
}

async function existingLockResponse(env, deviceId, orderId, requestedMethod) {
    const order = await ownedOrder(env, deviceId, orderId);
    const attempt = await env.DB.prepare("SELECT * FROM payment_attempts WHERE order_id=?").bind(orderId).first();
    if (requestedMethod === "QRPH" && order.payment_method === "QRPH" && attempt) {
        if (attempt.state === "CREATING") throw http(409, "QR Ph is still being created. Check the order status.", "qr_creation_in_progress", { attemptState: attempt.state });
        return json({ attempt: publicAttempt(attempt), replay: true });
    }
    if (order.payment_method && order.payment_method !== requestedMethod) {
        throw http(409, order.payment_method === "QRPH"
            ? "This order already started QR Ph. Cash cannot be accepted for it; check the QR status."
            : "This order was already paid by cash declaration.", "payment_method_locked", { lockedMethod: order.payment_method, attemptState: attempt?.state || null });
    }
    if (order.superseded_by_order_id) throw http(409, "This order was replaced by a newer checkout.", "order_superseded");
    if (order.expires_at && Date.parse(order.expires_at) <= Date.now()) throw http(409, "This checkout expired. Start a new checkout.", "order_expired");
    throw http(409, "This order cannot accept payment now.", "order_not_payable", { orderState: order.state });
}

async function setAttemptState(env, attemptId, state, error) {
    await env.DB.prepare("UPDATE payment_attempts SET state=?,last_reconcile_error=?,updated_at=? WHERE id=? AND state IN ('CREATING','UNKNOWN_RECONCILIATION')").bind(state, error, now(), attemptId).run();
}

async function orderStatus(env, principal, orderId) {
    return statusResponse(env, await ownedOrder(env, principal.id, orderId));
}

async function statusResponse(env, order) {
    const orderId = order.id;
    const attempt = await env.DB.prepare("SELECT * FROM payment_attempts WHERE order_id=?").bind(orderId).first();
    const entitlement = await entitlementRow(env, "e.order_id=?", orderId);
    return json({
        order: publicOrder(order), attempt: attempt && publicAttempt(attempt), entitlement: entitlement && publicEntitlement(entitlement),
        newCheckout: supersedeDecision(order, attempt), serverTime: now()
    });
}

// MARK: - Booth: entitlements and prints

/// Read-only recovery view of every order this device created for one checkout session, so an
/// iPad that crashed before receiving an order ID can find the original checkout instead of
/// charging again. Device-scoped: another iPad or account sees nothing.
async function checkoutRecovery(env, principal, checkoutSessionId) {
    const orders = (await env.DB.prepare("SELECT * FROM orders WHERE device_id=? AND checkout_session_id=? ORDER BY created_at, id LIMIT 20")
        .bind(principal.id, checkoutSessionId).all()).results || [];
    const views = [];
    for (const order of orders) {
        const attempt = await env.DB.prepare("SELECT * FROM payment_attempts WHERE order_id=?").bind(order.id).first();
        const entitlement = await entitlementRow(env, "e.order_id=?", order.id);
        const prints = entitlement
            ? await env.DB.prepare(`SELECT po.copy_index, po.outcome FROM print_copy_outcomes po JOIN print_batches pb ON pb.id=po.batch_id WHERE pb.entitlement_id=? ORDER BY po.copy_index`).bind(entitlement.id).all()
            : null;
        views.push({
            // Recovery never needs the QR image; omit it so the response carries the minimum data.
            order: publicOrder(order), attempt: attempt && { ...publicAttempt(attempt), qrImageDataURL: null }, entitlement: entitlement && publicEntitlement(entitlement),
            newCheckout: supersedeDecision(order, attempt), printOutcomes: prints?.results || []
        });
    }
    const open = orders.find(order => !order.superseded_by_order_id);
    return json({ checkoutSessionId, orders: views, openOrderId: open?.id || null, serverTime: now() });
}

async function claimEntitlement(request, env, principal, entitlementId) {
    const body = await bodyJSON(request);
    if (!ID_PATTERN.test(body.sessionId || "") || !ID_PATTERN.test(body.idempotencyKey || "")) throw http(422, "Session and idempotency key are required.", "invalid_claim");
    const before = await entitlementRow(env, "e.id=? AND e.device_id=?", entitlementId, principal.id);
    if (!before) throw http(404, "Entitlement not found.", "entitlement_not_found");
    if (before.checkout_session_id && before.checkout_session_id !== body.sessionId) throw http(409, "This entitlement belongs to a different checkout session.", "entitlement_session_mismatch");
    const timestamp = now();
    await env.DB.batch([
        env.DB.prepare("UPDATE entitlements SET session_id=?,claim_idempotency_key=?,state='IN_SESSION',updated_at=? WHERE id=? AND device_id=? AND state='AUTHORIZED' AND session_id IS NULL")
            .bind(body.sessionId, body.idempotencyKey, timestamp, entitlementId, principal.id),
        env.DB.prepare("UPDATE orders SET state='IN_SESSION',updated_at=? WHERE id=? AND state='AUTHORIZED' AND EXISTS (SELECT 1 FROM entitlements WHERE id=? AND session_id=? AND state='IN_SESSION')")
            .bind(timestamp, before.order_id, entitlementId, body.sessionId)
    ]);
    const claimed = await entitlementRow(env, "e.id=?", entitlementId);
    if (claimed.state === "IN_SESSION" && claimed.session_id === body.sessionId) {
        if (body.recovery === true) {
            await audit(env, principal.id, claimed.entitlement_event_id, claimed.order_id, "ENTITLEMENT_RECOVERY_CLAIM", { entitlementId, sessionId: body.sessionId, previousState: before.state });
        }
        return json({ entitlement: publicEntitlement(claimed), replay: before.state === "IN_SESSION" });
    }
    if (claimed.state === "CONSUMED") throw http(409, "This entitlement was already used.", "entitlement_consumed");
    if (claimed.state === "REVIEW_REQUIRED") throw http(409, "This payment needs operator review before it can be used.", "entitlement_under_review");
    if (claimed.session_id && claimed.session_id !== body.sessionId) throw http(409, "Entitlement is already bound to another session.", "entitlement_session_mismatch");
    throw http(409, "This entitlement cannot be claimed.", "entitlement_not_claimable", { entitlementState: claimed.state });
}

async function completeEntitlement(request, env, principal, entitlementId) {
    const body = await bodyJSON(request);
    const timestamp = now();
    await env.DB.batch([
        env.DB.prepare("UPDATE entitlements SET state='CONSUMED',updated_at=? WHERE id=? AND device_id=? AND session_id=? AND state='IN_SESSION'").bind(timestamp, entitlementId, principal.id, body.sessionId || ""),
        env.DB.prepare("UPDATE orders SET state='COMPLETE',updated_at=? WHERE id=(SELECT order_id FROM entitlements WHERE id=? AND state='CONSUMED') AND state='IN_SESSION'").bind(timestamp, entitlementId),
        env.DB.prepare("UPDATE print_batches SET state='COMPLETE' WHERE entitlement_id=? AND session_id=? AND state='PRINTING'").bind(entitlementId, body.sessionId || "")
    ]);
    const row = await entitlementRow(env, "e.id=? AND e.device_id=?", entitlementId, principal.id);
    if (!row || row.session_id !== body.sessionId || row.state !== "CONSUMED") throw http(409, "Entitlement is not in this session.", "entitlement_session_mismatch");
    return json({ entitlement: publicEntitlement(row) });
}

/// Records one physical copy outcome. Never authorizes a reprint: each copy index is recorded once,
/// the batch is bound to one entitlement/session/receipt, and conflicting replays are rejected.
async function recordPrint(request, env, principal, batchId) {
    const body = await bodyJSON(request);
    if (!ID_PATTERN.test(batchId) || !ID_PATTERN.test(body.idempotencyKey || "") || !ID_PATTERN.test(body.sessionId || "")) throw http(422, "Valid batch, session and idempotency key are required.", "invalid_print_record");
    const entitlement = await env.DB.prepare("SELECT * FROM entitlements WHERE id=? AND device_id=?").bind(body.entitlementId, principal.id).first();
    if (!entitlement || entitlement.session_id !== body.sessionId || !["IN_SESSION", "CONSUMED"].includes(entitlement.state)) throw http(403, "Print entitlement does not match this session.", "print_not_authorized");
    const index = integer(body.copyIndex);
    if (index < 1 || index > entitlement.purchased_copies) throw http(422, "Copy is not authorized.", "copy_not_authorized");
    const fingerprint = String(body.receiptFingerprint || "").toLowerCase();
    if (!/^[a-f0-9]{64}$/.test(fingerprint)) throw http(422, "Receipt fingerprint is required.", "invalid_fingerprint");
    // DELIVERED: every byte accepted by the transport and the physical handoff elapsed; paper not verified.
    const outcome = ["CONFIRMED", "DELIVERED", "UNCERTAIN", "FAILED", "NOT_STARTED"].includes(body.outcome) ? body.outcome : null;
    if (!outcome) throw http(422, "Valid print outcome is required.", "invalid_outcome");

    const prior = await env.DB.prepare("SELECT * FROM print_copy_outcomes WHERE idempotency_key=?").bind(body.idempotencyKey).first();
    if (prior) {
        if (prior.batch_id === batchId && prior.copy_index === index && prior.outcome === outcome) return json({ accepted: true, replay: true, batchId, copyIndex: index, outcome, reprintAuthorized: false });
        throw http(409, "Idempotency key was reused for a different print record.", "print_idempotency_conflict");
    }
    let batch = await env.DB.prepare("SELECT * FROM print_batches WHERE id=?").bind(batchId).first();
    if (!batch) {
        if (entitlement.state !== "IN_SESSION") throw http(409, "This entitlement is complete.", "entitlement_consumed");
        const timestamp = now();
        try {
            await env.DB.batch([
                env.DB.prepare("UPDATE entitlements SET receipt_fingerprint=?,updated_at=? WHERE id=? AND receipt_fingerprint IS NULL").bind(fingerprint, timestamp, entitlement.id),
                env.DB.prepare(`INSERT INTO print_batches(id,entitlement_id,session_id,receipt_fingerprint,authorized_copies,state,created_at)
                    SELECT ?,id,session_id,receipt_fingerprint,purchased_copies,'PRINTING',? FROM entitlements WHERE id=? AND session_id=? AND receipt_fingerprint=?`)
                    .bind(batchId, timestamp, entitlement.id, body.sessionId, fingerprint)
            ]);
        } catch (error) {
            if (!/print_batch_exists|UNIQUE constraint failed: print_batches/.test(error.message)) throw error;
        }
        batch = await env.DB.prepare("SELECT * FROM print_batches WHERE id=?").bind(batchId).first();
    }
    if (!batch || batch.entitlement_id !== entitlement.id || batch.session_id !== body.sessionId || batch.receipt_fingerprint !== fingerprint) {
        throw http(409, "This print record conflicts with the receipt already bound to the entitlement.", "print_batch_conflict");
    }
    const inserted = await env.DB.prepare(`INSERT OR IGNORE INTO print_copy_outcomes(id,batch_id,copy_index,outcome,transport,idempotency_key,created_at) VALUES(?,?,?,?,?,?,?)`)
        .bind(crypto.randomUUID(), batchId, index, outcome, cleanOptional(body.transport || "unknown", 24), body.idempotencyKey, now()).run();
    if (changes(inserted) !== 1) {
        const existing = await env.DB.prepare("SELECT outcome FROM print_copy_outcomes WHERE batch_id=? AND copy_index=?").bind(batchId, index).first();
        throw http(409, "This copy already has a recorded outcome.", "copy_outcome_conflict", { recordedOutcome: existing?.outcome || null });
    }
    return json({ accepted: true, replay: false, batchId, copyIndex: index, outcome, reprintAuthorized: false });
}

// MARK: - Booth: offline cash sync

async function syncOfflineCash(request, env, principal) {
    const body = await bodyJSON(request);
    if (!Array.isArray(body.records) || body.records.length > 50) throw http(422, "Expected at most 50 records.", "invalid_sync_batch");
    const results = [];
    for (const record of body.records) {
        const localId = typeof record?.localId === "string" && ID_PATTERN.test(record.localId) ? record.localId : null;
        if (!localId) { results.push({ localId: record?.localId ?? null, result: "conflict", reason: "invalid_local_id" }); continue; }
        try {
            results.push(await syncOfflineRecord(env, principal, record, localId));
        } catch (error) {
            console.error(JSON.stringify({ event: "offline_sync_failed", message: safeError(error) }));
            results.push({ localId, result: "retry", reason: "server_error" });
        }
    }
    return json({ results, serverTime: now() });
}

async function syncOfflineRecord(env, principal, record, localId) {
    const synced = await env.DB.prepare("SELECT order_id, review_flag FROM offline_cash_sync_records WHERE device_id=? AND local_event_id=?").bind(principal.id, localId).first();
    if (synced) return { localId, orderId: synced.order_id, result: "duplicate", reviewFlag: synced.review_flag };
    const priorConflict = await env.DB.prepare("SELECT reason FROM offline_cash_sync_conflicts WHERE device_id=? AND local_event_id=?").bind(principal.id, localId).first();
    if (priorConflict) return { localId, result: "conflict", reason: priorConflict.reason, duplicate: true };

    const snapshot = typeof record.snapshotId === "string" && ID_PATTERN.test(record.snapshotId)
        ? await env.DB.prepare("SELECT * FROM offline_policy_snapshots WHERE id=? AND device_id=? AND account_id=?").bind(record.snapshotId, principal.id, principal.accountId).first()
        : null;
    const declaredAt = isoTimestamp(record.declaredAt), copies = integer(record.copies), sequence = integer(record.localSequence);
    const reason = offlineRecordRejection(record, snapshot, declaredAt, copies, sequence);
    if (reason) return recordOfflineConflict(env, principal, record, localId, snapshot, declaredAt, reason);

    const used = await env.DB.prepare("SELECT COUNT(*) count FROM offline_cash_sync_records WHERE snapshot_id=?").bind(snapshot.id).first();
    if (Number(used?.count || 0) >= snapshot.max_declarations) return recordOfflineConflict(env, principal, record, localId, snapshot, declaredAt, "declaration_limit_exceeded");

    const reviewFlag = snapshot.revoked_at && declaredAt > snapshot.revoked_at ? "DECLARED_AFTER_SERVER_REVOCATION" : null;
    const orderId = crypto.randomUUID(), timestamp = now(), live = environment(env) === "live";
    const total = checkedMultiply(snapshot.unit_price_centavos, copies);
    try {
        await env.DB.batch([
            env.DB.prepare(`INSERT INTO orders(id,event_id,policy_revision_id,device_id,booth_format,copies,unit_price_centavos,total_centavos,currency,state,idempotency_key,checkout_session_id,payment_method,created_at,updated_at)
                VALUES(?,?,?,?,?,?,?,?,'PHP','COMPLETE',?,?,'CASH_DECLARED',?,?)`).bind(orderId, snapshot.event_id, snapshot.policy_revision_id, principal.id, record.format, copies, snapshot.unit_price_centavos, total, `offline:${localId}`, record.sessionId, declaredAt, timestamp),
            env.DB.prepare(`INSERT INTO payment_attempts(id,order_id,method,livemode,state,created_at,updated_at) VALUES(?,?,'CASH_DECLARED',?,'SELF_REPORTED_OFFLINE',?,?)`).bind(crypto.randomUUID(), orderId, +live, declaredAt, timestamp),
            env.DB.prepare(`INSERT INTO entitlements(id,order_id,device_id,session_id,purchased_copies,authorization_source,state,created_at,updated_at) VALUES(?,?,?,?,?,'UNVERIFIED_CASH_DECLARED','CONSUMED',?,?)`).bind(crypto.randomUUID(), orderId, principal.id, record.sessionId, copies, declaredAt, timestamp),
            env.DB.prepare(`INSERT INTO offline_cash_sync_records(id,device_id,local_event_id,local_sequence,event_id,policy_revision_id,order_id,synced_at,snapshot_id,declared_at,review_flag) VALUES(?,?,?,?,?,?,?,?,?,?,?)`)
                .bind(crypto.randomUUID(), principal.id, localId, sequence, snapshot.event_id, snapshot.policy_revision_id, orderId, timestamp, snapshot.id, declaredAt, reviewFlag)
        ]);
    } catch (error) {
        // A concurrent duplicate of this record may surface as any unique index; re-check it first.
        if (/UNIQUE constraint failed/.test(error.message)) {
            const winner = await env.DB.prepare("SELECT order_id, review_flag FROM offline_cash_sync_records WHERE device_id=? AND local_event_id=?").bind(principal.id, localId).first();
            if (winner) return { localId, orderId: winner.order_id, result: "duplicate", reviewFlag: winner.review_flag };
        }
        if (/offline_cash_sync_records\.device_id, offline_cash_sync_records\.local_sequence/.test(error.message)) return recordOfflineConflict(env, principal, record, localId, snapshot, declaredAt, "duplicate_local_sequence");
        if (/orders\.device_id, orders\.checkout_session_id/.test(error.message)) return recordOfflineConflict(env, principal, record, localId, snapshot, declaredAt, "session_has_online_checkout");
        throw error;
    }
    return { localId, orderId, result: "synced", reviewFlag };
}

function offlineRecordRejection(record, snapshot, declaredAt, copies, sequence) {
    if (!snapshot) return "unknown_snapshot";
    if (!declaredAt) return "invalid_declared_at";
    if (sequence < 1) return "invalid_local_sequence";
    if (!ID_PATTERN.test(record.sessionId || "")) return "invalid_session";
    if (Date.parse(declaredAt) > Date.now() + CLOCK_SKEW_MS) return "declared_in_future";
    if (Date.parse(declaredAt) < Date.parse(snapshot.issued_at) - CLOCK_SKEW_MS || Date.parse(declaredAt) > Date.parse(snapshot.expires_at)) return "outside_offline_validity";
    if (record.eventId !== undefined && record.eventId !== snapshot.event_id) return "event_mismatch";
    if (record.policyRevisionId !== undefined && record.policyRevisionId !== snapshot.policy_revision_id) return "policy_mismatch";
    if (integer(record.unitPriceCentavos) !== snapshot.unit_price_centavos) return "price_mismatch";
    if (copies < 1 || copies > snapshot.max_copies) return "copies_out_of_bounds";
    if (!JSON.parse(snapshot.supported_formats_json).includes(record.format)) return "format_not_enabled";
    if (record.totalCentavos !== undefined && integer(record.totalCentavos) !== snapshot.unit_price_centavos * copies) return "total_mismatch";
    return null;
}

async function recordOfflineConflict(env, principal, record, localId, snapshot, declaredAt, reason) {
    await env.DB.prepare(`INSERT OR IGNORE INTO offline_cash_sync_conflicts(id,account_id,device_id,local_event_id,local_sequence,snapshot_id,event_id,session_id,booth_format,copies,unit_price_centavos,declared_at,reason,received_at)
        VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)`).bind(crypto.randomUUID(), principal.accountId, principal.id, localId, integer(record.localSequence) > 0 ? integer(record.localSequence) : null,
        snapshot?.id || null, snapshot?.event_id || (typeof record.eventId === "string" ? record.eventId.slice(0, 100) : null), typeof record.sessionId === "string" ? record.sessionId.slice(0, 100) : null,
        ALLOWED_FORMATS.has(record.format) ? record.format : null, integer(record.copies) > 0 ? integer(record.copies) : null,
        integer(record.unitPriceCentavos) > 0 ? integer(record.unitPriceCentavos) : null, declaredAt, reason, now()).run();
    return { localId, result: "conflict", reason };
}

// MARK: - Provider evidence

async function paymongoWebhook(request, env, liveEndpoint) {
    if (liveEndpoint && !isLiveEnabled(env)) return json({ error: "live_payments_disabled" }, 503);
    if (liveEndpoint !== (environment(env) === "live")) throw http(400, "Webhook environment mismatch.", "environment_mismatch");
    const raw = await request.text();
    if (raw.length > 256 * 1024) throw http(413, "Payload too large.", "payload_too_large");
    const secret = liveEndpoint ? env.PAYMONGO_WEBHOOK_SECRET_LIVE : env.PAYMONGO_WEBHOOK_SECRET_TEST;
    if (!secret || !(await verifyPaymongoSignature(request.headers.get("Paymongo-Signature"), raw, secret, liveEndpoint, Date.now()))) throw http(401, "Invalid webhook signature.", "invalid_signature");
    let event;
    try { event = JSON.parse(raw)?.data; } catch { throw http(400, "Invalid webhook payload.", "invalid_payload"); }
    const attributes = event?.attributes;
    if (typeof event?.id !== "string" || !ID_PATTERN.test(event.id) || typeof attributes?.type !== "string" || attributes.livemode !== liveEndpoint) {
        throw http(400, "Invalid webhook environment or payload.", "invalid_payload");
    }
    // Claim the provider event ID first so concurrent duplicates are not processed twice.
    const claim = await env.DB.prepare("INSERT OR IGNORE INTO payment_webhook_events(provider_event_id,event_type,livemode,provider_created_at,processing_outcome,created_at) VALUES(?,?,?,?,'PROCESSING',?)")
        .bind(event.id, attributes.type.slice(0, 64), +liveEndpoint, integer(attributes.created_at), now()).run();
    if (changes(claim) !== 1) {
        const retry = await env.DB.prepare("UPDATE payment_webhook_events SET processing_outcome='PROCESSING' WHERE provider_event_id=? AND processing_outcome='FAILED'").bind(event.id).run();
        if (changes(retry) !== 1) return json({ received: true, duplicate: true });
    }
    try {
        let outcome = "IGNORED";
        if (attributes.type === "payment.paid") outcome = await applyPaidWebhook(env, attributes.data, liveEndpoint);
        else if (["payment.failed", "qrph.expired"].includes(attributes.type)) outcome = await applyFailureWebhook(env, attributes.type, attributes.data, liveEndpoint);
        await env.DB.prepare("UPDATE payment_webhook_events SET processing_outcome=? WHERE provider_event_id=?").bind(outcome, event.id).run();
        return json({ received: true, outcome });
    } catch (error) {
        await env.DB.prepare("UPDATE payment_webhook_events SET processing_outcome='FAILED' WHERE provider_event_id=?").bind(event.id).run();
        throw error;
    }
}

/// A signed `payment.paid` webhook is necessary but not sufficient: the attempt must match exactly and
/// the Payment Intent is independently re-read server-to-server before any entitlement is created.
async function applyPaidWebhook(env, resource, livemode) {
    const p = resource?.attributes;
    const intentId = p?.payment_intent_id;
    if (typeof intentId !== "string") return "REJECTED_MISMATCH";
    const attempt = await attemptForReconciliation(env, "a.provider_payment_intent_id=?", intentId);
    if (!attempt || attempt.method !== "QRPH" || resource.type !== "payment" || p.status !== "paid" || p.amount !== attempt.total_centavos
        || p.currency !== attempt.currency || p.livemode !== livemode || attempt.livemode !== +livemode) return "REJECTED_MISMATCH";
    if (attempt.state === "PAID_VERIFIED") return "ALREADY_PAID";
    let payload;
    try {
        payload = await retrievePaymongoIntent(env, intentId, livemode);
    } catch (error) {
        await deferToReconciliation(env, attempt.id, error);
        return "DEFERRED_PROVIDER_UNAVAILABLE";
    }
    const evidence = providerIntentEvidence(payload, { intentId, amount: attempt.total_centavos, livemode });
    if (evidence !== "paid") {
        if (evidence === "conflict") await applyCanonicalProviderEvidence(env, attempt, "conflict", null);
        else await deferToReconciliation(env, attempt.id, new Error(`Provider intent status is ${evidence}.`));
        return evidence === "conflict" ? "MANUAL_REVIEW" : "DEFERRED_PROVIDER_PENDING";
    }
    return applyCanonicalProviderEvidence(env, attempt, "paid", typeof resource.id === "string" ? resource.id : null);
}

async function applyFailureWebhook(env, type, resource, livemode) {
    const intentId = resource?.attributes?.payment_intent_id || (resource?.type === "payment_intent" ? resource.id : null);
    if (typeof intentId !== "string") return "IGNORED_NO_INTENT";
    const attempt = await env.DB.prepare("SELECT * FROM payment_attempts WHERE provider_payment_intent_id=? AND method='QRPH'").bind(intentId).first();
    if (!attempt || attempt.livemode !== +livemode) return "IGNORED_UNKNOWN_INTENT";
    if (attempt.state === "PAID_VERIFIED") return "IGNORED_FINAL";
    const state = type === "qrph.expired" ? "QR_EXPIRED_CONFIRMED" : "PAYMENT_FAILED";
    const result = await env.DB.prepare("UPDATE payment_attempts SET state=?,updated_at=? WHERE id=? AND state NOT IN ('PAID_VERIFIED')").bind(state, now(), attempt.id).run();
    return changes(result) === 1 ? state : "IGNORED_FINAL";
}

async function deferToReconciliation(env, attemptId, error) {
    await env.DB.prepare("UPDATE payment_attempts SET state='UNKNOWN_RECONCILIATION',reconcile_after=?,last_reconcile_error=?,updated_at=? WHERE id=? AND state NOT IN ('PAID_VERIFIED')")
        .bind(now(), safeError(error), now(), attemptId).run();
}

async function attemptForReconciliation(env, where, value) {
    return env.DB.prepare(`SELECT a.*,o.total_centavos,o.currency,o.copies,o.device_id FROM payment_attempts a JOIN orders o ON o.id=a.order_id WHERE ${where}`).bind(value).first();
}

/// The only transition into verified QR payment. Idempotent and monotonic under concurrent
/// webhook and Cron delivery: the paid update is guarded in SQL, the entitlement is unique per
/// order, and a late payment on a superseded order is held for review instead of authorizing.
async function applyCanonicalProviderEvidence(env, attempt, evidence, paymentId) {
    const state = nextProviderState(attempt.state, evidence, { expiresAt: attempt.expires_at }), timestamp = now();
    if (state === "PAID_VERIFIED") {
        await env.DB.batch([
            env.DB.prepare("UPDATE payment_attempts SET provider_payment_id=COALESCE(provider_payment_id,?),state='PAID_VERIFIED',last_reconcile_error=NULL,updated_at=? WHERE id=? AND method='QRPH' AND state<>'PAID_VERIFIED'").bind(paymentId, timestamp, attempt.id),
            env.DB.prepare(`INSERT OR IGNORE INTO entitlements(id,order_id,device_id,purchased_copies,authorization_source,state,created_at,updated_at)
                SELECT ?,o.id,o.device_id,o.copies,'VERIFIED_QRPH',CASE WHEN o.superseded_by_order_id IS NULL THEN 'AUTHORIZED' ELSE 'REVIEW_REQUIRED' END,?,? FROM orders o WHERE o.id=? AND o.payment_method='QRPH'`)
                .bind(crypto.randomUUID(), timestamp, timestamp, attempt.order_id),
            env.DB.prepare("UPDATE orders SET state=CASE WHEN superseded_by_order_id IS NULL THEN 'AUTHORIZED' ELSE 'LATE_PAID_REVIEW' END,updated_at=? WHERE id=? AND state IN ('PAYMENT_PENDING','SUPERSEDED','AWAITING_PAYMENT')").bind(timestamp, attempt.order_id)
        ]);
    } else {
        await env.DB.prepare("UPDATE payment_attempts SET state=?,reconcile_count=reconcile_count+1,reconcile_after=?,updated_at=? WHERE id=? AND state<>'PAID_VERIFIED'")
            .bind(state, new Date(Date.now() + 60_000).toISOString(), timestamp, attempt.id).run();
    }
    return state;
}

export async function runScheduledReconciliation(env, scheduledTime = Date.now()) {
    if (environment(env) === "live" && !isLiveEnabled(env)) return { skipped: "live_disabled" };
    const live = environment(env) === "live";
    const runId = crypto.randomUUID(), started = new Date(scheduledTime).toISOString(), limit = boundedLimit(env.RECONCILIATION_BATCH_SIZE, 25, 100);
    await env.DB.prepare("INSERT INTO reconciliation_runs(id,environment,started_at) VALUES(?,?,?)").bind(runId, environment(env), started).run();
    // A creation that died before any intent existed never produced a payable QR.
    await env.DB.prepare("UPDATE payment_attempts SET state='CREATE_FAILED_NO_QR',last_reconcile_error='creation_interrupted',updated_at=? WHERE method='QRPH' AND state='CREATING' AND provider_payment_intent_id IS NULL AND created_at<?")
        .bind(now(), new Date(scheduledTime - 120_000).toISOString()).run();
    const rows = await env.DB.prepare(`SELECT a.*,o.total_centavos,o.currency,o.copies,o.device_id FROM payment_attempts a JOIN orders o ON o.id=a.order_id
        WHERE a.method='QRPH' AND a.livemode=? AND a.provider_payment_intent_id IS NOT NULL
          AND (a.state IN ('AWAITING_PAYMENT','UNKNOWN_RECONCILIATION','MANUAL_REVIEW') OR (a.state='CREATING' AND a.created_at<?))
          AND (a.reconcile_after IS NULL OR a.reconcile_after<=?) ORDER BY a.updated_at LIMIT ?`).bind(+live, new Date(scheduledTime - 120_000).toISOString(), started, limit).all();
    let resolved = 0, conflicts = 0, failures = 0;
    for (const attempt of rows.results || []) {
        try {
            const payload = await retrievePaymongoIntent(env, attempt.provider_payment_intent_id, !!attempt.livemode);
            const evidence = providerIntentEvidence(payload, { intentId: attempt.provider_payment_intent_id, amount: attempt.total_centavos, livemode: !!attempt.livemode });
            const state = await applyCanonicalProviderEvidence(env, attempt, evidence, payload?.data?.attributes?.payments?.[0]?.id || null);
            if (["PAID_VERIFIED", "PAYMENT_FAILED", "QR_EXPIRED_CONFIRMED"].includes(state)) resolved++; else if (state === "MANUAL_REVIEW") conflicts++;
        } catch (error) {
            failures++;
            const delay = Math.min(3600, 30 * (2 ** Math.min(Number(attempt.reconcile_count || 0), 7)));
            await env.DB.prepare("UPDATE payment_attempts SET state='UNKNOWN_RECONCILIATION',reconcile_count=reconcile_count+1,last_reconcile_error=?,reconcile_after=?,updated_at=? WHERE id=? AND state<>'PAID_VERIFIED'")
                .bind(safeError(error), new Date(Date.now() + delay * 1000).toISOString(), now(), attempt.id).run();
        }
    }
    await env.DB.prepare("DELETE FROM request_rate_limits WHERE minute_window<?").bind(Math.floor(scheduledTime / 60000) - 60).run();
    await env.DB.prepare("UPDATE reconciliation_runs SET finished_at=?,inspected_count=?,resolved_count=?,conflict_count=?,failure_summary=? WHERE id=?")
        .bind(now(), (rows.results || []).length, resolved, conflicts, failures ? `${failures} provider lookups failed` : null, runId).run();
    return { runId, inspected: (rows.results || []).length, resolved, conflicts, failures };
}

async function retrievePaymongoIntent(env, intentId, live) {
    assertPaymentsEnvironment(env, live);
    const key = live ? env.PAYMONGO_SECRET_KEY_LIVE : env.PAYMONGO_SECRET_KEY_TEST;
    if (!key) throw http(503, "Provider credentials are not configured.", "qrph_not_configured");
    let response;
    try {
        response = await fetch(`${apiBase(env)}/payment_intents/${encodeURIComponent(intentId)}`, { headers: { authorization: `Basic ${btoa(`${key}:`)}` }, signal: AbortSignal.timeout(providerTimeout(env)) });
    } catch {
        throw http(503, "Provider lookup timed out.", "provider_unavailable");
    }
    if (response.status === 429 || response.status >= 500) throw http(503, `Provider temporarily unavailable (${response.status}).`, "provider_unavailable");
    if (!response.ok) throw http(502, `Provider lookup failed (${response.status}).`, "provider_rejected");
    return response.json();
}

// MARK: - Reports (operator)

async function eventSummary(request, env, principal, eventId) {
    await scopedEvent(env, principal, eventId);
    const url = new URL(request.url);
    const pendingLocal = Math.max(0, integer(url.searchParams.get("pendingLocalCount") || 0));
    const row = await env.DB.prepare(`SELECT
      COALESCE(SUM(CASE WHEN a.method='QRPH' AND a.state='PAID_VERIFIED' AND a.livemode=1 AND o.superseded_by_order_id IS NULL THEN o.total_centavos ELSE 0 END),0) qr_live_centavos,
      COALESCE(SUM(CASE WHEN a.method='QRPH' AND a.state='PAID_VERIFIED' AND a.livemode=0 AND o.superseded_by_order_id IS NULL THEN o.total_centavos ELSE 0 END),0) qr_test_centavos,
      COALESCE(SUM(CASE WHEN a.method='QRPH' AND a.state='PAID_VERIFIED' AND o.superseded_by_order_id IS NOT NULL THEN o.total_centavos ELSE 0 END),0) qr_late_review_centavos,
      COALESCE(SUM(CASE WHEN a.method='CASH_DECLARED' AND a.state='SELF_REPORTED' THEN o.total_centavos ELSE 0 END),0) cash_online_centavos,
      COALESCE(SUM(CASE WHEN a.method='CASH_DECLARED' AND a.state='SELF_REPORTED_OFFLINE' THEN o.total_centavos ELSE 0 END),0) cash_offline_centavos,
      COALESCE(SUM(CASE WHEN a.method='CASH_DECLARED' AND a.state='OPERATOR_CONFIRMED' THEN o.total_centavos ELSE 0 END),0) cash_operator_confirmed_centavos,
      COUNT(CASE WHEN a.method='QRPH' AND a.state='PAID_VERIFIED' AND o.superseded_by_order_id IS NULL THEN 1 END) qr_sessions,
      COUNT(CASE WHEN a.method='CASH_DECLARED' THEN 1 END) cash_sessions,
      COUNT(CASE WHEN a.method='QRPH' AND a.state IN ('CREATING','AWAITING_PAYMENT','UNKNOWN_RECONCILIATION','MANUAL_REVIEW') THEN 1 END) qr_unresolved,
      COUNT(CASE WHEN o.state IN ('LATE_PAID_REVIEW','MANUAL_REVIEW') THEN 1 END) review_orders
      FROM orders o LEFT JOIN payment_attempts a ON a.order_id=o.id WHERE o.event_id=?`).bind(eventId).first();
    const conflicts = await env.DB.prepare("SELECT COUNT(*) count FROM offline_cash_sync_conflicts WHERE account_id=? AND event_id=?").bind(principal.accountId, eventId).first();
    const count = await env.DB.prepare("SELECT counted_centavos,provisional,created_at FROM cash_reconciliations WHERE account_id=? AND event_id=? ORDER BY created_at DESC, id DESC LIMIT 1").bind(principal.accountId, eventId).first();
    // Separate aggregates avoid join fan-out between batches and copy outcomes.
    const purchased = await env.DB.prepare(`SELECT COALESCE(SUM(en.purchased_copies),0) purchased FROM entitlements en JOIN orders o ON o.id=en.order_id WHERE o.event_id=? AND en.state<>'REVIEW_REQUIRED'`).bind(eventId).first();
    const outcomes = await env.DB.prepare(`SELECT
      COALESCE(SUM(CASE WHEN po.outcome='CONFIRMED' THEN 1 ELSE 0 END),0) confirmed,
      COALESCE(SUM(CASE WHEN po.outcome='DELIVERED' THEN 1 ELSE 0 END),0) delivered,
      COALESCE(SUM(CASE WHEN po.outcome='UNCERTAIN' THEN 1 ELSE 0 END),0) uncertain,
      COALESCE(SUM(CASE WHEN po.outcome='FAILED' THEN 1 ELSE 0 END),0) failed,
      COALESCE(SUM(CASE WHEN po.outcome='NOT_STARTED' THEN 1 ELSE 0 END),0) not_started
      FROM print_copy_outcomes po JOIN print_batches pb ON pb.id=po.batch_id JOIN entitlements en ON en.id=pb.entitlement_id JOIN orders o ON o.id=en.order_id WHERE o.event_id=?`).bind(eventId).first();
    const selfReported = Number(row.cash_online_centavos || 0) + Number(row.cash_offline_centavos || 0);
    // A physical count is compared with every cash order: guest-declared and attendant-confirmed.
    const expectedCash = selfReported + Number(row.cash_operator_confirmed_centavos || 0);
    const offlineConflicts = Number(conflicts?.count || 0);
    return json({
        eventId, currency: "PHP",
        verifiedQRPhLiveCentavos: row.qr_live_centavos, verifiedQRPhTestCentavos: row.qr_test_centavos,
        cashSelfReportedCentavos: selfReported, cashSelfReportedOnlineCentavos: row.cash_online_centavos, cashSelfReportedOfflineSyncedCentavos: row.cash_offline_centavos,
        cashOperatorConfirmedCentavos: row.cash_operator_confirmed_centavos,
        cashLocalUnsyncedCentavos: null,
        qrSessions: row.qr_sessions, cashSessions: row.cash_sessions, unresolvedQRCount: row.qr_unresolved,
        lateQRPaidReviewCentavos: row.qr_late_review_centavos, reviewOrderCount: row.review_orders, offlineConflictCount: offlineConflicts,
        physicalCashCount: count ? { countedCentavos: count.counted_centavos, provisional: !!count.provisional || pendingLocal > 0 || offlineConflicts > 0, createdAt: count.created_at, varianceCentavos: count.counted_centavos - expectedCash } : null,
        printUtilization: { purchased: purchased.purchased, confirmed: outcomes.confirmed, delivered: outcomes.delivered, uncertain: outcomes.uncertain, failed: outcomes.failed, notStarted: outcomes.not_started },
        settlementStatus: "NOT_REPORTED",
        unsupported: { refunds: "UNSUPPORTED", complimentaryPrints: "UNSUPPORTED", processorFees: "UNSUPPORTED", payouts: "UNSUPPORTED" },
        categories: ["QRPH_VERIFIED_TEST", "QRPH_VERIFIED_LIVE", "CASH_OPERATOR_CONFIRMED", "CASH_SELF_REPORTED", "CASH_LOCAL_UNSYNCED", "CASH_PHYSICALLY_COUNTED", "VARIANCE"]
    });
}

const ORDER_FILTERS = {
    all: "1=1",
    unresolved: "a.method='QRPH' AND a.state IN ('CREATING','AWAITING_PAYMENT','UNKNOWN_RECONCILIATION','MANUAL_REVIEW')",
    review: "o.state IN ('LATE_PAID_REVIEW','MANUAL_REVIEW')",
    cash: "a.method='CASH_DECLARED'",
    outstanding: "en.state IN ('AUTHORIZED','IN_SESSION')",
    qr: "a.method='QRPH'"
};

async function eventOrders(request, env, principal, eventId) {
    await scopedEvent(env, principal, eventId);
    const url = new URL(request.url), limit = boundedLimit(url.searchParams.get("limit"), 50, 100);
    const filter = ORDER_FILTERS[url.searchParams.get("filter") || "all"];
    if (!filter) throw http(422, "Unknown filter.", "invalid_filter");
    const cursor = decodeCursor(url.searchParams.get("cursor")) || { timestamp: "9999-12-31T23:59:59.999Z", id: "￿" };
    const rows = await env.DB.prepare(`SELECT o.id,o.created_at,o.booth_format,o.copies,o.unit_price_centavos,o.total_centavos,o.currency,o.state,o.superseded_by_order_id,o.supersedes_order_id,
      a.method,a.state payment_state,a.livemode,a.last_reconcile_error,a.reconcile_count,en.session_id,en.authorization_source,en.state entitlement_state,
      (SELECT COUNT(*) FROM print_copy_outcomes po JOIN print_batches pb ON pb.id=po.batch_id WHERE pb.entitlement_id=en.id AND po.outcome='CONFIRMED') confirmed_prints,
      (SELECT COUNT(*) FROM print_copy_outcomes po JOIN print_batches pb ON pb.id=po.batch_id WHERE pb.entitlement_id=en.id AND po.outcome='UNCERTAIN') uncertain_prints
      FROM orders o LEFT JOIN payment_attempts a ON a.order_id=o.id LEFT JOIN entitlements en ON en.order_id=o.id
      WHERE o.event_id=? AND (o.created_at<? OR (o.created_at=? AND o.id<?)) AND ${filter} ORDER BY o.created_at DESC, o.id DESC LIMIT ?`)
        .bind(eventId, cursor.timestamp, cursor.timestamp, cursor.id, limit + 1).all();
    const values = rows.results || [], page = values.slice(0, limit).map(row => ({ ...row, category: reportCategory(row), last_reconcile_error: row.last_reconcile_error ? "provider_lookup_failed" : null }));
    return json({ orders: page, nextCursor: values.length > limit ? encodeCursor(page.at(-1).created_at, page.at(-1).id) : null });
}

async function offlineConflicts(request, env, principal, eventId) {
    await scopedEvent(env, principal, eventId);
    const limit = boundedLimit(new URL(request.url).searchParams.get("limit"), 50, 100);
    const rows = await env.DB.prepare(`SELECT local_event_id,local_sequence,device_id,session_id,booth_format,copies,unit_price_centavos,declared_at,reason,received_at
        FROM offline_cash_sync_conflicts WHERE account_id=? AND event_id=? ORDER BY received_at DESC LIMIT ?`).bind(principal.accountId, eventId, limit).all();
    return json({ conflicts: rows.results || [] });
}

async function eventCSV(request, env, principal, eventId) {
    await scopedEvent(env, principal, eventId);
    const url = new URL(request.url), cursor = decodeCursor(url.searchParams.get("cursor")) || { timestamp: "", id: "" };
    const rows = await env.DB.prepare(`SELECT o.id,o.created_at,o.booth_format,o.copies,o.unit_price_centavos,o.total_centavos,o.currency,o.state,a.method,a.state payment_state,a.livemode,en.authorization_source,en.session_id
        FROM orders o LEFT JOIN payment_attempts a ON a.order_id=o.id LEFT JOIN entitlements en ON en.order_id=o.id
        WHERE o.event_id=? AND (o.created_at>? OR (o.created_at=? AND o.id>?)) ORDER BY o.created_at,o.id LIMIT ?`)
        .bind(eventId, cursor.timestamp, cursor.timestamp, cursor.id, CSV_PAGE_SIZE + 1).all();
    const values = rows.results || [], page = values.slice(0, CSV_PAGE_SIZE), complete = values.length <= CSV_PAGE_SIZE;
    let csv = csvRow(["order_id", "server_timestamp_utc", "manila_date", "format", "copies", "unit_price_centavos", "total_centavos", "currency", "order_state", "method", "payment_state", "environment", "category", "provenance", "session_id"]);
    for (const row of page) csv += csvRow([row.id, row.created_at, manilaDate(row.created_at), row.booth_format, row.copies, row.unit_price_centavos, row.total_centavos, row.currency, row.state, row.method, row.payment_state, row.livemode === 1 ? "live" : "test", reportCategory(row), row.authorization_source, row.session_id]);
    const next = complete || page.length === 0 ? null : encodeCursor(page.at(-1).created_at, page.at(-1).id);
    return new Response(csv, { headers: {
        "content-type": "text/csv; charset=utf-8", "content-disposition": `attachment; filename="event-${eventId}-sales.csv"`, "cache-control": "no-store",
        "x-export-row-count": String(page.length), "x-export-complete": String(complete), ...(next ? { "x-export-next-cursor": next } : {})
    } });
}

async function recordCashCount(request, env, principal, eventId) {
    await scopedEvent(env, principal, eventId);
    const body = await bodyJSON(request), counted = integer(body.countedCentavos);
    if (counted < 0) throw http(422, "Counted cash must be a nonnegative integer number of centavos.", "invalid_count");
    const reason = clean(body.reason, 200);
    const latest = await env.DB.prepare("SELECT id FROM cash_reconciliations WHERE account_id=? AND event_id=? ORDER BY created_at DESC, id DESC LIMIT 1").bind(principal.accountId, eventId).first();
    const conflicts = await env.DB.prepare("SELECT COUNT(*) count FROM offline_cash_sync_conflicts WHERE account_id=? AND event_id=?").bind(principal.accountId, eventId).first();
    // The server cannot see records still queued on a disconnected iPad; the operator's device reports them.
    const provisional = Math.max(0, integer(body.pendingLocalCount || 0)) > 0 || Number(conflicts?.count || 0) > 0;
    const id = crypto.randomUUID(), timestamp = now();
    await env.DB.batch([
        env.DB.prepare("INSERT INTO cash_reconciliations(id,account_id,event_id,actor_device_id,counted_centavos,reason,supersedes_id,provisional,created_at) VALUES(?,?,?,?,?,?,?,?,?)").bind(id, principal.accountId, eventId, principal.id, counted, reason, latest?.id || null, +provisional, timestamp),
        env.DB.prepare("INSERT INTO operator_audit_log(id,actor_device_id,event_id,action,safe_summary_json,created_at) VALUES(?,?,?,'CASH_COUNT_RECORDED',?,?)").bind(crypto.randomUUID(), principal.id, eventId, JSON.stringify({ countedCentavos: counted, supersedesId: latest?.id || null, reason }), timestamp)
    ]);
    return json({ id, countedCentavos: counted, provisional, createdAt: timestamp }, 201);
}

async function diagnostics(env, principal) {
    const unresolved = await env.DB.prepare(`SELECT COUNT(*) count,MIN(a.updated_at) oldest FROM payment_attempts a JOIN orders o ON o.id=a.order_id JOIN events e ON e.id=o.event_id
        WHERE e.account_id=? AND a.method='QRPH' AND a.state IN ('CREATING','AWAITING_PAYMENT','UNKNOWN_RECONCILIATION','MANUAL_REVIEW')`).bind(principal.accountId).first();
    const review = await env.DB.prepare("SELECT COUNT(*) count FROM orders o JOIN events e ON e.id=o.event_id WHERE e.account_id=? AND o.state IN ('LATE_PAID_REVIEW','MANUAL_REVIEW')").bind(principal.accountId).first();
    const conflicts = await env.DB.prepare("SELECT COUNT(*) count FROM offline_cash_sync_conflicts WHERE account_id=?").bind(principal.accountId).first();
    const run = await env.DB.prepare("SELECT id,environment,started_at,finished_at,inspected_count,resolved_count,conflict_count,failure_summary FROM reconciliation_runs ORDER BY started_at DESC LIMIT 1").first();
    return json({
        environment: environment(env), liveEnabled: isLiveEnabled(env), offlineSigningConfigured: !!(await offlineSigner(env)),
        unresolvedIntentCount: unresolved?.count || 0, oldestUnresolvedAt: unresolved?.oldest || null,
        reviewOrderCount: review?.count || 0, offlineConflictCount: conflicts?.count || 0, lastReconciliation: run || null
    });
}

async function scopedEvent(env, principal, eventId) {
    const event = await env.DB.prepare("SELECT id FROM events WHERE id=? AND account_id=?").bind(eventId, principal.accountId).first();
    if (!event) throw http(404, "Event not found.", "event_not_found");
    return event;
}

function manilaDate(value) { return new Intl.DateTimeFormat("en-CA", { timeZone: "Asia/Manila", year: "numeric", month: "2-digit", day: "2-digit" }).format(new Date(value)); }

export async function verifyPaymongoSignature(header, raw, secret, live, currentTime) {
    if (!header || !secret) return false;
    const fields = Object.fromEntries(header.split(",").map(part => { const index = part.indexOf("="); return index < 0 ? [part.trim(), ""] : [part.slice(0, index).trim(), part.slice(index + 1).trim()]; }));
    const timestamp = Number(fields.t), supplied = live ? fields.li : fields.te;
    if (!/^\d{1,12}$/.test(fields.t || "") || !supplied || !/^[a-f0-9]{64}$/i.test(supplied) || Math.abs(currentTime / 1000 - timestamp) > 300) return false;
    const key = await crypto.subtle.importKey("raw", encoder.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
    const signature = new Uint8Array(await crypto.subtle.sign("HMAC", key, encoder.encode(`${fields.t}.${raw}`)));
    return constantTimeEqual(hex(signature), supplied.toLowerCase());
}

export function validatePolicy(value = {}) {
    const commercialMode = ["PRIVATE_PREPAID", "PAY_PER_PRINT"].includes(value.commercialMode) ? value.commercialMode : null;
    const unitPriceCentavos = integer(value.unitPriceCentavos), maxCopies = integer(value.maxCopies), defaultCopies = integer(value.defaultCopies);
    const supportedFormats = Array.isArray(value.supportedFormats) ? [...new Set(value.supportedFormats)] : [];
    if (!commercialMode || maxCopies < 1 || maxCopies > 10 || defaultCopies < 1 || defaultCopies > maxCopies || supportedFormats.length === 0 || supportedFormats.some(item => !ALLOWED_FORMATS.has(item))) throw http(422, "Invalid event policy.", "invalid_policy");
    if (commercialMode === "PAY_PER_PRINT" && (unitPriceCentavos <= 0 || unitPriceCentavos > MAX_UNIT_PRICE_CENTAVOS || (!value.cashEnabled && !value.qrphEnabled))) throw http(422, "Paid events require a price from ₱0.01 to ₱100,000.00 and a payment method.", "invalid_policy");
    // PayMongo QR Ph minimum is PHP 1.00 (docs.paymongo.com, QR Ph). One copy must meet it.
    if (commercialMode === "PAY_PER_PRINT" && value.qrphEnabled && unitPriceCentavos < 100) throw http(422, "QR Ph requires a price of at least ₱1.00 per copy.", "invalid_policy");
    if (commercialMode === "PRIVATE_PREPAID" && (unitPriceCentavos !== 0 || value.cashEnabled || value.qrphEnabled)) throw http(422, "Prepaid events must not set a guest price or payment method.", "invalid_policy");
    const features = value.features && typeof value.features === "object" && !Array.isArray(value.features) ? value.features : {};
    if (JSON.stringify(features).length > 4096) throw http(422, "Feature settings are too large.", "invalid_policy");
    let offlineValidUntil = null;
    if (value.offlineValidUntil != null) {
        offlineValidUntil = isoTimestamp(value.offlineValidUntil);
        if (!offlineValidUntil) throw http(422, "Offline validity must be an ISO-8601 UTC timestamp.", "invalid_policy");
        if (!value.cashEnabled) throw http(422, "Offline validity only applies to cash.", "invalid_policy");
    }
    return { commercialMode, unitPriceCentavos, maxCopies, defaultCopies, cashEnabled: !!value.cashEnabled, qrphEnabled: !!value.qrphEnabled, prepaidGuestCopyChoice: !!value.prepaidGuestCopyChoice, supportedFormats, features, offlineValidUntil };
}

function validateStoredPolicy(policy) {
    if (!policy) throw http(422, "Policy not found.", "policy_not_found");
    validatePolicy({ commercialMode: policy.commercial_mode, unitPriceCentavos: policy.unit_price_centavos, maxCopies: policy.max_copies, defaultCopies: policy.default_copies, cashEnabled: !!policy.cash_enabled, qrphEnabled: !!policy.qrph_enabled, prepaidGuestCopyChoice: !!policy.prepaid_guest_copy_choice, supportedFormats: JSON.parse(policy.supported_formats_json), features: JSON.parse(policy.features_json), offlineValidUntil: policy.offline_valid_until });
}

function expectedVersionFrom(request, body) {
    const expected = Number(request.headers.get("if-match") ?? body.expectedVersion);
    if (!Number.isSafeInteger(expected) || expected < 1) throw http(428, "If-Match with the event version is required.", "version_required");
    return expected;
}

function versionConflict(currentVersion) {
    return http(409, "Event was changed by another operator. Refresh before saving.", "version_conflict", { currentVersion: currentVersion ?? null });
}

async function entitlementRow(env, where, ...values) {
    return env.DB.prepare(`SELECT e.*,o.event_id entitlement_event_id,o.policy_revision_id entitlement_policy_revision_id,o.booth_format entitlement_format,o.unit_price_centavos entitlement_unit_price,o.total_centavos entitlement_total,o.checkout_session_id
        FROM entitlements e JOIN orders o ON o.id=e.order_id WHERE ${where}`).bind(...values).first();
}

async function ownedOrder(env, deviceId, id) { const row = await env.DB.prepare("SELECT * FROM orders WHERE id=? AND device_id=?").bind(id, deviceId).first(); if (!row) throw http(404, "Order not found.", "order_not_found"); return row; }

/// PayMongo POST with a timeout. `definitive` marks a provider answer that proves the action did
/// not happen (4xx); timeouts, transport errors and 5xx/429 are ambiguous.
async function paymongo(env, key, path, payload) {
    let response;
    try {
        response = await fetch(`${apiBase(env)}${path}`, { method: "POST", headers: { authorization: `Basic ${btoa(`${key}:`)}`, "content-type": "application/json" }, body: JSON.stringify(payload), signal: AbortSignal.timeout(providerTimeout(env)) });
    } catch {
        throw Object.assign(new Error("PayMongo request timed out or failed in transit."), { definitive: false });
    }
    const definitive = response.status >= 400 && response.status < 500 && response.status !== 429;
    let value;
    try { value = await response.json(); } catch { throw Object.assign(new Error(`PayMongo returned an unreadable response (${response.status}).`), { definitive }); }
    if (!response.ok) throw Object.assign(new Error(`PayMongo request failed (${response.status}).`), { definitive });
    return value;
}

async function audit(env, actor, eventId, orderId, action, summary) { await env.DB.prepare("INSERT INTO operator_audit_log(id,actor_device_id,event_id,order_id,action,safe_summary_json,created_at) VALUES(?,?,?,?,?,?,?)").bind(crypto.randomUUID(), actor, eventId, orderId, action, JSON.stringify(summary), now()).run(); }
async function bodyJSON(request, optional = false) {
    const text = await request.text();
    if (text.length > MAX_BODY_BYTES) throw http(413, "Request body is too large.", "payload_too_large");
    if (optional && !text.trim()) return {};
    try { const value = JSON.parse(text); if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error(); return value; } catch { throw http(400, "Invalid JSON body.", "invalid_json"); }
}
function policyRevision(p) { return { id: p.id, revision: p.revision, commercialMode: p.commercial_mode, unitPriceCentavos: p.unit_price_centavos, maxCopies: p.max_copies, defaultCopies: p.default_copies, cashEnabled: !!p.cash_enabled, qrphEnabled: !!p.qrph_enabled, prepaidGuestCopyChoice: !!p.prepaid_guest_copy_choice, supportedFormats: JSON.parse(p.supported_formats_json), features: JSON.parse(p.features_json), offlineValidUntil: p.offline_valid_until, createdAt: p.created_at, activatedAt: p.activated_at }; }
function publicPolicy(r) { return { id: r.event_id || r.id, name: r.name, venue: r.venue, lifecycle: r.lifecycle, policyRevisionId: r.id, revision: r.revision, commercialMode: r.commercial_mode, unitPriceCentavos: r.unit_price_centavos, maxCopies: r.max_copies, defaultCopies: r.default_copies, cashEnabled: !!r.cash_enabled, qrphEnabled: !!r.qrph_enabled, prepaidGuestCopyChoice: !!r.prepaid_guest_copy_choice, supportedFormats: JSON.parse(r.supported_formats_json), features: JSON.parse(r.features_json), offlineValidUntil: r.offline_valid_until }; }
function publicOrder(o) { return { id: o.id, eventId: o.event_id, policyRevisionId: o.policy_revision_id, format: o.booth_format, copies: o.copies, unitPriceCentavos: o.unit_price_centavos, totalCentavos: o.total_centavos, currency: o.currency, state: o.state, paymentMethod: o.payment_method ?? null, checkoutSessionId: o.checkout_session_id ?? null, supersedesOrderId: o.supersedes_order_id ?? null, supersededByOrderId: o.superseded_by_order_id ?? null, expiresAt: o.expires_at }; }
function publicAttempt(a) { return { id: a.id, method: a.method, state: a.state, qrImageDataURL: a.qr_image_data_url, testURL: a.provider_test_url, expiresAt: a.expires_at, verification: a.method === "CASH_DECLARED" ? (a.state === "OPERATOR_CONFIRMED" ? "OPERATOR_CONFIRMED" : "UNVERIFIED_SELF_REPORTED") : a.state === "PAID_VERIFIED" ? "PROVIDER_VERIFIED" : "NOT_VERIFIED" }; }
function publicEntitlement(e) { return { id: e.id, orderId: e.order_id, eventId: e.entitlement_event_id, policyRevisionId: e.entitlement_policy_revision_id, sessionId: e.session_id, selectedFormat: e.entitlement_format, purchasedCopies: e.purchased_copies, unitPriceCentavos: e.entitlement_unit_price, totalCentavos: e.entitlement_total, authorizationSource: e.authorization_source, authorizedAt: e.created_at, state: e.state, receiptFingerprint: e.receipt_fingerprint }; }
function environment(env) { return env.PAYMENTS_ENVIRONMENT === "live" ? "live" : "test"; }
function isLiveEnabled(env) { return environment(env) === "live" && env.LIVE_PAYMENTS_ENABLED === "true" && !!env.PAYMONGO_SECRET_KEY_LIVE && !!env.PAYMONGO_WEBHOOK_SECRET_LIVE; }
function assertPaymentsEnvironment(env, live) { if (live && !isLiveEnabled(env)) throw http(503, "Live payments are disabled.", "live_payments_disabled"); if (!live && environment(env) !== "test") throw http(503, "Test payments are unavailable in this environment.", "test_payments_unavailable"); }
function apiBase(env) { return env.PAYMONGO_API_BASE || "https://api.paymongo.com/v1"; }
function providerTimeout(env) { const n = integer(env.PROVIDER_TIMEOUT_MS || PROVIDER_TIMEOUT_MS); return Math.min(30_000, Math.max(100, n)); }
function qrExpiry(env) { const n = integer(env.QR_EXPIRY_SECONDS || 300); return Math.min(9000, Math.max(60, n)); }
export function checkedMultiply(a, b) { if (!Number.isSafeInteger(a) || !Number.isSafeInteger(b) || a <= 0 || b <= 0 || a > Math.floor(Number.MAX_SAFE_INTEGER / b)) throw http(422, "Invalid or overflowing amount.", "invalid_amount"); return a * b; }
function integer(v) { if (typeof v === "boolean" || v === null || v === "" || (typeof v === "string" && !/^-?\d+$/.test(v.trim()))) return -1; return Number.isSafeInteger(Number(v)) ? Number(v) : -1; }
function clean(v, max) { const s = String(v || "").replace(/[\u0000-\u001f\u007f]/g, " ").replace(/\s+/g, " ").trim().slice(0, max); if (!s) throw http(422, "Required text is missing.", "required_text_missing"); return s; }
function cleanOptional(v, max) { return String(v ?? "").replace(/[\u0000-\u001f\u007f]/g, " ").replace(/\s+/g, " ").trim().slice(0, max); }
function segment(path, index) { let value; try { value = decodeURIComponent(path.split("/")[index] || ""); } catch { throw http(400, "Invalid path.", "invalid_path"); } if (!ID_PATTERN.test(value)) throw http(400, "Invalid identifier.", "invalid_path"); return value; }
function changes(result) { return Number(result?.meta?.changes ?? 0); }
function now() { return new Date().toISOString(); }
function json(value, status = 200) { return new Response(JSON.stringify(value), { status, headers: JSON_HEADERS }); }
function http(status, message, code, details) { const e = new Error(message); e.status = status; e.code = code; e.details = details; return e; }
function safeError(error) { return String(error?.message || "unknown").replace(/(sk|pk)_(test|live)_[A-Za-z0-9]+/g, "[REDACTED]").replace(/whsk_[A-Za-z0-9]+|whsec_[A-Za-z0-9]+/g, "[REDACTED]").replace(/Bearer\s+\S+/gi, "Bearer [REDACTED]").slice(0, 240); }
function safePublicError(error) { return error?.status && error.status < 500 || error?.code === "qr_status_unknown" || error?.code === "qr_create_failed" || error?.code === "qrph_not_configured" || error?.code === "live_payments_disabled" || error?.code === "test_payments_unavailable" ? safeError(error) : "The payments service could not complete the request."; }
async function sha256Hex(value) { return hex(new Uint8Array(await crypto.subtle.digest("SHA-256", encoder.encode(value)))); }
function hex(bytes) { return [...bytes].map(byte => byte.toString(16).padStart(2, "0")).join(""); }
function base64(bytes) { let s = ""; for (const b of bytes) s += String.fromCharCode(b); return btoa(s); }
function unbase64(value) { const s = atob(String(value).trim()); const out = new Uint8Array(s.length); for (let i = 0; i < s.length; i++) out[i] = s.charCodeAt(i); return out; }
function constantTimeEqual(a, b) { if (a.length !== b.length) return false; let diff = 0; for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i); return diff === 0; }
