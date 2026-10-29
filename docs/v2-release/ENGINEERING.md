# Operations, Receipt Studio and Monitoring V2

## Baseline and scope

- Started from clean `main` / `origin/main` at `ff4c06d5ecadabcd32001b5e560bc1c96b4b8253` on 2026-10-29.
- Review branch: `feat/operations-studio-monitor-v2`.
- Read root AGENTS.md, Production Gate workflow, current gallery persistence / delivery tests,
  and recent receipt editor and print recovery changes (`ae5d7e5`, `5775490`, `c7070da`, `bf3d1bb`).
- Xcode 27.1 and iPad simulators are available. No physical iPad is available.
- Baseline simulator build-for-testing passed. Payments Worker: 223 tests passed.
- Baseline monitoring: 8 passed, one failure in supersession test (2 versus 3 messages);
  investigate concurrent heartbeat `waitUntil` delivery and Cron during the monitoring phase.

## Implementation checkpoints

1. Gallery: a continuation-driven serialized scheduler shared by foreground and recovery;
   bounded preference for new guests, persistent retry classification/deadlines, event-driven
   recovery wakeups, truthful Waiting Galleries controls. Retain frozen identities, ambiguity
   reconciliation and public verification before deletion. Keep 90/180-second POST timeouts.
2. Receipt Studio: full receipt by default, top tabs, persistent left preview / right tools,
   explicit fit actions, conventional movement pad and precision, distinct recenter/reset,
   model undo/redo, and explicit staging/save/discard. Preserve the rendering pipeline.
3. Monitoring: additive bounded queue/event telemetry; owner-only read-only Telegram webhook;
   authenticated bounded parsing, durable deduplication/rate limits, truthful stale responses,
   contextual alerts and synthetic integration tests. No live webhook registration.
4. Integration: complete iOS unit/UI suites and backend checks, hardware checklist,
   deployment/rollback instructions and actual result record.

## Safeguards

No changes to signing, bundle identity, deployment target, payment authorization or physical
print recovery. No production Worker deployment, secrets, data modification or iPad install.
No new dependencies. Retained uncertain print evidence is never automatically resent.

## Gallery checkpoint

One process-wide scheduler owns both public reconciliation and POST work. Callers for the
same token join one operation, including after caller cancellation. No in-flight request is
preempted. At most two fresh guest slots pass an eligible recovery slot; recovery is oldest
first. The public reconciliation sweep remains ahead of historical POSTs, preserving the
existing later-ready-gallery recovery fix. Only one recovery pass and one cancellable deadline
exist; queue changes, foreground activation, connectivity restoration and explicit retries
signal that owner. There is no 30-second polling loop.

Retry category, attempt time/count and next deadline are additive optional metadata. Old
queues decode unchanged. Temporary failures use exponential jittered backoff capped at 15
minutes. Retry-After (seconds or HTTP date) wins over backoff, including public-read 429s.
Connectivity restoration never clears authentication/manual-inspection or rate-limit gates.
Explicit operator retry permits a repaired configuration to be checked again. NWPath status
is labelled as path evidence only. Accepted POSTs retry public reads, never another POST;
ambiguous outcomes reconcile the frozen QR before same-token backend-idempotent recovery.
Media is removed only after public verification and durable local verification evidence.

Validation: simulator build-for-testing passed; targeted GallerySchedulerV2Tests,
GalleryDeliveryHardeningTests and GalleryFrontDoorMigrationTests passed in
`/tmp/mtk-v2-gallery-reviewed.xcresult`. Historical test logs also contain a simulator stall
in the 1,000-session isolation test; this is not counted as a passing integrated run.

## Receipt Studio checkpoint

Portrait uses top Header/Footer/Text tabs with a persistent approximately 60% left receipt
and minimum 290-point right controls. Below 680 points the operator explicitly chooses Receipt
or Tools instead of receiving a tiny stacked thumbnail. The default is the complete receipt;
tabs, element selection, ordinary re-rendering and text focus do not request zoom or recenter.
Native pinch/pan, explicit Fit Full / Fit Width and expanded inspection remain available.
Geometry changes recompute fit, preserving relative manual zoom. Selection outlines remain
UIKit layers over the preview, never composed pixels.

Co-brand Whole Header is first-class and selected by default. A conventional 44-point direction
pad uses Fine/Normal/Fast = 1/4/12 printer dots through production travel/bounds functions.
Existing independent size support remains, with unsupported ranges disabled. Recenter changes
position only within valid geometry; Reset Selection restores selected defaults. Whole reset
restores combined header geometry/crop without deleting the imported artwork. Advanced artwork,
composition, footer and typography capabilities remain accessible.

A value-only, 60-entry undo/redo history records actual staged design changes. Continuous
single-field bursts coalesce; section/target changes break groups. Studio owns a local copy:
Save returns it to the existing Setup/Settings draft; Cancel/back abandonment leaves the caller
unchanged. Existing Save Design / Save Defaults still own library persistence and event apply
is unchanged. Print Sample previews the local edited profile, not a stale parent binding.

Simulator UI: all five focused editor flows passed in `/tmp/mtk-v2-studio-ui.xcresult`, including
portrait columns, default whole viewport, pinch/pan, stable tab changes, whole movement,
undo/redo, save/reopen, cancellation and accessibility. Reviewed the portrait screenshot in
`screenshots/receipt-studio-portrait.png`. Initial model run passed all five new V2 tests but
flagged two legacy assertions for whole reset retaining individual scale; those assertions now
verify the intended complete reset against original production frames. An updated model and
integrated run follow. No physical thermal output has been tested.
