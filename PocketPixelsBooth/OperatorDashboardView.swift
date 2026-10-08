import SwiftUI
import UIKit

struct OperatorDashboardView: View {
    @StateObject private var operations = EventOperationalState.shared
    @StateObject private var printer = PrinterCoordinator.shared
    @StateObject private var bluetooth = PrinterBluetoothService.shared
    @StateObject private var spooler = PrintSpooler.shared
    @State private var eventProfile = EventProfileStore.load()

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
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 20) {
                        OperatorEventCard(eventName: eventProfile.eventName, isActive: eventProfile.isEventModeActive)
                        OperatorReadinessCard(status: status)
                    }
                    VStack(spacing: 20) {
                        OperatorEventCard(eventName: eventProfile.eventName, isActive: eventProfile.isEventModeActive)
                        OperatorReadinessCard(status: status)
                    }
                }

                OperatorPrimaryActions()

                if !status.attentionItems.isEmpty {
                    OperatorAttentionCard(items: status.attentionItems)
                }

                OperatorSystemStatusCard(status: status)

                OperatorEventSummaryCard(
                    sessions: operations.sessionsCompletedThisLaunch,
                    waitingGalleries: operations.pendingUploadCount
                )

                HStack(spacing: 16) {
                    OperatorSecondaryLink(title: "Equipment", systemImage: "printer.fill.and.paper.fill") {
                        OperatorEquipmentView()
                    }
                    OperatorSecondaryLink(title: "Advanced", systemImage: "gearshape.2") {
                        OperatorAdvancedView()
                    }
                }
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
            eventProfile = EventProfileStore.load()
            operations.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: EventProfileStore.didChangeNotification)) { _ in
            eventProfile = EventProfileStore.load()
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
    @ViewBuilder let destination: () -> Destination

    var body: some View {
        NavigationLink {
            destination()
        } label: {
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
        .buttonStyle(.plain)
    }
}

private struct OperatorEventCard: View {
    let eventName: String
    let isActive: Bool

    var body: some View {
        HStack(spacing: 18) {
            Image(systemName: "ticket.fill")
                .font(.title)
                .foregroundStyle(.tint)
                .frame(width: 54, height: 54)
                .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))

            VStack(alignment: .leading, spacing: 8) {
                Text("CURRENT EVENT")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Text(eventName.isEmpty ? "No event configured" : eventName)
                    .font(.title2.bold())
                    .foregroundStyle(eventName.isEmpty ? .secondary : .primary)
                    .lineLimit(2)
                HStack(spacing: 8) {
                    Text("Event Mode")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(isActive ? "ON" : "OFF")
                        .font(.subheadline.bold())
                        .foregroundStyle(isActive ? .green : .secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background((isActive ? Color.green : Color.secondary).opacity(0.12), in: Capsule())
                }
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .operatorCard()
        .accessibilityElement(children: .combine)
    }
}

private struct OperatorReadinessCard: View {
    let status: OperatorStatusSummary

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: symbol)
                .font(.largeTitle)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 8) {
                Text(status.headline)
                    .font(.title.bold())
                    .foregroundStyle(color)
                    .minimumScaleFactor(0.8)
                Text(status.summary)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .operatorCard(accent: color)
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch status.readiness {
        case .ready: "checkmark.seal.fill"
        case .attention: "exclamationmark.triangle.fill"
        case .notReady: "xmark.octagon.fill"
        }
    }

    private var color: Color {
        switch status.readiness {
        case .ready: .green
        case .attention: .orange
        case .notReady: .red
        }
    }
}

/// Booth Check stays reachable at all times; its own Run button is disabled while a customer
/// session or print is active, so the operator can still read the latest results.
private struct OperatorPrimaryActions: View {
    var body: some View {
        ViewThatFits {
            HStack(spacing: 14) { actions }
            VStack(spacing: 12) { actions }
        }
    }

    @ViewBuilder
    private var actions: some View {
        OperatorActionLink(title: "Event Setup", subtitle: "Branding and activation", systemImage: "calendar") {
            EventSetupView()
        }

        OperatorActionLink(title: "Booth Check", subtitle: "Confirm readiness", systemImage: "checkmark.shield.fill") {
            EventPreflightView()
        }

        OperatorActionLink(title: "Manage Event", subtitle: "Sessions and delivery", systemImage: "person.2.crop.square.stack.fill") {
            OperatorManageEventView()
        }
    }
}

private struct OperatorActionLink<Destination: View>: View {
    let title: String
    let subtitle: String
    let systemImage: String
    @ViewBuilder let destination: () -> Destination

