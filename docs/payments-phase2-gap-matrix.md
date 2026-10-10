# Phase 2 gap matrix

| Original acceptance requirement | Actual current implementation | Proof file/test | Missing behavior | Phase 2 fix | Final status |
|---|---|---|---|---|---|
| Isolated payment backend | Separate Worker/D1; gallery untouched | `Backend/PaymentsWorker/` | None found | Preserved boundary | PASS |
| Server-verified QR unlock | HMAC webhook and Cron converge on canonical transition | `src/index.js`, 66 Worker tests | Provider E2E unavailable | Scheduled reconciliation added | NOT TESTED |
| Cash self-attestation, no operator touch | Guest “I’ve Paid”; unverified provenance | `PaymentCheckoutViews.swift`, `OfflineCashLedger.swift` | Physical UI test unavailable | Preserved | NOT TESTED |
| Format/copies/payment before camera | View-model authorization gate and new screens | `BoothSessionViewModel.swift`, `BoothSessionView.swift` | Full Swift execution blocked | Surgically ported to clean base | NOT TESTED |
| Exact N identical prints | Paid copy fixed; print entry verifies entitlement quantity | `BoothSessionViewModel.swift` | Physical ambiguity/hardware test unavailable | Added non-UI print gate | NOT TESTED |
| Event list/create/edit/lifecycle | Scoped paginated list/get/create/update with version check; operator list/create/lifecycle UI | Worker routes, `PaymentsOperatorView.swift` | Remote policy editor still relies on local detailed editor; archive route absent | Added remote management core | FAIL |
| Reports with provenance | Authenticated summary/orders UI separates QR live/test, declared/counted cash, prints | Worker summary, operator view | Refund/complimentary buckets not modeled | Added scoped aggregation | PASS |
| Cash count and variance | Append-only count revisions and variance | migration 0003, Worker/UI | Pending-local outbox estimate is device-local only | Added reconciliation workflow | PASS |
| Safe CSV | Authenticated event CSV, deterministic quoting/formula guard | `domain.js`, CSV tests | 10k hard cap has no continuation manifest | Added ShareLink flow | PASS |
| Scheduled reconciliation | Bounded Cron, backoff, diagnostics, live gate | `runScheduledReconciliation`, wrangler | No deployed Cron/provider E2E | Implemented locally only | NOT TESTED |
| Test/live segregation | Separate bindings/endpoints/secrets; live Cron empty; live gate false | `wrangler.toml`, Worker | External configuration not performed | Hardened | PASS |
| Offline policy integrity | Durable atomic ledger, expiry/conflict visibility | `OfflineCashLedger.swift`, sync route | No asymmetric signature; disk-full/corruption tests incomplete | Bounded fail-closed expiry | FAIL |
| 60+ backend cases | 66 executed pass | `docs/payments-phase2-test-report.md` | Deep D1 route/race harness incomplete | Added 60 Phase 2 domain cases | PASS |
| Full Swift tests | Source parses | test report | Macro plugin/simulator unavailable | Exact blocker captured | BLOCKED |
| Physical/provider/accessibility validation | Not executed | test report/manual runbook | Credentials/hardware/runtime unavailable | Manual QA defined | BLOCKED |
| No production action | No deploy/migration/payment | git custody and staging docs | Owner actions remain | Live gate documented | PASS |
