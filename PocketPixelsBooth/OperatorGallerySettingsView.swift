import SwiftUI

struct OperatorGallerySettingsView: View {
    @State private var token = ""
    @State private var message = ""
    @State private var checkingBackend = false
    @State private var backendStatus: String?
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
            Section("Delivery diagnostics") {
                LabeledContent("Waiting galleries", value: "\(operations.pendingUploadCount)")
                Text(operations.lastUploadWorkerMessage).font(.callout)
                Button(checkingBackend ? "Checking backend…" : "Check Gallery Backend") {
                    checkingBackend = true
                    Task {
                        let result = await GoogleDriveGalleryUploadService().testBackendDiagnostic()
                        backendStatus = result.diagnosticDescription
                        checkingBackend = false
                    }
                }.disabled(checkingBackend)
                if let backendStatus { Text(backendStatus).font(.callout) }
                Text("This read-only check does not upload photos. A gallery is confirmed delivered only after its printed URL serves the completed page.").font(.caption)
            }
            Text(message)
            Text("Tokens are stored in Keychain and excluded from diagnostic reports. Changing credentials does not delete pending galleries.")
        }.navigationTitle("Gallery Setup")
        .onDisappear { token = "" }
    }
}
