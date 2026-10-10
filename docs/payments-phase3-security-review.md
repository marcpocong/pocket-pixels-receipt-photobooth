# Payments Phase 3 — security and integrity review

Scope: `Backend/PaymentsWorker` (Worker, migrations 0001–0004) and the iOS payment paths (`PaymentsAPIClient`, `PaymentsDomain`, `OfflinePolicyVerification`, `OfflineCashLedger`, `BoothSessionViewModel` checkout, operator views). Evidence references are to `docs/payments-phase3-test-report.md`.

Trust model: the Worker + D1 is the source of truth. The iPad is semi-trusted (it holds a revocable per-device bearer token and can self-attest cash, which is by design unverified). PayMongo is trusted only through signed webhooks *plus* server-to-server Payment Intent reads. The guest is untrusted.

## 1. Double payment and conflicting payment pathways

| Threat | Control | Evidence |
|---|---|---|
| Cash and QR both authorize one order (sequential or concurrent) | Single guarded lock `UPDATE orders SET payment_method=… WHERE state='AWAITING_PAYMENT' AND payment_method IS NULL` with the attempt insert in the same D1 transaction (keyed by a per-request lock token). Triggers: one attempt per order; attempt method must equal order lock; locked method immutable. | `routes-payment-exclusivity`: QR→cash, cash→QR, 6 rounds × 8 concurrent mixed requests, trigger bypass test; mutation check (removing the guard → 8 failures) |
| Unknown QR outcome silently becomes cash | Provider timeout/5xx during attach → `UNKNOWN_RECONCILIATION`, order stays QR-locked. iPad `CheckoutGuard` hides cash while a QR is unresolved and never falls back to offline cash once any server checkout started. | timeout + real abort tests; Swift `CheckoutGuardTests` |
| Switching method on a possibly paid order | Only a *new* order for the same checkout session, with `supersedesOrderId`, and only when SQL proves the old QR is conclusively unpaid (never issued, or failed/expired and past expiry + 60 s). Partial unique index: one open order per device session. Old order/attempt retained. | supersede tests (early refused, late allowed, cross-session refused, history retained) |
| Late PayMongo success after a new checkout | Paid evidence is applied to the original order; superseded orders become `LATE_PAID_REVIEW` with a `REVIEW_REQUIRED` entitlement (not claimable), reported separately for refund review. No second charge is created. | late-paid test; summary `lateQRPaidReviewCentavos` |
| Duplicate/replayed webhooks, webhook vs Cron races | Webhook ID claimed with `INSERT OR IGNORE` before processing; failed processing marked `FAILED` and reprocessed on retry; paid transition guarded `state<>'PAID_VERIFIED'`; entitlement unique per order; `PAID_VERIFIED` final (trigger). | duplicate (6 concurrent), distinct notifications, Cron+webhook race ×4, retry test |
| Forged/mismatched provider evidence | HMAC over `t.rawBody`, `te`/`li` chosen by endpoint, ±300 s window, hex format check, constant-time compare. Payload must match intent, amount, PHP, livemode and attempt livemode; the Intent is then re-read server-to-server and must also match. Mismatch → `MANUAL_REVIEW`, never authorization. | 7 mismatch cases, signature suite, provider-pending deferral |
| Test payment counted as live revenue | Separate endpoints/secrets; attempt livemode is checked against endpoint; summary splits by livemode. | test-mode revenue test |
| Price shown ≠ price charged | `createOrder` requires `expectedPolicyRevisionId` + `expectedUnitPriceCentavos`; mismatch → `policy_changed` with the current policy; the iPad re-shows the price. Orders snapshot price immutably (trigger). | stale-price and snapshot tests |
| Entitlement reuse | First claim binds session (and must match the order's checkout session); replay idempotent; consumed/under-review refused; binding fields immutable (trigger). | claim tests incl. 4 concurrent sessions |
| Ambiguous print causes extra prints | One batch / one fingerprint per entitlement; each copy outcome recorded once and append-only; conflicting replays → 409; API returns `reprintAuthorized:false`. iPad reports outcomes best-effort and never prints because of a server answer. | print suite incl. concurrent fingerprints |

## 2. Event source of truth and policy replay

- Paid policy exists only on the server. `CommercialEventRunStore.publish` refuses non-prepaid runs; the local editor can only edit Private/Prepaid copies/formats. Server-managed booths resolve `GET /v1/events/active` per session; a paused/ended/ambiguous server answer blocks the session (no local fallback). Only an *unreachable* server falls back, and only to a verified signed offline policy (cash only).
- Operator edits are server drafts (`PATCH` with mandatory `If-Match`); losing writers write nothing (revision insert is conditional on the winner's mutation marker — previously an orphan revision was committed on conflict). Publishing requires the explicit revision **and** its acknowledged price. Revisions are immutable.
- One `ACTIVE` event per account (trigger) so all booths of an account resolve the same policy; multiple active (legacy) → `409 ambiguous_active_event`, fail closed. All operator/booth queries are account-scoped (offline sync was **not** account-scoped in Phase 2; fixed).

## 3. Offline signing

- Ed25519 (WebCrypto in the Worker; CryptoKit `Curve25519.Signing` on iOS 18+). The private key is a Worker secret; the iPad pins public keys (`PAYMENTS_OFFLINE_POLICY_PUBLIC_KEYS`, key IDs for rotation). No pinned key → offline paid cash disabled.
- Signed bytes are transmitted as-is (no re-serialization). Claims: version, key ID, environment, account, device, event, revision, lifecycle, price, max copies, formats, `paymentMethods=["CASH_DECLARED"]`, `maxDeclarations`, `issuedAt`/`notBefore`/`expiresAt` (UTC). Window = `min(4 h default, operator limit, event end)`.
- iPad fails closed on: no/unknown key, bad signature, malformed payload, wrong environment/device/account, non-cash policy, invalid bounds, not-yet-valid, expired, clock rolled back below the trusted floor (max of server times seen and prior declarations), corrupt/inconsistent journal, failed durable write, per-snapshot cap reached, duplicate session.
- Server sync re-checks against its own issued-snapshot record (device/account binding, window, price, copies, format, total, per-snapshot cap, duplicate local ID/sequence, collision with an online checkout for the same session). Rejected records are stored as replay-safe conflicts and shown to the operator; they are never silently dropped.
- **Unavoidable limitation:** a disconnected iPad cannot learn of a pause/revocation. Exposure is bounded by the signed window (≤ 4 h by default, configurable to ≤ 12 h) and `maxDeclarations`; declarations after the server revocation time are accepted (the guest was served) but flagged `DECLARED_AFTER_SERVER_REVOCATION`. Clock-based checks on the iPad are best-effort against a determined device owner; the server-side window and caps are the authoritative bound.
- Offline cash remains guest self-attested and is reported as `CASH_SELF_REPORTED_OFFLINE_SYNCED`, separate from verified QR and from physical counts.

## 4. Credential boundaries

- PayMongo secret/public keys, webhook secrets and the offline signing key live only in Worker secrets; none is in source, the iOS bundle, test fixtures that resemble real keys, or logs. Errors are redacted (`sk_/pk_/whsk_/whsec_`, bearer tokens) and provider error bodies are never echoed to clients (tested).
- Device tokens: 256-bit random, stored in Keychain `AfterFirstUnlockThisDeviceOnly`; D1 stores SHA-256 only; revocation is immediate for online calls. Pairing reads the environment from the server. Failed authentication is rate limited per client address.
- Test fixtures embed only an Ed25519 *public* key, a signed payload and its signature; the throwaway private key was never saved.

## 5. Reporting and exports

Categories stay distinct: `QRPH_VERIFIED_TEST`, `QRPH_VERIFIED_LIVE`, `CASH_SELF_REPORTED` (+ offline-synced), `CASH_LOCAL_UNSYNCED` (device-local only; server reports `null`), `CASH_PHYSICALLY_COUNTED` (append-only, trigger), `VARIANCE`, print outcomes. Refunds, complimentary prints, fees and payouts are explicitly `UNSUPPORTED`; settlement is `NOT_REPORTED`. CSV: formula-prefix guard, control-char stripping, quoted Unicode, deterministic order, 5,000-row pages with completion headers; no QR images, provider IDs, URLs or credentials. Print-utilization over-counting from a join fan-out in Phase 2 is fixed.

## 6. Residual risks (not closed in Phase 3)

1. No provider E2E, deployed Cron, physical iPad/VOZY, or accessibility runtime validation has been performed (BLOCKED on authorization/hardware).
2. iPad print-outcome reporting is best-effort and not durably queued across app termination; the server ledger can miss outcomes (never extra prints).
3. A paid entitlement whose session is lost (app killed after payment, before claim) needs operator handling via the orders drill-down; there is no in-app rebind route.
4. Rate limiting is per-minute D1 counters, adequate for kiosks, not a DDoS control; add Cloudflare WAF rules before production.
5. Miniflare `5.20261006.1-alpha` (the version Wrangler 4.149 uses) is labelled alpha; route tests should be re-run on the next stable Wrangler.
6. `npm audit` reports 3 high advisories in **dev-only** transitive dependencies (`sharp`, `undici` via Wrangler/Miniflare); they are not part of the deployed Worker bundle.
