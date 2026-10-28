import LocalAuthentication
import SwiftUI

struct OperatorPINChangeView: View {
    var ownerRecovery = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var current = ""
    @State private var new = ""
    @State private var confirmation = ""
    @State private var message = ""
    @State private var working = false
    @State private var generation = UUID()
    @State private var context: LAContext?

    var body: some View {
        Form {
            Section(ownerRecovery ? "Owner Recovery" : "Change Passcode") {
                if ownerRecovery {
                    Text("Authenticate as the iPad owner to replace a forgotten operator passcode. This keeps your booth data and credentials.")
                } else {
                    SecureField("Current operator passcode", text: $current).keyboardType(.numberPad)
                }
                SecureField("New six-digit passcode", text: $new).keyboardType(.numberPad)
                SecureField("Confirm new passcode", text: $confirmation).keyboardType(.numberPad)
            }.textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive()
            Section {
                Button(ownerRecovery ? "Authenticate Owner & Set Passcode" : "Change Passcode") { change() }
                    .disabled(working || !OperatorPINStore.isValid(new) || new != confirmation || (!ownerRecovery && !OperatorPINStore.isValid(current)))
                if working { ProgressView("Authenticating…") }
                if !message.isEmpty { Text(message).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle(ownerRecovery ? "Recover Operator Access" : "Change Passcode")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(working)
        .onChange(of: scenePhase) { _, phase in if phase == .background { cancel(); dismiss() } }
        .onDisappear { cancel() }
    }

    private func cancel() {
        generation = UUID(); context?.invalidate(); context = nil
        current = ""; new = ""; confirmation = ""
    }
    private func change() {
        let request = UUID(); generation = request; working = true; message = ""
        Task { @MainActor in
            defer { if generation == request { working = false } }
            do {
                let store = OperatorPINStore()
                if ownerRecovery {
                    let challenge = LAContext(); context = challenge
                    challenge.touchIDAuthenticationAllowableReuseDuration = 0
                    guard try await challenge.evaluatePolicy(.deviceOwnerAuthentication,
                        localizedReason: "Owner recovery: replace the forgotten operator passcode") else { return }
                    guard generation == request, scenePhase != .background else { return }
                    try store.replaceAfterOwnerRecovery(new: new, confirmation: confirmation)
                } else {
                    guard OperatorAccessPermit.shared.isAuthorized else { throw SetupFailure("Unlock operator controls first.") }
                    try store.change(current: current, new: new, confirmation: confirmation)
                }
                current = ""; new = ""; confirmation = ""
                message = "Operator passcode changed. Use the new passcode next time you unlock."
            } catch {
                guard generation == request else { return }
                message = (error as? SetupFailure)?.localizedDescription ?? "Passcode was not changed. Try again when you’re ready."
            }
        }
    }
}
