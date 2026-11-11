import SwiftUI
import UIKit

/// Reads the existing state owners. No lifecycle, admission, payment or transport policy lives here.
struct OperatorDashboardView: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    @ObservedObject private var workspace: OperatorWorkspace
    @ObservedObject private var lifecycle: EventLifecycleCoordinator
    @ObservedObject private var operations = EventOperationalState.shared
    @ObservedObject private var printer = PrinterCoordinator.shared
    @ObservedObject private var bluetooth = PrinterBluetoothService.shared
    @ObservedObject private var recovery = PaymentRecoveryCoordinator.shared
    @ObservedObject private var monitoring = BoothMonitoring.shared
    private let loadsRemote: Bool

    init(lifecycle: EventLifecycleCoordinator? = nil, workspace: OperatorWorkspace? = nil, loadsRemote: Bool = true) {
        _lifecycle = ObservedObject(wrappedValue: lifecycle ?? EventLifecycleCoordinator())
        _workspace = ObservedObject(wrappedValue: workspace ?? .shared)
        self.loadsRemote = loadsRemote
    }

    var body: some View {
        let status = OperatorStatusSummary(report: operations.readinessReport,
            hasUnresolvedPrint: operations.hasUnresolvedPrint, printerRequiresRecovery: printer.requiresRecovery,
            pendingUploadCount: operations.pendingUploadCount, galleryStorageError: operations.queueError != nil)
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: OperatorStyle.Space.section) {
                    OperatorSectionHeading(title: "At a glance", detail: "Your event, guest admission and next steps.")
                    CurrentEventCard(lifecycle: lifecycle, loadsRemote: loadsRemote, workspace: workspace)
                    followUps(status)
                    equipment(status, width: geometry.size.width)
                    OperatorHomeMetricsView(runs: lifecycle.runs)
                    OperatorSectionHeading(title: "Quick access")
                    LazyVGrid(columns: columns(width: geometry.size.width), spacing: OperatorStyle.Space.row) {
                        link("Waiting Galleries", detail: "Saved uploads and delivery checks", symbol: "icloud.and.arrow.up", route: .waitingGalleries)
                        link("Booth Check", detail: "Inspect camera and equipment evidence", symbol: "checkmark.shield", route: .boothCheck)
                        link("Help & Recovery", detail: "Current receipt and interrupted guest support", symbol: "lifepreserver", route: .recovery)
                    }
                    VStack(alignment: .leading, spacing: OperatorStyle.Space.row) {
                        OperatorSectionHeading(title: "Printer & reprints")
                        OperatorPrinterControls()
                    }.operatorCard()
                }
                .frame(maxWidth: OperatorStyle.contentWidth)
                .padding(OperatorStyle.Space.page).frame(maxWidth: .infinity)
            }
        }
        .operatorScreen().navigationTitle("Home").toolbar(.hidden, for: .navigationBar)
        .task { operations.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: EventProfileStore.didChangeNotification)) { _ in operations.refresh() }
        .onChange(of: printer.state) { _, _ in operations.refresh() }
        .onChange(of: bluetooth.canPrintRaster) { _, _ in operations.refresh() }
        .refreshable { operations.refresh(); if loadsRemote { await lifecycle.refresh() } }
    }

    private func columns(width: CGFloat) -> [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: OperatorStyle.Space.row), count: typeSize.isAccessibilitySize || width < 580 ? 1 : 2)
    }

    @ViewBuilder private func followUps(_ status: OperatorStatusSummary) -> some View {
        let items = status.actionableAttentionItems
        let galleryAttention = operations.pendingUploads.filter(\.needsAttention).count
        VStack(alignment: .leading, spacing: OperatorStyle.Space.row) {
            OperatorSectionHeading(title: "Follow-ups", detail: "Current work requiring an attendant. Saved history stays in Reports.")
            if !items.isEmpty { OperatorAttentionCard(items: items, workspace: workspace) }
            if recovery.needsAttention {
                link(recovery.activeInterruptionCount > 0 ? "Interrupted guest checkout" : "Payment records need review",
                     detail: recovery.activeInterruptionCount > 0
                        ? "Review the current interruption in Help & Recovery. Closing a guest never settles a payment."
                        : "Review saved payment and recovery evidence. Financial report review stays separate from guest admission.",
                     symbol: "creditcard", route: .recovery, tone: .attention)
            }
            if operations.hasPendingSessionRecovery && !operations.hasUnresolvedPrint {
                link("Interrupted guest session", detail: "Review the saved session before continuing.", symbol: "person.crop.rectangle", route: .recovery, tone: .attention)
            }
            if galleryAttention > 0 && operations.queueError == nil {
                link("Gallery delivery needs review", detail: "\(galleryAttention) saved item(s) need operator attention. Photos stay on this iPad.", symbol: "icloud", route: .waitingGalleries, tone: .attention)
            }
            if items.isEmpty && !recovery.needsAttention && !operations.hasPendingSessionRecovery && galleryAttention == 0 {
                OperatorStatePanel(title: "No current follow-ups", detail: "Equipment observations are listed below. Guest admission is shown in the current event card.", symbol: "checklist")
            }
            if recovery.parkedFollowUpCount > 0 {
                link("Financial follow-up", detail: "\(recovery.parkedFollowUpCount) closed guest interaction(s). Review separately; unrelated guests can continue.", symbol: "tray", route: .recovery)
            }
        }
    }

    private func equipment(_ status: OperatorStatusSummary, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: OperatorStyle.Space.row) {
            OperatorSectionHeading(title: "System overview", detail: "Observations are separate from guest admission.")
            LazyVGrid(columns: columns(width: width), spacing: OperatorStyle.Space.row) {
                link("Camera", detail: operations.cameraCheckPassed ? "Checked this foreground session · inspect live preview" : status.camera.label + " · open Camera Check", symbol: "camera", route: .camera, tone: operations.cameraCheckPassed ? .verified : .neutral)
                link("Printer", detail: "Last reported: \(printer.operatorState.label). Transport status does not confirm paper output.", symbol: "printer", route: .printer,
                     tone: printer.requiresRecovery || operations.hasUnresolvedPrint ? .attention : .neutral)
                link("Connectivity", detail: "Network path: \(operations.networkPathStatus). Internet and providers are not verified by this observation.", symbol: "network", route: .equipment)
                link("Galleries", detail: operations.queueError != nil ? "Saved queue needs review" : "\(operations.pendingUploadCount) saved upload(s) waiting · public delivery is verified per session", symbol: "icloud", route: .waitingGalleries,
                     tone: operations.queueError != nil ? .attention : .neutral)
                if CommercialPolicySource.load() == .serverManaged {
                    link("Payments", detail: lifecycle.lastCheckedAt.map { "Event server last checked \($0.formatted(date: .omitted, time: .shortened)). Provider availability is not checked here." } ?? "Event server not checked this visit. Provider availability is unknown.", symbol: "creditcard", route: .payments)
                }
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    link("Monitoring V3", detail: OperatorEvidence.monitoringDetail(lastAccepted: monitoring.lastHeartbeat, configured: !monitoring.endpoint.isEmpty, now: context.date), symbol: "antenna.radiowaves.left.and.right", route: .monitoring)
                }
            }
            Text("Equipment snapshot: \(operations.readinessReport.generatedAt.formatted(date: .omitted, time: .shortened)). Pull to refresh saved observations; use Booth Check for an explicit camera check.")
                .font(OperatorStyle.TypeScale.metadata).foregroundStyle(OperatorPalette.secondaryText)
        }
    }

    private func link(_ title: String, detail: String, symbol: String, route: OperatorWorkspaceRoute, tone: OperatorStatusTone = .neutral) -> some View {
        OperatorNavigationCard(title: title, detail: detail, symbol: symbol, tone: tone) { workspace.navigate(to: route) }
    }
}

