import SwiftUI

/// Shared staged controls: the workspace embeds these directly, and legacy design routes use
/// the same portrait editor. Collapsing a group never reconstructs the setup coordinator.
struct EventDesignEditorView: View {
    @ObservedObject var setup: SessionSetupCoordinator
    var inline = false
    var showsPreview = true
    private var defaults: RegularBoothSettings { setup.studioDefaultsForPresentation }

    var body: some View {
        Group {
            if inline { editor }
            else {
                VStack(spacing: 0) {
                    EventReceiptComposerPreview(profile: setup.effectiveProfile, printOptions: ReceiptPrintSettingsStore.load(), compact: true).padding(20)
                    Divider()
                    ScrollView { editor.padding(24) }.scrollDismissesKeyboard(.interactively)
                }.navigationTitle("Customize Receipt").navigationBarTitleDisplayMode(.inline)
            }
        }.tint(OperatorPalette.ink)
    }

    @ViewBuilder private var editor: some View {
        VStack(alignment: .leading, spacing: 16) {
            if inline && showsPreview { EventReceiptComposerPreview(profile: setup.effectiveProfile, printOptions: ReceiptPrintSettingsStore.load(), compact: true) }
            if let design = Binding($setup.design) {
                Divider()
                Text("Caption & Footer").font(.headline)
                TextField("Receipt footer caption (optional)", text: limited(design.profile.receiptDesign.editorialCaption, ReceiptEditorialCaption.inputLimit), axis: .vertical)
                    .lineLimit(2...3).accessibilityIdentifier("event-footer-caption")
                    .onChange(of: design.wrappedValue.profile.receiptDesign.editorialCaption) { _, _ in design.wrappedValue.profile.receiptExtrasEnabled = true }
                Button("Reset Caption to Studio") {
                    design.wrappedValue.profile.receiptDesign.editorialCaption = defaults.profile.receiptDesign.editorialCaption
                    design.wrappedValue.profile.receiptExtrasEnabled = true
                }.font(.callout).frame(minHeight: 44)
                EventGalleryPresentationControls(setup: setup)
                Divider()
                Text("Header & Logo").font(.headline)
                EventReceiptDesignPanel(design: design, isDirty: setup.designDirty, save: {}, discard: {},
                    editsLiveEvent: setup.editingLiveEvent, managesSaving: false, showsGalleryOptions: false,
                    studioProfile: defaults.profile)
                Divider()
                Text("Event Information").font(.headline)
                Toggle("Print event details below the footer", isOn: design.profile.showEventTextBlock)
                    .onChange(of: design.wrappedValue.profile.showEventTextBlock) { _, _ in design.wrappedValue.profile.receiptExtrasEnabled = true }
                if design.wrappedValue.profile.showEventTextBlock {
                    TextField("Subtitle / Host", text: limited(design.profile.subtitle, EventProfile.subtitleLimit))
                    Toggle("Show date", isOn: design.profile.includeEventDate)
                    if design.wrappedValue.profile.includeEventDate { DatePicker("Date", selection: design.profile.eventDate, displayedComponents: .date) }
                    TextField("Location", text: limited(design.profile.location, EventProfile.locationLimit))
                    TextField("Optional message", text: limited(design.profile.shortMessage, EventProfile.shortMessageLimit))
                }
                Divider()
                EventTypographySection(typography: design.profile.receiptDesign.typography)
                DisclosureGroup("Photo Pass") {
                    Text("Uses this event’s name and location. Guests add their name, note and signature.").font(.callout).padding(.top, 8)
                }
            }
        }.textFieldStyle(.roundedBorder)
    }
    private func limited(_ text: Binding<String>, _ limit: Int) -> Binding<String> {
        Binding(get: { text.wrappedValue }, set: { text.wrappedValue = String($0.prefix(limit)) })
    }
}

/// Nil legacy overrides resolve to the real device value. Editing writes an event value directly.
struct EventGalleryPresentationControls: View {
    @ObservedObject var setup: SessionSetupCoordinator
    var body: some View {
        if let design = Binding($setup.design) {
            LabeledContent("Footer Layout") {
            Picker("Footer Layout", selection: Binding(get: {
                design.wrappedValue.profile.receiptDesign.footerStyleOverride ?? ReceiptPrintSettingsStore.load().footerStyle
            }, set: { design.wrappedValue.profile.receiptDesign.footerStyleOverride = $0 })) {
                ForEach(ReceiptFooterStyle.allCases) { Text($0.displayName).tag($0) }
            }.labelsHidden().frame(minHeight: 44)
            }
            LabeledContent("Gallery Appearance") {
            Picker("Gallery Appearance", selection: Binding(get: {
                design.wrappedValue.profile.galleryReceiptStyleOverride ?? GalleryReceiptSettingsStore.load()
            }, set: { design.wrappedValue.profile.galleryReceiptStyleOverride = $0 })) {
                ForEach(GalleryReceiptStyle.allCases) { Text($0.title).tag($0) }
            }.labelsHidden().frame(minHeight: 44)
            }
            Button("Reset Gallery & Footer to Studio") {
                design.wrappedValue.profile.receiptDesign.footerStyleOverride = setup.studioDefaultsForPresentation.profile.receiptDesign.footerStyleOverride ?? ReceiptPrintSettingsStore.load().footerStyle
                design.wrappedValue.profile.galleryReceiptStyleOverride = setup.studioDefaultsForPresentation.profile.galleryReceiptStyleOverride ?? GalleryReceiptSettingsStore.load()
            }.font(.callout).frame(minHeight: 44)
        }
    }
}

struct EventDesignRouteView: View {
    @StateObject private var setup = SessionSetupCoordinator()
    var body: some View {
        Group {
            if setup.design != nil { EventDesignEditorView(setup: setup) }
            else { RegularBoothSettingsView() }
        }.onAppear { setup.reloadDesignFromStorage() }
    }
}
