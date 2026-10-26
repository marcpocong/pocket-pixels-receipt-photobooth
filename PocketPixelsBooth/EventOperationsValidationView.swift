#if DEBUG
import SwiftUI
import Combine

/// Explicit local acceptance mode for a connected iPad. Never constructs ContentView or starts
/// production camera/payment/print workers. Every mutable record belongs to the named fixture.
struct EventOperationsValidationView: View {
    @State private var fixture: EventOperationsValidationFixture?
    @State private var error = ""
    var body: some View {
        Group {
            if let fixture { EventOperationsValidationHome(fixture: fixture) }
            else if !error.isEmpty { Text(error) }
            else { ProgressView("Preparing isolated event validation…") }
        }.environment(\.colorScheme, .light)
            .dynamicTypeSize(ProcessInfo.processInfo.arguments.contains("--fixture-accessibility") ? .accessibility2 : .large).task {
            guard fixture == nil else { return }
            do { fixture = try EventOperationsValidationFixture() } catch { self.error = error.localizedDescription }
        }
    }
}

private struct EventOperationsValidationHome: View {
    @ObservedObject var fixture: EventOperationsValidationFixture
    @ObservedObject var runs: EventRunStore
    @ObservedObject var library: EventDesignLibraryStore
    init(fixture: EventOperationsValidationFixture) { self.fixture = fixture; runs = fixture.runs; library = fixture.library }
    var body: some View {
        NavigationStack {
            List {
                Text("Isolated event validation · no customer data or payment requests")
                NavigationLink("Check Portrait Camera") { PortraitCameraValidationView() }
                NavigationLink("Create Test Event") { SessionSetupView(coordinator: fixture.setup(), opensNewEventDraft: true) }
                if let saved = library.library.events.filter({ $0.name != "Synthetic Paid History" && $0.removedAt == nil }).sorted(by: { $0.updatedAt > $1.updatedAt }).first {
                    NavigationLink("Reopen Saved Test Event") { SessionSetupView(coordinator: fixture.setup(designID: saved.id)) }
                }
                if runs.operational?.status == .active {
                    NavigationLink("Edit Live Event") { SessionSetupView(coordinator: fixture.setup(live: true)) }
                }
                NavigationLink("Manage Test Events") {
                    OperatorEventsView(workspace: fixture.workspace, runs: fixture.runs, library: fixture.library,
                        lifecycle: fixture.lifecycle, creationPending: { _ in false })
                }
                NavigationLink("Manage Test Checkouts") {
                    List { CheckoutRecoverySection(recovery: fixture.recovery, showsArchived: true) }
                        .navigationTitle("Test Checkouts")
                        .task { await fixture.recovery.refresh() }
                }
                Text("Applied caption: " + fixture.profile.receiptDesign.editorialCaption)
                    .accessibilityIdentifier("validation-applied-caption")
                Text("Run ID: " + (runs.currentRunID ?? "None")).accessibilityIdentifier("validation-run-id")
            }.navigationTitle("Event Validation")
        }
    }
}