    var body: some View {
        NavigationLink {
            destination()
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: systemImage)
                    .font(.title)
                    .foregroundStyle(.tint)
                    .frame(height: 34)
                Text(title)
                    .font(.title3.bold())
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
            .padding(18)
            .background(.background, in: RoundedRectangle(cornerRadius: 18))
            .overlay { RoundedRectangle(cornerRadius: 18).stroke(.separator.opacity(0.5)) }
        }
        .buttonStyle(.plain)
        .accessibilityHint(subtitle)
    }
}

private struct OperatorSystemStatusCard: View {
    let status: OperatorStatusSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(status.allSystemsReady ? "All systems ready" : "Equipment Status")
                .font(.headline)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { items }
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                    GridRow {
                        OperatorStatusItem(title: "Camera", systemImage: "camera.fill", state: status.camera)
                        OperatorStatusItem(title: "Printer", systemImage: "printer.fill", state: status.printer)
                    }
                    GridRow {
                        OperatorStatusItem(title: "Gallery", systemImage: "photo.stack.fill", state: status.gallery)
                        OperatorStatusItem(title: "Internet", systemImage: "wifi", state: status.internet)
                    }
                }
            }
        }
        .operatorCard()
    }

    @ViewBuilder
    private var items: some View {
        OperatorStatusItem(title: "Camera", systemImage: "camera.fill", state: status.camera)
        OperatorStatusItem(title: "Printer", systemImage: "printer.fill", state: status.printer)
        OperatorStatusItem(title: "Gallery", systemImage: "photo.stack.fill", state: status.gallery)
        OperatorStatusItem(title: "Internet", systemImage: "wifi", state: status.internet)
    }
}

private struct OperatorStatusItem: View {
    let title: String
    let systemImage: String
    let state: OperatorStatusSummary.ComponentState

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(color)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.subheadline.bold())
                Label(state.label, systemImage: badge)
                    .font(.caption)
                    .foregroundStyle(state.isReady ? Color.secondary : color)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var badge: String {
        switch state {
        case .ready: "checkmark.circle.fill"
        case .attention: "exclamationmark.circle.fill"
        case .offline: "minus.circle.fill"
        }
    }

    private var color: Color {
        switch state {
        case .ready: .green
        case .attention: .orange
        case .offline: .secondary
        }
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
        case .eventSetup: EventSetupView()
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

private struct OperatorEventSummaryCard: View {
    let sessions: Int
    let waitingGalleries: Int

    var body: some View {
        HStack(spacing: 32) {
            summary(title: "Sessions this launch", value: sessions)
            Divider().frame(height: 42)
            summary(title: "Waiting galleries", value: waitingGalleries)
            Spacer()
        }
        .operatorCard()
    }

    private func summary(title: String, value: Int) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value, format: .number)
                .font(.title2.bold())
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
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
            }

            Section("Sessions") {
                NavigationLink("Recent Sessions & Reprints") { RecentSessionsView() }
                NavigationLink("Waiting Galleries") { PendingUploadsView() }
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
        .navigationTitle("Manage Event")
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
                NavigationLink("Printer Setup") { OperatorPrinterSetupView() }
                    .disabled(printer.isWorking)
                if printer.requiresRecovery || operations.hasUnresolvedPrint {
                    NavigationLink("Fix Printer") { OperatorRecoveryView() }
                }
            }

            Section {
                EquipmentDestination(
                    title: "Camera",
                    status: operations.cameraCheckPassed ? "Ready" : "Booth Check needed",
                    systemImage: "camera.fill",
                    ready: operations.cameraCheckPassed
                )
                NavigationLink("Camera Check") { OperatorCameraCheckView() }
                    .disabled(operations.customerSessionActive || operations.isPreflightRunning || printer.isWorking)
            }

            Section {
                EquipmentDestination(
                    title: "Gallery & Internet",
                    status: galleryStatus,
                    systemImage: "icloud.fill",
                    ready: DeviceCredentialStore().hasDeviceToken() && operations.networkPathStatus == "Online"
                )
                NavigationLink("Gallery Setup") { OperatorGallerySettingsView() }
                NavigationLink("Waiting Galleries (\(operations.pendingUploadCount))") { PendingUploadsView() }
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
            Section("Operations") {
                NavigationLink("Recovery") { OperatorRecoveryView() }
                NavigationLink("Print History") { OperatorPrintAuditView() }
                NavigationLink("Storage") { OperatorStorageView() }
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
    private let store = GalleryBackendOverrideStore()

    var body: some View {
        Form {
            Section("Optional Local Overrides") {
                TextField("Apps Script upload URL", text: $uploadURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Customer gallery base URL", text: $customerURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Text("Leave either field blank to use its Info.plist default. Only validated HTTPS endpoints are accepted.")
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
        }
    }

    private func save() {
        do {
            try store.save(uploadURL: uploadURL, customerURL: customerURL)
            message = "Saved. New sessions and queued upload attempts will use this configuration."
        } catch {
            message = error.localizedDescription
        }
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
