# PayMongo Production Release Report

Date: 2026-10-13 (Asia/Manila)

**LIVE INFRASTRUCTURE DEPLOYED — PAYMENTS DISABLED**

## Source and preservation

- Canonical project: `/Users/marc/Desktop/PocketPixelsBooth`; no clone, worktree, duplicate project or new dependency was created.
- Starting local and fetched remote main: `b35f92ca03ddd74d7edb6c34887308817feae5f7`.
- Final reviewed implementation: `802795ebe7fb0176136df9eef5b7c46020c96a89`, pushed normally to the existing repository; local and remote matched after push. The subsequent documentation commit contains this report and is identified in the handoff/Git history, since a file cannot contain its own commit SHA.
- Verified TEST commit `f5e6c3c17d794882d9e840fe4ae8ad5acbdebd8f` remains an ancestor. Newer receipt/sticker artwork changes, tracked renders, ignored owner work and the existing consolidation stash are preserved.
- The completion-outbox drain fix remains intact. No payment system was rebuilt. Changes protect operator entry, separate LIVE operator credentials, preserve old pairing on failure, provision inert infrastructure, and change provider descriptions to `Made to Keep Studios order <existing-id>`.
- Bundle ID `com.pocketpixels.PocketPixelsBooth` and signing team `PQ26682725` are unchanged. Camera, receipt, printer and gallery implementations were not changed.
- Credential/private-key pattern review of 415 tracked files and available text history across 96 commits found no matching LIVE keys, webhook secrets, GitHub tokens or private-key blocks. This is a bounded scan, not a certification of every historical binary/image. The repository remains public and includes preview imagery; the owner should decide whether private visibility is preferable. Visibility was not changed. No secret, device-token value, customer archive or database export was committed.

## Isolated infrastructure

| Item | Evidence |
|---|---|
| Account inventory | Authenticated Cloudflare account inspected before creation: gallery and TEST Workers existed; only TEST D1 existed; no custom DNS zones were returned. Owner approved new isolated LIVE resources and the proposed workers.dev hostname. |
| TEST | Worker/configuration/database/secrets/routes/Cron were not remotely modified. Health returned TEST with LIVE disabled. Existing TEST secret names remain present. |
| LIVE Worker | `pocket-pixels-payments-live`; first inert version `bd9ac10c-2afa-48d9-ac4f-b98da7feaa2a`. Owner secret changes produced current version `71d66b05-429a-4cbb-9e11-77ee9d96e7cb`. |
| LIVE HTTPS | `https://pocket-pixels-payments-live.madetokeepstudios.workers.dev`; workers.dev enabled, preview URLs disabled. Gallery hostname is not the Payments API. |
| LIVE D1 | `pocket-pixels-payments-live`, ID `3417d35d-3d47-457a-bd45-0d6371fadc8f`, APAC. New and empty before migration. Correct destination and empty schema inspected first; migrations 0001–0005 applied in order and history independently reread. No TEST rows copied. |
| TEST D1 | `d7b7bfe1-b981-4289-b69b-bd120703887d`; independent of LIVE. |
| Payment gate | Deployed health returns service `pocket-pixels-payments`, version `3`, environment `live`, `liveEnabled: false`. Authenticated LIVE QR probe returned 503 `live_payments_disabled` before any order lookup/provider call; no checkout/order was created for that probe. |
| Secrets | Owner securely entered `PAYMONGO_SECRET_KEY_LIVE`, `PAYMONGO_PUBLIC_KEY_LIVE`, `PAYMONGO_WEBHOOK_SECRET_LIVE` with Wrangler. Names/presence verified without retrieving values. TEST secret names were not reused. Presence alone does not establish successful provider authentication. |
| LIVE webhook | Owner created enabled webhook `hook_1nxgEtcAEwcmm5AJt4EuEDDQ` in dashboard LIVE mode, URL `/v1/webhooks/paymongo/live`, events exactly `payment.paid`, `payment.failed`, `qrph.expired`. Details inspected; signing secret hidden afterward. No genuine LIVE payment delivery has occurred. |
| Reconciliation | `*/5 * * * *` registered and independently confirmed through Cloudflare's schedule API. Automated runtime tests verify disabled LIVE Cron skips D1/provider work. Remote `reconciliation_runs` remains empty while disabled. Tail produced no captured scheduled-event evidence; enabled LIVE reconciliation/provider success remains to be verified during the approved pilot. |
| Operational records | Two separate device rows, one draft event and one draft policy. Zero LIVE orders, attempts, entitlements and print batches at verification. |
| Backups | Private mode-0600 LIVE export loaded into local SQLite; integrity check passed. SHA-256 `68b11a6c712bfd291c0a2b13925636088071848b32c901565b3988f56f32eb32`. It contains the two hashed device rows and draft policy, no payment records. D1 Time Travel bookmark retrieval succeeded. No destructive restore was attempted. |
| Recovery procedures | Concrete monitoring, backup/restore cautions, compatible Worker rollback, credential revocation and operator incident instructions added to `docs/payment-operations.md`. Backup retention is plan-dependent; no unverified 30-day claim. |

