import SwiftUI

struct OperatorGallerySettingsView: View {
    @State private var token = ""
    @State private var message = ""
    @StateObject private var operations = EventOperationalState.shared
    var body: some View {
        Form {
            Text(DeviceCredentialStore().hasDeviceToken() ? "Gallery credential saved on this iPad." : "Gallery credential missing. Photos can wait locally for setup.")
            SecureField("New device upload token", text: $token)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("Save Gallery Credential") {
                do {
                    try DeviceCredentialStore().saveDeviceToken(token)
                    token = ""
                    message = "Saved securely on this iPad."
                    operations.refresh()
                } catch { message = "Could not save. Verify the device token and try again." }
            }.disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).count < 24 || operations.isUploadWorkerRunning)
            Text(message)
            Text("Tokens are stored in Keychain and excluded from diagnostic reports. Changing credentials does not delete pending galleries.")
        }.navigationTitle("Gallery Credentials")
        .onDisappear { token = "" }
    }
}
