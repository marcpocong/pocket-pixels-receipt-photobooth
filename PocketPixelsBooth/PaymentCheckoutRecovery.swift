import Combine
import Foundation

/// Where a paid checkout was when the last durable checkpoint was written.
nonisolated enum CheckoutPhase: String, Codable, Sendable, Comparable {
    /// Written before the first server mutation; an order may or may not exist.
    case orderRequested
    /// A payment request (QR creation / cash declaration) may have reached the server.
    case paymentRequested
    /// A QR was shown; the guest may be paying.
    case awaitingProvider
    /// The server (or offline ledger) authorized an entitlement.
    case entitled
    /// The entitlement is bound to this checkout session; capture may have started.
    case claimed
    /// At least one copy was sent to the printer.
    case printing
    case completed

    private var rank: Int { [.orderRequested, .paymentRequested, .awaitingProvider, .entitled, .claimed, .printing, .completed].firstIndex(of: self) ?? 0 }
    static func < (lhs: CheckoutPhase, rhs: CheckoutPhase) -> Bool { lhs.rank < rhs.rank }
}

/// Minimal, non-secret record of one paid checkout. No tokens, keys, QR images, photos or guest
/// personal data are stored. Keyed by the checkout session ID the server also stores.
nonisolated struct CheckoutCheckpoint: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let environment: String
    var deviceID: String?
    var accountID: String?
    let eventID: String
    let policyRevisionID: String
    let unitPriceCentavos: Int
    let copies: Int
    let format: String
    /// `QRPH`, `CASH_DECLARED` or `OFFLINE_CASH` once a method was chosen.
    var method: String?
    var orderID: String?
    var entitlementID: String?
    var offlineRecordID: String?
    var phase: CheckoutPhase
    var lastServerState: String?
    let createdAt: Date
    var updatedAt: Date
    var resolution: String?
    var resolvedAt: Date?

    var isResolved: Bool { resolution != nil }
}

/// Durable store of checkout checkpoints, written with the same commit-after-write discipline as
/// the offline cash journal.
@MainActor
final class CheckoutCheckpointStore {
    nonisolated enum StoreError: Error, LocalizedError, Equatable {
        case persistFailed(String)
        case integrityFault(String)

        var errorDescription: String? {
            switch self {
            case .persistFailed(let detail): "Payment could not start: this iPad could not save its checkout record (\(detail))."
            case .integrityFault(let detail): "Paid checkout is blocked: \(detail)"
            }
        }
    }

    typealias Writer = (Data, URL) throws -> Void
    static let shared: CheckoutCheckpointStore? = try? CheckoutCheckpointStore()
    static let retainedResolvedCount = 100

    private struct FilePayload: Codable { var checkpoints: [CheckoutCheckpoint] }

    private let url: URL
    private let writer: Writer
    private var payload = FilePayload(checkpoints: [])
    private(set) var integrityFault: String?

