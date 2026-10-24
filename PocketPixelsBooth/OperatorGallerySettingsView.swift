import SwiftUI

struct OperatorGallerySettingsView: View {
    @State private var token = ""
    @AppStorage(SessionMediaExport.retentionKey) private var keepsOriginals = true
    @AppStorage(SessionMediaExport.retentionErrorKey) private var retentionNeedsReview = false
    @State private var originalStorage = "Calculating…"
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
            Section("Local Photo Retention") {
                Toggle("Keep Original Photos for Export", isOn: $keepsOriginals)
                LabeledContent("Retained originals", value: originalStorage)
                if retentionNeedsReview {
                    Label("An original-photo write failed. Review recent sessions and free storage. Receipts and gallery recovery were retained independently.", systemImage: "exclamationmark.triangle")
                    Button("Acknowledge Retention Warning") { retentionNeedsReview = false }.frame(minHeight: 44)
                }
                Text("Applies to future captures. Disabling keeps existing originals. Protected app files are excluded from device backup; exports to Photos require a separate Save action. Delete Local Session removes the app's media; public galleries and Photos copies remain.").font(.footnote)
            }
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
        .task {
            let bytes = await Task.detached(priority: .utility) { try? RecentSessionArchiveStore().originalPhotoStorageBytes() }.value
            originalStorage = bytes.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "Storage unavailable"
        }
    }
}
