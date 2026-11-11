# Operator Workspace V5 — route audit

Baseline: `4f601eada932131f6118c930f4033e975fd9dfc7`; latest main fetched before edits. All routes below remain inside the authenticated operator workspace; existing action-level authorization and destructive confirmations remain authoritative. Debug tools are separate, explicitly initiated destinations.

## Existing visual findings

The five roots share typed restoration but mix default grouped Lists, Forms, custom scroll cards and editor canvases. OperatorPalette already owns the brand colors. Primary navigation is outside the scroll content. Home duplicates tab actions, hides later follow-ups, uses warning colors for normal pending work, and combines connectivity with gallery evidence. Nested pages have inconsistent canvas, row heights, header casing, card padding and semantic colors. Native sheets already preserve cancellation and destructive confirmation behavior. Session lists already defer archive/media reads; retain that architecture.

## Screen and entry-point inventory

Each file entry lists its actual declared surfaces, navigation titles, and links/sheets. Purpose is described by the screen title and route label. Source evidence is retained here so inline destinations are included alongside typed routes.

### OperatorWorkspaceView

| Line | Screen / entry point |
| --- | --- |
| 10 | `struct OperatorFeedbackBanner: View {` |
| 32 | `struct OperatorWorkspaceView: View {` |
| 169 | `struct OperatorEventsView: View {` |
| 290 | `.navigationTitle("Rename Event").navigationBarTitleDisplayMode(.inline)` |
| 347 | `NavigationLink(value: OperatorWorkspaceRoute.liveEvent) { Label("Edit Live Event", systemImage: "square.and.pencil") }` |
| 349 | `NavigationLink(value: OperatorWorkspaceRoute.sessionSetup) { Label("Review Current Setup", systemImage: "checklist") }` |
| 356 | `NavigationLink(value: OperatorWorkspaceRoute.newEvent) { Label("Quick Start", systemImage: "play.circle") }` |
| 357 | `NavigationLink(value: OperatorWorkspaceRoute.customizeEvent) { Label("Customize New Event", systemImage: "paintpalette") }` |
| 358 | `NavigationLink(value: OperatorWorkspaceRoute.previousEvent) { Label("Use Previous Event", systemImage: "doc.on.doc") }` |
| 359 | `NavigationLink(value: OperatorWorkspaceRoute.savedDrafts) {` |
| 367 | `NavigationLink(value: OperatorWorkspaceRoute.savedEvent(event.id)) {` |
| 381 | `NavigationLink("Event History & Earlier Sessions", value: OperatorWorkspaceRoute.eventHistory)` |
| 382 | `NavigationLink("Manage Saved Events & Archived Designs", value: OperatorWorkspaceRoute.eventLibrary)` |
| 418 | `NavigationLink(value: OperatorWorkspaceRoute.branding) { Label("Event Customization", systemImage: "paintpalette") }` |
| 419 | `NavigationLink(value: OperatorWorkspaceRoute.samplePrints) { Label("Preview & Sample Prints", systemImage: "printer.dotmatrix") }` |
| 420 | `NavigationLink(value: OperatorWorkspaceRoute.regularBooth) { Label("Regular Booth Configuration", systemImage: "camera") }` |
| 428 | `.sheet(isPresented: Binding(get: { managingDesignID != nil // managingRunID != nil }, set: {` |
| 464 | `}.navigationTitle(managementTitle).navigationBarTitleDisplayMode(.inline)` |
| 471 | `.sheet(isPresented: Binding(get: { renameDesignID != nil // renameRunID != nil }, set: {` |
| 486 | `.navigationTitle("Events").navigationBarTitleDisplayMode(.inline)` |
| 493 | `struct OperatorSavedEventSetupView: View {` |

### OperatorDashboardView

