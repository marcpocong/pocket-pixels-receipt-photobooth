import SwiftUI
import UIKit

struct SystemHealthView: View {
    @StateObject private var operations = EventOperationalState.shared
    @StateObject private var printer = PrinterCoordinator.shared
    @StateObject private var bluetooth = PrinterBluetoothService.shared
    @StateObject private var spooler = PrintSpooler.shared
    @State private var showCloseSummary = false
    @State private var copied = false

    var body: some View {
        List {
            Section("Can the booth operate?") {
                Text(operations.readinessReport.title)
                    .font(.title2.bold())
                    .foregroundStyle(readinessColor)
                if operations.readinessReport.checks.isEmpty { Text("Run event preflight before welcoming guests.") }
                ForEach(operations.readinessReport.reasons) { check in
                    Label("\(check.title): \(check.detail)", systemImage: check.severity == .critical ? "xmark.circle" : "exclamationmark.circle")
                        .font(.subheadline)
                }
                NavigationLink("Run Event Preflight") { EventPreflightView() }
            }
            Section("Event Status") {
                LabeledContent("Event", value: EventProfileStore.load().activeReceiptSnapshot?.eventName ?? "Pocket Pixels default")
                LabeledContent("Receipt mode", value: EventProfileStore.load().activeReceiptSnapshot == nil ? "Standard Pocket Pixels" : "Event profile")
                LabeledContent("Gallery setup", value: DeviceCredentialStore().hasDeviceToken() ? "Credential saved · delivery deferred when offline" : "Needs credential · photos remain local")
                LabeledContent("Printer", value: printer.requiresRecovery ? "Operator recovery required" : printer.bluetoothSummary)
                LabeledContent("Camera", value: operations.cameraCheckPassed ? "Initialization checked" : "Needs preflight")
                LabeledContent("Internet", value: operations.networkPathStatus)
                LabeledContent("Pending galleries", value: "\(operations.pendingUploadCount)")
                LabeledContent("Recovery", value: operations.hasUnresolvedPrint ? "Print status unknown" : (operations.recoverableSession == nil ? "None" : "Saved session retained"))
            }
            Section("Quick Actions") {
                NavigationLink("Recovery Center") { OperatorRecoveryView() }
                NavigationLink("Recent Sessions") { RecentSessionsView() }
                NavigationLink("Pending Uploads") { PendingUploadsView() }
                NavigationLink("Print Audit") { OperatorPrintAuditView() }
                NavigationLink("Camera Check") { OperatorCameraCheckView() }
                    .disabled(operations.customerSessionActive || operations.isPreflightRunning || printer.isWorking)
                NavigationLink("Gallery Credentials") { OperatorGallerySettingsView() }
                NavigationLink("Event Profile") { EventSetupView() }
                NavigationLink("Printer Connection Setup") { ScrollView { PrinterSetupView() } }
                    .disabled(printer.isWorking)
            }
            Section("Storage — no automatic cleanup") {
                Text(operations.storageText)
                LabeledContent("Archives stored", value: "\(operations.archiveCount)")
                LabeledContent("Pending gallery storage", value: ByteCountFormatter.string(fromByteCount: Int64(operations.pendingUploads.reduce(0) { $0 + $1.payloadSizeBytes }), countStyle: .file))
                Text("Customer archives and pending uploads are retained. Cleanup is deferred until delivery and recovery can be verified safely.").font(.caption)
            }
            Section("This App Launch") {
                LabeledContent("Sessions completed", value: "\(operations.sessionsCompletedThisLaunch)")
                TimelineView(.periodic(from: .now, by: 30)) { _ in LabeledContent("App uptime", value: operations.uptimeText) }
                LabeledContent("Camera restarts", value: "\(operations.cameraRestartCountThisLaunch)")
                LabeledContent("Copies requested in retained audit", value: "\(operations.launchAuditSummary.requestedCopies)")
                LabeledContent("Recovery events in retained audit", value: "\(operations.launchAuditSummary.recoveryEvents)")
                Text("Audit counters cover retained jobs only (up to 200). Session counters reset when the app relaunches.").font(.caption)
                Button("Review End-of-Event Summary") { operations.refresh(); showCloseSummary = true }
            }
            Section("Support") {
                Button(copied ? "Diagnostic Report Copied" : "Copy Diagnostic Report") {
                    operations.refresh()
                    UIPasteboard.general.string = operations.diagnosticReport
                    copied = true
                }
                Text("No customer images, gallery links or access tokens are included.").font(.caption)
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
        .navigationTitle("Event Operations")
        .task { operations.start() }
        .onChange(of: printer.state) { _, _ in operations.refresh() }
        .onChange(of: bluetooth.isConnectedAndReady) { _, _ in operations.refresh() }
        .onChange(of: bluetooth.canPrintRaster) { _, _ in operations.refresh() }
        .onChange(of: spooler.requiresRecovery) { _, _ in operations.refresh() }
        .refreshable { operations.refresh() }
        .sheet(isPresented: $showCloseSummary) {
            NavigationStack {
                List {
                    Text("End-of-Event Review").font(.title2.bold())
                    Text("\(operations.sessionsCompletedThisLaunch) sessions completed this launch · \(operations.uptimeText)")
                    Text("\(operations.launchAuditSummary.requestedCopies) requested copies and \(operations.launchAuditSummary.recoveryEvents) recovery events in retained audit.")
                    if operations.customerSessionActive || printer.isWorking { Label("A customer session or print is active. Finish it before closing.", systemImage: "exclamationmark.triangle") }
                    if operations.hasUnresolvedPrint || printer.requiresRecovery { Text("Resolve unknown print status with the operator before closing.").foregroundStyle(.red) }
                    if operations.pendingUploadCount > 0 { Text("\(operations.pendingUploadCount) galleries remain on this iPad. Keep the app open with internet to finish delivery.") }
                    Text("This review does not reset counters or delete archives, recovery data, or pending uploads.")
                }.toolbar { Button("Done") { showCloseSummary = false } }
            }
        }
    }
    private var readinessColor: Color {
        switch operations.readinessReport.readiness { case .ready: .green; case .attention: .orange; case .notReady: .red }
    }
}

struct EventPreflightView: View {
    @StateObject private var operations = EventOperationalState.shared
    @StateObject private var printer = PrinterCoordinator.shared
    var body: some View {
        List {
            Section {
                Text(operations.readinessReport.title).font(.headline)
                Text("No paper is printed. Checks cannot prove physical receipt completion, paper feed or cutter operation.")
                Button(operations.isPreflightRunning ? "Checking…" : "Run Event Preflight") { operations.runEventPreflight() }
                    .disabled(operations.isPreflightRunning || operations.customerSessionActive || printer.isWorking)
                if operations.customerSessionActive { Text("Finish the customer session before initializing the preflight camera.") }
                if operations.isPreflightRunning { ProgressView() }
            }
            Section("Checks") {
                ForEach(operations.readinessReport.checks) { check in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(check.status == .pass ? "PASS" : (check.status == .warning ? "ATTENTION" : "FAIL")) · \(check.title)").font(.headline)
                        Text(check.detail).font(.subheadline)
                    }
                }
            }
        }.navigationTitle("Event Preflight")
    }
}

struct OperatorRecoveryView: View {
    @StateObject private var operations = EventOperationalState.shared
    @StateObject private var printer = PrinterCoordinator.shared
    @State private var confirming = false
    @State private var confirmingTest = false
    @State private var confirmingPaper = false
    @State private var testRunning = false
    @State private var textTestSent = false
    @State private var testMessage = ""
    @ObservedObject private var bluetooth = PrinterBluetoothService.shared
    var body: some View {
        List {
            Section("Printer Recovery") {
                Text(printer.requiresRecovery || operations.hasUnresolvedPrint ? "Printer status unknown. A receipt may already have printed." : "No unacknowledged printer recovery lock.").font(.headline)
                Text("Inspect the receipt and paper path, then restart the printer. Automatic retry is disabled after bytes may have started. Confirmation never sends a print job.")
                Button("Confirm Printer Restarted and Receipt Checked") { confirming = true }
                    .disabled(printer.isWorking || (!printer.requiresRecovery && !operations.hasUnresolvedPrint))
                NavigationLink("Reconnect / Printer Setup") { ScrollView { PrinterSetupView() } }
                    .disabled(printer.isWorking)
                Button("Print Diagnostic Text — Uses Paper") { confirmingTest = true }
                    .disabled(testRunning || printer.isWorking || printer.requiresRecovery || operations.hasUnresolvedPrint || !bluetooth.isConnectedAndReady)
                if textTestSent {
                    Button("Confirm Diagnostic Text Printed Correctly") { confirmingPaper = true }
                        .disabled(printer.isWorking || printer.requiresRecovery || !bluetooth.isConnectedAndReady)
                }
                if !testMessage.isEmpty { Text(testMessage) }
                NavigationLink("View Print Audit") { OperatorPrintAuditView() }
                NavigationLink("Open Recent Sessions") { RecentSessionsView() }
                Text("After confirmation, reconnect the printer. Any archived reprint is a separate, intentional operator print; inspect previous output first.")
            }
            if let snapshot = operations.recoverableSession {
                Section("Saved Recovery Context") {
                    Text(snapshot.sessionIdentifier)
                    Text(snapshot.stage == .printStatusUnknown ? "Previous physical result is unknown, even after restart acknowledgement." : "Interrupted customer session saved locally.")
                    Text("Recovery data is retained. No automatic reprint or deletion.")
                }
            }
        }.navigationTitle("Recovery Center")
        .task { operations.refresh() }
        .onChange(of: bluetooth.isConnectedAndReady) { _, ready in if !ready { textTestSent = false } }
        .confirmationDialog("Print one diagnostic text test on paper?", isPresented: $confirmingTest, titleVisibility: .visible) {
            Button("Print Diagnostic Text") {
                guard !testRunning, !printer.isWorking, !printer.requiresRecovery, !operations.hasUnresolvedPrint else { return }
                testRunning = true
                textTestSent = false
                printer.quickBluetoothTextTest { result in
                    testRunning = false
                    switch result {
                    case .success: textTestSent = true; testMessage = "Transport completed. Inspect the paper before confirming."
                    case .failure: testMessage = "Test needs operator attention. No automatic retry."
                    }
                    operations.refresh()
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Did the diagnostic text physically print correctly?", isPresented: $confirmingPaper, titleVisibility: .visible) {
            Button("Yes — Paper Output Verified") {
                guard textTestSent, !printer.isWorking, !printer.requiresRecovery else { return }
                bluetooth.confirmDiagnosticTextTestSucceeded()
                textTestSent = false
                testMessage = "Operator verified diagnostic paper output."
                operations.refresh()
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Have you physically checked the receipt and restarted the printer?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Yes — Confirm Physical Recovery") { operations.confirmPhysicalPrinterRecovery() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This acknowledges operator inspection. It does not prove whether the previous receipt printed and does not retry it.") }
    }
}

struct PendingUploadsView: View {
    @StateObject private var operations = EventOperationalState.shared
    var body: some View {
        List {
            Section {
                LabeledContent("Pending", value: "\(operations.pendingUploadCount)")
                LabeledContent("Network", value: operations.networkPathStatus)
                if let first = operations.pendingUploads.first { LabeledContent("Oldest pending", value: first.createdAt) }
                Text("Photos saved locally. Uploads wait for internet; receipt printing does not need to wait.")
                if let error = operations.queueError { Text(error).foregroundStyle(.red) }
                Button(operations.isUploadWorkerRunning ? "Uploading…" : "Retry All") { operations.retryPendingUploads(reason: "Operator requested retry.") }
                    .disabled(operations.isUploadWorkerRunning || operations.pendingUploads.isEmpty || operations.networkPathStatus != "Online")
                Text(operations.lastUploadWorkerMessage).font(.caption)
            }
            ForEach(operations.pendingUploads) { upload in
                Section(upload.sessionID) {
                    Text(upload.createdAt)
                    Text("\(upload.deliveryState.operatorTitle) · \(upload.retryAttemptCount) attempts")
                    if let last = upload.lastAttemptAt { Text("Last attempt: \(last.formatted())") }
                    if upload.lastSafeError != nil { Text("Last attempt failed. Check network and saved gallery credentials; data is retained.") }
                    NavigationLink("View Session") { RecentSessionsView(initialSearch: upload.sessionID) }
                }
            }
        }.navigationTitle("Pending Uploads")
        .task { operations.refresh() }
        .refreshable { operations.refresh() }
    }
}

struct OperatorPrintAuditView: View {
    @State private var records: [PrintAuditRecord] = []
    @State private var failed = false
    var body: some View {
        List {
            Text("Recent transport history (up to 200 jobs). Transport completion is not proof of paper output.").font(.caption)
            if failed { Text("Print audit could not be read. Keep recovery locked and inspect storage.").foregroundStyle(.red) }
            ForEach(records.reversed()) { record in
                Section(record.sessionIdentifier) {
                    Text(record.timestamp.formatted())
                    Text("\(record.source.rawValue) · Copy \(record.copyIndex)/\(record.copyCount) · \(record.transport.rawValue)")
                    Text(record.terminalResult.operatorTitle).font(.headline)
                    Text("Bytes started: \(record.bytesStarted ? "Yes" : "No") · Fingerprint: \(record.payloadFingerprint.prefix(12))")
                    Text("Transport: \(String(format: "%.2f", record.transportDuration ?? 0))s · Handoff: \(String(format: "%.2f", record.handoffDuration))s")
                    if record.recoveryReason != nil { Text("Recovery reason: transport ended with uncertain physical output. Automatic retry disabled.") }
                }
            }
        }.navigationTitle("Print Audit")
        .task { load() }.refreshable { load() }
    }
    private func load() {
        do { records = try PrintAuditStore().load(); failed = false }
        catch { failed = true }
    }
}

// Operator camera preview has no print controls or sample-photo fallback.
struct OperatorCameraCheckView: View {
    @State private var camera = CameraService()
    @State private var message = "Starting camera…"
    @State private var starting = false
    @State private var visible = false
    @Environment(\.scenePhase) private var phase
    var body: some View {
        VStack {
            CameraPreview(session: camera.session, cameraService: camera).aspectRatio(3.0 / 4.0, contentMode: .fit)
            Text(message).padding()
            Button("Check Camera Again") { start() }.disabled(starting)
        }.navigationTitle("Camera Check")
        .onAppear { visible = true; start() }
        .onDisappear { visible = false; camera.stopSession() }
        .onChange(of: phase) { _, value in
            if value != .active { camera.stopSession() }
            else if visible { start() }
        }
    }
    private func start() {
        guard !starting, visible, !EventOperationalState.shared.customerSessionActive else { return }
        starting = true
        camera.configureAndStart { result in
            starting = false
            guard visible, phase == .active else { camera.stopSession(); return }
            switch result {
            case .success: message = "Live preview ready. Check framing on the physical iPad."
            case .failure: message = "Camera unavailable. Enable camera permission in iPad Settings and check on a real iPad."
            }
        }
    }
}
