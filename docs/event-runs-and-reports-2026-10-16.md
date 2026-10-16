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


## Owner-approved release — October 17, 2026 (Asia/Manila)

The owner explicitly approved Stage 2 installation and all necessary backend deployments. This supersedes the pending approval state above. Both complete Production Gates passed: source `3814dc4792a0a47a730b6967d14468b25329ad0b` ([run 38923451101](https://github.com/marcpocong/pocket-pixels-receipt-photobooth/actions/runs/38923451101)) and handoff `7604324cc887fe82491665548385cf24d5e43ddb` ([run 38924354602](https://github.com/marcpocong/pocket-pixels-receipt-photobooth/actions/runs/38924354602)). No source changes followed the validated candidate.

### Payments reporting deployment

The existing authenticated Cloudflare CLI published the reporting addition to TEST first, then LIVE. Chrome was opened as requested, but its Cloudflare dashboard required sign-in and its health-page navigation was blocked by the browser. No browser login was needed because the CLI already had authorized account access.

| Environment | Previous version | Released version |
|---|---|---|
| TEST | `252f4caa-351e-45d6-8c3f-6e78c916ce3a` | `f4eac4ea-34f6-4ea3-b729-3bad5cacafce` |
| LIVE | `ccdc2798-96e5-46e5-b34c-c113d8534818` | `76afce7c-75b5-4d2e-ac5d-09c69918aea0` |

Remote settings and source snapshots were retained privately under `/tmp/pocket-stage2-cloudflare-before` and `...-after`. Before/after checks confirmed every binding, secret name, plaintext setting, D1 database ID, compatibility date and Cron expression was preserved. The existing LIVE gate was already `true`; the release explicitly preserved it rather than applying the repository's inert `false` default. TEST remains `false`. Deployed source in both environments includes the original checkout ID and reporting capability flag. Public health returned HTTP 200 with the correct environment/activation state; unauthenticated admin listing returned HTTP 401. Authenticated account isolation and paid-unclaimed attribution passed the real Worker/D1 integration tests in CI; no remote financial transaction was created for verification.

There were no D1 migrations, credential rotations, PayMongo changes, gallery Worker releases or Apps Script releases. The only backend code difference from the previous LIVE source is the read-only order-report addition.

### Carlo in-place update

The signed Release candidate was reverified and installed on Carlo `00008112-000D08463E8BC01E`, preserving bundle ID `com.pocketpixels.PocketPixelsBooth`, signing team `PQ26682725`, version 1.0 and build 1. Its executable SHA-256 is `403e285624e33b92cf47c7c7ac2f19549b44af1302e722eabfc7cf518fe9e8ce`. It launched successfully as PID 1427. No uninstall or container reset occurred.

Fresh private safeguards retain about 412 MiB of Application Support and all 18 preference files under `/tmp/pocket-stage2-preinstall-*`. Documents had no children. Before first launch all 3,552 protected files were present at unchanged sizes; all 18 preferences and all four payment-state files were byte-identical. After launch all 58 checkout IDs and all 267 print-outbox IDs remained present; all outbox entries remained delivered. All preferences remained byte-identical and the original unresolved entitlement remained retained for legitimate recovery. No record was cleared to permit this update.

The owner confirmed Welcome, authenticated operator access, Event Operations & Reports/current settings, and Return to Booth passed and Carlo was behaving normally. This is owner-observed physical validation. Repeated interaction stress, the full 75-second Thank You cycle, Wi-Fi interruption and controlled payment/physical print checks remain unperformed. No real payment, physical print or new event run was created by deployment validation.