| Line | Screen / entry point |
| --- | --- |
| 5 | `struct OperatorDashboardView: View {` |
| 54 | `.navigationTitle("Home").toolbar(.hidden, for: .navigationBar)` |
| 95 | `private struct OperatorAttentionCard: View {` |
| 122 | `struct OperatorPrinterSetupView: View {` |
| 125 | `.navigationTitle("Printer Setup")` |
| 130 | `struct OperatorEquipmentView: View {` |
| 144 | `NavigationLink("Printer Setup", value: OperatorWorkspaceRoute.printer)` |
| 147 | `NavigationLink("Fix Printer", value: OperatorWorkspaceRoute.recovery)` |
| 158 | `NavigationLink("Camera Check", value: OperatorWorkspaceRoute.camera)` |
| 163 | `NavigationLink("Payments Connection & Maintenance", value: OperatorWorkspaceRoute.payments)` |
| 170 | `NavigationLink("Gallery Setup", value: OperatorWorkspaceRoute.gallery)` |
| 171 | `NavigationLink("Waiting Galleries (\(operations.pendingUploadCount))", value: OperatorWorkspaceRoute.waitingGalleries)` |
| 174 | `NavigationLink(value: OperatorWorkspaceRoute.storage) {` |
| 177 | `NavigationLink(value: OperatorWorkspaceRoute.monitoring) { Label("Monitoring", systemImage: "antenna.radiowaves.left.and.right") }` |
| 178 | `NavigationLink(value: OperatorWorkspaceRoute.boothCheck) { Label("Check Booth", systemImage: "checkmark.shield") }` |
| 181 | `NavigationLink("Change Passcode") { OperatorPINChangeView() }` |
| 184 | `NavigationLink("Help & Recovery", value: OperatorWorkspaceRoute.recovery)` |
| 185 | `NavigationLink("Print History", value: OperatorWorkspaceRoute.printHistory)` |
| 188 | `NavigationLink(value: OperatorWorkspaceRoute.advanced) { Label("Advanced", systemImage: "gearshape.2") }` |
| 191 | `.navigationTitle("System")` |
| 204 | `private struct EquipmentDestination: View {` |
| 224 | `struct OperatorAdvancedView: View {` |
| 231 | `NavigationLink("Payment Maintenance & Recovery", value: OperatorWorkspaceRoute.payments)` |
| 232 | `NavigationLink("Fix Printer", value: OperatorWorkspaceRoute.recovery)` |
| 236 | `NavigationLink("Recovery", value: OperatorWorkspaceRoute.recovery)` |
| 237 | `NavigationLink("Print History", value: OperatorWorkspaceRoute.printHistory)` |
| 238 | `NavigationLink("Storage", value: OperatorWorkspaceRoute.storage)` |
| 242 | `NavigationLink {` |
| 254 | `NavigationLink("Printer Transport & Diagnostics") { ScrollView { PrinterSetupView(advancedOnly: true).padding() }.navigationTitle("Advanced Printer") }` |
| 270 | `NavigationLink("Gallery Backend Override") {` |
| 280 | `NavigationLink("Endurance / Chaos Harness") { EventEnduranceHarnessView() }` |
| 281 | `NavigationLink("Printer Deep Diagnostics / Explicit Test Print") { PrinterTestView() }` |
| 282 | `NavigationLink("Camera Development Tools") { CameraTestView() }` |
| 283 | `NavigationLink("Gallery Development Tools") { GalleryUploadTestView() }` |
| 284 | `NavigationLink("Booth Development Tools") { BoothSessionView(showsReceiptDebugTools: true) }` |
| 288 | `.navigationTitle("Advanced")` |
| 293 | `private struct GalleryBackendOverrideView: View {` |
| 336 | `.navigationTitle("Gallery Backend")` |
| 355 | `private struct OperatorStorageView: View {` |
| 378 | `.navigationTitle("Storage")` |

### RegularBoothSettingsView

| Line | Screen / entry point |
| --- | --- |
| 3 | `struct RegularBoothSettingsView: View {` |
| 47 | `.fullScreenCover(isPresented: $studioPresented) {` |
| 70 | `NavigationLink("Preview Receipt") {` |
| 72 | `.navigationTitle("Regular Booth Preview")` |
| 77 | `.navigationTitle("Receipt & Footer").navigationBarTitleDisplayMode(.inline)` |
| 110 | `NavigationLink(value: OperatorWorkspaceRoute.regularFooter) {` |
| 126 | `NavigationLink("Device Footer & Gallery Defaults", value: OperatorWorkspaceRoute.branding)` |
| 130 | `}.navigationTitle("Regular Booth Settings")` |