struct OperatorAttentionCard: View {
    let items: [OperatorStatusSummary.AttentionItem]
    @ObservedObject var workspace: OperatorWorkspace
    var body: some View {
        VStack(alignment: .leading, spacing: OperatorStyle.Space.row) {
            ForEach(items) { item in
                OperatorNavigationCard(title: item.message, detail: item.actionTitle, symbol: "exclamationmark.circle", tone: .attention) {
                    workspace.navigate(to: item.destination.route)
                }.accessibilityIdentifier("operator-follow-up-\(item.id)")
            }
        }
    }
}

/// Printer Setup wrapper. Transport selection stays inside `PrinterSetupView`.
struct OperatorPrinterSetupView: View {
    var body: some View {
        ScrollView { PrinterSetupView().padding() }
            .operatorScreen().navigationTitle("Printer Setup")
            .navigationBarTitleDisplayMode(.inline)
    }
}

struct OperatorEquipmentView: View {
    @StateObject private var operations = EventOperationalState.shared
    @StateObject private var printer = PrinterCoordinator.shared
    @StateObject private var bluetooth = PrinterBluetoothService.shared

    var body: some View {
        List {
            Section { OperatorSectionHeading(title: "System & equipment", detail: "Inspect devices and connections. Last reported states are observations; they do not confirm receipt delivery.") }
                .listRowBackground(OperatorPalette.canvas)
            Section("Devices · Printer") {
                EquipmentDestination(
                    title: "Printer",
                    status: "Last reported: " + printer.operatorState.label + " · inspect paper to confirm output",
                    systemImage: "printer.fill",
                    ready: false
                )
                NavigationLink("Printer Setup", value: OperatorWorkspaceRoute.printer)
                    .disabled(printer.isWorking)
                if printer.requiresRecovery || operations.hasUnresolvedPrint {
                    NavigationLink("Fix Printer", value: OperatorWorkspaceRoute.recovery)
                }
            }

            Section("Devices · Camera") {
                EquipmentDestination(
                    title: "Camera",
                    status: operations.cameraCheckPassed ? "Checked this foreground session" : "Not checked — run Booth Check",
                    systemImage: "camera.fill",
                    ready: operations.cameraCheckPassed
                )
                NavigationLink("Camera Check", value: OperatorWorkspaceRoute.camera)
                    .disabled(operations.customerSessionActive || operations.isPreflightRunning || printer.isWorking)
            }

            Section("Connections") {
                NavigationLink("Payments Connection & Maintenance", value: OperatorWorkspaceRoute.payments)
                LabeledContent("Network path", value: operations.networkPathStatus)
                Text("A network path does not verify internet, a payment provider or gallery delivery.")
                    .font(OperatorStyle.TypeScale.metadata).foregroundStyle(OperatorPalette.secondaryText)
                EquipmentDestination(
                    title: "Galleries",
                    status: galleryStatus,
                    systemImage: "icloud.fill",
                    ready: false
                )
                NavigationLink("Gallery Setup", value: OperatorWorkspaceRoute.gallery)
                NavigationLink(operations.queueError == nil ? "Waiting Galleries (\(operations.pendingUploadCount))" : "Waiting Galleries · review storage", value: OperatorWorkspaceRoute.waitingGalleries)
            }
            Section("Storage") {
                NavigationLink(value: OperatorWorkspaceRoute.storage) {
                    Label("Storage · \(operations.storageText)", systemImage: "internaldrive")
                }
                NavigationLink(value: OperatorWorkspaceRoute.monitoring) { Label("Monitoring", systemImage: "antenna.radiowaves.left.and.right") }
                NavigationLink(value: OperatorWorkspaceRoute.boothCheck) { Label("Check Booth", systemImage: "checkmark.shield") }
            }
            Section("Operator Access") {
                NavigationLink("Change Passcode") { OperatorPINChangeView() }
            }
            Section("Maintenance") {
                NavigationLink("Help & Recovery", value: OperatorWorkspaceRoute.recovery)
                NavigationLink("Print History", value: OperatorWorkspaceRoute.printHistory)
            }
            Section {
                NavigationLink(value: OperatorWorkspaceRoute.advanced) { Label("Advanced", systemImage: "gearshape.2") }
            } header: { Text("Advanced") } footer: { Text("Payment recovery, print audits, hardware qualification and backend configuration.") }
        }
        .operatorScreen().navigationTitle("System")
        .scrollContentBackground(.hidden).background(OperatorPalette.canvas)
        .environment(\.defaultMinListRowHeight, 52)
        .task { operations.refresh() }
    }

