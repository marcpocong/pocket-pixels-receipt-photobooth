# Gallery, Receipt Studio and Telegram Monitor V2 — engineering report

Implementation is on `feat/operations-studio-monitor-v2`, draft [PR #20](https://github.com/marcpocong/pocket-pixels-receipt-photobooth/pull/20).
Production deployment, physical iPad/G80 testing and live Telegram delivery have **not** occurred.
Hosted CI is blocked by the repository's Actions budget; this is not a passing release gate.

## 1. Baseline

Inspected latest fetched `main`, `ff4c06d5ecadabcd32001b5e560bc1c96b4b8253`, root AGENTS.md,
Production Gate, current stores/services/views/tests and recent editor/recovery fixes. Existing
work was already on the isolated review branch at the start of this continuation; it was reviewed
and completed without discarding it. Xcode 27.1 and iPad simulators were available.

## 2. Architectural findings

The 90-second POST timeout is an operation timeout, not a retry interval; it remains, with the
180-second resource timeout. The previous public-read sweep deliberately rescued later-ready
items before slow historical POSTs; that safeguard remains. Backend acceptance and public
availability are separate facts, with independent durable verification evidence.

Receipt Studio already edited Setup drafts and used production composition, but section/target
focus drove viewport changes and the preview was allocated about 43% width. There was no real
editor history or isolated Save/Cancel session. The existing monitoring Worker already owned
heartbeat, independent payment health, incident transitions, supersession and bounded outbound
Telegram sends. It lacked inbound owner commands and aggregated upload telemetry.

## 3. Gallery Upload Engine V2

- One process-wide continuation-driven scheduler serializes public reconciliation and uploads.
  Same-token requests join, including after a caller cancels. Active delivery is never preempted.
- At most two fresh slots pass eligible recovery. A completed-job yield lets sequential durable
  recovery enqueue its next item even while many immediately completed jobs are waiting.
- One recovery owner and one cancellable next deadline replace the 30-second polling loop.
  Foreground activation, queue changes, reconnection and operator requests signal that owner.
- Additive optional retry category/deadline metadata survives relaunch. Temporary failures use
  exponential jittered backoff capped at 15 minutes; Retry-After takes precedence, including on
  public verification reads. Authentication/configuration/inspection failures require attention.
  Rapid reconnection does not override those gates or rate limits.
- Reconciliation GET attempts count toward backoff. Accepted POSTs retry verification only.
  Uncertain outcomes reconcile the frozen public identity before same-token idempotent recovery.
  Local media clears only after public verification and durable verification evidence.
- Waiting Galleries exposes Retry Now, per-gallery retry/details, path-versus-backend truth,
  active phase, attention, last attempt/failure and next retry. Printing and guest reset remain
  independent of cloud delivery.

## 4. Receipt Studio V2

Top Header/Footer/Text tabs sit above persistent left receipt / right tools. Normal portrait
uses approximately 60/40 and touch-sized controls; truly narrow workspaces explicitly choose
Receipt or Tools. The entire receipt opens fitted. Tabs, target selection and ordinary edits
preserve the operator viewport; native pinch/pan, Fit Full, Fit Width and expansion are explicit.
Image-change preservation is scoped to the editor; archived-image viewers retain their existing
reset behavior. Selection is a preview-only layer.

Whole Header is the default co-brand target. The conventional direction pad uses 1/4/12-dot
precision through existing production bounds. Supported size controls remain immediate;
advanced artwork/crop/composition, footer and typography remain accessible. Recenter changes
position, Reset Selection restores selected defaults, and whole reset retains uploaded artwork.

Bounded model undo/redo coalesces continuous single-field edits and groups derived receipt
extras with the edit that enabled them. Studio keeps a local copy until Save. Cancel/back do
not checkpoint abandoned changes. Save merges only edited receipt fields into the latest Setup
value, preserving refreshed commercial bindings, event identity and unrelated guest settings.
Existing Save Design / Save Defaults persistence and explicit event application remain owners.

## 5. Telegram Monitor V2

The existing Worker/D1 now accepts `/status`, `/event`, `/uploads`, `/incidents`, `/help` through
an owner-only private-chat webhook. It verifies a distinct secret before bounded UTF-8 parsing;
validates sender/chat/update/date/commands; uses durable unique update IDs and an atomic ten/minute
limit; and queues bounded leased reply delivery. No printing, payment, event mutation, deletion
or credential commands exist. No Telegram credential is added to the iPad.

Optional bounded telemetry includes sample time, event state, observed guest activity and
aggregated unverified queue/active phase/attention/oldest/activity counts/times. It excludes
customer names, session/gallery/payment identifiers, photos and QR URLs. Missing values stay
unknown. Reports identify generation/heartbeat/sample/backend-check times and stale state.
An accepted upload never becomes availability evidence. Queue read failures become storage
incidents. Old Workers receive the legacy schema through capability negotiation/fallback.

Upload warnings require attention or an active event's ten-minute backlog. Idle offline queueing
alone stays quiet. Existing recovery/deduplication/supersession remain. Telegram retry advice
is honored; at most five attempts remain. Migration 0003 is additive.

## 6. Decisions and limits

No concurrency increase for gallery transmission, new QR strategy, new dependency or paid
service. No changes to bundle/signing/deployment settings, payment architecture, printer
transport, receipt dimensions or raster generation. Editor actions use the existing geometry.
Undo holds value snapshots and artwork references, not bitmap copies. Queue summaries read
metadata; recovery loads one item at a time. Preview work retains the existing cancellable,
generation-checked render debounce.

Telegram sendMessage has no idempotency key: a crash after a remote send but before local
acknowledgment can duplicate an alert/status reply during bounded retries. It cannot operate
the booth. Monitoring cannot prove physical output or continuous background execution.
Physical resource/gesture/weak-network performance still requires acceptance on Carlo.

## 7. Changed files

See [CHANGED-FILES.md](CHANGED-FILES.md). Core source is separated into gallery coordination,
receipt presentation/history and monitoring. No Payment Worker or project configuration changed.
Generated browser-test comparison images are restored rather than included as product changes.

## 8. Tests

New tests cover scheduler preference/fairness, coalesced retry/reconnect, persisted failure and
rate-limit gates, offline reconciliation, verification-only recovery, portrait layout, stable
viewport, movement/bounds, recenter/reset/artwork, undo/redo and non-destructive receipt commit.
Existing receipt/raster, guest isolation and recovery checks remain. Native UI checks cover
portrait columns, whole preview, gestures, target movement, tabs, undo/redo, save/reopen, cancel
and accessibility. Monitoring tests use real local D1 and mocked outbound services.

Full-suite review also found and corrected an overly broad viewport policy and asynchronous
fixture ordering/isolation. Test coverage/thresholds were not suppressed or weakened.

## 9. Commands and outcomes

See [VALIDATION.md](VALIDATION.md) for actual commands, result bundle paths, passing counts,
initial failures and final full-suite results. The report distinguishes complete suites from
focused reruns and synthetic tests from hardware/live verification.

## 10. Hosted CI

[Production Gate run 40894983896](https://github.com/marcpocong/pocket-pixels-receipt-photobooth/actions/runs/40894983896)
failed before any job steps ran. GitHub's annotation: “The job was not started because an
Actions budget is preventing further use.” No budget or check was changed to bypass this.
Hosted CI must run successfully after account capacity is restored before release approval.

## 11. Commits / review

- `675028a`: audit and safeguards checkpoint.
- `9ab10d9`: durable gallery scheduler, retries and operator controls.
- `dec100d`: preview-first Receipt Studio and staged undo/redo.
- `3e32da5`: secure read-only Telegram monitoring and additive migration.
- `2a2f6a4`: caption/derived-extras undo transaction.
- `d20cdfa`: sequential recovery fairness and reconciliation backoff.
- `aaf8790`: viewport scope, queue fixture isolation and snapshot/banner ordering.
- `237161f`: merge receipt edits without replacing refreshed Setup records.

Further final validation/save-safety documentation commits are listed in the branch history.
PR remains draft; no merge, production deploy, secret update or physical install was performed.

## 12. Outstanding items

Hosted Actions budget and physical/live acceptance remain external release gates. Any remaining
local validation failures are recorded explicitly in VALIDATION.md. Do not treat this document
or simulator results as approval to deploy or proof of hardware behavior.

## 13. Physical validation

[HARDWARE-ACCEPTANCE.md](HARDWARE-ACCEPTANCE.md) contains the pending portrait/gestures/thermal
comparison, weak Wi-Fi/hotspot, restart/background/next-guest, original QR and owner-only
Telegram/stale-state checks. Every item is pending physical or live verification.

## 14. Deployment and rollback

Privately export D1, apply additive migrations in order, then deploy the reviewed Monitoring
Worker and separately configure/register the private owner webhook. Worker-first rollout
allows negotiated V2 telemetry; legacy heartbeat fallback supports code rollback. No Gallery
or Payments Worker deployment is needed. Keep the PR draft until release gates are resolved.

Rollback app/Worker code while preserving all customer/session/print/payment/artwork/queue
records and additive tables. Never restore an old data snapshot over newer evidence or clear
uncertain work. Disable the webhook privately if returning to a Worker without inbound commands.
Older apps ignore optional queue retry metadata and retain their old scheduling policy, so
supervise any rollback with pending rate-limited/attention work.