### RecentSessionsView

| Line | Screen / entry point |
| --- | --- |
| 680 | `struct RecentSessionsView: View {` |
| 729 | `.navigationTitle("Sessions").navigationBarTitleDisplayMode(.inline)` |
| 742 | `.sheet(isPresented: $filtersPresented) { filterSheet }` |
| 743 | `.sheet(item: $cleanupRequest, onDismiss: { selectedIDs.formIntersection(Set(viewModel.summaries.map(\.archiveID))) }) { request in SessionCleanupReview(candidates: request.candidates, model: viewModel) }` |
| 980 | `}.navigationTitle("Filter Sessions").navigationBarTitleDisplayMode(.inline)` |
| 987 | `struct RecentSessionRow: View, Equatable {` |
| 1037 | `struct ArchivedSessionDetailView: View {` |
| 1115 | `.navigationTitle(summary.eventName ?? "Archived Session")` |
| 1141 | `.sheet(isPresented: $isReviewingDeletion) { SessionCleanupReview(candidates: [summary], model: rootViewModel) }` |
| 1142 | `.sheet(item: $selectedPhoto) { photo in` |
| 1150 | `}.padding().navigationTitle("Photo \(photo.id + 1)")` |
| 1159 | `.sheet(isPresented: $isShowingFullReceiptPreview) {` |
| 1338 | `NavigationLink {` |
| 1497 | `private struct FullReceiptPreviewSheet: View {` |
| 1516 | `.navigationTitle("Original Receipt")` |

### EventRunReportingView

| Line | Screen / entry point |
| --- | --- |
| 39 | `struct EventRunReportingView: View {` |
| 130 | `NavigationLink("Whole commercial event · all iPads & runs", value: OperatorWorkspaceRoute.eventReport(eventID))` |
| 152 | `.navigationTitle(tab == .history ? "Event History" : tab == .manage ? "Saved Events" : "Reports")` |
| 196 | `.sheet(item: $attributionSelection) { selection in` |
| 288 | `NavigationLink("Open Print History", value: OperatorWorkspaceRoute.printHistory)` |
| 300 | `NavigationLink("Waiting Uploads", value: OperatorWorkspaceRoute.waitingGalleries)` |
| 332 | `NavigationLink {` |
| 355 | `NavigationLink("Earlier & Unassigned Sessions", value: OperatorWorkspaceRoute.eventHistory)` |
| 360 | `NavigationLink("Earlier & Unassigned Sessions", value: OperatorWorkspaceRoute.eventHistory)` |
| 361 | `NavigationLink("All Recent Receipts & Reprints", value: OperatorWorkspaceRoute.recentSessions)` |
| 406 | `NavigationLink("Paid Event Report — all runs and iPads", value: OperatorWorkspaceRoute.eventReport(eventID))` |
| 426 | `NavigationLink("Whole Commercial Event · All iPads & Runs") { PaymentsOperatorView(salesOnly: true) }` |
| 504 | `NavigationLink("Paid Event History & Archive") { PaymentsOperatorView(salesOnly: true, allowsEventMaintenance: true) }` |
| 514 | `NavigationLink(value: OperatorWorkspaceRoute.sessionSetup) {` |
| 548 | `NavigationLink("Event Setup — create or reuse a design", value: OperatorWorkspaceRoute.sessionSetup)` |
| 707 | `private struct LegacyAttributionSheet: View {` |
| 768 | `.navigationTitle(saved == nil ? "Review Earlier Sessions" : "Attribution Saved")` |

### SessionSetupView

