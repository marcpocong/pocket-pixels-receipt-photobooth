# Payment transition — implementation specification

> Current implementation and Phase 3 handoff: [Phase 2 delivery](PHASE2.md). The Phase 1 audit/proposal below is historical; the owner's Phase 2 request and implemented local acknowledgment architecture supersede its proposed online-only digital restriction and entitlement rebuild.

Proposed Phase 2 contract, based on `8baadb77c53321c576d4fe160efc66def199b8b8`, 24 November 2026. **No redesign is implemented by this document.** The architecture is deliberately incremental: retain guest/camera/receipt/printer/gallery services and Operator Workspace V5.1; replace the authority for new paid sessions, while preserving legacy evidence/recovery.

## Service boundaries

1. Extend the existing **Payments Worker** with versioned `/v2` routes and a small mobile checkout page. Reuse separate LIVE/TEST D1, established device/operator principals and rate-limit conventions. Existing `/v1` provider recovery remains available to old checkpoints. New manual routes must not call `assertPaymentsEnvironment` or require PayMongo keys.
2. Add new **manual-payment tables** alongside immutable legacy orders/attempts. Extend the common entitlement/print adapter so the existing print journal and copy protection remain authoritative. Avoid rewriting old payment facts or duplicating print engines.
3. Reuse the existing Google account, Apps Script runtime and Drive resumable-upload techniques through a **separate receipt Apps Script project/deployment and private root**. Isolation is justified: the gallery script serves anonymous token-based reads and its manifest/publication paths must never resolve payment receipts. Do not add receipt branches to its `getGalleryImage`, `doGet`, manifests or public folder discovery. No new paid store, R2 mirror or payment gateway is required.
4. Keep the **gallery Worker, source, root, tokens, pending queue and URLs unchanged**. Receipt-upload journals have their own namespace and bounded scheduler; they cannot occupy the gallery's transmission lane or block unrelated guests for post-session review.
5. Native code exposes separate `ManualCheckoutService`, `PaymentReceiptStore/Transport` and `PaymentReviewService` boundaries behind the existing checkout/entitlement interfaces. Printer transport receives an authorized immutable job, never a receiving-account QR, financial receipt image or provider client.

## Facts and data model

Use integer centavos/PHP, server-authoritative arithmetic and existing 1–10 copy bounds. Freeze checkout price, quantity, format, policy, receiving-account revision and device/session ownership at creation. No single `paid: Bool` is authoritative.