## Merchant and payment readiness

- Authenticated owner account inspected: Individual account, QR Ph **Active**, LIVE API keys available, dashboard Test mode switch off. Existing merchant legal/trade identity was inspected privately and was not renamed to match app branding.
- LIVE payment acceptance and wallet enablement are separate. Wallet page confirms in-network PayMongo balance movement, with an upgrade required for external bank/e-wallet transfers. Bank information remains unset. This is an external withdrawal restriction, not a reason to declare active QR Ph unavailable.
- Payout Overview shows weekly Wednesday generation into PayMongo Payments, Inc./the PayMongo wallet, and no payout history. There is no evidence of this application's LIVE money being received, settled or withdrawn.
- Official standard QR Ph online pricing is **1.34%, excluding VAT**; account-specific pricing/actual assessed fees must be checked on the eventual transaction. No instant-settlement add-on or payout change was purchased.
- Current official QR Ph documentation confirms dynamic Payment Intent/method attachment and the three selected webhook events. Existing signature verification, independent provider reread, idempotency, unique entitlements, session-bound claims, durable per-copy outcomes, printer recovery and completion behavior were reviewed and preserved.
- Photo keepsakes are not represented as BIR sales invoices. Applicable registration/invoicing arrangements have not been supplied by the owner. PayMongo QR eligibility is not evidence of tax compliance. This remains an owner confirmation before collecting customer revenue, not a requirement to enable unrelated payment methods.

## Operator and device readiness

- All operator tools behind the Welcome gesture now require Apple device-owner authentication. Explicit **Use iPad Passcode** uses a passcode-only Keychain ACL. No app PIN is hardcoded or stored; owner setup/recovery uses iPad Settings/Apple recovery. Face ID, passcode access, and renewed authentication after Done were physically confirmed by the owner.
- Sessions lock on dismissal, backgrounding or five minutes. Cancelled/failed/late authentication cannot grant access; automated denial/retry/background-race checks pass. Locking does not erase evidence or archives.
- LIVE booth row `ipad-carlo-live-20261013` has only `booth`; operator row `owner-carlo-live-20261013` has only `operator`. Remote probes verified booth administration and operator booth access both return 403. Operator Keychain credentials bind to exact environment/URL and require a current local authentication permit. LIVE never falls back to the booth token for administration.
- Physical device independently identified as **Carlo**, iPad Pro 11-inch (4th generation), iPadOS **26.6.1**. Reviewed development-signed Release configuration **1.0 (1)** built, signature verified, installed in place and launched. No uninstall or archive reset.
- Application Support and settings backed up privately before install. All **288 customer archive files** independently matched their pre-install SHA-256 fingerprints after final installation and LIVE pairing. The resolved checkout journal, all three delivered outbox entries and printer preferences compared unchanged after the initial install. Original gallery endpoints/assets and queued-upload storage are preserved.
- Before update, owner confirmed Welcome; local checkout was resolved, both copy reports and completion delivered, and AppRecoveryStateV1 contained no session file. A historical TEST cash order remains `IN_SESSION` with zero print batches (`863c6254-3265-45f1-a464-3b6b68d559d7`); it was retained, not completed or deleted without evidence. Separate old staging-account authorizations also remain in TEST.
- Owner explicitly approved changing Carlo to disabled LIVE. An initial attempt retained TEST because the pairing destination had not been changed. After correction, an independent on-device settings copy confirms the exact LIVE URL and environment `live`; the owner confirmed Refresh displays the LIVE pilot draft and **Live payments: Disabled**, demonstrating operator API access. Credentials clearing from a field was not treated as proof of success.
- The two temporary mode-0600 device-token transfer files created during this execution were removed after confirmed pairing. Device credentials remain in Keychain; D1/backups contain hashes only. No owner file or operational record was deleted.
- TEST simulator URL exposure remains guarded by environment and provider TEST evidence. LIVE has no usable simulator URL. Private / Prepaid remains available through authenticated operator controls; no new guest session was started.
- Owner confirmed VOZY G80 connected/ready and Print Accounting clear of pending/uncertain reports after LIVE pairing. Earlier TEST paper acceptance is preserved evidence, not a claim that new LIVE paper printed.

