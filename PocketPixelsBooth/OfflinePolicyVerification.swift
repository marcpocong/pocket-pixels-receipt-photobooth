import CryptoKit
import Foundation

/// A server-signed offline cash policy exactly as delivered by `GET /v1/events/active`.
/// `payload` is the base64 of the exact bytes the Worker signed; it is never re-serialized.
nonisolated struct SignedOfflinePolicy: Codable, Equatable, Sendable {
    let snapshotId: String
    let keyId: String
    let payload: String
    let signature: String
}

/// Decoded claims of a verified offline policy. Only produced by `OfflinePolicyVerifier`.
nonisolated struct OfflinePolicyPayload: Codable, Equatable, Sendable {
    let v: Int
    let kid: String
    let env: String
    let snapshotId: String
    let accountId: String
    let deviceId: String
    let eventId: String
    let eventName: String
    let eventLifecycle: String
    let policyRevisionId: String
    let revision: Int
    let commercialMode: String
    let currency: String
    let unitPriceCentavos: Int
    let maxCopies: Int
    let defaultCopies: Int
    let paymentMethods: [String]
    let supportedFormats: [String]
    let maxDeclarations: Int
    let issuedAt: Date
    let notBefore: Date
    let expiresAt: Date

    /// Cash-only policy for an offline session. QR Ph always requires the server.
    var eventRun: CommercialEventRun {
        CommercialEventRun(
            id: eventId,
            name: eventName,
            venue: "",
            lifecycle: .active,
            activePolicy: PaymentPolicySnapshot(
                revisionID: policyRevisionId,
                revision: revision,
                commercialMode: .payPerPrint,
                unitPriceCentavos: unitPriceCentavos,
                maxCopies: maxCopies,
                defaultCopies: defaultCopies,
                cashEnabled: true,
                qrPhEnabled: false,
                prepaidGuestCopyChoice: false,
                supportedFormatRawValues: supportedFormats,
                offlineValidUntil: expiresAt
            ),
            startsAt: nil,
            endsAt: nil,
            updatedAt: issuedAt
        )
    }
}

nonisolated enum OfflinePolicyError: Error, Equatable, LocalizedError, Sendable {
    case noTrustedKeys
    case untrustedKey
    case malformed
    case badSignature
    case unsupportedVersion
    case wrongEnvironment
    case wrongDevice
    case wrongAccount
    case notCashOnly
    case invalidBounds
    case notYetValid
    case expired
    case clockRolledBack

    var errorDescription: String? {
        switch self {
        case .noTrustedKeys: "Offline cash is disabled: no offline policy verification key is installed."
        case .untrustedKey: "Offline cash is disabled: the policy was signed by an unknown key."
        case .malformed: "Offline cash is disabled: the saved policy is unreadable."
        case .badSignature: "Offline cash is disabled: the policy signature is invalid."
        case .unsupportedVersion: "Offline cash is disabled: the policy format is not supported."
        case .wrongEnvironment: "Offline cash is disabled: the policy is for a different payments environment."
        case .wrongDevice: "Offline cash is disabled: the policy was issued to a different iPad."
        case .wrongAccount: "Offline cash is disabled: the policy belongs to a different account."
        case .notCashOnly: "Offline cash is disabled: the policy does not authorize offline cash."
        case .invalidBounds: "Offline cash is disabled: the policy limits are invalid."
        case .notYetValid: "Offline cash is disabled: the iPad clock is earlier than the policy start."
        case .expired: "Offline cash is disabled: the offline policy has expired. Reconnect to refresh it."
        case .clockRolledBack: "Offline cash is disabled: the iPad clock moved backwards."
        }
    }
}

