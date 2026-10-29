import SwiftUI

/// An isolated editing session. Save returns a value to Setup; abandoning never checkpoints edits.
struct ReceiptStudioView: View {
    @Binding var design: SavedEventDesign
    let profile: EventProfile
    var studioProfile: EventProfile? = nil
    var isRegularBooth = false
    var onSave: (() -> Void)? = nil
    var onCancel: (() -> Void)? = nil
    @State private var original: SavedEventDesign
    @State private var draft: SavedEventDesign
    @State private var history = ReceiptStudioHistory()
    @State private var artworkImport = ReceiptArtworkImportSession()
    @State private var saveConflicts: [String] = []
    @State private var showsConflict = false
    @State private var compactShowsPreview = false
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var section: EditingSection = .header
    @State private var focus: ReceiptPreviewFocus = .full
    @State private var target: CoBrandedHeaderTarget = .whole
    @State private var textTarget: ReceiptTextFocus = .all
    @FocusState private var textField: ReceiptTextFocus?
    @State private var previewSelection = ReceiptPreviewSelection()

    private enum EditingSection: String, CaseIterable, Identifiable {
        case header = "Header", footer = "Footer", text = "Text"
        var title: String { switch self { case .header: "Header & Logo"; case .footer: "Footer & QR"; case .text: "Text & Style" } }
        var id: Self { self }
    }

    init(design: Binding<SavedEventDesign>, profile: EventProfile, studioProfile: EventProfile? = nil,
         isRegularBooth: Bool = false, onSave: (() -> Void)? = nil, onCancel: (() -> Void)? = nil) {
        _design = design; self.profile = profile; self.studioProfile = studioProfile
        self.isRegularBooth = isRegularBooth; self.onSave = onSave; self.onCancel = onCancel
        _original = State(initialValue: design.wrappedValue)
        _draft = State(initialValue: design.wrappedValue)
    }