    private var galleryStatus: String {
        if operations.queueError != nil { return "Saved queue unavailable · review Waiting Galleries" }
        if !DeviceCredentialStore().hasDeviceToken() { return "Setup needed" }
        return operations.pendingUploadCount == 0 ? "Configured · public delivery verified per session" : "\(operations.pendingUploadCount) waiting on this iPad · public delivery verified per session"
    }
}

private struct EquipmentDestination: View {
    let title: String
    let status: String
    let systemImage: String
    let ready: Bool

    var body: some View {
        Label {
            VStack(alignment: .leading) {
                Text(title).font(.headline)
                Text(status).font(.subheadline).foregroundStyle(OperatorPalette.secondaryText)
            }
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(ready ? OperatorPalette.ready : OperatorPalette.secondaryText)
        }
        .padding(.vertical, 6)
    }
}

struct OperatorAdvancedView: View {
    @StateObject private var operations = EventOperationalState.shared
    @State private var copied = false

    var body: some View {
        List {
            Section("Payments & Recovery") {
                NavigationLink("Payment Maintenance & Recovery", value: OperatorWorkspaceRoute.payments)
                NavigationLink("Fix Printer", value: OperatorWorkspaceRoute.recovery)
            }

            Section("Operations") {
                NavigationLink("Recovery", value: OperatorWorkspaceRoute.recovery)
                NavigationLink("Print History", value: OperatorWorkspaceRoute.printHistory)
                NavigationLink("Storage", value: OperatorWorkspaceRoute.storage)
            }

            Section {
                NavigationLink {
                    HardwareQualificationView()
                } label: {
                    Label("Hardware Qualification", systemImage: "checkmark.shield")
                }
            } header: {
                Text("Qualification")
            } footer: {
                Text("Operator-approved endurance tests for this iPad, camera and printer. Opens in simulation; physical tests need explicit approval.")
            }

            Section("Diagnostics") {
                NavigationLink("Printer Transport & Diagnostics") { ScrollView { PrinterSetupView(advancedOnly: true).padding() }.operatorScreen().navigationTitle("Advanced Printer") }
                Button(copied ? "Diagnostic Report Copied" : "Copy Diagnostic Report") {
                    operations.refresh()
                    UIPasteboard.general.string = operations.diagnosticReport
                    copied = true
                }
                LabeledContent("App uptime", value: operations.uptimeText)
                LabeledContent("Camera restarts", value: "\(operations.cameraRestartCountThisLaunch)")
                LabeledContent("Copies requested", value: "\(operations.launchAuditSummary.requestedCopies)")
                LabeledContent("Recovery events", value: "\(operations.launchAuditSummary.recoveryEvents)")
                Text("Diagnostic reports exclude customer images, gallery links and access tokens.")
                    .font(.caption)
                    .foregroundStyle(OperatorPalette.secondaryText)
            }

            Section("Backend Configuration") {
                NavigationLink("Gallery Backend Override") {
                    GalleryBackendOverrideView()
                }
                Text("Advanced event support only. Defaults come from the app configuration; upload credentials stay in Keychain.")
                    .font(.caption)
                    .foregroundStyle(OperatorPalette.secondaryText)
            }

#if DEBUG
            Section("Developer Tools") {
                NavigationLink("Endurance / Chaos Harness") { EventEnduranceHarnessView() }
                NavigationLink("Printer Deep Diagnostics / Explicit Test Print") { PrinterTestView() }
                NavigationLink("Camera Development Tools") { CameraTestView() }
                NavigationLink("Gallery Development Tools") { GalleryUploadTestView() }
                NavigationLink("Booth Development Tools") { BoothSessionView(showsReceiptDebugTools: true) }
            }
#endif
        }
        .operatorScreen().navigationTitle("Advanced")
        .task { operations.refresh() }
    }
}

