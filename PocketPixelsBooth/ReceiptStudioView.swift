import SwiftUI

/// A viewport over the existing staged design. Saving and applying remain owned by the caller.
struct ReceiptStudioView: View {
    @Binding var design: SavedEventDesign
    let profile: EventProfile
    var studioProfile: EventProfile? = nil
    var isRegularBooth = false
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var section: EditingSection = .header
    @State private var focus: ReceiptPreviewFocus = .header
    @State private var target: CoBrandedHeaderTarget = .whole
    @State private var previewSelection = ReceiptPreviewSelection()

    private enum EditingSection: String, CaseIterable, Identifiable {
        case header = "Header & Logo", footer = "Footer & QR", text = "Text & Style"
        var id: Self { self }
    }

    var body: some View {
        GeometryReader { geometry in
            let sideBySide = geometry.size.width >= 720 && !typeSize.isAccessibilitySize
            let previewWidth = floor((geometry.size.width - 48) * 0.43)
            Group {
                if sideBySide {
                    HStack(alignment: .top, spacing: 20) {
                        preview(height: max(240, geometry.size.height - 220)).frame(width: previewWidth)
                        Divider()
                        controls.frame(maxWidth: .infinity)
                    }
                } else {
                    VStack(spacing: 12) {
                        preview(height: max(150, geometry.size.height * 0.27))
                        Divider()
                        controls
                    }
                }
            }.padding(sideBySide ? 16 : 12)
        }
        .background(OperatorPalette.canvas)
        .navigationTitle("Receipt Studio").navigationBarTitleDisplayMode(.inline)
        .tint(OperatorPalette.ink)
        .onChange(of: section) { _, value in
            // A manual focus choice stays in effect until the operator selects another section.
            focus = value == .header ? .header : .footer
        }
        .textFieldStyle(.roundedBorder)
    }

    private func preview(height: CGFloat) -> some View {
        EventReceiptComposerPreview(profile: profile, printOptions: ReceiptPrintSettingsStore.load(),
            showsSamplePrintLink: false, editorFocus: $focus, editorViewportHeight: height,
            headerTarget: section == .header ? $target : nil, selection: $previewSelection)
            .accessibilityElement(children: .contain).accessibilityIdentifier("receipt-studio-preview-pane")
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Menu {
                Picker("Editing Section", selection: $section) {
                    ForEach(EditingSection.allCases) { Text($0.rawValue).tag($0) }
                }
            } label: {
                HStack {
                    Text(section.rawValue).font(.headline)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                }.frame(maxWidth: .infinity, minHeight: 44)
            }.accessibilityLabel("Editing Section, " + section.rawValue)
                .accessibilityIdentifier("receipt-studio-section")
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(section.rawValue).font(.title3.weight(.semibold))
                    switch section {
                    case .header:
                        EventReceiptDesignPanel(design: $design, studioProfile: studioProfile, headerTarget: $target, isRegularBooth: isRegularBooth)
                    case .footer: footerControls
                    case .text: textControls
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 24)
            }.scrollDismissesKeyboard(.interactively).accessibilityIdentifier("receipt-studio-controls")
        }
    }

    private var footerControls: some View {
        VStack(alignment: .leading, spacing: 16) {
            EventPrintedFooterControls(profile: $design.profile, studioProfile: studioProfile)
            Text("Footer Caption").font(.headline)
            TextField("Receipt footer caption (optional)", text: limited($design.profile.receiptDesign.editorialCaption, ReceiptEditorialCaption.inputLimit), axis: .vertical)
                .lineLimit(2...3).accessibilityIdentifier("event-footer-caption")
                .onChange(of: design.profile.receiptDesign.editorialCaption) { _, _ in design.profile.receiptExtrasEnabled = true }
            if let studioProfile {
                Button("Reset Caption to Studio") {
                    design.profile.receiptDesign.editorialCaption = studioProfile.receiptDesign.editorialCaption
                    design.profile.receiptExtrasEnabled = true
                }.frame(minHeight: 44)
            }
        }
    }

    private var textControls: some View {
        VStack(alignment: .leading, spacing: 16) {
            EventTypographySection(typography: $design.profile.receiptDesign.typography, showsSample: false)
            if !isRegularBooth {
            Divider()
            Toggle("Print event details below the footer", isOn: $design.profile.showEventTextBlock)
                .onChange(of: design.profile.showEventTextBlock) { _, _ in design.profile.receiptExtrasEnabled = true }
            if design.profile.showEventTextBlock {
                Text("The event name comes from Event Setup.").font(.caption).foregroundStyle(.secondary)
                TextField("Subtitle / Host", text: limited($design.profile.subtitle, EventProfile.subtitleLimit))
                Toggle("Show date", isOn: $design.profile.includeEventDate)
                if design.profile.includeEventDate { DatePicker("Date", selection: $design.profile.eventDate, displayedComponents: .date) }
                TextField("Location", text: limited($design.profile.location, EventProfile.locationLimit))
                TextField("Optional message", text: limited($design.profile.shortMessage, EventProfile.shortMessageLimit), axis: .vertical)
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
