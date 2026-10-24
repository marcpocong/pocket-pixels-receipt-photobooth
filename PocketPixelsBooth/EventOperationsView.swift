import SwiftUI
import UIKit

/// Booth Check: runs the existing event preflight and presents its checks in operator wording.
struct EventPreflightView: View {
    @StateObject private var operations = EventOperationalState.shared
    @StateObject private var printer = PrinterCoordinator.shared

    var body: some View {
        let status = OperatorStatusSummary(
            report: operations.readinessReport,
            hasUnresolvedPrint: operations.hasUnresolvedPrint,
            printerRequiresRecovery: printer.requiresRecovery,
            pendingUploadCount: operations.pendingUploadCount,
            galleryStorageError: operations.queueError != nil
        )
        let needsAttention = operations.readinessReport.reasons
        let passed = operations.readinessReport.checks.filter { $0.status == .pass }

        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(status.headline)
                        .font(.title.bold())
                        .foregroundStyle(readinessColor)
                    Text(status.summary)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)

                Button {
                    operations.runEventPreflight()
                } label: {
                    HStack {
                        if operations.isPreflightRunning { ProgressView() }
                        Text(operations.isPreflightRunning ? "Checking…" : "Run Booth Check")
                            .font(.headline)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .disabled(operations.isPreflightRunning || operations.customerSessionActive || printer.isWorking)

                if operations.customerSessionActive {
                    Text("Finish the customer session before checking the camera.")
                        .foregroundStyle(.orange)
                }
            } footer: {
                Text("No paper is printed. Booth Check cannot prove physical receipt output, paper feed or cutter operation.")
            }

            if !needsAttention.isEmpty {
                Section("Needs Attention") {
                    ForEach(needsAttention) { check in
                        checkRow(check)
                    }
                }
            }

            if !passed.isEmpty {
                Section {
                    DisclosureGroup("Passed (\(passed.count))") {
                        ForEach(passed) { check in
                            checkRow(check)
                        }
                    }
                }
            }
        }
        .navigationTitle("Booth Check")
        .task { operations.refresh() }
    }

    private func checkRow(_ check: EventReadinessCheck) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                Text(OperatorStatusSummary.displayName(forCheckTitle: check.title))
                    .font(.headline)
                Text(check.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: icon(for: check))
                .foregroundStyle(color(for: check))
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private func icon(for check: EventReadinessCheck) -> String {
        switch check.status {
        case .pass: "checkmark.circle.fill"
        case .warning: "exclamationmark.circle.fill"
        case .fail: "xmark.circle.fill"
        }
    }

    private func color(for check: EventReadinessCheck) -> Color {
        switch check.status {
        case .pass: .green
        case .warning: .orange
        case .fail: .red
        }
    }

    private var readinessColor: Color {
        switch operations.readinessReport.readiness {
        case .ready: .green
        case .attention: .orange
        case .notReady: .red
        }
    }
}