private struct GalleryBackendOverrideView: View {
    @State private var uploadURL = ""
    @State private var customerURL = ""
    @State private var message = ""
    @State private var activeFrontDoor = ""
    private let store = GalleryBackendOverrideStore()

    var body: some View {
        Form {
            Section("Customer Gallery Front Door") {
                LabeledContent("New sessions use", value: activeFrontDoor)
                Text("Sessions already created keep the gallery link printed on their QR code.")
                    .font(.caption)
                    .foregroundStyle(OperatorPalette.secondaryText)
            }

            Section("Optional Local Overrides") {
                TextField("Apps Script upload URL", text: $uploadURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Customer gallery base URL", text: $customerURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Text("Leave either field blank to use its Info.plist default. Only validated HTTPS endpoints are accepted. The Made to Keep and legacy gallery front doors both open the same galleries.")
                    .font(.caption)
                    .foregroundStyle(OperatorPalette.secondaryText)
            }

            Section {
                Button("Save Overrides") { save() }
                Button("Reset to Defaults", role: .destructive) {
                    store.reset()
                    uploadURL = ""
                    customerURL = ""
                    message = "Using packaged defaults."
                    activeFrontDoor = CustomerGalleryConfiguration.activeFrontDoorDescription()
                }
                if !message.isEmpty {
                    Text(message)
                        .foregroundStyle(OperatorPalette.secondaryText)
                }
            }
        }
        .operatorScreen().navigationTitle("Gallery Backend")
        .onAppear {
            uploadURL = store.uploadURLOverride() ?? ""
            customerURL = store.customerURLOverride() ?? ""
            activeFrontDoor = CustomerGalleryConfiguration.activeFrontDoorDescription()
        }
    }

    private func save() {
        do {
            try store.save(uploadURL: uploadURL, customerURL: customerURL)
            message = "Saved. New sessions use this gallery front door; queued uploads use this upload URL and keep their original gallery links."
        } catch {
            message = error.localizedDescription
        }
        activeFrontDoor = CustomerGalleryConfiguration.activeFrontDoorDescription()
    }
}

private struct OperatorStorageView: View {
    @StateObject private var operations = EventOperationalState.shared

