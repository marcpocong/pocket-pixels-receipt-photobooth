import SwiftUI
import LocalAuthentication
import Combine
import Security
import UIKit

/// Session-scoped operator access, shared with the API credential reader. No inactivity expiry.
nonisolated final class OperatorAccessPermit: @unchecked Sendable {
    static let shared = OperatorAccessPermit()
    private let lock = NSLock()
    private var authorized = false

    var isAuthorized: Bool { lock.withLock { authorized } }
    func authorize() { lock.withLock { authorized = true } }
    func revoke() { lock.withLock { authorized = false } }
}

@MainActor final class OperatorAuthentication: ObservableObject {
    @Published private(set) var isUnlocked = false
    @Published private(set) var isAuthenticating = false
    @Published private(set) var message = ""
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
                NotificationCenter.default.post(name: OperatorWorkspace.didUnlock, object: nil)
            } else {
                message = "Couldn’t unlock. Try again or use the iPad passcode."
            }
        } catch {
            guard generation == request else { return }
            if let error = error as? LAError, [.userCancel, .systemCancel, .appCancel].contains(error.code) {
                message = "Unlock cancelled. Try again when you’re ready."
            } else if (error as NSError).code == Int(errSecUserCanceled) {
                message = "Unlock cancelled. Try again when you’re ready."
            } else if let error = error as? LAError, error.code == .passcodeNotSet {
                message = "Set an iPad passcode in Settings to unlock operator controls."
            } else {
                message = "Couldn’t unlock. Try again or use the iPad passcode."
            }
        }
    }

    func lock() {
        generation = UUID()
        isAuthenticating = false
        isUnlocked = false
        permit.revoke()
    }

    func synchronizeAuthorization() { if isUnlocked && !permit.isAuthorized { lock() } }

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
    @StateObject private var authentication: OperatorAuthentication
    @State private var hasOpenedWorkspace = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    @ViewBuilder let controls: () -> Controls

    init(authentication: OperatorAuthentication? = nil, @ViewBuilder controls: @escaping () -> Controls) {
        _authentication = StateObject(wrappedValue: authentication ?? OperatorAuthentication())
        self.controls = controls
    }

    private var isConcealed: Bool { !authentication.isUnlocked || scenePhase != .active }

    var body: some View {
        ZStack {
            if hasOpenedWorkspace {
                controls()
                    .opacity(isConcealed ? 0 : 1)
                    .allowsHitTesting(!isConcealed)
                    .accessibilityHidden(isConcealed)
                    .disabled(isConcealed)
            }
            if isConcealed {
                OperatorAccessScreen(
                    authenticating: authentication.isAuthenticating,
                    disabled: authentication.isAuthenticating || scenePhase != .active,
                    message: authentication.message,
                    unlock: { Task { await authentication.unlock() } },
                    passcode: { Task { await authentication.unlock(usingPasscode: true) } },
                    back: { dismiss() }
                )
                .zIndex(1)
            }
        }
        .background(OperatorWindowPrivacyCover(concealed: scenePhase != .active))
        .onAppear { if authentication.isUnlocked { hasOpenedWorkspace = true } }
        .onChange(of: authentication.isUnlocked) { _, unlocked in
            if unlocked { hasOpenedWorkspace = true }
        }
        .onChange(of: scenePhase) { _, phase in
            // Authentication itself may briefly make the scene inactive. Background always locks.
            if phase == .background {
                OperatorWorkspace.shared.checkpoint()
                authentication.lock()
            }
            if phase == .active { authentication.synchronizeAuthorization() }
        }
        .onDisappear { authentication.lock() }
    }
}

/// Presentation only. Both authentication actions continue to use native owner authentication.
struct OperatorAccessScreen: View {
    var authenticating = false
    var disabled = false
    var message = ""
    var unlock: () -> Void
    var passcode: () -> Void
    var back: () -> Void