struct OperatorRecoveryView: View {
    @StateObject private var operations = EventOperationalState.shared
    @StateObject private var printer = PrinterCoordinator.shared
    @State private var confirming = false
    @State private var physicalIdentity: String?
    @StateObject private var lifecycle = EventLifecycleCoordinator()
    @State private var showsEndEvent = false
    @State private var confirmingTest = false
    @State private var confirmingPaper = false
    @State private var testRunning = false
    @State private var textTestSent = false
    @State private var testMessage = ""
    @ObservedObject private var bluetooth = PrinterBluetoothService.shared
    var body: some View {
        List {
            Section {
                if printer.requiresRecovery || operations.hasUnresolvedPrint {
                    Label("A receipt may already have printed", systemImage: "exclamationmark.triangle.fill").font(.headline)
                    Text("1. Check the paper and ask whether the guest received the receipt.\n2. Clear any jam and restart the printer.\n3. Record your check below, then reconnect.")
                    OperatorCloseContinueButton()
                    Button("Record Receipt Check Only") { physicalIdentity = operations.physicalRecoveryIdentity; confirming = true }
                        .disabled(printer.isWorking)
                    Text("The result stays recorded as uncertain. Recording your check never prints another copy.").font(.footnote)
                } else {
                    Label("No receipt waiting for a paper check", systemImage: "checkmark.circle").font(.headline)
                }
                NavigationLink("Reconnect / Printer Setup") { OperatorPrinterSetupView() }
                    .disabled(printer.isWorking)
                if !operations.recoveryActionMessage.isEmpty { Text(operations.recoveryActionMessage) }
            } header: { Text("Action needed now") }

            if printer.preferredMode != .wifi, bluetooth.needsDiagnosticTextTest || textTestSent {
                Section("Finish the printer check") {
                    Text("Reconnect first, print one short text test, then inspect the paper. This unlocks receipt printing after a restart.")
                    Button("Print One Text Test · Uses Paper") { confirmingTest = true }
                        .disabled(testRunning || printer.isWorking || printer.requiresRecovery || operations.hasUnresolvedPrint || !bluetooth.isConnectedAndReady)
                    if textTestSent {
                        Button("The Text Printed Correctly") { confirmingPaper = true }
                            .disabled(printer.isWorking || printer.requiresRecovery || !bluetooth.isConnectedAndReady)
                    }
                    if !testMessage.isEmpty { Text(testMessage) }
                }
            }
            if let snapshot = operations.recoverableSession {
                Section {
                    Text(snapshot.sessionIdentifier).font(.headline)
                    if operations.hasPendingSessionRecovery {
                        Text(snapshot.stage == .printStatusUnknown
                             ? "Check the previous receipt above. Its photos and print record are kept."
                             : "A guest session stopped before printing was recorded. Keep its photos for reference before continuing.")
                        if snapshot.stage != .printStatusUnknown {
                            OperatorCloseContinueButton()
                            Text("Keeps the checkpoint and photos on this iPad. Pending payments still need payment recovery.").font(.footnote)
                        }
                    } else {
                        Text("Already reviewed. Kept for reference; this is not a new printer warning.")
                    }
                } header: { Text(operations.hasPendingSessionRecovery ? "Interrupted guest session" : "Earlier session") }
            }
            if operations.customerSessionActive, operations.recoverableSession == nil {
                Section("Current guest") { OperatorCloseContinueButton() }
            }
            if let error = operations.recoveryStorageError { Section("Saved guest records") { Text(error).foregroundStyle(.orange) } }
            if let error = PrintOutcomeOutbox.shared?.persistenceFailure {
                Section("Print record needs saving") {
                    Text(error).foregroundStyle(.orange)
                    Button("Retry Saving Resolution") {
                        PrintOutcomeOutbox.shared?.retryLaunchRecovery()
                        operations.refresh()
                    }
                }
            }
            CheckoutRecoverySection()
            Section("Continue operation") {
                Button("Return to Regular Booth") {
                    if let run = lifecycle.runs.current, [.active, .paused].contains(run.status) { showsEndEvent = true }
                    else { Task { _ = await lifecycle.returnToRegular() } }
                }.disabled(lifecycle.operation != nil || SessionSetupSafety.blockingReason != nil)
                if !lifecycle.message.isEmpty { Text(lifecycle.message).font(.footnote) }
                NavigationLink("Regular Booth Settings", value: OperatorWorkspaceRoute.regularBooth)
                NavigationLink("Open Session Setup", value: OperatorWorkspaceRoute.sessionSetup)
            }
            Section("History & help") {
                NavigationLink("Recent Sessions · View or Reprint") { RecentSessionsView() }
                NavigationLink("Retained Interrupted Sessions") { RetainedRecoverySessionsView() }
                NavigationLink("Print History") { OperatorPrintAuditView() }
                NavigationLink("Payment Recovery", value: OperatorWorkspaceRoute.payments)
                Text("An intentional reprint is a new print job. Inspect previous output first; uncertain prints are never retried automatically.").font(.footnote)
            }
        }.navigationTitle("Help & Recovery")
        .environment(\.defaultMinListRowHeight, 52)
        .task { operations.refresh() }
        .sheet(isPresented: $showsEndEvent) { EndEventSheet(lifecycle: lifecycle, isPresented: $showsEndEvent) }
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
                    case .failure(let error): testMessage = "\(error.localizedDescription) No automatic retry."
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
            Button("Yes — Confirm Physical Recovery") { operations.confirmPhysicalPrinterRecovery(expectedIdentity: physicalIdentity) }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This acknowledges operator inspection. It does not prove whether the previous receipt printed and does not retry it.") }
    }
}

