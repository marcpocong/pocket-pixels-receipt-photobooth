//
//  EventTypographySectionView.swift
//  PocketPixelsBooth
//

import SwiftUI
import UIKit

/// Event Setup → Receipt Typography. Presets first; individual controls only for Custom.
struct EventTypographySection: View {
    @Binding var typography: EventTypographyConfiguration

    var body: some View {
        Section {
            Picker("Typography Style", selection: $typography.preset) {
                ForEach(EventTypographyPreset.allCases) { preset in
                    Text(preset.displayName).tag(preset)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityHint("Sets the fonts used for event details on printed receipts.")

            TypographySample(resolved: typography.resolved)

            if typography.preset == .custom {
                DisclosureGroup("Advanced Typography") {
                    advancedControls
                }
            }
        } header: {
            Text("Receipt Typography")
        } footer: {
            Text("\(typography.preset.summary) Sizes are preferences: long names and messages shrink or wrap so they always fit. Use the preview above to check the printed result.")
        }
    }

    @ViewBuilder
    private var advancedControls: some View {
        Group {
            Text("TITLE").font(.caption.bold()).foregroundStyle(.secondary)
            fontPicker("Title Font", selection: $typography.custom.titleFont)
            weightPicker("Title Weight", selection: $typography.custom.titleWeight)
            slider("Title Size", value: $typography.custom.titleSize, range: EventTypographyCustomStyle.titleSizeRange, step: 1, suffix: "pt")
            slider("Title Letter Spacing", value: $typography.custom.titleTracking, range: EventTypographyCustomStyle.trackingRange, step: 0.1, suffix: "")

            Text("DETAILS").font(.caption.bold()).foregroundStyle(.secondary)
            fontPicker("Details Font", selection: $typography.custom.detailsFont)
            weightPicker("Details Weight", selection: $typography.custom.detailsWeight)
            slider("Details Size", value: $typography.custom.detailsSize, range: EventTypographyCustomStyle.detailsSizeRange, step: 1, suffix: "pt")
            slider("Details Letter Spacing", value: $typography.custom.detailsTracking, range: EventTypographyCustomStyle.trackingRange, step: 0.1, suffix: "")

            Text("LAYOUT").font(.caption.bold()).foregroundStyle(.secondary)
            slider("Line Spacing", value: $typography.custom.lineSpacing, range: EventTypographyCustomStyle.lineSpacingRange, step: 0.5, suffix: "")
            Picker("Alignment", selection: $typography.custom.alignment) {
                ForEach(EventTextAlignment.allCases) { alignment in
                    Text(alignment.displayName).tag(alignment)
                }
            }
            .pickerStyle(.segmented)

            Button("Reset Custom Typography") { typography.custom = .default }
        }
        .padding(.vertical, 2)
    }

    private func fontPicker(_ title: String, selection: Binding<EventFontFamily>) -> some View {
        Picker(title, selection: selection) {
            ForEach(EventFontFamily.allCases) { family in
                Text(family.displayName)
                    .font(Font(EventFontLibrary.font(family: family, weight: .semibold, size: 17)))
                    .tag(family)
            }
        }
    }

    private func weightPicker(_ title: String, selection: Binding<EventFontWeight>) -> some View {
        Picker(title, selection: selection) {
            ForEach(EventFontWeight.allCases) { weight in
                Text(weight.displayName).tag(weight)
            }
        }
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, suffix: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: step < 1 ? "%.1f" : "%.0f", value.wrappedValue) + (suffix.isEmpty ? "" : " \(suffix)"))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: step)
                .accessibilityLabel(title)
        }
    }
}

/// A quick on-screen impression of the style. The Preview Event receipt is the authoritative view.
private struct TypographySample: View {
    let resolved: ResolvedEventTypography

    var body: some View {
        VStack(spacing: 4) {
            Text("A KEEPSAKE FROM")
                .font(font(resolved.eyebrow, scale: 1.2))
                .tracking(resolved.eyebrow.tracking)
            Text(transform("Mark & Anna", resolved.title))
                .font(font(resolved.title, scale: 1.1))
                .tracking(resolved.title.tracking)
            Text(transform("Our Wedding Day", resolved.subtitle))
                .font(font(resolved.subtitle, scale: 1.2))
            Text("SEP 7, 2026 • CEBU CITY")
                .font(font(resolved.metadata, scale: 1.2))
                .tracking(resolved.metadata.tracking)
        }
        .multilineTextAlignment(resolved.alignment.textAlignment)
        .frame(maxWidth: .infinity, alignment: resolved.alignment.frameAlignment)
        .foregroundStyle(.black)
        .padding(14)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).stroke(.secondary.opacity(0.25)) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Typography sample")
    }

    private func font(_ style: EventTextRoleStyle, scale: CGFloat) -> Font {
        Font(style.face.font(size: style.preferredSize * scale))
    }

    private func transform(_ text: String, _ style: EventTextRoleStyle) -> String {
        style.uppercased ? text.uppercased() : text
    }
}

private extension EventTextAlignment {
    var textAlignment: TextAlignment {
        switch self {
        case .left: .leading
        case .center: .center
        case .right: .trailing
        }
    }

    var frameAlignment: Alignment {
        switch self {
        case .left: .leading
        case .center: .center
        case .right: .trailing
        }
    }
}
