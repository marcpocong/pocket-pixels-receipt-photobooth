import SwiftUI

struct RegularBoothSettingsView: View {
    @ObservedObject private var workspace: OperatorWorkspace
    private let footerOnly: Bool
    @State private var settings: RegularBoothSettings
    @State private var saved: RegularBoothSettings
    @State private var message = ""
    @State private var loadIssue = RegularBoothSettings.loadIssue()
    @State private var design: SavedEventDesign

    init(workspace: OperatorWorkspace? = nil, footerOnly: Bool = false) {
        self.footerOnly = footerOnly
        let workspace = workspace ?? .shared
        _workspace = ObservedObject(wrappedValue: workspace)
        let settings = workspace.snapshot.regularBoothDraft ?? RegularBoothSettings.load()
        let displayedProfile = settings.profile
        _settings = State(initialValue: settings)
        var baseline = RegularBoothSettings.load()
        var profile = baseline.profile
        profile.isEnabled = true; profile.customerScreenEnabled = false; profile.showEventTextBlock = false
        // The fallback studio profile has a generated date even though it prints no event date.
        // Reuse the displayed fallback so opening an untouched form isn't itself an edit.
        if baseline.receiptProfile == nil { profile.eventDate = displayedProfile.eventDate }
        baseline.receiptProfile = profile
        _saved = State(initialValue: baseline)
        var design = SavedEventDesign.new(name: "Regular Booth", venue: "")
        design.profile = displayedProfile
        design.personalizeReceipt = settings.profile.receiptHeader.mode == .customEventHeader
        _design = State(initialValue: design)
    }

    private var candidate: RegularBoothSettings {
        var value = settings; value.receiptProfile = regularProfile; return value
    }
    private var isDirty: Bool { candidate != saved }
    private func checkpoint() { workspace.saveRegularBoothDraft(isDirty ? candidate : nil) }

