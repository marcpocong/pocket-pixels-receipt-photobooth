//
//  HardwareQualificationRecord.swift
//  PocketPixelsBooth
//
//  Operator authorization, physical safety gates, durable run records, verdicts and reports
//  for hardware qualification. Everything here is a pure value so the rules are unit-testable
//  without a camera or printer.
//

import Foundation
import UIKit

// MARK: - Launch identity

/// Identifies this process launch. Physical authorization is bound to it and never persisted,
/// so a relaunch always invalidates approval.
nonisolated enum QualificationLaunch {
    static let current = UUID()
}

// MARK: - Authorization

/// Approval for one specific run configuration, one launch and an explicit print budget.
/// Lives only in memory.
nonisolated struct QualificationAuthorization: Equatable, Sendable {
    let runID: UUID
    let planFingerprint: String
    let launchID: UUID
    /// Sessions up to and including this number are approved.
    let approvedThroughSession: Int
    /// Total physical receipts (copies) the operator approved for the run so far.
    let approvedPhysicalReceipts: Int
    let approvedAt: Date

    enum Denial: Equatable, Sendable {
        case differentRun
        case planChanged
        case relaunched
        case sessionBeyondApprovedBatch(Int)
        case printBudgetExceeded(requested: Int, approved: Int)

        var message: String {
            switch self {
            case .differentRun: "Approval belongs to a different run."
            case .planChanged: "The run configuration changed after approval."
            case .relaunched: "The app relaunched; physical approval is no longer valid."
            case .sessionBeyondApprovedBatch(let session): "Session \(session) is beyond the approved batch. Approve the next batch to continue."
            case .printBudgetExceeded(let requested, let approved): "This needs \(requested) physical receipts but only \(approved) were approved. Renewed approval is required."
            }
        }
    }

    /// Checks one physical job before any bytes. `receiptsAfterJob` includes this job's copies.
    func denial(
        runID: UUID,
        planFingerprint: String,
        session: Int,
        receiptsAfterJob: Int,
        launchID: UUID = QualificationLaunch.current
    ) -> Denial? {
        if runID != self.runID { return .differentRun }
        if planFingerprint != self.planFingerprint { return .planChanged }
        if launchID != self.launchID { return .relaunched }
        if session > approvedThroughSession { return .sessionBeyondApprovedBatch(session) }
        if receiptsAfterJob > approvedPhysicalReceipts {
            return .printBudgetExceeded(requested: receiptsAfterJob, approved: approvedPhysicalReceipts)
        }
        return nil
    }
}

// MARK: - Safety gates

nonisolated struct QualificationSafetySnapshot: Equatable, Sendable {
    var customerSessionActive: Bool
    var printerJobActive: Bool
    var unresolvedPrint: Bool
    var printerRecoveryLocked: Bool
    var transport: PrinterTransportSelection
    var transportSupported: Bool
    var printerIdentity: String

    static let idle = QualificationSafetySnapshot(
        customerSessionActive: false,
        printerJobActive: false,
        unresolvedPrint: false,
        printerRecoveryLocked: false,
        transport: .none,
        transportSupported: false,
        printerIdentity: "No printer"
    )
}

nonisolated enum QualificationSafetyViolation: String, Codable, CaseIterable, Sendable {
    case customerSessionActive
    case printerJobActive
    case unresolvedPrint
    case printerRecoveryLocked
    case unsupportedTransport
    case checkpointNotCommitted
    case notAuthorized

    var message: String {
        switch self {
        case .customerSessionActive: "A customer session is active."
        case .printerJobActive: "Another print job owns the printer."
        case .unresolvedPrint: "An earlier print has an unresolved status."
        case .printerRecoveryLocked: "Printer recovery is required."
        case .unsupportedTransport: "No supported printer connection is ready."
        case .checkpointNotCommitted: "The diagnostic pre-print checkpoint could not be saved."
        case .notAuthorized: "The operator has not approved this physical print."
        }
    }
}

