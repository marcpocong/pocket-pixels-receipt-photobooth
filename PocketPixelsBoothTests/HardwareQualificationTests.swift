import Foundation
import UIKit
import XCTest
@testable import PocketPixelsBooth

/// Hardware qualification rules, verified with a fake printer and temporary stores. Nothing in
/// this suite can reach a physical printer, the camera, or a customer gallery.
@MainActor
final class HardwareQualificationTests: XCTestCase {
    private var root: URL!
    private var store: HardwareQualificationStore!
    private var printer: FakeQualificationPrinter!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("qualification-\(UUID().uuidString)", isDirectory: true)
        store = try HardwareQualificationStore(rootURL: root)
        printer = FakeQualificationPrinter()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeEngine() -> HardwareQualificationEngine {
        HardwareQualificationEngine(
            store: store,
            printer: printer,
            makeSessionModel: { _ in
                XCTFail("Mode C must not start in unit tests")
                return BoothSessionViewModel.immediateConfirmation()
            },
            pendingUploadCount: { 0 },
            cameraRestartCount: { 0 },
            pollInterval: .milliseconds(5),
            auditSettleTimeout: 0.2
        )
    }

    private func physicalConfiguration(sessions: Int, batch: Int = 10) -> HardwareQualificationEngine.Configuration {
        var configuration = HardwareQualificationEngine.Configuration()
        configuration.mode = .physicalPrinterEndurance
        configuration.sessionCount = sessions
        configuration.batchSize = batch
        configuration.paperStock = "Test 58mm"
        return configuration
    }

