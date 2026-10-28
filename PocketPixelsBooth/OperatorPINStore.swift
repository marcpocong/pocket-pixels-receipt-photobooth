import CommonCrypto
import Foundation
import Security

/// A salted PBKDF2 verifier and persisted guessing delay, isolated from payment credentials.
/// Missing items may install the default; every other Keychain/decoding error fails closed.
nonisolated struct OperatorPINStore: Sendable {
    let service: String
    init(service: String = "com.pocketpixels.operator.pin.v1") { self.service = service }
    private static let rounds: UInt32 = 150_000
    private struct Record: Codable {
        let salt: Data
        let verifier: Data
        var failures = 0
        var retryAfter: Date?
    }
    private var identity: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: "operator-pin-verifier"]
    }
    static func isValid(_ pin: String) -> Bool {
        pin.utf8.count == 6 && pin.utf8.allSatisfy { (48...57).contains($0) }
    }
    func installDefaultIfNeeded() throws {
        guard try read() == nil else { return }
        let record = try makeRecord("987654")
        var item = identity
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        item[kSecValueData as String] = try JSONEncoder().encode(record)
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else { throw failure(status) }
    }
    func verify(_ pin: String, now: Date = Date()) throws -> Bool {
        try installDefaultIfNeeded()
        guard var record = try read() else { throw SetupFailure("Operator passcode storage is unavailable.") }
        if let date = record.retryAfter, date > now {
            throw SetupFailure("Too many attempts. Try again in \(Int(ceil(date.timeIntervalSince(now)))) seconds, or use owner recovery.")
        }
        let candidate = try Self.isValid(pin) ? Self.derive(pin, salt: record.salt) : Data(count: 32)
        let accepted = Self.isValid(pin) && constantTimeEqual(candidate, record.verifier)
        if accepted { record.failures = 0; record.retryAfter = nil }
        else {
            record.failures = min(record.failures + 1, 12)
            if record.failures >= 5 {
                let delay = min(300.0, 30 * pow(2, Double(record.failures - 5)))
                record.retryAfter = now.addingTimeInterval(delay)
            }
        }
        try write(record)
        return accepted
    }
    func change(current: String, new: String, confirmation: String) throws {
        guard Self.isValid(new), new == confirmation else { throw SetupFailure("Enter and confirm the same six-digit passcode.") }
        guard try verify(current) else { throw SetupFailure("Current operator passcode is incorrect.") }
        try write(makeRecord(new))
    }
    /// Caller must first complete the separate Apple device-owner recovery challenge.
    func replaceAfterOwnerRecovery(new: String, confirmation: String) throws {
        guard Self.isValid(new), new == confirmation else { throw SetupFailure("Enter and confirm the same six-digit passcode.") }
        let record = try makeRecord(new)
        let data = try JSONEncoder().encode(record)
        let updated = SecItemUpdate(identity as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updated == errSecItemNotFound {
            var item = identity
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            item[kSecValueData as String] = data
            let status = SecItemAdd(item as CFDictionary, nil)
            guard status == errSecSuccess else { throw failure(status) }
        } else if updated != errSecSuccess { throw failure(updated) }
    }
    private func makeRecord(_ pin: String) throws -> Record {
        var salt = Data(count: 32)
        let status = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }
        guard status == errSecSuccess else { throw failure(status) }
        return Record(salt: salt, verifier: try Self.derive(pin, salt: salt))
    }
    private static func derive(_ pin: String, salt: Data) throws -> Data {
        var result = Data(count: 32)
        let password = Array(pin.utf8)
        let status = password.withUnsafeBytes { passwordBytes in
            salt.withUnsafeBytes { saltBytes in
                result.withUnsafeMutableBytes { output in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.baseAddress!.assumingMemoryBound(to: Int8.self), passwordBytes.count,
                        saltBytes.baseAddress!.assumingMemoryBound(to: UInt8.self), saltBytes.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), rounds,
                        output.baseAddress!.assumingMemoryBound(to: UInt8.self), output.count)
                }
            }
        }
        guard status == kCCSuccess else { throw SetupFailure("Could not protect the operator passcode.") }
        return result
    }
    private func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for (a, b) in zip(lhs, rhs) { difference |= a ^ b }
        return difference == 0
    }
    private func read() throws -> Record? {
        var query = identity
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw failure(status) }
        let record = try JSONDecoder().decode(Record.self, from: data)
        guard record.salt.count == 32, record.verifier.count == 32, (0...12).contains(record.failures) else {
            throw SetupFailure("Operator passcode storage needs owner recovery.")
        }
        return record
    }
    private func write(_ record: Record) throws {
        let status = SecItemUpdate(identity as CFDictionary,
            [kSecValueData as String: try JSONEncoder().encode(record)] as CFDictionary)
        guard status == errSecSuccess else { throw failure(status) }
    }
    private func failure(_ status: OSStatus) -> SetupFailure {
        SetupFailure("Operator passcode storage is unavailable (\(status)). Unlock the iPad and try again.")
    }
}
