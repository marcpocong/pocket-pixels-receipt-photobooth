//
//  HardwareQualificationStore.swift
//  PocketPixelsBooth
//
//  Durable qualification reports plus the isolated diagnostic namespace each run writes into.
//
//  Layout (Application Support/HardwareQualificationV1):
//    runs/<runID>.json                 durable report, survives relaunch
//    diagnostic/<runID>/archive        the run's own RecentSessionArchiveStore
//    diagnostic/<runID>/recovery       the run's own AppRecoveryStore
//    diagnostic/<runID>/audit.json     simulation-mode spooler audit
//
//  Customer archives (RecentSessionArchiveV1), recovery (AppRecoveryStateV1), pending galleries
//  and the production print audit live elsewhere and are never written or deleted from here.
//

import Foundation

nonisolated enum HardwareQualificationStoreError: Error, LocalizedError, Equatable {
    case runIsActive
    case unresolvedPrint
    case confirmationMismatch
    case outsideNamespace

    var errorDescription: String? {
        switch self {
        case .runIsActive: "Stop the run before cleaning up its diagnostic data."
        case .unresolvedPrint: "This run has an unresolved print. Inspect the printer and resolve it first."
        case .confirmationMismatch: "Type the run code exactly to confirm cleanup."
        case .outsideNamespace: "Refusing to delete a path outside the qualification namespace."
        }
    }
}

nonisolated struct HardwareQualificationStore: Sendable {
    static let directoryName = "HardwareQualificationV1"

    nonisolated(unsafe) private let fileManager: FileManager
    let rootURL: URL

    init(fileManager: FileManager = .default, rootURL: URL? = nil) throws {
        self.fileManager = fileManager
        if let rootURL {
            self.rootURL = rootURL
        } else {
            let support = try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            self.rootURL = support.appendingPathComponent(Self.directoryName, isDirectory: true)
        }
        try fileManager.createDirectory(at: runsURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: diagnosticURL, withIntermediateDirectories: true)
    }

    private var runsURL: URL { rootURL.appendingPathComponent("runs", isDirectory: true) }
    private var diagnosticURL: URL { rootURL.appendingPathComponent("diagnostic", isDirectory: true) }

    func diagnosticDirectory(for runID: UUID) -> URL {
        diagnosticURL.appendingPathComponent(runID.uuidString, isDirectory: true)
    }

    func archiveDirectory(for runID: UUID) -> URL {
        diagnosticDirectory(for: runID).appendingPathComponent("archive", isDirectory: true)
    }

    func recoveryDirectory(for runID: UUID) -> URL {
        diagnosticDirectory(for: runID).appendingPathComponent("recovery", isDirectory: true)
    }

    func auditURL(for runID: UUID) -> URL {
        diagnosticDirectory(for: runID).appendingPathComponent("audit.json")
    }

    private func recordURL(for runID: UUID) -> URL {
        runsURL.appendingPathComponent("\(runID.uuidString).json")
    }

    /// Durable (fsync + atomic rename). Throws so a caller that needs a pre-print checkpoint
    /// can fail closed.
    func save(_ record: QualificationRunRecord) throws {
        try fileManager.createDirectory(at: diagnosticDirectory(for: record.runID), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try DurableFileWriter.write(try encoder.encode(record), to: recordURL(for: record.runID), fileManager: fileManager)
    }

    func load(runID: UUID) throws -> QualificationRunRecord {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(QualificationRunRecord.self, from: Data(contentsOf: recordURL(for: runID)))
    }

    /// Newest first. Unreadable records are skipped, never deleted.
    func loadAll() -> [QualificationRunRecord] {
        let urls = (try? fileManager.contentsOfDirectory(at: runsURL, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return urls
            .filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(QualificationRunRecord.self, from: Data(contentsOf: $0)) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// Called once per launch. A run that was active in an earlier launch is marked INTERRUPTED,
    /// or HALTED if bytes may have been in flight. Nothing is resumed: no camera, no printing.
    @discardableResult
    func reconstructAfterLaunch(launchID: UUID = QualificationLaunch.current, now: Date = Date()) -> [QualificationRunRecord] {
        var changed: [QualificationRunRecord] = []
        for var record in loadAll() where record.launchID != launchID && record.state.isActive {
            if let inFlight = record.inFlightPrint {
                record.state = .haltedUncertainPrint
                record.log(.relaunch, session: inFlight.session, "App relaunched while copy \(inFlight.copyIndex) of \(inFlight.copyCount) may have been printing. Physical inspection required; it will never be resent automatically.", at: now)
                if let index = record.sessions.lastIndex(where: { $0.sessionNumber == inFlight.session }) {
                    record.sessions[index].outcome = .uncertainPrint
                    record.sessions[index].endedAt = record.sessions[index].endedAt ?? now
                    record.sessions[index].lastStage = "Print status unknown after relaunch"
                }
            } else {
                record.state = .interrupted
                record.log(.relaunch, "App relaunched during the run. Physical authorization was invalidated; camera capture and printing were not resumed.", at: now)
                if let index = record.sessions.lastIndex(where: { $0.endedAt == nil }) {
                    record.sessions[index].outcome = .interrupted
                    record.sessions[index].endedAt = now
                }
            }
            record.endedAt = record.endedAt ?? now
            record.launchID = launchID
            if (try? save(record)) != nil {
                changed.append(record)
            }
        }
        return changed
    }

    /// An earlier run left a print whose outcome is unknown. Blocks further qualification.
    var unresolvedPrintRun: QualificationRunRecord? {
        loadAll().first { $0.state == .haltedUncertainPrint && $0.inFlightPrint != nil }
    }

    /// Operator confirms the printer was physically inspected after an uncertain print.
    func acknowledgeUncertainPrint(runID: UUID, note: String, now: Date = Date()) throws {
        var record = try load(runID: runID)
        guard record.inFlightPrint != nil else { return }
        record.log(.recovery, session: record.inFlightPrint?.session, "Operator inspected the printer after an uncertain print: \(note.isEmpty ? "no note" : note). The copy was not resent.", at: now)
        record.inFlightPrint = nil
        try save(record)
    }

    func storageBytes(for runID: UUID) -> Int64 {
        directorySize(diagnosticDirectory(for: runID)) + fileSize(recordURL(for: runID))
    }

    var totalStorageBytes: Int64 {
        directorySize(rootURL)
    }

    /// Deletes a finished run's diagnostic artifacts after the operator types its short code.
    /// The report is kept unless `includingReport` is set. Never touches customer stores.
    func deleteDiagnosticArtifacts(runID: UUID, typedConfirmation: String, includingReport: Bool) throws {
        let record = try load(runID: runID)
        guard !record.state.isActive else { throw HardwareQualificationStoreError.runIsActive }
        guard record.inFlightPrint == nil else { throw HardwareQualificationStoreError.unresolvedPrint }
        guard typedConfirmation.trimmingCharacters(in: .whitespaces).uppercased() == record.shortID.uppercased() else {
            throw HardwareQualificationStoreError.confirmationMismatch
        }
        let target = diagnosticDirectory(for: runID).standardizedFileURL
        guard target.path.hasPrefix(diagnosticURL.standardizedFileURL.path + "/") else {
            throw HardwareQualificationStoreError.outsideNamespace
        }
        if fileManager.fileExists(atPath: target.path) {
            try fileManager.removeItem(at: target)
        }
        if includingReport {
            try fileManager.removeItem(at: recordURL(for: runID))
        }
    }

    private func fileSize(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    private func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}