| Proposed entity | Required fields and invariants |
| --- | --- |
| `receiving_account_revisions` | `id`, `account_id`, monotonic revision, display name, provider/instructions/account identifier, authorized QR asset reference/hash, owner permitted-use attestation/time, active/disabled state, created actor/time. Immutable revision contents. No real account information in source/config Git. Old checkouts retain their revision. |
| `manual_policy_revisions` | account/device scope, regular/event context, optional stable local run/design IDs, immutable price/max/default copies/formats, methods (`NONE`, `CASH`, `MANUAL_DIGITAL`, combination), receipt policy (`ACK_ONLY`, `OPTIONAL`, `REQUIRED`), receiving revision for digital, revision/hash and activation provenance. Event Mode remains independent from methods. Digital is unavailable until a valid permitted receiving revision and private storage readiness are configured. |
| `manual_checkouts` | UUID, account/environment/device/session, run/context and policy revision/hash, method lock, quantity/unit/total/currency/format, receiving revision, receipt policy, creation/acknowledgment deadlines, lifecycle (`OPEN`, `ACKNOWLEDGED`, `CLOSED`, `EXPIRED`, `REVIEW_ONLY`), closure reason/time, optimistic version, idempotency operation ID/payload hash. Unique current checkout per device/session. CLOSED does not mean refunded or unpaid. |
| `checkout_capabilities` | random 256-bit token hash, checkout ID, explicit guest scopes, environment, issued/expiry/revoked times. AES-GCM encrypted replay material, bound to checkout/environment and a versioned Worker secret, lets the owning booth recover the same unexpired link after a lost creation response; no plaintext token is stored. Keep required decrypt keys until affected capabilities expire. Raw token appears only in the returned QR fragment; never store it in telemetry or operator reports. One token cannot access another checkout or become a booth/operator credential. |
| `payment_acknowledgments` | UUID, checkout ID unique, channel (`KIOSK`, `MOBILE`), actor scope, exact snapshot hash, server acceptance time, client declared time, idempotency key. Immutable guest assertion. Acknowledgment is neither proof of transfer nor independent verification. Concurrent kiosk/mobile requests converge on the same fact. |
| `payment_receipt_uploads` | upload ID, checkout ID, expected MIME/length/hash, operation key, stable reserved Drive file ID, expiry, state (`RESERVED`, `UPLOADING`, `VALIDATING`, `STORED_PRIVATE`, `REJECTED`, `REVIEW_REQUIRED`), committed size/hash/parent/permission proof and accepted time. Separate durable script journal survives lost initialization/finalization responses. A receipt is “accepted” only at STORED_PRIVATE. |
| `payment_reviews` | append-only review ID, checkout ID, operator principal, outcome (`FUNDS_CONFIRMED`, `NOT_FOUND`, `MISMATCH`, `NEEDS_REVIEW`), actual confirmed amount if checked, reviewed time, bounded reason, optional supersedes ID. Record actual independent checking; never infer from screenshot/upload. Review correction appends rather than edits evidence. |
| Common `entitlements` | Preserve existing IDs, device/session/receipt/copy bindings and lifecycle. Add nullable `manual_checkout_id` (unique) and allow exactly one of legacy `order_id` or manual checkout. Add sources `MANUAL_DIGITAL_ACKNOWLEDGED` and `MANUAL_CASH_ACKNOWLEDGED`; legacy sources retain exact raw values. Eligibility is a policy decision, separate from review. |
| Local offline cash journal | Retain current immutable local record ID/sequence, frozen policy/session/copies/amount, authority type and sync/conflict state. Distinguish a new explicit local operator cash policy from a historical server-signed grant. Local authorization and server reporting share one identity; import must not mint another usable entitlement. |
| Existing print evidence | Reuse `PrintOutcomeOutbox`, `print_batches` and append-only copy outcomes. Batch/copy/fingerprint identity does not change when a receipt is uploaded or a review is entered. `DELIVERED`, `UNCERTAIN`, `CONFIRMED`, `FAILED`, `NOT_STARTED` retain their present meaning. |

Index checkout account/device/session and idempotency keys, capability hash/expiry, upload checkout/state, review checkout/time and report account/run/time. Do not poll unindexed histories. Never copy image bytes or private Drive URLs into D1 summary rows, gallery manifests or Telegram payloads.

### Entitlement compatibility is a real migration

Current `orders.payment_method`, `payment_attempts.method` and `entitlements.authorization_source` have CHECK constraints; old triggers require matching provider/cash evidence. Merely adding a Swift enum case or renaming QRPH is unsafe. Proposed migration leaves legacy orders/attempts untouched and rebuilds **only the common entitlement table** as necessary to support the alternative manual foreign key and sources. All dependent triggers/indexes and `print_batches` foreign keys must be preserved. Manual insertion requires an eligible matching acknowledgment and, when required, a stored private receipt. Legacy inserts still require their exact existing evidence. Existing entitlement identity/session immutability and unique receipt/batch rules remain enforced.

Adapt `entitlementRow`, `publicEntitlement`, claim, completion, checkout recovery and report queries to an explicit authority branch; existing inner joins to `orders` must not hide manual rows. Legacy `/v1` wire responses remain compatible. `/v2` returns `authority`, `manualCheckoutId` or `legacyOrderId` explicitly. In Swift, do not use `orderID != nil` as the sole “requires claim” test after adding manual authority (`PaymentsDomain.swift:164` currently does so).

