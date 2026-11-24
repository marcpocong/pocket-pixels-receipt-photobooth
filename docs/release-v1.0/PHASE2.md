# Phase 2 — implemented manual payments

Implementation and focused validation: 24–25 November 2026, Asia/Manila. Baseline `7cee3a5c31e6248ee2dd0fe444bf6d86bdaa8bf3`; archive `legacy-paymongo-final` remains at `8baadb77c53321c576d4fe160efc66def199b8b8`. Origin/main was fetched before delivery; the original safety stash and auxiliary preservation ref remain untouched. This document supersedes Phase 1's proposed payment implementation, including its online-only digital rule and proposed entitlement-table rebuild. Phase 1 findings remain historical evidence.

**Implemented and staged; not a production release.** LIVE has only the protective PayMongo creation retirement. Full manual checkout runs on TEST. No real receiving details, financial transfers, charges or customer receipts were used. No dependency, bundle identifier, signing, Keychain identifier, app version, portrait setting, gallery source, camera/renderer/transport implementation or paper-gap behavior was changed.

## Authority and immutable identity

Regular Booth and local event policies offer No Payment, Cash Only, Digital Payment Only and Cash + Digital Payment. Receiving-account configuration is private, operator-unlocked and disabled by default. Digital options require an enabled receiving account with provider, recipient, identifier and an explicit permitted-use attestation; an authorized receiving QR is optional. Enabling an account does not establish provider permission or verify money. Optional Receipt Submission is the initial digital receipt default.

The chosen mode, per-copy integer price, quantity, format, event/run/session and receiving revision freeze when checkout begins. Editing future settings never changes that record. Financial snapshot identity is a SHA-256 over the documented field order below. Receiver data is frozen separately on the server and locally. Exact replays retain original server UUID/link; conflicting session reuse is rejected.

`ManualPaymentStore` atomically persists a protected local journal before issuing one stable `manual-<checkoutID>` entitlement through the existing capture/copy pathway. Its local JSON uses native Date encoding to preserve the exact authorization across relaunch, with read compatibility for early ISO prototype records. Cloud status, mobile submissions and independent reviews are evidence; none can print, increase quantity, or mint a second entitlement. Existing server entitlements remain unchanged.

A local durable print-intent marker is also committed in the existing before-bytes gate. Once set, the original manual authorization cannot be treated as unused even after older outbox report entries are pruned. Failed writes stop the send. The physical outbox, immutable print jobs, receipt archives and current-session recovery still govern paper handling; neither an old payment record nor an unresolved review is a global operation lock.

## Acknowledgment, evidence and review

| Dimension | Behavior |
| --- | --- |
| Cash acknowledgment | Local guest assertion; no receiver, internet, provider or per-guest PIN required. |
| Digital ACK_ONLY | Local or mobile guest acknowledgment; receipt unnecessary; local acknowledgment needs no successful backend call. |
| Digital OPTIONAL | Same acknowledgment path, with optional private receipt. Later evidence remains on the original checkout. |
| Digital REQUIRED | Acknowledgment may be saved, but camera authority waits for matching server checkout/session/hash/copies/amount and privately stored Drive proof. A screenshot never verifies funds. |
| Receipt | Reserved → STORED_PRIVATE only after authenticated signed storage proof. Lost responses retry the same normalized image/operation/file identity. Up to three versions per checkout. |
| Independent review | Append-only FUNDS_CONFIRMED, MISMATCH or NEEDS_REVIEW, actual received amount and a recorded reason. Confirmation means checking funds independently. |
| Entitlement | One durable local source, MANUAL_CASH_ACKNOWLEDGED or MANUAL_DIGITAL_ACKNOWLEDGED; purchased quantity cannot expand. |
| Physical outcome | Separate original-session evidence from the existing outbox; cloud imports never authorize printing. |

Local guest acknowledgment expires after 30 minutes. The mobile acknowledgment window is also bounded to 30 minutes from the original supplied creation time (or server creation for older clients), so delayed offline sync cannot extend it. Mobile receipt capability expires after 24 hours. Closed/expired mobile claims are retained for review without authorizing photos. Receipt submission within the remaining evidence window can still attach to a closed original checkout. There is no automatic second-payment request or silent downgrade of REQUIRED.

