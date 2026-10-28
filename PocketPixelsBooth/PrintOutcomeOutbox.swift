import Foundation

/// Local physical outcome of one copy attempt. Evidence only ever weakens toward `uncertain`.
nonisolated enum PrintCopyLocalState: String, Codable, Sendable {
    /// Durably recorded immediately before the transport starts. Never resent automatically.
    case inFlight
    /// The transport refused or failed before any byte was sent: conclusively not printed.
    case notStarted
    /// Every byte was accepted by the transport and the physical handoff elapsed. Paper is not
    /// sensor-verified (raw TCP / BLE only confirm delivery).
    case delivered
    /// Bytes may have reached the printer, or the app stopped while sending: inspect the paper.
    case uncertain

    /// Server outcome to report; `notStarted` is local evidence only so the copy can be retried.
    var serverOutcome: String? {
        switch self {
        case .delivered: "DELIVERED"
        case .uncertain: "UNCERTAIN"
        case .inFlight, .notStarted: nil
        }
    }

    /// The copy may have produced paper, so it must never be sent again automatically.
    var mayHavePrinted: Bool { self != .notStarted }
}

nonisolated enum OutboxReportState: String, Codable, Sendable {
    /// Waiting for a final local outcome.
    case awaitingOutcome
    case pending
    case delivered
    /// The server refused the record; kept for operator review, never retried blindly.
    case conflict
    /// Nothing to report (local prepaid / offline cash entitlement, or no-byte attempt).
    case notApplicable
}

nonisolated struct PrintOutboxEntry: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable { case copy, completion }

    let id: String
    let kind: Kind
    let batchID: String
    let sessionID: String
    /// Server entitlement ID, or nil for prepaid / offline-cash sessions (local evidence only).
    let entitlementID: String?
    let receiptFingerprint: String
    let copyIndex: Int
    let copyCount: Int
    var transport: String
    /// Stable server idempotency key; identical on every replay.
    let idempotencyKey: String
    let createdAt: Date
    var localState: PrintCopyLocalState
    var reportState: OutboxReportState
    var attempts: Int
    var nextAttemptAt: Date?
    var lastError: String?
    var updatedAt: Date
    var inspectionRequired: Bool? = nil
    var hardwareAcknowledgedAt: Date? = nil
    var source: PrintJobSource? = nil
    /// Older journals contain only customer copies. Operator batches never fulfill a purchase.
    var isCustomerCopy: Bool { kind == .copy && (source == nil || source == .liveCustomer) }
}

/// Durable journal of every live-customer copy attempt plus an outbox of server reports.
///
/// - `beginCopy` runs inside the print spooler's fail-closed gate: if it cannot be persisted, the
///   copy is never sent. A copy that already may have printed can never be begun again.
/// - Final outcomes and reports are persisted before being acknowledged; anything still
///   `inFlight` after a relaunch becomes `uncertain` and is reported, never resent.
/// - Reports replay with unchanged idempotency keys and bounded backoff; server conflicts are
///   quarantined for operator review.
@MainActor
final class PrintOutcomeOutbox {
    nonisolated enum OutboxError: Error, LocalizedError, Equatable {
        case persistFailed(String)
        case integrityFault(String)
        case copyAlreadyAttempted(Int)
        case receiptChanged

        var errorDescription: String? {
            switch self {
            case .persistFailed(let detail): "The print record could not be saved (\(detail))."
            case .integrityFault(let detail): "Print accounting is blocked: \(detail)"
            case .copyAlreadyAttempted(let copy): "Copy \(copy) may already have printed. Inspect the paper; it will not be sent again automatically."
            case .receiptChanged: "This receipt differs from copies already printed for this purchase. Ask the attendant."
            }
        }
    }

    typealias Writer = (Data, URL) throws -> Void

    static let shared: PrintOutcomeOutbox? = try? PrintOutcomeOutbox()

    private struct FilePayload: Codable {
        var entries: [PrintOutboxEntry]
        var hardwareActions: [PrinterHardwareAction]? = nil
    }
    struct PrinterHardwareAction: Codable, Sendable {
        let kind: String
        let at: Date
    }
    var hardwareActions: [PrinterHardwareAction] { payload.hardwareActions ?? [] }
    func recordHardwareAction(_ kind: String) throws {
        var candidate = payload
        candidate.hardwareActions = Array(((candidate.hardwareActions ?? []) + [PrinterHardwareAction(kind: kind, at: Date())]).suffix(300))
        try commit(candidate)
    }