    init(fileManager: FileManager = .default, directory: URL? = nil, writer: Writer? = nil) throws {
        let root = directory ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? fileManager.temporaryDirectory
        url = root.appendingPathComponent("PaymentState", isDirectory: true).appendingPathComponent("checkout-checkpoints.json")
        self.writer = writer ?? { data, url in
            try DurableFileWriter.write(data, to: url)
            PaymentStateFileProtection.apply(to: url)
        }
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard fileManager.fileExists(atPath: url.path) else { return }
        do {
            payload = try PaymentsJSON.decoder().decode(FilePayload.self, from: Data(contentsOf: url))
        } catch {
            let quarantine = url.deletingLastPathComponent().appendingPathComponent("checkout-checkpoints.corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? fileManager.moveItem(at: url, to: quarantine)
            integrityFault = "the checkout record file was unreadable and was set aside for review (\(quarantine.lastPathComponent)). Check server orders for this iPad."
        }
        // Older builds could resolve an empty recovery response while order creation was still
        // in flight, then save its successful response without reopening the checkpoint.
        var repaired = payload
        for index in repaired.checkpoints.indices where Self.hasStaleNoPaymentResolution(repaired.checkpoints[index]) {
            repaired.checkpoints[index].resolution = nil
            repaired.checkpoints[index].resolvedAt = nil
        }
        if repaired.checkpoints != payload.checkpoints { try commit(repaired) }
    }

    private static func hasStaleNoPaymentResolution(_ checkpoint: CheckoutCheckpoint) -> Bool {
        checkpoint.resolution == "auto:No payment was taken."
            && (checkpoint.orderID != nil || checkpoint.entitlementID != nil || checkpoint.phase >= .entitled)
            && checkpoint.phase < .completed
    }

    var all: [CheckoutCheckpoint] { payload.checkpoints }
    var unresolved: [CheckoutCheckpoint] { payload.checkpoints.filter { !$0.isResolved } }

    func checkpoint(id: String) -> CheckoutCheckpoint? { payload.checkpoints.first { $0.id == id } }

    /// Fail-closed write before the first server mutation of a checkout. Re-beginning the same
    /// checkout session (a superseding checkout) keeps its history and only advances it.
    func begin(_ checkpoint: CheckoutCheckpoint) throws {
        if let integrityFault { throw StoreError.integrityFault(integrityFault) }
        var candidate = payload
        if let index = candidate.checkpoints.firstIndex(where: { $0.id == checkpoint.id }) {
            candidate.checkpoints[index].method = checkpoint.method ?? candidate.checkpoints[index].method
            candidate.checkpoints[index].updatedAt = checkpoint.updatedAt
            candidate.checkpoints[index].resolution = nil
            candidate.checkpoints[index].resolvedAt = nil
        } else {
            candidate.checkpoints.append(checkpoint)
        }
        try commit(candidate)
    }

    /// Best-effort enrichment after a server response. The server can always be asked by session
    /// ID, so a failed write here never loses the checkout. Phases never move backwards.
    @discardableResult
    func update(id: String, now: Date = Date(), _ change: (inout CheckoutCheckpoint) -> Void) -> Bool {
        guard let index = payload.checkpoints.firstIndex(where: { $0.id == id }) else { return false }
        var candidate = payload
        let previousPhase = candidate.checkpoints[index].phase
        change(&candidate.checkpoints[index])
        candidate.checkpoints[index].phase = max(previousPhase, candidate.checkpoints[index].phase)
        if Self.hasStaleNoPaymentResolution(candidate.checkpoints[index]) {
            candidate.checkpoints[index].resolution = nil
            candidate.checkpoints[index].resolvedAt = nil
        }
        candidate.checkpoints[index].updatedAt = now
        return (try? commit(candidate)) != nil
    }

    func resolve(id: String, reason: String, now: Date = Date()) {
        update(id: id, now: now) { checkpoint in
            checkpoint.resolution = reason
            checkpoint.resolvedAt = now
        }
    }

    /// Operator acknowledgement of a quarantined file; unresolved server orders remain visible
    /// in the server's order list.
    func acknowledgeIntegrityFault() throws {
        guard integrityFault != nil else { return }
        try commit(FilePayload(checkpoints: []))
        integrityFault = nil
    }

    private func commit(_ candidate: FilePayload) throws {
        var pruned = candidate
        let resolved = pruned.checkpoints.filter(\.isResolved)
        if resolved.count > Self.retainedResolvedCount {
            let drop = Set(resolved.sorted { $0.updatedAt < $1.updatedAt }.prefix(resolved.count - Self.retainedResolvedCount).map(\.id))
            pruned.checkpoints.removeAll { drop.contains($0.id) }
        }
        do {
            try writer(try PaymentsJSON.encoder().encode(pruned), url)
        } catch {
            throw StoreError.persistFailed(error.localizedDescription)
        }
        payload = pruned
    }
}

/// Server view from `GET /v1/checkouts/:checkoutSessionId` (device-scoped).
nonisolated struct CheckoutRecoveryResponse: Decodable, Sendable {
    struct OrderView: Decodable, Sendable {
        struct PrintOutcome: Decodable, Sendable { let copyIndex: Int; let outcome: String }
        let order: PaymentOrder
        let attempt: PaymentAttempt?
        let entitlement: CheckoutEntitlement?
        let newCheckout: NewCheckoutDecision?
        let printOutcomes: [PrintOutcome]
    }
    let checkoutSessionId: String
    let orders: [OrderView]
    let openOrderId: String?
    let serverTime: Date
}

/// What an interrupted checkout means and what may safely happen next.
nonisolated enum CheckoutRecoveryClassification: Equatable, Sendable {
    /// No order exists, or the open order never chose a payment method: nothing was charged.
    case nothingCharged
    /// A QR payment is pending or unknown. Keep reconciling; no cash, no new QR.
    case paymentPending
    /// Every order is conclusively unpaid.
    case unpaidClosed
    /// Paid (verified QR) or self-declared cash, not yet bound to the session: resumable.
    case paidUnclaimed(verified: Bool)
    /// Bound to the original session and nothing may have printed: resumable.
    case claimedNotPrinted(verified: Bool)
    /// Paper may already exist: operator must inspect; never resumed automatically.
    case printStarted
    case completed
    /// Late payment on a replaced checkout, manual review, or another server hold.
    case needsReview(String)
    /// Offline self-declared cash recorded locally; resumable while nothing may have printed.
    case offlineCashDeclared(printStarted: Bool)
    /// Local and server evidence disagree; fail closed.
    case inconsistent(String)

    var isTerminal: Bool {
        switch self {
        case .nothingCharged, .unpaidClosed, .completed: true
        default: false
        }
    }

    var isResumable: Bool {
        switch self {
        case .paidUnclaimed, .claimedNotPrinted, .offlineCashDeclared(printStarted: false): true
        default: false
        }
    }

    var operatorDescription: String {
        switch self {
        case .nothingCharged: "No payment was taken."
        case .paymentPending: "QR Ph payment is still being confirmed. Do not accept another payment."
        case .unpaidClosed: "The QR code was not paid."
        case .paidUnclaimed(let verified): verified ? "Paid by QR Ph (verified) — session never started." : "Cash (not provider-verified) — session never started."
        case .claimedNotPrinted(let verified): verified ? "Paid by QR Ph (verified) — session interrupted before printing." : "Cash (not provider-verified) — session interrupted before printing."
        case .printStarted: "Printing had started. Inspect the paper; reprint only from Recent Sessions if needed."
        case .completed: "Completed."
        case .needsReview(let reason): "Needs review: \(reason)."
        case .offlineCashDeclared(let printed): printed ? "Offline cash (self-reported) — printing had started. Inspect the paper." : "Offline cash (self-reported) — session interrupted before printing."
        case .inconsistent(let reason): "Records disagree (\(reason)). Not resumable; check the server order list."
        }
    }
}

nonisolated enum CheckoutRecoveryClassifier {
    /// Pure decision from durable local evidence and the authoritative server view.
    /// `localPrintStarted` is true when the print journal shows a copy that may have printed.
    static func classify(checkpoint: CheckoutCheckpoint, server: CheckoutRecoveryResponse?, localPrintStarted: Bool, offlineRecordExists: Bool) -> CheckoutRecoveryClassification {
        if checkpoint.method == "OFFLINE_CASH" {
            guard offlineRecordExists else { return .inconsistent("offline cash record missing") }
            return .offlineCashDeclared(printStarted: localPrintStarted || checkpoint.phase >= .printing)
        }
        guard let server else { return .inconsistent("server view unavailable") }
        guard server.checkoutSessionId == checkpoint.id else { return .inconsistent("session mismatch") }
        if server.orders.isEmpty {
            guard checkpoint.orderID == nil, checkpoint.entitlementID == nil, checkpoint.phase < .entitled else {
                return .inconsistent("saved purchase missing from server recovery view")
            }
            return .nothingCharged
        }
        if let known = checkpoint.orderID, !server.orders.contains(where: { $0.order.id == known }) {
            return .inconsistent("recorded order not found for this iPad")
        }
        // Any held/late/manual entitlement or order wins: it needs a person.
        for view in server.orders {
            if view.entitlement?.serverState == "REVIEW_REQUIRED" || ["LATE_PAID_REVIEW", "MANUAL_REVIEW"].contains(view.order.state) {
                return .needsReview(view.order.state == "LATE_PAID_REVIEW" ? "late payment on a replaced checkout" : "server review")
            }
        }
        guard let open = server.orders.first(where: { $0.order.id == server.openOrderId }) ?? server.orders.last else { return .nothingCharged }
        if let entitlement = open.entitlement {
            let verified = entitlement.authorizationSource == .verifiedQRPh
            let printed = localPrintStarted || !open.printOutcomes.isEmpty
            switch entitlement.serverState {
            case "CONSUMED": return .completed
            case "AUTHORIZED": return printed ? .inconsistent("print evidence without a claimed session") : .paidUnclaimed(verified: verified)
            case "IN_SESSION":
                guard entitlement.sessionID == checkpoint.id else { return .inconsistent("entitlement bound to another session") }
                return printed ? .printStarted : .claimedNotPrinted(verified: verified)
            default: return .needsReview(entitlement.serverState ?? "unknown entitlement state")
            }
        }
        guard let attempt = open.attempt else { return .nothingCharged }
        if attempt.state == "PAID_VERIFIED" { return .paymentPending }
        if attempt.isConclusivelyUnpaid && server.orders.allSatisfy({ $0.entitlement == nil }) {
            return .unpaidClosed
        }
        return .paymentPending
    }
}

/// One interrupted checkout as shown to the operator.
nonisolated struct CheckoutRecoveryItem: Identifiable, Equatable, Sendable {
    let checkpoint: CheckoutCheckpoint
    let classification: CheckoutRecoveryClassification
    var id: String { checkpoint.id }
}

enum PrintReportSyncState: Equatable {
    case idle
    case syncing
    case nothingToSynchronize
    case sent(Int)
    case networkFailure(retryCount: Int)
    case serverConflict(Int)
    case retryScheduled(Int)
}

/// Read-only server view used by recovery. `PaymentsAPIClient` in production; a stub in tests.
nonisolated protocol CheckoutRecoveryReading: Sendable {
    var environment: String { get }
    func checkoutRecovery(checkoutSessionID: String) async throws -> CheckoutRecoveryResponse
}
extension PaymentsAPIClient: CheckoutRecoveryReading {}

/// Reconciles interrupted checkouts and replays print reports. Resuming is never automatic: an
/// operator arms a single-use, short-lived resume and the guest continues the original checkout.
@MainActor
final class PaymentRecoveryCoordinator: ObservableObject {
    static let shared = PaymentRecoveryCoordinator()
    static let armedResumeLifetime: TimeInterval = 5 * 60

