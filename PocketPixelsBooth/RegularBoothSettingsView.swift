import SwiftUI

struct RegularBoothSettingsView: View {
    @State private var settings = RegularBoothSettings.load()
    @State private var message = ""
    @State private var loadIssue = RegularBoothSettings.loadIssue()
    @State private var design: SavedEventDesign = {
        var value = SavedEventDesign.new(name: "Regular Booth", venue: "")
        value.profile = RegularBoothSettings.load().profile
        value.personalizeReceipt = value.profile.receiptHeader.mode == .customEventHeader
        return value
    }()
    var body: some View {
        Form {
            if let loadIssue {
                Section("Review saved settings") { Text(loadIssue).foregroundStyle(.orange) }
            }
            Section("Regular Booth") {
                Text("Local, no-payment sessions. Changes apply to the next guest and do not change event settings.")
                Stepper("Default copies: \(settings.defaultCopies)", value: $settings.defaultCopies, in: 1...max(1, settings.maxCopies))
                Stepper("Maximum copies: \(settings.maxCopies)", value: $settings.maxCopies, in: 1...10)
                Toggle("Let guests choose additional copies", isOn: $settings.guestCopyChoice)
            }
            Section("Available formats") {
                ForEach(BoothFormat.allCases, id: \.rawValue) { format in
                    Toggle(format.rawValue, isOn: Binding(get: { settings.formats.contains(format.rawValue) }, set: { enabled in
                        if enabled { settings.formats.append(format.rawValue) }
                        else { settings.formats.removeAll { $0 == format.rawValue } }
                    }))
                }
            }
            Section("Footer, logo & branding") {
                Text("These defaults are independent of saved events. Current guests keep the design they started with.")
                EventReceiptDesignPanel(design: $design, isDirty: false, save: {}, discard: {}, isRegularBooth: true)
                TextField("Optional receipt caption", text: $design.profile.receiptDesign.editorialCaption, axis: .vertical)
                NavigationLink("Preview Receipt") {
                    ScrollView { EventReceiptComposerPreview(profile: regularProfile, printOptions: ReceiptPrintSettingsStore.load().resolved(for: regularProfile), showsSamplePrintLink: false).padding() }.navigationTitle("Regular Booth Preview")
                }
                NavigationLink("Device Footer & Gallery Defaults", value: OperatorWorkspaceRoute.branding)
            }
            Section {
                Button("Save Regular Booth Defaults") {
                    guard OperatorAccessPermit.shared.isAuthorized else { message = "Unlock Operator again before saving."; return }
                    do {
                        settings.receiptProfile = regularProfile
                        try RegularBoothSettings.save(settings)
                        loadIssue = nil
                        message = "Saved for the next Regular Booth guest."
                    }
                    catch { message = error.localizedDescription }
                }.disabled(settings.formats.isEmpty)
                if !message.isEmpty { Text(message) }
            }
        }.navigationTitle("Regular Booth Settings")
        .environment(\.defaultMinListRowHeight, 52)
    }
    private var regularProfile: EventProfile {
        var profile = design.profile
        // A receipt-only default uses the existing renderer without creating an event/run.
        profile.isEnabled = true
        profile.customerScreenEnabled = false
        profile.showEventTextBlock = false
        profile.receiptHeader.mode = design.personalizeReceipt ? .customEventHeader : .pocketPixelsDefault
        return profile
    }
}
