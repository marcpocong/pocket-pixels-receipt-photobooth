# LIVE release readiness — October 14, 2026

Checkpoint status: **NEEDS OWNER ACTION — in-place installation approval pending.** No new LIVE deployment, event mutation, payment, cash attestation or print was performed. This is a preparation report, not a completed supervised pilot.

## A. MacBook and Carlo

- **PASS:** established workspace `/Users/marc/Desktop/PocketPixelsBooth`; initial local and remote main both `3ca41749dc5d46aa371f619bf3c1ef1da3f4be1b`. Working tree initially clean. Existing owner stash preserved; no clone/worktree created.
- **PASS:** Xcode 27.0 (27A266a). Carlo independently identified as a wired, paired physical iPad Pro 11-inch (4th generation), iPadOS 26.6.1. Developer Mode enabled, compatible developer disk image usable, no passcode required at inspection, and available as a physical Xcode destination. Unique device identifier retained privately.
- **PASS:** existing developer app `com.pocketpixels.PocketPixelsBooth`, version 1.0 (1), with accessible data container. Private 182 MB app-container copy contains 1,389 files, including 300 archive files, 209 artwork files, 640 qualification diagnostic files, saved operator workspace and payment state. SHA-256 manifest recorded outside Git with restrictive permissions. This is an app-data copy, not a full-device or Keychain backup. Keychain values were not retrieved.
- **PASS:** all three checkout checkpoints are completed; all seven print-outbox entries have delivered local/report states. Saved payment environment is LIVE with the expected Worker URL. VOZY G80 Bluetooth identity and network printer settings remain saved; current physical printer readiness is **NOT TESTED**.
- **PASS:** Release build for Carlo and strict code-signature verification. Bundle ID, team `PQ26682725`, iPad-only family, minimum iOS 18 and version 1.0 (1) preserved. Embedded profile includes Carlo and application identifier `PQ26682725.com.pocketpixels.PocketPixelsBooth`. Installed binary signing entitlements were not independently extracted; compatibility assessment uses the existing project identity, signed candidate and historical release evidence. In-place installation must still be verified.
- **NEEDS OWNER ACTION:** current development provisioning profile expires **October 19, 2026, 4:10 PM Manila**. Renewal is needed for sustained operation; no signing/profile changes were made.
- **NOT TESTED:** updated binary installation, launch, post-install hash comparison, device-side design migration, current Keychain credential use, physical operator navigation and printer readiness. Installation approval requested separately; no uninstall/reset performed.
- Device screenshots, app/process inventory, file copies and development destinations are supported. No existing XCUITest target was found. Device Hub UI access timed out; direct physical touchscreen automation is unverified. No new automation framework/test target installed. Owner authentication remains physical.

## B. Browser automation

- **PASS:** existing Chrome extension through `cua_repl`; opened GitHub CI, clicked ordinary navigation, read page contents and captured a screenshot. No new integration/package, profile change or debugging port was needed.
- **PASS:** authenticated GitHub and PayMongo dashboards accessed read-only. PayMongo historical payment detail and enabled LIVE webhook independently inspected.
- Cloudflare browser requires sign-in; CLI authentication already supports the needed read-only inspection. Browser sign-in/security prompts were not bypassed. No cookies/tokens exported.

## C. Cloudflare LIVE

- **PASS:** active Worker `pocket-pixels-payments-live` is still 100% version `043c9012-0b3e-4b0d-a8ad-0e0c71172fd6`. No new version uploaded/deployed.
- **PASS:** version bindings show `PAYMENTS_ENVIRONMENT=live`, `LIVE_PAYMENTS_ENABLED=true`, expected LIVE D1 `3417d35d-3d47-457a-bd45-0d6371fadc8f`, and three existing PayMongo LIVE secret names. Secret values were not retrieved. Health returns environment live and liveEnabled true.
- **PASS:** remote migrations list reports none pending; foreign-key check returns no violations. Cash confirmation needs no schema migration.
- **PASS:** latest inspected reconciliation run started October 14 at 7:10:20 PM Manila and finished 7:10:51 PM, zero pending attempts inspected, zero conflicts and no failure. Earlier five-minute runs also finished without failures.
- Prepared command, **not executed**, from `Backend/PaymentsWorker`: `npx wrangler deploy --env live --var LIVE_PAYMENTS_ENABLED:true`. Explicit override preserves the runtime gate despite checked-in false. Existing secrets are retained by Wrangler deployment; reviewed D1/vars/Cron remain configured. Never deploy the unchecked false default. LIVE-only dry run with this override passed and uploaded nothing.
- Proposed version ID is assigned by Cloudflare at deployment and is currently unknown. Exact commit must be refreshed at the later deployment checkpoint; Worker code is unchanged from `3ca4174` by this task.
- Reviewed rollback target: `043c9012-0b3e-4b0d-a8ad-0e0c71172fd6`, with enabled gate/current secret bindings. Command for a separately approved incident: `npx wrangler rollback 043c9012-0b3e-4b0d-a8ad-0e0c71172fd6 --env live`. No D1 rollback. Before new cash records, this preserves existing QR fulfillment. After attendant-confirmed cash is recorded, the old version lacks the endpoint and separate cash classification; reassess compatibility and prefer a forward fix rather than silently mislabelling new cash. Never execute rollback automatically.
- **NEEDS OWNER ACTION:** deployment checkpoint follows satisfactory app installation and non-payment checks. LIVE event lifecycle/public acceptance remain unchanged. TEST and gallery infrastructure untouched.

