import test from "node:test";
import assert from "node:assert/strict";
import { checkedMultiply, validatePolicy, verifyPaymongoSignature } from "../src/index.js";

const encoder = new TextEncoder();

async function signature(secret, timestamp, raw) {
    const key = await crypto.subtle.importKey("raw", encoder.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
    const value = new Uint8Array(await crypto.subtle.sign("HMAC", key, encoder.encode(`${timestamp}.${raw}`)));
    return [...value].map(byte => byte.toString(16).padStart(2, "0")).join("");
}

test("integer-centavo totals are exact for 1, 2, 3, and 10 copies", () => {
    assert.deepEqual([1, 2, 3, 10].map(count => checkedMultiply(5_000, count)), [5_000, 10_000, 15_000, 50_000]);
});

test("invalid, negative, zero, and overflowing amounts are rejected", () => {
    for (const pair of [[0, 1], [-1, 1], [5_000.5, 2], [Number.MAX_SAFE_INTEGER, 2]]) {
        assert.throws(() => checkedMultiply(...pair));
    }
});

test("paid policy requires a positive price and at least one method", () => {
    const base = { commercialMode: "PAY_PER_PRINT", unitPriceCentavos: 5_000, maxCopies: 10, defaultCopies: 1, supportedFormats: ["solo"] };
    assert.throws(() => validatePolicy(base));
    assert.equal(validatePolicy({ ...base, cashEnabled: true }).unitPriceCentavos, 5_000);
    assert.equal(validatePolicy({ ...base, qrphEnabled: true }).qrphEnabled, true);
});

test("prepaid policy cannot accidentally retain a guest price", () => {
    assert.throws(() => validatePolicy({ commercialMode: "PRIVATE_PREPAID", unitPriceCentavos: 1, maxCopies: 1, defaultCopies: 1, supportedFormats: ["solo"] }));
});

test("test webhook signature accepts raw payload and rejects alteration", async () => {
    const secret = "whsec_test_example";
    const timestamp = Math.floor(Date.now() / 1000);
    const raw = '{"data":{"id":"evt_1"}}';
    const digest = await signature(secret, timestamp, raw);
    assert.equal(await verifyPaymongoSignature(`t=${timestamp},te=${digest},li=`, raw, secret, false, Date.now()), true);
    assert.equal(await verifyPaymongoSignature(`t=${timestamp},te=${digest},li=`, `${raw} `, secret, false, Date.now()), false);
});

test("signature rejects wrong environment and stale timestamp", async () => {
    const secret = "whsec_example";
    const stale = Math.floor(Date.now() / 1000) - 301;
    const raw = "{}";
    const digest = await signature(secret, stale, raw);
    assert.equal(await verifyPaymongoSignature(`t=${stale},te=${digest},li=`, raw, secret, false, Date.now()), false);
    assert.equal(await verifyPaymongoSignature(`t=${stale},te=${digest},li=`, raw, secret, true, stale * 1000), false);
});