    var body: some View {
        Group {
            if footerOnly { footerForm }
            else { settingsForm }
        }
        .safeAreaInset(edge: .bottom) { saveBar }
        .tint(OperatorPalette.accent)
        .onAppear { reloadDraft() }
        .onChange(of: settings) { _, _ in message = ""; checkpoint() }
        .onChange(of: design) { _, _ in message = ""; checkpoint() }
    }
    private var footerForm: some View {
        Form {
            Section("Regular Booth receipt") {
                Text("Applies to the next Regular Booth guest. Event designs and admitted guests keep their own settings.")
                    .font(.callout).foregroundStyle(OperatorPalette.secondaryText)
                EventReceiptDesignPanel(design: $design, isDirty: false, save: {}, discard: {}, isRegularBooth: true)
                TextField("Footer text / optional receipt caption", text: $design.profile.receiptDesign.editorialCaption, axis: .vertical)
                    .accessibilityIdentifier("regular-footer-text")
            }
            Section {
                NavigationLink("Preview Receipt") {
                    ScrollView { EventReceiptComposerPreview(profile: regularProfile, printOptions: ReceiptPrintSettingsStore.load().resolved(for: regularProfile), showsSamplePrintLink: false).padding() }
                        .navigationTitle("Regular Booth Preview")
                }
            }
            if !message.isEmpty { Section { Text(message) } }
        }
        .navigationTitle("Receipt & Footer").navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden).background(OperatorPalette.canvas)
        .environment(\.defaultMinListRowHeight, 52)

    }
    private var settingsForm: some View {
        Form {
            if !message.isEmpty { Section { Text(message).accessibilityIdentifier("regular-defaults-save-result") } }
            if let loadIssue {
                Section("Review saved settings") { Text(loadIssue).foregroundStyle(.orange) }
            }
            Section("Printing") {
                Text("Local, no-payment sessions. Changes apply to the next guest and do not change event settings.")
                Stepper("Default copies: \(settings.defaultCopies)", value: $settings.defaultCopies, in: 1...max(1, settings.maxCopies))
                Stepper("Maximum copies: \(settings.maxCopies)", value: $settings.maxCopies, in: 1...10)
                Toggle("Let guests choose additional copies", isOn: $settings.guestCopyChoice)
            }
            Section("Available formats") {
                ForEach(BoothFormat.allCases, id: \.rawValue) { format in
                    Toggle(format.displayName, isOn: Binding(get: { settings.formats.contains(format.rawValue) }, set: { enabled in
                        if enabled { settings.formats.append(format.rawValue) }
                        else { settings.formats.removeAll { $0 == format.rawValue } }
                    }))
                }
            }
            if settings.formats.contains(where: { BoothFormat(rawValue: $0) == nil }) {
                Section("Unrecognized saved formats") {
                    ForEach(settings.formats.filter { BoothFormat(rawValue: $0) == nil }, id: \.self) { raw in
                        Button("Remove unsupported format: \(raw)") { settings.formats.removeAll { $0 == raw } }
                    }
                }
            }
            Section("Receipt & Footer") {
                NavigationLink(value: OperatorWorkspaceRoute.regularFooter) {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Footer, text & branding")
                            Text("Gallery code, logo and receipt caption").font(.caption).foregroundStyle(OperatorPalette.secondaryText)
                        }
                    } icon: { Image(systemName: "doc.text.image") }
                }.accessibilityIdentifier("regular-footer-settings")
            }
            Section("Appearance & Gallery") {
                Picker("Gallery presentation", selection: $design.profile.galleryReceiptStyleOverride) {
                    Text("Use device default").tag(Optional<GalleryReceiptStyle>.none)
                    ForEach(GalleryReceiptStyle.allCases) { style in Text(style.title).tag(Optional(style)) }
                }
            }
            Section("Advanced") {
                NavigationLink("Device Footer & Gallery Defaults", value: OperatorWorkspaceRoute.branding)
                Text("Device defaults are shared. Use Receipt & Footer above for Regular Booth changes.")
                    .font(.footnote).foregroundStyle(OperatorPalette.secondaryText)
            }
        }.navigationTitle("Regular Booth Settings")
        .environment(\.defaultMinListRowHeight, 52)
        .scrollContentBackground(.hidden).background(OperatorPalette.canvas)
        .navigationBarTitleDisplayMode(.inline)
    }
    private func reloadDraft() {
        let latest = RegularBoothSettings.load()
        settings = workspace.snapshot.regularBoothDraft ?? latest
        let displayedProfile = settings.profile
        design.profile = displayedProfile
        design.personalizeReceipt = settings.profile.receiptHeader.mode == .customEventHeader
        var baseline = latest
        var profile = latest.profile
        profile.isEnabled = true; profile.customerScreenEnabled = false; profile.showEventTextBlock = false
        // The fallback studio profile has a generated date even though it prints no event date.
        // Reuse the displayed fallback so opening an untouched form isn't itself an edit.
        if baseline.receiptProfile == nil { profile.eventDate = displayedProfile.eventDate }
        baseline.receiptProfile = profile
        saved = baseline
    }
    private var saveBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack { saveStatus; Spacer(); saveButton }
            VStack(alignment: .leading, spacing: 8) { saveStatus; saveButton }
        }.padding(12).background(.bar)
    }
    private var saveStatus: some View {
        Text(workspace.persistenceError ?? (message.isEmpty ? (isDirty ? "Unsaved changes · kept as a draft" : "Regular Booth · next guest defaults") : message))
            .font(.footnote).foregroundStyle(OperatorPalette.secondaryText)
    }
    private var saveButton: some View {
        Button("Save Defaults", action: saveDefaults).buttonStyle(.borderedProminent)
            .frame(minHeight: 44).disabled(settings.formats.isEmpty)
            .accessibilityIdentifier("save-regular-defaults")
    }
    private func saveDefaults() {
        guard OperatorAccessPermit.shared.isAuthorized else { message = "Unlock Operator again before saving."; return }
        do {
            settings.receiptProfile = regularProfile
            try RegularBoothSettings.save(settings)
            saved = settings
            workspace.saveRegularBoothDraft(nil)
            loadIssue = nil
            message = workspace.persistenceError ?? "Saved for the next Regular Booth guest."
        } catch { message = error.localizedDescription }
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
