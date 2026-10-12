import SwiftUI
import LocalAuthentication
import Combine
import Security

/// A short-lived permit, shared with the API credential reader. Locking never changes booth data.
nonisolated final class OperatorAccessPermit: @unchecked Sendable {
    static let shared = OperatorAccessPermit()
    private let lock = NSLock()
    private var expiresAt = Date.distantPast

    var isAuthorized: Bool { lock.withLock { Date() < expiresAt } }
    func authorize() { lock.withLock { expiresAt = Date().addingTimeInterval(300) } }
    func revoke() { lock.withLock { expiresAt = .distantPast } }
}

@MainActor final class OperatorAuthentication: ObservableObject {
    @Published private(set) var isUnlocked = false
    @Published private(set) var isAuthenticating = false
    @Published private(set) var message = "Authenticate with the iPad owner's Face ID or device passcode."
    private let permit: OperatorAccessPermit
    private let evaluate: () async throws -> Bool
    private let evaluatePasscode: () async throws -> Bool
    private var generation = UUID()

    init(permit: OperatorAccessPermit = .shared, evaluate: @escaping () async throws -> Bool = {
        let context = LAContext()
        context.touchIDAuthenticationAllowableReuseDuration = 0
        context.localizedFallbackTitle = "Use iPad Passcode"
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            throw error ?? NSError(domain: "OperatorAuthentication", code: 1)
        }
        return try await context.evaluatePolicy(.deviceOwnerAuthentication,
            localizedReason: "Unlock Made to Keep Studios operator controls")
    }, evaluatePasscode: @escaping () async throws -> Bool = {
        try await OperatorAuthentication.authenticateWithDevicePasscode()
    }) {
        self.permit = permit
        self.evaluate = evaluate
        self.evaluatePasscode = evaluatePasscode
    }

    func unlock(usingPasscode: Bool = false) async {
        guard !isAuthenticating else { return }
        let request = UUID()
        generation = request
        isAuthenticating = true
        defer { if generation == request { isAuthenticating = false } }
        do {
            let accepted = try await (usingPasscode ? evaluatePasscode() : evaluate())
            guard generation == request else { return }
            if accepted {
                permit.authorize()
                isUnlocked = true
            } else {
                message = "Operator access was not authorized. Try again with the device owner."
            }
        } catch {
            guard generation == request else { return }
            message = "Operator access is locked. The owner must configure or recover the iPad passcode in Settings, then authenticate again. Booth records are preserved."
        }
    }

    func lock() {
        generation = UUID()
        isAuthenticating = false
        isUnlocked = false
        permit.revoke()
    }

    func expireIfNeeded() { if isUnlocked && !permit.isAuthorized { lock() } }

    /// A passcode-only Keychain ACL gives attendants an explicit system passcode prompt,
    /// without storing a PIN or relying on a failed Face ID attempt to reveal the fallback.
    nonisolated private static func authenticateWithDevicePasscode() async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let context = LAContext()
                context.localizedReason = "Unlock Made to Keep Studios operator controls with the iPad passcode"
                context.touchIDAuthenticationAllowableReuseDuration = 0
                var error: NSError?
                guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error),
                      let access = SecAccessControlCreateWithFlags(nil,
                        kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, .devicePasscode, nil) else {
                    continuation.resume(throwing: error ?? NSError(domain: "OperatorAuthentication", code: 2))
                    return
                }
                let identity: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: "com.pocketpixels.operator.authentication",
                    kSecAttrAccount as String: "device-passcode-proof-v1"]
                var item = identity
                item[kSecAttrAccessControl as String] = access
                item[kSecValueData as String] = Data(UUID().uuidString.utf8)
                let added = SecItemAdd(item as CFDictionary, nil)
                guard added == errSecSuccess || added == errSecDuplicateItem else {
                    continuation.resume(throwing: NSError(domain: NSOSStatusErrorDomain, code: Int(added)))
                    return
                }
                var query = identity
                query[kSecUseAuthenticationContext as String] = context
                query[kSecReturnData as String] = true
                query[kSecMatchLimit as String] = kSecMatchLimitOne
                var result: CFTypeRef?
                let status = SecItemCopyMatching(query as CFDictionary, &result)
                guard status == errSecSuccess, result is Data else {
                    continuation.resume(throwing: NSError(domain: NSOSStatusErrorDomain, code: Int(status)))
                    return
                }
                continuation.resume(returning: true)
            }
        }
    }
}

struct OperatorAuthenticationView<Controls: View>: View {
    @StateObject private var authentication = OperatorAuthentication()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    private let clock = Timer.publish(every: 5, on: .main, in: .common).autoconnect()
    @ViewBuilder let controls: () -> Controls

    var body: some View {
        ZStack {
            if authentication.isUnlocked && scenePhase == .active {
                controls()
            } else {
                VStack(spacing: 24) {
                    Image(systemName: "lock.shield").font(.largeTitle)
                    Text("Operator Access").font(.title.bold())
                    Text(authentication.message).multilineTextAlignment(.center)
                    Button(authentication.isAuthenticating ? "Authenticating…" : "Unlock Operator Controls") {
                        Task { await authentication.unlock() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(authentication.isAuthenticating || scenePhase != .active)
                    Button("Use iPad Passcode") {
                        Task { await authentication.unlock(usingPasscode: true) }
                    }
                    .buttonStyle(.bordered)
                    .disabled(authentication.isAuthenticating || scenePhase != .active)
                    Button("Return to Booth") { dismiss() }
                }
                .padding(40)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // Authentication itself may briefly make the scene inactive. Background always locks.
            if phase == .background { authentication.lock() }
            if phase == .active { authentication.expireIfNeeded() }
        }
        .onReceive(clock) { _ in authentication.expireIfNeeded() }
        .onDisappear { authentication.lock() }
    }
}
