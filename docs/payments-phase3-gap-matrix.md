# Payments Phase 3 — gap matrix

Status key: **PASS** (implemented and proven by an executed test/command), **FAIL** (known not met), **BLOCKED** (cannot be proven without authorization, credentials or hardware), **NOT TESTED** (implemented, no executed proof). Test names refer to `Backend/PaymentsWorker/test/*` (route tests run in workerd + local D1) and `PocketPixelsBoothTests/*`; see `payments-phase3-test-report.md`.

## Original acceptance gates

| Gate | Status | Proof |
|---|---|---|
| Isolated payment backend (no gallery/Apps Script changes) | PASS | `git diff origin/main` touches no `Backend/CloudflareGalleryProxy` or `Backend/GoogleAppsScript` file |
| Server-verified QR unlock | PASS (local) / BLOCKED (provider) | webhook HMAC + intent re-read tests; PayMongo E2E not run |
| Cash self-attestation, no staff approval, labelled unverified | PASS | cash route returns `UNVERIFIED_SELF_REPORTED`; guest flow unchanged (“I’ve Paid”) |
| Format/copies/payment before camera | PASS (unit) / NOT TESTED (UI) | VM gates camera on entitlement; claim required for server entitlements |
| Exact N identical prints, no paid quantity change | PASS (server) / BLOCKED (hardware) | copy bounds, one receipt per entitlement; VOZY not tested |
| Event list/create/edit/lifecycle | PASS | `routes-events-auth` full lifecycle incl. PAUSED→ENDED, archive |
| Reports with provenance | PASS | `routes-reports` summary categories |
| Cash count and variance | PASS | append-only counts, trigger, variance, provisional |
| Safe CSV | PASS | determinism, no provider/media data, paging headers |
| Scheduled reconciliation | PASS (local) / BLOCKED (deployed) | bounded batch, backoff, settle-after-expiry tests |
| Test/live segregation | PASS | explicit envs, live inert tests, dry-runs |
| Offline policy integrity | PASS (crypto + server) / NOT TESTED (device) | Ed25519 issuance/sync tests; Swift vector + fail-closed tests |
| D1-integrated route tests executed | PASS | 94 route + 5 migration tests, 186 total |
| Full Swift build and tests | PASS with 3 pre-existing failures | 258/261; same 3 fail on `main` |
| Physical/provider/accessibility validation | BLOCKED | needs owner authorization + iPad + VOZY G80 |
| No production action | PASS | no deploy, remote D1, secret, webhook or live call |

## Phase 3 findings