| Line | Screen / entry point |
| --- | --- |
| 13 | `struct SessionSetupView: View {` |
| 90 | `.navigationTitle(setup.editingLiveEvent ? "Edit Live Event" : (opensNewEventDraft ? "New Event" : "Edit Event"))` |
| 116 | `.fullScreenCover(isPresented: $receiptStudioPresented) {` |
| 119 | `.sheet(isPresented: $review) { reviewSheet }` |
| 120 | `.sheet(isPresented: $previousEventPicker) {` |
| 127 | `}.navigationTitle("Use Previous Event")` |
| 482 | `struct SetupSummaryRows: View {` |
| 529 | `struct SessionSetupReviewView: View {` |
| 575 | `.navigationTitle(setup.editingLiveEvent ? "Review Live Changes" : "Review Setup").navigationBarTitleDisplayMode(.inline).tint(OperatorPalette.ink)` |
| 583 | `private struct SetupCopyControl: View {` |
| 609 | `private struct SetupCard<Content: View>: View {` |
| 619 | `private struct LabeledField<Content: View>: View {` |
| 630 | `private struct StatusPill: View {` |
| 643 | `private struct PaymentOptionCard: View {` |
| 690 | `private struct CreationRecoveryCard: View {` |

### CurrentEventViews

| Line | Screen / entry point |
| --- | --- |
| 7 | `struct CurrentEventCard: View {` |
| 65 | `.sheet(isPresented: $showsEnd) { EndEventSheet(lifecycle: lifecycle, isPresented: $showsEnd) }` |
| 66 | `.sheet(isPresented: $showsHealth) { ProductionHealthSheet(lifecycle: lifecycle, isPresented: $showsHealth, loadsRemote: loadsRemote) }` |
| 103 | `NavigationLink(value: SessionSetupSafety.recoveryDestination) {` |
| 332 | `struct EndEventSheet: View {` |
| 390 | `.navigationTitle("End Event")` |

### ProductionHealth

| Line | Screen / entry point |
| --- | --- |
| 153 | `struct ProductionHealthSheet: View {` |
| 218 | `.navigationTitle("Booth Health")` |

### EventOperationsView

| Line | Screen / entry point |
| --- | --- |
| 5 | `struct EventPreflightView: View {` |
| 71 | `.navigationTitle("Booth Check")` |
| 117 | `struct OperatorRecoveryView: View {` |
| 145 | `NavigationLink("Open Session Setup", value: OperatorWorkspaceRoute.sessionSetup)` |
| 148 | `NavigationLink("Recent Sessions · View or Reprint") { RecentSessionsView() }` |
| 149 | `NavigationLink("Retained Interrupted Sessions") { RetainedRecoverySessionsView() }` |
| 150 | `NavigationLink("Print History") { OperatorPrintAuditView() }` |
| 151 | `NavigationLink("Payment Recovery", value: OperatorWorkspaceRoute.payments)` |
| 153 | `}.navigationTitle("Help & Recovery")` |
| 156 | `.sheet(isPresented: $showsEndEvent) { EndEventSheet(lifecycle: lifecycle, isPresented: $showsEndEvent) }` |
| 161 | `struct OperatorPrinterControls: View {` |
| 193 | `NavigationLink("Reprint This Receipt / View Session") { InterruptedReceiptView(sessionID: id) }` |
| 198 | `NavigationLink("Recent Sessions / Reprint") { RecentSessionsView() }` |
| 208 | `struct InterruptedReceiptView: View {` |
| 229 | `struct RetainedRecoverySessionsView: View {` |
| 238 | `NavigationLink {` |
| 248 | `}.navigationTitle("Retained Session")` |
| 256 | `}.navigationTitle("Retained Sessions")` |
| 264 | `struct PendingUploadsView: View {` |
| 308 | `NavigationLink("Details / View Session") { RecentSessionsView(initialSearch: upload.sessionID) }` |
| 311 | `}.navigationTitle("Waiting Galleries")` |
| 317 | `struct OperatorPrintAuditView: View {` |
| 334 | `}.navigationTitle("Print History")` |
| 344 | `struct OperatorCameraCheckView: View {` |
| 355 | `}.navigationTitle("Camera Check")` |
| 383 | `struct OperatorCloseContinueButton: View {` |

### OperatorHomeStatusView