    @Published private(set) var items: [CheckoutRecoveryItem] = []
    @Published private(set) var lastRefreshMessage = ""
    @Published private(set) var armedResume: (item: CheckoutRecoveryItem, expiresAt: Date)?
    @Published private(set) var outboxSummary = (pending: 0, conflicts: 0, uncertain: 0, awaiting: 0)
    @Published private(set) var printReportSyncState = PrintReportSyncState.idle

    @Published private(set) var lastRefreshCompletedAt: Date?
    private var launched = false
    /// Refreshes are single-flight: one pass at a time, and requests made during a pass are
    /// coalesced into exactly one follow-up pass. An older pass can never publish over a newer one.
    private var refreshTask: Task<Void, Never>?
    private var refreshRequestedDuringPass = false
    private(set) var completedRefreshPasses = 0
    private let checkpointStore: @MainActor () -> CheckoutCheckpointStore?
    private let reader: @MainActor () -> (any CheckoutRecoveryReading)?
    private let outboxClient: @MainActor () -> PaymentsAPIClient?

    init(checkpointStore: @escaping @MainActor () -> CheckoutCheckpointStore? = { CheckoutCheckpointStore.shared },
         reader: @escaping @MainActor () -> (any CheckoutRecoveryReading)? = { PaymentsConfiguration.current().map { PaymentsAPIClient(configuration: $0) } },
         outboxClient: @escaping @MainActor () -> PaymentsAPIClient? = { PaymentsConfiguration.current().map { PaymentsAPIClient(configuration: $0) } }) {
        self.checkpointStore = checkpointStore; self.reader = reader; self.outboxClient = outboxClient
    }

