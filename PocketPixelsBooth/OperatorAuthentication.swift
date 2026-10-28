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
    @State private var entry = OperatorPINEntry()
    @Environment(\.scenePhase) private var scenePhase
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
                    VStack(spacing: 20) {
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
                            Text("Enter your 6-digit passcode").font(.headline)
                            HStack(spacing: 16) {
                                ForEach(0..<6) { index in
                                    Circle().fill(index < entry.count ? OperatorPalette.ink : .clear)
                                        .overlay { Circle().stroke(OperatorPalette.ink.opacity(0.6), lineWidth: 1.5) }
                                        .frame(width: 16, height: 16)
                                }
                            }
                            .padding(.vertical, 10)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("Passcode entry")
                            .accessibilityValue("\(entry.count) of 6 digits entered")
                            .accessibilityIdentifier("operator-pin")
                            .privacySensitive()
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                                ForEach(1...9, id: \.self) { digit in keypadDigit(digit) }
                                Color.clear.frame(minHeight: 64).accessibilityHidden(true)
                                keypadDigit(0)
                                Button { entry.delete() } label: {
                                    Image(systemName: "delete.left").font(.title2)
                                        .frame(maxWidth: .infinity, minHeight: 64)
                                }
                                .buttonStyle(OperatorKeypadButtonStyle())
                                .accessibilityLabel("Delete last digit")
                                .accessibilityIdentifier("operator-pin-delete")
                                .disabled(disabled || entry.isSubmitting || entry.count == 0)
                            }
                            .background {
                                OperatorHardwarePINInput(enabled: !disabled && !recovering && !entry.isSubmitting && scenePhase == .active,
                                    insert: enter, delete: { entry.delete() })
                                    .frame(width: 1, height: 1)
                            }
                            if authenticating || entry.isSubmitting { ProgressView("Unlocking…") }
                            if biometric.title != "Biometrics Unavailable" {
                                Button { entry.clear(); unlock() } label: { Label(biometric.title, systemImage: biometric.icon).frame(minHeight: 44) }
                                    .buttonStyle(.plain).disabled(disabled || entry.isSubmitting)
                            }
                            Button("Forgot Passcode?") { entry.clear(); recovering = true }
                                .font(.footnote).foregroundStyle(.secondary).frame(minHeight: 44)
                                .disabled(disabled || entry.isSubmitting)
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
                    .padding(28)
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
        .onChange(of: scenePhase) { _, phase in if phase != .active { entry.clear() } }
        .onDisappear { entry.clear() }
    }

    private func keypadDigit(_ digit: Int) -> some View {
        Button { enter(String(digit)) } label: {
            Text(String(digit)).font(.title2.weight(.medium))
                .frame(maxWidth: .infinity, minHeight: 64)
        }
        .buttonStyle(OperatorKeypadButtonStyle())
        .accessibilityLabel(String(digit))
        .accessibilityIdentifier("operator-pin-\(digit)")
        .disabled(disabled || entry.isSubmitting)
    }

    private func enter(_ text: String) {
        guard !disabled, scenePhase == .active, !recovering, let attempt = entry.insert(text) else { return }
        let request = entry.submissionID
        Task { @MainActor in
            await Task.yield()
            // A background transition cancels an entry before it can grant access.
            guard scenePhase == .active, !disabled, entry.isSubmitting, entry.submissionID == request else { entry.clear(); return }
            verifyPIN(attempt)
            entry.clear()
        }
    }

}

/// One input state for both touch and hardware keyboards. No PIN is exposed in accessibility.
nonisolated struct OperatorPINEntry {
    private var digits = ""
    private(set) var isSubmitting = false
    private(set) var submissionID: UUID?
    var count: Int { isSubmitting ? 6 : digits.count }

    mutating func insert(_ text: String) -> String? {
        guard !isSubmitting else { return nil }
        digits += text.filter { $0.isASCII && $0.isNumber }.prefix(6 - digits.count)
        guard digits.count == 6 else { return nil }
        isSubmitting = true
        submissionID = UUID()
        let attempt = digits
        digits = ""
        return attempt
    }
    mutating func delete() { if !isSubmitting && !digits.isEmpty { digits.removeLast() } }
    mutating func clear() { digits = ""; isSubmitting = false; submissionID = nil }
}

private struct OperatorKeypadButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(OperatorPalette.canvas.opacity(configuration.isPressed ? 0.55 : 1), in: RoundedRectangle(cornerRadius: 16))
            .overlay { RoundedRectangle(cornerRadius: 16).stroke(OperatorPalette.ink.opacity(configuration.isPressed ? 0.5 : 0.12)) }
    }
}

/// Receives physical keyboard events without displaying a system keyboard or visible text field.
private struct OperatorHardwarePINInput: UIViewRepresentable {
    var enabled: Bool
    var insert: (String) -> Void
    var delete: () -> Void
    func makeUIView(context: Context) -> KeyInput { KeyInput() }
    func updateUIView(_ view: KeyInput, context: Context) {
        view.insert = insert; view.delete = delete
        view.acceptsInput = enabled
        if enabled {
            DispatchQueue.main.async { [weak view] in
                guard let view, view.acceptsInput, view.window != nil, !view.isFirstResponder else { return }
                view.becomeFirstResponder()
            }
        } else if view.isFirstResponder { view.resignFirstResponder() }
    }
    final class KeyInput: UITextField, UITextFieldDelegate {
        var insert: (String) -> Void = { _ in }
        var delete: () -> Void = {}
        var acceptsInput = false
        override var canBecomeFirstResponder: Bool { acceptsInput }
        override init(frame: CGRect) {
            super.init(frame: frame)
            delegate = self
            isSecureTextEntry = true
            keyboardType = .numberPad
            autocorrectionType = .no
            spellCheckingType = .no
            inputView = UIView(frame: .zero)
            inputAccessoryView = nil
            tintColor = .clear
            textColor = .clear
            accessibilityLabel = "Hardware passcode input"
            accessibilityIdentifier = "operator-hardware-pin"
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        // Never pass characters into UITextField storage, accessibility, suggestions or undo.
        func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
            guard acceptsInput else { return false }
            if string.isEmpty { delete() } else { insert(string) }
            return false
        }
        override var hasText: Bool { true }
        override func insertText(_ text: String) { if acceptsInput { insert(text) } }
        override func deleteBackward() { if acceptsInput { delete() } }
        override func caretRect(for position: UITextPosition) -> CGRect { .zero }
        override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool { false }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if acceptsInput, window != nil { becomeFirstResponder() }
        }
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