/// Read-only retained checkpoints. No payment authorization or print operation lives here.
struct RetainedRecoverySessionsView: View {
    @State private var sessions: [AppRecoverySnapshot] = []
    @State private var error: String?
    var body: some View {
        List {
            Text("These interrupted sessions were kept by an operator. Photos, gallery links and the original uncertain result remain unchanged. Use Recent Sessions for an archived receipt reprint.").font(.footnote)
            if let error { Text(error).foregroundStyle(.orange) }
            if sessions.isEmpty, error == nil { Text("No retained interrupted sessions.") }
            ForEach(Array(sessions.enumerated()), id: \.offset) { _, session in
                NavigationLink {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            Text(session.sessionIdentifier).font(.headline)
                            Text(session.stage == .printStatusUnknown ? "Print result uncertain · already reviewed" : "Interrupted before printing was recorded")
                            if let url = session.galleryURL { Link("Open This Session's Gallery", destination: url) }
                            ForEach(Array(session.photoJPEGData.enumerated()), id: \.offset) { _, data in
                                if let photo = UIImage(data: data) { Image(uiImage: photo).resizable().scaledToFit().frame(maxHeight: 500) }
                            }
                        }.padding()
                    }.navigationTitle("Retained Session")
                } label: {
                    VStack(alignment: .leading) {
                        Text(session.sessionIdentifier)
                        Text(session.updatedAt.formatted()).font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 6)
                }
            }
        }.navigationTitle("Retained Sessions")
        .task {
            do { sessions = try AppRecoveryStore().retainedSessions() }
            catch { self.error = "Retained sessions could not be read. Their files are kept on this iPad." }
        }
    }
}

struct PendingUploadsView: View {
    @StateObject private var operations = EventOperationalState.shared
    var body: some View {
        List {
            Section {
                LabeledContent("Waiting", value: "\(operations.pendingUploadCount)")
                LabeledContent("Network", value: operations.networkPathStatus)
                if let first = operations.pendingUploads.first { LabeledContent("Oldest waiting", value: first.createdAt) }
                Text("Photos saved locally. Uploads wait for internet; receipt printing does not need to wait.")
                if let error = operations.queueError { Text(error).foregroundStyle(.red) }
                Button("Retry All") { operations.retryPendingUploads(reason: "Operator requested retry.") }
                    .disabled(operations.isUploadWorkerRunning || operations.pendingUploads.isEmpty || operations.networkPathStatus != "Online")
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(GoogleDriveGalleryUploadService.currentActivity).font(.caption)
                }
                if operations.isUploadWorkerRunning {
                    Text("Automatic recovery is checking galleries. Photos remain saved; Retry All is available between passes.").font(.caption)
                }
                Text(operations.lastUploadWorkerMessage).font(.caption)
            }
            ForEach(operations.pendingUploads) { upload in
                Section(upload.sessionID) {
                    Text(upload.createdAt)
                    Text("\(upload.deliveryState.operatorTitle) · \(upload.retryAttemptCount) attempts")
                    if let last = upload.lastAttemptAt { Text("Last attempt: \(last.formatted())") }
                    if let error = upload.lastSafeError {
                        Text("Needs attention: \(error)").font(.caption)
                        Text("Photos retained on iPad.").font(.caption)
                    }
                    if upload.galleryURL.host() == "pocket-pixels-gallery.pocketpixels-ceb.workers.dev",
                       let replacement = try? GalleryURLBuilder.makeGalleryURL(
                        customerGalleryBaseURL: URL(string: "https://gallery.madetokeepstudios.workers.dev/")!,
                        galleryToken: upload.galleryToken) {
                        Text("Original QR uses the unavailable legacy hostname. Check this same-token replacement and confirm all photos appear before sharing. The original QR stays unchanged.")
                            .font(.caption).foregroundStyle(.orange)
                        Link("Check Replacement Gallery", destination: replacement)
                        ShareLink("Share Replacement Link", item: replacement)
                    }
                    NavigationLink("View Session") { RecentSessionsView(initialSearch: upload.sessionID) }
                }
            }
        }.navigationTitle("Waiting Galleries")
        .task {
            // Refresh the operator's counts as each gallery clears, including a worker owned by
            // the customer view model. This task observes only; it never starts another upload.
            repeat {
                operations.refresh()
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            } while !Task.isCancelled
        }
        .refreshable { operations.refresh() }
    }
}

