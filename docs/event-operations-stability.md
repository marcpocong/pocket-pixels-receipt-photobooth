# Event operations stability and live editing

Baseline: `origin/main` at `6c44d32` (dual sample previews). Implementation stays on `main`. Bundle ID, signing, dependencies, payment backend, camera and printer transport are unchanged. The unrelated `.claude/` directory is untouched.

## Findings and evidence

Two regression cases failed against the unchanged baseline in `BuildArtifacts/EventOperations/Baseline.xcresult`:

- Three identical workspace updates performed **three synchronous durable writes**, including `F_FULLFSYNC`, on MainActor. The repaired case performs one write. Production workspace drafts now encode and write on an ordered background queue; an explicit save awaits the queue before reporting durability. An injected slow-disk test checks that enqueueing stays responsive, writes run off the main thread, and the latest value survives reconstruction.
- Creating a paid event while refresh owned `busy` saved a local event but **silently skipped payment linking**. The repaired test retains one local event and links exactly once after the shared refresh completes. Concurrent refreshes share their read, duplicate taps share the existing operation, and a reopened setup cannot overlap an in-flight Start.

Receipt composition was already detached, but `EventReceiptComposerPreview.scheduleRender` resumed on MainActor and performed thermal dithering/PNG encoding there. That raster stage is now detached too, with cancellation and generation checks retained. A pixel-data regression checks that its PNG remains identical to the original raster output.

The setup screen also disabled its entire contents and review dismissal for sequential network calls. Paid creation previously verified detail twice and fetched an event list after a successful link. The verified detail is now reused, the extra list request is omitted, and known selections refresh their own settings directly. Read, create, save and lifecycle requests log phase, mutation/read classification and elapsed milliseconds through OSLog's `EventSetup` category; no names, credentials or financial payloads are logged.

These are reproduced code-level causes and contributors. No Instruments trace of the original production incident was captured, and the measurements do not establish a particular production server's latency.

## Resulting behavior

Setup shows Saving Event, Linking Payments, Loading Settings, Activating, Verifying and completion feedback. Each network request has a 15-second deadline in addition to transport timeouts. A timed-out read can be checked again; a timed-out mutation explicitly says that the server may have committed it. Navigation and dismissal stay available. Leaving a screen does not claim to cancel a server mutation.

The creation journal is still durable before sending its original operation ID. An uncertain creation remains unresolved across restart and cannot silently create a second paid event. Recovery checks the original operation before linking. Versioned policy writes and subsequent publication are verified, and ambiguous mutations are never automatically replayed. Critical design, creation-journal, admission and run-start writes finish off MainActor before committing the corresponding state. A transient admission-store lease coordinates Start across reopened screens, and contradictory lifecycle controls wait for that real operation to finish. Admission and guest-idle checks are repeated after asynchronous staged saves.

**Remove Event** sets a reversible, persisted visibility tombstone and hides every run associated with that design from normal management/report selectors. Completed, archived and commercially linked events can be removed without deleting a commercial link. Standalone historical runs can also be removed. No payment request is made by historical removal. Original design/run/session/order IDs, receipt/media journals, financial records, entitlements and server records remain intact. Stale saves, adoption and linking cannot resurrect a removed identity. **Show Removed Events → Restore Removed Event** restores the same configuration and associations without activating it. Individual run restore also stays historical. Archive and restore-from-archive retain their existing separate meanings. Older identity-only permanent-removal references remain history-only; their deleted configuration cannot be reconstructed.

An applied/running event offers **End Event then Remove** in the same confirmation. It uses the existing local-only end transition and fresh operational recovery checks, then removes that exact design. It never ends an unrelated current event. Historical removal does not require scanning unrelated customer archives or clearing commercial records.