| Finding | Status | Proof / notes |
|---|---|---|
| P0 `declareCash` accepted orders with a QR attempt | PASS | QR→cash 409, no entitlement; trigger rejects second attempt |
| P0 `createQR` lacked order-state/cash guard | PASS | cash→QR 409 with zero provider calls |
| Atomic method lock in SQL (not stale SELECT) | PASS | lock UPDATE + attempt insert in one batch; mutation check |
| Concurrent cash vs QR never both | PASS | 6 rounds × 8 concurrent requests |
| Repeated QR create | PASS | 6 concurrent → 1 intent |
| Unknown QR never becomes cash | PASS | provider timeout + real abort tests; `CheckoutGuard` |
| Method switch only via new checkout after conclusive non-payment, history kept | PASS | supersede tests (early refused, late allowed, cross-session refused) |
| Late paid evidence reconciled to original order | PASS | `LATE_PAID_REVIEW`, review entitlement, separate report line |
| Duplicate webhook / Cron-webhook race / no paid regression | PASS | duplicate ×6, race ×4, `paid_state_is_final` trigger |
| `claimEntitlement` only authorized, unused, session-idempotent | PASS | 4-session race, consumed/review refused |
| `recordPrint` consistency, no misleading success on conflicting replay | PASS | fingerprint/batch/copy conflicts → 409; append-only |
| Cash remains UNVERIFIED / SELF-DECLARED | PASS | attempt `verification`, report categories |
| Stale event price | PASS | `policy_changed` with current policy; iPad re-shows price |
| Simulated provider timeout UNKNOWN | PASS | attach `network` fault and 150 ms abort |
| P0 server/iPad settings unified; detailed editor edits server drafts | PASS (code + API tests) / NOT TESTED (UI runtime) | `ServerEventEditorView`; local editor is prepaid-only (`publish` refuses paid) |
| Explicit publish of exact acknowledged revision | PASS | `acknowledgement_mismatch`, no implicit latest |
| Guest flow uses confirmed server policy; no local paid fallback | PASS (logic) / NOT TESTED (UI) | VM `resolveServerPolicy`; offline only via signed grant |
| CREATE/edit/activate/PAUSE/RESUME/END(from PAUSED)/ARCHIVE + conflict UI | PASS (API) / NOT TESTED (UI) | lifecycle test, trigger; `version_conflict` handling in editor |
| Operator status: draft vs saved vs active, revision, offline validity | NOT TESTED (UI) | implemented in editor/charging screens |
| Checkout snapshots price permanently; entitlements usable after pause/end | PASS | snapshot trigger + test; claim after end |
| Branding/EventProfile/gallery settings untouched | PASS | no changes to `EventProfile*`, gallery files |
| Pesos entry, centavo storage | PASS | `PesoAmountTests`, server rejects non-integers |
| Multi-iPad account/event scoping | PASS | account isolation tests; one ACTIVE per account trigger |
| P0 signed offline policy (Ed25519, pinned public key) | PASS | issuance/verify tests; Node→CryptoKit vector |
| Offline fail-closed (signature, clock, revoked, expired, disk full, partial, duplicate seq, rejected sync) | PASS | Swift journal/verifier tests; server conflict tests |
| Offline revocation limitation documented & bounded | PASS | window ≤ 4 h default, cap, review flag; security review §3 |
| Offline conflicts visible and replay-safe | PASS | conflict table + iPad journal + operator lists |
| P0 Wrangler `--env test` discrepancy | PASS | original dry-run exit 1; new config dry-runs exit 0; Wrangler local migration apply |
| P1 schema upgrade 0001→0004 with data preservation | PASS | `migrations.test.js` |
| P1 auth: invalid/revoked tokens, scopes, isolation, pagination, If-Match | PASS | `routes-events-auth` |
| P1 webhook raw body, `te`/`li`, wrong amount/intent/currency/mode, malformed | PASS | `routes-webhooks-cron` |
| P1 Cron with stubbed provider, bounded, backoff | PASS | batch size 3 test |
| P1 test payment never in LIVE revenue | PASS | test |
| P1 CSV Unicode/formula/no leakage/paging manifest | PASS | domain + report tests |
| P1 errors rate-limited & redacted | PASS | auth-fail throttle test; secret redaction test |
| P1 Xcode failure reproduced & diagnosed | PASS | baseline builds on this host (exit 0); host-specific in Phase 2 |
| P1 Swift tests for policy flow, centavos, exclusivity, signature, corruption, print authorization | PASS | `PaymentsPhase3Tests` (58 payment tests pass) |
| P1 Session retry/recovery after app kill during paid checkout | FAIL | no in-app rebind of an orphaned paid entitlement; operator review only |
| P1 Print outcome reporting durable across app kill | FAIL | best-effort only (never causes extra prints) |
| P1 Layout/VoiceOver/Dynamic Type/orientation runtime inspection | NOT TESTED | launch smoke only |
| P1 Refunds/complimentary/fees/payouts | PASS (marked UNSUPPORTED) | summary `unsupported` block; nothing fabricated |
| P1 Operator order/diagnostic drill-down, unknown QR review, conflicts | PASS (API) / NOT TESTED (UI) | filters + pagination tests |
| Pre-existing Passport/PhotoPass/grid-six flow test failures | FAIL (pre-existing, out of scope) | fail identically on `main` |

## Readiness

- **TEST-ONLY STAGING: READY to begin under separate owner authorization** (local gates pass; staging steps are prepare-only in `payments-phase3-test-staging-runbook.md`). Provider, device and printer gates remain BLOCKED until that staging run.
- **PRODUCTION GO-LIVE: NOT AUTHORIZED.**
