# PayMongo Final Release Report

Date: 2026-10-13 (Asia/Manila)

## A. Source status

- Canonical project: `/Users/marc/Desktop/PocketPixelsBooth`
- Starting reference: `06f63f643d60542a7da5ad3bad96bd3fc843497f`
- Integrated implementation: `6befd7dca2da5070da1f5fca7aa48c8db1ba91dc`
- Current local HEAD before the final acceptance commit: `698b18c7121f86f05f473f6635c192deb694e51e`
- Infrastructure verification commit: `a0411bc0202a0a7ba29806a29895a833f2d03c2a`
- Final local/remote ref: `main` at the commit containing this report; the resolved SHA is recorded in the final handoff because a committed file cannot contain its own Git object ID.
- User work preserved: yes. The pre-existing modified receipt PNGs, untracked event-render PNGs, `BuildArtifacts/StickerStudio/`, and existing stash were not changed, deleted, staged, or reset.
- Final acceptance-commit scope: the TEST workers.dev route correction, the small offline-cash draft invariant repair and targeted test, and this report. The owner's BuildArtifacts work remains separate and unstaged.
- Git write restriction: resolved. `.git/index.lock` is absent and staging the intended Worker configuration succeeded.

PR #2 contains the locally verified application/backend completion: the hardware-qualification isolation repair, TEST-only protected PayMongo simulator launcher, provider-aligned QR expiry, QR-first paid-event defaults, and Production Gate Worker tests. The intended source/config diff was scanned for common credential and private-key value patterns; none were found. No simulator URL, bearer token, webhook secret, or provider credential is recorded here.

The GitHub repository is public as of this verification. The owner must decide whether that visibility is intended.

## B. Verified environment

| Item | Result | Evidence |
|---|---|---|
| TEST Worker hostname | PASS | Existing Worker reused at `https://pocket-pixels-payments-test.madetokeepstudios.workers.dev`; no duplicate Worker or route was created. The checked-in TEST configuration was corrected to enable this workers.dev hostname and disable preview URLs. |
| TEST health response | PASS | `/v1/health` returned service `pocket-pixels-payments`, version `3`, environment `test`, and `liveEnabled: false` after deployment. |
| Environment/live guard | PASS | Only TEST was deployed. LIVE was not queried, migrated, deployed, or enabled; checked-in LIVE remains `LIVE_PAYMENTS_ENABLED=false`. |
| TEST D1 binding | PASS | Existing database `pocket-pixels-payments-test`, ID `d7b7bfe1-b981-4289-b69b-bd120703887d`, is the deployed binding. The local TEST placeholder was corrected to match it. |
| TEST D1 backup | PASS | A pre-deployment export was created with mode `0600`; SHA-256 `6423d9cc25e5b02308827fe706fdc2bed89610bf4a0392f4fe975f016b9d0a21`. It is outside the repository and contains no LIVE data. |
| TEST D1 migrations | PASS | Remote history contains migrations `0001` through `0005`; Wrangler reported no pending migration. No migration was rerun. |
| Secret presence | PASS | Existing TEST secret names were verified without reading values: PayMongo TEST public/secret keys, TEST webhook secret, and offline-policy signing key/key ID. |
| Webhook | PASS (operational evidence) | Remote D1 contains authentic TEST `payment.paid` webhook processing with `livemode=0`, replay-safe processing outcome `PAID_VERIFIED`, and associated authoritative intent/payment evidence. Current secret presence was verified; no secret value was exposed. |
| Cron reconciliation | PASS | Existing `*/5 * * * *` trigger was preserved. Post-deployment scheduled executions at 17:20, 17:25, 17:30, 17:35, and 17:40 UTC completed successfully. |
| Deployed TEST version | PASS | Version `252f4caa-351e-45d6-8c3f-6e78c916ce3a`, deployed after local configuration validation. |
| iPad pairing/environment | PASS | Physical iPad `Carlo` (iPadOS 26.6.1) has the current build installed in place, is paired to the TEST endpoint as `ipad-pro-step3-20261012`, and reports booth/operator scopes and LIVE disabled. |
| Printer transport | PASS (not paper proof) | The current app reconnected to the saved VOZY G80, discovered service `18F0` and writable characteristic `2AF1`, and reported write capability. This is not counted as physical paper confirmation. |

The server retains one prior provider-backed two-copy TEST transaction for the same physical iPad: ₱50 per copy, two copies, ₱100 total, QR Ph, `PAID_VERIFIED`, one `VERIFIED_QRPH` entitlement, one completed two-copy print batch, and two `DELIVERED` Bluetooth outcomes. Provider intent, method, payment, QR image, simulator URL, and authentic TEST webhook evidence are present; their sensitive values were not printed or copied. This proves the provider/server record chain, but no owner paper confirmation was recorded for that earlier run.

