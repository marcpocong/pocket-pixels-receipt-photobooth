# Changed source and tests

Baseline `ff4c06d`. Generated browser-test screenshots are restored after validation.

## Gallery delivery

- `PocketPixelsBooth/EventOperationalState.swift`
- `PocketPixelsBooth/EventOperationsView.swift`
- `PocketPixelsBooth/GalleryPendingUploadStore.swift`
- `PocketPixelsBooth/GalleryUploadModels.swift`
- `PocketPixelsBooth/GalleryUploadScheduler.swift`
- `PocketPixelsBooth/GalleryVerificationStore.swift`
- `PocketPixelsBooth/GoogleDriveGalleryUploadService.swift`
- `PocketPixelsBoothTests/GalleryDeliveryHardeningTests.swift`
- `PocketPixelsBoothTests/GallerySchedulerV2Tests.swift`

## Receipt editor

- `PocketPixelsBooth/CoBrandedHeaderControls.swift`
- `PocketPixelsBooth/CoBrandedReceiptHeader.swift`
- `PocketPixelsBooth/EventDesignEditorView.swift`
- `PocketPixelsBooth/EventProfile.swift`
- `PocketPixelsBooth/EventReceiptDesignPanel.swift`
- `PocketPixelsBooth/OperatorZoomableReceiptView.swift`
- `PocketPixelsBooth/RecentSessionsView.swift`
- `PocketPixelsBooth/ReceiptStudioHistory.swift`
- `PocketPixelsBooth/ReceiptStudioView.swift`
- `PocketPixelsBooth/RegularBoothSettingsView.swift`
- `PocketPixelsBoothTests/CoBrandedReceiptTests.swift`
- `PocketPixelsBoothTests/ReceiptStudioV2Tests.swift`
- `PocketPixelsBoothTests/EmojiStickerTests.swift`
- `PocketPixelsBoothTests/OperatorWorkspaceV41GalleryTests.swift`
- `PocketPixelsBoothUITests/EventOperationsUITests.swift`
- `PocketPixelsBoothUITests/HeaderPINRefinementUITests.swift`

## Monitoring

- `Backend/MonitoringWorker/README.md`
- `Backend/MonitoringWorker/migrations/0003_owner_commands.sql`
- `Backend/MonitoringWorker/src/index.js`
- `Backend/MonitoringWorker/test/monitoring.test.js`
- `PocketPixelsBooth/BoothMonitoring.swift`
- `PocketPixelsBoothTests/BoothMonitoringTelemetryTests.swift`

## Release documentation

- `docs/v2-release/ENGINEERING.md`
- `docs/v2-release/REPORT.md`
- `docs/v2-release/VALIDATION.md`
- `docs/v2-release/HARDWARE-ACCEPTANCE.md`
- `docs/v2-release/CHANGED-FILES.md`
- `docs/v2-release/screenshots/receipt-studio-portrait.png`
- `docs/v2-release/results/` (actual xcresult summary JSON)

No changes to project/bundle/signing/deployment settings, payment source, printer transport or raster generation. `EventProfile.swift` changes are preview-only; `CoBrandedReceiptHeader.swift` changes are explicit editor reset/recenter operations.