**Edit Live Event** is prominent on Current Event and in Events. It opens applied values rather than an unrelated saved draft and presents details, payment/copies/formats, branding, footer and guest screens together. Edits stay local until **Apply to Next Sessions**. **Cancel Changes** restores the pre-editor draft scopes and applied values. Success is visible in a pinned confirmation banner. The active design, commercial event and run IDs remain fixed; statistics, historical journals, captured-session snapshots and purchased entitlements retain their original meaning. Application waits for a guest/print-safe boundary and does not create another occurrence. Cosmetic changes skip payment-policy requests after the initial settings load; policy changes retain the existing versioned save, price acknowledgement, publish and verification mechanism. Stale versions preserve edits and expose refresh/review; partial or uncertain application is not reported as success.

## Verification

Focused validation uses synthetic records and injected services; no full-suite or manual remote CI workflow was initiated. Raw logs, results and screenshots are local under `BuildArtifacts/EventOperations/`.

- Unit coverage spans creation with/without payments, activation, interrupted/slow requests, original-operation recovery, duplicate taps, refresh/start concurrency and busy release; commercial removal/restore and exact media/order attribution; live settings/policy edits, stale versions, unknown publication, draft cancellation and restart; existing guest snapshot isolation, receipt-raster equality and the recent sample-preview behavior.
- Lifecycle regressions include acknowledgment → relaunch → next Regular Booth guest → next event, with uncertain print evidence retained and no automatic resend.
- Native checks exercise the actual menus, removal/restore, storage failure, active-guest protection, End then Remove, creation/activation, live editing and relaunch persistence.

Final observed outcomes, counting each test once across focused runs:

| Scope | Passed | Final observed failures |
| --- | ---: | ---: |
| Simulator unit cases | 163 | 0 |
| Simulator native UI cases | 7 | 0 |
| Carlo native UI cases | 2 | 0 |

The unit classes are CustomerExperience (14), EventLifecycleIntegration (28), EventRunArchiveAndLayout (16), EventSetupAndPaymentMatrix (19), ReceiptPreviewAccuracy (2), SamplePrintStudio (18), SavedDrafts (14), SessionIsolationAndRecovery (14) and SessionSetup (38). The final concurrency run passed 65 cases; the final lifecycle/native historical-removal run passed 28 unit cases plus one UI case. The corrected disk-failure case and draft tests passed in the 51-case final unit run. These are focused, overlapping runs rather than a claim that the complete repository suite ran.

An earlier native test had a restore-label locator failure; a stable accessibility identifier repairs it. A mixed simulator rerun also lost its unit-host bootstrap while an older failed test run was being stopped; the simulator was restarted, and the final unit run passed. Neither infrastructure interruption is counted as acceptance success.

Carlo (`iPad14,3`) was available over the existing paired connection. The signed Debug acceptance build installed in place and both physical native tests passed: **commercial history removal/restore (16.739 s)** and **create → activate → live edit → relaunch, preserving the run ID and caption (29.689 s)**. The reviewed screenshots are in `CarloDelivery.xcresult` / `CarloDeliveryAttachments`. All records in these tests were synthetic and isolated.

The signed **Release** device build also passed. Its signature verified with `codesign --verify --strict`; bundle/signing project settings have no diff. Release was installed over the existing app without uninstalling or deleting application data. The normal production app was then launched without fixture arguments. Real customer camera capture, live-provider transactions and physical paper printing were not exercised.

Main was fetched again before delivery and remained the baseline. Commit/push is direct to `origin/main`, with no feature branch, PR, force push or manual CI dispatch. Local generated build artifacts and unrelated `.claude/` files are excluded from the commit.

## Limits

The Debug-only `--event-operations-validation --fixture-id <id>` entry point uses an explicitly isolated directory, injected local configuration and no payment API. It never constructs production ContentView or starts production camera/payment/print workers. This allows physical-iPad acceptance without changing customer events. It is excluded from Release builds. It proves native screen responsiveness and local operations on the device; it does not establish real-provider payment latency or thermal-paper output. No live transaction, entitlement consumption or physical printer send is part of this validation.