@MainActor private final class EventOperationsValidationFixture: ObservableObject {
    let root: URL
    let workspace: OperatorWorkspace
    let library: EventDesignLibraryStore
    let runs: EventRunStore
    let acceptance: SessionAcceptanceStore
    let creations: CommercialEventCreationStore
    let recovery: PaymentRecoveryCoordinator
    @Published var profile: EventProfile
    var local: CommercialEventRun
    lazy var lifecycle = EventLifecycleCoordinator(runs: runs, acceptance: acceptance,
        authorized: { true }, blockingReason: { nil }, recoveryReason: { nil }, source: { .localPrepaid },
        loadLocal: { self.local }, saveLocal: { try self.saveLocal($0) },
        appliedContext: { .init(designID: self.library.library.appliedEventID, commercialEventID: nil, serverBinding: nil, name: self.profile.eventName) },
        applyRegularConfiguration: {
            try self.library.recordApplied(eventModeEnabled: false, eventID: nil)
            try self.saveProfile(.pocketPixelsDefault)
        })
    init() throws {
        let args = ProcessInfo.processInfo.arguments
        let id = args.firstIndex(of: "--fixture-id").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } ?? UUID().uuidString
        root = FileManager.default.temporaryDirectory.appendingPathComponent("EventOperationsValidation-" + id.filter { $0.isLetter || $0.isNumber || $0 == "-" })
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        profile = (try? JSONDecoder().decode(EventProfile.self, from: Data(contentsOf: root.appendingPathComponent("profile.json")))) ?? .pocketPixelsDefault
        local = (try? JSONDecoder().decode(CommercialEventRun.self, from: Data(contentsOf: root.appendingPathComponent("local.json")))) ?? .legacy
        workspace = OperatorWorkspace(directory: root, backgroundWrites: true)
        acceptance = SessionAcceptanceStore(directory: root)
        library = EventDesignLibraryStore(directory: root, legacyProfile: { .pocketPixelsDefault }, legacyName: { "" }, operationAuthorized: { true }, operationBlockingReason: { nil })
        runs = EventRunStore(directory: root.appendingPathComponent("runs"), authorized: { true }, blockingReason: { nil })
        creations = CommercialEventCreationStore(directory: root)
        let checkpoints = try CheckoutCheckpointStore(directory: root.appendingPathComponent("checkouts"))
        recovery = PaymentRecoveryCoordinator(checkpointStore: { checkpoints }, reader: { nil }, outboxClient: { nil },
            managementAuthorized: { true }, recoverPrintJournal: {}, inspectManagementDependencies: { _ in .init() })
        if !FileManager.default.fileExists(atPath: root.appendingPathComponent("seeded" ).path) {
            let historical = try library.create(name: "Synthetic Paid History", venue: "Validation only")
            try library.link(designID: historical.id, binding: "test:synthetic", serverEventID: "synthetic-financial-evidence")
            let run = try runs.startNewRun(context: .init(designID: historical.id, commercialEventID: "synthetic-financial-evidence", serverBinding: "test:synthetic", name: historical.name))
            try runs.beginSession(id: "synthetic-historical-session", runID: run.id, format: "solo")
            try runs.transition(id: run.id, to: .completed)
            var checkpoint = CheckoutCheckpoint(id: "SYNTHETIC-CHECKOUT-ONLY", environment: "test", eventID: "synthetic-financial-evidence",
                policyRevisionID: "synthetic-policy", unitPriceCentavos: 2500, copies: 2, format: "solo", method: "QRPH",
                phase: .awaitingProvider, createdAt: Date(), updatedAt: Date())
            checkpoint.locallyClosedAt = Date(); checkpoint.lastServerState = "AWAITING_PAYMENT"
            try checkpoints.begin(checkpoint)
            try Data().write(to: root.appendingPathComponent("seeded"))
        }
    }
    func saveLocal(_ value: CommercialEventRun) throws {
        try DurableFileWriter.write(JSONEncoder().encode(value), to: root.appendingPathComponent("local.json")); local = value
    }
    func saveProfile(_ value: EventProfile) throws {
        try DurableFileWriter.write(JSONEncoder().encode(value), to: root.appendingPathComponent("profile.json")); profile = value
    }
    func setup(live: Bool = false, designID: String? = nil) -> SessionSetupCoordinator {
        SessionSetupCoordinator(editingLiveEvent: live, draftTarget: designID.map { .design($0) }, workspace: workspace, acceptance: acceptance, library: library, eventRuns: runs, creations: creations,
            api: { throw SetupFailure("Payment requests are disabled in isolated device validation.") },
            authorized: { true }, blockingReason: { nil }, loadLocal: { self.local }, saveLocal: { try self.saveLocal($0) },
            source: { .localPrepaid }, saveSource: { _ in }, currentProfile: { self.profile }, applyProfile: { try self.saveProfile($0) }, studioDefaults: { .init() }, stickerSettings: { .default })
    }
}
/// Live camera preview only: no capture, archive, print, gallery, or saved configuration writes.
private struct PortraitCameraValidationView: View {
    @State private var camera = CameraService()
    @State private var status = "Starting camera preview…"
    var body: some View {
        VStack(spacing: 12) {
            CameraPreview(session: camera.session, cameraService: camera)
                .aspectRatio(3.0 / 4.0, contentMode: .fit)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Portrait camera preview")
                .accessibilityIdentifier("validation-camera-preview")
            Text(status).accessibilityIdentifier("validation-camera-status")
        }.padding(24).navigationTitle("Portrait Camera Check")
            .onAppear {
                camera.configureAndStart { result in
                    switch result {
                    case .success: status = "Camera preview ready"
                    case .failure: status = "Camera unavailable on this device"
                    }
                }
            }
            .onDisappear { camera.stopSession() }
    }
}
#endif