    private let biometric: (title: String, icon: String) = {
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else {
            return ("Unlock Operator", "lock.open")
        }
        switch context.biometryType {
        case .faceID: return ("Unlock with Face ID", "faceid")
        case .touchID: return ("Unlock with Touch ID", "touchid")
        default: return ("Unlock Operator", "lock.open")
        }
    }()

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 22) {
                    VStack(spacing: 28) {
                        VStack(spacing: 16) {
                            Text("MADE TO KEEP STUDIOS")
                                .font(.caption.weight(.semibold)).tracking(2).foregroundStyle(.secondary)
                            Image(systemName: "lock.shield")
                                .font(.system(size: 30, weight: .medium))
                                .frame(width: 72, height: 72)
                                .background(OperatorPalette.canvas, in: RoundedRectangle(cornerRadius: 20))
                            Text("Operator Access").font(.largeTitle.weight(.semibold))
                            Text("Unlock to manage your booth.")
                                .font(.body).foregroundStyle(.secondary)
                        }
                        VStack(spacing: 12) {
                            Button(action: unlock) {
                                HStack(spacing: 12) {
                                    if authenticating { ProgressView().tint(Color(uiColor: .systemBackground)) }
                                    else { Image(systemName: biometric.icon) }
                                    Text(authenticating ? "Unlocking…" : biometric.title)
                                }.font(.headline).frame(maxWidth: .infinity, minHeight: 56)
                            }
                            .buttonStyle(.borderedProminent).buttonBorderShape(.roundedRectangle(radius: 14))
                            .disabled(disabled)
                            Button(action: passcode) {
                                Label("Use iPad Passcode", systemImage: "key.horizontal")
                                    .font(.body.weight(.medium)).frame(maxWidth: .infinity, minHeight: 52)
                            }
                            .buttonStyle(.bordered).buttonBorderShape(.roundedRectangle(radius: 14))
                            .disabled(disabled)
                        }
                        if !message.isEmpty {
                            Text(message).font(.callout).foregroundStyle(.secondary)
                                .multilineTextAlignment(.center).accessibilityAddTraits(.updatesFrequently)
                        }
                        Divider()
                        Label("Your setup and unsaved changes are kept.", systemImage: "checkmark.shield")
                            .font(.footnote).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(36)
                    .frame(maxWidth: 480)
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 28))
                    .overlay { RoundedRectangle(cornerRadius: 28).stroke(.secondary.opacity(0.12)) }

                    Button(action: back) {
                        Label("Back to Booth", systemImage: "arrow.left").font(.body.weight(.medium))
                            .frame(minHeight: 48)
                    }.buttonStyle(.plain).disabled(authenticating)
                }
                .padding(24)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
        }
        .tint(OperatorPalette.ink)
        .background(OperatorPalette.canvas.ignoresSafeArea())
    }
}

/// Covers the complete operator window (including sheets) before an app-switcher snapshot.
private struct OperatorWindowPrivacyCover: UIViewRepresentable {
    let concealed: Bool
    func makeUIView(context: Context) -> Anchor { Anchor() }
    func updateUIView(_ view: Anchor, context: Context) { view.setConcealed(concealed) }
    static func dismantleUIView(_ view: Anchor, coordinator: ()) { view.removeCover() }

    final class Anchor: UIView {
        private var cover: UIView?
        private var concealed = false
        private var observers: [NSObjectProtocol] = []
        override init(frame: CGRect) {
            super.init(frame: frame)
            observers.append(NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setConcealed(true) }
            })
            observers.append(NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    // Dismiss transient confirmations/shares, never the operator cover itself.
                    guard let self else { return }
                    var responder: UIResponder? = self
                    while let current = responder {
                        if let controller = current as? UIViewController {
                            if controller !== self.window?.rootViewController { controller.presentedViewController?.dismiss(animated: false) }
                            break
                        }
                        responder = current.next
                    }
                }
            })
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        deinit { observers.forEach(NotificationCenter.default.removeObserver) }
        override func didMoveToWindow() { super.didMoveToWindow(); setConcealed(concealed) }
        func setConcealed(_ value: Bool) {
            concealed = value
            guard value, let window else { removeCover(); return }
            if cover == nil {
                let view = UIView(frame: window.bounds)
                view.backgroundColor = .systemBackground
                view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                view.accessibilityLabel = "Operator locked"
                view.accessibilityViewIsModal = true
                cover = view
                window.addSubview(view)
            }
            if let cover { window.bringSubviewToFront(cover) }
        }
        func removeCover() { cover?.removeFromSuperview(); cover = nil }
    }
}
