# Event operations and reporting — Stage 2

Stage 1 installed source: `00c482725ef5a0531bf50287125e6b82b1a65c99`. Carlo's owner confirmed normal operation after its in-place update. Its complete Production Gate passed: https://github.com/marcpocong/pocket-pixels-receipt-photobooth/actions/runs/38878974354 . Installation evidence is recorded separately in `live-event-guest-payment-hotfix-2026-10-16.md`.

**Stage 2 is source-only and must not be installed during the event without separate owner approval. No backend release has been performed. The read-only Payments Worker reporting addition below needs independent approval.**

## Operating model

- A reusable saved design, a local event occurrence, and the server commercial event have separate identities. `EventRunsV1/runs.json` retains occurrence history; one small protected JSON file per exact session retains its run, format, observed copy outcomes, completion, original order identities and verified gallery delivery. No photographs, gallery tokens, QR URLs or credentials are copied into the reporting journal.
- A setup's first admission creates its run. The same setup resumes the same active occurrence across launches. A deliberately confirmed Start New Event Run creates a new UUID and preserves previous history. Changed setup identities are never matched by name. Unsafe context changes, resets and lifecycle actions are blocked by financial/print recovery and active-guest guards.
- Pause and End close the existing durable admission barrier before changing run status; write failure leaves admission paused. Resume goes through the existing reviewed Session Setup flow and published payment policy. Starting a fresh statistics run retains the admission state and commercial prices; it does not authorize payment or override a paused server event.
- New archives carry optional exact run/design identities. Existing archives are not rewritten or assigned by event name. Existing paid recoveries use their saved session association if one exists; legacy recoveries remain unassigned.
- Completion is idempotent per session after a successful original print batch. Copy results are keyed by batch/copy, and startup/report reconciliation can recover completion and outcomes from exact durable print-outbox evidence after interruption. It never adopts an unassigned historical session. Transport delivery is distinguished from sensor-verified paper output. Archive reprint requests remain separate from original copy outcomes.
- Gallery reporting observes only successful verification of the original public URL. Queue ordering, retry ownership, persistence, identities, timeouts and success criteria are unchanged. Unknown/failed deliveries cannot become verified statistics.

## Operator screens and financial provenance

The operator dashboard opens Event Operations & Reports: current setup/admission/printer, Session Setup, confirmed run operations, persistent statistics, exact run payment evidence, saved designs, history and archive actions. Advanced pairing and credentials remain separate.

Commercial financial reports explicitly cover all runs/iPads for that server event. Per-run financial totals use fully paginated server orders matched to the original checkout session ID, exact saved order IDs or claimed session IDs, with duplicate rows removed. Held/replaced/late-review orders are excluded from verified collections. LIVE QR Ph, TEST QR Ph, attendant-confirmed cash, unverified guest cash, unresolved payments and local unsynced cash are separated. Unmatched or legacy orders remain in the commercial report rather than being guessed into a run. Physical cash reconciliation is commercial-event-wide, not a fabricated allocation between runs.

Summary, authorization, order and conflict failures are visible. Unavailable totals are not displayed as zero. Missing older response fields are labeled not reported. Local offline-cash evidence is loaded before the network request, so a server outage cannot turn saved cash into zero. Current delivered-print counts are decoded and displayed separately from legacy confirmed counts. New offline cash records retain their policy environment; legacy records without it remain visible as unassigned and keep reconciliation provisional. Cash counts remain append-only and require readable local pending-cash evidence.

Event listing follows every cursor and detects repeated cursors. Order filters reject stale responses and deduplicate loaded rows. CSV export follows every page and strips repeated headers; missing/repeated continuation or a safety bound fails the export instead of offering an incomplete file. Operational run CSV is separate from the complete commercial financial CSV.

## Archive and cleanup

- Completed runs can be archived and included in history without removing sessions, financial records, receipts or galleries.
- Commercial End/Archive still uses the existing authenticated, account-scoped, version-checked backend operations. No destructive paid-event deletion was added.
- Saved designs can be archived and restored. Archived designs disappear from ordinary setup selection. Applied, commercially linked, run-linked or archive-linked designs cannot be deleted. Ambiguous legacy references and unreadable history block deletion. A confirmed deletion removes only an unused design entry; artwork and customer records remain retained.

## Independent Payments Worker release

`GET /v1/admin/events/:id/orders` now includes the existing `orders.checkout_session_id` field and a `checkoutSessionIdentityIncluded` capability flag. This repairs attribution of paid-but-unclaimed and pending orders after an interrupted response. Authorization, account scope, pagination, financial state transitions, provider requests and database schema are unchanged. Route tests verify unclaimed paid identity and denial to booth-only and other-account credentials.

Exact run financial totals require this capability; an older Worker produces an explicit unavailable/update-required state instead of a misleading zero. Commercial-event reports, local run statistics, offline-cash evidence and existing payment/camera/print behavior remain usable with the existing backend. Both TEST and LIVE configuration packages passed `wrangler deploy --dry-run`; no deployment occurred. Deploying this small Worker addition requires separate approval. It has not been deployed to test or production infrastructure by this task.

## Compatibility and rollback

Archive run/design IDs, design archive timestamps and offline-cash environment are optional additive fields; older files keep decoding and are not bulk rewritten. No database migration, schema removal, gallery token change or checkpoint reset is involved. New reporting files are independent of payment and print journals. Unreadable run history is retained and blocks replacement; write failures do not advance the saved manifest.

Rollback to Stage 1 preserves the existing payment/printing/gallery formats and leaves the new reporting directory untouched. Older versions do not display run reports or hide archived designs, and older metadata writers may omit the additive archive fields; the separate session journal retains exact associations. Pause guest admission before a rollback and review setup afterward. No rollback step removes customer data.

## Validation and release boundary

Focused persistence, financial membership, CSV, archive compatibility/cleanup, operational recovery, gallery and setup tests passed during implementation. Synthetic portrait and landscape reports were rendered and visually inspected. Payments Worker (208), Gallery Worker (29), and Apps Script checks passed; the gallery backend is unchanged. Earlier full local iOS regressions passed (562 and 564 tests). The final expanded suite passed all 567 cases (478 XCTest and 89 Swift Testing), with zero failures and `TEST SUCCEEDED`. The complete clean run rebuilt the final fixture and finished in about 7.5 minutes; its text log is `/tmp/pocket-stage2-verified-production-gate.log`. A prior final run completed with two assertions in the same 100-session qualification test failing because the Mac exhausted disk space while saving synthetic diagnostic archives. Generated build artifacts were cleared and the complete suite was restarted, without changing those assertions. The signed Stage 2 Release build succeeded and passed strict code-signature verification; bundle ID, team, version and build number are unchanged.

Stage 2 source is `3814dc4792a0a47a730b6967d14468b25329ad0b`. Remote Production Gate: https://github.com/marcpocong/pocket-pixels-receipt-photobooth/actions/runs/38923451101 . At handoff the backend job passed and the iOS job was still running. Local equivalent checks passed, but remote success must still be confirmed before installation.

Stage 2 has not been installed or physically exercised on Carlo. Its release still needs a successful remote Production Gate and separate owner approval, followed by physical operator workflow validation. No real payment or physical print was created by this work.
