import SwiftUI
import UIKit

struct OperatorDashboardView: View {
    @ObservedObject private var workspace = OperatorWorkspace.shared
    @ObservedObject private var designLibrary = EventDesignLibraryStore.shared
    @StateObject private var operations = EventOperationalState.shared
    @StateObject private var printer = PrinterCoordinator.shared
    @StateObject private var bluetooth = PrinterBluetoothService.shared
    @StateObject private var spooler = PrintSpooler.shared

    var body: some View {
        let status = OperatorStatusSummary(
            report: operations.readinessReport,
            hasUnresolvedPrint: operations.hasUnresolvedPrint,
            printerRequiresRecovery: printer.requiresRecovery,
            pendingUploadCount: operations.pendingUploadCount,
            galleryStorageError: operations.queueError != nil
        )

        ScrollView {
            VStack(spacing: 20) {
                CurrentEventCard()
                NavigationLink { RegularBoothSettingsView() } label: { Label("Regular Booth Defaults", systemImage: "camera.fill").frame(maxWidth: .infinity, minHeight: 48) }.buttonStyle(.bordered)
                NavigationLink { BoothMonitoringView() } label: { Label("Remote Monitoring", systemImage: "antenna.radiowaves.left.and.right").frame(maxWidth: .infinity, minHeight: 48) }.buttonStyle(.bordered)
                if !status.attentionItems.isEmpty { OperatorAttentionCard(items: status.attentionItems) }
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)], spacing: 16) {
                    OperatorSecondaryLink(title: "Start / Manage Event", systemImage: "slider.horizontal.3", route: .sessionSetup) { SessionSetupView() }
                    OperatorSecondaryLink(title: "Payments & Reports", systemImage: "chart.bar", route: .sales) { EventRunReportingView() }
                    OperatorSecondaryLink(title: "Event Library & History", systemImage: "books.vertical", route: .manageEvent) { EventRunReportingView(initialTab: .history) }
                    OperatorSecondaryLink(title: "Branding & Design", systemImage: "paintpalette", route: .branding) { OperatorBrandingView() }
                    OperatorSecondaryLink(title: "Equipment & Recovery", systemImage: "printer", route: .equipment) { OperatorEquipmentView() }
                    OperatorSecondaryLink(title: "Advanced", systemImage: "gearshape.2", route: .advanced) { OperatorAdvancedView() }
                }
                OperatorSecondaryLink(title: "Saved Drafts · \(SavedDraftCatalog.entries(workspace: workspace, library: designLibrary.library).count)", systemImage: "doc.text", route: .savedDrafts) { SavedDraftsView() }
                OperatorSecondaryLink(title: "Print Display Samples", systemImage: "printer.dotmatrix", route: .samplePrints) { SamplePrintStudioView() }
            }
            .frame(maxWidth: 960)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("Operator")
        // The admin sheet header already shows "Made to Keep Studios · Operator"; the title is kept for back buttons.
        .toolbar(.hidden, for: .navigationBar)
        .task { operations.start() }
        .onAppear {
            operations.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: EventProfileStore.didChangeNotification)) { _ in
            operations.refresh()
        }
        .onChange(of: printer.state) { _, _ in operations.refresh() }
        .onChange(of: bluetooth.isConnectedAndReady) { _, _ in operations.refresh() }
        .onChange(of: bluetooth.canPrintRaster) { _, _ in operations.refresh() }
        .onChange(of: spooler.requiresRecovery) { _, _ in operations.refresh() }
        .refreshable { operations.refresh() }
    }
}

private struct OperatorSecondaryLink<Destination: View>: View {
    let title: String
    let systemImage: String
    var route: OperatorWorkspaceRoute? = nil
    @ViewBuilder let destination: () -> Destination

    var body: some View {
        Group {
            if let route { NavigationLink(value: route) { linkLabel } }
            else { NavigationLink { destination() } label: { linkLabel } }
        }
        .buttonStyle(.plain)
    }