    /// Items an attendant should look at (never shown with any detail on guest screens).
    var needsAttention: Bool {
        items.contains { !$0.classification.isTerminal } || outboxSummary.conflicts > 0
            || checkpointStore()?.integrityFault != nil || PrintOutcomeOutbox.shared?.integrityFault != nil
    }

    func launch() {
        guard !launched else { return }
        launched = true
        PrintOutcomeOutbox.shared?.recoverAfterLaunch()
        Task { await refresh() }
    }

    /// Startup, foregrounding and operator actions may all ask at once. Callers wait for a pass
    /// that started after their request, so what they see is never older than their request.
    func refresh() async {
        if let running = refreshTask {
            refreshRequestedDuringPass = true
            await running.value
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            repeat {
                self.refreshRequestedDuringPass = false
                await self.performRefreshPass()
                self.completedRefreshPasses += 1
            } while self.refreshRequestedDuringPass
            self.refreshTask = nil
        }
        refreshTask = task
        await task.value
    }

    private func performRefreshPass() async {
        refreshOutboxSummary()
        guard let store = checkpointStore() else {
            lastRefreshMessage = "Checkout records are unavailable on this iPad."
            return
        }
        let client = reader()
        var refreshed: [CheckoutRecoveryItem] = []
        var unreachable = false
        // Read-only server checks run one at a time: bounded load on the payments server.
        for checkpoint in store.unresolved {
            let printStarted = PrintOutcomeOutbox.shared.map { !$0.copiesThatMayHavePrinted(sessionID: checkpoint.id).isEmpty } ?? true
            var server: CheckoutRecoveryResponse?
            if checkpoint.method != "OFFLINE_CASH", let client, client.environment == checkpoint.environment {
                // A failed, timed-out or cancelled read proves nothing: the checkout stays pending.
                do { server = try await client.checkoutRecovery(checkoutSessionID: checkpoint.id) } catch { unreachable = true }
            }
            let offlineExists = await offlineRecordExists(checkpoint)
            // The operator may have resolved it while this pass was waiting; their decision stands.
            // No suspension point follows until this checkpoint is classified and recorded.
            guard store.checkpoint(id: checkpoint.id)?.isResolved == false else { continue }
            let classification: CheckoutRecoveryClassification = (server == nil && checkpoint.method != "OFFLINE_CASH")
                ? .paymentPending
                : CheckoutRecoveryClassifier.classify(checkpoint: checkpoint, server: server, localPrintStarted: printStarted, offlineRecordExists: offlineExists)
            if let server, let open = server.orders.last {
                store.update(id: checkpoint.id) { $0.lastServerState = open.entitlement?.serverState ?? open.attempt?.state ?? open.order.state }
            }
            if classification == .printStarted, finishFullyDeliveredCheckout(checkpoint, server: server) {
                continue
            }
            if classification.isTerminal {
                store.resolve(id: checkpoint.id, reason: "auto:\(classification.operatorDescription)")
            } else {
                refreshed.append(CheckoutRecoveryItem(checkpoint: checkpoint, classification: classification))
            }
        }
        items = refreshed.filter { store.checkpoint(id: $0.id)?.isResolved == false }
        // An armed resume follows the newest classification; it is dropped if no longer resumable.
        if let armed = armedResume {
            if let fresh = items.first(where: { $0.id == armed.item.id }), fresh.classification.isResumable { armedResume = (fresh, armed.expiresAt) } else { armedResume = nil }
        }
        lastRefreshMessage = unreachable ? "Some checkouts could not be checked: the payments server is unreachable." : "Checked \(Date().formatted(date: .omitted, time: .shortened))."
        if !unreachable { lastRefreshCompletedAt = Date() }
        if let outbox = outboxClient() { await syncOutbox(client: outbox) }
    }

