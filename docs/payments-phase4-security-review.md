# Payments Phase 4 — recovery and print-accounting security review

Scope: `PaymentCheckoutRecovery.swift`, `PrintOutcomeOutbox.swift`, checkout/print changes in `BoothSessionViewModel.swift`, operator recovery UI, Worker `GET /v1/checkouts/:id`, audited recovery claim, migration `0005`.

## Invariants and how they hold

| Invariant | Mechanism | Evidence |
|---|---|---|
| One verified QR payment funds one checkout's paid copies | Unchanged Phase 3 D1 locks; recovery reads by checkout session and claims the **existing** entitlement. Recovery never calls `POST /orders`, `/qrph` or `/cash-declaration`. | route test *crash before the order ID…* (1 intent, 1 order after lookup) |
| No second charge on retry | Checkpoint written durably **before** the first server mutation, keyed by checkout session; the server is asked by session ID, so a lost order ID never leads to a new order. | Swift *checkpointMustBeDurableBeforeAnyServerMutation*; route recovery tests |
| Cash stays unverified | Recovery views carry `UNVERIFIED_SELF_REPORTED`; operator text says *self-reported (unverified)*. | route *supersede history* test; classifier test |
| Unknown QR never becomes cash | Classifier → `paymentPending` (not resumable) for any non-final QR, including when the server is unreachable. | classifier table test |
| Recovery is device- and account-scoped | `GET /v1/checkouts/:id` filters `device_id = principal`; claim still requires the order's checkout session. | route *device- and account-scoped* and *cannot rebind* tests |
| No silent rebinding to another guest | Resume reuses the **original** checkout session ID; server refuses any other session (`entitlement_session_mismatch`); classifier marks an entitlement bound elsewhere `inconsistent`. | route + Swift tests |
| Guest privacy on a public kiosk | Resume is operator-armed (protected operator area + confirmation), single-use, 5-minute expiry; the welcome screen only shows a generic notice; recovered sessions start with fresh photos and a new gallery token; no checkout data, photos or prices appear on guest screens. | Swift *resumeIsOperatorArmedSingleUseAndExpires* |
| Paid quantity immutable | Resume requires `purchasedCopies == checkpoint.copies`; paid retries continue the same batch; outbox refuses a copy index that may have printed and a changed receipt fingerprint; server refuses copy > purchased. | Swift outbox tests; route *no copy beyond the paid quantity* |
| No automatic extra physical print | Outbox intent is durable before bytes; `inFlight` at relaunch → `uncertain`; `uncertain`/`delivered` copies are never begun again; the existing printer recovery lock still blocks sessions until an operator inspects paper. | crash-point tests ×3; Swift mutation check (6 failures when uncertain copies were allowed) |
| No lost known outcome | Final outcomes persisted; reports replay with unchanged idempotency keys; server exact replays are success; completion queued after copy reports. | *replayUsesUnchangedKeys…*; route *print outbox replay* |
| No speculative success | Transport success is `DELIVERED` (paper not sensor-verified) — previously reported as `CONFIRMED`; `UNCERTAIN` is never upgraded (server refuses with 409). | route + Swift tests |
| Terminal states monotonic | Server triggers unchanged (paid final, outcomes append-only — recreated in `0005`); local checkpoint phases never move backwards. | migration 0005 test; Swift phase test |

## Local data

Checkpoint and outbox files (`Application Support/PaymentState/`) contain IDs, prices, copy counts, states and timestamps only — no tokens, keys, QR images, photos, names or gallery tokens (asserted in a test). Files are written with `DurableFileWriter`, excluded from backup and protected `completeUntilFirstUserAuthentication`. Corrupt files are quarantined (kept) and fail closed for paid flows; private/prepaid printing is never blocked by payment journals.

## Residual risks

1. **Operator protection is a hidden long-press, not authentication.** Anyone who knows the gesture can arm a resume for a *paid, never-printed* checkout. Impact is bounded (it continues an already-paid checkout with the same copies; it cannot create value or reveal photos), but for production add Guided Access and an operator PIN.
2. **Checkpoint enrichment after the first write is best-effort.** If later writes fail, recovery still works through the server lookup by session ID; offline cash relies on its own durable ledger.
3. **Outcome write failure after a successful transport** leaves the copy `inFlight`, which becomes `uncertain` at relaunch — conservative (no extra print), but a delivered copy may be reported as uncertain.
4. **Dismissed checkouts** are hidden only on the iPad; the server entitlement stays outstanding (listed by the `outstanding` orders filter). Refund/write-off workflows remain unsupported.
5. **Printer semantics:** neither raw TCP nor BLE reports paper completion, so the system can never prove paper output; operator inspection remains the authority for uncertain copies.
