import SwiftUI

struct OperatorBrandingView: View {
    @State private var galleryStyle = GalleryReceiptSettingsStore.load()
    @State private var printOptions = ReceiptPrintSettingsStore.load()

    var body: some View {
        List {
            Section {
                NavigationLink("Regular Booth Footer, Logo & Branding", value: OperatorWorkspaceRoute.regularBooth)
                Text("Event logos and receipt layouts are part of each event's setup. Branding never starts or pauses sessions; changes reach guests after Review & Start.")
                NavigationLink(value: OperatorWorkspaceRoute.sessionSetup) { Label("Session Setup", systemImage: "slider.horizontal.3") }
            }
            Section("Design") {
                NavigationLink(value: OperatorWorkspaceRoute.receiptDesign) { Label("Event Receipt Design", systemImage: "paintpalette") }
                NavigationLink(value: OperatorWorkspaceRoute.stickers) { Label("Sticker Studio", systemImage: "face.smiling") }
                NavigationLink(value: OperatorWorkspaceRoute.samplePrints) { Label("Print Display Samples", systemImage: "printer.dotmatrix") }
            }
            Section {
                Picker("Gallery Code Style", selection: $printOptions.footerStyle) {
                    ForEach(ReceiptFooterStyle.allCases) { style in Text(style.displayName).tag(style) }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("device-gallery-code-style")
                .onChange(of: printOptions) { _, value in ReceiptPrintSettingsStore.save(value) }
                Button("Restore Default") { printOptions = .default }
                if printOptions.footerStyle == .decorativeBarcodeOnly {
                    Label("The barcode is decorative and does not provide gallery access.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
            } header: { Text("Physical Printing") } footer: {
                Text("Device default for future sessions. Saved events can override it. The guest’s gallery QR always stays available on the iPad.")
            }
            Section {
                Picker("Default QR Gallery Receipt Style", selection: $galleryStyle) {
                    ForEach(GalleryReceiptStyle.allCases) { style in Text(style.title).tag(style) }
                }
                .onChange(of: galleryStyle) { _, value in GalleryReceiptSettingsStore.save(value) }
            } header: { Text("Customer Gallery") } footer: {
                Text("Default digital receipt style for future guests. Saved events may inherit or override it.")
            }
            Section("Preview") {
                NavigationLink("Preview Guest Experience") {
                    ScrollView { CustomerExperiencePreviewView(profile: EventProfileStore.load()).padding() }.navigationTitle("Guest Preview")
                }
            }
        }
        .onAppear { printOptions = ReceiptPrintSettingsStore.load(); galleryStyle = GalleryReceiptSettingsStore.load() }
        .onReceive(NotificationCenter.default.publisher(for: ReceiptPrintSettingsStore.didChangeNotification)) { _ in
            printOptions = ReceiptPrintSettingsStore.load()
        }
        .navigationTitle("Branding & Design").tint(OperatorPalette.ink)
    }
}
