# Prepare Event V5.1 — release report

November 13, 2026, Asia/Manila. Baseline `b818da6`, fetched `origin/main` before implementation and again before delivery. The release is identified by the commit containing this report.

## Delivered

A read-only saved-event preparation hub with explicit saved/staged provenance, local policy summaries, existing receipt and guest previews without export or print controls, contextual receipt editing, printer/Booth Check/gallery tools, and persistent Continue to Event Setup. The saved-design row retains independent Prepare and Edit actions. Stable design IDs and library-owned payment bindings remain authoritative. Archived, removed, missing and unreadable designs have explicit recovery destinations.

Setup waits for the requested design before presenting its editor. Active-event edits reuse live editing. The receipt shortcut waits for the existing setup refresh before opening Receipt Studio. Review & Start and existing live-edit review/apply behavior remain owned by `SessionSetupView` / `SessionSetupCoordinator`. Archived designs keep their existing editing pathway; setup retains its existing start restriction. A library write failure shows a warning and leaves readable designs accessible for retry. No lifecycle, admission, recovery, printer, renderer or backend service was changed. No dependencies or signing settings were added or changed. See the [reuse map](README.md).

## Validation

| Execution | Outcome |
| --- | --- |
| Initial operator/setup/draft/recovery regression focus | 119 passed; `TEST SUCCEEDED` |
| Additional lifecycle/session-isolation focus | 51 unit tests passed; its initial UI run exposed identifier inheritance |
| Preparation, setup and draft regression focus after read/write handling | 71 unit tests passed |
| Final source: preparation and archived-start focus | 10 unit tests passed |
| Final source: preparation UI journeys | 3 passed; combined command `TEST SUCCEEDED` |
| Additional keyboard-focus check | 1 passed; `TEST SUCCEEDED` |
| Debug builds and signed Release build | Passed |
| Strict signature verification | Passed; profile covers Carlo |

Intermediate UI failures exposed an inherited identifier and competing saved-row NavigationLinks. A later keyboard-surface hittability expectation was unreliable in the headless simulator, even after disconnecting its hardware keyboard; the stable test checks keyboard presence and reachable field/Done Editing controls, and records the visual limitation below. Navigation failures were corrected with scoped identifiers and independent typed navigation actions; final entry, direct Edit, tool Back, receipt editor, Review Setup and relaunch journeys passed. Nine focused preparation unit tests cover identity, staged policies, environment bindings, current-event isolation, tombstones, unreadable original files, byte-preserving rendering and workspace restoration. Existing recovery regressions passed without changing their assertions or operational policies. Counts describe separate runs and include repeats, not unique total coverage. A full-suite run is not claimed. [Machine-readable results](validation-results.json) retain intermediate failures.

[Eight curated screenshots](screenshots/README.md) document portrait and larger-text behavior. Keyboard presence, field/Done Editing hittability and dismissal were exercised; the screenshot host omitted the keyboard surface, so docked/floating visual acceptance remains a device check. Existing Xcode SDK-version/orientation warnings were observed. No physical print or real payment transaction occurred.

## Signing and Carlo

Bundle ID `com.pocketpixels.PocketPixelsBooth`, team `PQ26682725`, and iPad portrait orientation are preserved. The profile expires **November 18, 2026 at 7:28:56 PM Manila time**. [Signing evidence](signing-summary.json) includes the exact validated binary hash. The signed app is retained locally at `BuildArtifacts/PrepareEventV51/PocketPixelsBooth.app` (excluded from Git).

Carlo became paired during validation, but iOS denied container access because it remained locked (`CoreDeviceError 10003`, `RemotePairingError 1016`). Installation is pending unlock. No uninstall, reset, device-data write or installation was performed. Data-retention or device-launch verification is therefore not claimed for this release. Physical VOZY G80 and live payment verification remain separate.