nonisolated enum QualificationSafetyGate {
    /// Every condition that must hold before printer bytes may be sent. Empty means safe.
    static func violations(
        snapshot: QualificationSafetySnapshot,
        authorizationDenial: QualificationAuthorization.Denial?,
        hasAuthorization: Bool,
        checkpointCommitted: Bool
    ) -> [QualificationSafetyViolation] {
        var result: [QualificationSafetyViolation] = []
        if snapshot.customerSessionActive { result.append(.customerSessionActive) }
        if snapshot.printerJobActive { result.append(.printerJobActive) }
        if snapshot.unresolvedPrint { result.append(.unresolvedPrint) }
        if snapshot.printerRecoveryLocked { result.append(.printerRecoveryLocked) }
        if !snapshot.transportSupported { result.append(.unsupportedTransport) }
        if !checkpointCommitted { result.append(.checkpointNotCommitted) }
        if !hasAuthorization || authorizationDenial != nil { result.append(.notAuthorized) }
        return result
    }
}

// MARK: - Run record

nonisolated enum QualificationRunState: String, Codable, Sendable {
    case draft
    case running
    case paused
    case awaitingCheckpoint
    case awaitingBatchApproval
    case stopped
    case completed
    case interrupted
    /// Printer bytes may have started without a confirmed completion. Never resumed automatically.
    case haltedUncertainPrint

    var isActive: Bool {
        switch self {
        case .running, .paused, .awaitingCheckpoint, .awaitingBatchApproval: true
        default: false
        }
    }
}

nonisolated enum QualificationSessionOutcome: String, Codable, Sendable {
    case passed
    case failed
    case uncertainPrint
    case interrupted
}

nonisolated enum QualificationPhysicalConfirmation: Codable, Equatable, Sendable {
    case notRequired
    case pending
    case confirmed(receipts: Int)
    case mismatch(expected: Int, observed: Int)

    var isSatisfied: Bool {
        switch self {
        case .notRequired, .confirmed: true
        case .pending, .mismatch: false
        }
    }

    var displayText: String {
        switch self {
        case .notRequired: "Not required"
        case .pending: "Pending operator confirmation"
        case .confirmed(let receipts): "Operator confirmed \(receipts) receipt\(receipts == 1 ? "" : "s")"
        case .mismatch(let expected, let observed): "MISMATCH — expected \(expected), operator saw \(observed)"
        }
    }
}

nonisolated struct QualificationSessionResult: Codable, Equatable, Identifiable, Sendable {
    let sessionNumber: Int
    /// Generated independently of the booth's own session identifier.
    let qualificationSessionID: UUID
    var boothSessionIdentifier: String?
    let format: BoothFormat
    let category: QualificationScenarioCategory
    let startedAt: Date
    var endedAt: Date?
    var outcome: QualificationSessionOutcome = .failed
    var lastStage: String = "Started"
    var captureAttempts = 0
    var captureFailures = 0
    var photoFingerprints: [String] = []
    var orientationChecksPassed: Bool?
    var receiptFingerprint: String?
    var copiesRequested = 0
    var printJobsRequested = 0
    var printJobsCompleted = 0
    var transportSeconds: [Double] = []
    var printAuditJobIDs: [UUID] = []
    var physicalConfirmation: QualificationPhysicalConfirmation = .notRequired
    var violations: [String] = []
    var notes: [String] = []
    var memoryMegabytesAtEnd: Int?

    var id: Int { sessionNumber }

    var duration: TimeInterval? {
        endedAt.map { $0.timeIntervalSince(startedAt) }
    }
}

nonisolated struct QualificationEvent: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case info
        case approval
        case safetyBlock
        case camera
        case printer
        case recovery
        case checkpoint
        case correctness
        case relaunch
    }

    let timestamp: Date
    let kind: Kind
    let session: Int?
    let detail: String
}

nonisolated struct QualificationApprovalRecord: Codable, Equatable, Sendable {
    let approvedAt: Date
    let launchID: UUID
    let approvedThroughSession: Int
    let approvedPhysicalReceipts: Int
}

/// The durable pre-print checkpoint: written (fsync) before bytes, cleared after completion.
nonisolated struct QualificationInFlightPrint: Codable, Equatable, Sendable {
    let session: Int
    let copyIndex: Int
    let copyCount: Int
    let batchID: UUID
    let startedAt: Date
}