## Proposed supervised event

- Name delegated by owner: **Made to Keep Studios — Supervised LIVE Pilot**.
- Event ID `3e056cab-264f-446f-875d-6c8d13668b0e`; event version **2**; draft policy revision **1**, ID `1718beb4-2cc4-45ac-a86c-a94ba5bb2dd7`.
- Proposed acceptance-only price **₱1.00**, default/max **one copy**, QR Ph only, attended/offline cash disabled, no offline-valid policy. All six current formats retained.
- Venue left empty rather than invented. Normal customer pricing, venue and maximum-copy policy are not yet established.
- Event remains **DRAFT**, no active policy, no publish/activate call. This proposed low-value acceptance policy requires explicit owner price/method acknowledgment and financial authorization before activation.

## Validation and launch decision

- Backend suite: **196/196 passed** after the branding change; syntax checks and TEST/LIVE Wrangler dry runs passed.
- Final focused iOS suite: **34/34 tests, 36 executions**, zero failures/skips; auth/access separation, API encoding/error paths, checkout recovery, camera handoff, print durability and completion drain covered. Local result bundle: `BuildArtifacts/PayMongoProductionPasscodeValidation.xcresult` (not committed).
- Final Release build passed; no new warning in modified files. Existing unrelated warnings remain. Codesign verification and physical in-place installation/launch succeeded.
- TEST acceptance evidence from the existing final report remains valid: provider TEST QR, server-confirmed payment, one entitlement, exactly two owner-confirmed paper receipts, two DELIVERED outcomes, COMPLETE order/batch, CONSUMED entitlement and Welcome reset. No new TEST payment order was created to repeat it.
- Historical gallery behavior was preserved by source/configuration inspection and data preservation; no new physical historical-gallery scan was claimed.
- **No LIVE transaction attempted or authorized.** No bank/e-wallet payment, LIVE entitlement, LIVE paper, settled funds or withdrawal is claimed.
- Full production qualification is **not complete**: device records include a stopped 18-session physical run (17 receipts sent, 10 confirmed) and a completed 100-session **simulation** (zero physical receipts). Neither meets the mandatory 100-session end-to-end physical gate. Unrestricted rollout remains NO-GO.

### Pre-activation checkpoint: infrastructure GO; payment activation held

Infrastructure, authenticated LIVE iPad pairing, operator authentication and current printer/recovery readiness are confirmed. Payment activation remains held pending the owner's applicable registration/invoicing acknowledgment, acceptance of restricted external withdrawals, exact draft-price/method acknowledgment and separate financial approval. Enabled LIVE webhook delivery and provider reconciliation will require the single approved supervised acceptance transaction; they are not already proven by secret presence or TEST evidence. No public or unattended customer collection is authorized.

### Outstanding owner actions

1. Confirm applicable invoicing/registration arrangements and whether the limited pilot's proceeds remaining in the restricted PayMongo wallet are acceptable. External withdrawal requires PayMongo wallet enablement; it is separate from QR-only acceptance.
2. Acknowledge the exact proposed ₱1/one-copy/QR-only revision and supply venue or confirm this is an owner-supervised bench acceptance. Only then give **explicit separate approval** to enable payments and initiate exactly one real-money transaction. Owner must perform bank/e-wallet payment and physically confirm paper.
3. Before unrestricted rollout, supply normal production pricing/event details and complete the mandatory real 100-session hardware/operational qualification. Simulation must not be counted as physical acceptance.

### Official sources reviewed

- [PayMongo QR Ph and events](https://docs.paymongo.com/docs/payment-acceptance-qr-ph)
- [Activation versus wallet enablement](https://docs.paymongo.com/docs/account-settings-troubleshooting)
- [PayMongo pricing](https://www.paymongo.com/en/pricing)
- [Wallet capabilities](https://docs.paymongo.com/docs/money-movement-wallets)
- [Cloudflare Wrangler environment configuration](https://developers.cloudflare.com/workers/wrangler/configuration/)
- [D1 Time Travel/backups](https://developers.cloudflare.com/d1/reference/time-travel/)
- [BIR invoicing clarification](https://bir-cdn.bir.gov.ph/BIR/pdf/RMC%20No.%2077-2024.pdf)

Final status: **LIVE INFRASTRUCTURE DEPLOYED — PAYMENTS DISABLED**.
