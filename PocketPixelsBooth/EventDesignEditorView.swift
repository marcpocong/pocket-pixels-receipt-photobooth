import SwiftUI

/// The same staged receipt editor is used by new, saved and live events.
struct EventDesignEditorView: View {
    @ObservedObject var setup: SessionSetupCoordinator
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var previewOnly = false
    private var defaults: RegularBoothSettings { setup.studioDefaultsForPresentation }

    var body: some View {
        GeometryReader { geometry in
            if geometry.size.width >= 900 && !typeSize.isAccessibilitySize {
                HStack(alignment: .top, spacing: 0) {
                    controls
                    Divider()
                    ScrollView { preview.padding(20) }.frame(width: 390)
                }
            } else {
                VStack(spacing: 0) {
                    Picker("Receipt editor", selection: $previewOnly) {
                        Text("Edit Receipt").tag(false)
                        Text("Live Preview").tag(true)
                    }.pickerStyle(.segmented).padding()
                    if previewOnly { ScrollView { preview.padding() } }
                    else { controls }
                }
            }
        }
        .navigationTitle("Customize Receipt")
        .navigationBarTitleDisplayMode(.inline)
        .background(OperatorPalette.canvas)
        .tint(OperatorPalette.ink)
    }

    @ViewBuilder private var controls: some View {
        Form {
            if let design = Binding($setup.design) {
                Section {
                    Text("\(design.wrappedValue.displayName) · Custom for this event").font(.headline)
                    Text(setup.editingLiveEvent ? "Apply to Next Sessions in the event workspace when ready." : "Edits save locally. Review & Start applies them to future guests.").font(.footnote)
                }
                Section("Caption & Footer") {
                    TextField("Receipt footer caption (optional)", text: limited(design.profile.receiptDesign.editorialCaption, ReceiptEditorialCaption.inputLimit), axis: .vertical)
                        .lineLimit(2...3).accessibilityIdentifier("event-footer-caption")
                        .onChange(of: design.wrappedValue.profile.receiptDesign.editorialCaption) { _, _ in design.wrappedValue.profile.receiptExtrasEnabled = true }
                    Button("Use Studio Default Footer Caption") {
                        design.wrappedValue.profile.receiptDesign.editorialCaption = defaults.profile.receiptDesign.editorialCaption
                        design.wrappedValue.profile.receiptExtrasEnabled = true
                    }
                    Text(design.wrappedValue.profile.receiptDesign.editorialCaption == defaults.profile.receiptDesign.editorialCaption ? "Studio default caption copied for this event" : "Custom event caption").font(.caption)
                    Picker("Footer Layout", selection: design.profile.receiptDesign.footerStyleOverride) {
                        Text("Use Studio Default Footer").tag(Optional<ReceiptFooterStyle>.none)
                        ForEach(ReceiptFooterStyle.allCases) { Text($0.displayName).tag(Optional($0)) }
                    }
                    Picker("Gallery Receipt Appearance", selection: design.profile.galleryReceiptStyleOverride) {
                        Text("Use Studio Default Gallery Settings").tag(Optional<GalleryReceiptStyle>.none)
                        ForEach(GalleryReceiptStyle.allCases) { Text($0.title).tag(Optional($0)) }
                    }
                    Text("Caption prints below the footer. Default footer and gallery choices inherit the device settings; custom choices affect only this event.").font(.footnote)
                }
                Section("Header & Logo") {
                    Button("Use Studio Default Logo") {
                        design.wrappedValue.profile.receiptHeader = defaults.profile.receiptHeader
                        design.wrappedValue.personalizeReceipt = defaults.profile.isEnabled
                    }
                    Text(design.wrappedValue.profile.receiptHeader == defaults.profile.receiptHeader ? "Studio default logo copied for this event" : "Custom event logo").font(.caption)
                    EventReceiptDesignPanel(design: design, isDirty: setup.designDirty, save: {}, discard: {}, editsLiveEvent: setup.editingLiveEvent, managesSaving: false, showsGalleryOptions: false)
                }
                Section("Event Information") {
                    Toggle("Print event details below the footer", isOn: design.profile.showEventTextBlock)
                        .onChange(of: design.wrappedValue.profile.showEventTextBlock) { _, _ in design.wrappedValue.profile.receiptExtrasEnabled = true }
                    if design.wrappedValue.profile.showEventTextBlock {
                        TextField("Subtitle / Host", text: limited(design.profile.subtitle, EventProfile.subtitleLimit))
                        Toggle("Show date", isOn: design.profile.includeEventDate)
                        if design.wrappedValue.profile.includeEventDate {
                            DatePicker("Date", selection: design.profile.eventDate, displayedComponents: .date)
                        }
                        TextField("Location", text: limited(design.profile.location, EventProfile.locationLimit))
                        TextField("Optional message", text: limited(design.profile.shortMessage, EventProfile.shortMessageLimit))
                    }
                }
                EventTypographySection(typography: design.profile.receiptDesign.typography)
                Section("Advanced Design · Photo Pass") {
                    Text("Photo Pass uses this event's name and location. Guests add their name, note and signature.").font(.callout)
                }
                Section {
                    if typeSize.isAccessibilitySize { preview }
                    else { Text("Use Live Preview to inspect the staged receipt, or rotate to landscape for controls beside the preview.").font(.footnote) }
                }
            } else {
                Section { Text("Create or choose an event in the event workspace.") }
            }
        }
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Live Receipt Preview").font(.headline)
            EventReceiptComposerPreview(profile: setup.effectiveProfile, printOptions: ReceiptPrintSettingsStore.load())
        }
    }
    private func limited(_ text: Binding<String>, _ limit: Int) -> Binding<String> {
        Binding(get: { text.wrappedValue }, set: { text.wrappedValue = String($0.prefix(limit)) })
    }
}

/// Existing design routes use the same editor. Studio defaults are available without an event.
struct EventDesignRouteView: View {
    @StateObject private var setup = SessionSetupCoordinator()
    var body: some View {
        Group {
            if setup.design != nil { EventDesignEditorView(setup: setup) }
            else { RegularBoothSettingsView() }
        }
        .onAppear { setup.reloadDesignFromStorage() }
    }
}