Help & Recovery → Original Claims retains the original receiver, amount, policy and session. An unlocked operator can explicitly record the original guest's claim as unresolved, refresh private evidence, and prepare only its unused original authorization to resume. Required proof still applies. Resume requires no physical print intent and no copy that may have printed. For expired evidence links without the required proof, keep the claim unresolved for owner resolution; do not create a replacement payment or bypass the receipt policy. Any existing paper attempt uses the established receipt/physical recovery, never fresh automatic capture-and-print authority.

## Checkout API

`/v2/booth/*` uses the existing device Bearer credential and booth scope. `/v2/admin/*` uses the separate operator credential, released by the iPad only while Operator is unlocked. Account/device ownership and environment are checked. Full v2 is default-off behind `MANUAL_CHECKOUT_ENABLED`; it is enabled only in the restricted TEST staging configuration.

| Route | Contract |
| --- | --- |
| POST `/v2/admin/receiving-accounts` | Register immutable ID/config revision, enabled state and permitted-use confirmation; optional normalized JPEG QR ≤256 KiB. Disabling the same revision preserves its frozen content. |
| POST `/v2/booth/checkouts` | Local checkout ID, session/event/run/name, format, copies 1–10, integer unitPriceCentavos, method CASH/MANUAL_DIGITAL, mode, receiptPolicy, receiverId, snapshotHash, optional original createdAt. Returns original server identity/status and checkoutURL. |
| GET `/v2/booth/checkouts/{uuid}` | Device-owned original status and matching private receipt proof, no image bytes. |
| POST `/v2/booth/checkouts/{uuid}/facts` | Idempotent original acknowledgment/closure/completion plus bounded physical evidence imports. Session/copy/fingerprint conflicts are rejected. |
| GET `/checkout#c=<uuid>.<capability>` | Lightweight branded page; capability stays in the fragment and scoped Authorization header, never a query parameter. |
| POST `/v2/guest/status` | Read only that checkout's frozen amount, quantity, receiver, policy and submission status. |
| POST `/v2/guest/acknowledgments` | Matching snapshotHash; idempotent claim, never server print authority. Closed/expired acknowledgment returns 409 with retained review evidence. |
| POST `/v2/guest/receipts` | Matching snapshotHash, JPEG/PNG MIME and base64; normalize metadata, enforce 2 MiB/25 MP/10k-side bounds and structural validation before storage. |
| GET `/v2/admin/records` | Account-scoped 100-row cursor pagination using before/id, separate acknowledgment/review/receipt/physical dimensions. |
| GET `/v2/admin/checkouts/{uuid}` | Authorized account-owned original status. |
| POST `/v2/admin/checkouts/{uuid}/reviews` | Stable review ID, outcome, independently confirmed amount where applicable, note; replay mismatch rejected. |
| GET `/v2/admin/receipts/{uuid}` | Authenticated image preview and authorized private folder URL; no public Drive download URL. |
| POST `/v2/admin/retention` | Explicit approved period 1–3650 days; no cleanup trigger. |
| POST `/v2/admin/receipts/{uuid}/trash` | Explicit approval/reason, eligible age and established policy required. Recoverable Trash only; audit, financial association and prior storage proof retained. |

Canonical snapshot hash fields, joined with `\n` and hashed as UTF-8: localCheckoutId, sessionId, eventId or empty, runId or empty, format, decimal copies, decimal unitPriceCentavos, method, receiptPolicy, receiverId or empty, mode. The server generates its UUID and a 256-bit HMAC capability using an independent random nonce and server secret; it stores only the capability digest. Tokens cannot list, preview, administer, claim legacy entitlements or access galleries. Public POST origins are restricted to the checkout origin. Per-address/per-checkout rate limits, body bounds, idempotent identities, no-store headers, no-referrer, CSP and fixed error messages limit abuse and leakage. The bridge verifies a fresh five-minute signed envelope and signed response.

