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
    private let pinStore: OperatorPINStore
    private var generation = UUID()

    init(permit: OperatorAccessPermit = .shared, evaluate: @escaping () async throws -> Bool = {
        let context = LAContext()
        context.touchIDAuthenticationAllowableReuseDuration = 0
        context.localizedFallbackTitle = ""
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            throw error ?? NSError(domain: "OperatorAuthentication", code: 1)
        }
        return try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics,
            localizedReason: "Unlock Made to Keep Studios operator controls")
    }, pinStore: OperatorPINStore = OperatorPINStore()) {
        self.permit = permit
        self.evaluate = evaluate
        self.pinStore = pinStore
    }

    func unlock(pin: String) {
        guard !isAuthenticating else { return }
        isAuthenticating = true
        defer { isAuthenticating = false }
        do {
            if try pinStore.verify(pin) { grantAccess() }
            else { message = "Incorrect operator passcode. Try again." }
        } catch { message = error.localizedDescription }
    }

    private func grantAccess() {
        permit.authorize()
        isUnlocked = true
        message = ""
        NotificationCenter.default.post(name: OperatorWorkspace.didUnlock, object: nil)
    }

    func unlock() async {
        guard !isAuthenticating else { return }
        let request = UUID()
        generation = request
        isAuthenticating = true
        defer { if generation == request { isAuthenticating = false } }
        do {
            let accepted = try await evaluate()
            guard generation == request else { return }
            if accepted {
                grantAccess()
            } else {
                message = "Couldn’t unlock with biometrics. Enter your operator passcode."
            }
        } catch {
            guard generation == request else { return }
            if let error = error as? LAError, [.userCancel, .systemCancel, .appCancel].contains(error.code) {
                message = "Unlock cancelled. Try again when you’re ready."
            } else if (error as NSError).code == Int(errSecUserCanceled) {
                message = "Unlock cancelled. Try again when you’re ready."
            } else if let error = error as? LAError, error.code == .passcodeNotSet {
                message = "Enter your operator passcode to unlock controls."
            } else {
                message = "Couldn’t unlock with biometrics. Enter your operator passcode."
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
                    verifyPIN: { authentication.unlock(pin: $0) },
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

/// Ordinary access uses the operator PIN; Apple owner authentication is recovery only.
struct OperatorAccessScreen: View {
    var authenticating = false
    var disabled = false
    var message = ""
    var unlock: () -> Void
    var verifyPIN: (String) -> Void
    @State private var pin = ""
    @State private var recovering = false
    var back: () -> Void

    private let biometric: (title: String, icon: String) = {
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else {
            return ("Biometrics Unavailable", "lock.open")
        }
        switch context.biometryType {
        case .faceID: return ("Unlock with Face ID", "faceid")
        case .touchID: return ("Unlock with Touch ID", "touchid")
        default: return ("Biometrics Unavailable", "lock.open")
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
                            SecureField("Six-digit operator passcode", text: $pin)
                                .keyboardType(.numberPad).textContentType(.password)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                                .textFieldStyle(.roundedBorder)
                                .privacySensitive()
                                .accessibilityIdentifier("operator-pin")
                                .onChange(of: pin) { _, value in pin = String(value.filter { $0.isASCII && $0.isNumber }.prefix(6)) }
                                .onSubmit { submitPIN() }
                            Button(action: submitPIN) {
                                Text(authenticating ? "Unlocking…" : "Unlock Operator")
                                    .font(.headline).frame(maxWidth: .infinity, minHeight: 56)
                            }.buttonStyle(.borderedProminent)
                                .disabled(disabled || !OperatorPINStore.isValid(pin))
                            if biometric.title != "Biometrics Unavailable" {
                                Button(action: unlock) { Label(biometric.title, systemImage: biometric.icon).frame(minHeight: 44) }
                                    .buttonStyle(.bordered).disabled(disabled)
                            }
                            Button("Forgot Operator Passcode?") { recovering = true }.disabled(disabled)
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
        .sheet(isPresented: $recovering) {
            NavigationStack {
                OperatorPINChangeView(ownerRecovery: true)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { recovering = false } } }
            }
        }
        .tint(OperatorPalette.ink)
        .background(OperatorPalette.canvas.ignoresSafeArea())
    }
    private func submitPIN() {
        guard !disabled, OperatorPINStore.isValid(pin) else { return }
        let entered = pin; pin = ""; verifyPIN(entered)
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
