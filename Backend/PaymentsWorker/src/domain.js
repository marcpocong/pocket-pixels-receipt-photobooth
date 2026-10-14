const FORMULA_PREFIX = /^[=+\-@\t\r\n]/;

/// A QR Ph code cannot be paid after its expiry. Settling a "still pending after expiry" provider
/// answer as expired waits this long past the code's expiry to absorb provider/clock skew.
export const QR_EXPIRY_GRACE_MS = 10 * 60 * 1000;
/// Superseding a failed/expired QR checkout also waits past the code's expiry.
export const SUPERSEDE_GRACE_MS = 60 * 1000;

/// QR attempt states from which no payment can still arrive for the attempt's own QR code.
export const CONCLUSIVE_NONPAID_QR_STATES = ["CREATE_FAILED_NO_QR", "PAYMENT_FAILED", "QR_EXPIRED_CONFIRMED"];
/// QR attempt states that are not final; the order stays locked to QR Ph.
export const UNRESOLVED_QR_STATES = ["CREATING", "AWAITING_PAYMENT", "UNKNOWN_RECONCILIATION", "MANUAL_REVIEW"];

export function parsePositiveInteger(value, name, maximum = Number.MAX_SAFE_INTEGER) {
    const number = Number(value);
    if (!Number.isSafeInteger(number) || number < 1 || number > maximum) {
        throw Object.assign(new Error(`${name} must be an integer from 1 through ${maximum}.`), { status: 422 });
    }
    return number;
}

export function checkedCentavoTotal(unitPriceCentavos, copies) {
    const price = parsePositiveInteger(unitPriceCentavos, "Unit price");
    const quantity = parsePositiveInteger(copies, "Copies", 10);
    if (price > Math.floor(Number.MAX_SAFE_INTEGER / quantity)) {
        throw Object.assign(new Error("Amount exceeds the supported range."), { status: 422 });
    }
    return price * quantity;
}

export function csvCell(value) {
    let text = value == null ? "" : String(value);
    text = text.replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/g, "");
    if (FORMULA_PREFIX.test(text)) text = `'${text}`;
    return `"${text.replaceAll('"', '""')}"`;
}

export function csvRow(values) {
    return `${values.map(csvCell).join(",")}\r\n`;
}

/// Converges a QR attempt state with provider evidence. `PAID_VERIFIED` is final. A plain
/// "pending" answer keeps a live QR awaiting payment, and only becomes a confirmed expiry once
/// the provider still reports nonpayment well after the QR code itself expired.
export function nextProviderState(current, evidence, { expiresAt = null, nowMs = Date.now() } = {}) {
    if (current === "PAID_VERIFIED") return "PAID_VERIFIED";
    if (evidence === "paid") return "PAID_VERIFIED";
    if (evidence === "failed") return "PAYMENT_FAILED";
    if (evidence === "expired") return "QR_EXPIRED_CONFIRMED";
    if (evidence === "conflict") return "MANUAL_REVIEW";
    const expiry = expiresAt ? Date.parse(expiresAt) : NaN;
    if (Number.isFinite(expiry) && nowMs > expiry + QR_EXPIRY_GRACE_MS) return "QR_EXPIRED_CONFIRMED";
    if (current === "AWAITING_PAYMENT" && Number.isFinite(expiry) && nowMs <= expiry) return "AWAITING_PAYMENT";
    return "UNKNOWN_RECONCILIATION";
}

export function providerIntentEvidence(payload, expected) {
    const data = payload?.data;
    const attributes = data?.attributes;
    if (!data?.id || data.id !== expected.intentId || data.type !== "payment_intent") return "conflict";
    if (attributes?.amount !== expected.amount || attributes?.currency !== "PHP" || attributes?.livemode !== expected.livemode) return "conflict";
    if (["succeeded", "paid"].includes(attributes.status)) return "paid";
    if (["failed", "payment_failed"].includes(attributes.status)) return "failed";
    if (["expired"].includes(attributes.status)) return "expired";
    return "pending";
}

/// Mirrors the SQL guard used when a new checkout supersedes an older order for the same session.
/// A new checkout may replace an order only when no payment can still arrive for it.
export function supersedeDecision(order, attempt, nowMs = Date.now()) {
    if (!order) return { allowed: false, reason: "order_not_found" };
    if (order.superseded_by_order_id) return { allowed: false, reason: "already_superseded" };
    if (!["AWAITING_PAYMENT", "PAYMENT_PENDING"].includes(order.state)) return { allowed: false, reason: "order_not_replaceable" };
    if (!order.payment_method) return { allowed: true, reason: "no_payment_method_chosen" };
    if (order.payment_method !== "QRPH" || !attempt) return { allowed: false, reason: "payment_method_locked" };
    if (attempt.state === "CREATE_FAILED_NO_QR") return { allowed: true, reason: "qr_never_issued" };
    if (["PAYMENT_FAILED", "QR_EXPIRED_CONFIRMED"].includes(attempt.state)) {
        const expiry = attempt.expires_at ? Date.parse(attempt.expires_at) : NaN;
        if (Number.isFinite(expiry) && nowMs > expiry + SUPERSEDE_GRACE_MS) return { allowed: true, reason: "qr_conclusively_unpaid" };
        return { allowed: false, reason: "qr_still_scannable" };
    }
    return { allowed: false, reason: "qr_payment_unresolved" };
}

/// Report category for a ledger row. Categories never merge verified, self-reported and counted money.
export function reportCategory(row) {
    if (row.method === "QRPH") {
        if (row.payment_state === "PAID_VERIFIED") return row.livemode === 1 ? "QRPH_VERIFIED_LIVE" : "QRPH_VERIFIED_TEST";
        if (CONCLUSIVE_NONPAID_QR_STATES.includes(row.payment_state)) return "QRPH_NOT_PAID";
        return "QRPH_UNRESOLVED";
    }
    if (row.method === "CASH_DECLARED") {
        if (row.payment_state === "OPERATOR_CONFIRMED") return "CASH_OPERATOR_CONFIRMED";
        return row.payment_state === "SELF_REPORTED_OFFLINE" ? "CASH_SELF_REPORTED_OFFLINE_SYNCED" : "CASH_SELF_REPORTED";
    }
    return "NO_PAYMENT";
}

export function boundedLimit(value, fallback = 50, maximum = 100) {
    const parsed = Number(value);
    return Number.isSafeInteger(parsed) && parsed > 0 ? Math.min(parsed, maximum) : fallback;
}

/// Opaque composite pagination cursor (`timestamp|id`) so equal timestamps never skip rows.
export function encodeCursor(timestamp, id) {
    return btoa(`${timestamp}|${id}`);
}

export function decodeCursor(value) {
    if (!value) return null;
    try {
        const [timestamp, id] = atob(value).split("|");
        if (!timestamp || !id || !Number.isFinite(Date.parse(timestamp))) return null;
        return { timestamp, id };
    } catch {
        return null;
    }
}

export function isoTimestamp(value) {
    if (typeof value !== "string" || value.length > 40) return null;
    const parsed = Date.parse(value);
    return Number.isFinite(parsed) ? new Date(parsed).toISOString() : null;
}