    func syncOutbox(
        client: PaymentsAPIClient? = PaymentsConfiguration.current().map { PaymentsAPIClient(configuration: $0) },
        showFeedback: Bool = false
    ) async {
        guard let outbox = PrintOutcomeOutbox.shared else {
            refreshOutboxSummary()
            if showFeedback { printReportSyncState = .networkFailure(retryCount: 0) }
            return
        }
        guard let client else {
            refreshOutboxSummary()
            if showFeedback { printReportSyncState = .networkFailure(retryCount: outbox.summary.pending) }
            return
        }
        let dueCount = outbox.dueReports().count
        if showFeedback {
            if outbox.summary.pending == 0 {
                printReportSyncState = outbox.summary.conflicts > 0 ? .serverConflict(outbox.summary.conflicts) : .nothingToSynchronize
                return
            }
            if dueCount == 0 {
                printReportSyncState = .retryScheduled(outbox.summary.pending)
                return
            }
            printReportSyncState = .syncing
        }
        let result = await outbox.sync(using: client)
        refreshOutboxSummary()
        guard showFeedback else { return }
        if result.conflicts > 0 || outbox.summary.conflicts > 0 {
            printReportSyncState = .serverConflict(max(result.conflicts, outbox.summary.conflicts))
        } else if result.retries > 0 {
            printReportSyncState = .networkFailure(retryCount: result.retries)
        } else if result.sent > 0 {
            printReportSyncState = .sent(result.sent)
        } else if outbox.summary.pending > 0 {
            printReportSyncState = .retryScheduled(outbox.summary.pending)
        } else {
            printReportSyncState = .nothingToSynchronize
        }
    }

