//
//  PrintSpooler.swift
//  PocketPixelsBooth
//

import OSLog
import Combine
import Foundation

struct PhysicalPrintTransportResult: Sendable {
    let transport: PrinterTransportSelection
    let bluetoothMode: BluetoothPrinterRasterMode?
    let chunkSize: Int?
    let chunkCount: Int?
    let flowControlPauseCount: Int?
    let writeTimeout: TimeInterval?
    let bytesStarted: Bool
    let transportFinishedAt: Date
}

/// Wraps a pre-print checkpoint so it is never confused with trailing state/completion closures.
struct PrePrintCheckpointGate {
    let persist: PrintSpooler.PrePrintCheckpoint
}

/// The durable pre-print safety checkpoint could not be written, so no bytes were sent.
enum PrintCheckpointError: Error, LocalizedError, Equatable {
    case persistenceFailed(String)

    var errorDescription: String? {
        switch self {
        case .persistenceFailed:
            "Nothing was printed. The iPad could not save its print safety checkpoint. Check free storage, then try printing again."
        }
    }

    /// Technical detail for diagnostics only (never shown to customers).
    var diagnosticDetail: String {
        switch self {
        case .persistenceFailed(let detail): detail
        }
    }
}

enum PrintSpoolerError: Error, LocalizedError {
    case physicalPrinterBusy
    case recoveryRequired(String)

    var errorDescription: String? {
        switch self {
        case .physicalPrinterBusy:
            "A printer job is already active. Wait for it to finish before starting another."
        case .recoveryRequired(let message):
            message
        }
    }
}

@MainActor
final class PrintSpooler: ObservableObject {
    typealias TransportOperation = @MainActor (PrintJobEnvelope) async -> Result<PhysicalPrintTransportResult, Error>
    /// Must durably persist crash-recovery state for this job. Throwing blocks the job before any
    /// bytes are sent (fail-closed).
    typealias PrePrintCheckpoint = @MainActor (PrintJobEnvelope) throws -> Void

    static let shared = PrintSpooler()

    @Published private(set) var activeJobID: UUID?
    @Published private(set) var activeSessionIdentifier: String?
    @Published private(set) var activeSource: PrintJobSource?
    @Published private(set) var queuedJobCount = 0
    @Published private(set) var recoveryReason: String?

    private let auditStore: PrintAuditStore?
    private var tailTask: Task<Void, Never> = Task {}
    private let conservativeThermalPrintMillimetersPerSecond: Double = 34
    private let cutAndSettleDelay: TimeInterval = 1.75
    private let minimumPhysicalHandoffDelay: TimeInterval = 1.5
    private let waitsForPhysicalHandoff: Bool
    private let writesAuditSynchronously: Bool

    init(
        auditStore: PrintAuditStore? = try? PrintAuditStore(),
        waitsForPhysicalHandoff: Bool = true,
        writesAuditSynchronously: Bool = false
    ) {
        self.auditStore = auditStore
        self.waitsForPhysicalHandoff = waitsForPhysicalHandoff
        self.writesAuditSynchronously = writesAuditSynchronously
    }

    var isWorking: Bool {
        activeJobID != nil || queuedJobCount > 0
    }

    var requiresRecovery: Bool {
        recoveryReason != nil
    }

    var auditExportText: String {
        auditStore?.exportText() ?? "Print audit storage is unavailable."
    }

    func confirmPrinterRestarted() {
        recoveryReason = nil
    }

    func submit(
        envelope: PrintJobEnvelope,
        prePrintCheckpoint: PrePrintCheckpoint? = nil,
        transport: @escaping TransportOperation
    ) async -> Result<PhysicalPrintTransportResult, Error> {
        let previousTail = tailTask
        queuedJobCount += 1
        let waiter = Task { await previousTail.value }

        let currentTask = Task { @MainActor [weak self] in
            await waiter.value
            return await self?.run(envelope: envelope, prePrintCheckpoint: prePrintCheckpoint, transport: transport)
                ?? .failure(PrintSpoolerError.physicalPrinterBusy)
        }

        tailTask = Task { _ = await currentTask.value }
        return await currentTask.value
    }

