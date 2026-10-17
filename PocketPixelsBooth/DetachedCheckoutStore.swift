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
