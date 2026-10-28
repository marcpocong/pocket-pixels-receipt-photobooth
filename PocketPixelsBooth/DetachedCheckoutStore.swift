import Foundation
import CryptoKit

/// Durable private handoff, written before a guest can release the kiosk. The reference is
/// for owner-assisted lookup only; it is never a credential and cannot authorize capture.
nonisolated struct DetachedCheckoutRecord: Codable, Sendable {
    let checkpoint: CheckoutCheckpoint
    let snapshot: AppRecoverySnapshot
    let reference: String
    let detachedAt: Date
}

nonisolated struct DetachedCheckoutStore {
    let directory: URL
    var writer: (Data, URL) throws -> Void = { try DurableFileWriter.write($0, to: $1) }
    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("DetachedCheckoutsV1")
    }
    private func file(_ sessionID: String) -> URL {
        let hash = SHA256.hash(data: Data(sessionID.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(hash + ".json")
    }
    func save(_ record: DetachedCheckoutRecord) throws {
        guard record.snapshot.sessionIdentifier == record.checkpoint.id,
              record.checkpoint.phase < .entitled, record.snapshot.photoJPEGData.isEmpty,
              record.snapshot.stage == .formatSelected else { throw SetupFailure("This checkout cannot be detached after capture or printing may have begun.") }
        try saveForOperator(record)
    }

    /// Operator closure retains the complete snapshot, including captured photos and previews.
    /// Callers must finish the physical check first if paper may exist.
    func saveForOperator(_ record: DetachedCheckoutRecord) throws {
        guard record.snapshot.sessionIdentifier == record.checkpoint.id else { throw AppRecoveryStoreError.verificationFailed }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700, .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(record)
        try writer(data, file(record.checkpoint.id))
        try FileManager.default.setAttributes([.posixPermissions: 0o600, .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: file(record.checkpoint.id).path)
        guard try Data(contentsOf: file(record.checkpoint.id)) == data else { throw AppRecoveryStoreError.verificationFailed }
    }
    func load(sessionID: String) throws -> DetachedCheckoutRecord? {
        let url = file(sessionID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let record = try decoder.decode(DetachedCheckoutRecord.self, from: Data(contentsOf: url))
        guard record.checkpoint.id == sessionID, record.snapshot.sessionIdentifier == sessionID else { throw AppRecoveryStoreError.verificationFailed }
        return record
    }
}

@MainActor enum DetachedCheckoutHandoff {
    /// Crash after a committed handoff must not leave the old pre-camera snapshot occupying the
    /// kiosk. Missing or contradictory evidence is preserved for operator review.
    static func recover(checkpoints: CheckoutCheckpointStore? = .shared, recovery: AppRecoveryStore? = try? AppRecoveryStore(),
                        detached: DetachedCheckoutStore = DetachedCheckoutStore()) throws {
        guard let snapshot = recovery?.load(), let checkpoint = checkpoints?.checkpoint(id: snapshot.sessionIdentifier),
              checkpoint.detachedAt != nil else { return }
        guard let record = try detached.load(sessionID: snapshot.sessionIdentifier), record.reference == checkpoint.recoveryReference,
              snapshot.stage == .formatSelected, snapshot.photoJPEGData.isEmpty else { throw AppRecoveryStoreError.verificationFailed }
        recovery?.clear(sessionIdentifier: snapshot.sessionIdentifier)
    }
}

/// Weak access to the actual guest state machine. Closing an operator sheet alone cannot
/// release the kiosk while a late payment/camera callback still owns the previous guest.
@MainActor enum ActiveGuestInteraction {
    static weak var model: BoothSessionViewModel?
}

@MainActor enum CheckoutInteractionClosure {
    /// Resume must never overwrite a different unclosed guest, or lose the original photos
    /// when the returning guest deliberately starts fresh capture under the same entitlement.
    static func snapshotForResume(id: String, checkpoints: CheckoutCheckpointStore, recovery: AppRecoveryStore,
                                  detached: DetachedCheckoutStore) throws -> AppRecoverySnapshot? {
        if let saved = try recovery.loadChecked() {
            if saved.sessionIdentifier != id {
                let closed = checkpoints.checkpoint(id: saved.sessionIdentifier)?.isParked == true
                    || recovery.acknowledgedIdentity == OperatorRecoveryAcknowledgement.identity(saved)
                    || UserDefaults.standard.string(forKey: OperatorRecoveryAcknowledgement.key) == OperatorRecoveryAcknowledgement.identity(saved)
                guard closed else { throw SetupFailure("Close Session & Continue for the other interrupted guest before resuming this checkout. Its photos are still saved.") }
            }
            try recovery.retainForReference(saved)
            if saved.sessionIdentifier == id { return saved }
        }
        return try detached.load(sessionID: id)?.snapshot
    }

    /// Commit retained assets first, then the local decision. Failure leaves the operation gate
    /// closed. Repeated calls reuse the same original checkout and reference.
    static func retainForEventEnd(checkpoints: CheckoutCheckpointStore, recovery: AppRecoveryStore,
                                  detached: DetachedCheckoutStore, defaults: UserDefaults = .standard) throws {
        guard checkpoints.integrityFault == nil else { throw AppRecoveryStoreError.verificationFailed }
        let snapshot = try recovery.loadChecked()
        if let snapshot { _ = try OperatorRecoveryAcknowledgement.retainAndAcknowledge(snapshot, store: recovery, defaults: defaults) }
        for checkpoint in checkpoints.unresolved where !checkpoint.isParked {
            try close(id: checkpoint.id, reason: "operator:event_ended_follow_up_retained", checkpoints: checkpoints,
                recovery: recovery, detached: detached, snapshot: snapshot.flatMap { $0.sessionIdentifier == checkpoint.id ? $0 : nil })
        }
    }

    static func close(id: String, reason: String, checkpoints: CheckoutCheckpointStore,
                      recovery: AppRecoveryStore, detached: DetachedCheckoutStore,
                      snapshot: AppRecoverySnapshot?) throws {
        guard let checkpoint = checkpoints.checkpoint(id: id), checkpoints.integrityFault == nil else {
            throw SetupFailure("Original checkout records are unavailable. Nothing was closed.")
        }
        if let snapshot {
            guard snapshot.sessionIdentifier == id else { throw AppRecoveryStoreError.verificationFailed }
            let existing = try detached.load(sessionID: id)
            try detached.saveForOperator(.init(checkpoint: checkpoint, snapshot: snapshot,
                reference: existing?.reference ?? checkpoint.recoveryReference ?? UUID().uuidString.lowercased(),
                detachedAt: existing?.detachedAt ?? Date()))
            try recovery.retainForReference(snapshot)
        }
        guard checkpoints.park(id: id, reason: reason) else {
            throw SetupFailure("Could not save the resolution. Retry Saving Resolution. \(checkpoints.lastPersistenceError ?? "Checkout records are unavailable.")")
        }
    }
}