nonisolated struct QualificationEnvironmentInfo: Codable, Equatable, Sendable {
    var appVersion: String
    var buildNumber: String
    var commitSHA: String
    var deviceModel: String
    var systemVersion: String

    @MainActor
    static func current(operatorCommitSHA: String) -> QualificationEnvironmentInfo {
        let info = Bundle.main.infoDictionary ?? [:]
        let embeddedSHA = (info["MADE_TO_KEEP_BUILD_COMMIT"] as? String).flatMap { $0.isEmpty || $0.hasPrefix("$(") ? nil : $0 }
        let enteredSHA = operatorCommitSHA.trimmingCharacters(in: .whitespacesAndNewlines)
        return QualificationEnvironmentInfo(
            appVersion: info["CFBundleShortVersionString"] as? String ?? "unknown",
            buildNumber: info["CFBundleVersion"] as? String ?? "unknown",
            commitSHA: embeddedSHA ?? (enteredSHA.isEmpty ? "Not recorded" : "\(enteredSHA) (operator-entered)"),
            deviceModel: "\(UIDevice.current.model) (\(Self.hardwareMachine()))",
            systemVersion: "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
        )
    }

    private static func hardwareMachine() -> String {
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        guard size > 0 else { return "unknown" }
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.machine", &buffer, &size, nil, 0)
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

nonisolated struct QualificationRunRecord: Codable, Equatable, Identifiable, Sendable {
    static let schemaVersion = 1

    var schemaVersion = Self.schemaVersion
    let runID: UUID
    let plan: QualificationPlan
    let createdAt: Date
    var startedAt: Date?
    var endedAt: Date?
    var state: QualificationRunState = .draft
    var environment: QualificationEnvironmentInfo
    var printerIdentity: String
    var printerTransport: String
    var paperStock: String
    var operatorName: String
    var launchID: UUID
    var sessions: [QualificationSessionResult] = []
    var events: [QualificationEvent] = []
    var approvals: [QualificationApprovalRecord] = []
    var inFlightPrint: QualificationInFlightPrint?
    var physicalReceiptsSent = 0
    var physicalReceiptsConfirmed = 0
    var peakMemoryMegabytes = 0
    var startingFreeStorageBytes: Int64?
    var latestFreeStorageBytes: Int64?
    var cameraInterruptions = 0
    var staleCallbackRejections = 0
    var staleCallbackViolations = 0
    var unsafeRetryAttempts = 0
    var duplicatePrintDetections = 0
    var acknowledgedCheckpoints: [String] = []

    var id: UUID { runID }

    var shortID: String {
        String(runID.uuidString.prefix(8))
    }

    var completedSessions: [QualificationSessionResult] {
        sessions.filter { $0.endedAt != nil }
    }

    var passedSessionCount: Int {
        sessions.filter { $0.outcome == .passed && $0.endedAt != nil }.count
    }

    var failedSessionCount: Int {
        sessions.filter { $0.endedAt != nil && $0.outcome != .passed }.count
    }

    mutating func log(_ kind: QualificationEvent.Kind, session: Int? = nil, _ detail: String, at date: Date = Date()) {
        events.append(QualificationEvent(timestamp: date, kind: kind, session: session, detail: detail))
    }
}

// MARK: - Verdict

nonisolated enum QualificationVerdict: String, Codable, Sendable {
    case pass = "PASS"
    case failed = "FAILED"
    case incomplete = "INCOMPLETE"
    case interrupted = "INTERRUPTED"
    case unverified = "UNVERIFIED"
    case simulationOnly = "SIMULATION ONLY"

    static func evaluate(_ record: QualificationRunRecord) -> QualificationVerdict {
        let violations = record.sessions.contains { !$0.violations.isEmpty }
            || record.staleCallbackViolations > 0
            || record.unsafeRetryAttempts > 0
            || record.duplicatePrintDetections > 0
        let anyFailure = record.sessions.contains { $0.endedAt != nil && $0.outcome == .failed }
        let mismatch = record.sessions.contains {
            if case .mismatch = $0.physicalConfirmation { return true }
            return false
        }
        if violations || anyFailure || mismatch { return .failed }
        if record.state == .haltedUncertainPrint || record.state == .interrupted
            || record.sessions.contains(where: { $0.outcome == .uncertainPrint || $0.outcome == .interrupted }) {
            return .interrupted
        }
        let finished = record.state == .completed
            && record.passedSessionCount == record.plan.sessionCount
        if !finished { return .incomplete }
        // Mock transport and synthetic photos never qualify hardware, however clean.
        if record.plan.mode == .simulation { return .simulationOnly }
        if !unverifiedRequirements(record).isEmpty { return .unverified }
        return .pass
    }

    /// Required physical evidence that this run did not (or could not) provide.
    static func unverifiedRequirements(_ record: QualificationRunRecord) -> [String] {
        var items: [String] = []
        if record.plan.mode == .simulation {
            items.append("No physical hardware was exercised (mock transport, synthetic photos).")
            return items
        }
        if record.sessions.contains(where: { !$0.physicalConfirmation.isSatisfied }) {
            items.append("Operator confirmation of physical paper output is missing for one or more sessions.")
        }
        for scenario in record.plan.scenarios {
            for checkpoint in scenario.checkpoints where checkpoint.isSupervised && checkpoint != .confirmPaperOutput {
                let key = Self.checkpointKey(session: scenario.sessionNumber, checkpoint)
                if !record.acknowledgedCheckpoints.contains(key) {
                    items.append("Session \(scenario.sessionNumber): \(checkpoint.title) not acknowledged.")
                }
            }
        }
        return items
    }

    /// Release checks outside the selected run never change its scoped verdict.
    static func outsideScopeRequirements(_ record: QualificationRunRecord) -> [String] {
        var items: [String] = []
        if record.plan.mode == .physicalPrinterEndurance {
            items.append("Live front-camera capture is not part of printer endurance; run Mode C for end-to-end qualification.")
        }
        items.append("Bluetooth disconnect during bytes, paper-out/reload and multi-hour operation remain manual drills (see release checklist).")
        return items
    }

    static func checkpointKey(session: Int, _ checkpoint: QualificationCheckpoint) -> String {
        "S\(session):\(checkpoint.rawValue)"
    }

    /// Whether this verdict claims physical hardware validation.
    var claimsHardwareValidation: Bool {
        self == .pass
    }
}

// MARK: - Report

nonisolated enum QualificationReportFormatter {
    static func text(for record: QualificationRunRecord, now: Date = Date()) -> String {
        let verdict = QualificationVerdict.evaluate(record)
        let iso = ISO8601DateFormatter()
        func date(_ value: Date?) -> String { value.map(iso.string(from:)) ?? "—" }
        let durations = record.completedSessions.compactMap(\.duration)
        let average = durations.isEmpty ? 0 : durations.reduce(0, +) / Double(durations.count)
        var lines: [String] = [
            "MADE TO KEEP STUDIOS — HARDWARE QUALIFICATION REPORT",
            "",
            "RESULT: \(verdict.rawValue)",
            record.plan.mode == .simulation
                ? "SIMULATION ONLY — no physical hardware was validated."
                : (verdict.claimsHardwareValidation ? "PASS for the selected test scope: all planned checks and physical confirmations were satisfied. This is not full production qualification." : "This run does not qualify the hardware."),
            "",
            "Run ID: \(record.runID.uuidString)",
            "Mode: \(record.plan.mode.displayName)",
            "Hands-free: \(record.plan.runsHandsFree ? "Yes — automatic details/signature; physical checks unverified" : "No")",
            "State: \(record.state.rawValue)",
            "App: \(record.environment.appVersion) (\(record.environment.buildNumber))",
            "Commit: \(record.environment.commitSHA)",
            "iPad: \(record.environment.deviceModel) · \(record.environment.systemVersion)",
            "Printer: \(record.printerIdentity) · \(record.printerTransport)",
            "Paper stock: \(record.paperStock.isEmpty ? "Not recorded" : record.paperStock)",
            "Operator: \(record.operatorName.isEmpty ? "Not recorded" : record.operatorName)",
            "Started: \(date(record.startedAt))",
            "Ended: \(date(record.endedAt))",
            "Seed: \(record.plan.seed) · Plan fingerprint: \(record.plan.fingerprint) · Batch size: \(record.plan.batchSize)",
            "",
            "SUMMARY",
            "Sessions: \(record.passedSessionCount) passed / \(record.failedSessionCount) failed / \(record.plan.sessionCount) planned",
            "Average session: \(String(format: "%.1f", average)) s · Longest: \(String(format: "%.1f", durations.max() ?? 0)) s",
            "Print jobs: \(record.sessions.reduce(0) { $0 + $1.printJobsCompleted }) completed / \(record.sessions.reduce(0) { $0 + $1.printJobsRequested }) requested",
            "Physical receipts sent: \(record.physicalReceiptsSent) · operator-confirmed on paper: \(record.physicalReceiptsConfirmed)",
            "Transport completion is reported by the app; it is not proof that paper emerged. Paper output is operator-confirmed.",
            "Peak memory: \(record.peakMemoryMegabytes) MB",
            "Storage change: \(storageChange(record))",
            "Camera interruptions: \(record.cameraInterruptions)",
            "Stale callbacks rejected: \(record.staleCallbackRejections) · stale callback violations: \(record.staleCallbackViolations)",
            "Unsafe retry attempts: \(record.unsafeRetryAttempts) · duplicate print detections: \(record.duplicatePrintDetections)",
            "",
            "UNVERIFIED REQUIREMENTS"
        ]
        let unverified = QualificationVerdict.unverifiedRequirements(record)
        lines += unverified.isEmpty ? ["None."] : unverified.map { "- \($0)" }
        lines += ["", "OUTSIDE THIS RUN — SEPARATE RELEASE CHECKS"]
        lines += QualificationVerdict.outsideScopeRequirements(record).map { "- \($0)" }
        lines += ["", "SESSIONS"]
        for session in record.sessions {
            let duration = session.duration.map { String(format: "%.1fs", $0) } ?? "—"
            lines.append("#\(session.sessionNumber) \(session.format.displayName) [\(session.category.displayName)] \(session.outcome.rawValue.uppercased()) \(duration) · qid \(session.qualificationSessionID.uuidString.prefix(8)) · booth \(session.boothSessionIdentifier ?? "—") · copies \(session.printJobsCompleted)/\(session.copiesRequested) · paper: \(session.physicalConfirmation.displayText)")
            if let fingerprint = session.receiptFingerprint { lines.append("   raster \(fingerprint) · audit \(session.printAuditJobIDs.map { String($0.uuidString.prefix(8)) }.joined(separator: ","))") }
            for violation in session.violations { lines.append("   VIOLATION: \(violation)") }
            for note in session.notes { lines.append("   note: \(note)") }
        }
        lines += ["", "EVENTS"]
        lines += record.events.map { "\(iso.string(from: $0.timestamp)) [\($0.kind.rawValue)]\($0.session.map { " S\($0)" } ?? "") \($0.detail)" }
        lines += ["", "Generated \(iso.string(from: now)). Zero detected software violations does not by itself prove that physical sessions passed."]
        return lines.joined(separator: "\n")
    }

    static func csv(for record: QualificationRunRecord) -> String {
        var rows = ["session,qualification_session_id,booth_session_id,format,category,outcome,duration_s,photos,captures_failed,orientation_ok,raster_fingerprint,copies_requested,jobs_completed,paper_confirmation,violations"]
        for session in record.sessions {
            let fields: [String] = [
                "\(session.sessionNumber)",
                session.qualificationSessionID.uuidString,
                session.boothSessionIdentifier ?? "",
                session.format.rawValue,
                session.category.rawValue,
                session.outcome.rawValue,
                session.duration.map { String(format: "%.2f", $0) } ?? "",
                "\(session.photoFingerprints.count)",
                "\(session.captureFailures)",
                session.orientationChecksPassed.map { $0 ? "yes" : "no" } ?? "",
                session.receiptFingerprint ?? "",
                "\(session.copiesRequested)",
                "\(session.printJobsCompleted)",
                session.physicalConfirmation.displayText,
                session.violations.joined(separator: " | ")
            ]
            rows.append(fields.map(escape).joined(separator: ","))
        }
        return rows.joined(separator: "\n")
    }

    private static func escape(_ field: String) -> String {
        guard field.contains(",") || field.contains("\"") || field.contains("\n") else { return field }
        return "\"\(field.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private static func storageChange(_ record: QualificationRunRecord) -> String {
        guard let start = record.startingFreeStorageBytes, let latest = record.latestFreeStorageBytes else { return "—" }
        let used = start - latest
        return "\(ByteCountFormatter.string(fromByteCount: used, countStyle: .file)) used"
    }
}
