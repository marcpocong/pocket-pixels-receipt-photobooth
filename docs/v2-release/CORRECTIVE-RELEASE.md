# Corrective release — 30 October 2026

This record supplements the historical V2 reports. The owner has authorized validated main
integration and an in-place installation on Carlo. The repository is now public. Earlier
private-repository, no-device and draft-PR statements describe the previous run only.

## Starting state

- Clean feature branch: `feat/operations-studio-monitor-v2`.
- Fetched main: `ff4c06d5ecadabcd32001b5e560bc1c96b4b8253`.
- PR #20 head: `89158f244e2a5e76dcfb7f42a89dfde76e5f4e9b`; open.
- Both match the audit reference points; no newer remote commits at initial fetch.
- Xcode 27.1 (27A9275). No changes to project signing, app identity or dependencies.
- GitHub main is unprotected and has no repository rulesets. A normal local merge preserving
  the entire feature history is permitted. Recheck immediately before integration.
- Existing Actions failures have no executed job steps. Do not infer the final run's outcome
  from those historical failures; do not alter billing, protections or workflow coverage.

## Corrective implementation

`EventArtworkImporter.swift` now contains a MainActor editing-session import lifecycle.
Both Photos and Files enter the same lifecycle. Receipt Studio executes the operation through
its structured SwiftUI task, independent of the selected editing section. Save is disabled
while processing and guarded again at commit time. Duplicate imports are rejected. A visible
progress message and Cancel Import remain available across all sections. Header mutations and
Undo/Redo are disabled while importing; other receipt sections remain editable. Successful
imports use the existing replacement/crop pipeline and history binding before enabling Save.
Failures preserve the current logo and display an error. Cancellation/dismissal invalidates the
generation before any late result can touch the draft. New imports cannot be overwritten by an
older completion. Cancellation checks surround background validation/storage. Immutable artwork
is never deleted when cancelling or replacing a draft.

`ReceiptStudioHistory.swift` now performs a three-way all-or-nothing merge against the latest
Setup value. Only edited receipt fields are considered; event metadata, commercial bindings,
guest/gallery settings and unrelated artwork references stay current. Existing header and
typography components merge recursively by persisted property, including nested placement.
If both copies made the same change it is accepted. A differing change to the same property
blocks the entire Save without modifying Setup. Simultaneous creation/reset of optional
geometry is a logical-component conflict because reference coordinates cannot safely be guessed.

Receipt Studio identifies the conflicting properties and offers Keep Editing or an explicit
Reload Latest Receipt, which discards the receipt draft and clears its history. Keep Editing
retains all draft/history values so Undo can remove a conflicting adjustment; every later Save
rechecks the latest parent. There is no silent force overwrite. Switching sections still ends
history groups. The production receipt composer/rasterizer is unchanged by these corrections.

Corrective source/test files:

- `PocketPixelsBooth/EventArtworkImporter.swift`
- `PocketPixelsBooth/EventReceiptDesignPanel.swift`
- `PocketPixelsBooth/ReceiptStudioHistory.swift`
- `PocketPixelsBooth/ReceiptStudioView.swift`
- `PocketPixelsBoothTests/ReceiptStudioV2Tests.swift`

Nine new deterministic regressions cover pending-import Save, completion then Save/reopen,
failed import, cancellation/dismissal with a late provider completion, replacement/removal versus
an older completion, scale versus external logo, local logo versus external spacing/nested
adjustments, all-or-nothing conflicts/Undo/Redo across sections, identical concurrent values,
optional removal and simultaneous geometry initialization. Existing replacement tests verify
crop compatibility, retained historical artwork and non-header settings. Existing native tests
cover Save/reopen, cancellation, layout, section switching, artwork controls and viewport stability.

## Independent V2 review

Reviewed the scheduler, delivery/reconciliation/persistence boundaries, retry deadlines,
monitoring schema/webhook/command delivery and the existing receipt UI/renderer separation.
The serialized scheduler joins same-token work and bounds fresh-guest preference; no in-flight
network operation is preempted. Accepted deliveries use public-read verification; ambiguous
POSTs retain the frozen identity. Public proof and durable verification evidence precede media
cleanup. Retry metadata is additive and retry signals share the recovery owner. Gallery tasks
remain independent of guest printing/admission. No additional serious defect was found in this
review; final test results are recorded below.

The five Telegram commands remain owner-only and read-only. Webhook authentication precedes
bounded parsing; replay/rate records and delivery leases are durable. Replies label heartbeat,
sample and payment-check freshness. Telemetry contains bounded health/queue observations,
without customer/gallery/payment secrets. Migration 0003 only adds tables. No production Worker,
webhook, secret, payment or print operation is part of this release.

