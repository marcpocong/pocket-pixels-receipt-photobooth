import Foundation

nonisolated struct RecordCleanupDecision: Equatable, Sendable {
    enum Category: String, Sendable { case eligible, archiveInstead, blocked, cannotInspect }
    let category: Category
    let reason: String
    static let eligible = Self(category: .eligible, reason: "Eligible for local deletion. Financial and print history remain.")
}

/// Main-actor leases cover the entire asynchronous reprint, including gaps between copies.
@MainActor
enum SessionMediaOperations {
    static var reprinting = Set<String>()
    static var deleting = Set<String>()
    static func ownerIsActive(_ id: String) -> Bool {
        ActiveGuestInteraction.model.map { $0.sessionIdentifier == id && $0.state != .welcome && $0.state != .thankYou } ?? false
    }

    static func sessionDeletionDecision(_ summary: RecentSessionArchiveSummary,
        checkpoints: CheckoutCheckpointStore? = .shared, outbox: PrintOutcomeOutbox? = .shared,
        recoveryStore: AppRecoveryStore? = nil, pendingStore: GalleryPendingUploadStore? = nil) throws -> RecordCleanupDecision {
        if ownerIsActive(summary.sessionIdentifier) || reprinting.contains(summary.sessionIdentifier) {
            return .init(category: .blocked, reason: "This guest or an operator reprint is still using the session.")
        }
        guard summary.rasterFingerprint != "CORRUPT" else { return .init(category: .cannotInspect, reason: "The session identity cannot be read safely. Hide it and recover storage first.") }
        guard let checkpoints, checkpoints.integrityFault == nil,
              let outbox, outbox.integrityFault == nil, outbox.persistenceFailure == nil else {
            return .init(category: .cannotInspect, reason: "Checkout or print recovery records could not be inspected.")
        }
        if checkpoints.unresolved.contains(where: { $0.id == summary.sessionIdentifier }) {
            return .init(category: .archiveInstead, reason: "The original checkout still needs reconciliation or fulfillment. Hide the local session for now.")
        }
        if outbox.entries.contains(where: { $0.sessionID == summary.sessionIdentifier && ($0.localState == .inFlight || $0.inspectionRequired == true) }) {
            return .init(category: .blocked, reason: "Review the unfinished physical receipt before deleting its local media.")
        }
        let recovery = try recoveryStore ?? AppRecoveryStore()
        if let snapshot = try recovery.loadChecked(), snapshot.sessionIdentifier == summary.sessionIdentifier,
           OperatorRecoveryAcknowledgement.identity(snapshot) != recovery.acknowledgedIdentity {
            return .init(category: .blocked, reason: "Close Session & Continue or review the original session in Help & Recovery before removing its recovery media.")
        }
        // A queued upload owns complete separate copies. Loading validates those copies before
        // allowing removal of unrelated archive media. Never clear the gallery queue here.
        let queue = try pendingStore ?? GalleryPendingUploadStore()
        if let payload = try queue.load(galleryToken: summary.archiveID) {
            guard payload.sessionID == summary.sessionIdentifier, !payload.photos.isEmpty,
                  payload.photos.allSatisfy({ !$0.data.isEmpty }), !payload.colorReceipt.data.isEmpty else {
                return .init(category: .cannotInspect, reason: "Gallery recovery does not have complete independent media.")
            }
        }
        return .eligible
    }
}

extension PaymentRecoveryCoordinator {
    func forceRemoveCheckout(id: String) throws {
        try setCheckoutHidden(id: id, hidden: true)
    }

