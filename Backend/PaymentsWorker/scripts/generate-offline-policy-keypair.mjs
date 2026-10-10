// Generates an Ed25519 key pair for signing offline cash policy snapshots.
//
// The PRIVATE key is written to a mode-0600 file and is never printed. Load it as a Worker secret
// for one environment, then securely delete the file:
//   npx wrangler secret put OFFLINE_POLICY_SIGNING_KEY --env test < <file>
// The PUBLIC key (printed) is not secret; it is pinned in the iPad configuration with its key ID.
import { webcrypto } from "node:crypto";
import { writeFileSync } from "node:fs";

const keyId = process.argv[2];
const output = process.argv[3];
if (!keyId || !/^[A-Za-z0-9._:-]{1,100}$/.test(keyId) || !output) {
    console.error("usage: node scripts/generate-offline-policy-keypair.mjs <key-id> <private-key-output-file>");
    process.exit(64);
}
const pair = await webcrypto.subtle.generateKey({ name: "Ed25519" }, true, ["sign", "verify"]);
const privateKey = Buffer.from(await webcrypto.subtle.exportKey("pkcs8", pair.privateKey)).toString("base64");
const publicKey = Buffer.from(await webcrypto.subtle.exportKey("raw", pair.publicKey)).toString("base64");
writeFileSync(output, privateKey, { mode: 0o600, flag: "wx" });
console.log(JSON.stringify({ keyId, publicKeyRawBase64: publicKey, privateKeyFile: output, iPadSetting: `${keyId}:${publicKey}` }, null, 2));