    private var linkLabel: some View {
            HStack {
                Label(title, systemImage: systemImage)
                    .font(.headline)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.bold())
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, minHeight: 56)
            .padding(.horizontal, 20)
            .background(.background, in: RoundedRectangle(cornerRadius: 16))
            .overlay { RoundedRectangle(cornerRadius: 16).stroke(.separator.opacity(0.5)) }
    }
}

private struct OperatorAttentionCard: View {
    let items: [OperatorStatusSummary.AttentionItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Needs Attention", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)
                .padding(.bottom, 6)

            ForEach(items) { item in
                NavigationLink {
                    OperatorDestinationView(destination: item.destination)
                } label: {
                    HStack(spacing: 12) {
                        Text(item.message)
                            .foregroundStyle(.primary)
                        Spacer()
                        Text(item.actionTitle)
                            .font(.subheadline.bold())
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(.orange.opacity(0.15), in: Capsule())
                    }
                    .frame(minHeight: 48)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(item.actionTitle)

                if item.id != items.last?.id {
                    Divider()
                }
            }
        }
        .operatorCard(accent: .orange)
    }
}

private struct OperatorDestinationView: View {
    let destination: OperatorStatusSummary.Destination

    var body: some View {
        switch destination {
        case .recovery: OperatorRecoveryView()
        case .boothCheck: EventPreflightView()
        case .printerSetup: OperatorPrinterSetupView()
        case .gallerySetup: OperatorGallerySettingsView()
        case .waitingGalleries: PendingUploadsView()
        case .storage: OperatorStorageView()
        case .eventSetup: EventDesignRouteView()
        }
    }
}

/// Printer Setup wrapper. Transport selection stays inside `PrinterSetupView`.
struct OperatorPrinterSetupView: View {
    var body: some View {
        ScrollView { PrinterSetupView().padding() }
            .navigationTitle("Printer Setup")
            .navigationBarTitleDisplayMode(.inline)
    }
}

struct OperatorManageEventView: View {
    @StateObject private var operations = EventOperationalState.shared
    @State private var showSummary = false

    var body: some View {
        List {
            Section("Event Activity") {
                LabeledContent("Sessions this launch", value: "\(operations.sessionsCompletedThisLaunch)")
                LabeledContent("Waiting galleries", value: "\(operations.pendingUploadCount)")
                NavigationLink("Event Sales & Reports") { PaymentsOperatorView(salesOnly: true) }
            }

            Section("Sessions") {
                NavigationLink("Recent Sessions & Reprints", value: OperatorWorkspaceRoute.recentSessions)
                NavigationLink("Waiting Galleries", value: OperatorWorkspaceRoute.waitingGalleries)
            }

            Section("Guests") {
                NavigationLink("Preview Booth") {
                    ScrollView {
                        CustomerExperiencePreviewView(profile: EventProfileStore.load())
                            .padding()
                    }
                    .navigationTitle("Preview Booth")
                }
            }

            Section("Finish") {
                Button("End-of-Event Summary") {
                    operations.refresh()
                    showSummary = true
                }
            }
        }
        .navigationTitle("Sales & History")
        .task { operations.refresh() }
        .sheet(isPresented: $showSummary) {
            OperatorEventSummarySheet(isPresented: $showSummary)
        }
    }
}

private struct OperatorEventSummarySheet: View {
    @Binding var isPresented: Bool
    @StateObject private var operations = EventOperationalState.shared
    @StateObject private var printer = PrinterCoordinator.shared

    var body: some View {
        NavigationStack {
            List {
                Section("Event Summary") {
                    LabeledContent("Sessions this launch", value: "\(operations.sessionsCompletedThisLaunch)")
                    LabeledContent("Waiting galleries", value: "\(operations.pendingUploadCount)")
                    LabeledContent("App uptime", value: operations.uptimeText)
                }
                Section("Before Closing") {
                    if operations.customerSessionActive || printer.isWorking {
                        Label("Finish the active customer session or print before closing.", systemImage: "exclamationmark.triangle")
                    }
                    if operations.hasUnresolvedPrint || printer.requiresRecovery {
                        Text("Resolve unknown print status with the operator before closing.")
                            .foregroundStyle(.red)
                    }
                    if operations.pendingUploadCount > 0 {
                        Text("Keep the app open with internet to finish gallery delivery. Photos remain saved on this iPad.")
                    }
                    Text("This summary does not reset counters or delete archives, recovery data, or waiting galleries.")
                }
            }
            .navigationTitle("End-of-Event Summary")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { isPresented = false }
                }
            }
        }
    }
}