| Line | Screen / entry point |
| --- | --- |
| 3 | `struct OperatorBrandingView: View {` |
| 21 | `NavigationLink("Regular Booth Footer, Logo & Branding", value: OperatorWorkspaceRoute.regularBooth)` |
| 23 | `NavigationLink(value: OperatorWorkspaceRoute.sessionSetup) { Label("Session Setup", systemImage: "slider.horizontal.3") }` |
| 26 | `NavigationLink(value: OperatorWorkspaceRoute.receiptDesign) { Label("Event Receipt Design", systemImage: "paintpalette") }` |
| 27 | `NavigationLink(value: OperatorWorkspaceRoute.stickers) { Label("Sticker Studio", systemImage: "face.smiling") }` |
| 28 | `NavigationLink(value: OperatorWorkspaceRoute.samplePrints) { Label("Print Display Samples", systemImage: "printer.dotmatrix") }` |
| 59 | `NavigationLink("Preview Guest Experience") {` |
| 60 | `ScrollView { CustomerExperiencePreviewView(profile: EventProfileStore.load()).padding() }.navigationTitle("Guest Preview")` |
| 69 | `.navigationTitle("Branding & Design").tint(OperatorPalette.ink)` |

### OperatorGallerySettingsView

| Line | Screen / entry point |
| --- | --- |
| 3 | `struct OperatorGallerySettingsView: View {` |
| 58 | `}.navigationTitle("Gallery Setup")` |

### BoothMonitoring

| Line | Screen / entry point |
| --- | --- |
| 302 | `struct BoothMonitoringView: View {` |
| 324 | `}.navigationTitle("Remote Monitoring").onAppear { endpoint=monitor.endpoint }` |

### PaymentsOperatorView

| Line | Screen / entry point |
| --- | --- |
| 4 | `struct PaymentsOperatorView: View {` |
| 78 | `NavigationLink("Open Session Setup", value: OperatorWorkspaceRoute.sessionSetup)` |
| 95 | `if salesOnly { NavigationLink("Operator API Credentials", value: OperatorWorkspaceRoute.payments) }` |
| 97 | `NavigationLink(value: OperatorWorkspaceRoute.eventReport(event.id)) {` |
| 106 | `NavigationLink("Close or Archive \(event.name)", value: OperatorWorkspaceRoute.eventMaintenance(event.id))` |
| 112 | `.navigationTitle(salesOnly ? "Event Sales & Reports" : "Payment Maintenance")` |
| 346 | `struct CheckoutRecoverySection: View {` |
| 519 | `.sheet(isPresented: Binding(get: { managedCheckoutID != nil }, set: { if !$0 { managedCheckoutID = nil } }), onDismiss: {` |
| 529 | `.sheet(item: $cleanupRequest) { request in CheckoutCleanupReview(ids: request.ids, forceLocal: request.forceLocal, recovery: recovery) }` |
| 530 | `.sheet(item: $detailItem) { item in` |
| 537 | `}.navigationTitle("Checkout Details")` |
| 573 | `}.navigationTitle("Manage Checkout").navigationBarTitleDisplayMode(.inline)` |

### ServerEventEditorView

| Line | Screen / entry point |
| --- | --- |
| 6 | `struct ServerEventEditorView: View {` |
| 93 | `.navigationTitle(detail?.event.name ?? "Server Event")` |
| 298 | `NavigationLink("Operator API Credentials", value: OperatorWorkspaceRoute.payments)` |

### CommercialEventSetupView

| Line | Screen / entry point |
| --- | --- |
| 4 | `struct CommercialEventSetupView: View {` |
| 61 | `struct ServerBoothStatusRows: View {` |

### SavedDraftsView

| Line | Screen / entry point |
| --- | --- |
| 3 | `struct SavedDraftsView: View {` |
| 31 | `.navigationTitle("Saved Drafts")` |
| 53 | `NavigationLink("Review", value: OperatorWorkspaceRoute.draftReview(entry.id)).buttonStyle(.borderedProminent)` |
| 76 | `struct SavedDraftChangesView: View {` |
| 92 | `struct SavedDraftReviewView: View {` |
| 128 | `.navigationTitle("Review Draft")` |
| 154 | `NavigationLink("Edit Receipt Design") { SavedDesignDraftEditor(id: id, workspace: workspace, library: library) }.buttonStyle(.bordered)` |
| 160 | `NavigationLink("Review Payment Settings") {` |
| 167 | `NavigationLink("Edit Session Setup") {` |
| 172 | `NavigationLink("Edit Booth Defaults") { RegularBoothSettingsView(workspace: workspace) }.buttonStyle(.borderedProminent)` |
| 174 | `NavigationLink("Edit Included Copies and Formats") {` |
| 178 | `NavigationLink("Continue New Event") {` |
| 212 | `struct SavedDesignDraftEditor: View {` |
| 224 | `NavigationLink("Customize Receipt") { EventDesignEditorView(setup: setup) }.buttonStyle(.borderedProminent)` |
| 234 | `}.navigationTitle("Edit Draft Design")` |

