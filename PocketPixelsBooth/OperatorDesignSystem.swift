import SwiftUI

/// Shared presentation only. These tokens never decide admission or recovery policy.
enum OperatorPalette {
    static let canvas = MadeToKeepTheme.ColorPalette.paper
    static let ink = MadeToKeepTheme.ColorPalette.ink
    static let accent = MadeToKeepTheme.ColorPalette.burgundy
    static let secondaryText = MadeToKeepTheme.ColorPalette.secondaryText
    static let ready = Color(.sRGB, red: 0.15, green: 0.38, blue: 0.25, opacity: 1)
    static let warning = Color(.sRGB, red: 0.55, green: 0.31, blue: 0.08, opacity: 1)
    static let danger = Color(.sRGB, red: 0.64, green: 0.12, blue: 0.13, opacity: 1)
    static let surface = MadeToKeepTheme.ColorPalette.ivoryLight
    static let border = accent.opacity(0.14)
    static let selected = accent.opacity(0.08)
}


enum OperatorStyle {
    enum Space {
        static let small: CGFloat = 8
        static let row: CGFloat = 12
        static let card: CGFloat = 16
        static let page: CGFloat = 24
        static let section: CGFloat = 24
    }
    static let radius: CGFloat = 16
    static let touchTarget: CGFloat = 48
    static let contentWidth: CGFloat = 940
    enum TypeScale {
        static let title = Font.system(.title, design: .serif).weight(.medium)
        static let section = Font.system(.title3, design: .serif).weight(.semibold)
        static let card = Font.headline
        static let body = Font.body
        static let support = Font.callout
        static let metadata = Font.footnote
    }
}

/// Applied at every operator screen boundary, including independently presented sheets.
/// Native controls retain keyboard avoidance, VoiceOver and confirmation semantics.
private struct OperatorScreenStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .listStyle(.insetGrouped)
            .listSectionSpacing(OperatorStyle.Space.card)
            .scrollContentBackground(.hidden)
            .background(OperatorPalette.canvas)
            .environment(\.defaultMinListRowHeight, OperatorStyle.touchTarget)
            .environment(\.defaultMinListHeaderHeight, 40)
            .textCase(nil)
            .tint(OperatorPalette.accent)
            .controlSize(.large)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.light, for: .navigationBar)
            .toolbarBackground(OperatorPalette.surface, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .presentationBackground(OperatorPalette.canvas)
            .preferredColorScheme(.light)
    }
}

extension View {
    func operatorScreen() -> some View { modifier(OperatorScreenStyle()) }
    func operatorCard() -> some View {
        self.padding(OperatorStyle.Space.card)
            .background(OperatorPalette.surface, in: RoundedRectangle(cornerRadius: OperatorStyle.radius))
            .overlay { RoundedRectangle(cornerRadius: OperatorStyle.radius).stroke(OperatorPalette.border) }
    }
}

struct OperatorSectionHeading: View {
    let title: String
    var detail: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: OperatorStyle.Space.small) {
            Text(title).font(OperatorStyle.TypeScale.section).foregroundStyle(OperatorPalette.ink)
                .accessibilityAddTraits(.isHeader)
            if let detail { Text(detail).font(OperatorStyle.TypeScale.metadata).foregroundStyle(OperatorPalette.secondaryText) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Neutral is deliberately distinct from verified success and an actionable warning.
enum OperatorStatusTone {
    case neutral, verified, attention, critical
    var color: Color {
        switch self {
        case .neutral: OperatorPalette.secondaryText
        case .verified: OperatorPalette.ready
        case .attention: OperatorPalette.warning
        case .critical: OperatorPalette.danger
        }
    }
}

struct OperatorStatusLabel: View {
    let title: String
    let symbol: String
    var tone: OperatorStatusTone = .neutral
    var body: some View {
        Label(title, systemImage: symbol)
            .font(OperatorStyle.TypeScale.metadata.weight(.medium))
            .foregroundStyle(tone.color)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(tone.color.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
    }
}

struct OperatorStatePanel: View {
    let title: String
    let detail: String
    var symbol = "info.circle"
    var tone: OperatorStatusTone = .neutral
    var body: some View {
        HStack(alignment: .top, spacing: OperatorStyle.Space.row) {
            Image(systemName: symbol).foregroundStyle(tone.color).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: OperatorStyle.Space.small) {
                Text(title).font(OperatorStyle.TypeScale.card)
                Text(detail).font(OperatorStyle.TypeScale.support).foregroundStyle(OperatorPalette.secondaryText)
            }.fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading).operatorCard()
    }
}

struct OperatorNavigationCard: View {
    let title: String
    let detail: String
    let symbol: String
    var tone: OperatorStatusTone = .neutral
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: OperatorStyle.Space.row) {
                Image(systemName: symbol).font(.title3).foregroundStyle(tone.color)
                    .frame(width: 28).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(OperatorStyle.TypeScale.card).foregroundStyle(OperatorPalette.ink)
                    Text(detail).font(OperatorStyle.TypeScale.support).foregroundStyle(OperatorPalette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                    .foregroundStyle(OperatorPalette.secondaryText).accessibilityHidden(true)
            }.frame(maxWidth: .infinity, minHeight: OperatorStyle.touchTarget, alignment: .leading)
                .operatorCard().contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityHint("Open \(title)")
    }
}

/// Freshness describes evidence only; it never grants operational permission.
enum OperatorEvidence {
    static func monitoringDetail(lastAccepted: Date?, configured: Bool, now: Date = Date()) -> String {
        guard configured else { return "Not configured · open Monitoring to set up owner alerts" }
        guard let lastAccepted else { return "No accepted heartbeat this launch · Telegram delivery is not verified here" }
        let stale = now.timeIntervalSince(lastAccepted) > 10 * 60
        return "\(stale ? "Stale observation" : "Worker accepted heartbeat") at \(lastAccepted.formatted(date: .omitted, time: .shortened)). Telegram delivery is not verified here."
    }
}
