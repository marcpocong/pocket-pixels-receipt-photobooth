// Creates a per-device bearer credential for the Payments Worker.
//
// The token is written to a mode-0600 file (enter it on the iPad's pairing screen, then delete the
// file). Only its SHA-256 hash is printed, inside an INSERT statement for the target D1 database.
//   node scripts/device-credential.mjs <device-id> "<display name>" <scopes> <account-id> <token-output-file>
// Example scopes: "booth,operator" for a kiosk the operator also manages from.
import { createHash, randomBytes } from "node:crypto";
import { writeFileSync } from "node:fs";

const [deviceId, displayName, scopes, accountId, output] = process.argv.slice(2);
const id = /^[A-Za-z0-9._:-]{1,100}$/;
if (!deviceId || !id.test(deviceId) || !displayName || !/^(booth|operator)(,(booth|operator))*$/.test(scopes || "") || !id.test(accountId || "") || !output) {
    console.error('usage: node scripts/device-credential.mjs <device-id> "<display name>" <booth|operator|booth,operator> <account-id> <token-output-file>');
    process.exit(64);
}
const token = randomBytes(32).toString("base64url");
writeFileSync(output, `${token}\n`, { mode: 0o600, flag: "wx" });
const hash = createHash("sha256").update(token).digest("hex");
const quote = value => `'${String(value).replaceAll("'", "''")}'`;
console.log(`INSERT INTO devices(id,credential_hash,display_name,scopes,revoked_at,created_at,account_id) VALUES(${quote(deviceId)},${quote(hash)},${quote(displayName)},${quote(scopes)},NULL,${quote(new Date().toISOString())},${quote(accountId)});`);
console.error(`Token written to ${output} (mode 0600). Pair the iPad, then delete the file.`);