## D. Payments and regression evidence

- **PASS:** LIVE D1 currently has exactly two COMPLETE orders (200 centavos total), two PAID_VERIFIED LIVE QR attempts, two CONSUMED VERIFIED_QRPH entitlements, two COMPLETE batches and two DELIVERED copy outcomes. One attempt has reconciliation count zero, the other one. Signed LIVE payment.paid rows retain PAID_VERIFIED and ALREADY_PAID outcomes. No unresolved order present.
- **PASS:** PayMongo lists the two historical ₱1 QR payments as PAID. The second payment detail independently shows Live mode, API origin, ₱1 gross, ₱0.02 fee and ₱0.98 net. List settlement badges and detail settlement messaging differ; no new settlement conclusion is made. No transaction/retry was initiated.
- **PASS:** existing webhook enabled at the expected LIVE endpoint for payment.paid, payment.failed and qrph.expired. No webhook edit or redelivery induced.
- **PASS:** Carlo LIVE booth/operator D1 principals remain unrevoked in the same account with separate exact booth/operator scopes; temporary historical principals remain revoked. Actual current Keychain/API pairing use requires the installed app and genuine owner unlock; it is **NOT TESTED** here. No new principal/token created.
- **PASS:** `npm ci`, all **207 Worker tests**, syntax checks and explicit LIVE-only deployment dry run. Local tests cover cash scope/account/amount/policy checks, idempotent concurrent confirmation, QR/cash exclusivity, historical cash separation and accounting. No TEST deployment.
- Worker source review against the release-era `802795e` baseline finds QR creation's lock helper now takes device ID explicitly and status serialization is shared with cash confirmation. Provider creation, webhook verification, scheduled reconciliation and entitlement/print implementation otherwise remain unchanged by the new cash change. Automated tests plus historical/live read-only evidence support QR regression confidence; updated deployed code remains unverified until approved deployment. No new QR charge is presently justified solely to repeat prior pilots.
- **BLOCKED (original CI revision):** Production Gate run `38550679305` completed with two XCTest failures, both hardcoded local artifact-output paths in the Co-Branded and Session Setup render tests. The XCTest log reports 383 tests/2 failures; Swift Testing checks ran separately. This was not an iOS-suite success.
- **PASS (focused correction):** replaced those host-specific writes with always-retained XCTest PNG attachments. Rebuilt and ran both affected classes on an iPad simulator: **10 tests, zero failures**, 54 attachments exported successfully. Solo normal/thermal Co-Branded and attendant-cash renders visually inspected using generic synthetic artwork/photos. Application/backend implementation unchanged. The new commit triggers normal remote CI; its result must be checked separately.
- Release compilation succeeds with existing warnings, including actor-isolation/default-argument warnings and an unused variable. A warning-free full qualification is not claimed.
- **NOT TESTED:** new LIVE cash endpoint, real cash receipt, amount/entitlement/print pilot and post-restart accounting. No cash order created and no financial approval inferred.

## E. Printer and receipt checks

- **PASS (code review only):** Event Mode, four payment selections, per-event persisted design, Co-Branded geometry/fallback, owner-authenticated cash and separate operator-credential API path are present. Hardware Qualification remains a separate physical workflow.
- Sample Print Studio uses applied saved branding, never the unsaved Session Setup draft. The setup preview does render its effective draft profile without activation. A safely selectable Co-Branded sample path must be established on Carlo before paper testing; do not activate a LIVE event just to print a draft.
- **NOT TESTED:** actual VOZY connection, standard receipt, Co-Branded Solo, additional format, thermal paper quality, feed/cut or physical recovery. **Zero paper jobs sent** in this task. Transport delivery alone cannot establish physical paper output.
- **NOT TESTED:** 100-session physical endurance qualification. No smoke/pilot result can satisfy that requirement.

## F. Current state and next checkpoint

**NEEDS OWNER ACTION:** approve only the prepared in-place production app replacement/launch, then compare copied persisted data and collect startup evidence. Follow with physical owner unlock, non-payment navigation/preview and separately approved sample prints. Refresh CI before the specific LIVE deployment approval checkpoint. Subsequent cash pilot needs separate approval for reusing/revising/activating the existing isolated ₱1 pilot, one real cash payment, one print and safe pause/reconciliation.

Regular Sessions remains **DRAFT, version 2, ₱25/copy, default 1/max 3, QR-only**. Existing supervised pilot remains **PAUSED, version 7, ₱1/copy, one copy, QR-only**. No duplicate event or public acceptance activation. Recommend supervised validation first, provisioning renewal, and completion of broader physical qualification before claiming normal commercial release readiness.

Operations guidance updated in `docs/payment-operations.md`: attendant confirmation, historical reporting distinction, runtime gate preservation and approval/recovery sequence. Backups, diagnostic/payment snapshots and render artifacts remain private outside Git; no production data/secrets staged.