The page shows exact totals, copies, copyable account details, an optional downloadable receiving QR distinctly labeled from the iPad checkout-link QR, saved-image selection, preview, metadata-minimizing 1600-pixel JPEG compression, upload progress, explicit acknowledgment and safe retry/status recovery. API calls and uploads have bounded timeouts. It uses no third-party scripts/fonts, login, install, OCR or customer-entered IDs.

## Private storage and reports

Separate Apps Script project and owner-only Drive root, outside all gallery folders. Hierarchy: Year / Month / Events / stable event ID, or Regular Booth / date. Actual file identity contains server checkout UUID and receipt UUID; names/timestamps alone do not identify money. A private operation journal reserves a Drive-generated file ID before upload. A ScriptLock protects folder/reservation creation. Retries reuse that file ID after an uncertain response and verify MIME, bytes, SHA-256, parent and private ACL before acceptance. Root, folders, journals and images are checked for owner-only permissions; sharing changes fail closed. No gallery manifest/token/download route is involved.

The iPad stores receipt proof only. Authenticated preview bytes remain in memory and are cleared on leaving the detail screen; protected CSV exports omit images, receiving details and tokens and are cleared on leaving the report. Retention starts unset. Manual eligible Trash requires an explicitly established policy and separate confirmation/reason; no automatic destructive process or permanent-delete endpoint exists.

Payment Maintenance, Home, Regular Booth, event setup/review/live summary, guest checkout, Event Reports → Sales, Help & Recovery, System and Monitoring link to the existing V5.1 routes. Local records filter by event, method and verification, open authenticated previews/private Drive folders, append reviews and export CSV. The local journal is this iPad's scope; account-wide server records are available through the paginated admin API. Manual event totals match exact run IDs. Acknowledged and independently confirmed values are overlapping views and are never added together. Existing prepaid, historical provider-verified and signed cash reports retain their original categories. Physical reports and unreviewed receipt claims remain separate from new guest admission.

Migration 0009 only adds manual tables/indexes/triggers. Legacy orders, payment attempts, policy revisions and entitlements are not rewritten. No Payment remains free/prepaid; existing cash-only policies retain their original rules. QR Ph-only/combined policies require an explicit supported replacement for future guests and are never silently reclassified as cash. Historical policies, attempts and authorized entitlements remain readable/recoverable.

## Executed validation

- Native integration simulator build passed; subsequent test builds passed on Xcode 27.2, iOS 26.5 simulator `PocketPixels Gallery Validation`. Stale CoreSimulator tooling was repaired by Xcode tooling without erasing devices. Bundle/signing/project settings were unchanged.
- Focused native batches: 37/37 (manual policies plus event lifecycle), 32/32 (10 manual cases, Regular Booth, prepaid authorization and the two mandated unknown-print/parked-payment relaunch → next guest/event cycles), 4/4 WebKit browser cases. After the final actor-boundary/report-sync separation and cash-policy wording changes, the final 12/12 manual plus mandated recovery cases passed again, including a successful app build. Earlier unchanged Close & Continue and prepaid cases also passed in the initial 61-case batch; its failures exposed timestamp precision and retired-QR fixtures, corrected and revalidated without relaxing the lifecycle assertions.
- New manual cases cover four modes in Regular/Event guest flows, all policies, local no-PIN acknowledgment, frozen copies/receiver, foreign-session rejection, failed disk writes/corrupt-original preservation, relaunch, report non-duplication, legacy decoding/explicit QR replacement, expired claims and print-intent duplicate prevention.
- Consolidated payments Worker subsystem: 234/234 passed. Expanded manual route checks: 15/15 passed after the final atomic acknowledgment/closure change, including delayed offline expiry and concurrent closure/claim retention. Bridge contracts: 5/5, including signature/freshness, 2 MiB nested-envelope bounds, private ACLs and inert/age-gated/idempotent Trash.
- TEST pre-migration SQL export restored in isolation; 0008+0009 preserved all 19 existing tables' rows unchanged, integrity check `ok`, foreign-key check empty. Both migrations then applied to TEST. An additional populated legacy entitlement upgrade test passed. LIVE received no manual schema migration.
- Actual staged Worker → Apps Script → Drive synthetic upload passed. Repeat checkout and upload retained the same identities; authenticated preview matched the image hash. Owner-only root/folder/file permissions and unauthenticated media denial were independently checked. The existing CLI OAuth can read metadata but lacks file-content authority for files created by this separate Apps Script; authenticated bridge preview verified the bytes instead. This is an OAuth scope boundary, not public access.
- Chrome browser integration loaded the real staged page, acknowledged the synthetic original checkout, selected a synthetic PNG, displayed its preview, normalized it to JPEG and received **Receipt stored privately** after actual Drive confirmation. WebKit separately exercised 320/375/430-point layouts, all policies, invalid/offline links, repeat taps and lost upload-response status recovery. [320-point capture](assets/manual-checkout-320.png), [430-point capture](assets/manual-checkout-430.png). No physical Android/iPhone compatibility claim is made.
- The canonical Apps Script source was read back, with the temporary private owner initializer absent from published versions/current source. No actual customer files were changed. Tiny, specifically labeled synthetic images/journals remain private for Phase 3 review; do not broadly delete the root. Retention remains unset.

