const FORMULA_PREFIX = /^[=+\-@\t\r\n]/;

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

export function nextProviderState(current, evidence) {
    if (current === "PAID_VERIFIED") return "PAID_VERIFIED";
    if (evidence === "paid") return "PAID_VERIFIED";
    if (evidence === "failed") return "PAYMENT_FAILED";
    if (evidence === "expired") return "QR_EXPIRED_CONFIRMED";
    if (evidence === "conflict") return "MANUAL_REVIEW";
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

export function boundedLimit(value, fallback = 50, maximum = 100) {
    const parsed = Number(value);
    return Number.isSafeInteger(parsed) && parsed > 0 ? Math.min(parsed, maximum) : fallback;
}
