import SwiftUI

struct ReceiptDesignAndBrandingView: View {
    @State private var profile = EventProfileStore.load()
    @State private var printOptions = ReceiptPrintSettingsStore.load()
    @State private var statusMessage = ""

    var body: some View {
        Form {
            ReceiptPhysicalPrintingSection(
                includesPrintedGalleryQR: Binding(
                    get: { printOptions.includesPrintedGalleryQR },
                    set: { value in
                        printOptions.includesPrintedGalleryQR = value
                        ReceiptPrintSettingsStore.save(printOptions)
                    }
                )
            )

            Section("Event Branding") {
                EventHeaderEditorView(profile: $profile, statusMessage: $statusMessage)

                Button("Save Receipt Branding") {
                    profile = profile.normalized()
                    EventProfileStore.save(profile)
                    statusMessage = "Receipt branding saved for the next customer."
                }
                .buttonStyle(.borderedProminent)

                if !statusMessage.isEmpty {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Actual Printer-Raster Preview") {
                ReceiptPreviewStateSummary(
                    brandingMode: profile.receiptHeader.brandingMode ?? .studioFirst,
                    includesPrintedGalleryQR: printOptions.includesPrintedGalleryQR
                )
                EventReceiptComposerPreview(profile: profile, printOptions: printOptions)
            }
        }
        .navigationTitle("Receipt Design & Branding")
        .navigationBarTitleDisplayMode(.inline)
        .onReceive(NotificationCenter.default.publisher(for: EventProfileStore.didChangeNotification)) { _ in
            profile = EventProfileStore.load()
        }
    }
}

private struct ReceiptPhysicalPrintingSection: View {
    @Binding var includesPrintedGalleryQR: Bool

    var body: some View {
        Section("Physical Printing") {
            Toggle("Print Gallery QR Code", isOn: $includesPrintedGalleryQR)
            Text("Include a gallery QR code on physical receipts. The guest’s gallery QR remains available on the iPad.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct ReceiptPreviewStateSummary: View {
    let brandingMode: ReceiptBrandingMode
    let includesPrintedGalleryQR: Bool

    var body: some View {
        LabeledContent("Branding", value: brandingMode.displayName)
        LabeledContent("Printed Gallery QR", value: includesPrintedGalleryQR ? "ON" : "OFF")
    }
}