Raw `.xcresult`, images and logs remain local under TestResults/DerivedData and `/tmp/mtk-phase2-*`. Private source/config snapshots, SQL exports, secret references, exact resource IDs/deployments, browser and signed storage proofs are under `~/.codex/private/manual-payments-phase2/` with directory 0700/files 0600. Do not commit or upload that directory. Hosted GitHub Actions remain subject to the Phase 1 billing lock; local evidence does not claim hosted CI success.

## Deployment ledger and Phase 3 gate

LIVE protective retirement deployed as `e2b3a7da-f9ad-4421-a3ef-846fedac6518`: only the creation guard, existing secrets/D1 and five-minute Cron retained. Health confirms `liveEnabled:true`, `newPaymongoCheckoutsEnabled:false`. Original attempts still replay/reconcile; no provider credentials needed for recovery were revoked. A post-deployment LIVE Cron run completed at 2026-11-24T16:00:44.904Z; the indexed read examined one row. The full new v2 service was not deployed to LIVE. TEST final Worker version and private Apps Script version are recorded in the restricted resource ledger, along with fresh before-mutation SQL backups and source readback evidence.

Phase 3 must:

1. Run the complete candidate release gates once, including affected production/UI/security checks, physical camera/BLE/TCP/paper interruption/relaunch and sustained-event acceptance on Carlo. This phase did not install a newly signed build or perform physical printing.
2. Resolve compatible expired app provisioning/distribution and the outstanding portable-device backup/restore gate from Phase 1. Preserve Keychain/data on any in-place install; no team/bundle migration is authorized by these changes.
3. Configure an actual receiving account permitted for the activity and its authorized QR privately; independently validate readability, cash fallback, required receipts, real iOS/Android browsers and venue network switching. No real receiving account has been configured by this implementation.
4. Provision/review the intended production private service/key/root and account/device/operator scope, validate quotas and test privacy/retry with synthetic data. Do not repurpose the public gallery root or reuse staging credentials casually. Keep retention unset until the owner establishes a reviewed policy; no automatic cleanup.
5. Back up/restore-check LIVE again, apply pending additive migrations through the controlled release process, deploy the reviewed full Worker with manual rollout intentionally enabled, pair the app and verify exact environments/proofs. Default configs leave manual checkout disabled. Preserve the separate PayMongo creation-off flag and legacy reconciliation throughout.
6. Reconcile remaining provider obligations before December 1 using owner-led Dashboard/support access; the notice's API/wallet/payment-method restrictions may limit later legacy verification. D1 app history does not prove payouts/settlement. Review obsolete infrastructure retirement only after unresolved obligations are understood. No actual transfer or financial closure was attempted.
7. Publish a uniquely signed RC only after those gates, record the exact source/binary/profile evidence, and promote only the qualified candidate. General production checkout, v1.0.0 release and hardware/financial certification remain explicitly outside this Phase 2 delivery.
