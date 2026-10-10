import { boundedLimit, csvRow, nextProviderState, providerIntentEvidence } from "./domain.js";

const JSON_HEADERS = { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" };
const ALLOWED_FORMATS = new Set(["solo", "duo", "grid", "strip", "gridSix", "passport", "photoPass"]);
const encoder = new TextEncoder();

export default {
    async fetch(request, env) {
        try {
            return await route(request, env);
        } catch (error) {
            console.error(JSON.stringify({ event: "request_failed", message: safeError(error) }));
            return json({ error: "request_failed", message: safePublicError(error) }, error.status || 500);
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
        return json({ service: "pocket-pixels-payments", version: "1", environment: environment(env), liveEnabled: isLiveEnabled(env) });
    }
    if (request.method === "POST" && path === "/v1/webhooks/paymongo/test") return paymongoWebhook(request, env, false);
    if (request.method === "POST" && path === "/v1/webhooks/paymongo/live") return paymongoWebhook(request, env, true);

    const principal = await authenticate(request, env);
    await enforceRateLimit(env, principal.id, request.method === "GET" ? 240 : 60);
    if (request.method === "GET" && path === "/v1/events/active") return getActiveEvent(env, principal);
    if (request.method === "POST" && path === "/v1/orders") return createOrder(request, env, principal);
    if (request.method === "POST" && /^\/v1\/orders\/[^/]+\/qrph$/.test(path)) return createQR(request, env, principal, segment(path, 3));
    if (request.method === "POST" && /^\/v1\/orders\/[^/]+\/cash-declaration$/.test(path)) return declareCash(request, env, principal, segment(path, 3));
    if (request.method === "GET" && /^\/v1\/orders\/[^/]+\/status$/.test(path)) return orderStatus(env, principal, segment(path, 3));
    if (request.method === "POST" && /^\/v1\/entitlements\/[^/]+\/claim$/.test(path)) return claimEntitlement(request, env, principal, segment(path, 3));
    if (request.method === "POST" && /^\/v1\/prints\/[^/]+\/progress$/.test(path)) return recordPrint(request, env, principal, segment(path, 3));
    if (request.method === "POST" && path === "/v1/sync/offline-cash") return syncOfflineCash(request, env, principal);

    requireScope(principal, "operator");
    if (request.method === "GET" && path === "/v1/admin/events") return listEvents(request, env, principal);
    if (request.method === "POST" && path === "/v1/admin/events") return createEvent(request, env, principal);
    if (request.method === "GET" && /^\/v1\/admin\/events\/[^/]+$/.test(path)) return getEvent(env, principal, segment(path, 4));
    if (request.method === "PATCH" && /^\/v1\/admin\/events\/[^/]+$/.test(path)) return updateEvent(request, env, principal, segment(path, 4));
    if (request.method === "POST" && /^\/v1\/admin\/events\/[^/]+\/(activate|pause|resume|end)$/.test(path)) {
        return transitionEvent(request, env, principal, segment(path, 4), segment(path, 5));
    }
    if (request.method === "GET" && /^\/v1\/admin\/events\/[^/]+\/summary$/.test(path)) return eventSummary(env, principal, segment(path, 4));
    if (request.method === "GET" && /^\/v1\/admin\/events\/[^/]+\/orders$/.test(path)) return eventOrders(request, env, principal, segment(path, 4));
    if (request.method === "GET" && /^\/v1\/admin\/events\/[^/]+\/export.csv$/.test(path)) return eventCSV(request, env, principal, segment(path, 4));
    if (request.method === "POST" && /^\/v1\/admin\/events\/[^/]+\/cash-counts$/.test(path)) return recordCashCount(request, env, principal, segment(path, 4));
    if (request.method === "GET" && path === "/v1/admin/diagnostics") return diagnostics(env, principal);
    return json({ error: "not_found" }, 404);
}

async function authenticate(request, env) {
    const value = request.headers.get("authorization") || "";
    if (!value.startsWith("Bearer ")) throw http(401, "Authentication required.");
    const token = value.slice(7).trim();
    if (token.length < 32) throw http(401, "Invalid credential.");
    const hash = await sha256Hex(token);
    const device = await env.DB.prepare("SELECT id, account_id, scopes, revoked_at FROM devices WHERE credential_hash = ?").bind(hash).first();
    if (!device || device.revoked_at) throw http(401, "Credential is invalid or revoked.");
    return { id: device.id, accountId: device.account_id || "default", scopes: new Set(device.scopes.split(",").map(value => value.trim())) };
}

async function listEvents(request, env, principal) {
    const url = new URL(request.url), limit = boundedLimit(url.searchParams.get("limit"), 25, 100), cursor = url.searchParams.get("cursor") || "9999-12-31T23:59:59.999Z";
    const rows = await env.DB.prepare(`SELECT id,name,venue,lifecycle,active_policy_revision_id,starts_at,ends_at,version,updated_at
        FROM events WHERE account_id=? AND updated_at<? ORDER BY updated_at DESC LIMIT ?`).bind(principal.accountId,cursor,limit+1).all();
    const values = rows.results || [], hasMore = values.length > limit, page = values.slice(0,limit);
    return json({ events: page, nextCursor: hasMore ? page.at(-1).updated_at : null });
}

async function getEvent(env, principal, eventId) {
    const row = await env.DB.prepare(`SELECT e.*,p.revision,p.commercial_mode,p.unit_price_centavos,p.max_copies,p.default_copies,p.cash_enabled,p.qrph_enabled,p.prepaid_guest_copy_choice,p.supported_formats_json,p.features_json,p.offline_valid_until
        FROM events e LEFT JOIN event_policy_revisions p ON p.id=e.active_policy_revision_id WHERE e.id=? AND e.account_id=?`).bind(eventId,principal.accountId).first();
    if (!row) throw http(404,"Event not found.");
    return json({ event: row.active_policy_revision_id ? publicPolicy(row) : { id:row.id,name:row.name,venue:row.venue,lifecycle:row.lifecycle,version:row.version } });
}

function requireScope(principal, scope) {
    if (!principal.scopes.has(scope)) throw http(403, "Operator authorization required.");
}

async function enforceRateLimit(env, key, limit) {
    const window = Math.floor(Date.now() / 60000);
    const result = await env.DB.prepare(`INSERT INTO request_rate_limits(key, minute_window, request_count)
        VALUES (?, ?, 1) ON CONFLICT(key, minute_window) DO UPDATE SET request_count = request_count + 1
        RETURNING request_count`).bind(key, window).first();
    if (result.request_count > limit) throw http(429, "Too many requests. Try again shortly.");
}

async function getActiveEvent(env, principal) {
    const row = await env.DB.prepare(`SELECT e.id, e.name, e.venue, e.lifecycle, p.*
        FROM events e JOIN event_policy_revisions p ON p.id = e.active_policy_revision_id
        WHERE e.lifecycle = 'ACTIVE' AND e.account_id=? ORDER BY e.updated_at DESC LIMIT 1`).bind(principal.accountId).first();
    return row ? json({ event: publicPolicy(row), serverTime: now() }) : json({ event: null, serverTime: now() });
}

async function createEvent(request, env, principal) {
    const body = await bodyJSON(request);
    const id = crypto.randomUUID();
    const timestamp = now();
    await env.DB.prepare("INSERT INTO events(id,name,venue,lifecycle,account_id,created_at,updated_at) VALUES(?,?,?,'DRAFT',?,?,?)")
        .bind(id, clean(body.name, 80), clean(body.venue || "", 120), principal.accountId, timestamp, timestamp).run();
    await audit(env, principal.id, id, null, "EVENT_CREATED", { name: clean(body.name, 80) });
    return json({ id, lifecycle: "DRAFT" }, 201);
}

async function updateEvent(request, env, principal, eventId) {
    const body = await bodyJSON(request);
    const event = await env.DB.prepare("SELECT * FROM events WHERE id = ? AND account_id=?").bind(eventId,principal.accountId).first();
    if (!event || ["ENDED", "ARCHIVED"].includes(event.lifecycle)) throw http(409, "Event cannot be edited.");
    const revision = (await env.DB.prepare("SELECT COALESCE(MAX(revision),0)+1 value FROM event_policy_revisions WHERE event_id=?").bind(eventId).first()).value;
    const policy = validatePolicy(body.policy);
    const policyId = crypto.randomUUID();
    const timestamp = now();
    const expectedVersion = Number(request.headers.get("if-match") || body.expectedVersion);
    if (!Number.isSafeInteger(expectedVersion) || expectedVersion !== event.version) throw http(409,"Event was changed by another operator. Refresh before saving.");
    const changes = await env.DB.batch([
        env.DB.prepare(`INSERT INTO event_policy_revisions(id,event_id,revision,commercial_mode,unit_price_centavos,max_copies,default_copies,cash_enabled,qrph_enabled,prepaid_guest_copy_choice,supported_formats_json,features_json,offline_valid_until,created_at)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)`).bind(policyId,eventId,revision,policy.commercialMode,policy.unitPriceCentavos,policy.maxCopies,policy.defaultCopies,+policy.cashEnabled,+policy.qrphEnabled,+policy.prepaidGuestCopyChoice,JSON.stringify(policy.supportedFormats),JSON.stringify(policy.features),policy.offlineValidUntil,timestamp),
        env.DB.prepare("UPDATE events SET name=?,venue=?,version=version+1,updated_at=? WHERE id=? AND account_id=? AND version=?").bind(clean(body.name || event.name,80),clean(body.venue ?? event.venue,120),timestamp,eventId,principal.accountId,expectedVersion)
    ]);
    if ((changes?.[1]?.meta?.changes ?? 1) !== 1) throw http(409,"Event was changed by another operator.");
    await audit(env, principal.id, eventId, null, "POLICY_DRAFTED", { revision, commercialMode: policy.commercialMode });
    return json({ eventId, policyRevisionId: policyId, revision, version: expectedVersion + 1 });
}

async function transitionEvent(request, env, principal, eventId, action) {
    const event = await env.DB.prepare("SELECT * FROM events WHERE id=? AND account_id=?").bind(eventId,principal.accountId).first();
    if (!event) throw http(404, "Event not found.");
    const transitions = { activate: ["DRAFT", "ACTIVE"], pause: ["ACTIVE", "PAUSED"], resume: ["PAUSED", "ACTIVE"], end: ["ACTIVE", "ENDED"] };
    const [required, target] = transitions[action] || [];
    if (event.lifecycle !== required) throw http(409, `Event must be ${required}.`);
    let policyId = event.active_policy_revision_id;
    if (action === "activate") {
        const body = await bodyJSON(request, true);
        policyId = body.policyRevisionId || (await env.DB.prepare("SELECT id FROM event_policy_revisions WHERE event_id=? ORDER BY revision DESC LIMIT 1").bind(eventId).first())?.id;
        if (!policyId) throw http(422, "A valid policy revision is required.");
        const policy = await env.DB.prepare("SELECT * FROM event_policy_revisions WHERE id=? AND event_id=?").bind(policyId,eventId).first();
        validateStoredPolicy(policy);
        await env.DB.prepare("UPDATE event_policy_revisions SET activated_at=? WHERE id=? AND activated_at IS NULL").bind(now(),policyId).run();
    }
    await env.DB.prepare("UPDATE events SET lifecycle=?,active_policy_revision_id=?,updated_at=? WHERE id=? AND lifecycle=?")
        .bind(target,policyId,now(),eventId,required).run();
    await audit(env, principal.id, eventId, null, `EVENT_${action.toUpperCase()}`, { from: required, to: target });
    return json({ id: eventId, lifecycle: target });
}

async function createOrder(request, env, principal) {
    const body = await bodyJSON(request);
    if (!ALLOWED_FORMATS.has(body.format)) throw http(422, "Unsupported format.");
    const copies = integer(body.copies);
    const active = await env.DB.prepare(`SELECT e.id event_id,e.lifecycle,p.* FROM events e JOIN event_policy_revisions p ON p.id=e.active_policy_revision_id WHERE e.id=? AND e.account_id=?`).bind(body.eventId,principal.accountId).first();
    if (!active || active.lifecycle !== "ACTIVE" || active.commercial_mode !== "PAY_PER_PRINT") throw http(409, "Paid event is not active.");
    if (copies < 1 || copies > active.max_copies) throw http(422, "Copy quantity is outside the event limit.");
    if (!JSON.parse(active.supported_formats_json).includes(body.format)) throw http(422, "Format is not enabled for this event.");
    const total = checkedMultiply(active.unit_price_centavos, copies);
    const idempotency = request.headers.get("idempotency-key") || body.idempotencyKey;
    if (!idempotency || idempotency.length > 100) throw http(422, "Idempotency-Key is required.");
    const existing = await env.DB.prepare("SELECT * FROM orders WHERE device_id=? AND idempotency_key=?").bind(principal.id,idempotency).first();
    if (existing) return json({ order: publicOrder(existing) });
    const order = { id: crypto.randomUUID(), eventId: active.event_id, policyId: active.id, copies, unitPrice: active.unit_price_centavos, total };
    const timestamp = now();
    await env.DB.prepare(`INSERT INTO orders(id,event_id,policy_revision_id,device_id,booth_format,copies,unit_price_centavos,total_centavos,currency,state,idempotency_key,created_at,updated_at)
        VALUES(?,?,?,?,?,?,?,?,?,'AWAITING_PAYMENT',?,?,?)`).bind(order.id,order.eventId,order.policyId,principal.id,body.format,copies,order.unitPrice,total,"PHP",idempotency,timestamp,timestamp).run();
    return json({ order: { ...order, currency: "PHP", state: "AWAITING_PAYMENT" } }, 201);
}

async function createQR(request, env, principal, orderId) {
    const live = environment(env) === "live";
    assertPaymentsEnvironment(env, live);
    const order = await ownedOrder(env, principal.id, orderId);
    const policy = await env.DB.prepare("SELECT qrph_enabled FROM event_policy_revisions WHERE id=?").bind(order.policy_revision_id).first();
    if (!policy.qrph_enabled) throw http(409, "QR Ph is disabled for this event.");
    const existing = await env.DB.prepare("SELECT * FROM payment_attempts WHERE order_id=? AND method='QRPH'").bind(orderId).first();
    if (existing) return json({ attempt: publicAttempt(existing) });
    const secretKey = live ? env.PAYMONGO_SECRET_KEY_LIVE : env.PAYMONGO_SECRET_KEY_TEST;
    const publicKey = live ? env.PAYMONGO_PUBLIC_KEY_LIVE : env.PAYMONGO_PUBLIC_KEY_TEST;
    const intent = await paymongo(env, secretKey, "/payment_intents", {
        data: { attributes: { amount: order.total_centavos, currency: "PHP", payment_method_allowed: ["qrph"], description: `Pocket Pixels order ${order.id}` } }
    });
    const method = await paymongo(env, publicKey, "/payment_methods", {
        data: { attributes: { type: "qrph", expiry_seconds: qrExpiry(env) } }
    });
    const attached = await paymongo(env, publicKey, `/payment_intents/${intent.data.id}/attach`, {
        data: { attributes: { payment_method: method.data.id, client_key: intent.data.attributes.client_key } }
    });
    const attributes = attached.data.attributes;
    if (attributes.status !== "awaiting_next_action" || !attributes.next_action?.code?.image_url) throw http(502, "Provider did not return a usable QR.");
    const attempt = { id: crypto.randomUUID(), intentId: intent.data.id, methodId: method.data.id, image: attributes.next_action.code.image_url, testURL: attributes.next_action.code.test_url || attributes.next_action.test_url || null, expiresAt: new Date(Date.now() + qrExpiry(env) * 1000).toISOString() };
    await env.DB.prepare(`INSERT INTO payment_attempts(id,order_id,method,provider_payment_intent_id,provider_payment_method_id,livemode,state,qr_image_data_url,provider_test_url,expires_at,created_at,updated_at)
        VALUES(?,?,'QRPH',?,?,?,'AWAITING_PAYMENT',?,?,?,?,?)`).bind(attempt.id,orderId,attempt.intentId,attempt.methodId,+live,attempt.image,attempt.testURL,attempt.expiresAt,now(),now()).run();
    return json({ attempt: { id: attempt.id, state: "AWAITING_PAYMENT", qrImageDataURL: attempt.image, testURL: attempt.testURL, expiresAt: attempt.expiresAt } }, 201);
}

async function declareCash(request, env, principal, orderId) {
    const order = await ownedOrder(env, principal.id, orderId);
    const policy = await env.DB.prepare("SELECT cash_enabled FROM event_policy_revisions WHERE id=?").bind(order.policy_revision_id).first();
    if (!policy.cash_enabled) throw http(409, "Cash is disabled for this event.");
    const attemptId = crypto.randomUUID();
    const entitlementId = crypto.randomUUID();
    const timestamp = now();
    await env.DB.batch([
        env.DB.prepare(`INSERT OR IGNORE INTO payment_attempts(id,order_id,method,livemode,state,created_at,updated_at) VALUES(?,?,'CASH_DECLARED',0,'SELF_REPORTED',?,?)`).bind(attemptId,orderId,timestamp,timestamp),
        env.DB.prepare(`INSERT OR IGNORE INTO entitlements(id,order_id,device_id,purchased_copies,authorization_source,state,created_at,updated_at) VALUES(?,?,?,?, 'UNVERIFIED_CASH_DECLARED','AUTHORIZED',?,?)`).bind(entitlementId,orderId,principal.id,order.copies,timestamp,timestamp),
        env.DB.prepare("UPDATE orders SET state='AUTHORIZED',updated_at=? WHERE id=? AND state='AWAITING_PAYMENT'").bind(timestamp,orderId)
    ]);
    return orderStatus(env, principal, orderId);
}

async function orderStatus(env, principal, orderId) {
    const order = await ownedOrder(env, principal.id, orderId);
    const attempt = await env.DB.prepare("SELECT * FROM payment_attempts WHERE order_id=? ORDER BY created_at DESC LIMIT 1").bind(orderId).first();
    const entitlement = await env.DB.prepare(`SELECT e.*,o.event_id entitlement_event_id,o.policy_revision_id entitlement_policy_revision_id,o.booth_format entitlement_format,o.unit_price_centavos entitlement_unit_price,o.total_centavos entitlement_total
        FROM entitlements e JOIN orders o ON o.id=e.order_id WHERE e.order_id=?`).bind(orderId).first();
    return json({ order: publicOrder(order), attempt: attempt && publicAttempt(attempt), entitlement: entitlement && publicEntitlement(entitlement), serverTime: now() });
}

async function claimEntitlement(request, env, principal, entitlementId) {
    const body = await bodyJSON(request);
    if (!body.sessionId || !body.idempotencyKey) throw http(422, "Session and idempotency key are required.");
    const entitlement = await env.DB.prepare("SELECT * FROM entitlements WHERE id=? AND device_id=?").bind(entitlementId,principal.id).first();
    if (!entitlement) throw http(404, "Entitlement not found.");
    if (entitlement.session_id && entitlement.session_id !== body.sessionId) throw http(409, "Entitlement is already bound to another session.");
    await env.DB.batch([
        env.DB.prepare("UPDATE entitlements SET session_id=?,claim_idempotency_key=?,state='IN_SESSION',updated_at=? WHERE id=? AND (session_id IS NULL OR session_id=?)").bind(body.sessionId,body.idempotencyKey,now(),entitlementId,body.sessionId),
        env.DB.prepare("UPDATE orders SET state='IN_SESSION',updated_at=? WHERE id=?").bind(now(),entitlement.order_id)
    ]);
    const claimed = await env.DB.prepare(`SELECT e.*,o.event_id entitlement_event_id,o.policy_revision_id entitlement_policy_revision_id,o.booth_format entitlement_format,o.unit_price_centavos entitlement_unit_price,o.total_centavos entitlement_total
        FROM entitlements e JOIN orders o ON o.id=e.order_id WHERE e.id=?`).bind(entitlementId).first();
    return json({ entitlement: publicEntitlement(claimed) });
}

async function recordPrint(request, env, principal, batchId) {
    const body = await bodyJSON(request);
    const entitlement = await env.DB.prepare("SELECT * FROM entitlements WHERE id=? AND device_id=?").bind(body.entitlementId,principal.id).first();
    if (!entitlement || entitlement.session_id !== body.sessionId) throw http(403, "Print entitlement does not match this session.");
    const index = integer(body.copyIndex);
    if (index < 1 || index > entitlement.purchased_copies) throw http(422, "Copy is not authorized.");
    if (!/^[a-f0-9]{64}$/i.test(body.receiptFingerprint || "")) throw http(422, "Receipt fingerprint is required.");
    const outcome = ["CONFIRMED","UNCERTAIN","FAILED","NOT_STARTED"].includes(body.outcome) ? body.outcome : null;
    if (!outcome || !body.idempotencyKey) throw http(422, "Valid print outcome and idempotency key are required.");
    const timestamp = now();
    await env.DB.batch([
        env.DB.prepare(`INSERT OR IGNORE INTO print_batches(id,entitlement_id,session_id,receipt_fingerprint,authorized_copies,state,created_at) VALUES(?,?,?,?,?,'PRINTING',?)`).bind(batchId,entitlement.id,body.sessionId,body.receiptFingerprint,entitlement.purchased_copies,timestamp),
        env.DB.prepare(`INSERT OR IGNORE INTO print_copy_outcomes(id,batch_id,copy_index,outcome,transport,idempotency_key,created_at) VALUES(?,?,?,?,?,?,?)`).bind(crypto.randomUUID(),batchId,index,outcome,clean(body.transport || "unknown",24),body.idempotencyKey,timestamp)
    ]);
    return json({ accepted: true });
}

async function syncOfflineCash(request, env, principal) {
    const body = await bodyJSON(request);
    if (!Array.isArray(body.records) || body.records.length > 50) throw http(422, "Expected at most 50 records.");
    const results = [];
    for (const record of body.records) {
        try {
            const policy = await env.DB.prepare("SELECT p.*,e.lifecycle FROM event_policy_revisions p JOIN events e ON e.id=p.event_id WHERE p.id=? AND p.event_id=?").bind(record.policyRevisionId,record.eventId).first();
            if (!policy || !policy.cash_enabled || policy.commercial_mode !== "PAY_PER_PRINT") throw http(409, "Cached policy is not accepted.");
            if (!policy.offline_valid_until || Date.parse(policy.offline_valid_until) < Date.parse(record.declaredAt) || Date.parse(record.declaredAt) > Date.now() + 300000) throw http(409,"Offline policy was expired or the device clock is invalid.");
            const copies = integer(record.copies);
            if (copies < 1 || copies > policy.max_copies || policy.unit_price_centavos !== integer(record.unitPriceCentavos)) throw http(409, "Offline policy snapshot conflicts with server policy.");
            const existing = await env.DB.prepare("SELECT order_id FROM offline_cash_sync_records WHERE device_id=? AND local_event_id=?").bind(principal.id,record.localId).first();
            if (existing) { results.push({ localId: record.localId, orderId: existing.order_id, result: "duplicate" }); continue; }
            const orderId = crypto.randomUUID(), entitlementId = crypto.randomUUID(), attemptId = crypto.randomUUID(), timestamp = now();
            const total = checkedMultiply(policy.unit_price_centavos,copies);
            await env.DB.batch([
                env.DB.prepare(`INSERT INTO orders(id,event_id,policy_revision_id,device_id,booth_format,copies,unit_price_centavos,total_centavos,currency,state,idempotency_key,created_at,updated_at) VALUES(?,?,?,?,?,?,?,?, 'PHP','AUTHORIZED',?,?,?)`).bind(orderId,record.eventId,record.policyRevisionId,principal.id,record.format,copies,policy.unit_price_centavos,total,`offline:${record.localId}`,record.declaredAt,timestamp),
                env.DB.prepare(`INSERT INTO payment_attempts(id,order_id,method,livemode,state,created_at,updated_at) VALUES(?,?,'CASH_DECLARED',0,'SELF_REPORTED_OFFLINE',?,?)`).bind(attemptId,orderId,record.declaredAt,timestamp),
                env.DB.prepare(`INSERT INTO entitlements(id,order_id,device_id,session_id,purchased_copies,authorization_source,state,created_at,updated_at) VALUES(?,?,?,?,?,'UNVERIFIED_CASH_DECLARED','IN_SESSION',?,?,?)`).bind(entitlementId,orderId,principal.id,record.sessionId,copies,record.declaredAt,timestamp),
                env.DB.prepare("INSERT INTO offline_cash_sync_records(id,device_id,local_event_id,local_sequence,event_id,policy_revision_id,order_id,synced_at) VALUES(?,?,?,?,?,?,?,?)").bind(crypto.randomUUID(),principal.id,record.localId,integer(record.localSequence),record.eventId,record.policyRevisionId,orderId,timestamp)
            ]);
            results.push({ localId: record.localId, orderId, result: "synced" });
        } catch (error) { results.push({ localId: record.localId, result: "conflict", message: safePublicError(error) }); }
    }
    return json({ results });
}

async function paymongoWebhook(request, env, liveEndpoint) {
    if (liveEndpoint && !isLiveEnabled(env)) return json({ error: "live_payments_disabled" }, 503);
    if (liveEndpoint !== (environment(env) === "live")) throw http(400, "Webhook environment mismatch.");
    const raw = await request.text();
    const secret = liveEndpoint ? env.PAYMONGO_WEBHOOK_SECRET_LIVE : env.PAYMONGO_WEBHOOK_SECRET_TEST;
    if (!secret || !(await verifyPaymongoSignature(request.headers.get("Paymongo-Signature"), raw, secret, liveEndpoint, Date.now()))) throw http(401, "Invalid webhook signature.");
    const event = JSON.parse(raw)?.data;
    const attributes = event?.attributes;
    if (!event?.id || attributes?.livemode !== liveEndpoint) throw http(400, "Invalid webhook environment or payload.");
    const prior = await env.DB.prepare("SELECT provider_event_id FROM payment_webhook_events WHERE provider_event_id=?").bind(event.id).first();
    if (prior) return json({ received: true, duplicate: true });
    let outcome = "IGNORED";
    if (attributes.type === "payment.paid") outcome = await applyPaidWebhook(env, attributes.data, liveEndpoint);
    else if (["payment.failed", "qrph.expired"].includes(attributes.type)) outcome = await applyFailureWebhook(env, attributes.type, attributes.data);
    await env.DB.prepare("INSERT INTO payment_webhook_events(provider_event_id,event_type,livemode,provider_created_at,processing_outcome,created_at) VALUES(?,?,?,?,?,?)")
        .bind(event.id,attributes.type,+liveEndpoint,integer(attributes.created_at),outcome,now()).run();
    return json({ received: true });
}

async function applyPaidWebhook(env, resource, livemode) {
    const p = resource?.attributes;
    const intentId = p?.payment_intent_id;
    const attempt = await env.DB.prepare(`SELECT a.*,o.total_centavos,o.currency,o.copies,o.device_id FROM payment_attempts a JOIN orders o ON o.id=a.order_id WHERE a.provider_payment_intent_id=?`).bind(intentId).first();
    if (!attempt || p.status !== "paid" || p.amount !== attempt.total_centavos || p.currency !== attempt.currency || p.livemode !== livemode || resource.type !== "payment") return "REJECTED_MISMATCH";
    await applyCanonicalProviderEvidence(env,attempt,"paid",resource.id);
    return "AUTHORIZED";
}

async function applyFailureWebhook(env, type, resource) {
    const intentId = resource?.attributes?.payment_intent_id || (resource?.type === "payment_intent" ? resource.id : null);
    if (!intentId) return "IGNORED_NO_INTENT";
    const attempt = await env.DB.prepare("SELECT * FROM payment_attempts WHERE provider_payment_intent_id=?").bind(intentId).first();
    if (!attempt || attempt.state === "PAID_VERIFIED") return "IGNORED_FINAL";
    const state = type === "qrph.expired" ? "QR_EXPIRED_CONFIRMED" : "PAYMENT_FAILED";
    await env.DB.prepare("UPDATE payment_attempts SET state=?,updated_at=? WHERE id=?").bind(state,now(),attempt.id).run();
    return state;
}

async function eventSummary(env, principal, eventId) {
    await scopedEvent(env, principal, eventId);
    const row = await env.DB.prepare(`SELECT
      COALESCE(SUM(CASE WHEN a.method='QRPH' AND a.state='PAID_VERIFIED' AND a.livemode=1 THEN o.total_centavos ELSE 0 END),0) qr_live_centavos,
      COALESCE(SUM(CASE WHEN a.method='QRPH' AND a.state='PAID_VERIFIED' AND a.livemode=0 THEN o.total_centavos ELSE 0 END),0) qr_test_centavos,
      COALESCE(SUM(CASE WHEN a.method='CASH_DECLARED' THEN o.total_centavos ELSE 0 END),0) cash_declared_centavos,
      COUNT(DISTINCT CASE WHEN a.method='QRPH' AND a.state='PAID_VERIFIED' THEN o.id END) qr_sessions,
      COUNT(DISTINCT CASE WHEN a.method='CASH_DECLARED' THEN o.id END) cash_sessions
      FROM orders o LEFT JOIN payment_attempts a ON a.order_id=o.id WHERE o.event_id=?`).bind(eventId).first();
    const count = await env.DB.prepare("SELECT counted_centavos,provisional,created_at FROM cash_reconciliations WHERE account_id=? AND event_id=? ORDER BY created_at DESC LIMIT 1").bind(principal.accountId,eventId).first();
    const prints = await env.DB.prepare(`SELECT
      COALESCE(SUM(pb.authorized_copies),0) purchased,
      COALESCE(SUM(CASE WHEN po.outcome='CONFIRMED' THEN 1 ELSE 0 END),0) confirmed,
      COALESCE(SUM(CASE WHEN po.outcome='UNCERTAIN' THEN 1 ELSE 0 END),0) uncertain,
      COALESCE(SUM(CASE WHEN po.outcome='FAILED' THEN 1 ELSE 0 END),0) failed
      FROM print_batches pb JOIN entitlements en ON en.id=pb.entitlement_id JOIN orders o ON o.id=en.order_id LEFT JOIN print_copy_outcomes po ON po.batch_id=pb.id WHERE o.event_id=?`).bind(eventId).first();
    const expected = Number(row.cash_declared_centavos||0);
    return json({ eventId, currency: "PHP", verifiedQRPhLiveCentavos: row.qr_live_centavos, verifiedQRPhTestCentavos: row.qr_test_centavos, cashSelfReportedCentavos: expected, qrSessions: row.qr_sessions, cashSessions: row.cash_sessions, physicalCashCount: count ? { countedCentavos:count.counted_centavos, provisional:!!count.provisional, createdAt:count.created_at, varianceCentavos:count.counted_centavos-expected } : null, printUtilization: prints, settlementStatus: "NOT_REPORTED" });
}

async function eventOrders(request, env, principal, eventId) {
    await scopedEvent(env, principal, eventId);
    const url=new URL(request.url), limit=boundedLimit(url.searchParams.get("limit"),50,100), before=url.searchParams.get("cursor")||"9999-12-31T23:59:59.999Z";
    const rows=await env.DB.prepare(`SELECT o.id,o.created_at,o.booth_format,o.copies,o.unit_price_centavos,o.total_centavos,o.currency,o.state,
      a.method,a.state payment_state,a.livemode,a.provider_payment_intent_id,en.session_id,en.authorization_source,
      COALESCE(SUM(CASE WHEN po.outcome='CONFIRMED' THEN 1 ELSE 0 END),0) confirmed_prints,
      COALESCE(SUM(CASE WHEN po.outcome='UNCERTAIN' THEN 1 ELSE 0 END),0) uncertain_prints
      FROM orders o LEFT JOIN payment_attempts a ON a.order_id=o.id LEFT JOIN entitlements en ON en.order_id=o.id
      LEFT JOIN print_batches pb ON pb.entitlement_id=en.id LEFT JOIN print_copy_outcomes po ON po.batch_id=pb.id
      WHERE o.event_id=? AND o.created_at<? GROUP BY o.id ORDER BY o.created_at DESC LIMIT ?`).bind(eventId,before,limit+1).all();
    const values=rows.results||[], page=values.slice(0,limit);
    return json({ orders:page, nextCursor:values.length>limit?page.at(-1).created_at:null });
}

async function eventCSV(request, env, principal, eventId) {
    await scopedEvent(env, principal, eventId);
    const rows=await env.DB.prepare(`SELECT o.id,o.created_at,o.booth_format,o.copies,o.unit_price_centavos,o.total_centavos,o.currency,o.state,a.method,a.state payment_state,a.livemode,en.authorization_source,en.session_id FROM orders o LEFT JOIN payment_attempts a ON a.order_id=o.id LEFT JOIN entitlements en ON en.order_id=o.id WHERE o.event_id=? ORDER BY o.created_at,o.id LIMIT 10000`).bind(eventId).all();
    let csv=csvRow(["order_id","server_timestamp_utc","manila_date","format","copies","unit_price_centavos","total_centavos","currency","order_state","method","payment_state","environment","provenance","session_id"]);
    for (const row of rows.results||[]) csv+=csvRow([row.id,row.created_at,manilaDate(row.created_at),row.booth_format,row.copies,row.unit_price_centavos,row.total_centavos,row.currency,row.state,row.method,row.payment_state,row.livemode===1?"live":"test",row.authorization_source,row.session_id]);
    return new Response(csv,{headers:{"content-type":"text/csv; charset=utf-8","content-disposition":`attachment; filename="event-${eventId}-sales.csv"`,"cache-control":"no-store"}});
}

async function recordCashCount(request, env, principal, eventId) {
    await scopedEvent(env, principal, eventId);
    const body=await bodyJSON(request), counted=integer(body.countedCentavos);
    if (counted<0) throw http(422,"Counted cash must be a nonnegative integer number of centavos.");
    const reason=clean(body.reason,200), latest=await env.DB.prepare("SELECT id FROM cash_reconciliations WHERE account_id=? AND event_id=? ORDER BY created_at DESC LIMIT 1").bind(principal.accountId,eventId).first();
    const pending=await env.DB.prepare("SELECT COUNT(*) count FROM offline_cash_sync_records WHERE event_id=? AND synced_at IS NULL").bind(eventId).first();
    const id=crypto.randomUUID(), timestamp=now();
    await env.DB.batch([
      env.DB.prepare("INSERT INTO cash_reconciliations(id,account_id,event_id,actor_device_id,counted_centavos,reason,supersedes_id,provisional,created_at) VALUES(?,?,?,?,?,?,?,?,?)").bind(id,principal.accountId,eventId,principal.id,counted,reason,latest?.id||null,+(Number(pending?.count||0)>0),timestamp),
      env.DB.prepare("INSERT INTO operator_audit_log(id,actor_device_id,event_id,action,safe_summary_json,created_at) VALUES(?,?,?,'CASH_COUNT_RECORDED',?,?)").bind(crypto.randomUUID(),principal.id,eventId,JSON.stringify({countedCentavos:counted,supersedesId:latest?.id||null,reason}),timestamp)
    ]);
    return json({id,countedCentavos:counted,provisional:Number(pending?.count||0)>0,createdAt:timestamp},201);
}

async function diagnostics(env, principal) {
    const unresolved=await env.DB.prepare(`SELECT COUNT(*) count,MIN(updated_at) oldest FROM payment_attempts a JOIN orders o ON o.id=a.order_id JOIN events e ON e.id=o.event_id WHERE e.account_id=? AND a.method='QRPH' AND a.state IN ('AWAITING_PAYMENT','UNKNOWN_RECONCILIATION','MANUAL_REVIEW')`).bind(principal.accountId).first();
    const run=await env.DB.prepare("SELECT * FROM reconciliation_runs ORDER BY started_at DESC LIMIT 1").first();
    return json({environment:environment(env),liveEnabled:isLiveEnabled(env),unresolvedIntentCount:unresolved?.count||0,oldestUnresolvedAt:unresolved?.oldest||null,lastReconciliation:run||null});
}

async function scopedEvent(env, principal, eventId) {
    const event=await env.DB.prepare("SELECT id FROM events WHERE id=? AND account_id=?").bind(eventId,principal.accountId).first();
    if (!event) throw http(404,"Event not found.");
    return event;
}

export async function runScheduledReconciliation(env, scheduledTime=Date.now()) {
    if (environment(env)==="live" && !isLiveEnabled(env)) return {skipped:"live_disabled"};
    const runId=crypto.randomUUID(), started=new Date(scheduledTime).toISOString(), limit=boundedLimit(env.RECONCILIATION_BATCH_SIZE,25,100);
    await env.DB.prepare("INSERT INTO reconciliation_runs(id,environment,started_at) VALUES(?,?,?)").bind(runId,environment(env),started).run();
    const rows=await env.DB.prepare(`SELECT a.*,o.total_centavos,o.currency,o.copies,o.device_id FROM payment_attempts a JOIN orders o ON o.id=a.order_id WHERE a.method='QRPH' AND a.state IN ('AWAITING_PAYMENT','UNKNOWN_RECONCILIATION','MANUAL_REVIEW') AND (a.reconcile_after IS NULL OR a.reconcile_after<=?) ORDER BY a.updated_at LIMIT ?`).bind(started,limit).all();
    let resolved=0, conflicts=0;
    for (const attempt of rows.results||[]) {
      try {
        const payload=await retrievePaymongoIntent(env,attempt.provider_payment_intent_id,!!attempt.livemode);
        const evidence=providerIntentEvidence(payload,{intentId:attempt.provider_payment_intent_id,amount:attempt.total_centavos,livemode:!!attempt.livemode});
        const state=await applyCanonicalProviderEvidence(env,attempt,evidence,payload?.data?.attributes?.payments?.[0]?.id||null);
        if (["PAID_VERIFIED","PAYMENT_FAILED","QR_EXPIRED_CONFIRMED"].includes(state)) resolved++; else if (state==="MANUAL_REVIEW") conflicts++;
      } catch (error) {
        const delay=Math.min(3600,30*(2**Math.min(Number(attempt.reconcile_count||0),7)));
        await env.DB.prepare("UPDATE payment_attempts SET state='UNKNOWN_RECONCILIATION',reconcile_count=reconcile_count+1,last_reconcile_error=?,reconcile_after=?,updated_at=? WHERE id=? AND state!='PAID_VERIFIED'").bind(safeError(error),new Date(Date.now()+delay*1000).toISOString(),now(),attempt.id).run();
      }
    }
    await env.DB.prepare("UPDATE reconciliation_runs SET finished_at=?,inspected_count=?,resolved_count=?,conflict_count=? WHERE id=?").bind(now(),(rows.results||[]).length,resolved,conflicts,runId).run();
    return {runId,inspected:(rows.results||[]).length,resolved,conflicts};
}

async function retrievePaymongoIntent(env,intentId,live) {
    assertPaymentsEnvironment(env,live);
    const key=live?env.PAYMONGO_SECRET_KEY_LIVE:env.PAYMONGO_SECRET_KEY_TEST;
    const response=await fetch(`${env.PAYMONGO_API_BASE||"https://api.paymongo.com/v1"}/payment_intents/${encodeURIComponent(intentId)}`,{headers:{authorization:`Basic ${btoa(`${key}:`)}`}});
    if (response.status===429 || response.status>=500) throw http(503,`Provider temporarily unavailable (${response.status}).`);
    if (!response.ok) throw http(502,`Provider lookup failed (${response.status}).`);
    return response.json();
}

async function applyCanonicalProviderEvidence(env,attempt,evidence,paymentId) {
    const state=nextProviderState(attempt.state,evidence), timestamp=now();
    if (state==="PAID_VERIFIED") {
      await env.DB.batch([
        env.DB.prepare("UPDATE payment_attempts SET provider_payment_id=COALESCE(provider_payment_id,?),state='PAID_VERIFIED',last_reconcile_error=NULL,updated_at=? WHERE id=?").bind(paymentId,timestamp,attempt.id),
        env.DB.prepare(`INSERT OR IGNORE INTO entitlements(id,order_id,device_id,purchased_copies,authorization_source,state,created_at,updated_at) VALUES(?,?,?,?, 'VERIFIED_QRPH','AUTHORIZED',?,?)`).bind(crypto.randomUUID(),attempt.order_id,attempt.device_id,attempt.copies,timestamp,timestamp),
        env.DB.prepare("UPDATE orders SET state='AUTHORIZED',updated_at=? WHERE id=? AND state NOT IN ('AUTHORIZED','IN_SESSION','PRINT_PENDING','COMPLETE')").bind(timestamp,attempt.order_id)
      ]);
    } else await env.DB.prepare("UPDATE payment_attempts SET state=?,reconcile_count=reconcile_count+1,reconcile_after=?,updated_at=? WHERE id=? AND state!='PAID_VERIFIED'").bind(state,new Date(Date.now()+300000).toISOString(),timestamp,attempt.id).run();
    return state;
}

function manilaDate(value) { return new Intl.DateTimeFormat("en-CA",{timeZone:"Asia/Manila",year:"numeric",month:"2-digit",day:"2-digit"}).format(new Date(value)); }

export async function verifyPaymongoSignature(header, raw, secret, live, currentTime) {
    if (!header || !secret) return false;
    const fields = Object.fromEntries(header.split(",").map(part => part.trim().split("=")));
    const timestamp = Number(fields.t), supplied = live ? fields.li : fields.te;
    if (!Number.isFinite(timestamp) || !supplied || Math.abs(currentTime / 1000 - timestamp) > 300) return false;
    const key = await crypto.subtle.importKey("raw", encoder.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
    const signature = new Uint8Array(await crypto.subtle.sign("HMAC", key, encoder.encode(`${fields.t}.${raw}`)));
    return constantTimeEqual(hex(signature), supplied.toLowerCase());
}

export function validatePolicy(value = {}) {
    const commercialMode = ["PRIVATE_PREPAID","PAY_PER_PRINT"].includes(value.commercialMode) ? value.commercialMode : null;
    const unitPriceCentavos = integer(value.unitPriceCentavos), maxCopies = integer(value.maxCopies), defaultCopies = integer(value.defaultCopies);
    const supportedFormats = Array.isArray(value.supportedFormats) ? [...new Set(value.supportedFormats)] : [];
    if (!commercialMode || maxCopies < 1 || maxCopies > 10 || defaultCopies < 1 || defaultCopies > maxCopies || supportedFormats.length === 0 || supportedFormats.some(item => !ALLOWED_FORMATS.has(item))) throw http(422, "Invalid event policy.");
    if (commercialMode === "PAY_PER_PRINT" && (unitPriceCentavos <= 0 || (!value.cashEnabled && !value.qrphEnabled))) throw http(422, "Paid events require a positive price and payment method.");
    if (commercialMode === "PRIVATE_PREPAID" && unitPriceCentavos !== 0) throw http(422, "Prepaid events must not set a guest price.");
    return { commercialMode, unitPriceCentavos, maxCopies, defaultCopies, cashEnabled: !!value.cashEnabled, qrphEnabled: !!value.qrphEnabled, prepaidGuestCopyChoice: !!value.prepaidGuestCopyChoice, supportedFormats, features: value.features || {}, offlineValidUntil: value.offlineValidUntil || null };
}

function validateStoredPolicy(policy) {
    if (!policy) throw http(422, "Policy not found.");
    validatePolicy({ commercialMode: policy.commercial_mode, unitPriceCentavos: policy.unit_price_centavos, maxCopies: policy.max_copies, defaultCopies: policy.default_copies, cashEnabled: !!policy.cash_enabled, qrphEnabled: !!policy.qrph_enabled, prepaidGuestCopyChoice: !!policy.prepaid_guest_copy_choice, supportedFormats: JSON.parse(policy.supported_formats_json), features: JSON.parse(policy.features_json), offlineValidUntil: policy.offline_valid_until });
}

async function ownedOrder(env, deviceId, id) { const row = await env.DB.prepare("SELECT * FROM orders WHERE id=? AND device_id=?").bind(id,deviceId).first(); if (!row) throw http(404,"Order not found."); return row; }
async function paymongo(env, key, path, payload) { if (!key) throw http(503,"QR Ph test credentials are not configured."); const response = await fetch(`${env.PAYMONGO_API_BASE || "https://api.paymongo.com/v1"}${path}`, { method:"POST", headers:{ authorization:`Basic ${btoa(`${key}:`)}`,"content-type":"application/json" }, body:JSON.stringify(payload) }); const value=await response.json(); if (!response.ok) throw http(502,`PayMongo request failed (${response.status}).`); return value; }
async function audit(env, actor, eventId, orderId, action, summary) { await env.DB.prepare("INSERT INTO operator_audit_log(id,actor_device_id,event_id,order_id,action,safe_summary_json,created_at) VALUES(?,?,?,?,?,?,?)").bind(crypto.randomUUID(),actor,eventId,orderId,action,JSON.stringify(summary),now()).run(); }
async function bodyJSON(request, optional=false) { if (optional && !request.headers.get("content-length")) return {}; try { return await request.json(); } catch { throw http(400,"Invalid JSON body."); } }
function publicPolicy(r) { return { id:r.event_id||r.id,name:r.name,venue:r.venue,lifecycle:r.lifecycle,policyRevisionId:r.id,revision:r.revision,commercialMode:r.commercial_mode,unitPriceCentavos:r.unit_price_centavos,maxCopies:r.max_copies,defaultCopies:r.default_copies,cashEnabled:!!r.cash_enabled,qrphEnabled:!!r.qrph_enabled,prepaidGuestCopyChoice:!!r.prepaid_guest_copy_choice,supportedFormats:JSON.parse(r.supported_formats_json),features:JSON.parse(r.features_json),offlineValidUntil:r.offline_valid_until }; }
function publicOrder(o) { return { id:o.id,eventId:o.event_id,policyRevisionId:o.policy_revision_id,format:o.booth_format,copies:o.copies,unitPriceCentavos:o.unit_price_centavos,totalCentavos:o.total_centavos,currency:o.currency,state:o.state,expiresAt:o.expires_at }; }
function publicAttempt(a) { return { id:a.id,method:a.method,state:a.state,qrImageDataURL:a.qr_image_data_url,testURL:a.provider_test_url,expiresAt:a.expires_at }; }
function publicEntitlement(e) { return { id:e.id,orderId:e.order_id,eventId:e.entitlement_event_id,policyRevisionId:e.entitlement_policy_revision_id,sessionId:e.session_id,selectedFormat:e.entitlement_format,purchasedCopies:e.purchased_copies,unitPriceCentavos:e.entitlement_unit_price,totalCentavos:e.entitlement_total,authorizationSource:e.authorization_source,authorizedAt:e.created_at,state:e.state,receiptFingerprint:e.receipt_fingerprint }; }
function environment(env) { return env.PAYMENTS_ENVIRONMENT === "live" ? "live" : "test"; }
function isLiveEnabled(env) { return environment(env)==="live" && env.LIVE_PAYMENTS_ENABLED==="true" && !!env.PAYMONGO_SECRET_KEY_LIVE && !!env.PAYMONGO_WEBHOOK_SECRET_LIVE; }
function assertPaymentsEnvironment(env, live) { if (live && !isLiveEnabled(env)) throw http(503,"Live payments are disabled."); if (!live && environment(env)!=="test") throw http(503,"Test payments are unavailable in this environment."); }
function qrExpiry(env) { const n=integer(env.QR_EXPIRY_SECONDS||300); return Math.min(9000,Math.max(60,n)); }
export function checkedMultiply(a,b) { if (!Number.isSafeInteger(a)||!Number.isSafeInteger(b)||a<=0||b<=0||a>Math.floor(Number.MAX_SAFE_INTEGER/b)) throw http(422,"Invalid or overflowing amount."); return a*b; }
function integer(v) { return Number.isSafeInteger(Number(v)) ? Number(v) : -1; }
function clean(v,max) { const s=String(v||"").replace(/\s+/g," ").trim().slice(0,max); if (!s) throw http(422,"Required text is missing."); return s; }
function segment(path,index) { return decodeURIComponent(path.split("/")[index]||""); }
function now() { return new Date().toISOString(); }
function json(value,status=200) { return new Response(JSON.stringify(value),{status,headers:JSON_HEADERS}); }
function http(status,message) { const e=new Error(message); e.status=status; return e; }
function safeError(error) { return String(error?.message||"unknown").replace(/sk_(test|live)_[A-Za-z0-9]+/g,"[REDACTED]").slice(0,240); }
function safePublicError(error) { return error?.status && error.status<500 ? safeError(error) : "The payments service could not complete the request."; }
async function sha256Hex(value) { return hex(new Uint8Array(await crypto.subtle.digest("SHA-256",encoder.encode(value)))); }
function hex(bytes) { return [...bytes].map(byte=>byte.toString(16).padStart(2,"0")).join(""); }
function constantTimeEqual(a,b) { if (a.length!==b.length) return false; let diff=0; for(let i=0;i<a.length;i++) diff|=a.charCodeAt(i)^b.charCodeAt(i); return diff===0; }
