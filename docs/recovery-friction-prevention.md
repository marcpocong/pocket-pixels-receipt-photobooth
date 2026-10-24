# Preventing historical recovery from blocking operation

Follow-up to Operator Experience V3, October 24, 2026 (Asia/Manila).

The invariant is: a retained receipt outcome is evidence, not unfinished operational work. An unknown outcome stays unknown and keeps copy-level duplicate protection. It does not become a permanent booth lock after the operator has handled the current recovery checkpoint.

## Implementation

- `PrintOutcomeOutbox` exposes separate unfinished-physical-send and unresolved-server-report checks. Its aggregate summary is explicitly for history/accounting, not readiness or admission.
- `SessionSetupSafety` classifies current recovery once. Its issue supplies both the operator instruction and destination, so an interrupted guest opens Help & Recovery rather than an unrelated payments screen.
- Payment connection changes use this same policy and the unacknowledged-session state. A checkpoint already retained and acknowledged no longer permanently blocks changing the connection. Active guests, printer work, current receipt checks, interrupted payments, damaged/unavailable records and outstanding server reports/conflicts retain their protections.
- Detailed Booth Health recognizes Regular Booth as a ready event state. Background reports have their own financial-report row and do not imply printer failure. Genuine conflicts remain visible for financial review.
- `AGENTS.md` records this boundary and requires recovery → acknowledgment → relaunch → next guest/event regression coverage for later recovery changes.

No print transport, receipt raster, camera, server/payment endpoint, entitlement, customer archive, bundle identifier, signing configuration or dependency was changed. No automatic resend or journal-clearing path was added.

## Automated acceptance

`EventLifecycleIntegrationTests.testAcknowledgedUnknownPrintAllowsRelaunchRegularGuestEventStartAndEnd` uses actual durable recovery/journal/acceptance stores and production lifecycle/setup/admission helpers:

1. An unfinished send becomes unknown after simulated relaunch; switching setup is blocked while its receipt check is current.
2. Explicit acknowledgment retains the original photos/checkpoint and is reloaded from persisted preferences.
3. After another relaunch, Regular Booth opens, defaults can be saved, and a different guest can be admitted.
4. A free event starts, admits a guest and ends back in Regular Booth without payment requests.
5. Original unknown print evidence is unchanged and the original batch/copy still cannot be attempted again.
6. A different unknown checkpoint requires a new receipt check.

Additional tests cover local unknown history versus pending/conflicted/acknowledged server reports when changing the payments connection, correct recovery destinations, Regular Booth health, report-only status, and current physical receipt warnings.

Focused validation: **104 passed**, zero failures/skips/runtime warnings. Debug simulator and signed device Release builds passed. Full production-suite results and device-update evidence are recorded in the completion report/PR after the run finishes. All hardware behavior in these tests is simulated; no physical receipt or LIVE payment/event was initiated.

## Real-device follow-up

Use the [iPad acceptance checklist](operator-experience-v3-ipad-checklist.md), especially acknowledgment/relaunch, a different interrupted receipt, and operation with old unknown history. Camera, physical printer/paper behavior and VoiceOver still need owner-supervised acceptance with separate printing/payment authorization.
