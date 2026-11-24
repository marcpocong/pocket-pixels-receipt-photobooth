# Phase 3 release record

See the [Phase 3.2 checkout and RC 2 release record](PHASE3.2.md) for the current candidate.

The release starts from Phase 2 commit `fb8c0763e4c1fdaf5ad380e05e3eb73303ed938a` and uses marketing version **1.0.0**, build **4**. The legacy archive remains at `8baadb77c53321c576d4fe160efc66def199b8b8`. See the [payment transitions and API contract](PHASE2.md), [device recovery instructions](DEVICE-RECOVERY.md), and [PayMongo decommissioning inventory](DECOMMISSION.md).

## Release hardening

- Guest polling registers the original checkout once and reads its current status. Facts and reviews sync when they change. Equal snapshots cause no durable record rewrite. Print evidence imports validate the session, purchased copy count and fingerprint, and apply one bounded atomic batch. A conflict preserves the original record and blocks the batch.
- Required-receipt checkout asks guests to wait for the mobile link. Acknowledged or closed mobile sessions hide transfer instructions while preserving the original receipt path. Receipt presence and independent confirmation remain distinct.
- Mobile checkout configuration and repeated storage faults use the existing monitoring health request. Receipt monitoring reads a fixed indexed 15-minute window and records only failure class and count. One or two retryable failures do not open an incident. Existing episode handling coalesces alerts. No independent receipt crawler or recurring Drive writes are involved.
- The production gate now generates both browser fixtures and includes the private bridge and backup checks. Existing valid historical and lifecycle assertions remain covered. Activation fixtures use supported cash policies and explicitly check refusal of retired QR policies.

## Security and account boundaries

Manual checkout capabilities remain fragment-scoped, authenticated in headers, and time-limited. Booth ownership and operator credentials scope their respective APIs. Receipt writes remain size-bounded and idempotent. Uploads need signed owner-only storage evidence and operator previews require separate authorization. Manual failure logs use fixed classes. TEST and LIVE use separate receipt keys, roots and retention settings on the existing private Apps Script project. The gallery service has its own deployment and storage.

The historical secret scan is in the [Phase 1 audit](README.md). Phase 3 extended the scan across the post-baseline Git objects and candidate changes with published token patterns and exact known local secret values. Results are in the private release ledger. No history rewrite or visibility change was made.

The GitHub repository is public. Making it private would restrict prereleases and source downloads to authorized readers, detach existing public forks, remove stars and watchers, and require review of integration access, Actions minutes, and plan-specific security features. Previously distributed copies remain outside repository access controls. Any visibility change is an owner decision. [GitHub visibility consequences](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/managing-repository-settings/setting-repository-visibility)

## Data and capacity

LIVE migration 0009 applied after isolated SQLite verification. The private dump passed integrity and foreign-key checks, and applying 0009 to the copy preserved every row of all 19 preexisting tables. The migration adds seven isolated manual tables. Keep the additive schema during a Worker rollback. Current financial history remains authoritative.

Carlo's pre-install persistent files were copied to the Mac's FileVault-protected private release directory. An offline reconstruction matched all four file digests. The snapshot had no pending session, payment, or recovery journal. The test fixture covers a pending journal and corrupted manifest. The restore tool writes to an isolated review directory. [Device recovery instructions](DEVICE-RECOVERY.md)

The historical gallery sample delivered a complete page through the current public front door. The disconnected legacy hostname still fails DNS. Existing public gallery routing, resumable compatibility, storage and source were kept in place.