    /// No server call is necessary: original payment identity and entitlement evidence are
    /// committed independently with the tombstone. Existing snapshots/media are retained.
    func forceDeleteLocalCheckout(id: String) async throws {
        guard managementAuthorized(), let store = managementStore, store.integrityFault == nil else {
            throw SetupFailure("Unlock operator controls and repair checkout storage before deleting. Force Remove from Workspace remains available when storage is writable.")
        }
        guard let original = store.checkpoint(id: id) else { return }
        guard original.isParked || original.isResolved else { throw SetupFailure("Close Session & Continue before deleting this active interruption.") }
        guard !SessionMediaOperations.ownerIsActive(id), armedResume?.item.id != id,
              !SessionMediaOperations.reprinting.contains(id) else { throw SetupFailure("This checkout is being used by a guest or reprint.") }
        let dependencies = try await inspectManagementDependencies(id)
        guard dependencies.inspectionComplete,
              !dependencies.copies.contains(where: { $0.localState == .inFlight }) else {
            throw SetupFailure("An unfinished print send or unreadable recovery record prevents deletion. Force Remove from Workspace preserves the checkpoint instead.")
        }
        guard managementAuthorized(), store.checkpoint(id: id) == original,
              !SessionMediaOperations.ownerIsActive(id), armedResume?.item.id != id,
              !SessionMediaOperations.reprinting.contains(id) else { throw SetupFailure("Checkout changed during cleanup. Review it again.") }
        try store.retainFinancialRecoveryAndDelete(id: id)
        refreshLocalDecisions()
    }

    /// Inspection is read-only; repeat it immediately before each mutation, never trust preflight.
    func checkoutDeletionDecision(id: String) async -> RecordCleanupDecision {
        guard managementAuthorized() else { return .init(category: .blocked, reason: "Unlock operator controls first.") }
        guard let store = managementStore, store.integrityFault == nil else { return .init(category: .cannotInspect, reason: "Checkout storage needs review.") }
        guard let checkpoint = store.checkpoint(id: id) else { return .eligible }
        if SessionMediaOperations.ownerIsActive(id) || armedResume?.item.id == id {
            return .init(category: .blocked, reason: "This checkout belongs to a current guest or armed resume.")
        }
        guard let client = managementReader, client.environment == checkpoint.environment,
              checkpoint.serverBinding == nil || client.serverBinding == checkpoint.serverBinding else {
            return .init(category: .cannotInspect, reason: "Connect to the original payment server before deleting. Archive is available for closed interactions.")
        }
        do {
            let server = try await client.checkoutRecovery(checkoutSessionID: id)
            let dependencies = try await inspectManagementDependencies(id)
            guard store.checkpoint(id: id) == checkpoint, !SessionMediaOperations.ownerIsActive(id), armedResume?.item.id != id else {
                return .init(category: .blocked, reason: "The checkout changed during inspection. Check it again.")
            }
            return CheckoutDeletionPolicy.decide(checkpoint: checkpoint, server: server, dependencies: dependencies)
        } catch {
            return .init(category: .cannotInspect, reason: "The original payment or recovery records could not be checked. No deletion was made; try again online.")
        }
    }

    func deleteEligibleCheckout(id: String) async throws {
        let original = managementStore?.checkpoint(id: id)
        let decision = await checkoutDeletionDecision(id: id)
        guard decision.category == .eligible else { throw SetupFailure(decision.reason) }
        // No suspension between revalidated decision and atomic removal.
        guard let store = managementStore, store.checkpoint(id: id) == original else { throw SetupFailure("Checkout changed. Review it again before deleting.") }
        try store.deleteCheckpoint(id: id)
        refreshLocalDecisions()
    }

    func setCheckoutHidden(id: String, hidden: Bool) throws {
        guard managementAuthorized(), let store = managementStore else { throw PaymentsAPIError.unauthorized }
        guard let checkpoint = store.checkpoint(id: id), checkpoint.isParked || checkpoint.isResolved else {
            throw SetupFailure("Close Session & Continue before archiving an active interruption.")
        }
        guard !SessionMediaOperations.ownerIsActive(id), armedResume?.item.id != id,
              !SessionMediaOperations.reprinting.contains(id),
              PrintOutcomeOutbox.shared?.entries.contains(where: { $0.sessionID == id && $0.localState == .inFlight }) != true else {
            throw SetupFailure("This checkout is still used by a guest or print send.")
        }
        guard store.update(id: id, { $0.hiddenAt = hidden ? Date() : nil }) else { throw SetupFailure("Could not save visibility. Nothing was hidden.") }
        refreshLocalDecisions()
    }
}


