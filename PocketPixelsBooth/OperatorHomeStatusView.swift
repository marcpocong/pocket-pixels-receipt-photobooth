import SwiftUI

struct OperatorBrandingView: View {
    @State private var printsGalleryQR = ReceiptPrintSettingsStore.load().includesPrintedGalleryQR

    var body: some View {
        List {
            Section {
                Text("Event logos and receipt layouts are part of each event's setup. Branding never starts or pauses sessions; changes reach guests after Review & Start.")
                NavigationLink(value: OperatorWorkspaceRoute.sessionSetup) { Label("Session Setup", systemImage: "slider.horizontal.3") }
            }
            Section("Design") {
                NavigationLink(value: OperatorWorkspaceRoute.receiptDesign) { Label("Event Receipt Design", systemImage: "paintpalette") }
                NavigationLink(value: OperatorWorkspaceRoute.stickers) { Label("Sticker Studio", systemImage: "face.smiling") }
                NavigationLink(value: OperatorWorkspaceRoute.samplePrints) { Label("Print Display Samples", systemImage: "printer.dotmatrix") }
            }
            Section {
                Toggle("Print Gallery QR Code", isOn: $printsGalleryQR)
                    .onChange(of: printsGalleryQR) { _, value in ReceiptPrintSettingsStore.save(ReceiptPrintOptions(includesPrintedGalleryQR: value)) }
            } header: { Text("Physical Printing") } footer: {
                Text("Applies to every receipt, with or without Event Mode. The guest’s gallery QR always stays available on the iPad.")
            }
            Section("Preview") {
                NavigationLink("Preview Guest Experience") {
                    ScrollView { CustomerExperiencePreviewView(profile: EventProfileStore.load()).padding() }.navigationTitle("Guest Preview")
                }
            }
        }.navigationTitle("Branding & Design").tint(OperatorPalette.ink)
    }
}