    private let url: URL
    private let writer: Writer
    private var payload = FilePayload(entries: [])
    private(set) var integrityFault: String?
    private(set) var persistenceFailure: String?
    /// Only failed launch recovery can be retried as recovery; never convert a live send.
    private var launchRecoveryPending = false
    private var failedFinishes: [String: PrintCopyLocalState] = [:]
    private var failedCompletions: [String: (batch: String, session: String)] = [:]
    private var isSyncing = false
    static let retainedDeliveredCount = 300

    init(fileManager: FileManager = .default, directory: URL? = nil, writer: Writer? = nil) throws {
        let root = directory ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? fileManager.temporaryDirectory
        url = root.appendingPathComponent("PaymentState", isDirectory: true).appendingPathComponent("print-outbox.json")
        self.writer = writer ?? { data, url in
            try DurableFileWriter.write(data, to: url)
            PaymentStateFileProtection.apply(to: url)
        }
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard fileManager.fileExists(atPath: url.path) else { return }
        do {
            payload = try PaymentsJSON.decoder().decode(FilePayload.self, from: Data(contentsOf: url))
        } catch {
            // Keep the unreadable journal for audit and stop printing paid copies until reviewed.
            let quarantine = url.deletingLastPathComponent().appendingPathComponent("print-outbox.corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? fileManager.copyItem(at: url, to: quarantine)
            integrityFault = "the print journal was unreadable and was set aside for review (\(quarantine.lastPathComponent))."
        }
    }

    var entries: [PrintOutboxEntry] { payload.entries }

    static func idempotencyKey(batchID: String, copyIndex: Int) -> String {
        "print-\(batchID)-\(copyIndex)"
    }

    /// First copy index (1-based) that has never possibly printed in this batch, or nil when all
    /// paid copies have already been attempted with paper possibly produced.
    func nextCopyToPrint(batchID: String, copyCount: Int) -> Int? {
        let attempted = Set(payload.entries.filter { $0.kind == .copy && $0.batchID == batchID && $0.localState.mayHavePrinted }.map(\.copyIndex))
        return (1...max(1, copyCount)).first { !attempted.contains($0) }
    }

    func copiesThatMayHavePrinted(sessionID: String) -> [PrintOutboxEntry] {
        payload.entries.filter { $0.isCustomerCopy && $0.sessionID == sessionID && $0.localState.mayHavePrinted }
    }

    var latestInterruptedSessionID: String? {
        guard let last = payload.entries.last(where: { $0.isCustomerCopy }),
              last.localState == .uncertain || last.localState == .notStarted else { return nil }
        return last.sessionID
    }

    func latestBatchEntries(sessionID: String) -> [PrintOutboxEntry] {
        let copies = payload.entries.filter { $0.isCustomerCopy && $0.sessionID == sessionID }
        guard let batch = copies.last?.batchID else { return [] }
        return copies.filter { $0.batchID == batch }
    }

    /// Durable intent written immediately before bytes are sent. Throwing blocks the copy.
    func beginCopy(batchID: String, sessionID: String, entitlementID: String?, receiptFingerprint: String,
                   copyIndex: Int, copyCount: Int, transport: String, now: Date = Date(), source: PrintJobSource? = nil) throws {
        if let integrityFault { throw OutboxError.integrityFault(integrityFault) }
        let batch = payload.entries.filter { $0.kind == .copy && $0.batchID == batchID }
        if batch.contains(where: { $0.copyIndex == copyIndex && $0.localState.mayHavePrinted }) {
            throw OutboxError.copyAlreadyAttempted(copyIndex)
        }
        if let printed = batch.first(where: { $0.localState.mayHavePrinted }), printed.receiptFingerprint != receiptFingerprint {
            throw OutboxError.receiptChanged
        }
        let entry = PrintOutboxEntry(
            id: "\(batchID)-\(copyIndex)-\(batch.filter { $0.copyIndex == copyIndex }.count + 1)",
            kind: .copy, batchID: batchID, sessionID: sessionID, entitlementID: entitlementID,
            receiptFingerprint: receiptFingerprint, copyIndex: copyIndex, copyCount: copyCount, transport: transport,
            idempotencyKey: Self.idempotencyKey(batchID: batchID, copyIndex: copyIndex), createdAt: now,
            localState: .inFlight, reportState: .awaitingOutcome, attempts: 0, nextAttemptAt: nil, lastError: nil, updatedAt: now, source: source
        )
        var candidate = payload
        candidate.entries.append(entry)
        try commit(candidate)
    }

    /// Refines the already-durable intent after the coordinator resolves the concrete transport
    /// and immediately before that transport may send bytes. A failed write blocks printing.
    func selectTransportBeforeBytes(
        batchID: String,
        copyIndex: Int,
        transport: PrinterTransportSelection,
        now: Date = Date()
    ) throws {
        guard transport != .none,
              let index = payload.entries.lastIndex(where: {
                  $0.kind == .copy && $0.batchID == batchID && $0.copyIndex == copyIndex && $0.localState == .inFlight
              }) else {
            throw OutboxError.persistFailed("the in-flight copy was not found")
        }
        var candidate = payload
        candidate.entries[index].transport = transport.rawValue
        candidate.entries[index].updatedAt = now
        try commit(candidate)
    }

    /// Records the transport result for the in-flight copy. If this write fails the entry stays
    /// `inFlight` on disk and becomes `uncertain` at the next launch (conservative, never lost).
    @discardableResult
    func finishCopy(batchID: String, copyIndex: Int, state: PrintCopyLocalState, now: Date = Date()) -> Bool {
        guard state != .inFlight,
              let index = payload.entries.lastIndex(where: { $0.kind == .copy && $0.batchID == batchID && $0.copyIndex == copyIndex && $0.localState == .inFlight }) else { return false }
        var candidate = payload
        candidate.entries[index].inspectionRequired = state == .uncertain
        candidate.entries[index].localState = state
        candidate.entries[index].reportState = (state.serverOutcome != nil && candidate.entries[index].entitlementID != nil) ? .pending : .notApplicable
        candidate.entries[index].updatedAt = now
        let id = candidate.entries[index].id
        do {
            try commit(candidate)
            failedFinishes[id] = nil
            return true
        } catch {
            failedFinishes[id] = state
            return false
        }
    }

    /// Queues entitlement completion after the last copy. Replays are idempotent server-side.
    @discardableResult
    func enqueueCompletion(batchID: String, sessionID: String, entitlementID: String, now: Date = Date()) -> Bool {
        guard !payload.entries.contains(where: { $0.kind == .completion && $0.entitlementID == entitlementID }) else { return true }
        let entry = PrintOutboxEntry(
            id: "\(batchID)-complete", kind: .completion, batchID: batchID, sessionID: sessionID, entitlementID: entitlementID,
            receiptFingerprint: "", copyIndex: 0, copyCount: 0, transport: "", idempotencyKey: "complete-\(entitlementID)", createdAt: now,
            localState: .delivered, reportState: .pending, attempts: 0, nextAttemptAt: nil, lastError: nil, updatedAt: now
        )
        var candidate = payload
        candidate.entries.append(entry)
        do {
            try commit(candidate)
            failedCompletions[entitlementID] = nil
            return true
        } catch {
            failedCompletions[entitlementID] = (batchID, sessionID)
            return false
        }
    }

    /// After a relaunch nothing is still sending, so any `inFlight` copy is ambiguous.
    @discardableResult
    func recoverAfterLaunch(now: Date = Date()) -> Int {
        var candidate = payload
        var changed = 0
        for index in candidate.entries.indices where candidate.entries[index].localState == .inFlight {
            candidate.entries[index].inspectionRequired = true
            candidate.entries[index].localState = .uncertain
            candidate.entries[index].reportState = candidate.entries[index].entitlementID == nil ? .notApplicable : .pending
            candidate.entries[index].lastError = "app_stopped_during_transport"
            candidate.entries[index].updatedAt = now
            changed += 1
        }
        guard changed > 0 else { launchRecoveryPending = false; return 0 }
        do {
            try commit(candidate)
            launchRecoveryPending = false
            return changed
        } catch {
            launchRecoveryPending = true
            return 0
        }
    }

    func retryLaunchRecovery() {
        if launchRecoveryPending { recoverAfterLaunch() }
        for (id, state) in failedFinishes {
            guard let entry = payload.entries.first(where: { $0.id == id }) else { continue }
            finishCopy(batchID: entry.batchID, copyIndex: entry.copyIndex, state: state)
        }
        for (entitlement, value) in failedCompletions {
            enqueueCompletion(batchID: value.batch, sessionID: value.session, entitlementID: entitlement)
        }
        if !launchRecoveryPending && failedFinishes.isEmpty && failedCompletions.isEmpty && persistenceFailure != nil { try? commit(payload) }
    }

    var inspectionEntryIDs: Set<String> {
        Set(payload.entries.filter { $0.inspectionRequired == true }.map(\.id))
    }
    /// Exact copy identities captured when the confirmation was shown; a newer failure must
    /// get its own physical check. The unknown local outcome and report state never change.
    func acknowledgeInspection(entryIDs: Set<String>) throws {
        guard entryIDs == inspectionEntryIDs else { throw OutboxError.persistFailed("A different receipt now needs inspection. Review Receipt again.") }
        var candidate = payload
        candidate.hardwareActions = (candidate.hardwareActions ?? []) + [PrinterHardwareAction(kind: "operator_acknowledged_current_hardware_readiness", at: Date())]
        for index in candidate.entries.indices where entryIDs.contains(candidate.entries[index].id) {
            candidate.entries[index].inspectionRequired = false
            candidate.entries[index].hardwareAcknowledgedAt = Date()
        }
        try commit(candidate)
    }


    func dueReports(now: Date = Date()) -> [PrintOutboxEntry] {
        payload.entries.filter { entry in
            guard entry.reportState == .pending else { return false }
            if entry.kind == .completion {
                // Completion only after every copy report of the batch left the device.
                let copies = payload.entries.filter { $0.kind == .copy && $0.batchID == entry.batchID }
                guard !copies.contains(where: { $0.reportState == .pending || $0.reportState == .awaitingOutcome }) else { return false }
            }
            return (entry.nextAttemptAt ?? .distantPast) <= now
        }
    }

    /// Operation gates use current work, never the historical `uncertain` count below.
    var hasUnfinishedPhysicalSend: Bool {
        payload.entries.contains { $0.kind == .copy && ($0.localState == .inFlight || $0.reportState == .awaitingOutcome) }
    }

    /// Keep the original payments connection until its reports can be delivered/reviewed.
    /// An old local or already reported uncertain receipt has no such server obligation.
    var hasUnresolvedServerReports: Bool {
        payload.entries.contains { $0.entitlementID != nil && [.pending, .conflict, .awaitingOutcome].contains($0.reportState) }
    }

    /// Accounting/history only. These totals are not a booth readiness or admission decision.
    var summary: (pending: Int, conflicts: Int, uncertain: Int, awaiting: Int) {
        (payload.entries.filter { $0.reportState == .pending }.count,
         payload.entries.filter { $0.reportState == .conflict }.count,
         payload.entries.filter { $0.localState == .uncertain }.count,
         payload.entries.filter { $0.reportState == .awaitingOutcome }.count)
    }

    var conflicts: [PrintOutboxEntry] { payload.entries.filter { $0.reportState == .conflict } }

    @discardableResult
    func markReported(id: String, now: Date = Date()) -> Bool {
        mutate(id: id, now: now) { $0.reportState = .delivered; $0.lastError = nil; $0.nextAttemptAt = nil }
    }

    func markConflict(id: String, code: String, now: Date = Date()) {
        mutate(id: id, now: now) { $0.reportState = .conflict; $0.lastError = code }
    }

    func markRetry(id: String, code: String, now: Date = Date()) {
        mutate(id: id, now: now) { entry in
            entry.attempts += 1
            // Bounded exponential backoff: 5 s, 10 s, 20 s … capped at 15 minutes.
            let delay = min(900, 5 * pow(2, Double(min(entry.attempts - 1, 8))))
            entry.nextAttemptAt = now.addingTimeInterval(delay)
            entry.lastError = code
        }
    }

    /// Sends due reports. Unreachable server → retry later; definitive refusal → conflict.
    func sync(using client: PaymentsAPIClient, now: Date = Date()) async -> (sent: Int, conflicts: Int, retries: Int) {
        guard !isSyncing else { return (0, 0, 0) }
        isSyncing = true
        defer { isSyncing = false }
        var sent = 0, conflicted = 0, retries = 0
        var attemptedEntryIDs = Set<String>()
        while true {
            // A completion becomes due only after every copy report in its batch is acknowledged.
            // Drain again in the same sync so an overlapping background trigger cannot strand it.
            let entries = dueReports(now: now).filter { !attemptedEntryIDs.contains($0.id) }
            guard !entries.isEmpty else { break }
            for entry in entries {
                attemptedEntryIDs.insert(entry.id)
                guard let entitlementID = entry.entitlementID else { continue }
                do {
                    switch entry.kind {
                    case .copy:
                        guard let outcome = entry.localState.serverOutcome else { continue }
                        try await client.recordPrint(PrintProgressRecord(
                            batchID: entry.batchID, entitlementId: entitlementID, sessionId: entry.sessionID,
                            receiptFingerprint: entry.receiptFingerprint, copyIndex: entry.copyIndex, outcome: outcome,
                            transport: entry.transport, idempotencyKey: entry.idempotencyKey))
                    case .completion:
                        try await client.complete(entitlementID: entitlementID, sessionID: entry.sessionID)
                    }
                    if markReported(id: entry.id) { sent += 1 }
                    else { retries += 1 }
                } catch let error as PaymentsAPIError {
                    switch error {
                    case .rejected(let code, _, let status, _) where status != 429 && status < 500:
                        markConflict(id: entry.id, code: code)
                        conflicted += 1
                    case .rejected(let code, _, _, _):
                        markRetry(id: entry.id, code: code)
                        retries += 1
                    case .outcomeUnknown, .unavailable, .unauthorized, .invalidResponse, .configuration:
                        markRetry(id: entry.id, code: String(describing: error).prefix(40).description)
                        retries += 1
                    }
                } catch {
                    markRetry(id: entry.id, code: "transport")
                    retries += 1
                }
            }
        }
        return (sent, conflicted, retries)
    }

    @discardableResult
    private func mutate(id: String, now: Date, _ change: (inout PrintOutboxEntry) -> Void) -> Bool {
        guard let index = payload.entries.firstIndex(where: { $0.id == id }) else { return false }
        var candidate = payload
        change(&candidate.entries[index])
        candidate.entries[index].updatedAt = now
        return (try? commit(candidate)) != nil
    }

    private func commit(_ candidate: FilePayload) throws {
        if let integrityFault { throw OutboxError.integrityFault(integrityFault) }
        var pruned = candidate
        // Keep every copy in an uncertain batch, including earlier reported sends. Otherwise
        // pruning successful copies would turn missing historical evidence into "not started".
        let protectedBatches = Set(pruned.entries.filter {
            $0.localState == .uncertain || $0.localState == .inFlight || $0.inspectionRequired == true ||
            [.pending, .conflict, .awaitingOutcome].contains($0.reportState)
        }.map(\.batchID))
        let settled = pruned.entries.enumerated().filter {
            !protectedBatches.contains($0.element.batchID) && [.delivered, .notApplicable].contains($0.element.reportState)
        }
        if settled.count > Self.retainedDeliveredCount {
            let drop = Set(settled.prefix(settled.count - Self.retainedDeliveredCount).map(\.offset))
            pruned.entries = pruned.entries.enumerated().filter { !drop.contains($0.offset) }.map(\.element)
        }
        do {
            try writer(try PaymentsJSON.encoder().encode(pruned), url)
        } catch {
            persistenceFailure = "Print journal could not be saved. Retry Saving Resolution; the original print evidence is retained. \(error.localizedDescription)"
            throw OutboxError.persistFailed(error.localizedDescription)
        }
        if !launchRecoveryPending && failedFinishes.isEmpty && failedCompletions.isEmpty { persistenceFailure = nil }
        payload = pruned
    }
}

/// Payment state files: device-only, excluded from backup, unreadable before first unlock.
nonisolated enum PaymentStateFileProtection {
    static func apply(to url: URL) {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try? mutableURL.setResourceValues(values)
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
    }
}