nonisolated struct CheckoutManagementSnapshot: Sendable {
    var cash: [OfflineCashRecord] = []
    var copies: [PrintOutboxEntry] = []
    var receiptNeedsReview = false
    var inspectionComplete = true

    @MainActor static func inspect(_ id: String) async throws -> Self {
        guard let ledger = OfflineCashLedger.shared else { throw SetupFailure("Cash storage is unavailable.") }
        let cashFault = await ledger.integrityFault
        let cash = await ledger.allRecords().filter { $0.sessionID == id }
        guard cashFault == nil, let outbox = PrintOutcomeOutbox.shared,
              outbox.integrityFault == nil, outbox.persistenceFailure == nil else { throw SetupFailure("Cash or print records need review.") }
        let recovery = try AppRecoveryStore()
        let current = try recovery.loadChecked()
        _ = try DetachedCheckoutStore().load(sessionID: id)
        // Audits remain evidence. Historical failures never become an operation lock.
        _ = try? PrintAuditStore().load()
        return Self(cash: cash, copies: outbox.entries.filter { $0.sessionID == id },
            receiptNeedsReview: current.map { $0.sessionIdentifier == id && $0.stage == .printStatusUnknown && recovery.acknowledgedIdentity != OperatorRecoveryAcknowledgement.identity($0) } ?? false)
    }
}

nonisolated enum CheckoutDeletionPolicy {
    static func decide(checkpoint: CheckoutCheckpoint, server: CheckoutRecoveryResponse, dependencies: CheckoutManagementSnapshot) -> RecordCleanupDecision {
        guard dependencies.inspectionComplete else { return .init(category: .cannotInspect, reason: "Recovery dependencies could not be inspected safely.") }
        if dependencies.cash.contains(where: { $0.syncState != .synced || $0.reviewFlag != nil }) {
            return .init(category: .archiveInstead, reason: "Cash reconciliation is outstanding. Archive keeps its original evidence.")
        }
        if dependencies.receiptNeedsReview || dependencies.copies.contains(where: { $0.localState == .inFlight || $0.inspectionRequired == true }) {
            return .init(category: .blocked, reason: "Review and acknowledge the unfinished physical receipt before cleanup.")
        }
        var originalCheckout = checkpoint
        if originalCheckout.method == "OFFLINE_CASH", !dependencies.cash.isEmpty,
           dependencies.cash.allSatisfy({ $0.syncState == .synced && $0.reviewFlag == nil }) {
            originalCheckout.method = "CASH_DECLARED" // authoritative consumed entitlement is still required
        }
        let classification = CheckoutRecoveryClassifier.classify(checkpoint: originalCheckout, server: server,
            localPrintStarted: dependencies.copies.contains { $0.localState.mayHavePrinted }, offlineRecordExists: !dependencies.cash.isEmpty)
        switch classification {
        case .nothingCharged:
            guard checkpoint.phase == .orderRequested, checkpoint.method == nil,
                  checkpoint.entitlementID == nil, checkpoint.offlineRecordID == nil,
                  dependencies.cash.isEmpty, dependencies.copies.isEmpty,
                  server.orders.allSatisfy({ $0.order.paymentMethod == nil && $0.attempt == nil && $0.entitlement == nil }) else {
                return .init(category: .archiveInstead, reason: "Payment or fulfillment evidence remains. Archive this record instead.")
            }
        case .unpaidClosed: break
        case .completed:
            guard server.orders.allSatisfy({ view in
                if let entitlement = view.entitlement { return entitlement.serverState == "CONSUMED" }
                if let attempt = view.attempt { return attempt.isConclusivelyUnpaid }
                return view.order.paymentMethod == nil
            }) else { return .init(category: .archiveInstead, reason: "Another original payment attempt still needs reconciliation. Archive this checkout instead.") }
        default: return .init(category: .archiveInstead, reason: classification.operatorDescription + " Archive keeps reconciliation available.")
        }
        return .eligible
    }
}
