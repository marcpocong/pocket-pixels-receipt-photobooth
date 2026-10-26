# Made to Keep Studios receipt photobooth

[![Production Gate](https://github.com/marcpocong/pocket-pixels-receipt-photobooth/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/marcpocong/pocket-pixels-receipt-photobooth/actions/workflows/ci.yml)

An iPad-only SwiftUI photobooth that captures guest photos, composes branded receipts, prints to an ESC/POS thermal printer over Bluetooth or TCP, and delivers digital galleries. The Xcode project and bundle identifier remain **PocketPixelsBooth** / **`com.pocketpixels.PocketPixelsBooth`**.

Start with [the 27 October development handoff](docs/development-handoff-2026-10-27.md) for the final receipt-printing behavior, sample-preview fix, copy-authorization fix, CI repairs and verification record. [The documentation index](docs/README.md) links the broader architecture and earlier releases.

## Development

- macOS with Xcode; the current CI toolchain supports the project's iOS 18.0 deployment target. Use an iPad simulator or a development-enabled iPad.
- The iPad app uses Apple frameworks. Do not add dependencies or change bundle ID/signing without explicit authorization.
- Build after meaningful changes. [AGENTS.md](AGENTS.md) contains the repository's working rules.
- Payments Worker development uses its pinned npm dependencies; the production gate selects Node.js 22. No cloud deployment is part of an iPad build.

Build the simulator app:

```sh
xcodebuild build -project PocketPixelsBooth.xcodeproj -scheme PocketPixelsBooth \
  -destination 'generic/platform=iOS Simulator'
```

For full tests, select an available iPad with `xcrun simctl list devices available`, then use that device's identifier:

```sh
xcodebuild test -project PocketPixelsBooth.xcodeproj -scheme PocketPixelsBooth \
  -destination 'platform=iOS Simulator,id=<IPAD_SIMULATOR_UDID>' \
  -derivedDataPath DerivedData -parallel-testing-enabled NO \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER=
```

Ad-hoc simulator signing is intentional: disabling signing entirely breaks Keychain-backed authentication tests. Physical iPad builds use the existing project signing configuration.

## Code map

| Area | Entry points |
| --- | --- |
| App and guest session | `PocketPixelsBoothApp`, `BoothSessionView`, `BoothSessionViewModel` |
| Camera | `CameraService`, `CameraPreview` |
| Receipt layout and digital images | `ReceiptComposer`, `MonochromeReceiptRenderer`, `ThermalImageRasterizer` |
| Printer transport and immutable jobs | `PrinterCoordinator`, `PrintJobEnvelope`, `PrintSpooler`, Bluetooth/network services |
| Local settings and event lifecycle | `RegularBoothMode`, `SessionSetupCoordinator`, `EventLifecycleCoordinator` |
| Payment authorization and recovery | `PaymentsDomain`, `PaymentsAPIClient`, `PrintOutcomeOutbox`, checkpoint/recovery stores |
| Gallery and media export | gallery upload services/stores, `GalleryUploadPreparation`, `SessionMediaExport` |
| Server components | `Backend/PaymentsWorker`, `Backend/MonitoringWorker`, `Backend/CloudflareGalleryProxy`, `Backend/GoogleAppsScript` |

Keep these responsibilities separate. Printer history is evidence, not a customer/session operation lock. Operational gates use current recovery obligations and unfinished physical sends; gallery/report follow-up stays separate. Never automatically resend a copy that may have printed.

## Current printer baseline

- Receipts print **footer-first**. Only outgoing print packets trim wholly blank bottom rows; digital previews, gallery images and Photos exports retain their normal upright margins.
- The owner accepts the remaining **16–17 mm physical bottom gap** on the VOZY G80, identified as **`80-VI 80.C-z04-AA`**. This remains a known physical limitation, not a claimed software fix.
- The attempted cut-and-return diagnostic failed: A did not cut; B's ordinary command did. Its controls are retired from the sample screen and its code is retained under `DEBUG` for evidence only. No persistent printer setting was changed.
- [The printer development log](docs/receipt-footer-first-printing.md) records all attempted changes, measurements, test results and limits. Do not reopen experimentation or tighten digital margins as a paper-gap workaround without a new owner request.

## Authorization and sample previews

Regular Booth and private/prepaid events may let guests choose copies up to the session's frozen policy limit. The local prepaid authorization follows that choice before printing starts. Paid quantities, session/event/format ownership, policy revisions and already-started copies cannot be expanded by the selector.

An empty Sample Print Studio prepares a numbered-photo receipt placeholder. Empty slots never make the sample printable; importing photos enables the normal preparation progress indicator. Black & White and Thermal Raster previews retain their digital borders and can be saved independently of the printer.

## Continuous integration and evidence

The [Production Gate](.github/workflows/ci.yml) runs the complete native UI and production test targets on separate macOS runners, each with its own 60-minute budget. The `ios` aggregate requires both to pass. The backend job runs payment, monitoring, gallery and Apps Script tests. No test is skipped to address the former shared-budget timeout.

GitHub Actions retains `.xcresult` bundles and failure evidence as run artifacts. Curated documentation and synthetic screenshots are versioned; raw device inventories, local agent permissions, signing files and Xcode caches are excluded. See [the evidence index](BuildArtifacts/PortraitWorkspace/README.md).