    private var editing: Binding<SavedEventDesign> {
        Binding(get: { draft }, set: { candidate in
            var value = candidate
            if value.profile.receiptDesign.editorialCaption != draft.profile.receiptDesign.editorialCaption
                || value.profile.showEventTextBlock != draft.profile.showEventTextBlock {
                value.profile.receiptExtrasEnabled = true
            }
            history.record(from: draft, to: value)
            draft = value
        })
    }
    private var previewProfile: EventProfile {
        if !isRegularBooth { return draft.appliedProfile() }
        var value = draft.profile
        value.isEnabled = true; value.customerScreenEnabled = false; value.showEventTextBlock = false
        value.receiptHeader.mode = draft.personalizeReceipt ? .customEventHeader : .pocketPixelsDefault
        return value
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 12) {
                if artworkImport.isImporting {
                    HStack {
                        ProgressView("Preparing logo… Save is available when it finishes.")
                        Button("Cancel Import") { artworkImport.cancelImport() }
                    }.accessibilityIdentifier("receipt-studio-importing")
                }
                if let error = artworkImport.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                Picker("Editing Section", selection: $section) {
                    ForEach(EditingSection.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).accessibilityIdentifier("receipt-studio-section")
                if ReceiptStudioLayout.usesColumns(width: geometry.size.width) {
                    HStack(alignment: .top, spacing: 10) {
                        preview(height: max(180, geometry.size.height - 245))
                            .frame(width: ReceiptStudioLayout.previewWidth(for: geometry.size.width, accessibility: typeSize.isAccessibilitySize))
                        Divider()
                        controls.frame(maxWidth: .infinity)
                    }
                } else {
                    // Split-screen / accessibility fallback is explicitly focused, never a tiny thumbnail.
                    Picker("Workspace", selection: $compactShowsPreview) {
                        Text("Receipt").tag(true); Text("Tools").tag(false)
                    }.pickerStyle(.segmented)
                    if compactShowsPreview { preview(height: max(180, geometry.size.height - 290)) }
                    else { controls }
                }
            }.padding(16)
        }
        .background(OperatorPalette.canvas)
        .navigationTitle("Receipt Studio").navigationBarTitleDisplayMode(.inline)
        .tint(OperatorPalette.ink).textFieldStyle(.roundedBorder)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { draft = history.undo(draft) } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                    .disabled(!history.canUndo || artworkImport.isImporting).accessibilityIdentifier("receipt-studio-undo")
                Button { draft = history.redo(draft) } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
                    .disabled(!history.canRedo || artworkImport.isImporting).accessibilityIdentifier("receipt-studio-redo")
                Button("Save") {
                    guard !artworkImport.isImporting else { return }
                    var latest = design
                    saveConflicts = artworkImport.save(draft, baseline: original, into: &latest)
                    guard saveConflicts.isEmpty else { showsConflict = true; return }
                    artworkImport.close()
                    design = latest; onSave?()
                }.disabled(design.id != draft.id || artworkImport.isImporting).accessibilityIdentifier("receipt-studio-done")
            }
            ToolbarItem(placement: .topBarLeading) {
                NavigationLink("Print Sample") { SamplePrintStudioView(previewProfile: previewProfile) }
                    .disabled(artworkImport.isImporting).accessibilityIdentifier("receipt-studio-print-sample")
            }
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { artworkImport.close(); onCancel?() }.accessibilityIdentifier("receipt-studio-cancel")
            }
        }
        .task(id: artworkImport.requestID) {
            await artworkImport.process { result in
                editing.wrappedValue.replaceLogo(identifier: result.identifier)
            }
        }
        .onDisappear { artworkImport.cancelImport() }
        .alert("Receipt changed elsewhere", isPresented: $showsConflict) {
            Button("Keep Editing", role: .cancel) { }
            Button("Reload Latest Receipt", role: .destructive) {
                original = design; draft = design; history = ReceiptStudioHistory()
            }
        } message: {
            Text("Nothing was saved. Conflicting adjustments: " + saveConflicts.joined(separator: ", ")
                 + ". Keep editing to undo your conflicting adjustments, or reload to discard this receipt draft and use the latest values.")
        }
        .onChange(of: section) { _, _ in history.endGroup() }
        .onChange(of: target) { _, _ in history.endGroup() }
        .onChange(of: textField) { _, value in if let value { textTarget = value }; history.endGroup() }
    }

    private func preview(height: CGFloat) -> some View {
        EventReceiptComposerPreview(profile: previewProfile, printOptions: ReceiptPrintSettingsStore.load(),
            showsSamplePrintLink: false, editorFocus: $focus, editorViewportHeight: height,
            headerTarget: Binding(get: { target }, set: { target = $0; section = .header }),
            showsHeaderSelection: section == .header, textTarget: textTarget, selection: $previewSelection,
            stableEditorViewport: true)
            .accessibilityElement(children: .contain).accessibilityIdentifier("receipt-studio-preview-pane")
    }

    private var controls: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(section.title).font(.title3.weight(.semibold))
                switch section {
                case .header:
                    EventReceiptDesignPanel(design: editing, studioProfile: studioProfile, headerTarget: $target, isRegularBooth: isRegularBooth, artworkImport: artworkImport)
                case .footer: footerControls
                case .text: textControls
                }
                if design.id != draft.id { Text("Setup changed to another design. Cancel and reopen Receipt Studio.").foregroundStyle(.orange) }
                Text(isRegularBooth ? "Save returns edits to Settings. Save Defaults applies them to future guests."
                     : "Save returns edits to Setup. Save Design keeps them for future use.")
                    .font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 24)
        }.scrollDismissesKeyboard(.interactively).accessibilityIdentifier("receipt-studio-controls")
    }

    private var footerControls: some View {
        VStack(alignment: .leading, spacing: 16) {
            EventPrintedFooterControls(profile: editing.profile, studioProfile: studioProfile)
            Text("Footer Caption").font(.headline)
            TextField("Receipt footer caption (optional)", text: limited(editing.profile.receiptDesign.editorialCaption, ReceiptEditorialCaption.inputLimit), axis: .vertical)
                .lineLimit(2...3).accessibilityIdentifier("event-footer-caption")
                .focused($textField, equals: .caption)
            if let studioProfile {
                Button("Reset Caption to Studio") {
                    editing.wrappedValue.profile.receiptDesign.editorialCaption = studioProfile.receiptDesign.editorialCaption
                    editing.wrappedValue.profile.receiptExtrasEnabled = true
                }.frame(minHeight: 44)
            }
        }
    }

    private var textControls: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("Text to Inspect", selection: $textTarget) {
                ForEach(ReceiptTextFocus.allCases) { Text($0.rawValue).tag($0) }
            }.accessibilityIdentifier("receipt-text-target")
            EventTypographySection(typography: editing.profile.receiptDesign.typography, showsSample: false, onInspectText: { textTarget = $0 })
            if !isRegularBooth {
            Divider()
            Toggle("Print event details below the footer", isOn: editing.profile.showEventTextBlock)
            if draft.profile.showEventTextBlock {
                Text("The event name comes from Event Setup.").font(.caption).foregroundStyle(.secondary)
                TextField("Subtitle / Host", text: limited(editing.profile.subtitle, EventProfile.subtitleLimit)).focused($textField, equals: .subtitle)
                Toggle("Show date", isOn: editing.profile.includeEventDate)
                if draft.profile.includeEventDate { DatePicker("Date", selection: editing.profile.eventDate, displayedComponents: .date) }
                TextField("Location", text: limited(editing.profile.location, EventProfile.locationLimit)).focused($textField, equals: .metadata)
                TextField("Optional message", text: limited(editing.profile.shortMessage, EventProfile.shortMessageLimit), axis: .vertical).focused($textField, equals: .message)
            }
            }
        }
    }

    private func limited(_ text: Binding<String>, _ limit: Int) -> Binding<String> {
        Binding(get: { text.wrappedValue }, set: { text.wrappedValue = String($0.prefix(limit)) })
    }
}

struct EventPrintedFooterControls: View {
    @Binding var profile: EventProfile
    var studioProfile: EventProfile? = nil
    var body: some View {
        Menu {
            Picker("Printed Footer Layout", selection: Binding(get: {
                profile.receiptDesign.footerStyleOverride ?? ReceiptPrintSettingsStore.load().footerStyle
            }, set: { profile.receiptDesign.footerStyleOverride = $0 })) {
                ForEach(ReceiptFooterStyle.allCases) { Text($0.displayName).tag($0) }
            }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text("Printed Footer Layout").font(.headline)
                HStack {
                    Text((profile.receiptDesign.footerStyleOverride ?? ReceiptPrintSettingsStore.load().footerStyle).displayName)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.up.chevron.down")
                }
            }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        }.accessibilityIdentifier("receipt-footer-layout")
        if (profile.receiptDesign.footerStyleOverride ?? ReceiptPrintSettingsStore.load().footerStyle) == .decorativeBarcodeOnly {
            Label("Decorative barcode only: no printed gallery access. The iPad gallery QR remains available.", systemImage: "exclamationmark.triangle")
                .font(.footnote).foregroundStyle(.orange)
        }
        if let studioProfile {
            Button("Reset Footer to Studio") {
                profile.receiptDesign.footerStyleOverride = studioProfile.receiptDesign.footerStyleOverride ?? ReceiptPrintSettingsStore.load().footerStyle
            }.frame(minHeight: 44)
        }
    }
}