struct OperatorEquipmentView: View {
    @StateObject private var operations = EventOperationalState.shared
    @StateObject private var printer = PrinterCoordinator.shared
    @StateObject private var bluetooth = PrinterBluetoothService.shared

    var body: some View {
        List {
            Section {
                EquipmentDestination(
                    title: "Printer",
                    status: printer.requiresRecovery ? "Needs attention" : (bluetooth.canPrintRaster ? "Ready" : "Not connected"),
                    systemImage: "printer.fill",
                    ready: !printer.requiresRecovery && bluetooth.canPrintRaster
                )
                LabeledContent("Receipt transfer", value: printer.receiptBluetoothTransferMode.operatorSummary)
                    .font(.subheadline)
                NavigationLink("Printer Setup", value: OperatorWorkspaceRoute.printer)
                    .disabled(printer.isWorking)
                if printer.requiresRecovery || operations.hasUnresolvedPrint {
                    NavigationLink("Fix Printer", value: OperatorWorkspaceRoute.recovery)
                }
            }

            Section {
                EquipmentDestination(
                    title: "Camera",
                    status: operations.cameraCheckPassed ? "Ready" : "Booth Check needed",
                    systemImage: "camera.fill",
                    ready: operations.cameraCheckPassed
                )
                NavigationLink("Camera Check", value: OperatorWorkspaceRoute.camera)
                    .disabled(operations.customerSessionActive || operations.isPreflightRunning || printer.isWorking)
            }

            Section {
                EquipmentDestination(
                    title: "Gallery & Internet",
                    status: galleryStatus,
                    systemImage: "icloud.fill",
                    ready: DeviceCredentialStore().hasDeviceToken() && operations.networkPathStatus == "Online"
                )
                NavigationLink("Gallery Setup", value: OperatorWorkspaceRoute.gallery)
                NavigationLink("Waiting Galleries (\(operations.pendingUploadCount))", value: OperatorWorkspaceRoute.waitingGalleries)
            }
        }
        .navigationTitle("Equipment")
        .task { operations.refresh() }
    }

    private var galleryStatus: String {
        if !DeviceCredentialStore().hasDeviceToken() { return "Setup needed" }
        if operations.networkPathStatus != "Online" { return "Internet offline" }
        return operations.pendingUploadCount == 0 ? "Ready" : "\(operations.pendingUploadCount) waiting"
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
                Text(status).font(.subheadline).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(ready ? .green : .orange)
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
                    .foregroundStyle(.secondary)
            }

            Section("Backend Configuration") {
                NavigationLink("Gallery Backend Override") {
                    GalleryBackendOverrideView()
                }
                Text("Advanced event support only. Defaults come from the app configuration; upload credentials stay in Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
        .navigationTitle("Advanced")
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
                    .foregroundStyle(.secondary)
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
                    .foregroundStyle(.secondary)
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
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Gallery Backend")
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
                LabeledContent("Archives stored", value: "\(operations.archiveCount)")
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
        .navigationTitle("Storage")
        .task { operations.refresh() }
    }
}

private extension View {
    func operatorCard(accent: Color? = nil) -> some View {
        self
            .padding(20)
            .background(.background, in: RoundedRectangle(cornerRadius: 20))
            .overlay {
                RoundedRectangle(cornerRadius: 20)
                    .stroke((accent ?? Color.secondary).opacity(accent == nil ? 0.18 : 0.5), lineWidth: accent == nil ? 1 : 2)
            }
    }
}

// Shared typed destinations allow restoration without replacing the existing dashboard.
extension OperatorWorkspaceRoute {
    @MainActor @ViewBuilder var destination: some View {
        switch self {
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
