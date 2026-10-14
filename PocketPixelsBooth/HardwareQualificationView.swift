//
//  HardwareQualificationView.swift
//  PocketPixelsBooth
//
//  Operator Dashboard → Advanced → Hardware Qualification.
//  Setup, preflight, explicit approval, live monitoring, supervised checkpoints and durable
//  reports. The screen always opens in simulation mode and never prints on its own.
//

import AVFoundation
import SwiftUI
import UIKit

struct HardwareQualificationView: View {
    @StateObject private var engine = HardwareQualificationEngine()
    @State private var configuration = HardwareQualificationEngine.Configuration()
    @State private var showingApproval = false
    @State private var startError: String?
    @State private var safety = QualificationSafetySnapshot.idle
    @State private var showingPlan = false

    var body: some View {
        List {
            if let unresolved = engine.history.first(where: { $0.inFlightPrint != nil && $0.state == .haltedUncertainPrint }) {
                UnresolvedQualificationPrintSection(record: unresolved, engine: engine)
            }

            if let record = engine.record, engine.isRunning || record.endedAt != nil {
                QualificationLiveSection(engine: engine, record: record)
            }

            if !engine.isRunning {
                setupSection
                planSection
                preflightSection
                startSection
            }

            historySection
        }
        .navigationTitle("Hardware Qualification")
        .task {
            engine.loadHistory()
            refreshSafety()
        }
        .refreshable { refreshSafety() }
        .sheet(isPresented: $showingApproval) {
            QualificationApprovalSheet(
                plan: engine.plan(for: configuration),
                configuration: configuration,
                safety: safety,
                onApprove: { fingerprint in
                    showingApproval = false
                    start(approved: true, fingerprint: fingerprint)
                },
                onCancel: { showingApproval = false }
            )
        }
        .sheet(item: Binding<HardwareQualificationEngine.OperatorPrompt?>(
            get: { engine.endToEndModel == nil ? sheetPrompt : nil },
            set: { _, _ in }
        )) { prompt in
            QualificationPromptSheet(prompt: prompt, engine: engine)
        }
        .fullScreenCover(isPresented: Binding(get: { engine.endToEndModel != nil }, set: { _ in })) {
            if let model = engine.endToEndModel {
                QualificationBoothHost(engine: engine, model: model)
            }
        }
        .alert("Cannot start", isPresented: Binding(get: { startError != nil }, set: { if !$0 { startError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(startError ?? "")
        }
    }

    private var sheetPrompt: HardwareQualificationEngine.OperatorPrompt? {
        guard let prompt = engine.prompt else { return nil }
        if case .boothInteraction = prompt.kind { return nil }
        return prompt
    }

    // MARK: Setup

    private var setupSection: some View {
        Section {
            Picker("Test mode", selection: $configuration.mode) {
                ForEach(QualificationMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            Text(configuration.mode.summary)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Picker("Sessions", selection: $configuration.sessionCount) {
                ForEach(QualificationPlan.supportedSessionCounts, id: \.self) { Text("\($0)").tag($0) }
            }
            if configuration.mode == .endToEnd {
                Toggle("Hands-free run", isOn: $configuration.handsFreeEndToEnd)
                Text("Approve the whole run once. Captures, test details, signatures, printing and reset advance automatically. Paper checks and recovery drills stay unverified. Printer faults still require inspection.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Stepper("Batch size: \(configuration.batchSize) sessions", value: $configuration.batchSize, in: 1...25)
            LabeledContent("Seed") {
                TextField("Seed", value: $configuration.seed, format: .number.grouping(.never))
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
            }
            if configuration.mode == .simulation {
                Toggle("Inject one simulated after-bytes fault", isOn: $configuration.injectsSimulatedTransportFault)
            } else {
                LabeledContent("Paper stock") {
                    TextField("Brand, width, lot", text: $configuration.paperStock)
                        .multilineTextAlignment(.trailing)
                }
            }
            LabeledContent("Operator") {
                TextField("Name", text: $configuration.operatorName)
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("Commit SHA") {
                TextField("If not embedded in the build", text: $configuration.commitSHA)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .multilineTextAlignment(.trailing)
            }
        } header: {
            Text("Test Setup")
        } footer: {
            Text(configuration.mode.usesPhysicalPrinter
                 ? "Physical mode selected. Nothing prints until you approve the run on the confirmation sheet."
                 : "Opens in simulation. Physical modes never start without the approval sheet.")
        }
    }

    private var planSection: some View {
        let plan = engine.plan(for: configuration)
        return Section("Scenario Plan") {
            LabeledContent("Formats", value: BoothFormat.allCases.map { "\($0.displayName) \(plan.formatDistribution[$0] ?? 0)" }.joined(separator: " · "))
            LabeledContent("Copies per session", value: plan.copyDistribution.keys.sorted().map { "\($0)×: \(plan.copyDistribution[$0] ?? 0)" }.joined(separator: " · "))
            LabeledContent("Print jobs (copies)", value: "\(plan.plannedPrintJobs)")
            LabeledContent("Physical receipts", value: configuration.mode.usesPhysicalPrinter ? "\(plan.plannedPhysicalReceipts)" : "None (simulation)")
            if configuration.mode.usesPhysicalPrinter {
                LabeledContent("Estimated paper", value: plan.estimatedPaperMillimeters.map { String(format: "≈ %.1f m (estimate)", $0 / 1_000) } ?? "Not reliably calculable")
            }
            LabeledContent("Supervised checkpoints", value: plan.runsHandsFree ? "None — physical checks remain unverified" : "\(plan.scenarios.reduce(0) { $0 + $1.checkpoints.filter(\.isSupervised).count })")
            LabeledContent("Plan fingerprint", value: plan.fingerprint)
            DisclosureGroup("All \(plan.sessionCount) scenarios", isExpanded: $showingPlan) {
                ForEach(plan.scenarios) { scenario in
                    QualificationScenarioRow(scenario: scenario)
                }
            }
        }
    }

    private var preflightSection: some View {
        Section {
            QualificationCheckRow(title: "No customer session active", passed: !safety.customerSessionActive)
            if configuration.mode.usesPhysicalPrinter {
                QualificationCheckRow(title: "Printer is free", passed: !safety.printerJobActive)
                QualificationCheckRow(title: "No unresolved print", passed: !safety.unresolvedPrint)
                QualificationCheckRow(title: "No printer recovery lock", passed: !safety.printerRecoveryLocked)
                QualificationCheckRow(title: "Supported printer connection", passed: safety.transportSupported, detail: safety.printerIdentity)
                NavigationLink("Open Printer Recovery") { OperatorRecoveryView() }
            }
            if configuration.mode.usesLiveCamera {
                QualificationCheckRow(title: "Camera permission granted", passed: AVCaptureDevice.authorizationStatus(for: .video) == .authorized)
                Text("Place the physical test target (with visible identification markers) in front of the camera. Every session must capture new real photographs; identical frames are flagged as stale.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            QualificationCheckRow(title: "Diagnostic namespace available", passed: engine.store != nil, detail: "Isolated archive and recovery; never customer galleries")
            Button("Re-check") { refreshSafety() }
        } header: {
            Text("Preflight")
        }
    }

    private var startSection: some View {
        Section {
            Button {
                refreshSafety()
                showingApproval = true
            } label: {
                Label(configuration.mode.usesPhysicalPrinter ? "Review & Approve Hardware Test…" : "Review & Start Simulation…", systemImage: configuration.mode.usesPhysicalPrinter ? "checkmark.shield" : "play.circle")
            }
            // The engine re-checks on start; this just keeps a blocked preflight from reaching approval.
            .disabled(!preflightBlockers.isEmpty)
            if !preflightBlockers.isEmpty {
                Text("Blocked: \(preflightBlockers.map(\.message).joined(separator: " "))")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        } footer: {
            Text(configuration.mode.usesPhysicalPrinter
                 ? "The next screen lists everything that will physically happen. Nothing prints until you choose Approve & Start Hardware Test."
                 : "Simulation uses a mock printer and never sends bytes to hardware.")
        }
    }

    private var historySection: some View {
        Section("Historical Reports") {
            if engine.history.isEmpty {
                Text("No qualification runs yet.").foregroundStyle(.secondary)
            }
            ForEach(engine.history) { record in
                NavigationLink {
                    QualificationReportView(record: record, engine: engine)
                } label: {
                    QualificationHistoryRow(record: record)
                }
            }
            if let store = engine.store {
                LabeledContent("Qualification storage", value: ByteCountFormatter.string(fromByteCount: store.totalStorageBytes, countStyle: .file))
            }
        }
    }

    private var preflightBlockers: [QualificationSafetyViolation] {
        if configuration.mode.usesPhysicalPrinter {
            return QualificationSafetyGate.violations(snapshot: safety, authorizationDenial: nil, hasAuthorization: true, checkpointCommitted: engine.store != nil)
        }
        return safety.customerSessionActive ? [.customerSessionActive] : []
    }

    private func refreshSafety() {
        safety = engine.safetySnapshot()
    }

    private func start(approved: Bool, fingerprint: String?) {
        do {
            try engine.start(configuration, approvedByOperator: approved, expectedPlanFingerprint: fingerprint)
        } catch {
            startError = error.localizedDescription
        }
    }
}

// MARK: - Approval

private struct QualificationApprovalSheet: View {
    let plan: QualificationPlan
    let configuration: HardwareQualificationEngine.Configuration
    let safety: QualificationSafetySnapshot
    let onApprove: (String) -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section("What will happen") {
                    LabeledContent("Test mode", value: plan.mode.displayName)
                    LabeledContent("Hands-free", value: plan.runsHandsFree ? "Yes — entire run approved once" : "No")
                    LabeledContent("Sessions", value: "\(plan.sessionCount)")
                    LabeledContent("Physical receipts", value: plan.mode.usesPhysicalPrinter ? "\(plan.plannedPhysicalReceipts)" : "None")
                    LabeledContent("Copy distribution", value: plan.copyDistribution.keys.sorted().map { "\($0)-copy × \(plan.copyDistribution[$0] ?? 0)" }.joined(separator: ", "))
                    if plan.mode.usesPhysicalPrinter {
                        LabeledContent("Estimated paper", value: plan.estimatedPaperMillimeters.map { String(format: "≈ %.1f m", $0 / 1_000) } ?? "Not reliably calculable")
                        LabeledContent("Printer", value: safety.printerIdentity)
                        LabeledContent("Transport", value: safety.transport.displayName)
                        let firstWindow = HardwareQualificationEngine.approvalWindow(for: plan, after: 0)
                        LabeledContent("This approval covers", value: "Sessions 1–\(firstWindow.throughSession), \(firstWindow.receipts) receipts")
                    }
                    LabeledContent("Live camera capture", value: plan.mode.usesLiveCamera ? "Yes — front camera, every session" : "No (diagnostic photos)")
                    LabeledContent("Diagnostic data", value: "Isolated archive & report on this iPad")
                    LabeledContent("Gallery uploads", value: "None — customer galleries are never touched")
                }

                if plan.mode.usesPhysicalPrinter {
                    Section("Warnings") {
                        Label("Long runs take hours and use a lot of paper. Keep spare rolls ready.", systemImage: "clock")
                        Label("Continuous printing heats the print head. Pause if receipts fade.", systemImage: "thermometer.high")
                        if plan.runsHandsFree {
                            Label("No routine prompts. Test details and signatures are automatic. Paper output and manual recovery drills remain unverified.", systemImage: "info.circle")
                        } else {
                            Label("Supervised checkpoints ask you to power-cycle the printer or background the app between sessions. Never interrupt a print in progress.", systemImage: "hand.raised")
                            Label("Approval lasts for this launch only and stops at each batch boundary for a paper check and renewed approval.", systemImage: "lock")
                        }
                        Label("If a print's outcome becomes uncertain the run stops and nothing is resent.", systemImage: "exclamationmark.triangle")
                    }
                }

                Section {
                    Button {
                        onApprove(plan.fingerprint)
                    } label: {
                        Text(plan.mode.usesPhysicalPrinter ? "Approve & Start Hardware Test" : "Start Simulation")
                            .frame(maxWidth: .infinity)
                            .fontWeight(.semibold)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(plan.mode.usesPhysicalPrinter ? .red : .accentColor)
                    .accessibilityIdentifier("qualification.approveAndStart")
                }
            }
            .navigationTitle("Confirm Qualification Run")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
            }
        }
    }
}

// MARK: - Live monitoring

private struct QualificationLiveSection: View {
    @ObservedObject var engine: HardwareQualificationEngine
    let record: QualificationRunRecord

    var body: some View {
        let verdict = QualificationVerdict.evaluate(record)
        let durations = record.completedSessions.compactMap(\.duration)
        let current = engine.currentSession.flatMap { number in record.plan.scenarios.first { $0.sessionNumber == number } }

        Section {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(engine.isRunning ? "Session \(engine.currentSession ?? 0) / \(record.plan.sessionCount)" : record.state.rawValue.capitalized)
                        .font(.title2.bold())
                    Text(engine.stageText).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                QualificationVerdictBadge(verdict: verdict, mode: record.plan.mode)
            }
            ProgressView(value: Double(record.completedSessions.count), total: Double(max(1, record.plan.sessionCount)))
            if let current {
                LabeledContent("Current format", value: "\(current.format.displayName) · \(current.category.displayName) · \(current.plannedCopies) cop\(current.plannedCopies == 1 ? "y" : "ies")")
            }
            LabeledContent("Passed / failed", value: "\(record.passedSessionCount) / \(record.failedSessionCount)")
            LabeledContent("Elapsed", value: record.startedAt.map { Duration.seconds(Int((record.endedAt ?? Date()).timeIntervalSince($0))).formatted(.time(pattern: .hourMinuteSecond)) } ?? "—")
            LabeledContent("Average / longest session", value: String(format: "%.1f s / %.1f s", durations.isEmpty ? 0 : durations.reduce(0, +) / Double(durations.count), durations.max() ?? 0))
        } header: {
            Text("Test Execution · \(record.plan.mode.shortName)")
        }

        if engine.isRunning {
            Section("Controls") {
                if engine.pauseRequested || record.state == .paused {
                    Button("Resume (re-checks safety)") { engine.resume() }
                } else {
                    Button("Pause after current safe operation") { engine.requestPause() }
                }
                Button("Stop after current session") { engine.requestStopAfterSession() }
                    .disabled(engine.stopAfterSessionRequested)
                Button("Abort pending work", role: .destructive) { engine.abort() }
                NavigationLink("Open Printer Recovery") { OperatorRecoveryView() }
            }
        }

        Section("Live Results") {
            let sessions = record.sessions
            DisclosureGroup("Camera") {
                LabeledContent("Capture attempts", value: "\(sessions.reduce(0) { $0 + $1.captureAttempts })")
                LabeledContent("Capture failures", value: "\(sessions.reduce(0) { $0 + $1.captureFailures })")
                LabeledContent("Camera restarts (app-initiated)", value: "\(record.cameraInterruptions)")
                LabeledContent("Missing photographs", value: "\(sessions.reduce(0) { $0 + max(0, $1.captureAttempts - $1.photoFingerprints.count) })")
                LabeledContent("Crop/orientation checks failed", value: "\(sessions.filter { $0.orientationChecksPassed == false }.count)")
            }
            DisclosureGroup("Printer") {
                LabeledContent("Jobs requested / completed", value: "\(sessions.reduce(0) { $0 + $1.printJobsRequested }) / \(sessions.reduce(0) { $0 + $1.printJobsCompleted })")
                LabeledContent("Copies requested", value: "\(sessions.reduce(0) { $0 + $1.copiesRequested })")
                LabeledContent("Transport completed (app)", value: "\(record.physicalReceiptsSent)")
                LabeledContent("Paper output confirmed (operator)", value: "\(record.physicalReceiptsConfirmed)")
                LabeledContent("Uncertain transmissions", value: "\(sessions.filter { $0.outcome == .uncertainPrint }.count)")
                let transport = sessions.flatMap(\.transportSeconds)
                LabeledContent("Transport duration (avg)", value: transport.isEmpty ? "—" : String(format: "%.1f s", transport.reduce(0, +) / Double(transport.count)))
                LabeledContent("Recovery events", value: "\(record.events.filter { $0.kind == .recovery }.count)")
                LabeledContent("Duplicate/unexpected prints", value: "\(record.duplicatePrintDetections)")
                Text("The VOZY G80 gives no acknowledgement that paper physically emerged. Transport completion and operator-confirmed paper output are tracked separately.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            DisclosureGroup("Resources") {
                LabeledContent("Memory now / peak", value: "\(engine.currentMemoryMegabytes) MB / \(record.peakMemoryMegabytes) MB")
                LabeledContent("Local storage change", value: storageChange)
                LabeledContent("Pending gallery uploads (customer queue)", value: "\(engine.pendingGalleryUploads)")
                LabeledContent("Archive / recovery failures", value: "\(sessions.flatMap(\.violations).filter { $0.localizedCaseInsensitiveContains("archive") || $0.localizedCaseInsensitiveContains("checkpoint") }.count)")
            }
            DisclosureGroup("Correctness") {
                LabeledContent("Wrong-session photographs", value: "\(count(sessions, "photo from session"))")
                LabeledContent("Session identity changes", value: "\(count(sessions, "identity changed"))")
                LabeledContent("Raster fingerprint collisions", value: "\(count(sessions, "raster matches"))")
                LabeledContent("Incorrect copy counts", value: "\(count(sessions, "copies; planned") + count(sessions, "completed jobs for"))")
                LabeledContent("Stale callbacks rejected / violations", value: "\(record.staleCallbackRejections) / \(record.staleCallbackViolations)")
                LabeledContent("Unsafe retry attempts", value: "\(record.unsafeRetryAttempts)")
            }
            DisclosureGroup("Diagnostic details") {
                ForEach(Array(record.events.suffix(40).enumerated()), id: \.offset) { _, event in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(event.kind.rawValue.uppercased())\(event.session.map { " · S\($0)" } ?? "")").font(.caption.bold())
                        Text(event.detail).font(.caption)
                    }
                }
            }
        }
    }

    private var storageChange: String {
        guard let start = record.startingFreeStorageBytes, let latest = record.latestFreeStorageBytes else { return "—" }
        return ByteCountFormatter.string(fromByteCount: start - latest, countStyle: .file)
    }

    private func count(_ sessions: [QualificationSessionResult], _ marker: String) -> Int {
        sessions.reduce(0) { $0 + $1.violations.filter { $0.localizedCaseInsensitiveContains(marker) }.count }
    }
}

// MARK: - Operator prompts

private struct QualificationPromptSheet: View {
    let prompt: HardwareQualificationEngine.OperatorPrompt
    @ObservedObject var engine: HardwareQualificationEngine
    @State private var observedReceipts = 0

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(prompt.message)
                }
                switch prompt.kind {
                case .checkpoint(.confirmPaperOutput):
                    Section("Receipts physically counted") {
                        Stepper("\(observedReceipts) receipt\(observedReceipts == 1 ? "" : "s")", value: $observedReceipts, in: 0...500)
                        Button("Confirm count") { engine.respond(.paperCount(observedReceipts)) }
                            .buttonStyle(.borderedProminent)
                        Button("Skip (leaves sessions unverified)") { engine.respond(.skipped) }
                    }
                case .checkpoint:
                    Section {
                        Button("Done") { engine.respond(.acknowledged) }
                            .buttonStyle(.borderedProminent)
                        Button("Skip (remains unverified)") { engine.respond(.skipped) }
                    }
                case .batchApproval:
                    Section {
                        Button("Approve next batch") { engine.respond(.approveNextBatch) }
                            .buttonStyle(.borderedProminent)
                            .tint(.red)
                    }
                case .physicalJobBlocked:
                    Section {
                        NavigationLink("Open Printer Recovery") { OperatorRecoveryView() }
                        Button("Retry safety checks") { engine.respond(.retry) }
                            .buttonStyle(.borderedProminent)
                    }
                case .printFailedBeforeBytes:
                    Section {
                        Button("Retry (no bytes were sent)") { engine.respond(.retry) }
                            .buttonStyle(.borderedProminent)
                        Button("End session as failed") { engine.respond(.endSessionAsFailed) }
                    }
                case .boothInteraction:
                    EmptyView()
                }
                Section {
                    Button("Stop run", role: .destructive) { engine.respond(.stopRun) }
                }
            }
            .navigationTitle(prompt.title)
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled()
            .onAppear { observedReceipts = prompt.expectedReceipts ?? 0 }
        }
    }
}

/// Mode C: the production booth UI, driven by the engine, under a qualification banner.
private struct QualificationBoothHost: View {
    @ObservedObject var engine: HardwareQualificationEngine
    let model: BoothSessionViewModel

    var body: some View {
        BoothSessionView(viewModel: model)
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 6) {
                    HStack(spacing: 12) {
                        Label("HARDWARE QUALIFICATION", systemImage: "checkmark.shield")
                            .font(.caption.bold())
                        Text("Session \(engine.currentSession ?? 0) / \(engine.record?.plan.sessionCount ?? 0)")
                            .font(.caption.monospacedDigit())
                        Text(engine.stageText)
                            .font(.caption)
                            .lineLimit(1)
                        Spacer()
                        if engine.pauseRequested {
                            Button("Resume") { engine.resume() }
                        } else {
                            Button("Pause") { engine.requestPause() }
                        }
                        Button("Stop") { engine.requestStopAfterSession() }
                        Button("Abort", role: .destructive) { engine.abort() }
                    }
                    if let prompt = engine.prompt, case .boothInteraction = prompt.kind {
                        Text(prompt.message)
                            .font(.callout.weight(.semibold))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .foregroundStyle(.white)
                .background(Color.black.opacity(0.85))
            }
            .sheet(item: Binding<HardwareQualificationEngine.OperatorPrompt?>(
                get: {
                    guard let prompt = engine.prompt else { return nil }
                    if case .boothInteraction = prompt.kind { return nil }
                    return prompt
                },
                set: { _, _ in }
            )) { prompt in
                QualificationPromptSheet(prompt: prompt, engine: engine)
            }
    }
}

private struct UnresolvedQualificationPrintSection: View {
    let record: QualificationRunRecord
    @ObservedObject var engine: HardwareQualificationEngine
    @State private var note = ""
    @State private var error: String?

    var body: some View {
        Section {
            Label("Run \(record.shortID): a print may have started without a confirmed outcome (session \(record.inFlightPrint?.session ?? 0)).", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text("Inspect the printer and paper. The copy will never be resent automatically. Customer printing stays blocked until this is acknowledged.")
                .font(.footnote)
            NavigationLink("Open Printer Recovery") { OperatorRecoveryView() }
            TextField("What did you find? (e.g. receipt complete / partial)", text: $note)
            Button("I inspected the printer") {
                do { try engine.acknowledgeUncertainPrint(runID: record.runID, note: note) } catch { self.error = error.localizedDescription }
            }
            if let error { Text(error).foregroundStyle(.red) }
        } header: {
            Text("Failure and Recovery")
        }
    }
}

// MARK: - Reports

private struct QualificationReportView: View {
    let record: QualificationRunRecord
    @ObservedObject var engine: HardwareQualificationEngine
    @State private var confirmation = ""
    @State private var includeReport = false
    @State private var showingCleanup = false
    @State private var message: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let text = QualificationReportFormatter.text(for: record)
        List {
            Section {
                QualificationVerdictBadge(verdict: QualificationVerdict.evaluate(record), mode: record.plan.mode)
                ShareLink("Share report (text)", item: text)
                if let csvURL = csvFileURL() {
                    ShareLink("Share sessions (CSV)", item: csvURL)
                }
            }
            Section("Report") {
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
            Section {
                if let store = engine.store {
                    LabeledContent("Diagnostic data", value: ByteCountFormatter.string(fromByteCount: store.storageBytes(for: record.runID), countStyle: .file))
                }
                Button("Clean up diagnostic data…", role: .destructive) { showingCleanup = true }
                    .disabled(record.state.isActive || record.inFlightPrint != nil)
                if let message { Text(message).font(.footnote) }
            } header: {
                Text("Retention")
            } footer: {
                Text("Removes only this run's diagnostic archive and recovery files. Customer archives, waiting galleries, unresolved prints and customer recovery data are never touched. Nothing is deleted automatically.")
            }
        }
        .navigationTitle("Run \(record.shortID)")
        .alert("Delete diagnostic data?", isPresented: $showingCleanup) {
            TextField("Type \(record.shortID)", text: $confirmation)
                .textInputAutocapitalization(.characters)
            Button("Keep report, delete diagnostic files", role: .destructive) { cleanup(includingReport: false) }
            Button("Delete everything for this run", role: .destructive) { cleanup(includingReport: true) }
            Button("Cancel", role: .cancel) { confirmation = "" }
        } message: {
            Text("Type the run code \(record.shortID) to confirm.")
        }
    }

    private func cleanup(includingReport: Bool) {
        do {
            try engine.store?.deleteDiagnosticArtifacts(runID: record.runID, typedConfirmation: confirmation, includingReport: includingReport)
            message = includingReport ? "Run deleted." : "Diagnostic files deleted; report kept."
            engine.loadHistory()
            if includingReport { dismiss() }
        } catch {
            message = error.localizedDescription
        }
        confirmation = ""
    }

    private func csvFileURL() -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("qualification-\(record.shortID).csv")
        do {
            try QualificationReportFormatter.csv(for: record).write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }
}

// MARK: - Rows

private struct QualificationVerdictBadge: View {
    let verdict: QualificationVerdict
    let mode: QualificationMode

    var body: some View {
        Text(verdict == .pass ? "PASS · \(mode.shortName)" : verdict.rawValue)
            .font(.caption.bold())
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .foregroundStyle(.white)
            .background(color, in: Capsule())
            .accessibilityLabel("Result \(verdict.rawValue)")
    }

    private var color: Color {
        switch verdict {
        case .pass: .green
        case .failed: .red
        case .interrupted: .orange
        case .incomplete, .unverified: .gray
        case .simulationOnly: .blue
        }
    }
}

private struct QualificationHistoryRow: View {
    let record: QualificationRunRecord

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(record.plan.mode.shortName) · \(record.plan.sessionCount) sessions").font(.headline)
                Text("\(record.createdAt.formatted(date: .abbreviated, time: .shortened)) · run \(record.shortID)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            QualificationVerdictBadge(verdict: QualificationVerdict.evaluate(record), mode: record.plan.mode)
        }
    }
}

private struct QualificationScenarioRow: View {
    let scenario: QualificationScenario

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("#\(scenario.sessionNumber) \(scenario.format.displayName) · \(scenario.category.displayName) · \(scenario.plannedCopies)×\(scenario.eventModeEnabled ? " · Event" : "")\(scenario.endsBatch ? " · batch end" : "")")
                .font(.subheadline)
            Text("\(scenario.expectedReceiptLayout) · \(scenario.expectedCaptureOrientations.joined(separator: ", "))")
                .font(.caption).foregroundStyle(.secondary)
            if !scenario.checkpoints.isEmpty {
                Text("Checkpoints: \(scenario.checkpoints.map(\.title).joined(separator: ", "))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

private struct QualificationCheckRow: View {
    let title: String
    let passed: Bool
    var detail: String?

    var body: some View {
        HStack {
            Image(systemName: passed ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .foregroundStyle(passed ? .green : .red)
            VStack(alignment: .leading) {
                Text(title)
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(passed ? "passed" : "blocked")
    }
}
