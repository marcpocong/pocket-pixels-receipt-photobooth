//
//  HardwareQualificationEngine.swift
//  PocketPixelsBooth
//
//  Orchestrates operator-approved hardware qualification runs.
//
//  Safety contract:
//  - Nothing physical happens because a screen opened or a default is set. The default mode is
//    simulation, and physical modes need an in-memory authorization bound to this run, this plan,
//    this launch and an explicit receipt budget.
//  - Before every physical job: no customer session, no other printer owner, no unresolved
//    print, no recovery lock, a supported transport, a durable pre-print checkpoint, and an
//    authorization that covers the job. Any failure blocks the job.
//  - Printing goes through PrinterCoordinator → PrintSpooler; no new transport exists here.
//  - A print whose bytes may have started without confirmed completion halts the run. It is
//    never resent automatically.
//

import Combine
import Foundation
import UIKit

// MARK: - Printer abstraction

struct QualificationPrintRequest {
    let rasterizedImage: ThermalRasterizedImage
    let sessionIdentifier: String
    let copyIndex: Int
    let copyCount: Int
    let batchID: UUID
    let prePrintCheckpoint: PrePrintCheckpointGate
}

struct QualificationPrintOutcome: Equatable {
    enum Status: Equatable {
        case completed
        case failedBeforeBytes
        case blockedByCheckpoint
        case uncertainAfterBytes
    }

    let status: Status
    let message: String
    let transportSeconds: Double?
}

/// The physical printer as qualification sees it. Production wraps PrinterCoordinator; tests
/// inject a fake so XCTest can never send bytes to a real printer.
@MainActor
protocol QualificationPrinter: AnyObject {
    func safetySnapshot() -> QualificationSafetySnapshot
    func printCopy(_ request: QualificationPrintRequest) async -> QualificationPrintOutcome
    func auditRecords(sessionIdentifier: String) -> [PrintAuditRecord]
    var wifiHost: String { get }
    var wifiPort: UInt16? { get }
}

@MainActor
final class CoordinatorQualificationPrinter: QualificationPrinter {
    private let coordinator: PrinterCoordinator
    private let operations: EventOperationalState

    init(coordinator: PrinterCoordinator? = nil, operations: EventOperationalState? = nil) {
        self.coordinator = coordinator ?? .shared
        self.operations = operations ?? .shared
    }

    var wifiHost: String {
        UserDefaults.standard.string(forKey: "printerIP") ?? BoothConfiguration.defaultPrinterIP
    }