    var body: some View {
        List {
            Section("Storage — no automatic cleanup") {
                Text(operations.storageText)
                if operations.readinessReport.checks.contains(where: { $0.title == "Archive Storage" && $0.status == .pass }) {
                    LabeledContent("Archives stored", value: "\(operations.archiveCount)")
                } else {
                    Label("Archive count unavailable — storage needs review.", systemImage: "exclamationmark.triangle").foregroundStyle(OperatorPalette.warning)
                }
                LabeledContent(
                    "Waiting gallery storage",
                    value: ByteCountFormatter.string(
                        fromByteCount: Int64(operations.pendingUploads.reduce(0) { $0 + $1.payloadSizeBytes }),
                        countStyle: .file
                    )
                )
                Text("Customer archives and waiting galleries are retained until delivery and recovery can be verified safely.")
                    .font(.caption)
            }
        }
        .operatorScreen().navigationTitle("Storage")
        .task { operations.refresh() }
    }
}

// Shared typed destinations allow restoration without replacing the existing dashboard.
extension OperatorWorkspaceRoute {
    @MainActor @ViewBuilder var destination: some View {
        switch self {
        case .liveEvent: SessionSetupView(editingLiveEvent: true)
        case .newEvent, .customizeEvent: SessionSetupView(opensNewEventDraft: true)
        case .previousEvent: SessionSetupView(opensNewEventDraft: true, usePreviousEvent: true)
        case .savedEvent(let id): OperatorSavedEventSetupView(designID: id)
        case .eventHistory: EventRunReportingView(initialTab: .history)
        case .eventLibrary: EventRunReportingView(initialTab: .manage)
        case .regularBooth: RegularBoothSettingsView()
        case .regularFooter: RegularBoothSettingsView(footerOnly: true)
        case .monitoring: BoothMonitoringView()
        case .sales: EventRunReportingView()
        case .manageEvent: EventRunReportingView(initialTab: .history)
        case .savedDrafts: SavedDraftsView()
        case .draftReview(let id): SavedDraftReviewView(draftID: id)
        case .sessionSetup, .charging: SessionSetupView()
        case .branding: OperatorBrandingView()
        case .payments: PaymentsOperatorView()
        case .eventSetup, .receiptDesign: EventDesignRouteView()
        case .boothCheck: EventPreflightView()
        case .stickers: StickerStudioOperatorView()
        case .samplePrints: SamplePrintStudioView()
        case .equipment: OperatorEquipmentView()
        case .advanced: OperatorAdvancedView()
        case .printer: OperatorPrinterSetupView()
        case .recovery: OperatorRecoveryView()
        case .camera: OperatorCameraCheckView()
        case .gallery: OperatorGallerySettingsView()
        case .waitingGalleries: PendingUploadsView()
        case .recentSessions: RecentSessionsView()
        case .storage: OperatorStorageView()
        case .printHistory: OperatorPrintAuditView()
        case .serverEvent(let id): SessionSetupView(eventID: id)
        case .eventReport(let id): ServerEventEditorView(eventID: id, reportsOnly: true)
        case .eventMaintenance(let id): ServerEventEditorView(eventID: id, reportsOnly: true, maintenance: true)
        }
    }
}

extension OperatorStatusSummary.Destination {
    var route: OperatorWorkspaceRoute {
        switch self {
        case .recovery: .recovery
        case .boothCheck: .boothCheck
        case .printerSetup: .printer
        case .gallerySetup: .gallery
        case .waitingGalleries: .waitingGalleries
        case .storage: .storage
        case .eventSetup: .eventSetup
        }
    }
}
