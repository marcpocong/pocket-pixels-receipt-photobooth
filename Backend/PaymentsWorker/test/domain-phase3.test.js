import test from "node:test";
import assert from "node:assert/strict";
import { decodeCursor, encodeCursor, isoTimestamp, nextProviderState, reportCategory, supersedeDecision } from "../src/domain.js";

const NOW = Date.parse("2026-10-10T10:00:00.000Z");
const iso = offsetMs => new Date(NOW + offsetMs).toISOString();

for (const [name, current, evidence, expiresAt, expected] of [
    ["live QR still pending stays awaiting", "AWAITING_PAYMENT", "pending", iso(60_000), "AWAITING_PAYMENT"],
    ["pending just after expiry is unknown", "AWAITING_PAYMENT", "pending", iso(-60_000), "UNKNOWN_RECONCILIATION"],
    ["pending well after expiry settles as expired", "UNKNOWN_RECONCILIATION", "pending", iso(-11 * 60_000), "QR_EXPIRED_CONFIRMED"],
    ["paid after time-based expiry still wins", "QR_EXPIRED_CONFIRMED", "paid", iso(-11 * 60_000), "PAID_VERIFIED"],
    ["paid is final even against expiry", "PAID_VERIFIED", "pending", iso(-11 * 60_000), "PAID_VERIFIED"]
]) test(`provider state: ${name}`, () => assert.equal(nextProviderState(current, evidence, { expiresAt, nowMs: NOW }), expected));

for (const [name, order, attempt, expected] of [
    ["no method chosen", { state: "AWAITING_PAYMENT", payment_method: null }, null, { allowed: true, reason: "no_payment_method_chosen" }],
    ["cash locked", { state: "AUTHORIZED", payment_method: "CASH_DECLARED" }, { state: "SELF_REPORTED" }, { allowed: false, reason: "order_not_replaceable" }],
    ["QR never issued", { state: "PAYMENT_PENDING", payment_method: "QRPH" }, { state: "CREATE_FAILED_NO_QR" }, { allowed: true, reason: "qr_never_issued" }],
    ["QR unknown", { state: "PAYMENT_PENDING", payment_method: "QRPH" }, { state: "UNKNOWN_RECONCILIATION" }, { allowed: false, reason: "qr_payment_unresolved" }],
    ["QR expired but still within grace", { state: "PAYMENT_PENDING", payment_method: "QRPH" }, { state: "QR_EXPIRED_CONFIRMED", expires_at: iso(-30_000) }, { allowed: false, reason: "qr_still_scannable" }],
    ["QR expired past grace", { state: "PAYMENT_PENDING", payment_method: "QRPH" }, { state: "QR_EXPIRED_CONFIRMED", expires_at: iso(-120_000) }, { allowed: true, reason: "qr_conclusively_unpaid" }],
    ["already superseded", { state: "SUPERSEDED", superseded_by_order_id: "x" }, null, { allowed: false, reason: "already_superseded" }]
]) test(`supersede decision: ${name}`, () => assert.deepEqual(supersedeDecision(order, attempt, NOW), expected));

for (const [row, expected] of [
    [{ method: "QRPH", payment_state: "PAID_VERIFIED", livemode: 1 }, "QRPH_VERIFIED_LIVE"],
    [{ method: "QRPH", payment_state: "PAID_VERIFIED", livemode: 0 }, "QRPH_VERIFIED_TEST"],
    [{ method: "QRPH", payment_state: "UNKNOWN_RECONCILIATION" }, "QRPH_UNRESOLVED"],
    [{ method: "QRPH", payment_state: "QR_EXPIRED_CONFIRMED" }, "QRPH_NOT_PAID"],
    [{ method: "CASH_DECLARED", payment_state: "SELF_REPORTED" }, "CASH_SELF_REPORTED"],
    [{ method: "CASH_DECLARED", payment_state: "SELF_REPORTED_OFFLINE" }, "CASH_SELF_REPORTED_OFFLINE_SYNCED"],
    [{ method: null }, "NO_PAYMENT"]
]) test(`report category ${expected}`, () => assert.equal(reportCategory(row), expected));

test("composite cursor round-trips and rejects garbage", () => {
    assert.deepEqual(decodeCursor(encodeCursor("2026-10-10T00:00:00.000Z", "abc")), { timestamp: "2026-10-10T00:00:00.000Z", id: "abc" });
    for (const value of [null, "", "%%%", btoa("nope"), btoa("not-a-date|id")]) assert.equal(decodeCursor(value), null);
});

test("ISO timestamp normalization", () => {
    assert.equal(isoTimestamp("2026-10-10T18:00:00+08:00"), "2026-10-10T10:00:00.000Z");
    for (const value of ["yesterday", 123, null, "x".repeat(41)]) assert.equal(isoTimestamp(value), null);
});