## Local validation

- First focused ReceiptStudioV2Tests: **16 passed**, zero failures/skips.
- Final focused/nearby regressions: **115 passed**, zero failures/skips. Includes the final
  import commit gate, receipt editor/artwork/co-brand, gallery scheduler/hardening, telemetry
  and durable acknowledgment/relaunch and scoped recovery coverage.
- Payments Worker: **223 passed**, zero failures/skips.
- Gallery Worker: **39 passed**, zero failures/skips.
- Monitoring Worker: **20 passed**, zero failures/skips; local D1 and mocked Telegram only.
- Apps Script checks and synthetic browser fixture generation: passed.
- Simulator build-for-testing: passed after each meaningful corrective change.
- Complete production suite: **971 passed** (873 XCTest + 98 Swift Testing), zero failures/skips.
- Complete native UI suite: **28 passed**, zero failures/skips, on iOS 27.0.
- Final strengthened cancellation assertion: all **16 ReceiptStudioV2Tests passed** again,
  zero failures/skips, after a successful final build-for-testing. Only the test assertion was
  extended after the full runs; the production debug dylib SHA-256 remained identical. No
  product code changed after the complete suites. The test host was re-signed normally.
- Exported and visually reviewed the new portrait editor screenshot: full left receipt, right
  controls, whole-header direction pad, precision/size, tabs and fit controls are present.
- iOS 27 warns about the existing UIRequiresFullScreen/orientation declaration; it is a future
  platform compatibility warning, with no test failure. Signing/orientation settings are unchanged.
- Monitoring Worker dry-run packaging: passed; no deployment.

Tests use existing iPads: production on iOS 26.5, native UI on iOS 27.0, sharing
`/tmp/mtk-v2-derived`; no new simulator or dependency was created. Commands use the existing
project/scheme and full target selections. Simulator-only ad-hoc signing flags are invocation
arguments, never project edits. Full runs retain all assertions and use 600/900-second test
allowances with bulky automatic diagnostics disabled. Result bundles/logs use the
`/tmp/mtk-corrective-*` prefix. Generated fixture files must be restored if changed by testing.

## Carlo preflight and data safeguards

Carlo is the paired, wired physical iPad Pro 11-inch (4th generation), iPad14,3,
UDID `00008112-000D08463E8BC01E`, iPadOS **26.6.1 (23G83)**, Developer Mode enabled.
Installed bundle: `com.pocketpixels.PocketPixelsBooth`, version 1.0/build 3.
Installed signer: Apple Development: marcpocong@gmail.com (98Q6MAT48P).
Installed application identifier: `PQ26682725.com.pocketpixels.PocketPixelsBooth`;
team `PQ26682725`. These match the unchanged project and available development identity.
Apple MobileDevice read-only queries report 166,319,673,344 bytes AmountDataAvailable
and 439,721,025,536 bytes TotalDataAvailable; adequate headroom for the app update.

A private local Library snapshot was copied with devicectl and verified against the device
listing: **3,976 files, 584,993,817 bytes**, no missing files or size mismatches. SHA-256 manifest
is stored beside it, outside Git, under the user's Application Support/PocketPixelsDeployment.
Documents is empty and was copied separately. Snapshot includes saved events/artwork, recent
sessions, event runs, original gallery verification evidence, payment/recovery state (including retained uncertain
print evidence), print audit,
operator preferences and settings. The durable pending-gallery queue has no files at preflight.
The monitoring endpoint is configured; its value is not published. Keychain contents are not
exported; matching application/team identity preserves their existing access. This is an app-data
snapshot, not a verified whole-iPad/iCloud/Keychain backup. No whole-device backup was found.

Install must use the final main tree and existing signing, without uninstalling or clearing
anything. Compare saved record hashes and container identity after installation, before launch,
then inspect safe startup results. Do not fabricate UI taps, force recovery, create customers,
charge payments, send synthetic live gallery data or initiate a physical print.

## Separate Telegram deployment

V2 commands require a separately authorized backend operation: privately export existing D1;
apply additive migration 0003 after 0001/0002; deploy MonitoringWorker; privately configure a
distinct TELEGRAM_WEBHOOK_SECRET; register the private owner webhook at `/v1/telegram` with
Telegram's matching secret_token. Keep existing credentials on their appropriate services.
Then verify all five commands and owner denial/stale/recovery behavior live. See
`Backend/MonitoringWorker/README.md`. The iPad app remains compatible with the legacy Worker
through schema negotiation. No Gallery or Payments Worker deployment is required by this work.

Integration, final hosted CI, device build/install/launch and physical acceptance are separate
outcomes; the final deployment report records their actual results after execution.