### EventDesignEditorView

| Line | Screen / entry point |
| --- | --- |
| 4 | `struct EventDesignEditorView: View {` |
| 46 | `struct EventGalleryPresentationControls: View {` |
| 65 | `struct EventDesignRouteView: View {` |

### ReceiptStudioView

| Line | Screen / entry point |
| --- | --- |
| 4 | `struct ReceiptStudioView: View {` |
| 92 | `.navigationTitle("Receipt Studio").navigationBarTitleDisplayMode(.inline)` |
| 110 | `NavigationLink("Print Sample") { SamplePrintStudioView(previewProfile: previewProfile) }` |
| 206 | `struct EventPrintedFooterControls: View {` |

### EventHeaderEditorView

| Line | Screen / entry point |
| --- | --- |
| 12 | `struct EventHeaderEditorView: View {` |
| 111 | `.fullScreenCover(isPresented: $isEditorPresented) {` |
| 234 | `private struct ArtworkSourceMenu: View {` |
| 257 | `private struct EventArtworkSummaryCard: View {` |

### EventArtworkEditorView

| Line | Screen / entry point |
| --- | --- |
| 13 | `struct EventArtworkEditorView: View {` |
| 59 | `.navigationTitle("Edit Artwork")` |
| 101 | `NavigationLink {` |
| 106 | `.navigationTitle("Receipt Preview")` |
| 389 | `private struct ArtworkReceiptCanvas: View {` |
| 438 | `private struct EditorCard<Content: View>: View {` |

### EventTypographySectionView

| Line | Screen / entry point |
| --- | --- |
| 10 | `struct EventTypographySection: View {` |
| 112 | `private struct TypographySample: View {` |

### EventReceiptDesignPanel

| Line | Screen / entry point |
| --- | --- |
| 7 | `struct EventReceiptDesignPanel: View {` |
| 38 | `.fullScreenCover(isPresented: $isStudioPresented) {` |
| 203 | `private struct ProminentIf: ViewModifier {` |
| 211 | `private struct LogoThumbnail: View {` |

### SamplePrintStudioView

| Line | Screen / entry point |
| --- | --- |
| 12 | `struct SamplePrintStudioView: View {` |
| 60 | `.navigationTitle("Print Display Samples")` |
| 68 | `.sheet(item: Binding(get: { selectedSlot.map(SlotSelection.init) }, set: { selectedSlot = $0?.index })) { selection in` |
| 318 | `private struct StudioStep<Content: View>: View {` |
| 341 | `struct SampleSlotCard: View {` |
| 401 | `private struct SampleTrayThumbnail: View {` |
| 434 | `struct SamplePhotoChooser: View {` |
| 471 | `.navigationTitle("Choose \(model.slotTitle(slot))")` |

### PrinterSetupView

| Line | Screen / entry point |
| --- | --- |
| 8 | `struct PrinterSetupView: View {` |
| 36 | `NavigationLink("Sample Print Studio") { SamplePrintStudioView() }` |
| 41 | `NavigationLink("Advanced Printer Settings") { ScrollView { PrinterSetupView(advancedOnly: true).padding() }.navigationTitle("Advanced Printer") }` |

### PrinterBluetoothDiagnosticView

| Line | Screen / entry point |
| --- | --- |
| 9 | `struct PrinterBluetoothDiagnosticView: View {` |

### OperatorPINChangeView

| Line | Screen / entry point |
| --- | --- |
| 4 | `struct OperatorPINChangeView: View {` |
| 34 | `.navigationTitle(ownerRecovery ? "Recover Operator Access" : "Change Passcode")` |

### StickerStudioOperatorView