Alternative table copies/rebuild mechanics must be proven in TEST before production. [D1 foreign-key enforcement](https://developers.cloudflare.com/d1/sql-api/foreign-keys/) cannot be disabled with ordinary `PRAGMA foreign_keys=OFF`; defer within the validated migration transaction, preserve children, and check foreign keys and row identities. No `writable_schema`, silent CHECK bypass or blanket trigger removal.

## State transitions and entitlement policy

| Input / policy | Durable outcome | Camera/print authority |
| --- | --- | --- |
| No Payment / prepaid | Existing local free policy/session snapshot | Existing prepaid authorization; no network or payment required. |
| New cash declaration | Guest acknowledgment persisted in local cash journal, with price/copies/policy authority frozen; sync later if offline | Local cash entitlement for this session only. Label guest-reported unless staff independently attests. Preserve existing server-backed/signed legacy behavior for old sessions. |
| Manual digital, ACK_ONLY | Valid kiosk/mobile acknowledgment accepted | Exactly one server entitlement; receipt is not required and verification is pending. |
| Manual digital, OPTIONAL | Same acknowledgment; any submitted receipt follows independent upload lifecycle | Entitlement need not wait for optional receipt. Failed upload is pending/retryable, never described as accepted. |
| Manual digital, REQUIRED | Acknowledgment plus at least one accepted STORED_PRIVATE receipt, in either order | Transactionally issue one entitlement only when both facts exist and original checkout is still eligible. A kiosk acknowledgment cannot bypass the required receipt. |
| Receipt without acknowledgment | Private stored evidence associated with exact checkout | No entitlement. |
| Later FUNDS_CONFIRMED review | Append independent verification | No additional copies, automatic resume or print action. |
| Negative/mismatch review | Append financial follow-up and highlight in reports | No unrelated guest lock, no history rewrite, no automatic resend/refund. Existing physical facts/entitlements remain evidence. |
| Expiry/Close Session & Continue before eligibility | Retain original facts; close guest capability to authorization | Late evidence is review-only. It must never authorize the next guest or silently revive a closed session. |
| Guest closes after eligibility | Park entitlement/checkpoint with existing retained-media path | Original authorized fulfillment remains recoverable through explicit operator handling; no charge again. |

Entitlement creation is an atomic guarded D1 batch with unique checkout ownership; receipt commit and acknowledgment races converge. A transaction failure or lost response requires original-ID lookup. Delayed polling must not regress state or duplicate a claim. Event end stops new acceptance but retains accepted fulfillment and uploads/review for the original checkout.

Public acknowledgment deadline: default **30 minutes** from creation. Optional late evidence capability: default **24 hours** after acknowledgment, separate upload-only scope, with no entitlement creation after closure. An already accepted receipt and financial review remain retained after capability expiry. Make durations explicit configuration with safe bounds and freeze them per checkout. Invalid/missing/stale receiving revisions fail closed for new digital acceptance; old acknowledgments and print rights are not erased. Changing receiving details affects future checkouts only.

Digital checkout requires online service availability in this initial contract. There is no offline manual-digital fallback that silently waives required private storage. Free and explicitly configured cash remain usable offline. Existing signed-offline cash limitations are retained for legacy sessions; implement the new local cash path deliberately, not by weakening the old signature checks.

## API contract

All mutations require a bounded idempotency key and payload hash; exact replay returns the same result, changed payload returns 409. Use integer amounts and server-computed totals. Errors carry safe fixed codes and recovery action; never raw upstream bodies. Authenticated device operations also enforce environment/account/device ownership; operator routes require separate operator scope.

| Endpoint (proposed) | Authority / request | Response / invariant |
| --- | --- | --- |
| `GET /checkout` | Public static mobile shell | No customer data, no third-party scripts/fonts/analytics. QR encodes `/checkout#c=<checkoutId>.<secret>`; fragment is not sent in URL requests. |
| `POST /v2/guest/checkout` | Checkout capability in authorization header | Minimal frozen amount/copies/format/receiving instructions/QR and receipt policy; no order history, private Drive IDs or entitlement claim secret. |
| `POST /v2/booth/checkouts` | Booth principal; session/context/policy revision, format/copies, operation key | Server snapshots validated policy and returns checkout ID, deadlines, exact total and unique mobile link. Digital fails with `receiving_account_unconfigured/disabled` or `receipt_storage_unavailable` where applicable. |
| `GET /v2/booth/checkouts/{id}` | Owning booth | Separate acknowledgment, receipt, verification, entitlement, closure facts and `nextAction`; recover original ID after uncertainty. |
| `POST /v2/guest/acknowledgments` | Capability; checkout version/snapshot hash + operation key | Assertion recorded only for that checkout; no claimed proof of funds. |
| `POST /v2/booth/checkouts/{id}/acknowledgments` | Owning booth + same exact snapshot | Kiosk acknowledgment with identical eligibility checks. Kiosk cannot fake a STORED_PRIVATE receipt. |
| `POST /v2/guest/receipt-uploads` | Receipt capability; checkout ID, MIME/bytes/hash/key | Reserves stable private Drive file and returns upload-scoped resumable URL, expiry and upload ID. Never returns Google OAuth or folder read/list ability. |
| `POST /v2/guest/receipt-uploads/status` | Same scoped capability/upload ID | Durable status/offset instructions; no private read/download. |
| `POST /v2/guest/receipt-uploads/finalize` | Same capability/upload ID/key | Confirms private storage after server validation; returns STORED_PRIVATE only after verified commit. Does not claim actual funds. |
| `POST /v2/booth/checkouts/{id}/close` | Owning booth and existing closure policy | Preserves facts and original entitlement; capability loses authorization scope; no provider cancellation or financial-settlement claim. |
| Existing common claim/print/complete, exposed in `/v2` | Booth principal + server entitlement ID, original session/fingerprint/copy identity | Reuse copy cap, immutable batch and append-only outcomes; mobile credential cannot call these. |
| `POST /v2/booth/cash-imports` | Owning paired device; original local cash IDs/sequences/policy snapshot | Reporting import only for already locally authorized sessions; duplicates converge, inconsistencies conflict. No second capture/print entitlement. |
| `/v2/admin/receiving-accounts` and `/v2/admin/policies` | Operator principal, optimistic version and exact confirmation of configuration | Immutable revisions and future activation. Real receiving QR image stays private/admin-managed and is disclosed only to scoped checkout guests. |
| `POST /v2/admin/checkouts/{id}/reviews` | Operator principal; independent outcome/amount/reason/key | Append review, do not mutate acknowledgment/provider/print facts. |
| `GET /v2/admin/receipts/{id}` | Authorized operator, same account | Authenticated stream/preview with no-store, safe MIME/disposition; no public share URL. |
| `/v2/admin/reports` / CSV | Operator, account/run/environment + bounded cursor | Acknowledged, independently confirmed, unverified, mismatch/review, receipt and fulfillment columns remain distinct; include legacy categories separately. |

Guest mobile code never receives booth/operator credentials. Separate capability verification from current device-token authentication; scope cannot be inferred solely from token shape. Persist only the minimum mobile recovery reference; do not leave raw receipts or long-lived capabilities in browser localStorage. Use a per-guest session with explicit expiry and server status recovery.

## Private receipt lifecycle and security boundary

Initial supported uploads: **JPEG/PNG, at most 10 MiB and 25 megapixels**, at most three receipt versions per checkout, one active upload at a time. Validate declared length, magic/structure/dimensions and checksum server-side; reject SVG/HTML/PDF/remote URLs and malformed images. Permit file selection without a camera capture prompt; do not implement photographing a customer's payment screen. Normalize safe previews and avoid leaking EXIF in operator previews. Never trust filename or browser MIME as evidence.

Metadata remains within the Worker's existing bounded-body discipline; image bytes use direct scoped resumable Drive PUTs. Reuse the *technique*, not gallery credentials, roots, token IDs or journals: reserve ID → persist private journal → initialize upload → client sends bounded chunks → probe acknowledged offset after interruption → finalize. No public Drive permissions are created.

Receipt Apps Script has only a signed server-operation `doPost`; `doGet` supplies no receipt read/list route. Internal helpers end in `_` and are not exposed through `google.script.run`. Because web-app event objects do not reliably expose arbitrary request headers, authenticate **inside a bounded JSON envelope**, not an assumed Authorization header:

```text
{ v: 1, keyId, timestamp, nonce, operationId, payloadB64, signature }
signature = HMAC-SHA256(serverSecret,
  "v1\n" + keyId + "\n" + timestamp + "\n" + nonce + "\n" +
  operationId + "\n" + payloadB64)
```

Worker secret and separate Script Property hold that server-only credential. Validate size/key/version/time (five-minute skew)/constant-time MAC **before** Drive operations. Verify signed responses against operation/payload hashes. Journal operation IDs durably with stable file IDs so a replay/lost response is idempotent; an evictable cache is not the correctness boundary. No credential goes into a URL or mobile response. Preserve safe Google HTTPS redirect/host validation.

Finalization independently checks exact reserved file, parent, no extra/public/domain/group permissions, nontrashed state, MIME/structure, byte count and Drive SHA-256. Root must be owner-only and outside the gallery root, including ancestor/inherited permissions. If ACL/parent/hash validation fails, retain private quarantine evidence and return REVIEW_REQUIRED; never publish or call it accepted. `STORED_PRIVATE` means the image exists privately and its association is durable, not that D1 merely has a filename. Permission and quota checks are release gates; they have not been demonstrated for a new receipt backend yet.

The mobile shell and APIs use HTTPS, no-store/no-referrer, restrictive CSP, no external resources, no wildcard credentialed CORS and no cookie-based ambient operator authority. Check Origin on browser mutations and rate-limit per capability/account/address before heavy work. Starting budgets: 60 guest metadata reads/minute/capability, 12 mutations/minute, 3 upload reservations/checkout, 10 MiB/file and account/day byte limits configured below verified remaining Drive capacity. Idempotent status/retry does not reserve new files. Bound concurrent initialization/finalization and honor Retry-After. Token, image, body, QR and account identifiers must be excluded from logs/traces; enable query redaction before public rollout even though tokens use fragments.

Poll only while the current checkout UI is active: 2 s → 5 s → 15 s backoff, stop at closure/expiry/background, resume by status read. No empty per-guest Cron or global scans. Upload work and optional financial review must not become global operational locks. Telegram reports actionable failure categories/counts without receipt/account/checkout capabilities; ordinary acknowledgments/reviews do not generate success spam.

## Failure and recovery behavior

| Failure | Required behavior |
| --- | --- |
| Lost checkout/ack response or double tap | Lookup original operation/checkout; same token/ack/entitlement identity. Changed amount/copies cannot replay. |
| Network drops mid-upload / phone reload | Persist private upload journal; query Drive acknowledged offset, resend missing bytes only. Expired scoped upload session refreshes the missing asset for the same reserved ID. |
| Drive stored file but D1 finalization response lost | Reinspect same private file/journal and commit association idempotently. No second receipt version or entitlement. |
| Required storage unavailable/full/ACL unsafe | Keep receipt pending/rejected; current checkout cannot authorize. Offer retry or explicit close with preserved evidence. Never quietly switch policy. |
| Optional upload fails after session | Keep upload pending/retryable within scope; already authorized session and unrelated guests continue. Never display accepted until private storage proof exists. |
| Kiosk dies after acknowledgment/claim | Durable local checkpoint plus owning-booth server lookup recover original entitlement; do not create a new purchase. |
| No bytes versus maybe printed | Retain the current outbox distinction and inspection process. A copy that may have printed is never automatically resent, including after restoring to another device. |
| Guest acknowledges after closure/event end | Retain audit/review-only fact when appropriate; no automatic next-session entitlement. Already issued entitlement remains an original fulfillment obligation. |
| Receiving account disabled/revised | Stop new affected digital creation; freeze existing snapshots and preserve accepted obligations. Explicitly review still-open unacknowledged checkouts; do not silently redirect them to a different receiver. |
| Provider keys rotate / retrieval fails | Legacy state remains unknown/review with original IDs. Existing entitlements remain recoverable; no manual acknowledgment upgrade of old QRPH evidence. |
| Corrupt/full local storage | Preserve original bytes, show actionable current recovery issue, block only unsafe current authorization/send. Post-session review/report issues remain separate. |
| Restored device or old backup | Enter nonprinting recovery mode, re-pair safely, compare authoritative state/journals before activation; never infer a missing historical copy was unstarted. |

Retention: no automatic financial-receipt deletion in the first release. Expose a private storage inventory and owner-reviewed retention/export process; stale incomplete uploads remain private and reviewable. Propose a documented duration with the owner before any purge job. Photo/session cleanup must never erase payment evidence.

## Migration and rollout sequence

1. **First, independent gateway-creation flag**: add `PAYMONGO_NEW_CHECKOUTS_ENABLED`, default false, checked before any new method lock/provider mutation. Existing-attempt/status replay, canonical retrieval, webhooks, legacy claims and reports continue. Keep current inactive LIVE events; do not use the combined LIVE flag or key deletion as retirement. Add explicit health fields for new acceptance versus legacy recovery. Remove deployment-script assumptions that “LIVE enabled” means permission for new gateway charges.
2. Preserve the tag/backups. Re-fetch main and fresh ledgers; TEST currently lacks 0008. Test populated migration on an isolated restored/synthetic dataset including legacy provider/cash, in-session entitlements, unknown prints, superseded orders and corrupt local stores. Keep private production dumps out of fixtures/Git.
3. Add tables and the tested common-entitlement migration in TEST. Assert all old IDs/values, child counts, unique rules and triggers survive; compare historical report categories, `integrity_check` and `foreign_key_check`. Add indexes for every new periodic lookup. No live financial row is relabeled or settled.
4. Add versioned native Codable fields with backwards defaults and explicit authority. Retain `QRPH`, `VERIFIED_QRPH`, old checkout/store keys and format aliases in decoders. Migrate saved QR-only/combo policies to **digital unavailable / needs setup**; never reinterpret provider QR as manual digital or autoactivate receiving details. Retain existing event/design/run identity and workspace navigation.
5. Implement locally configured cash and new digital checkout behind explicit policy; test Regular Booth and Event Mode independently. Existing old checkpoints always use legacy endpoints/connection; avoid switching a global payment base URL to strand original reports.
6. Provision the isolated private receipt project/root with the existing owner account; qualify using synthetic images and interruption/ACL-negative tests before activating real receiving details. Keep accepted file IDs and private storage proof out of public responses. No bulk gallery migration.
7. Deploy compatible backend first, then native version in place. Preserve routes, secrets, database bindings, existing public gallery origin and resumable transport. Require synthetic status/ack/private upload/preview checks, report reconciliation and historical gallery checks before enabling digital.
8. Rollback is forward-compatible: disable new manual acceptance, keep new schema and private objects/recovery endpoints, retain old data and use a binary that understands any new journal/authority. Old pre-transition binaries cannot safely decode new entitlement enum cases or resume new receipt uploads; do not promise a blind binary rollback or restore an old financial dump. Preserve pending work until compatible recovery is available.
9. Retire provider Cron/health dependencies only after provider obligations, fulfillment reports, financial exports and an alternative historical access plan are demonstrably resolved. Current absence of pending provider attempts is not proof of payout/refund closure. Do not delete LIVE/TEST D1 or revoke still-needed credentials.

## Reporting semantics

Display **Digital acknowledged**, **Receipt submitted privately**, **Funds independently confirmed**, **Needs review/mismatch**, **Cash guest-reported**, **Cash staff-attested**, **Unsynced cash**, **Historical PayMongo verified LIVE/TEST**, and physical print utilization as separate dimensions. A receipt count cannot substitute for confirmed money; acknowledgment plus verification are overlapping views, never additive revenue. Test totals never enter live gross. Independent confirmed amounts and variances must be visible without silently changing the original checkout price. Exports retain original run/session/authority and timestamps plus review provenance.

Release criteria, focused test obligations and deferred owner decisions are in [HANDOFF.md](HANDOFF.md). This architecture requires no OCR, banking-app automation, new automated gateway, gallery rewrite, paper-gap experiment or major workspace redesign.