    /// Answers prompts like a careful operator until the run ends.
    private func drive(
        _ engine: HardwareQualificationEngine,
        respond: @escaping (HardwareQualificationEngine.OperatorPrompt) -> HardwareQualificationEngine.OperatorResponse? = HardwareQualificationTests.carefulOperator
    ) async {
        let deadline = Date().addingTimeInterval(240)
        while engine.isRunning, Date() < deadline {
            if let prompt = engine.prompt, let response = respond(prompt) {
                engine.respond(response)
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(engine.isRunning, "Run did not finish in time")
    }

    nonisolated static func carefulOperator(_ prompt: HardwareQualificationEngine.OperatorPrompt) -> HardwareQualificationEngine.OperatorResponse? {
        switch prompt.kind {
        case .batchApproval: .approveNextBatch
        case .checkpoint(.confirmPaperOutput): .paperCount(prompt.expectedReceipts ?? 0)
        case .checkpoint: .acknowledged
        case .physicalJobBlocked, .printFailedBeforeBytes: .stopRun
        case .boothInteraction: nil
        }
    }

    // MARK: 1. Default is simulation and never prints

    func testDefaultConfigurationIsSimulationAndNeverTouchesThePrinter() async throws {
        let configuration = HardwareQualificationEngine.Configuration()
        XCTAssertEqual(configuration.mode, .simulation)
        XCTAssertFalse(configuration.mode.usesPhysicalPrinter)

        var short = configuration
        short.sessionCount = 6
        let engine = makeEngine()
        XCTAssertNil(engine.record, "Opening the screen creates nothing")
        try engine.start(short, approvedByOperator: false)
        XCTAssertNil(engine.authorization, "Simulation never holds physical authorization")
        await drive(engine)

        let record = try XCTUnwrap(engine.record)
        XCTAssertEqual(printer.bytesSentJobs.count, 0, "Simulation must never reach the physical printer")
        XCTAssertEqual(printer.snapshotRequests > 0, true)
        XCTAssertEqual(record.state, .completed)
        XCTAssertEqual(record.passedSessionCount, 6, record.sessions.flatMap(\.violations).joined(separator: "\n"))
        XCTAssertEqual(record.physicalReceiptsSent, 0)
        XCTAssertEqual(Set(record.sessions.map(\.format)), Set(BoothFormat.allCases), "Six sessions cover all six formats")
        XCTAssertEqual(QualificationVerdict.evaluate(record), .simulationOnly)
    }

    // MARK: 2–3. Approval

    func testPhysicalRunNeverStartsWithoutExplicitApproval() throws {
        let engine = makeEngine()
        XCTAssertThrowsError(try engine.start(physicalConfiguration(sessions: 6), approvedByOperator: false)) { error in
            XCTAssertEqual(error as? HardwareQualificationEngine.StartError, .physicalApprovalRequired)
        }
        XCTAssertThrowsError(try engine.start(physicalConfiguration(sessions: 6), approvedByOperator: true, expectedPlanFingerprint: "stale")) { error in
            XCTAssertEqual(error as? HardwareQualificationEngine.StartError, .approvalMismatch)
        }
        XCTAssertFalse(engine.isRunning)
        XCTAssertTrue(store.loadAll().isEmpty, "A refused start leaves no run behind")
        XCTAssertTrue(printer.bytesSentJobs.isEmpty)
    }

    func testAuthorizationIsBoundToRunPlanLaunchBatchAndBudget() {
        let runID = UUID()
        let approval = QualificationAuthorization(runID: runID, planFingerprint: "PLAN", launchID: QualificationLaunch.current, approvedThroughSession: 10, approvedPhysicalReceipts: 12, approvedAt: Date())
        XCTAssertNil(approval.denial(runID: runID, planFingerprint: "PLAN", session: 10, receiptsAfterJob: 12))
        XCTAssertEqual(approval.denial(runID: UUID(), planFingerprint: "PLAN", session: 1, receiptsAfterJob: 1), .differentRun)
        XCTAssertEqual(approval.denial(runID: runID, planFingerprint: "OTHER", session: 1, receiptsAfterJob: 1), .planChanged)
        XCTAssertEqual(approval.denial(runID: runID, planFingerprint: "PLAN", session: 11, receiptsAfterJob: 1), .sessionBeyondApprovedBatch(11))
        XCTAssertEqual(approval.denial(runID: runID, planFingerprint: "PLAN", session: 3, receiptsAfterJob: 13), .printBudgetExceeded(requested: 13, approved: 12))
        XCTAssertEqual(approval.denial(runID: runID, planFingerprint: "PLAN", session: 1, receiptsAfterJob: 1, launchID: UUID()), .relaunched)
    }

    func testApprovalCoversOnlyTheFirstBatchUntilRenewed() async throws {
        let engine = makeEngine()
        let configuration = physicalConfiguration(sessions: 12, batch: 4)
        let plan = engine.plan(for: configuration)
        try engine.start(configuration, approvedByOperator: true, expectedPlanFingerprint: plan.fingerprint)
        let firstWindow = HardwareQualificationEngine.approvalWindow(for: plan, after: 0)
        XCTAssertEqual(engine.authorization?.approvedThroughSession, firstWindow.throughSession)
        XCTAssertEqual(engine.authorization?.approvedPhysicalReceipts, firstWindow.receipts)

        // The operator declines the next batch: nothing beyond the approved budget prints.
        await drive(engine) { prompt in
            if case .batchApproval = prompt.kind { return .stopRun }
            return Self.carefulOperator(prompt)
        }
        XCTAssertEqual(printer.bytesSentJobs.count, firstWindow.receipts)
        let record = try XCTUnwrap(engine.record)
        XCTAssertEqual(record.state, .stopped)
        XCTAssertNotEqual(QualificationVerdict.evaluate(record), .pass)
        XCTAssertNil(engine.authorization, "Approval ends with the run")
    }

    // MARK: 4–6. Planning, identities, copies vs jobs

    func testHundredSessionPlanIsDeterministicBalancedAndCoversEveryScenario() {
        let plan = QualificationPlanner.makePlan(mode: .endToEnd)
        XCTAssertEqual(plan, QualificationPlanner.makePlan(mode: .endToEnd))
        XCTAssertEqual(plan.fingerprint, QualificationPlanner.makePlan(mode: .endToEnd).fingerprint)
        XCTAssertEqual(plan.sessionCount, 100)
        XCTAssertEqual(plan.scenarios.map(\.sessionNumber), Array(1...100))
        for format in BoothFormat.allCases {
            XCTAssertTrue((16...17).contains(plan.formatDistribution[format] ?? 0), "\(format) has \(plan.formatDistribution[format] ?? 0) sessions")
        }
        XCTAssertEqual(Set(plan.scenarios.map(\.category)), Set(QualificationScenarioCategory.allCases))
        let printLoad = plan.scenarios.filter { $0.category == .printLoad }
        XCTAssertEqual(printLoad.map(\.plannedCopies).sorted(), QualificationPlan.printLoadCopyCounts.sorted())
        XCTAssertTrue(printLoad.allSatisfy(\.endsBatch), "Each print-load batch is checked separately")
        XCTAssertTrue(plan.scenarios.filter { $0.format == .passport }.allSatisfy { $0.checkpoints.contains(.photoPassDetailsAndSignature) })
        let configurationPair = plan.scenarios.filter { $0.verifiesArchiveOfSession != nil }
        XCTAssertEqual(configurationPair.count, 1)
        XCTAssertTrue(configurationPair.allSatisfy { $0.checkpoints.contains(.verifyFrozenArchive) })
        for scenario in plan.scenarios {
            XCTAssertEqual(scenario.expectedPhotoCount, scenario.format.photoCount)
            XCTAssertEqual(scenario.expectedCaptureOrientations.count, scenario.format.photoCount)
        }
        XCTAssertTrue(plan.scenarios.first { $0.format == .passport }?.expectedCaptureOrientations.last?.contains("rotated 90° CCW") == true)

        let reseeded = QualificationPlanner.makePlan(mode: .endToEnd, seed: 7)
        XCTAssertEqual(reseeded.formatDistribution, plan.formatDistribution, "Seed never changes the format balance")
        XCTAssertNotEqual(reseeded.fingerprint, plan.fingerprint)
        XCTAssertEqual(plan.plannedPrintJobs, plan.scenarios.reduce(0) { $0 + $1.plannedCopies })
        XCTAssertGreaterThan(plan.plannedPrintJobs, plan.sessionCount, "Multi-copy batches are jobs, not extra sessions")
    }

    func testHundredSimulatedSessionsHaveHundredDistinctIdentities() async throws {
        var configuration = HardwareQualificationEngine.Configuration()
        configuration.sessionCount = 100
        let engine = makeEngine()
        try engine.start(configuration, approvedByOperator: false)
        await drive(engine)
        let record = try XCTUnwrap(engine.record)
        XCTAssertEqual(record.sessions.count, 100)
        XCTAssertEqual(Set(record.sessions.map(\.qualificationSessionID)).count, 100)
        XCTAssertEqual(Set(record.sessions.compactMap(\.boothSessionIdentifier)).count, 100)
        XCTAssertEqual(Set(record.sessions.compactMap(\.receiptFingerprint)).count, 100, "Every receipt raster is unique")
        XCTAssertTrue(record.sessions.compactMap(\.boothSessionIdentifier).allSatisfy { $0.hasPrefix("QA-") }, "Diagnostic identities never look like customer sessions")
        XCTAssertEqual(record.passedSessionCount, 100, record.sessions.flatMap(\.violations).joined(separator: "\n"))
        XCTAssertEqual(record.staleCallbackViolations, 0)
        XCTAssertGreaterThan(record.staleCallbackRejections, 0, "High-frequency sessions probe stale callbacks")
        XCTAssertEqual(record.unsafeRetryAttempts, 0)
        XCTAssertTrue(record.sessions.contains { $0.notes.contains { $0.contains("Injected after-bytes fault") } })
        XCTAssertTrue(record.sessions.contains { $0.notes.contains { $0.contains("archive is unchanged") } }, "The configuration pair re-verified the frozen archive")
        XCTAssertEqual(QualificationVerdict.evaluate(record), .simulationOnly)
    }

    func testCopyCountsStaySeparateFromSessionCounts() async throws {
        let engine = makeEngine()
        let configuration = physicalConfiguration(sessions: 50, batch: 25)
        let plan = engine.plan(for: configuration)
        try engine.start(configuration, approvedByOperator: true, expectedPlanFingerprint: plan.fingerprint)
        await drive(engine)
        let record = try XCTUnwrap(engine.record)
        XCTAssertEqual(record.sessions.count, 50, "Multi-copy batches never add sessions")
        XCTAssertEqual(printer.bytesSentJobs.count, plan.plannedPrintJobs)
        XCTAssertEqual(record.physicalReceiptsSent, plan.plannedPrintJobs)
        XCTAssertEqual(printer.maximumConcurrentJobs, 1, "Back-to-back batches are serialized")
        for (session, scenario) in zip(record.sessions, plan.scenarios) {
            XCTAssertEqual(session.copiesRequested, scenario.plannedCopies)
            XCTAssertEqual(session.printJobsCompleted, scenario.plannedCopies)
            let jobs = printer.bytesSentJobs.filter { $0.sessionIdentifier == session.boothSessionIdentifier }
            XCTAssertEqual(jobs.count, scenario.plannedCopies)
            XCTAssertEqual(jobs.map(\.copyIndex), Array(1...scenario.plannedCopies))
            XCTAssertEqual(Set(jobs.map(\.batchID)).count, 1, "One batch per session")
        }
        XCTAssertTrue(plan.scenarios.contains { $0.plannedCopies > 1 })
        XCTAssertEqual(record.physicalReceiptsConfirmed, plan.plannedPrintJobs)
        XCTAssertEqual(QualificationVerdict.evaluate(record), .unverified, "Printer-only runs never claim camera validation")
        XCTAssertFalse(QualificationVerdict.evaluate(record).claimsHardwareValidation)
    }

    // MARK: 7. Pause / stop

    func testPauseAndStopPreventNewPhysicalJobs() async throws {
        let engine = makeEngine()
        let configuration = physicalConfiguration(sessions: 12, batch: 12)
        printer.onPrint = { [weak engine] count in
            if count == 1 { engine?.requestPause() }
        }
        try engine.start(configuration, approvedByOperator: true, expectedPlanFingerprint: engine.plan(for: configuration).fingerprint)
        let pausedDeadline = Date().addingTimeInterval(30)
        while engine.record?.state != .paused, Date() < pausedDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(engine.record?.state, .paused)
        let printedBeforePause = printer.bytesSentJobs.count
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(printer.bytesSentJobs.count, printedBeforePause, "Paused runs send nothing")

        engine.requestStopAfterSession()
        engine.resume()
        await drive(engine)
        XCTAssertEqual(printer.bytesSentJobs.count, printedBeforePause, "Stop prevents new jobs")
        XCTAssertEqual(engine.record?.state, .stopped)
        XCTAssertEqual(QualificationVerdict.evaluate(try XCTUnwrap(engine.record)), .incomplete)
    }

    // MARK: 8. Uncertain prints

    func testUncertainPrintHaltsTheRunAndIsNeverResent() async throws {
        printer.outcomes = [.uncertainAfterBytes]
        let engine = makeEngine()
        let configuration = physicalConfiguration(sessions: 6)
        try engine.start(configuration, approvedByOperator: true, expectedPlanFingerprint: engine.plan(for: configuration).fingerprint)
        await drive(engine)

        XCTAssertEqual(printer.bytesSentJobs.count, 1, "The uncertain copy is never resent and nothing follows it")
        let record = try XCTUnwrap(engine.record)
        XCTAssertEqual(record.state, .haltedUncertainPrint)
        XCTAssertNotNil(record.inFlightPrint, "The durable checkpoint stays until a person inspects the printer")
        XCTAssertEqual(record.sessions.first?.outcome, .uncertainPrint)
        XCTAssertEqual(QualificationVerdict.evaluate(record), .interrupted)

        XCTAssertNotNil(store.unresolvedPrintRun)
        XCTAssertThrowsError(try makeEngine().start(configuration, approvedByOperator: true)) { error in
            XCTAssertEqual(error as? HardwareQualificationEngine.StartError, .unresolvedQualificationPrint)
        }
        try engine.acknowledgeUncertainPrint(runID: record.runID, note: "Receipt was half printed")
        XCTAssertNil(store.unresolvedPrintRun)
        XCTAssertEqual(store.loadAll().first?.state, .haltedUncertainPrint, "Acknowledging never turns the run into a pass")
    }

    func testFailedPreprintCheckpointSendsNoBytes() async throws {
        printer.failCheckpoints = true
        let engine = makeEngine()
        let configuration = physicalConfiguration(sessions: 6)
        try engine.start(configuration, approvedByOperator: true, expectedPlanFingerprint: engine.plan(for: configuration).fingerprint)
        await drive(engine)
        XCTAssertTrue(printer.bytesSentJobs.isEmpty)
        XCTAssertNil(engine.record?.inFlightPrint)
        XCTAssertEqual(QualificationVerdict.evaluate(try XCTUnwrap(engine.record)), .failed)
    }

    // MARK: 9. Relaunch

    func testRelaunchReconstructsStateWithoutResumingAndInvalidatesApproval() throws {
        let plan = QualificationPlanner.makePlan(mode: .endToEnd, sessionCount: 6)
        let earlierLaunch = UUID()
        var running = makeRecord(plan: plan, launchID: earlierLaunch)
        running.state = .running
        running.sessions = [QualificationSessionResult(sessionNumber: 1, qualificationSessionID: UUID(), format: .solo, category: .normal, startedAt: Date())]
        var printing = makeRecord(plan: plan, launchID: earlierLaunch)
        printing.state = .running
        printing.inFlightPrint = QualificationInFlightPrint(session: 1, copyIndex: 1, copyCount: 2, batchID: UUID(), startedAt: Date())
        printing.sessions = [QualificationSessionResult(sessionNumber: 1, qualificationSessionID: UUID(), format: .duo, category: .normal, startedAt: Date())]
        try store.save(running)
        try store.save(printing)

        let changed = store.reconstructAfterLaunch(launchID: QualificationLaunch.current)
        XCTAssertEqual(changed.count, 2)
        let reloadedRunning = try store.load(runID: running.runID)
        XCTAssertEqual(reloadedRunning.state, .interrupted)
        XCTAssertEqual(reloadedRunning.sessions.first?.outcome, .interrupted)
        XCTAssertTrue(reloadedRunning.events.contains { $0.kind == .relaunch })
        let reloadedPrinting = try store.load(runID: printing.runID)
        XCTAssertEqual(reloadedPrinting.state, .haltedUncertainPrint)
        XCTAssertEqual(reloadedPrinting.sessions.first?.outcome, .uncertainPrint)
        XCTAssertEqual(QualificationVerdict.evaluate(reloadedPrinting), .interrupted)
        XCTAssertTrue(store.reconstructAfterLaunch(launchID: QualificationLaunch.current).isEmpty, "Reconstruction is idempotent")

        let staleApproval = QualificationAuthorization(runID: running.runID, planFingerprint: plan.fingerprint, launchID: earlierLaunch, approvedThroughSession: 6, approvedPhysicalReceipts: 99, approvedAt: Date())
        XCTAssertEqual(staleApproval.denial(runID: running.runID, planFingerprint: plan.fingerprint, session: 2, receiptsAfterJob: 1), .relaunched)

        let engine = makeEngine()
        engine.loadHistory()
        XCTAssertFalse(engine.isRunning, "Nothing resumes after relaunch")
        XCTAssertNil(engine.authorization)
    }

    // MARK: 10. Recovery locks

    func testPrinterRecoveryLockBlocksStartAndStopsARun() async throws {
        printer.snapshot.printerRecoveryLocked = true
        let engine = makeEngine()
        let configuration = physicalConfiguration(sessions: 6)
        XCTAssertThrowsError(try engine.start(configuration, approvedByOperator: true)) { error in
            XCTAssertEqual(error as? HardwareQualificationEngine.StartError, .safety([.printerRecoveryLocked]))
        }

        printer.snapshot.printerRecoveryLocked = false
        printer.onPrint = { [weak printer] count in
            if count == 1 { printer?.snapshot.printerRecoveryLocked = true }
        }
        try engine.start(configuration, approvedByOperator: true)
        var sawBlock = false
        await drive(engine) { prompt in
            if case .physicalJobBlocked(let violations) = prompt.kind {
                sawBlock = violations.contains(.printerRecoveryLocked)
                return .stopRun
            }
            return Self.carefulOperator(prompt)
        }
        XCTAssertTrue(sawBlock)
        XCTAssertEqual(printer.bytesSentJobs.count, 1)
        XCTAssertNotEqual(QualificationVerdict.evaluate(try XCTUnwrap(engine.record)), .pass)
    }

    func testSafetyGateListsEveryBlockingCondition() {
        var snapshot = QualificationSafetySnapshot.idle
        snapshot.transportSupported = true
        XCTAssertTrue(QualificationSafetyGate.violations(snapshot: snapshot, authorizationDenial: nil, hasAuthorization: true, checkpointCommitted: true).isEmpty)
        let blocked = QualificationSafetySnapshot(customerSessionActive: true, printerJobActive: true, unresolvedPrint: true, printerRecoveryLocked: true, transport: .none, transportSupported: false, printerIdentity: "")
        XCTAssertEqual(
            Set(QualificationSafetyGate.violations(snapshot: blocked, authorizationDenial: .relaunched, hasAuthorization: true, checkpointCommitted: false)),
            Set(QualificationSafetyViolation.allCases)
        )
    }

    // MARK: 11. Customer data isolation

    func testDiagnosticRunsNeverWriteCustomerArchivesGalleriesOrRecovery() async throws {
        let customerArchives = try RecentSessionArchiveStore().summaries().map(\.archiveID)
        let customerUploads = try GalleryPendingUploadStore().summaries().map(\.galleryToken)
        let customerRecovery = try AppRecoveryStore().load()?.sessionIdentifier

        var configuration = HardwareQualificationEngine.Configuration()
        configuration.sessionCount = 6
        let engine = makeEngine()
        let record = try engine.start(configuration, approvedByOperator: false)
        await drive(engine)

        XCTAssertEqual(try RecentSessionArchiveStore().summaries().map(\.archiveID), customerArchives)
        XCTAssertEqual(try GalleryPendingUploadStore().summaries().map(\.galleryToken), customerUploads)
        XCTAssertEqual(try AppRecoveryStore().load()?.sessionIdentifier, customerRecovery)
        let diagnosticArchive = try RecentSessionArchiveStore(directoryURL: store.archiveDirectory(for: record.runID))
        XCTAssertEqual(try diagnosticArchive.summaries().count, 6)
        XCTAssertTrue(store.archiveDirectory(for: record.runID).path.hasPrefix(root.path))

        // Cleanup needs the typed run code, stays inside the namespace and keeps customer data.
        XCTAssertThrowsError(try store.deleteDiagnosticArtifacts(runID: record.runID, typedConfirmation: "nope", includingReport: false))
        try store.deleteDiagnosticArtifacts(runID: record.runID, typedConfirmation: record.shortID.lowercased(), includingReport: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.diagnosticDirectory(for: record.runID).path))
        XCTAssertNoThrow(try store.load(runID: record.runID), "The report is kept unless explicitly deleted")
        XCTAssertEqual(try RecentSessionArchiveStore().summaries().map(\.archiveID), customerArchives)
    }

    func testCleanupRefusesActiveRunsAndUnresolvedPrints() throws {
        let plan = QualificationPlanner.makePlan(mode: .physicalPrinterEndurance, sessionCount: 6)
        var active = makeRecord(plan: plan)
        active.state = .running
        try store.save(active)
        XCTAssertThrowsError(try store.deleteDiagnosticArtifacts(runID: active.runID, typedConfirmation: active.shortID, includingReport: true)) { error in
            XCTAssertEqual(error as? HardwareQualificationStoreError, .runIsActive)
        }
        var halted = makeRecord(plan: plan)
        halted.state = .haltedUncertainPrint
        halted.inFlightPrint = QualificationInFlightPrint(session: 1, copyIndex: 1, copyCount: 1, batchID: UUID(), startedAt: Date())
        try store.save(halted)
        XCTAssertThrowsError(try store.deleteDiagnosticArtifacts(runID: halted.runID, typedConfirmation: halted.shortID, includingReport: true)) { error in
            XCTAssertEqual(error as? HardwareQualificationStoreError, .unresolvedPrint)
        }
    }

    func testQualificationBoothEnvironmentIsolatesTheProductionStateMachine() async throws {
        let archiveDirectory = root.appendingPathComponent("vm-archive", isDirectory: true)
        let recoveryDirectory = root.appendingPathComponent("vm-recovery", isDirectory: true)
        let customerArchives = try RecentSessionArchiveStore().summaries().map(\.archiveID)
        var environment = BoothSessionEnvironment.customer
        environment.purpose = .hardwareQualification(runID: "TEST")
        environment.archiveDirectory = archiveDirectory
        environment.recoveryDirectory = recoveryDirectory
        environment.deliversGallery = false
        environment.recordsCustomerSessionMetrics = false
        environment.printSource = .diagnostic
        environment.makeSessionIdentifier = { HardwareQualificationEngine.sessionIdentifier(runCode: "TEST", session: 1, date: $0) }
        environment.eventProfileSource = { QualificationEventProfiles.profileA }
        let model = BoothSessionViewModel(environment: environment, captureConfirmationPause: {})

        model.selectedBoothFormat = nil
        model.state = .welcome
        model.startSession()
        guard model.state == .choosingFormat else {
            throw XCTSkip("Booth start is blocked on this simulator (\(model.state)); isolation is still covered by the engine tests.")
        }
        model.selectBoothFormat(.solo)
        XCTAssertTrue(model.sessionIdentifier?.hasPrefix("QA-TEST-001-") == true)
        // Let the real camera preparation settle (simulator: unavailable, or the 12 s watchdog)
        // so its callback cannot land after the sample-photo path below.
        let cameraDeadline = Date().addingTimeInterval(15)
        while model.state == .preparingCamera, Date() < cameraDeadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        model.isCameraUnavailable = true
        model.state = .cameraReady
        await model.addSamplePhotoAndConfirm(ReliabilityFixtures.syntheticPhoto(session: 42, photo: 1, format: .solo))
        model.continueToReceipt()
        let deadline = Date().addingTimeInterval(30)
        while model.state != .receiptPreview, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(model.state, .receiptPreview)
        XCTAssertEqual(model.uploadPhase, .idle, "Qualification never prepares or uploads a gallery")
        let token = try XCTUnwrap(model.galleryToken)
        let diagnostic = try RecentSessionArchiveStore(directoryURL: archiveDirectory)
        let committedDeadline = Date().addingTimeInterval(10)
        while !diagnostic.containsCommittedArchive(galleryToken: token), Date() < committedDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(diagnostic.containsCommittedArchive(galleryToken: token))
        XCTAssertFalse(try RecentSessionArchiveStore().containsCommittedArchive(galleryToken: token))
        XCTAssertEqual(try RecentSessionArchiveStore().summaries().map(\.archiveID), customerArchives)
        XCTAssertEqual(try diagnostic.load(archiveID: token).eventProfile?.eventName, QualificationEventProfiles.profileA.eventName, "The scenario profile is frozen, not the saved event settings")
        model.cancelSession()
    }

    // MARK: 12–13. Verdicts and reports

    func testReportsNeverClaimPhysicalValidationFromMockResults() {
        let plan = QualificationPlanner.makePlan(mode: .simulation, sessionCount: 6)
        var record = completedRecord(plan: plan)
        XCTAssertEqual(QualificationVerdict.evaluate(record), .simulationOnly)
        XCTAssertFalse(QualificationVerdict.evaluate(record).claimsHardwareValidation)
        let text = QualificationReportFormatter.text(for: record)
        XCTAssertTrue(text.contains("RESULT: SIMULATION ONLY"))
        XCTAssertTrue(text.contains("no physical hardware was validated"))
        XCTAssertFalse(text.contains("RESULT: PASS"))
        record.physicalReceiptsConfirmed = 6
        XCTAssertEqual(QualificationVerdict.evaluate(record), .simulationOnly, "Even claimed confirmations cannot upgrade a simulation")
        XCTAssertTrue(QualificationReportFormatter.csv(for: record).hasPrefix("session,qualification_session_id"))
    }

    func testOnlyACompleteFullyConfirmedRunCanPass() {
        let plan = QualificationPlanner.makePlan(mode: .endToEnd, sessionCount: 12, batchSize: 6)
        var record = completedRecord(plan: plan)
        record.acknowledgedCheckpoints = plan.scenarios.flatMap { scenario in
            scenario.checkpoints.filter(\.isSupervised).map { QualificationVerdict.checkpointKey(session: scenario.sessionNumber, $0) }
        }
        XCTAssertEqual(QualificationVerdict.evaluate(record), .unverified, "Manual drills outside the plan stay listed as unverified")
        XCTAssertFalse(QualificationVerdict.unverifiedRequirements(record).contains { $0.contains("not acknowledged") })

        var partial = record
        partial.state = .stopped
        partial.sessions.removeLast()
        XCTAssertEqual(QualificationVerdict.evaluate(partial), .incomplete)

        var pending = record
        pending.sessions[0].physicalConfirmation = .pending
        XCTAssertTrue(QualificationVerdict.unverifiedRequirements(pending).contains { $0.contains("paper output") })

        var mismatch = record
        mismatch.sessions[0].physicalConfirmation = .mismatch(expected: 2, observed: 1)
        XCTAssertEqual(QualificationVerdict.evaluate(mismatch), .failed)

        var violation = record
        violation.sessions[3].violations = ["Receipt raster matches session 1"]
        XCTAssertEqual(QualificationVerdict.evaluate(violation), .failed)

        var interrupted = record
        interrupted.state = .interrupted
        XCTAssertEqual(QualificationVerdict.evaluate(interrupted), .interrupted)

        // The only path to PASS is a complete run with every check satisfied; with the manual
        // drills that remain outside the app, the strongest verdict available is UNVERIFIED.
        XCTAssertFalse(QualificationVerdict.unverifiedRequirements(record).isEmpty)
    }

    // MARK: 14–15. Orientation and customer defaults

    func testDiagnosticPhotosKeepCaptureAndPrintOrientationConsistent() {
        for format in BoothFormat.allCases {
            for index in 0..<format.photoCount {
                let photo = QualificationDiagnosticPhoto.storedCapture(
                    QualificationDiagnosticPhoto.make(runCode: "T", session: 1, photoIndex: index, photoCount: format.photoCount, label: "TEST"),
                    format: format
                )
                XCTAssertTrue(QualificationFingerprint.orientationIsConsistent(stored: photo, format: format, photoIndex: index), "\(format) photo \(index + 1)")
            }
        }
    }

    func testCustomerEnvironmentKeepsProductionBehaviour() {
        let environment = BoothSessionEnvironment.customer
        XCTAssertEqual(environment.purpose, .customer)
        XCTAssertFalse(environment.isQualification)
        XCTAssertNil(environment.archiveDirectory)
        XCTAssertNil(environment.recoveryDirectory)
        XCTAssertTrue(environment.deliversGallery)
        XCTAssertTrue(environment.recordsCustomerSessionMetrics)
        XCTAssertEqual(environment.printSource, .liveCustomer)
        XCTAssertTrue(environment.makeSessionIdentifier(Date()).hasPrefix("PP-"))
        XCTAssertEqual(BoothSessionViewModel().environment.purpose, .customer)
        XCTAssertEqual(HardwareQualificationEngine.sessionIdentifier(runCode: "AB12", session: 7, date: Date()).count, ReceiptComposer.makeSessionIdentifier().count, "Diagnostic IDs fit the printed session line")
    }

    func testBackToBackCustomerBatchesAreSerializedWithoutInterleaving() async throws {
        let spooler = PrintSpooler(auditStore: nil, waitsForPhysicalHandoff: false, writesAuditSynchronously: true)
        var order: [String] = []
        var active = 0
        var maximumActive = 0
        func batch(_ name: String, copies: Int) async {
            let raster = try! ReliabilityFixtures.rasterizedImage(seed: name == "A" ? 1 : 2)
            let batchID = UUID()
            for copy in 1...copies {
                let envelope = try! PrintJobEnvelope.receipt(rasterizedImage: raster, sessionIdentifier: name, source: .liveCustomer, copyIndex: copy, copyCount: copies, batchID: batchID, transportPolicy: .safeIntegrity)
                _ = await spooler.submit(envelope: envelope) { envelope in
                    active += 1
                    maximumActive = max(maximumActive, active)
                    order.append("\(envelope.sessionIdentifier)\(envelope.copyIndex)")
                    try? await Task.sleep(for: .milliseconds(5))
                    active -= 1
                    return .success(PhysicalPrintTransportResult(transport: .bluetooth, bluetoothMode: nil, chunkSize: nil, chunkCount: nil, flowControlPauseCount: nil, writeTimeout: nil, bytesStarted: true, transportFinishedAt: Date()))
                }
            }
        }
        async let first: Void = batch("A", copies: 3)
        async let second: Void = batch("B", copies: 2)
        _ = await (first, second)
        XCTAssertEqual(maximumActive, 1)
        XCTAssertEqual(order.filter { $0.hasPrefix("A") }, ["A1", "A2", "A3"])
        XCTAssertEqual(order.filter { $0.hasPrefix("B") }, ["B1", "B2"])
        XCTAssertEqual(order.count, 5)
    }

    // MARK: Helpers

    private func makeRecord(plan: QualificationPlan, launchID: UUID = QualificationLaunch.current) -> QualificationRunRecord {
        QualificationRunRecord(
            runID: UUID(),
            plan: plan,
            createdAt: Date(),
            environment: QualificationEnvironmentInfo(appVersion: "1", buildNumber: "1", commitSHA: "test", deviceModel: "iPad", systemVersion: "iPadOS"),
            printerIdentity: "Fake",
            printerTransport: "Bluetooth",
            paperStock: "",
            operatorName: "",
            launchID: launchID
        )
    }

    private func completedRecord(plan: QualificationPlan) -> QualificationRunRecord {
        var record = makeRecord(plan: plan)
        record.state = .completed
        record.startedAt = Date()
        record.endedAt = Date()
        record.sessions = plan.scenarios.map { scenario in
            var session = QualificationSessionResult(sessionNumber: scenario.sessionNumber, qualificationSessionID: UUID(), format: scenario.format, category: scenario.category, startedAt: Date())
            session.endedAt = Date()
            session.outcome = .passed
            session.copiesRequested = scenario.plannedCopies
            session.printJobsCompleted = scenario.plannedCopies
            session.physicalConfirmation = plan.mode.usesPhysicalPrinter ? .confirmed(receipts: scenario.plannedCopies) : .notRequired
            return session
        }
        return record
    }
}

/// A printer that never prints. It runs the pre-print checkpoint exactly like the spooler and
/// records which jobs would have sent bytes.
@MainActor
final class FakeQualificationPrinter: QualificationPrinter {
    struct Job {
        let sessionIdentifier: String
        let copyIndex: Int
        let copyCount: Int
        let batchID: UUID
    }

