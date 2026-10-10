# Payments Phase 4 — audit (before code changes)

## Custody

| Item | Value |
|---|---|
| Remote branch `codex/madetokeep-payments-phase2` at start | `a3707c4499b7092d134f67bcad3593aa56f035e4` (fetched 2026-10-11; equals Phase 3 push) |
| Draft PR #1 | OPEN, draft, base `main` `934a76d350fb3e09b63941c8e6436f85ab9cd43a`, head `a3707c4` |
| Working copy | isolated no-hardlink clone `~/Desktop/PP-phase3/repo` (Phase 3 custody clone; clean at `a3707c4`) |
| Original tree | `/Users/marc/Desktop/PocketPixelsBooth`, HEAD `934a76d`, 120 porcelain entries, 27 staged paths, 0 stashes. Read-only status fingerprint recorded at start (`sha256 b4dec048…6fe33c`) and re-checked at the end. Never written, staged, stashed, reset or cleaned. |
| Exclusions | `node_modules/`, `.wrangler/`, `.dev.vars*`, key/token files, DerivedData, logs, xcresult bundles, customer photos |

## Existing machinery reused (no duplicate stores)

| Need | Existing component | Phase 4 decision |
|---|---|---|
| Atomic durable writes | `DurableFileWriter` (temp + fsync + `F_FULLFSYNC` + rename) | reuse for checkpoint store and print outbox |
| Fail-closed point immediately before bytes | `PrintSpooler.run` → `PrePrintCheckpoint` gate (throwing blocks transport) | append the outbox *in-flight* entry inside the same gate, after the existing recovery snapshot |
| Ambiguous print semantics | `PrintSpooler`: success → audit `completed`; failure with `bytesStarted` → `recoveryRequiredAfterBytes` + recovery lock; no bytes → `failedBeforeBytes` | map 1:1 to outbox states; never invent stronger evidence |
| Paper certainty | `PrinterNetworkService`: "Raw TCP confirms data delivery to the socket, not that paper physically finished printing"; BLE: "Paper completion still requires physical confirmation" | transport success is **DELIVERED (paper unverified)**, not `CONFIRMED`. Phase 3 reported it as `CONFIRMED` — an overclaim fixed here. |
| Crash during print | `AppRecoverySnapshot` stage `printStatusUnknown` → `EventOperationalState.hasUnresolvedPrint` blocks new sessions until protected `confirmPhysicalPrinterRecovery()` | keep; outbox converts in-flight copies to `UNCERTAIN` on relaunch and never resends |
| Interrupted session photos | `AppRecoveryStore` (operator-visible only; never auto-restored to a guest) | keep; payment recovery never restores photos |
| Offline cash proof | `OfflineCashLedger` (per-session record) | reuse as the offline checkpoint proof |
| Operator protection | admin opened by a hidden long-press on the welcome screen (`MadeToKeepWelcomeView.onAdminLongPress`), full-screen operator dashboard. No PIN. | recovery actions live there behind confirmations; limitation documented (not cryptographic) |
| Server lookups | `GET /v1/orders/:id/status` needs an order ID the app may never have received | add one narrow, read-only, device-scoped `GET /v1/checkouts/:checkoutSessionId` |

## Flows (Phase 3 state) and crash points

```text
QR Ph
 guest copies → [C1] POST /v1/orders (Idempotency-Key, checkoutSessionId=sessionIdentifier)
   → [C2] response → POST /orders/:id/qrph → [C3] QR shown → guest pays (test_url in TEST)
   → PayMongo webhook / Cron → PAID_VERIFIED, entitlement AUTHORIZED      (server only)
   → [C4] iPad poll /status sees entitlement → POST /entitlements/:id/claim (session) → IN_SESSION
   → [C5] camera, review, compose → print loop
Cash (online)
 guest copies → "I've Paid" → [C1] POST /orders → POST /cash-declaration (entitlement AUTHORIZED,
   UNVERIFIED) → [C4] claim → camera …
Cash (offline, signed policy)
 → OfflineCashLedger.declare (durable record, local entitlement) → [C4'] camera …
Print, copy k of N
 [P0] recovery snapshot printStatusUnknown (fail-closed) → transport bytes [P1..P2]
   → transport result → audit → [P3] VM: reportPrintOutcome (fire-and-forget HTTP) → next copy
 after N: [P4] complete entitlement (fire-and-forget) → thank you → snapshot cleared
```

| Crash point | Phase 3 behaviour | Gap |
|---|---|---|
| C1/C2 (order may exist, ID unknown) | VM state lost; no local record | order invisible to the iPad; staff must search |
| C3/C4 (paid or pending, not claimed) | entitlement stays `AUTHORIZED` forever on server; nothing on iPad | **stranded paid entitlement** (Phase 3 FAIL) |
| C4' (offline cash declared, camera not started) | ledger record exists, no way to resume | guest paid (self-reported) but cannot be served |
| C5 (claimed, mid-capture) | entitlement `IN_SESSION`; photos in operator-only snapshot | no resume path; no audited resolution |
| P1/P2 (bytes in flight) | recovery lock on relaunch (good); server never told | **lost UNCERTAIN outcome** |
| P3 (outcome known, HTTP lost) | outcome lost | **lost known outcome** (Phase 3 FAIL) |
| P4 (complete lost) | entitlement stays `IN_SESSION` | consumption not recorded |
| Paid retry after a no-bytes failure | loop restarts at copy 1 with a new batch ID | **extra physical copies beyond paid quantity**; server rejects the second batch |

## Decisions

1. **Checkout checkpoint** keyed by `checkoutSessionId`, written durably *before* the first server mutation (fail closed: no request if the write fails). Later enrichments (order/entitlement IDs) are best-effort because the server can always be asked by session ID. No secrets, tokens, QR images, photos or guest personal data.
2. **Recovery is operator-armed.** On launch/foreground the app reconciles unresolved checkpoints with the server (same device). Paid-but-unclaimed or claimed-but-not-printed checkouts appear only in the protected operator area; an operator arms a single-use, 5-minute resume; the next start tap continues the *original* checkout (same session ID, fixed format and copies, fresh photos). No public "restore any order", no rebinding to another session, no new charge.
3. **Print outbox** (durable journal) appended at the spooler gate; outcomes `DELIVERED` / `UNCERTAIN` / `NOT_STARTED`; in-flight at relaunch → `UNCERTAIN`; never resent automatically; reports replayed with unchanged idempotency keys and bounded backoff; conflicts quarantined and visible. `NOT_STARTED` is kept locally but not sent, so a conclusively unprinted copy can be retried without a server conflict. Entitlement completion is an outbox operation too.
4. **Paid retries continue** from the first copy without a delivered/uncertain record, in the same batch and with the same receipt fingerprint; a changed fingerprint blocks printing.
5. Server: migration `0005` adds `DELIVERED` (table rebuild preserving rows and append-only triggers); `GET /v1/checkouts/:id`; claim `recovery` flag is audited; `outstanding` orders filter.