/// Verifies Ed25519 offline policies against public keys pinned in the app bundle.
/// The signing private key lives only in the Worker's secret store.
nonisolated struct OfflinePolicyVerifier: Sendable {
    static let clockSkew: TimeInterval = 5 * 60

    let trustedKeys: [String: Curve25519.Signing.PublicKey]
    let environment: String

    init(trustedKeys: [String: Curve25519.Signing.PublicKey], environment: String) {
        self.trustedKeys = trustedKeys
        self.environment = environment
    }

    /// Reads `PAYMENTS_OFFLINE_POLICY_PUBLIC_KEYS` (comma-separated `keyId:base64RawPublicKey`).
    static func bundled(environment: String, bundle: Bundle = .main) -> OfflinePolicyVerifier {
        let raw = bundle.object(forInfoDictionaryKey: "PAYMENTS_OFFLINE_POLICY_PUBLIC_KEYS") as? String ?? ""
        return OfflinePolicyVerifier(trustedKeys: parseKeys(raw), environment: environment)
    }

    static func parseKeys(_ raw: String) -> [String: Curve25519.Signing.PublicKey] {
        var keys: [String: Curve25519.Signing.PublicKey] = [:]
        for entry in raw.split(separator: ",") {
            let parts = entry.trimmingCharacters(in: .whitespaces).split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, !parts[0].isEmpty,
                  let data = Data(base64Encoded: parts[1]),
                  let key = try? Curve25519.Signing.PublicKey(rawRepresentation: data) else { continue }
            keys[parts[0]] = key
        }
        return keys
    }

    /// Verifies signature, binding and validity. `trustedClockFloor` is the latest time this iPad
    /// has already trusted; a clock earlier than it (minus skew) means the clock was rolled back.
    func verify(
        _ grant: SignedOfflinePolicy,
        deviceID: String,
        accountID: String,
        now: Date,
        trustedClockFloor: Date?
    ) throws -> OfflinePolicyPayload {
        guard !trustedKeys.isEmpty else { throw OfflinePolicyError.noTrustedKeys }
        guard let key = trustedKeys[grant.keyId] else { throw OfflinePolicyError.untrustedKey }
        guard let payloadData = Data(base64Encoded: grant.payload),
              let signature = Data(base64Encoded: grant.signature) else { throw OfflinePolicyError.malformed }
        guard key.isValidSignature(signature, for: payloadData) else { throw OfflinePolicyError.badSignature }
        guard let payload = try? PaymentsJSON.decoder().decode(OfflinePolicyPayload.self, from: payloadData) else {
            throw OfflinePolicyError.malformed
        }
        guard payload.v == 1 else { throw OfflinePolicyError.unsupportedVersion }
        guard payload.kid == grant.keyId, payload.snapshotId == grant.snapshotId else { throw OfflinePolicyError.malformed }
        guard payload.env == environment else { throw OfflinePolicyError.wrongEnvironment }
        guard payload.deviceId == deviceID else { throw OfflinePolicyError.wrongDevice }
        guard payload.accountId == accountID else { throw OfflinePolicyError.wrongAccount }
        guard payload.commercialMode == "PAY_PER_PRINT", payload.paymentMethods == ["CASH_DECLARED"],
              payload.eventLifecycle == "ACTIVE", payload.currency == "PHP" else { throw OfflinePolicyError.notCashOnly }
        guard payload.unitPriceCentavos > 0, payload.unitPriceCentavos <= PesoAmount.maximumCentavos,
              PaymentPolicySnapshot.copyRange.contains(payload.maxCopies),
              (1...payload.maxCopies).contains(payload.defaultCopies),
              !payload.supportedFormats.isEmpty, payload.maxDeclarations >= 1,
              payload.expiresAt > payload.issuedAt else { throw OfflinePolicyError.invalidBounds }
        if let trustedClockFloor, now < trustedClockFloor.addingTimeInterval(-Self.clockSkew) {
            throw OfflinePolicyError.clockRolledBack
        }
        guard now >= payload.notBefore.addingTimeInterval(-Self.clockSkew) else { throw OfflinePolicyError.notYetValid }
        guard now <= payload.expiresAt else { throw OfflinePolicyError.expired }
        return payload
    }
}

/// Durable copy of the last signed grant plus this iPad's paired identity and clock floor.
/// Every use re-verifies the stored signature; nothing here is trusted on its own.
nonisolated struct OfflineGrantRecord: Codable, Equatable, Sendable {
    var grant: SignedOfflinePolicy?
    var deviceID: String
    var accountID: String
    var environment: String
    var trustedClockFloor: Date
}

nonisolated enum OfflineGrantStore {
    static func url(fileManager: FileManager = .default, directory: URL? = nil) -> URL {
        let root = directory ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? fileManager.temporaryDirectory
        return root.appendingPathComponent("PaymentState", isDirectory: true).appendingPathComponent("offline-policy-grant.json")
    }

    static func load(fileManager: FileManager = .default, directory: URL? = nil) -> OfflineGrantRecord? {
        guard let data = try? Data(contentsOf: url(fileManager: fileManager, directory: directory)) else { return nil }
        return try? PaymentsJSON.decoder().decode(OfflineGrantRecord.self, from: data)
    }

    static func save(_ record: OfflineGrantRecord, fileManager: FileManager = .default, directory: URL? = nil) throws {
        let target = url(fileManager: fileManager, directory: directory)
        try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try DurableFileWriter.write(try PaymentsJSON.encoder().encode(record), to: target, fileManager: fileManager)
    }

    /// Records a server-confirmed identity/time and the newest grant (nil clears a revoked one).
    static func recordServerContact(
        device: PaymentDeviceIdentity,
        environment: String,
        serverTime: Date,
        grant: SignedOfflinePolicy?,
        fileManager: FileManager = .default,
        directory: URL? = nil
    ) throws {
        let previous = load(fileManager: fileManager, directory: directory)
        let floor = max(previous?.trustedClockFloor ?? .distantPast, serverTime)
        try save(OfflineGrantRecord(grant: grant, deviceID: device.id, accountID: device.accountId, environment: environment, trustedClockFloor: floor), fileManager: fileManager, directory: directory)
    }
}

nonisolated struct PaymentDeviceIdentity: Codable, Equatable, Sendable {
    let id: String
    let accountId: String
}