| Line | Screen / entry point |
| --- | --- |
| 5 | `struct StickerStudioOperatorView: View {` |
| 33 | `NavigationLink {` |
| 47 | `NavigationLink {` |
| 53 | `NavigationLink {` |
| 62 | `NavigationLink("Advanced Settings") {` |
| 82 | `.navigationTitle("Advanced Sticker Settings")` |
| 86 | `.navigationTitle("Sticker Studio")` |
| 116 | `struct StickerStudioPreviewView: View {` |
| 151 | `.navigationTitle("Sticker Studio Preview")` |
| 251 | `struct EmojiPrintTestView: View {` |
| 276 | `.navigationTitle("Emoji Print Preview Test")` |

### OperatorStickerLibraryView

| Line | Screen / entry point |
| --- | --- |
| 14 | `struct OperatorStickerLibraryView: View {` |
| 61 | `.navigationTitle("Manage Stickers")` |

### HardwareQualificationView

| Line | Screen / entry point |
| --- | --- |
| 14 | `struct HardwareQualificationView: View {` |
| 41 | `.navigationTitle("Hardware Qualification")` |
| 47 | `.sheet(isPresented: $showingApproval) {` |
| 59 | `.sheet(item: Binding<HardwareQualificationEngine.OperatorPrompt?>(` |
| 65 | `.fullScreenCover(isPresented: Binding(get: { engine.endToEndModel != nil }, set: { _ in })) {` |
| 165 | `NavigationLink("Open Printer Recovery") { OperatorRecoveryView() }` |
| 208 | `NavigationLink {` |
| 242 | `private struct QualificationApprovalSheet: View {` |
| 297 | `.navigationTitle("Confirm Qualification Run")` |
| 310 | `private struct QualificationLiveSection: View {` |
| 350 | `NavigationLink("Open Printer Recovery") { OperatorRecoveryView() }` |
| 413 | `private struct QualificationPromptSheet: View {` |
| 446 | `NavigationLink("Open Printer Recovery") { OperatorRecoveryView() }` |
| 463 | `.navigationTitle(prompt.title)` |
| 472 | `private struct QualificationBoothHost: View {` |
| 508 | `.sheet(item: Binding<HardwareQualificationEngine.OperatorPrompt?>(` |
| 521 | `private struct UnresolvedQualificationPrintSection: View {` |
| 533 | `NavigationLink("Open Printer Recovery") { OperatorRecoveryView() }` |
| 547 | `private struct QualificationReportView: View {` |
| 584 | `.navigationTitle("Run \(record.shortID)")` |
| 621 | `private struct QualificationVerdictBadge: View {` |
| 646 | `private struct QualificationHistoryRow: View {` |
| 662 | `private struct QualificationScenarioRow: View {` |
| 679 | `private struct QualificationCheckRow: View {` |

### SessionCleanupReview

| Line | Screen / entry point |
| --- | --- |
| 9 | `struct SessionCleanupReview: View {` |
| 54 | `.navigationTitle(candidates.count == 1 ? "Delete Session?" : "Delete Sessions?")` |

### CheckoutCleanupReview

| Line | Screen / entry point |
| --- | --- |
| 9 | `struct CheckoutCleanupReview: View {` |
| 66 | `}.navigationTitle("Review Checkout Deletion").navigationBarTitleDisplayMode(.inline)` |

### EventEnduranceHarnessView

| Line | Screen / entry point |
| --- | --- |
| 564 | `struct EventEnduranceHarnessView: View {` |
| 638 | `.navigationTitle("Endurance Harness")` |

### PrinterTestView

| Line | Screen / entry point |
| --- | --- |
| 14 | `struct PrinterTestView: View {` |
| 119 | `.navigationTitle("Made to Keep Printer Test")` |

### CameraTestView

| Line | Screen / entry point |
| --- | --- |
| 13 | `struct CameraTestView: View {` |
| 61 | `.navigationTitle("Made to Keep Camera Test")` |

### GalleryUploadTestView

| Line | Screen / entry point |
| --- | --- |
| 50 | `struct GalleryUploadTestView: View {` |
| 93 | `.navigationTitle("Cloud Test")` |
