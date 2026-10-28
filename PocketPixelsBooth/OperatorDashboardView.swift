import SwiftUI
import UIKit

/// Home uses the existing lifecycle coordinator; presentation never starts or activates an event.
struct OperatorDashboardView: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    @ObservedObject private var workspace: OperatorWorkspace
    @ObservedObject private var lifecycle: EventLifecycleCoordinator
    @ObservedObject private var operations = EventOperationalState.shared
    @ObservedObject private var printer = PrinterCoordinator.shared
    @ObservedObject private var bluetooth = PrinterBluetoothService.shared
    @ObservedObject private var recovery = PaymentRecoveryCoordinator.shared
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
                VStack(alignment: .leading, spacing: 20) {
                    CurrentEventCard(lifecycle: lifecycle, loadsRemote: loadsRemote, workspace: workspace)
                    Text("Quick actions").font(.headline).accessibilityAddTraits(.isHeader)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: typeSize.isAccessibilitySize || geometry.size.width < 580 ? 1 : 2), spacing: 12) {
                        equipmentButton("Booth Settings", detail: "Copies, formats, footer & branding", symbol: "slider.horizontal.3", route: .regularBooth, ready: true)
                        equipmentButton("Recent Sessions", detail: "Find a guest's receipt or gallery", symbol: "photo.stack", route: .recentSessions, ready: true)
                        equipmentButton(lifecycle.runs.operational == nil ? "Start Event" : "Manage Event", detail: "Setup, design and saved drafts", symbol: "calendar", route: lifecycle.runs.operational == nil ? .newEvent : .sessionSetup, ready: true)
                        equipmentButton("Help & Recovery", detail: "\(recovery.activeInterruptionCount) active checkout interruption(s) · receipt recovery", symbol: "lifepreserver", route: .recovery, ready: !recovery.needsAttention)
                    }
                    if !status.attentionItems.isEmpty { OperatorAttentionCard(items: status.attentionItems, workspace: workspace) }
                    if recovery.parkedFollowUpCount > 0 {
                        Button { workspace.navigate(to: .recovery) } label: {
                            Label("\(recovery.parkedFollowUpCount) parked financial follow-up(s) · guests closed · review separately", systemImage: "creditcard")
                                .font(.callout).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        }.buttonStyle(.bordered)
                    }
                    equipment(status)
                    OperatorHomeMetricsView(runs: lifecycle.runs)
                }
                .frame(maxWidth: 1_040).padding(20).frame(maxWidth: .infinity)
            }
        }
        .background(OperatorPalette.canvas)
        .navigationTitle("Home").toolbar(.hidden, for: .navigationBar)
        .task { operations.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: EventProfileStore.didChangeNotification)) { _ in operations.refresh() }
        .onChange(of: printer.state) { _, _ in operations.refresh() }
        .onChange(of: bluetooth.canPrintRaster) { _, _ in operations.refresh() }
        .refreshable { operations.refresh(); if loadsRemote { await lifecycle.refresh() } }
    }

    private func equipment(_ status: OperatorStatusSummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Equipment").font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 12)], spacing: 12) {
                equipmentButton("Camera", detail: status.camera.label, symbol: "camera", route: .camera, ready: status.camera.isReady)
                equipmentButton("Printer", detail: printer.operatorState.label,
                    symbol: "printer", route: printer.requiresRecovery || operations.hasUnresolvedPrint ? .recovery : .printer, ready: status.printer.isReady)
                equipmentButton("Gallery / connectivity", detail: status.internet.isReady ? (status.gallery.isReady ? "Configured · online" : status.gallery.label) : status.internet.label,
                    symbol: "icloud", route: operations.pendingUploadCount > 0 ? .waitingGalleries : .gallery,
                    ready: status.gallery.isReady && status.internet.isReady)
            }
            Text("Equipment shows the last reported state. Booth Check verifies the camera; inspect paper to confirm physical print output.")
                .font(.footnote).foregroundStyle(OperatorPalette.secondaryText)
        }
    }
    private func equipmentButton(_ title: String, detail: String, symbol: String, route: OperatorWorkspaceRoute, ready: Bool) -> some View {
        Button { workspace.navigate(to: route) } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol).foregroundStyle(ready ? OperatorPalette.accent : OperatorPalette.warning)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.callout.weight(.semibold))
                    Text(detail).font(.caption).foregroundStyle(OperatorPalette.secondaryText).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(OperatorPalette.secondaryText)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).padding(12)
            .background(OperatorPalette.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).stroke(OperatorPalette.border) }
        }.buttonStyle(.plain).accessibilityHint("Open \(title)")
    }
}

private struct OperatorAttentionCard: View {
    let items: [OperatorStatusSummary.AttentionItem]
    @ObservedObject var workspace: OperatorWorkspace
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Needs attention", systemImage: "exclamationmark.triangle.fill")
                .font(.callout.weight(.semibold)).foregroundStyle(OperatorPalette.accent)
            if let item = items.first {
                Button { workspace.navigate(to: item.destination.route) } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.message).font(.callout).foregroundStyle(.primary)
                        Label(item.actionTitle, systemImage: "arrow.right").font(.callout.weight(.semibold))
                    }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }.buttonStyle(.plain).accessibilityHint(item.actionTitle)
            }
            if items.count > 1 {
                Button("\(items.count - 1) more in System") { workspace.navigate(to: .equipment) }
                    .font(.footnote).frame(minHeight: 44, alignment: .leading)
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).stroke(Color.orange.opacity(0.35)) }
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

struct OperatorEquipmentView: View {
    @StateObject private var operations = EventOperationalState.shared
    @StateObject private var printer = PrinterCoordinator.shared
    @StateObject private var bluetooth = PrinterBluetoothService.shared

    var body: some View {
        List {
            Section("Devices · Printer") {
                EquipmentDestination(
                    title: "Printer",
                    status: printer.operatorState.label,
                    systemImage: "printer.fill",
                    ready: printer.operatorState.acceptsJobs
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
                EquipmentDestination(
                    title: "Gallery & Internet",
                    status: galleryStatus,
                    systemImage: "icloud.fill",
                    ready: DeviceCredentialStore().hasDeviceToken() && operations.networkPathStatus == "Online"
                )
                NavigationLink("Gallery Setup", value: OperatorWorkspaceRoute.gallery)
                NavigationLink("Waiting Galleries (\(operations.pendingUploadCount))", value: OperatorWorkspaceRoute.waitingGalleries)
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
        .navigationTitle("System")
        .scrollContentBackground(.hidden).background(OperatorPalette.canvas)
        .environment(\.defaultMinListRowHeight, 52)
        .task { operations.refresh() }
    }

    private var galleryStatus: String {
        if !DeviceCredentialStore().hasDeviceToken() { return "Setup needed" }
        if operations.networkPathStatus != "Online" { return "Internet offline" }
        return operations.pendingUploadCount == 0 ? "Configured · online (delivery not checked here)" : "\(operations.pendingUploadCount) waiting on this iPad"
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
                .foregroundStyle(ready ? OperatorPalette.ready : OperatorPalette.warning)
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
                NavigationLink("Printer Transport & Diagnostics") { ScrollView { PrinterSetupView(advancedOnly: true).padding() }.navigationTitle("Advanced Printer") }
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
        .navigationTitle("Storage")
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