    var wifiPort: UInt16? {
        UInt16((UserDefaults.standard.string(forKey: "printerPort") ?? BoothConfiguration.defaultPrinterPort)
            .trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func safetySnapshot() -> QualificationSafetySnapshot {
        operations.refresh()
        let bluetoothReady = coordinator.isBluetoothReady
        let wifiConfigured = wifiPort != nil && !wifiHost.trimmingCharacters(in: .whitespaces).isEmpty
        let transport: PrinterTransportSelection
        let supported: Bool
        switch coordinator.preferredMode {
        case .bluetooth:
            transport = .bluetooth
            supported = bluetoothReady
        case .wifi:
            transport = .wifi
            supported = wifiConfigured
        case .auto:
            // Auto only counts a connected Bluetooth printer. A configured Wi-Fi address alone is
            // not proof a printer is there, so preflight never reports it as ready.
            transport = bluetoothReady ? .bluetooth : .none
            supported = bluetoothReady
        }
        let identity: String
        switch transport {
        case .wifi:
            identity = "Wi-Fi printer \(wifiHost):\(wifiPort.map(String.init) ?? "?") (reachability is checked when printing; failures stop before bytes)"
        case .bluetooth:
            identity = bluetoothReady ? "\(coordinator.bluetoothPrinterName) connected" : "\(coordinator.bluetoothPrinterName) not connected"
        case .none:
            identity = "No printer connected"
        }
        return QualificationSafetySnapshot(
            customerSessionActive: operations.customerSessionActive,
            printerJobActive: coordinator.isWorking,
            unresolvedPrint: operations.hasUnresolvedPrint,
            printerRecoveryLocked: coordinator.requiresRecovery,
            transport: transport,
            transportSupported: supported,
            printerIdentity: "\(identity) · \(coordinator.preferredMode.displayName) · \(coordinator.receiptBluetoothTransferMode.operatorSummary)"
        )
    }

    func printCopy(_ request: QualificationPrintRequest) async -> QualificationPrintOutcome {
        let startedAt = Date()
        return await withCheckedContinuation { continuation in
            coordinator.printReceipt(
                rasterizedImage: request.rasterizedImage,
                wifiHost: wifiHost,
                wifiPort: wifiPort,
                sessionIdentifier: request.sessionIdentifier,
                source: .diagnostic,
                copyIndex: request.copyIndex,
                copyCount: request.copyCount,
                batchID: request.batchID,
                transportPolicy: coordinator.productionReceiptTransportPolicy,
                prePrintCheckpoint: request.prePrintCheckpoint
            ) { _ in
            } completion: { [weak self] result in
                let seconds = Date().timeIntervalSince(startedAt)
                switch result {
                case .success:
                    continuation.resume(returning: QualificationPrintOutcome(status: .completed, message: "Transport completed.", transportSeconds: seconds))
                case .failure(let error):
                    if error is PrintCheckpointError {
                        continuation.resume(returning: QualificationPrintOutcome(status: .blockedByCheckpoint, message: error.localizedDescription, transportSeconds: nil))
                        return
                    }
                    let bytesStarted = (error as? PrintTransportFailure)?.bytesStarted ?? false
                    // Conservative: a recovery lock after the attempt also counts as uncertain.
                    let uncertain = bytesStarted || (self?.coordinator.requiresRecovery ?? true)
                    continuation.resume(returning: QualificationPrintOutcome(
                        status: uncertain ? .uncertainAfterBytes : .failedBeforeBytes,
                        message: error.localizedDescription,
                        transportSeconds: seconds
                    ))
                }
            }
        }
    }

    func auditRecords(sessionIdentifier: String) -> [PrintAuditRecord] {
        ((try? PrintAuditStore().load()) ?? []).filter { $0.sessionIdentifier == sessionIdentifier }
    }
}

// MARK: - Engine

@MainActor
final class HardwareQualificationEngine: ObservableObject {
    struct Configuration: Equatable {
        var mode: QualificationMode = .simulation
        var sessionCount = QualificationPlan.defaultSessionCount
        var seed = QualificationPlan.defaultSeed
        var batchSize = QualificationPlan.defaultBatchSize
        var paperStock = ""
        var operatorName = ""
        var commitSHA = ""
        /// Simulation only: inject one after-bytes transport fault to prove the lock / no-retry path.
        var injectsSimulatedTransportFault = true
    }

    enum OperatorPromptKind: Equatable {
        case checkpoint(QualificationCheckpoint)
        case batchApproval(throughSession: Int, receipts: Int)
        case physicalJobBlocked([QualificationSafetyViolation])
        case printFailedBeforeBytes(String)
        /// Photo Pass details/signature are entered on the booth screen; resumes on its own.
        case boothInteraction(QualificationCheckpoint)
    }

    struct OperatorPrompt: Identifiable, Equatable {
        let id = UUID()
        let session: Int
        let kind: OperatorPromptKind
        let title: String
        let message: String
        var expectedReceipts: Int?
    }

    enum OperatorResponse: Equatable {
        case acknowledged
        case skipped
        case paperCount(Int)
        case approveNextBatch
        case retry
        case endSessionAsFailed
        case stopRun
    }

    enum StartError: Error, LocalizedError, Equatable {
        case alreadyRunning
        case physicalApprovalRequired
        case approvalMismatch
        case unresolvedQualificationPrint
        case safety([QualificationSafetyViolation])
        case storeUnavailable

        var errorDescription: String? {
            switch self {
            case .alreadyRunning: "A qualification run is already in progress."
            case .physicalApprovalRequired: "Physical tests need explicit operator approval."
            case .approvalMismatch: "The approval does not match this run configuration."
            case .unresolvedQualificationPrint: "An earlier qualification print has an unknown outcome. Inspect the printer and acknowledge it first."
            case .safety(let violations): violations.map(\.message).joined(separator: " ")
            case .storeUnavailable: "Qualification storage is unavailable."
            }
        }
    }

    @Published private(set) var record: QualificationRunRecord?
    @Published private(set) var history: [QualificationRunRecord] = []
    @Published private(set) var stageText = "Idle"
    @Published private(set) var currentSession: Int?
    @Published private(set) var prompt: OperatorPrompt?
    @Published private(set) var authorization: QualificationAuthorization?
    @Published private(set) var isRunning = false
    @Published private(set) var pauseRequested = false
    @Published private(set) var stopAfterSessionRequested = false
    @Published private(set) var abortRequested = false
    @Published private(set) var currentMemoryMegabytes = 0
    @Published private(set) var pendingGalleryUploads = 0
    @Published private(set) var lastSafetyViolations: [QualificationSafetyViolation] = []
    /// The production booth model driven during Mode C; the UI hosts BoothSessionView on it.
    @Published private(set) var endToEndModel: BoothSessionViewModel?

    let store: HardwareQualificationStore?
    private let printer: QualificationPrinter
    private let makeSessionModel: @MainActor (BoothSessionEnvironment) -> BoothSessionViewModel
    private let pendingUploadCount: @MainActor () -> Int
    private let cameraRestartCount: @MainActor () -> Int
    private let pollInterval: Duration
    private let auditSettleTimeout: TimeInterval

    private var promptContinuation: CheckedContinuation<OperatorResponse, Never>?
    private var resumeContinuation: CheckedContinuation<Void, Never>?
    private var runTask: Task<Void, Never>?
    private var simulationSpooler: PrintSpooler?
    private var seenPhotoFingerprints: [String: Int] = [:]
    private var seenRasterFingerprints: [String: Int] = [:]
    private var archivedSessions: [Int: (token: String, fingerprint: String, eventName: String)] = [:]
    private var receiptsAwaitingPaper = 0
    private var sessionsAwaitingPaper: [Int] = []
    private var cameraRestartBaseline = 0
    private var currentEventProfile = QualificationEventProfiles.disabled
    private var injectedFaultSession: Int?
    private var configuration = Configuration()

    init(
        store: HardwareQualificationStore? = try? HardwareQualificationStore(),
        printer: QualificationPrinter? = nil,
        makeSessionModel: (@MainActor (BoothSessionEnvironment) -> BoothSessionViewModel)? = nil,
        pendingUploadCount: (@MainActor () -> Int)? = nil,
        cameraRestartCount: (@MainActor () -> Int)? = nil,
        pollInterval: Duration = .milliseconds(100),
        auditSettleTimeout: TimeInterval = 3
    ) {
        self.store = store
        self.printer = printer ?? CoordinatorQualificationPrinter()
        self.makeSessionModel = makeSessionModel ?? { BoothSessionViewModel(environment: $0) }
        self.pendingUploadCount = pendingUploadCount ?? { (try? GalleryPendingUploadStore().summaries().count) ?? 0 }
        self.cameraRestartCount = cameraRestartCount ?? { EventOperationalState.shared.cameraRestartCountThisLaunch }
        self.pollInterval = pollInterval
        self.auditSettleTimeout = auditSettleTimeout
    }

    // MARK: Setup

    /// Rebuilds history and marks runs from an earlier launch as interrupted. Never resumes.
    func loadHistory() {
        guard let store else { return }
        store.reconstructAfterLaunch()
        history = store.loadAll()
    }

    func plan(for configuration: Configuration) -> QualificationPlan {
        QualificationPlanner.makePlan(
            mode: configuration.mode,
            sessionCount: configuration.sessionCount,
            seed: configuration.seed,
            batchSize: configuration.batchSize
        )
    }

    func safetySnapshot() -> QualificationSafetySnapshot {
        printer.safetySnapshot()
    }

    /// The first approval window: up to the first batch end, and the receipts it needs.
    static func approvalWindow(for plan: QualificationPlan, after session: Int) -> (throughSession: Int, receipts: Int) {
        let remaining = plan.scenarios.filter { $0.sessionNumber > session }
        guard let end = remaining.first(where: \.endsBatch)?.sessionNumber ?? remaining.last?.sessionNumber else {
            return (session, 0)
        }
        let receipts = plan.scenarios.filter { $0.sessionNumber <= end }.reduce(0) { $0 + $1.plannedCopies }
        return (end, receipts)
    }

    /// Starts a run. Physical modes require `approvedByOperator`, which the UI sets only from
    /// the explicit "Approve & Start Hardware Test" action on the confirmation sheet.
    @discardableResult
    func start(_ configuration: Configuration, approvedByOperator: Bool, expectedPlanFingerprint: String? = nil) throws -> QualificationRunRecord {
        guard !isRunning else { throw StartError.alreadyRunning }
        guard let store else { throw StartError.storeUnavailable }
        let plan = plan(for: configuration)
        if configuration.mode.usesPhysicalPrinter {
            guard approvedByOperator else { throw StartError.physicalApprovalRequired }
            if let expectedPlanFingerprint, expectedPlanFingerprint != plan.fingerprint { throw StartError.approvalMismatch }
            guard store.unresolvedPrintRun == nil else { throw StartError.unresolvedQualificationPrint }
            let snapshot = printer.safetySnapshot()
            let blocking = QualificationSafetyGate.violations(snapshot: snapshot, authorizationDenial: nil, hasAuthorization: true, checkpointCommitted: true)
            guard blocking.isEmpty else {
                lastSafetyViolations = blocking
                throw StartError.safety(blocking)
            }
        } else if printer.safetySnapshot().customerSessionActive {
            throw StartError.safety([.customerSessionActive])
        }

        self.configuration = configuration
        let snapshot = printer.safetySnapshot()
        var record = QualificationRunRecord(
            runID: UUID(),
            plan: plan,
            createdAt: Date(),
            environment: QualificationEnvironmentInfo.current(operatorCommitSHA: configuration.commitSHA),
            printerIdentity: configuration.mode.usesPhysicalPrinter ? snapshot.printerIdentity : "Mock transport (no printer)",
            printerTransport: configuration.mode.usesPhysicalPrinter ? snapshot.transport.displayName : "Simulated",
            paperStock: configuration.paperStock,
            operatorName: configuration.operatorName,
            launchID: QualificationLaunch.current
        )
        record.startedAt = Date()
        record.state = .running
        record.startingFreeStorageBytes = QualificationResourceMonitor.freeStorageBytes()
        record.log(.info, "Run started: \(plan.mode.displayName), \(plan.sessionCount) sessions, seed \(plan.seed).")

        if configuration.mode.usesPhysicalPrinter {
            let window = Self.approvalWindow(for: plan, after: 0)
            let approval = QualificationAuthorization(
                runID: record.runID,
                planFingerprint: plan.fingerprint,
                launchID: QualificationLaunch.current,
                approvedThroughSession: window.throughSession,
                approvedPhysicalReceipts: window.receipts,
                approvedAt: Date()
            )
            authorization = approval
            record.approvals.append(QualificationApprovalRecord(approvedAt: approval.approvedAt, launchID: approval.launchID, approvedThroughSession: approval.approvedThroughSession, approvedPhysicalReceipts: approval.approvedPhysicalReceipts))
            record.log(.approval, "Operator approved sessions 1–\(window.throughSession) and \(window.receipts) physical receipts.")
        } else {
            authorization = nil
        }

        try store.save(record)
        self.record = record
        resetRunState(plan: plan)
        isRunning = true
        runTask = Task { [weak self] in
            await self?.runLoop()
        }
        return record
    }

    /// Awaits the current run (tests and the UI's completion handling).
    func waitUntilFinished() async {
        await runTask?.value
    }

    // MARK: Controls

    func requestPause() {
        guard isRunning else { return }
        pauseRequested = true
        stageText = "Pausing after the current safe operation…"
    }

    /// Resumes after re-checking safety; physical approval must still be valid for this launch.
    func resume() {
        guard isRunning, pauseRequested || record?.state == .paused else { return }
        if configuration.mode.usesPhysicalPrinter {
            guard let authorization, authorization.launchID == QualificationLaunch.current else {
                stageText = "Approval is no longer valid. Stop this run and start a new approved run."
                return
            }
            let snapshot = printer.safetySnapshot()
            let violations = QualificationSafetyGate.violations(snapshot: snapshot, authorizationDenial: nil, hasAuthorization: true, checkpointCommitted: true)
                .filter { $0 != .customerSessionActive || configuration.mode != .endToEnd }
            guard violations.isEmpty else {
                lastSafetyViolations = violations
                stageText = "Cannot resume: \(violations.map(\.message).joined(separator: " "))"
                return
            }
        }
        pauseRequested = false
        mutate { $0.log(.info, "Operator resumed the run.") }
        resumeContinuation?.resume()
        resumeContinuation = nil
    }

    func requestStopAfterSession() {
        guard isRunning else { return }
        stopAfterSessionRequested = true
        stageText = "Stopping after the current session…"
    }

    /// Abandons pending work. A print already sending is allowed to finish (bytes are never cut
    /// off by the app); nothing new starts.
    func abort() {
        guard isRunning else { return }
        abortRequested = true
        stopAfterSessionRequested = true
        mutate { $0.log(.info, "Operator aborted pending work.") }
        if let continuation = promptContinuation {
            promptContinuation = nil
            prompt = nil
            continuation.resume(returning: .stopRun)
        }
        resumeContinuation?.resume()
        resumeContinuation = nil
    }

    func respond(_ response: OperatorResponse) {
        guard let continuation = promptContinuation else { return }
        promptContinuation = nil
        prompt = nil
        continuation.resume(returning: response)
    }

    func acknowledgeUncertainPrint(runID: UUID, note: String) throws {
        try store?.acknowledgeUncertainPrint(runID: runID, note: note)
        history = store?.loadAll() ?? history
        if record?.runID == runID { record = history.first { $0.runID == runID } }
    }

    // MARK: Run loop

    private func resetRunState(plan: QualificationPlan) {
        pauseRequested = false
        stopAfterSessionRequested = false
        abortRequested = false
        seenPhotoFingerprints = [:]
        seenRasterFingerprints = [:]
        archivedSessions = [:]
        receiptsAwaitingPaper = 0
        sessionsAwaitingPaper = []
        cameraRestartBaseline = cameraRestartCount()
        injectedFaultSession = plan.mode == .simulation && configuration.injectsSimulatedTransportFault
            ? plan.scenarios.first { $0.category == .recovery || $0.category == .printLoad }?.sessionNumber
            : nil
        if plan.mode == .simulation, let store, let runID = record?.runID {
            simulationSpooler = PrintSpooler(
                auditStore: try? PrintAuditStore(fileURL: store.auditURL(for: runID)),
                waitsForPhysicalHandoff: false,
                writesAuditSynchronously: true
            )
        } else {
            simulationSpooler = nil
        }
        if plan.mode == .endToEnd, let record, let store {
            endToEndModel = makeSessionModel(endToEndEnvironment(record: record, store: store))
        } else {
            endToEndModel = nil
        }
    }

    private func endToEndEnvironment(record: QualificationRunRecord, store: HardwareQualificationStore) -> BoothSessionEnvironment {
        let runCode = record.shortID.prefix(4).uppercased()
        return BoothSessionEnvironment(
            purpose: .hardwareQualification(runID: record.runID.uuidString),
            archiveDirectory: store.archiveDirectory(for: record.runID),
            recoveryDirectory: store.recoveryDirectory(for: record.runID),
            deliversGallery: false,
            recordsCustomerSessionMetrics: false,
            printSource: .diagnostic,
            makeSessionIdentifier: { [weak self] date in
                Self.sessionIdentifier(runCode: String(runCode), session: self?.currentSession ?? 0, date: date)
            },
            eventProfileSource: { [weak self] in
                self?.currentEventProfile ?? QualificationEventProfiles.disabled
            },
            // Qualification measures the production print path; it never opens Sticker Studio.
            stickerConfigurationSource: { .disabled }
        )
    }

    static func sessionIdentifier(runCode: String, session: Int, date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = ReceiptComposer.sessionIdentifierTimeZone
        formatter.dateFormat = "HHmmss"
        return "QA-\(runCode)-\(String(format: "%03d", session))-\(formatter.string(from: date))"
    }

    private func runLoop() async {
        guard let plan = record?.plan else { return }
        for scenario in plan.scenarios {
            if await shouldStopBeforeSession() { break }

            if plan.mode.usesPhysicalPrinter, let authorization, scenario.sessionNumber > authorization.approvedThroughSession {
                let window = Self.approvalWindow(for: plan, after: scenario.sessionNumber - 1)
                mutate { $0.state = .awaitingBatchApproval }
                let response = await ask(OperatorPrompt(
                    session: scenario.sessionNumber,
                    kind: .batchApproval(throughSession: window.throughSession, receipts: window.receipts),
                    title: "Approve next batch",
                    message: "Sessions \(scenario.sessionNumber)–\(window.throughSession) will print up to \(window.receipts - (record?.physicalReceiptsSent ?? 0)) more receipts (\(window.receipts) total for the run). Check paper, printer temperature and the test target before approving."
                ))
                guard response == .approveNextBatch else {
                    mutate { $0.log(.approval, session: scenario.sessionNumber, "Operator did not approve the next batch; run stopped.") }
                    break
                }
                let renewed = QualificationAuthorization(
                    runID: authorization.runID,
                    planFingerprint: authorization.planFingerprint,
                    launchID: QualificationLaunch.current,
                    approvedThroughSession: window.throughSession,
                    approvedPhysicalReceipts: window.receipts,
                    approvedAt: Date()
                )
                self.authorization = renewed
                mutate {
                    $0.state = .running
                    $0.approvals.append(QualificationApprovalRecord(approvedAt: renewed.approvedAt, launchID: renewed.launchID, approvedThroughSession: renewed.approvedThroughSession, approvedPhysicalReceipts: renewed.approvedPhysicalReceipts))
                    $0.log(.approval, session: scenario.sessionNumber, "Operator approved sessions through \(window.throughSession) and \(window.receipts) physical receipts in total.")
                }
            }

            currentSession = scenario.sessionNumber
            currentEventProfile = QualificationEventProfiles.profile(for: scenario, plan: plan)
            let continueRun: Bool
            switch plan.mode {
            case .simulation, .physicalPrinterEndurance:
                continueRun = await runSyntheticSession(scenario, plan: plan)
            case .endToEnd:
                continueRun = await runEndToEndSession(scenario, plan: plan)
            }
            sampleResources()
            guard continueRun else { break }
            guard await runCheckpoints(after: scenario, plan: plan) else { break }
        }
        await finish()
    }

    private func shouldStopBeforeSession() async -> Bool {
        if stopAfterSessionRequested || abortRequested { return true }
        if pauseRequested {
            mutate { $0.state = .paused; $0.log(.info, "Paused between sessions.") }
            stageText = "Paused. Resume re-checks safety and approval."
            await withCheckedContinuation { resumeContinuation = $0 }
            mutate { $0.state = .running }
            if stopAfterSessionRequested || abortRequested { return true }
        }
        return false
    }

    private func finish() async {
        guard var final = record else { return }
        if final.state != .haltedUncertainPrint && final.state != .interrupted {
            let allDone = final.sessions.count == final.plan.sessionCount && final.sessions.allSatisfy { $0.endedAt != nil }
            final.state = allDone && !stopAfterSessionRequested ? .completed : .stopped
        }
        final.endedAt = Date()
        final.latestFreeStorageBytes = QualificationResourceMonitor.freeStorageBytes()
        final.log(.info, "Run finished: \(final.state.rawValue). Verdict \(QualificationVerdict.evaluate(final).rawValue).")
        record = final
        persist()
        if let model = endToEndModel, model.state != .welcome, model.isCustomerResetSafe {
            model.resetAfterDone()
        }
        endToEndModel = nil
        authorization = nil
        currentSession = nil
        isRunning = false
        stageText = "Finished: \(QualificationVerdict.evaluate(final).rawValue)"
        history = store?.loadAll() ?? history
    }

    // MARK: Checkpoints

    private func runCheckpoints(after scenario: QualificationScenario, plan: QualificationPlan) async -> Bool {
        for checkpoint in scenario.checkpoints {
            switch checkpoint {
            case .photoPassDetailsAndSignature, .verifyFrozenArchive:
                continue // handled inside the session
            case .appBackgroundAndReturn where plan.mode == .endToEnd:
                continue // asked while the camera is ready, inside the session
            case .confirmPaperOutput:
                guard receiptsAwaitingPaper > 0 || !sessionsAwaitingPaper.isEmpty else { continue }
                let expected = receiptsAwaitingPaper
                mutate { $0.state = .awaitingCheckpoint }
                let response = await ask(OperatorPrompt(
                    session: scenario.sessionNumber,
                    kind: .checkpoint(.confirmPaperOutput),
                    title: checkpoint.title,
                    message: "\(checkpoint.instruction)\n\nThe app sent \(expected) receipt\(expected == 1 ? "" : "s") since the last check (sessions \(sessionsAwaitingPaper.map(String.init).joined(separator: ", "))).",
                    expectedReceipts: expected
                ))
                if case .paperCount(let observed) = response {
                    resolvePaper(observed: observed, expected: expected, session: scenario.sessionNumber)
                } else if response == .stopRun {
                    return false
                } else {
                    mutate { $0.log(.checkpoint, session: scenario.sessionNumber, "Paper confirmation skipped; affected sessions stay unverified.") }
                }
                mutate { $0.state = .running }
            case .printerPowerCycleBetweenSessions, .appRelaunch, .galleryDeliveryAttestation, .appBackgroundAndReturn:
                mutate { $0.state = .awaitingCheckpoint }
                let response = await ask(OperatorPrompt(session: scenario.sessionNumber, kind: .checkpoint(checkpoint), title: checkpoint.title, message: checkpoint.instruction))
                if response == .stopRun { return false }
                acknowledge(checkpoint, session: scenario.sessionNumber, response: response)
                mutate { $0.state = .running }
            }
        }
        return !abortRequested
    }

    private func acknowledge(_ checkpoint: QualificationCheckpoint, session: Int, response: OperatorResponse) {
        mutate {
            if response == .acknowledged {
                $0.acknowledgedCheckpoints.append(QualificationVerdict.checkpointKey(session: session, checkpoint))
                $0.log(.checkpoint, session: session, "\(checkpoint.title): operator confirmed.")
            } else {
                $0.log(.checkpoint, session: session, "\(checkpoint.title): skipped; remains unverified.")
            }
        }
    }

    private func resolvePaper(observed: Int, expected: Int, session: Int) {
        let pending = sessionsAwaitingPaper
        mutate { record in
            for number in pending {
                guard let index = record.sessions.firstIndex(where: { $0.sessionNumber == number }) else { continue }
                let copies = record.sessions[index].printJobsCompleted
                record.sessions[index].physicalConfirmation = observed == expected
                    ? .confirmed(receipts: copies)
                    : .mismatch(expected: expected, observed: observed)
            }
            if observed == expected {
                record.physicalReceiptsConfirmed += observed
                record.log(.checkpoint, session: session, "Operator confirmed \(observed) receipts on paper.")
            } else {
                record.log(.correctness, session: session, "Paper count mismatch: app sent \(expected), operator counted \(observed).")
            }
        }
        receiptsAwaitingPaper = 0
        sessionsAwaitingPaper = []
    }

    private func ask(_ newPrompt: OperatorPrompt) async -> OperatorResponse {
        if abortRequested { return .stopRun }
        stageText = "Waiting for operator: \(newPrompt.title)"
        return await withCheckedContinuation { continuation in
            promptContinuation = continuation
            prompt = newPrompt
        }
    }

    // MARK: Modes A and B

    private func runSyntheticSession(_ scenario: QualificationScenario, plan: QualificationPlan) async -> Bool {
        guard let store, let runID = record?.runID else { return false }
        var result = beginSession(scenario)
        let runCode = String(runID.uuidString.prefix(4))
        let label = plan.mode == .simulation ? "SIMULATION" : "PRINTER ENDURANCE"
        let sessionID = Self.sessionIdentifier(runCode: runCode, session: scenario.sessionNumber, date: Date())
        result.boothSessionIdentifier = sessionID

        stage(&result, "Generating watermarked diagnostic photos")
        let format = scenario.format
        let photos = (0..<format.photoCount).map { index in
            QualificationDiagnosticPhoto.storedCapture(
                QualificationDiagnosticPhoto.make(runCode: runCode, session: scenario.sessionNumber, photoIndex: index, photoCount: format.photoCount, label: label),
                format: format
            )
        }
        result.captureAttempts = photos.count
        checkPhotos(photos, format: format, into: &result)

        stage(&result, "Composing receipt")
        let eventProfile = currentEventProfile.normalized().activeReceiptSnapshot
        let passport: PassportSessionData? = format == .passport ? Self.diagnosticPassport() : nil
        let token: String
        let galleryURL: URL
        do {
            token = try GalleryTokenGenerator.makeGalleryToken()
            galleryURL = try GalleryURLBuilder.makeGalleryURL(customerGalleryBaseURL: CustomerGalleryConfiguration.load().baseURL, galleryToken: token)
        } catch {
            return failSession(&result, "Diagnostic session identity could not be created: \(error.localizedDescription)")
        }
        let date = Date()
        let printOptions = ReceiptPrintSettingsStore.load()
        let composed: (ComposedReceipt, ThermalRasterizedImage)
        do {
            composed = try await Task.detached(priority: .userInitiated) {
                let receipt = try ReceiptComposer.compose(photos: photos, sessionIdentifier: sessionID, date: date, galleryURL: galleryURL, format: format, eventProfile: eventProfile, passport: passport, printOptions: printOptions)
                guard let image = UIImage(data: receipt.imagePNGData) else { throw ReceiptComposerError.renderFailed }
                return (receipt, try ThermalImageRasterizer.rasterize(image, purpose: .completeReceipt))
            }.value
        } catch {
            return failSession(&result, "Receipt composition failed: \(error.localizedDescription)")
        }
        checkRaster(composed.1, into: &result)

        stage(&result, "Archiving to the diagnostic namespace")
        let committed = CommittedGallerySession(sessionIdentifier: sessionID, createdAt: date, galleryToken: token, galleryURL: galleryURL, photos: photos, format: format, eventProfile: eventProfile, passport: passport, printOptions: printOptions)
        do {
            let archive = try BoothSessionEnvironment.makeArchiveStore(directory: store.archiveDirectory(for: runID))
            try archive.save(RecentSessionArchivePayload(committedSession: committed, composedReceipt: composed.0, receiptPreviewPNGData: composed.0.imagePNGData, thermalPreviewPNGData: composed.1.previewPNGData, rasterizedImage: composed.1, photoThumbnailData: []))
            archivedSessions[scenario.sessionNumber] = (token, result.receiptFingerprint ?? "", eventProfile?.eventName ?? "")
        } catch {
            return failSession(&result, "Diagnostic archive failed; nothing printed: \(error.localizedDescription)")
        }
        verifyFrozenArchiveIfNeeded(scenario, into: &result)

        if scenario.category == .highFrequency, plan.mode == .simulation {
            stage(&result, "Probing stale callbacks on the production state machine")
            await probeStaleCallbacks(into: &result)
        }

        result.copiesRequested = scenario.plannedCopies
        let batchID = UUID()
        if plan.mode == .simulation {
            stage(&result, "Printing \(scenario.plannedCopies) cop\(scenario.plannedCopies == 1 ? "y" : "ies") to the mock transport")
            await simulatePrint(composed.1, sessionID: sessionID, batchID: batchID, scenario: scenario, into: &result)
        } else {
            let continueRun = await printPhysically(composed.1, sessionID: sessionID, batchID: batchID, scenario: scenario, into: &result)
            guard continueRun else { return false }
        }

        return endSession(&result)
    }

    private static func diagnosticPassport() -> PassportSessionData {
        var passport = PassportSessionData(configuration: PassportConfiguration.effective(for: nil))
        passport.name = "Qualification"
        passport.notes = "Diagnostic receipt"
        // A deterministic diagnostic signature (debug fixtures are not compiled into release).
        if let stroke = PassportSignature.stroke(
            from: [CGPoint(x: 20, y: 70), CGPoint(x: 90, y: 30), CGPoint(x: 160, y: 75), CGPoint(x: 240, y: 35), CGPoint(x: 320, y: 70)],
            canvasSize: CGSize(width: 400, height: 100)
        ) {
            passport.signature = PassportSignature.empty.appending(stroke)
        }
        return passport.committed(at: Date())
    }

    private func simulatePrint(_ raster: ThermalRasterizedImage, sessionID: String, batchID: UUID, scenario: QualificationScenario, into result: inout QualificationSessionResult) async {
        guard let spooler = simulationSpooler else { return }
        let injectFault = scenario.sessionNumber == injectedFaultSession
        var expectedFingerprint: String?
        for copy in 1...scenario.plannedCopies {
            guard let envelope = try? PrintJobEnvelope.receipt(rasterizedImage: raster, sessionIdentifier: sessionID, source: .diagnostic, copyIndex: copy, copyCount: scenario.plannedCopies, batchID: batchID, transportPolicy: .safeIntegrity) else {
                result.violations.append("Print envelope could not be built for copy \(copy).")
                return
            }
            if let expectedFingerprint, expectedFingerprint != envelope.payloadFingerprint {
                result.violations.append("Copy \(copy) payload differs from copy 1.")
            }
            expectedFingerprint = envelope.payloadFingerprint
            result.printJobsRequested += 1
            let failThisCopy = injectFault && copy == 1
            let outcome = await spooler.submit(envelope: envelope) { _ in
                let transport = PhysicalPrintTransportResult(transport: .none, bluetoothMode: nil, chunkSize: nil, chunkCount: nil, flowControlPauseCount: nil, writeTimeout: nil, bytesStarted: true, transportFinishedAt: Date())
                if failThisCopy {
                    return .failure(PrintTransportFailure(underlyingError: ReliabilitySimulationError.injectedAfterBytes, bytesStarted: true, transportResult: transport))
                }
                return .success(transport)
            }
            switch outcome {
            case .success:
                result.printJobsCompleted += 1
                result.printAuditJobIDs.append(envelope.jobID)
            case .failure:
                guard failThisCopy else {
                    result.violations.append("Mock transport failed unexpectedly on copy \(copy).")
                    return
                }
                // The spooler must now lock recovery and refuse the next job.
                if !spooler.requiresRecovery {
                    result.violations.append("Injected after-bytes fault did not lock printer recovery.")
                }
                let retry = await spooler.submit(envelope: envelope) { _ in
                    .success(PhysicalPrintTransportResult(transport: .none, bluetoothMode: nil, chunkSize: nil, chunkCount: nil, flowControlPauseCount: nil, writeTimeout: nil, bytesStarted: true, transportFinishedAt: Date()))
                }
                if case .success = retry {
                    mutate { $0.unsafeRetryAttempts += 1 }
                    result.violations.append("A job was accepted after an uncertain print.")
                }
                result.notes.append("Injected after-bytes fault on copy 1: recovery locked and the copy was not resent. Simulated operator recovery confirmed; remaining copies skipped.")
                mutate { $0.log(.recovery, session: scenario.sessionNumber, "Simulated uncertain print locked recovery; no automatic resend.") }
                spooler.confirmPrinterRestarted()
                result.copiesRequested = result.printJobsCompleted
                return
            }
        }
    }

    // MARK: Physical printing (Mode B)

    private func printPhysically(_ raster: ThermalRasterizedImage, sessionID: String, batchID: UUID, scenario: QualificationScenario, into result: inout QualificationSessionResult) async -> Bool {
        var copy = 1
        while copy <= scenario.plannedCopies {
            if abortRequested {
                result.notes.append("Aborted before copy \(copy); nothing further was sent.")
                result.outcome = .interrupted
                result.lastStage = "Aborted before printing"
                result.endedAt = Date()
                commit(result)
                return false
            }
            stage(&result, "Checking print safety for copy \(copy) of \(scenario.plannedCopies)")
            guard await passPrintGate(session: scenario.sessionNumber, receiptsAfterJob: (record?.physicalReceiptsSent ?? 0) + 1, ignoringOwnSession: false) else {
                result.notes.append("Physical job blocked by a safety gate before copy \(copy).")
                return failSessionAndStop(&result, "Print blocked by safety gate.")
            }
            stage(&result, "Printing copy \(copy) of \(scenario.plannedCopies)")
            result.printJobsRequested += 1
            let session = scenario.sessionNumber
            let copyIndex = copy
            let copies = scenario.plannedCopies
            let outcome = await printer.printCopy(QualificationPrintRequest(
                rasterizedImage: raster,
                sessionIdentifier: sessionID,
                copyIndex: copy,
                copyCount: copies,
                batchID: batchID,
                prePrintCheckpoint: PrePrintCheckpointGate { [weak self] _ in
                    // Fail closed: no durable checkpoint, no bytes.
                    guard let self else { throw PrintCheckpointError.persistenceFailed("Qualification run ended.") }
                    try self.writeInFlightCheckpoint(QualificationInFlightPrint(session: session, copyIndex: copyIndex, copyCount: copies, batchID: batchID, startedAt: Date()))
                }
            ))
            switch outcome.status {
            case .completed:
                clearInFlightCheckpoint()
                result.printJobsCompleted += 1
                if let seconds = outcome.transportSeconds { result.transportSeconds.append(seconds) }
                mutate { $0.physicalReceiptsSent += 1 }
                receiptsAwaitingPaper += 1
                copy += 1
            case .uncertainAfterBytes:
                return haltUncertain(&result, outcome.message)
            case .failedBeforeBytes, .blockedByCheckpoint:
                clearInFlightCheckpoint()
                mutate { $0.log(.printer, session: session, "Copy \(copyIndex) failed before any bytes: \(outcome.message)") }
                let response = await ask(OperatorPrompt(
                    session: session,
                    kind: .printFailedBeforeBytes(outcome.message),
                    title: "Print failed before printing",
                    message: "\(outcome.message)\n\nNo bytes were sent, so retrying this copy is safe. Check the printer connection first."
                ))
                if response != .retry {
                    return failSessionAndStop(&result, "Copy \(copyIndex) failed before bytes and the operator ended the session.")
                }
                mutate { $0.log(.printer, session: session, "Operator retried copy \(copyIndex) after a failure before bytes.") }
            }
        }
        result.physicalConfirmation = .pending
        sessionsAwaitingPaper.append(scenario.sessionNumber)
        await reconcileAudit(sessionID: sessionID, expectedCopies: result.printJobsCompleted, into: &result)
        return true
    }

    /// Evaluates every physical safety condition. Blocks (and asks the operator) if any fails.
    private func passPrintGate(session: Int, receiptsAfterJob: Int, ignoringOwnSession: Bool) async -> Bool {
        while true {
            var snapshot = printer.safetySnapshot()
            if ignoringOwnSession { snapshot.customerSessionActive = false }
            let denial = authorization?.denial(runID: record?.runID ?? UUID(), planFingerprint: record?.plan.fingerprint ?? "", session: session, receiptsAfterJob: receiptsAfterJob)
            let violations = QualificationSafetyGate.violations(snapshot: snapshot, authorizationDenial: denial, hasAuthorization: authorization != nil, checkpointCommitted: store != nil)
            lastSafetyViolations = violations
            guard !violations.isEmpty else { return true }
            mutate { $0.log(.safetyBlock, session: session, "Physical job blocked: \(violations.map(\.message).joined(separator: " "))\(denial.map { " " + $0.message } ?? "")") }
            // Authorization problems never self-heal; recoverable hardware states can be retried.
            if violations.contains(.notAuthorized) && authorization == nil { return false }
            if let denial, case .printBudgetExceeded = denial { return false }
            if let denial, case .relaunched = denial { return false }
            let response = await ask(OperatorPrompt(
                session: session,
                kind: .physicalJobBlocked(violations),
                title: "Physical job blocked",
                message: violations.map(\.message).joined(separator: "\n") + "\n\nResolve the condition (use Printer Recovery if needed), then Retry."
            ))
            if response != .retry { return false }
        }
    }

    private func writeInFlightCheckpoint(_ inFlight: QualificationInFlightPrint) throws {
        guard var updated = record, let store else {
            throw PrintCheckpointError.persistenceFailed("Qualification store unavailable.")
        }
        updated.inFlightPrint = inFlight
        do {
            try store.save(updated)
        } catch {
            throw PrintCheckpointError.persistenceFailed(error.localizedDescription)
        }
        record = updated
    }

    private func clearInFlightCheckpoint() {
        mutate { $0.inFlightPrint = nil }
    }

    private func haltUncertain(_ result: inout QualificationSessionResult, _ message: String) -> Bool {
        result.outcome = .uncertainPrint
        result.lastStage = "Print status unknown — halted"
        result.endedAt = Date()
        result.notes.append("Bytes may have started without confirmed completion: \(message). Not resent.")
        commit(result)
        // inFlightPrint stays recorded until the operator inspects the printer.
        mutate {
            $0.state = .haltedUncertainPrint
            $0.log(.printer, session: result.sessionNumber, "Uncertain print: run halted for physical inspection. No automatic resend.")
        }
        stageText = "Halted: inspect the printer. Use Printer Recovery, then acknowledge."
        return false
    }

    private func reconcileAudit(sessionID: String, expectedCopies: Int, into result: inout QualificationSessionResult) async {
        let deadline = Date().addingTimeInterval(auditSettleTimeout)
        var records = printer.auditRecords(sessionIdentifier: sessionID)
        while records.filter({ $0.terminalResult == .completed }).count < expectedCopies, Date() < deadline {
            try? await Task.sleep(for: pollInterval)
            records = printer.auditRecords(sessionIdentifier: sessionID)
        }
        result.printAuditJobIDs = records.map(\.jobID)
        let completed = records.filter { $0.terminalResult == .completed }
        if Set(records.map(\.jobID)).count != records.count || completed.count > expectedCopies {
            mutate { $0.duplicatePrintDetections += 1 }
            result.violations.append("Print audit shows \(completed.count) completed jobs for \(expectedCopies) copies (duplicate or unexpected print).")
        } else if completed.count < expectedCopies {
            result.notes.append("Print audit recorded \(completed.count) of \(expectedCopies) completions within \(Int(auditSettleTimeout))s.")
        }
        if let lock = records.firstIndex(where: { $0.terminalResult == .recoveryRequiredAfterBytes }), lock < records.count - 1 {
            mutate { $0.unsafeRetryAttempts += 1 }
            result.violations.append("A job ran after an uncertain print for this session.")
        }
        if result.transportSeconds.isEmpty {
            result.transportSeconds = completed.compactMap(\.transportDuration)
        }
    }

    // MARK: Mode C

    private func runEndToEndSession(_ scenario: QualificationScenario, plan: QualificationPlan) async -> Bool {
        guard let model = endToEndModel else { return false }
        var result = beginSession(scenario)

        stage(&result, "Checking the booth is idle")
        guard model.state == .welcome else {
            return failSessionAndStop(&result, "Booth was not at Welcome before the session (\(model.state)).")
        }
        if printer.safetySnapshot().customerSessionActive {
            return failSessionAndStop(&result, "A customer session is active; qualification will not take over the booth.")
        }

        model.startSession()
        guard await waitFor(timeout: 5, { model.state == .choosingFormat }) else {
            return failSessionAndStop(&result, "Booth did not start a session (\(model.state)).")
        }
        stage(&result, "Starting front camera")
        model.selectBoothFormat(scenario.format)
        result.boothSessionIdentifier = model.sessionIdentifier
        let galleryToken = model.galleryToken
        guard await waitFor(timeout: 20, { model.state == .cameraReady || Self.isError(model.state) }) else {
            return failSession(&result, "Camera did not become ready within 20 s.", model: model)
        }
        if model.isCameraUnavailable || Self.isError(model.state) {
            result.captureFailures += 1
            // Never substitute sample photos for a real capture; without a camera Mode C stops.
            return failSessionAndStop(&result, "Front camera unavailable: \(model.statusMessage)", model: model)
        }

        if scenario.checkpoints.contains(.appBackgroundAndReturn) {
            let response = await ask(OperatorPrompt(session: scenario.sessionNumber, kind: .checkpoint(.appBackgroundAndReturn), title: QualificationCheckpoint.appBackgroundAndReturn.title, message: QualificationCheckpoint.appBackgroundAndReturn.instruction))
            acknowledge(.appBackgroundAndReturn, session: scenario.sessionNumber, response: response)
            guard await waitFor(timeout: 20, { model.state == .cameraReady && model.canBeginPhotos }) else {
                return failSession(&result, "Camera did not recover after background/foreground.", model: model)
            }
        }

        stage(&result, "Capturing \(scenario.format.photoCount) photo\(scenario.format.photoCount == 1 ? "" : "s") with the front camera")
        result.captureAttempts = scenario.format.photoCount
        model.beginPhotoSequence()
        let captureTimeout = Double(scenario.format.photoCount) * (Double(BoothConfiguration.countdownSeconds) + BoothConfiguration.interPhotoDelay + BoothConfiguration.capturedPhotoDisplayDuration + 4) + 20
        guard await waitFor(timeout: captureTimeout, { model.state == .review || Self.isError(model.state) }), model.state == .review else {
            result.captureFailures += 1
            return failSession(&result, "Capture did not complete: \(model.statusMessage)", model: model)
        }
        checkIdentity(model, expected: result.boothSessionIdentifier, into: &result)
        checkPhotos(model.capturedPhotos, format: scenario.format, into: &result)
        if model.capturedPhotos.count != scenario.expectedPhotoCount {
            result.violations.append("Captured \(model.capturedPhotos.count) photos; expected \(scenario.expectedPhotoCount).")
        }

        if scenario.format.usesPassportFlow {
            model.continueFromReview()
            stage(&result, "Waiting for Photo Pass details and signature on the booth screen")
            let completed = await waitForBoothInteraction(session: scenario.sessionNumber) { model.state == .passportPreview }
            guard completed else {
                return failSession(&result, "Photo Pass details/signature were not completed.", model: model)
            }
            acknowledge(.photoPassDetailsAndSignature, session: scenario.sessionNumber, response: .acknowledged)
        }

        stage(&result, "Composing receipt (production pipeline)")
        model.continueToReceipt()
        guard await waitFor(timeout: 60, { model.state == .receiptPreview || Self.isError(model.state) }), model.state == .receiptPreview,
              let raster = model.receiptRasterizedImage, let receipt = model.composedReceipt else {
            return failSession(&result, "Receipt composition failed: \(model.statusMessage)", model: model)
        }
        checkIdentity(model, expected: result.boothSessionIdentifier, into: &result)
        if receipt.sessionIdentifier != result.boothSessionIdentifier || receipt.format != scenario.format {
            result.violations.append("Composed receipt belongs to \(receipt.sessionIdentifier)/\(receipt.format.rawValue), not this session.")
        }
        checkRaster(raster, into: &result)
        if let galleryToken {
            archivedSessions[scenario.sessionNumber] = (galleryToken, result.receiptFingerprint ?? "", currentEventProfile.normalized().activeReceiptSnapshot?.eventName ?? "")
        }

        result.copiesRequested = scenario.plannedCopies
        let sentBefore = record?.physicalReceiptsSent ?? 0
        guard await passPrintGate(session: scenario.sessionNumber, receiptsAfterJob: sentBefore + scenario.plannedCopies, ignoringOwnSession: true) else {
            return failSessionAndStop(&result, "Print blocked by a safety gate.", model: model)
        }
        do {
            try writeInFlightCheckpoint(QualificationInFlightPrint(session: scenario.sessionNumber, copyIndex: 1, copyCount: scenario.plannedCopies, batchID: UUID(), startedAt: Date()))
        } catch {
            return failSessionAndStop(&result, "Pre-print checkpoint could not be saved; nothing printed.", model: model)
        }

        var remaining = scenario.plannedCopies
        var printed = 0
        while remaining > 0 {
            stage(&result, "Printing \(remaining) cop\(remaining == 1 ? "y" : "ies") through the production booth")
            result.printJobsRequested += remaining
            model.selectedPrintCopies = remaining
            model.printReceipt(host: printer.wifiHost, port: printer.wifiPort)
            let printTimeout = Double(remaining) * 120 + 30
            _ = await waitFor(timeout: printTimeout) {
                !model.isPrintBatchActive && (model.state == .thankYou || model.state == .receiptPreview || Self.isRecovery(model.state) || Self.isError(model.state))
            }
            printed += model.completedPrintCopies
            if model.state == .thankYou {
                remaining = 0
                break
            }
            if Self.isRecovery(model.state) || model.isPrintBatchActive {
                result.printJobsCompleted = printed
                mutate { $0.physicalReceiptsSent += printed }
                return haltUncertain(&result, model.statusMessage)
            }
            // Failure before bytes: the booth stayed on the preview; retrying is safe.
            remaining -= model.completedPrintCopies
            mutate { $0.log(.printer, session: scenario.sessionNumber, "Print stopped before bytes after \(printed) copies: \(model.statusMessage)") }
            let response = await ask(OperatorPrompt(session: scenario.sessionNumber, kind: .printFailedBeforeBytes(model.statusMessage), title: "Print failed before printing", message: "\(model.statusMessage)\n\n\(printed) of \(scenario.plannedCopies) copies printed. No bytes were sent for the failed copy, so printing the remaining \(remaining) is safe."))
            guard response == .retry else {
                clearInFlightCheckpoint()
                result.printJobsCompleted = printed
                mutate { $0.physicalReceiptsSent += printed }
                return failSession(&result, "Print failed before bytes; operator ended the session.", model: model)
            }
            guard await passPrintGate(session: scenario.sessionNumber, receiptsAfterJob: sentBefore + printed + remaining, ignoringOwnSession: true) else {
                clearInFlightCheckpoint()
                return failSessionAndStop(&result, "Retry blocked by a safety gate.", model: model)
            }
        }
        clearInFlightCheckpoint()
        result.printJobsCompleted = printed
        mutate { $0.physicalReceiptsSent += printed }
        receiptsAwaitingPaper += printed
        if printed != scenario.plannedCopies {
            result.violations.append("Printed \(printed) copies; planned \(scenario.plannedCopies).")
        }
        result.physicalConfirmation = .pending
        sessionsAwaitingPaper.append(scenario.sessionNumber)
        if let sessionID = result.boothSessionIdentifier {
            await reconcileAudit(sessionID: sessionID, expectedCopies: printed, into: &result)
        }

        stage(&result, "Verifying diagnostic archive")
        if let store, let runID = record?.runID, let galleryToken {
            let archive = try? BoothSessionEnvironment.makeArchiveStore(directory: store.archiveDirectory(for: runID))
            if archive?.containsCommittedArchive(galleryToken: galleryToken) != true {
                result.violations.append("Session was printed without a committed diagnostic archive.")
            }
        }
        verifyFrozenArchiveIfNeeded(scenario, into: &result)

        stage(&result, "Resetting the booth")
        model.resetAfterDone()
        guard await waitFor(timeout: 5, { model.state == .welcome }) else {
            return failSession(&result, "Booth did not return to Welcome after the session.", model: model)
        }
        if !model.capturedPhotos.isEmpty || model.sessionIdentifier != nil || model.galleryToken != nil
            || model.receiptRasterizedImage != nil || model.selectedPrintCopies != 1 || model.passportDraft != .empty {
            result.violations.append("Reset left session data behind (photos, identity, receipt, copies or Photo Pass details).")
        }
        let restarts = cameraRestartCount() - cameraRestartBaseline
        mutate { $0.cameraInterruptions = max($0.cameraInterruptions, restarts) }
        return endSession(&result)
    }

    private func waitForBoothInteraction(session: Int, until condition: @escaping @MainActor () -> Bool) async -> Bool {
        prompt = OperatorPrompt(session: session, kind: .boothInteraction(.photoPassDetailsAndSignature), title: QualificationCheckpoint.photoPassDetailsAndSignature.title, message: QualificationCheckpoint.photoPassDetailsAndSignature.instruction)
        mutate { $0.state = .awaitingCheckpoint }
        defer {
            prompt = nil
            mutate { $0.state = .running }
        }
        while !condition() {
            if abortRequested { return false }
            try? await Task.sleep(for: pollInterval)
        }
        return true
    }

    private static func isError(_ state: BoothSessionState) -> Bool {
        if case .error = state { return true }
        return false
    }

    private static func isRecovery(_ state: BoothSessionState) -> Bool {
        if case .recoveryRequired = state { return true }
        return false
    }

    private func waitFor(timeout: TimeInterval, _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline || abortRequested { return condition() }
            try? await Task.sleep(for: pollInterval)
        }
        return true
    }

    // MARK: Correctness checks

    private func checkPhotos(_ photos: [UIImage], format: BoothFormat, into result: inout QualificationSessionResult) {
        var orientationOK = true
        for (index, photo) in photos.enumerated() {
            let fingerprint = QualificationFingerprint.photo(photo)
            result.photoFingerprints.append(fingerprint)
            if let earlier = seenPhotoFingerprints[fingerprint], earlier != result.sessionNumber {
                result.violations.append("Photo \(index + 1) is identical to a photo from session \(earlier) (stale or wrong-session photograph).")
            }
            seenPhotoFingerprints[fingerprint] = result.sessionNumber
            if !QualificationFingerprint.orientationIsConsistent(stored: photo, format: format, photoIndex: index) {
                orientationOK = false
                result.violations.append("Photo \(index + 1) framing does not match the approved \(QualificationPlanner.orientationDescription(format: format, photoIndex: index)) crop.")
            }
        }
        if Set(result.photoFingerprints).count != result.photoFingerprints.count {
            result.violations.append("Two photos in this session are identical.")
        }
        result.orientationChecksPassed = orientationOK
    }

    private func checkRaster(_ raster: ThermalRasterizedImage, into result: inout QualificationSessionResult) {
        let fingerprint = RecentSessionArchiveStore.rasterFingerprint(for: raster)
        result.receiptFingerprint = fingerprint
        if let earlier = seenRasterFingerprints[fingerprint], earlier != result.sessionNumber {
            result.violations.append("Receipt raster matches session \(earlier) (cross-session contamination).")
        }
        seenRasterFingerprints[fingerprint] = result.sessionNumber
    }

    private func checkIdentity(_ model: BoothSessionViewModel, expected: String?, into result: inout QualificationSessionResult) {
        if model.sessionIdentifier != expected {
            result.violations.append("Session identity changed from \(expected ?? "nil") to \(model.sessionIdentifier ?? "nil") mid-session.")
        }
    }

    private func verifyFrozenArchiveIfNeeded(_ scenario: QualificationScenario, into result: inout QualificationSessionResult) {
        guard let earlier = scenario.verifiesArchiveOfSession else { return }
        guard let store, let runID = record?.runID, let frozen = archivedSessions[earlier] else {
            result.violations.append("Frozen archive of session \(earlier) is unavailable for comparison.")
            return
        }
        do {
            let archive = try BoothSessionEnvironment.makeArchiveStore(directory: store.archiveDirectory(for: runID)).load(archiveID: frozen.token)
            let fingerprint = RecentSessionArchiveStore.rasterFingerprint(for: archive.rasterizedImage)
            let eventName = archive.eventProfile?.eventName ?? ""
            if fingerprint != frozen.fingerprint || eventName != frozen.eventName || archive.summary.rasterFingerprint != frozen.fingerprint {
                result.violations.append("Session \(earlier)'s archive changed after the configuration change.")
            } else if eventName == (currentEventProfile.normalized().activeReceiptSnapshot?.eventName ?? "") {
                result.violations.append("Configuration change was not applied to session \(scenario.sessionNumber); the comparison proves nothing.")
            } else {
                result.notes.append("Session \(earlier)'s archive is unchanged (\(frozen.eventName)) after switching to \(currentEventProfile.eventName).")
                mutate { $0.log(.correctness, session: scenario.sessionNumber, "Frozen archive of session \(earlier) verified unchanged.") }
            }
        } catch {
            result.violations.append("Frozen archive of session \(earlier) could not be loaded: \(error.localizedDescription)")
        }
    }

    /// Exercises the production state machine: a confirmation from a cancelled session must
    /// never advance the next session.
    private func probeStaleCallbacks(into result: inout QualificationSessionResult) async {
        guard let store, let runID = record?.runID else { return }
        var environment = BoothSessionEnvironment.customer
        environment.purpose = .hardwareQualification(runID: runID.uuidString)
        environment.archiveDirectory = store.archiveDirectory(for: runID)
        environment.recoveryDirectory = store.recoveryDirectory(for: runID)
        environment.deliversGallery = false
        environment.recordsCustomerSessionMetrics = false
        environment.printSource = .diagnostic
        environment.eventProfileSource = { QualificationEventProfiles.disabled }
        // Session A's confirmation ends quickly; session B's stays on screen. If A's stale
        // confirmation were applied it would dismiss B's photo and jump B to review.
        let pauses = ConfirmationPauseCounter()
        let model = BoothSessionViewModel(environment: environment, captureConfirmationPause: {
            let call = pauses.next()
            try? await Task.sleep(for: .milliseconds(call == 1 ? 20 : 400))
        })
        model.selectedBoothFormat = .duo
        model.isCameraUnavailable = true
        model.state = .cameraReady
        model.addSamplePhoto(QualificationDiagnosticPhoto.make(runCode: "PROBE", session: result.sessionNumber, photoIndex: 0, photoCount: 2, label: "STATE PROBE A"))
        model.cancelSession()
        model.selectedBoothFormat = .solo
        model.isCameraUnavailable = true
        model.state = .cameraReady
        model.addSamplePhoto(QualificationDiagnosticPhoto.make(runCode: "PROBE", session: result.sessionNumber, photoIndex: 0, photoCount: 1, label: "STATE PROBE B"))
        try? await Task.sleep(for: .milliseconds(120))
        let isolated = model.transientCapturedPhoto != nil && model.state == .cameraReady && model.capturedPhotos.count == 1
        if isolated {
            mutate { $0.staleCallbackRejections += 1 }
        } else {
            mutate { $0.staleCallbackViolations += 1 }
            result.violations.append("A cancelled session's confirmation changed the next session.")
        }
        model.cancelSession()
    }

    // MARK: Session bookkeeping

    private func beginSession(_ scenario: QualificationScenario) -> QualificationSessionResult {
        let result = QualificationSessionResult(sessionNumber: scenario.sessionNumber, qualificationSessionID: UUID(), format: scenario.format, category: scenario.category, startedAt: Date())
        mutate { $0.sessions.append(result) }
        stageText = "Session \(scenario.sessionNumber): starting"
        return result
    }

    private func stage(_ result: inout QualificationSessionResult, _ text: String) {
        result.lastStage = text
        stageText = "Session \(result.sessionNumber): \(text)"
        commit(result, persistNow: false)
    }

    private func endSession(_ result: inout QualificationSessionResult) -> Bool {
        result.endedAt = Date()
        result.outcome = result.violations.isEmpty ? .passed : .failed
        result.lastStage = result.outcome == .passed ? "Completed" : "Completed with violations"
        result.memoryMegabytesAtEnd = QualificationResourceMonitor.memoryFootprintMegabytes()
        commit(result)
        return !abortRequested
    }

    private func failSession(_ result: inout QualificationSessionResult, _ reason: String, model: BoothSessionViewModel? = nil) -> Bool {
        result.violations.append(reason)
        result.outcome = .failed
        result.lastStage = "Failed"
        result.endedAt = Date()
        commit(result)
        mutate { $0.log(.correctness, session: result.sessionNumber, reason) }
        // cancelSession refuses while a print is active or unresolved.
        model?.cancelSession()
        // A failed session does not by itself stop the run; operators decide via Stop.
        return !abortRequested
    }

    private func failSessionAndStop(_ result: inout QualificationSessionResult, _ reason: String, model: BoothSessionViewModel? = nil) -> Bool {
        _ = failSession(&result, reason, model: model)
        stopAfterSessionRequested = true
        return false
    }

    private func commit(_ result: QualificationSessionResult, persistNow: Bool = true) {
        guard var updated = record, let index = updated.sessions.lastIndex(where: { $0.sessionNumber == result.sessionNumber }) else { return }
        updated.sessions[index] = result
        record = updated
        if persistNow { persist() }
    }

    private func mutate(_ change: (inout QualificationRunRecord) -> Void) {
        guard var updated = record else { return }
        change(&updated)
        record = updated
        persist()
    }

    private func persist() {
        guard let record, let store else { return }
        try? store.save(record)
    }

    private func sampleResources() {
        currentMemoryMegabytes = QualificationResourceMonitor.memoryFootprintMegabytes()
        pendingGalleryUploads = pendingUploadCount()
        mutate {
            $0.peakMemoryMegabytes = max($0.peakMemoryMegabytes, currentMemoryMegabytes)
            $0.latestFreeStorageBytes = QualificationResourceMonitor.freeStorageBytes()
        }
    }
}

@MainActor
private final class ConfirmationPauseCounter {
    private var count = 0

    func next() -> Int {
        count += 1
        return count
    }
}

enum ReliabilitySimulationError: Error, LocalizedError {
    case injectedAfterBytes

    var errorDescription: String? {
        "Simulated transport fault after bytes started."
    }
}