    func refreshOutboxSummary() {
        outboxSummary = PrintOutcomeOutbox.shared?.summary ?? (0, 0, 0, 0)
    }

    /// Operator action: the next guest start continues this checkout. Single use, expires.
    func armResume(_ item: CheckoutRecoveryItem, now: Date = Date()) -> Bool {
        guard item.classification.isResumable else { return false }
        armedResume = (item, now.addingTimeInterval(Self.armedResumeLifetime))
        return true
    }

    func disarmResume() { armedResume = nil }

    func takeArmedResume(now: Date = Date()) -> CheckoutRecoveryItem? {
        defer { armedResume = nil }
        guard let armed = armedResume, armed.expiresAt > now, armed.item.classification.isResumable else { return nil }
        return armed.item
    }

    /// Hides an item on this iPad. Server entitlements are untouched and stay listed as
    /// outstanding in the server's order list; the reason is kept in the local record.
    func dismiss(_ item: CheckoutRecoveryItem, reason: String) {
        checkpointStore()?.resolve(id: item.id, reason: "operator:\(reason)")
        items.removeAll { $0.id == item.id }
        if armedResume?.item.id == item.id { armedResume = nil }
    }

    /// Crash after the last copy but before completion was queued: when every paid copy is
    /// recorded as delivered, record consumption. Nothing is printed; uncertain copies still go
    /// to the operator.
    private func finishFullyDeliveredCheckout(_ checkpoint: CheckoutCheckpoint, server: CheckoutRecoveryResponse?) -> Bool {
        guard let outbox = PrintOutcomeOutbox.shared,
              let entitlementID = server?.orders.first(where: { $0.order.id == server?.openOrderId })?.entitlement?.id ?? checkpoint.entitlementID else { return false }
        let copies = outbox.copiesThatMayHavePrinted(sessionID: checkpoint.id)
        guard Self.allPaidCopiesDelivered(copies, paidCopies: checkpoint.copies), let batchID = copies.first?.batchID else { return false }
        outbox.enqueueCompletion(batchID: batchID, sessionID: checkpoint.id, entitlementID: entitlementID)
        checkpointStore()?.resolve(id: checkpoint.id, reason: "auto:all paid copies delivered before interruption")
        return true
    }

    /// True only when exactly copies 1…N of one batch were delivered and none is uncertain.
    nonisolated static func allPaidCopiesDelivered(_ copies: [PrintOutboxEntry], paidCopies: Int) -> Bool {
        guard paidCopies >= 1, !copies.isEmpty, Set(copies.map(\.batchID)).count == 1 else { return false }
        return copies.allSatisfy { $0.localState == .delivered } && Set(copies.map(\.copyIndex)) == Set(1...paidCopies)
    }

    private func offlineRecordExists(_ checkpoint: CheckoutCheckpoint) async -> Bool {
        guard checkpoint.method == "OFFLINE_CASH", let ledger = OfflineCashLedger.shared else { return false }
        return await ledger.allRecords().contains { $0.sessionID == checkpoint.id && ($0.id == checkpoint.offlineRecordID || checkpoint.offlineRecordID == nil) }
    }
}
