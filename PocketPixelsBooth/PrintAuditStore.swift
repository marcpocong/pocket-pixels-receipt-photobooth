//
//  PrintAuditStore.swift
//  PocketPixelsBooth
//

import Foundation

struct PrintAuditRecord: Codable, Identifiable, Sendable {
    enum TerminalResult: String, Codable, Sendable {
        case completed
        case failedBeforeBytes
        case recoveryRequiredAfterBytes
        case cancelledBeforeBytes
    }

    let id: UUID
    let timestamp: Date
    let jobID: UUID
    let batchID: UUID
    let sessionIdentifier: String
    let source: PrintJobSource
    let copyIndex: Int
    let copyCount: Int
    let payloadFingerprint: String
    let payloadByteCount: Int
    let imageWidth: Int
    let imageHeight: Int
    let rasterByteCount: Int
    let transport: PrinterTransportSelection
    let bluetoothMode: BluetoothPrinterRasterMode?
    let chunkSize: Int?
    let chunkCount: Int?
    let startedAt: Date
    let transportFinishedAt: Date?
    let physicalOwnershipReleasedAt: Date
    let transportDuration: TimeInterval?
    let handoffDuration: TimeInterval
    let flowControlPauseCount: Int?
    let writeTimeout: TimeInterval?
    let bytesStarted: Bool
    let terminalResult: TerminalResult
    let recoveryReason: String?
}

nonisolated struct PrintAuditStore: Sendable {
    static let retentionCount = 200

    nonisolated(unsafe) private let fileManager: FileManager
    private let fileURL: URL

    nonisolated init(fileManager: FileManager = .default, fileURL: URL? = nil) throws {
        self.fileManager = fileManager
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let supportURL = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let directoryURL = supportURL.appendingPathComponent("PrintAudit", isDirectory: true)
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            self.fileURL = directoryURL.appendingPathComponent("rolling-print-audit-v1.json")
        }
    }

    nonisolated var storagePath: String {
        fileURL.path
    }

    nonisolated func append(_ record: PrintAuditRecord) {
        do {
            var records = try load()
            records.append(record)
            if records.count > Self.retentionCount {
                records.removeFirst(records.count - Self.retentionCount)
            }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(records)
            try data.write(to: fileURL, options: .atomic)
        } catch {
#if DEBUG
            print("[PrintAuditStore] append failed: \(error.localizedDescription)")
#endif
        }
    }

    nonisolated func load() throws -> [PrintAuditRecord] {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return []
        }
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([PrintAuditRecord].self, from: data)
    }

    nonisolated func exportText(limit: Int = 200) -> String {
        do {
            return try load()
                .suffix(limit)
                .map { record in
                    [
                        record.startedAt.formatted(date: .numeric, time: .standard),
                        "job=\(record.jobID.uuidString)",
                        "batch=\(record.batchID.uuidString)",
                        "session=\(record.sessionIdentifier)",
                        "source=\(record.source.rawValue)",
                        "copy=\(record.copyIndex)/\(record.copyCount)",
                        "payload=\(record.payloadFingerprint.prefix(12)) bytes=\(record.payloadByteCount)",
                        "image=\(record.imageWidth)x\(record.imageHeight)",
                        "transport=\(record.transport.rawValue)",
                        "ble=\(record.bluetoothMode?.rawValue ?? "n/a")",
                        "chunk=\(record.chunkSize.map(String.init) ?? "n/a")x\(record.chunkCount.map(String.init) ?? "n/a")",
                        "bytesStarted=\(record.bytesStarted)",
                        "result=\(record.terminalResult.rawValue)",
                        "transportDuration=\(record.transportDuration.map { String(format: "%.2f", $0) } ?? "n/a")",
                        "handoff=\(String(format: "%.2f", record.handoffDuration))",
                        "recovery=\(record.recoveryReason ?? "none")"
                    ].joined(separator: " ")
                }
                .joined(separator: "\n")
        } catch {
            return "Print audit unavailable: \(error.localizedDescription)"
        }
    }
}
