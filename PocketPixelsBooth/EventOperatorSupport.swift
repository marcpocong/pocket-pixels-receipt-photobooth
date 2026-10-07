import Foundation

// Conservative thresholds, not an estimate of remaining customer capacity.
enum StorageHealth: String {
    case healthy = "Healthy"
    case low = "Getting Low"
    case critical = "Critical"

    init(bytes: Int64) {
        self = bytes < 100_000_000 ? .critical : (bytes < 500_000_000 ? .low : .healthy)
    }
    var checkStatus: EventReadinessCheck.Status {
        switch self { case .healthy: .pass; case .low: .warning; case .critical: .fail }
    }
}

enum OperatorStorageProbe {
    static func verify(directory: URL) throws {
        let probe = directory.appendingPathComponent(".preflight-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: probe) }
        let data = Data("Pocket Pixels storage check".utf8)
        try data.write(to: probe, options: .atomic)
        guard try Data(contentsOf: probe) == data else { throw CocoaError(.fileReadCorruptFile) }
    }
}

enum OperatorPrintPolicy {
    static func requiresAcknowledgement(stage: AppRecoveryStage?, snapshotIdentity: String?, acknowledgedIdentity: String?) -> Bool {
        stage == .printStatusUnknown && (snapshotIdentity == nil || snapshotIdentity != acknowledgedIdentity)
    }

    static func canReprint(busy: Bool, recoveryLocked: Bool, unresolvedPrint: Bool) -> Bool {
        !busy && !recoveryLocked && !unresolvedPrint
    }
}

enum SamplePrintPolicy {
    static func canStart(hasPreview: Bool, printerBusy: Bool, recoveryLocked: Bool, unresolvedPrint: Bool, operationActive: Bool) -> Bool {
        hasPreview && !printerBusy && !recoveryLocked && !unresolvedPrint && !operationActive
    }
}

extension PrintAuditRecord.TerminalResult {
    var operatorTitle: String {
        switch self {
        case .completed: "Transport completed"
        case .failedBeforeBytes: "Failed before bytes"
        case .recoveryRequiredAfterBytes: "Print status unknown — inspect receipt"
        case .cancelledBeforeBytes: "Cancelled before bytes"
        }
    }
}

struct OperatorAuditSummary {
    let records: [PrintAuditRecord]
    var requestedCopies: Int {
        // Count each batch once, even when several copies reached the transport.
        Dictionary(grouping: records, by: \.batchID).values.reduce(0) {
            $0 + ($1.map(\.copyCount).max() ?? 0)
        }
    }
    var recoveryEvents: Int {
        Set(records.filter { $0.terminalResult == .recoveryRequiredAfterBytes }.map(\.jobID)).count
    }
}

extension EventOperationalState {
    var storageText: String {
        "\(StorageHealth(bytes: availableBytes).rawValue) · \(ByteCountFormatter.string(fromByteCount: availableBytes, countStyle: .file)) available"
    }
    var launchAuditSummary: OperatorAuditSummary {
        OperatorAuditSummary(records: auditRecords.filter { $0.startedAt >= appStartedAt })
    }
    func printContext(sessionID: String) -> String {
        let records = auditRecords.filter { $0.sessionIdentifier == sessionID }
        if records.contains(where: { $0.terminalResult == .recoveryRequiredAfterBytes }) {
            return "Earlier print status unknown. Inspect paper before any operator reprint."
        }
        guard let last = records.last else { return "Print state / copies not recorded in retained audit." }
        return "\(last.terminalResult.operatorTitle) · copy \(last.copyIndex)/\(last.copyCount)"
    }
    func galleryContext(sessionID: String) -> String {
        if let item = pendingUploads.first(where: { $0.sessionID == sessionID }) {
            return "Saved locally · \(item.deliveryState.operatorTitle)"
        }
        return "Not in pending queue · online delivery not verified"
    }
    var diagnosticReport: String {
        var lines = [
            "POCKET PIXELS EVENT DIAGNOSTICS",
            "Time: \(Date().formatted())",
            "App uptime: \(uptimeText)",
            "Event: \(EventProfileStore.load().activeReceiptSnapshot?.eventName ?? "Pocket Pixels default")",
            "Status: \(readinessReport.title)",
            "Sessions this launch: \(sessionsCompletedThisLaunch)",
            "Camera: \(cameraCheckMessage)",
            "Printer ready: \(PrinterCoordinator.shared.isBluetoothReady)",
            "Bluetooth transfer: \(PrinterCoordinator.shared.receiptBluetoothTransferMode.operatorSummary)",
            "Printer recovery: \(PrinterCoordinator.shared.requiresRecovery)",
            "Unresolved print: \(hasUnresolvedPrint)",
            "Print queue busy: \(PrinterCoordinator.shared.isWorking)",
            "Internet: \(networkPathStatus)",
            "Pending uploads: \(pendingUploadCount)",
            "Storage: \(storageText)"
        ]
        if let record = auditRecords.last {
            lines += ["Latest print: \(record.timestamp.formatted())",
                      "Session: \(record.sessionIdentifier)", "Copy: \(record.copyIndex)/\(record.copyCount)",
                      "Transport: \(record.transport.rawValue)", "Result: \(record.terminalResult.operatorTitle)",
                      "Bytes started: \(record.bytesStarted)", "Fingerprint: \(record.payloadFingerprint.prefix(12))"]
        }
        // Deliberately omit free-form service errors, URLs, credentials, images and gallery tokens.
        return lines.joined(separator: "\n")
    }
}

extension GalleryDeliveryState {
    var operatorTitle: String {
        switch self {
        case .notStarted: "Waiting to upload"
        case .posted: "Posted; awaiting delivery confirmation"
        case .deliveryUnknown: "Delivery unknown; retry safely"
        }
    }
}