    private func run(
        envelope: PrintJobEnvelope,
        prePrintCheckpoint: PrePrintCheckpoint?,
        transport: @escaping TransportOperation
    ) async -> Result<PhysicalPrintTransportResult, Error> {
        if let recoveryReason {
            queuedJobCount = max(0, queuedJobCount - 1)
            audit(
                envelope: envelope,
                startedAt: Date(),
                transportResult: nil,
                releasedAt: Date(),
                terminalResult: .failedBeforeBytes,
                recoveryReason: recoveryReason,
                writeTimeout: nil
            )
            return .failure(PrintSpoolerError.recoveryRequired(recoveryReason))
        }

        do {
            try envelope.verifyPayloadIntegrity()
        } catch {
            queuedJobCount = max(0, queuedJobCount - 1)
            audit(
                envelope: envelope,
                startedAt: Date(),
                transportResult: nil,
                releasedAt: Date(),
                terminalResult: .failedBeforeBytes,
                recoveryReason: error.localizedDescription,
                writeTimeout: nil
            )
            return .failure(error)
        }

        // Fail-closed: the crash-recovery checkpoint is written after this job reaches the front
        // of the queue and immediately before transport. If it cannot be persisted, the
        // transport is never invoked, so zero bytes reach the printer and no recovery lock is set.
        if let prePrintCheckpoint {
            do {
                try prePrintCheckpoint(envelope)
            } catch {
                queuedJobCount = max(0, queuedJobCount - 1)
                let failure = (error as? PrintCheckpointError) ?? .persistenceFailed(error.localizedDescription)
                audit(
                    envelope: envelope,
                    startedAt: Date(),
                    transportResult: nil,
                    releasedAt: Date(),
                    terminalResult: .failedBeforeBytes,
                    recoveryReason: "Pre-print checkpoint not persisted: \(failure.diagnosticDetail)",
                    writeTimeout: nil
                )
                BoothDiagnostics.recovery.error("Pre-print checkpoint failed; job blocked before bytes. detail=\(failure.diagnosticDetail, privacy: .public)")
                return .failure(failure)
            }
        }

        queuedJobCount = max(0, queuedJobCount - 1)
        activeJobID = envelope.jobID
        activeSessionIdentifier = envelope.sessionIdentifier
        activeSource = envelope.source

        let startedAt = Date()
        let result = await transport(envelope)
        let transportCompletedAt = Date()

        switch result {
        case .success(let transportResult):
            await waitForPhysicalHandoff(envelope: envelope, startedAt: startedAt, transportFinishedAt: transportResult.transportFinishedAt)
            let releaseAt = Date()
            audit(
                envelope: envelope,
                startedAt: startedAt,
                transportResult: transportResult,
                releasedAt: releaseAt,
                terminalResult: .completed,
                recoveryReason: nil,
                writeTimeout: transportResult.writeTimeout
            )
        case .failure(let error):
            let bytesStarted = (error as? PrintTransportFailure)?.bytesStarted ?? false
            let transportResult = (error as? PrintTransportFailure)?.transportResult
            let terminal: PrintAuditRecord.TerminalResult = bytesStarted ? .recoveryRequiredAfterBytes : .failedBeforeBytes
            if bytesStarted {
                recoveryReason = error.localizedDescription
                await waitForPhysicalHandoff(envelope: envelope, startedAt: startedAt, transportFinishedAt: transportResult?.transportFinishedAt ?? transportCompletedAt)
            }
            let releaseAt = Date()
            audit(
                envelope: envelope,
                startedAt: startedAt,
                transportResult: transportResult,
                releasedAt: releaseAt,
                terminalResult: terminal,
                recoveryReason: error.localizedDescription,
                writeTimeout: transportResult?.writeTimeout
            )
        }

        activeJobID = nil
        activeSessionIdentifier = nil
        activeSource = nil
        return result
    }

    private func waitForPhysicalHandoff(
        envelope: PrintJobEnvelope,
        startedAt: Date,
        transportFinishedAt: Date
    ) async {
        guard waitsForPhysicalHandoff else {
            return
        }

        let receiptLengthMillimeters = Double(envelope.imageHeight) / 8.0
        let estimatedPhysicalDuration = (receiptLengthMillimeters / conservativeThermalPrintMillimetersPerSecond) + cutAndSettleDelay
        let elapsedSinceStart = transportFinishedAt.timeIntervalSince(startedAt)
        let remaining = max(minimumPhysicalHandoffDelay, estimatedPhysicalDuration - elapsedSinceStart)

        guard remaining > 0 else {
            return
        }

        try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
    }

    private func audit(
        envelope: PrintJobEnvelope,
        startedAt: Date,
        transportResult: PhysicalPrintTransportResult?,
        releasedAt: Date,
        terminalResult: PrintAuditRecord.TerminalResult,
        recoveryReason: String?,
        writeTimeout: TimeInterval?
    ) {
        let record = PrintAuditRecord(
            id: UUID(),
            timestamp: Date(),
            jobID: envelope.jobID,
            batchID: envelope.batchID,
            sessionIdentifier: envelope.sessionIdentifier,
            source: envelope.source,
            copyIndex: envelope.copyIndex,
            copyCount: envelope.copyCount,
            payloadFingerprint: envelope.payloadFingerprint,
            payloadByteCount: envelope.payloadByteCount,
            imageWidth: envelope.imageWidth,
            imageHeight: envelope.imageHeight,
            rasterByteCount: envelope.rasterByteCount,
            transport: transportResult?.transport ?? .none,
            bluetoothMode: transportResult?.bluetoothMode,
            chunkSize: transportResult?.chunkSize,
            chunkCount: transportResult?.chunkCount,
            startedAt: startedAt,
            transportFinishedAt: transportResult?.transportFinishedAt,
            physicalOwnershipReleasedAt: releasedAt,
            transportDuration: transportResult.map { $0.transportFinishedAt.timeIntervalSince(startedAt) },
            handoffDuration: max(0, releasedAt.timeIntervalSince(transportResult?.transportFinishedAt ?? startedAt)),
            flowControlPauseCount: transportResult?.flowControlPauseCount,
            writeTimeout: writeTimeout,
            bytesStarted: transportResult?.bytesStarted ?? false,
            terminalResult: terminalResult,
            recoveryReason: recoveryReason
        )

        if writesAuditSynchronously {
            auditStore?.append(record)
        } else {
            Task.detached(priority: .utility) { [auditStore] in
                auditStore?.append(record)
            }
        }
    }
}

struct PrintTransportFailure: Error, LocalizedError {
    let underlyingError: Error
    let bytesStarted: Bool
    let transportResult: PhysicalPrintTransportResult?

    var errorDescription: String? {
        underlyingError.localizedDescription
    }
}
