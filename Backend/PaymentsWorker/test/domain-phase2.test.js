import test from "node:test";
import assert from "node:assert/strict";
import { boundedLimit, checkedCentavoTotal, csvCell, csvRow, nextProviderState, parsePositiveInteger, providerIntentEvidence } from "../src/domain.js";

for (let copies = 1; copies <= 10; copies++) {
    test(`server centavo calculation freezes complete-copy quantity ${copies}`, () => {
        assert.equal(checkedCentavoTotal(5_000, copies), 5_000 * copies);
    });
}

for (const value of [0, -1, 1.5, NaN, Infinity, Number.MAX_SAFE_INTEGER + 1, "2.5", null]) {
    test(`positive integer validation rejects ${String(value)}`, () => {
        assert.throws(() => parsePositiveInteger(value, "Value", 10));
    });
}

for (const [source, expected] of [
    ["hello", '"hello"'], ["a,b", '"a,b"'], ['a"b', '"a""b"'], ["=SUM(A1)", '"\'=SUM(A1)"'],
    ["+cmd", '"\'+cmd"'], ["-1+2", '"\'-1+2"'], ["@evil", '"\'@evil"'], ["\tformula", '"\'\tformula"'],
    ["line\nvalue", '"line\nvalue"'], ["peso ₱ / José", '"peso ₱ / José"'], ["\u0000safe", '"safe"'], [null, '""']
]) {
    test(`CSV safely quotes ${JSON.stringify(source)}`, () => assert.equal(csvCell(source), expected));
}

test("CSV uses deterministic CRLF and fixed ordering", () => assert.equal(csvRow(["a", "b"]), '"a","b"\r\n'));

for (const [current, evidence, expected] of [
    ["AWAITING_PAYMENT","paid","PAID_VERIFIED"], ["UNKNOWN_RECONCILIATION","paid","PAID_VERIFIED"],
    ["QR_EXPIRED_CONFIRMED","paid","PAID_VERIFIED"], ["PAID_VERIFIED","expired","PAID_VERIFIED"],
    ["PAID_VERIFIED","failed","PAID_VERIFIED"], ["AWAITING_PAYMENT","expired","QR_EXPIRED_CONFIRMED"],
    ["AWAITING_PAYMENT","failed","PAYMENT_FAILED"], ["AWAITING_PAYMENT","pending","UNKNOWN_RECONCILIATION"],
    ["UNKNOWN_RECONCILIATION","conflict","MANUAL_REVIEW"], ["MANUAL_REVIEW","pending","UNKNOWN_RECONCILIATION"]
]) {
    test(`${current} plus ${evidence} converges to ${expected}`, () => assert.equal(nextProviderState(current,evidence),expected));
}

const expected={intentId:"pi_1",amount:10_000,livemode:false};
const intent=(overrides={})=>({data:{id:"pi_1",type:"payment_intent",attributes:{amount:10_000,currency:"PHP",livemode:false,status:"awaiting_next_action",...overrides}}});
for (const [name,payload,result] of [
    ["paid",intent({status:"succeeded"}),"paid"], ["pending",intent(),"pending"], ["failed",intent({status:"failed"}),"failed"],
    ["expired",intent({status:"expired"}),"expired"], ["wrong amount",intent({amount:9_999,status:"succeeded"}),"conflict"],
    ["wrong currency",intent({currency:"USD",status:"succeeded"}),"conflict"], ["wrong environment",intent({livemode:true,status:"succeeded"}),"conflict"],
    ["wrong id",{data:{...intent().data,id:"pi_other"}},"conflict"], ["wrong type",{data:{...intent().data,type:"payment"}},"conflict"],
    ["malformed",{},"conflict"]
]) test(`provider evidence: ${name}`,()=>assert.equal(providerIntentEvidence(payload,expected),result));

for (const [value,expectedLimit] of [[null,50],[0,50],[-1,50],[1,1],[25,25],[100,100],[101,100],["20",20],["x",50]]) {
    test(`bounded pagination ${String(value)} -> ${expectedLimit}`,()=>assert.equal(boundedLimit(value),expectedLimit));
}