The receipt service reuses existing allocations. Owner Drive quota reported 86.4% storage headroom at inspection. The reviewed physical evidence import fits the Free D1 per-invocation query budget. Receipt health uses an indexed narrow range. Day-level Cloudflare and Apps Script capacity depends on account usage. [Cloudflare D1 limits](https://developers.cloudflare.com/d1/platform/limits/) · [Apps Script quotas](https://developers.google.com/apps-script/guides/services/quotas)

## Distribution and validation

The matching development identity was renewed under team `PQ26682725`. The verified profile covers Carlo and expires December 2, 2026 at 12:14:21 a.m. Manila time. The signed build preserves the original bundle, Keychain access group, and fixed iPad portrait. The currently verified compatible route is short-lived Personal Team provisioning. Registered-device distribution requires a compatible eligible Apple Developer Program team and distribution profile. [Apple developer account and provisioning](https://developer.apple.com/help/account/basics/about-your-developer-account/) · [Apple registered-device distribution](https://developer.apple.com/documentation/xcode/distributing-your-app-to-registered-devices/)

The signed Mach-O executable SHA-256 is `a246f33d6b3507bc4c6fdbbda8d3c8926a623d7016dd68ae98dec0fa17dc6463`. The private archive is identified as **Made to Keep 1.0.0 (4) final.xcarchive** in the restricted owner handoff.

Hosted Actions reported that its jobs could not start because of account billing. The equivalent local build uses Xcode 27.2 and iPadOS 26.5. Backend validation uses the pinned package dependencies and the available Node 24 runtime. Raw results and device identifiers stay in protected local storage. [Hosted Actions run](https://github.com/marcpocong/pocket-pixels-receipt-photobooth/actions/runs/45434330329)

The full local production suite accounted for 1,032 cases. Its initial run passed 1,009 and reported 23 failures or interruptions in older activating-QR fixtures. The final affected-area runs recorded a pass for each of those 23 case IDs and covered 129 cases across checkout, WebKit and event lifecycle. One stalled preliminary case was interrupted after the corresponding corrected case passed. The combined evidence covers all 1,032 cases, with zero skipped.

The full native UI run passed 31 of 33 cases. The other two cases used outdated payment and accessibility controls. The final-source rerun passed both, including entry of the exact cash price, keyboard dismissal, and navigation between Receipt and Tools at accessibility sizes. Combined UI evidence covers 33 cases, with zero skipped.

The backend gate passed 243 payments, 60 monitoring, 45 gallery Worker, six Apps Script resumable upload, one isolated deployment contract, six private receipt bridge, and three backup tests. The gallery fixture and package checks passed.

## Production rollout and rollback

| Service | Verified release | Rollback scope |
|---|---|---|
| LIVE Payments Worker | `d5d9dae3-98d2-4c02-9781-3fdb7e0029b9` | The staged `5a2c4dee-7969-4136-beae-e7fc4a4d78ea` version has the manual service gate disabled. Keep D1 migration 0009, existing checkout identities, and new PayMongo creation disabled. |
| TEST Payments Worker | `a7019025-3b56-41db-86d5-e6410bde5364` | TEST has independent secrets and receipt storage. |
| Private receipt Apps Script | Version 8 | Version 8 serves both storage roots. Version 7 supports TEST only, so retain version 8 for any active LIVE receipt operation. |
| Monitoring Worker | `4452a6d8-2197-488c-922e-155575f40b7d` | Prior version `4d318023-b9bf-4818-a3a8-f629871cea96` supports the existing heartbeat schema and lacks the new manual-service observations. |

LIVE health reports manual checkout enabled and new PayMongo creation disabled. A synthetic LIVE checkout exercised identity-preserving replay, late claim retention, immutable print evidence, idempotent review, and receipt retry. Chrome at a 375-point viewport rendered the closed original checkout with private receipt confirmation and hid the transfer controls. The Drive root, submission folder and image were owner-only. Anonymous image access returned 403, and the scoped operator preview matched the submitted bytes. Both temporary test credentials were revoked. The synthetic records remain for audit with fictional receiving details and no money moved. The new monitoring Worker observed healthy LIVE service and stopped expecting PayMongo reconciliation freshness.

For a subsequent authorized deploy, use the recorded LIVE bindings with `LIVE_PAYMENTS_ENABLED=true`, `PAYMONGO_NEW_CHECKOUTS_ENABLED=false`, `LEGACY_RECONCILIATION_ENABLED=false`, `MANUAL_CHECKOUT_ENABLED=true`, and `RECEIPTS_KEY_ID=receipt-live-v1`. Preserve the private receipt endpoint and its secrets. The corresponding monitor deploy uses `EXPECT_MANUAL_CHECKOUT=true`. Verify bindings and health after deployment. The checked-in defaults protect an unreviewed deployment from enabling LIVE checkout.

If the receipt bridge fails, pause issuance at the booth and retain open claims for reconciliation by original identity. The global manual gate disables guest status and submission as well as new checkouts, so account for those open claims before taking that route. Keep the compatible bridge, signing keys and additive D1 history during a compatible rollback.

## Carlo and physical handoff

Carlo was updated in place from 1.0 build 3 to 1.0.0 build 4. iPadOS requested developer trust, the owner approved the existing profile, and device tooling confirmed the process running. All four existing persistent files were byte-identical both immediately after installation and after launch. The production monitoring database accepted an authenticated heartbeat from Carlo on launch. The owner opened System → Payments on Carlo and confirmed Payment Maintenance showed digital payment disabled. The payment connection and receiving account require pairing and approval. The LIVE receipt path was tested with scoped synthetic credentials outside Carlo.

The signed archive, signing metadata, raw validation, deployment settings, and sensitive evidence are held outside Git. Phase 4 covers physical camera, BLE/TCP, paper interruption and recovery, mobile devices and network handoff, and the sustained 100-session qualification. The accepted VOZY G80 paper gap is preserved.

Before accepting live digital payments, the owner must pair Carlo to the intended LIVE booth account and approve the permitted receiving account and QR. Review the provider-side balance, payouts, disputes and export under the supplied December 1 PayMongo notice. Arrange compatible reprovisioning before the current profile expires.