The original endpoint failure was Cloudflare error 1042: `workers_dev=false` with no custom route meant the advertised workers.dev hostname did not reach the Worker. Enabling the existing TEST Worker's workers.dev route repaired `/v1/health` and authenticated device/event access. No LIVE setting was changed.

For the supervised acceptance run, the owner published the Step 3 event at ₱50 per copy with a default of two copies and selected **Paid events (server-managed)** as the booth charging source. A prior attempt while the booth was still explicitly in Private / Prepaid mode correctly bypassed payment and then failed closed before print transmission when its local authorization did not match the selected two-copy quantity. That session was cancelled and is not counted as payment acceptance.

The final active server policy is revision 3: `PAY_PER_PRINT`, ₱50 per copy, default two copies, QR Ph enabled, attended cash disabled, and offline cash disabled. The physical run exposed a narrow local outbox race: both copy outcomes reached D1, but an overlapping background sync initially left the newly eligible completion entry queued. The queued completion was safely replayed without reprinting, and D1 then reached `COMPLETE`/`CONSUMED`. The app now drains newly eligible completion entries within the same sync; its focused regression passes and the corrected build is installed on the iPad.

## C. Acceptance results

| Acceptance item | Result | Evidence |
|---|---|---|
| QR image generation | PASS | The fresh physical-iPad TEST checkout received and displayed the real provider QR; no mock record was used. |
| QR display on iPad | PASS | The fresh ₱100 QR Ph checkout displayed the provider QR on the physical iPad. |
| PayMongo TEST simulator payment | PASS | The owner opened the protected TEST-only simulator from the QR screen, completed secure TEST authorization, and used no bank/e-wallet or real money. |
| Server verification | PASS | The app remained locked until the simulator payment resolved. Remote D1 records the fresh attempt as TEST (`livemode=0`) and `PAID_VERIFIED`, with an authentic `payment.paid` webhook processed as `PAID_VERIFIED`. |
| Entitlement issuance | PASS | Remote D1 contains exactly one `VERIFIED_QRPH` entitlement for the fresh order, fixed at two purchased copies and claimed by the original session. |
| Camera unlock | PASS | The original fresh checkout session advanced to the camera only after TEST simulator authorization. |
| Receipt composition | PASS | The same paid session captured photos and reached the receipt preview with two purchased copies. |
| Exact purchased-copy printing | PASS | The VOZY G80 physically produced exactly two receipts; the owner confirmed both were complete, correct, and readable. |
| Print outcome reporting | PASS | Remote D1 contains exactly two `DELIVERED` outcomes for two authorized copies, with zero uncertain or failed outcomes. |
| Payment completion | PASS | Remote D1 records the order and print batch `COMPLETE` and the single entitlement `CONSUMED`. The post-print action returned the booth to a clean Welcome state. |
| Failed payment safety | PASS | Failed, expired, unknown, ambiguous, supersede-grace, and no-cash-fallback tests pass; remote expired TEST attempts did not issue entitlements. |
| Interrupted session recovery | PASS | Original-session lookup/claim, paid recovery, idempotency, and fresh-photo isolation tests pass without another charge. |
| Interrupted print safety | PASS | In-flight recovery becomes durable `UNCERTAIN`, requires acknowledgement, and is never automatically resent. |
| Prepaid regression | PASS | Private/prepaid remains local and independent of the Payments Worker; the final iOS regression passed its prepaid/checkout guards. |
| Final iOS build | PASS | The current project built and was installed/launched in place on physical iPad `Carlo`. |
| Final relevant test suite | PASS | Payments Worker: 196/196 and prior full iOS regression: 395/395. After the two final repairs, the focused offline-cash and durable-print-outbox regression passed 14/14, including the new completion-drain test. The formerly failing hardware-isolation test passes. |
| Physical printer confirmation | PASS | The owner physically observed exactly two complete, correct, readable VOZY G80 paper receipts from the fresh paid session. |

## D. Remaining blockers

No TEST software, provider, or physical acceptance blocker remains for the verified scenario.

LIVE owner gates remain separate: merchant QR Ph eligibility, settlement/payout readiness, registration/invoicing/regulatory requirements, production secrets/D1/webhook/hostname, device provisioning, backups/incident procedures, final live physical sign-off, and the 100-session qualification. Keep `LIVE_PAYMENTS_ENABLED=false` until explicit authorization.

## E. Production release decision

**TEST INTEGRATION VERIFIED — LIVE NOT YET AUTHORIZED**

LIVE is not authorized and was not modified.