struct OperatorPrintAuditView: View {
    @State private var records: [PrintAuditRecord] = []
    @State private var failed = false
    var body: some View {
        List {
            Text("Recent transport history (up to 200 jobs). Transport completion is not proof of paper output.").font(.caption)
            if failed { Text("Print history could not be read. Keep recovery locked and inspect storage.").foregroundStyle(.red) }
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
        }.navigationTitle("Print History")
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
            case .success:
                message = "Live preview ready. Check framing on the physical iPad."
                EventOperationalState.shared.recordOperatorCameraCheck(passed: true, message: message)
            case .failure:
                message = "Camera unavailable. Enable camera permission in iPad Settings and check on a real iPad."
                EventOperationalState.shared.recordOperatorCameraCheck(passed: false, message: message)
            }
        }
    }
}

/// One operator-authorized workflow wherever the interruption is shown. The confirmation
/// captures the exact physical checkpoint; a newly failed copy cannot inherit this check.
struct OperatorCloseContinueButton: View {
    var checkoutID: String? = nil
    var title = "Close Session & Continue"
    @ObservedObject private var operations = EventOperationalState.shared
    @ObservedObject private var printer = PrinterCoordinator.shared
    @State private var confirming = false
    @State private var expectedPhysicalIdentity = ""
    @State private var checkingPaper = false

    var body: some View {
        Button(title) {
            operations.refresh()
            checkingPaper = printer.requiresRecovery || operations.hasUnresolvedPrint
            expectedPhysicalIdentity = operations.physicalRecoveryIdentity
            confirming = true
        }
        .buttonStyle(.bordered).controlSize(.large)
        .frame(minHeight: 48)
        .disabled(printer.isWorking)
        .accessibilityIdentifier("operator.closeContinue")
        .confirmationDialog(checkingPaper ? "Review Receipt, then Close & Continue" : "Close this guest interaction?",
                            isPresented: $confirming, titleVisibility: .visible) {
            Button(checkingPaper ? "I've Checked the Paper & Restarted · Close & Continue" : "Close Session & Continue") {
                if checkingPaper {
                    guard operations.confirmPhysicalPrinterRecovery(expectedIdentity: expectedPhysicalIdentity) else { return }
                }
                _ = operations.closeSessionAndContinue(checkoutID: checkoutID)
            }
            Button("Keep Session", role: .cancel) {}
        } message: {
            Text(checkingPaper
                 ? "Physically inspect the receipt and clear any jam first. Paper may already exist. The outcome stays unknown and no copy is resent. Photos and financial records stay saved."
                 : "Keep the original photos and checkout, close this guest's screen, and continue unrelated operation. Pending payments remain pending in Outstanding Payments. Paid copies remain recoverable. This does not cancel, refund or settle a payment.")
        }
    }
}