    var snapshot = QualificationSafetySnapshot(
        customerSessionActive: false,
        printerJobActive: false,
        unresolvedPrint: false,
        printerRecoveryLocked: false,
        transport: .bluetooth,
        transportSupported: true,
        printerIdentity: "Fake VOZY G80"
    )
    var outcomes: [QualificationPrintOutcome.Status] = []
    var failCheckpoints = false
    var onPrint: ((Int) -> Void)?
    private(set) var bytesSentJobs: [Job] = []
    private(set) var snapshotRequests = 0
    private(set) var maximumConcurrentJobs = 0
    private var activeJobs = 0
    private var audit: [PrintAuditRecord] = []

    let wifiHost = "127.0.0.1"
    let wifiPort: UInt16? = 9

    func safetySnapshot() -> QualificationSafetySnapshot {
        snapshotRequests += 1
        return snapshot
    }

    func printCopy(_ request: QualificationPrintRequest) async -> QualificationPrintOutcome {
        guard let envelope = try? PrintJobEnvelope.receipt(rasterizedImage: request.rasterizedImage, sessionIdentifier: request.sessionIdentifier, source: .diagnostic, copyIndex: request.copyIndex, copyCount: request.copyCount, batchID: request.batchID, transportPolicy: .safeIntegrity) else {
            return QualificationPrintOutcome(status: .failedBeforeBytes, message: "Envelope", transportSeconds: nil)
        }
        do {
            if failCheckpoints { throw PrintCheckpointError.persistenceFailed("Test checkpoint failure") }
            try request.prePrintCheckpoint.persist(envelope)
        } catch {
            return QualificationPrintOutcome(status: .blockedByCheckpoint, message: error.localizedDescription, transportSeconds: nil)
        }
        activeJobs += 1
        maximumConcurrentJobs = max(maximumConcurrentJobs, activeJobs)
        bytesSentJobs.append(Job(sessionIdentifier: request.sessionIdentifier, copyIndex: request.copyIndex, copyCount: request.copyCount, batchID: request.batchID))
        await Task.yield()
        activeJobs -= 1
        let status = outcomes.isEmpty ? .completed : outcomes.removeFirst()
        audit.append(Self.auditRecord(envelope, status: status))
        onPrint?(bytesSentJobs.count)
        return QualificationPrintOutcome(status: status, message: status == .completed ? "ok" : "uncertain", transportSeconds: 0.01)
    }

    func auditRecords(sessionIdentifier: String) -> [PrintAuditRecord] {
        audit.filter { $0.sessionIdentifier == sessionIdentifier }
    }

    private static func auditRecord(_ envelope: PrintJobEnvelope, status: QualificationPrintOutcome.Status) -> PrintAuditRecord {
        PrintAuditRecord(
            id: UUID(), timestamp: Date(), jobID: envelope.jobID, batchID: envelope.batchID,
            sessionIdentifier: envelope.sessionIdentifier, source: envelope.source,
            copyIndex: envelope.copyIndex, copyCount: envelope.copyCount,
            payloadFingerprint: envelope.payloadFingerprint, payloadByteCount: envelope.payloadByteCount,
            imageWidth: envelope.imageWidth, imageHeight: envelope.imageHeight, rasterByteCount: envelope.rasterByteCount,
            transport: .bluetooth, bluetoothMode: nil, chunkSize: nil, chunkCount: nil,
            startedAt: Date(), transportFinishedAt: Date(), physicalOwnershipReleasedAt: Date(),
            transportDuration: 0.01, handoffDuration: 0, flowControlPauseCount: nil, writeTimeout: nil,
            bytesStarted: true,
            terminalResult: status == .completed ? .completed : .recoveryRequiredAfterBytes,
            recoveryReason: nil
        )
    }
}
