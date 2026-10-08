//
//  KeepsakeFormatSelectionView.swift
//  PocketPixelsBooth
//
//  "Choose Your Keepsake" format-selection screen: editorial heading, a 3 × 2 grid of
//  printed-paper cards and native miniature print illustrations. Presentation only — the
//  booth session decides what happens when a format is chosen.
//

import SwiftUI
import UIKit

// MARK: - Content

/// Customer-facing copy for one format card. The underlying `BoothFormat` (and its persisted
/// raw value) is unchanged; Photo Pass stays `.passport`.
struct KeepsakeFormatOption: Identifiable {
    let format: BoothFormat

    var id: String { format.id }
    var title: String { format.displayName.lowercased() }
    var countLabel: String { format.photoCountLabel.uppercased() }

    var caption: String {
        switch format {
        case .solo: "One portrait"
        case .duo: "Two moments"
        case .grid: "Four-photo collage"
        case .strip: "Classic photo strip"
        case .gridSix: "Six-photo collage"
        case .passport: "Two-photo event keepsake"
        }
    }

    var accessibilityLabel: String {
        switch format {
        case .passport:
            "Photo Pass, 2 photos. A two-photo event keepsake with your name, an optional note and your signature."
        default:
            "\(format.displayName), \(format.photoCountLabel). \(caption)"
        }
    }

    /// Reference ordering: Solo, Duo, Grid on the first row; Strip, Grid 6, Photo Pass below.
    static let referenceOrder: [BoothFormat] = [.solo, .duo, .grid, .strip, .gridSix, .passport]

    static var all: [KeepsakeFormatOption] {
        referenceOrder.map(KeepsakeFormatOption.init)
    }
}

// MARK: - Layout

/// Geometry for the screen, derived from the 11-inch portrait reference (834 × 1194 pt, a
/// 716 pt wide card grid). Everything scales from one factor so other window sizes keep the
/// same composition; if the scaled content is still taller than the window it scrolls.
struct KeepsakeSelectionLayout {
    static let referenceGridWidth: CGFloat = 716
    static let referenceSafeHeight: CGFloat = 1150
    static let referenceCardSize = CGSize(width: 228, height: 332)
    /// Logo row through the end of the subtitle, plus the gap above the cards.
    static let referenceHeaderHeight: CGFloat = 247

    let scale: CGFloat
    let gridWidth: CGFloat
    let columnGap: CGFloat
    let rowGap: CGFloat
    let cardSize: CGSize
    let topInset: CGFloat
    let bottomInset: CGFloat

    init(container: CGSize) {
        let width = max(1, container.width.isFinite ? container.width : 1)
        let height = max(1, container.height.isFinite ? container.height : 1)
        let margin = max(24, width * 0.07)
        let widthScale = (width - margin * 2) / Self.referenceGridWidth
        let heightScale = height / Self.referenceSafeHeight
        scale = min(max(min(widthScale, heightScale), 0.6), 1.3)

        gridWidth = Self.referenceGridWidth * scale
        columnGap = 19 * scale
        rowGap = 22 * scale
        let cardWidth = (gridWidth - columnGap * 2) / 3
        cardSize = CGSize(width: cardWidth, height: cardWidth * Self.referenceCardSize.height / Self.referenceCardSize.width)

        let contentHeight = Self.referenceHeaderHeight * scale + cardSize.height * 2 + rowGap
        let leftover = max(0, height - contentHeight)
        // The reference sits high on the page: roughly 30% of the spare height above.
        topInset = max(16 * scale, leftover * 0.3)
        bottomInset = max(16 * scale, leftover - topInset)
    }
}

// MARK: - Screen

struct KeepsakeFormatSelectionView: View {
    let options: [KeepsakeFormatOption]
    /// Format that was just tapped; shows the selected treatment until the camera takes over.
    let chosenFormat: BoothFormat?
    let motionActive: Bool
    let onSelect: (BoothFormat) -> Void
    let onBack: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let layout = KeepsakeSelectionLayout(container: proxy.size)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    KeepsakeSelectionHeader(scale: layout.scale, width: layout.gridWidth, onBack: onBack)
                        .padding(.bottom, 32 * layout.scale)

                    grid(layout: layout)
                }
                .frame(width: layout.gridWidth)
                .padding(.top, layout.topInset)
                .padding(.bottom, layout.bottomInset)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(.hidden)
        }
        .background { KeepsakeSelectionAtmosphere() }
    }

    private func grid(layout: KeepsakeSelectionLayout) -> some View {
        let columns = Array(repeating: GridItem(.fixed(layout.cardSize.width), spacing: layout.columnGap), count: 3)
        return LazyVGrid(columns: columns, spacing: layout.rowGap) {
            ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
                Button {
                    onSelect(option.format)
                } label: {
                    KeepsakeFormatCard(option: option, scale: layout.scale)
                        .frame(width: layout.cardSize.width, height: layout.cardSize.height)
                }
                .buttonStyle(KeepsakeCardButtonStyle(isChosen: chosenFormat == option.format))
                .allowsHitTesting(chosenFormat == nil)
                .accessibilityLabel(option.accessibilityLabel)
                .accessibilityAddTraits(chosenFormat == option.format ? .isSelected : [])
                .opacity(motionActive ? 1 : 0)
                .offset(y: reduceMotion || motionActive ? 0 : MadeToKeepTheme.Motion.entranceOffset)
                .animation(
                    (reduceMotion ? MadeToKeepTheme.Motion.quickAnimation : MadeToKeepTheme.Motion.entranceAnimation)
                        .delay(reduceMotion ? 0 : Double(index) * MadeToKeepTheme.Motion.stagger),
                    value: motionActive
                )
            }
        }
        .frame(width: layout.gridWidth)
    }
}

// MARK: - Header

/// Wordmark and Back pill, then the tracked step indicator, Bodoni headline and italic caption.
struct KeepsakeSelectionHeader: View {
    let scale: CGFloat
    let width: CGFloat
    let onBack: () -> Void

    private let burgundy = MadeToKeepTheme.ColorPalette.burgundy

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                KeepsakeLockup(scale: scale)
                Spacer(minLength: 16)
                Button {
                    onBack()
                } label: {
                    HStack(spacing: 12 * scale) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 15 * scale, weight: .medium))
                        Text("Back")
                            .font(MadeToKeepTheme.Typography.sans(size: 19 * scale, weight: .regular))
                            .lineLimit(1)
                    }
                    .fixedSize()
                    .padding(.horizontal, 26 * scale)
                    .frame(minWidth: 112 * scale, minHeight: max(44, 51 * scale))
                }
                .buttonStyle(KeepsakeBackButtonStyle())
                .accessibilityLabel("Back")
                .accessibilityHint("Cancels this session and returns to the start screen.")
            }
            .padding(.bottom, 34 * scale)

            HStack(spacing: 22 * scale) {
                MadeToKeepTrackedText(
                    text: "STEP 1 OF 1",
                    font: MadeToKeepTheme.Typography.sans(size: 11.5 * scale, weight: .regular),
                    size: 11.5 * scale,
                    tracking: 0.38
                )
                MadeToKeepRule(width: 54 * scale, thickness: 1, color: burgundy.opacity(0.7))
            }
            .padding(.leading, 7 * scale)
            .padding(.bottom, 2 * scale)

            Text(MadeToKeepBrand.formatHeadline)
                .font(MadeToKeepTheme.Typography.serif(size: headlineSize))
                .tracking(headlineSize * Self.headlineTracking)
                .foregroundStyle(burgundy)
                .lineLimit(1)
                .fixedSize()
                .padding(.leading, 5 * scale)
                .accessibilityAddTraits(.isHeader)

            Text("Pick how your little moment will print.")
                .font(MadeToKeepTheme.Typography.italicSerif(size: 30 * scale))
                .foregroundStyle(burgundy)
                .padding(.leading, 6 * scale)
                .padding(.top, -6 * scale)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: width, alignment: .leading)
    }

    private static let headlineTracking: CGFloat = -0.012
    private static let referenceHeadlineSize: CGFloat = 58

    /// 60 pt at the reference scale, reduced only when the measured line would not fit the grid.
    private var headlineSize: CGFloat {
        let preferred = Self.referenceHeadlineSize * scale
        let probe = MadeToKeepTheme.Typography.uprightSerifUIFont(size: 100)
        let measured = NSAttributedString(
            string: MadeToKeepBrand.formatHeadline,
            attributes: [.font: probe, .kern: 100 * Self.headlineTracking]
        ).size().width
        guard measured > 0 else { return preferred }
        let fitting = (width - 12 * scale) * 100 / measured
        return min(preferred, fitting)
    }
}

/// Larger header lockup than `MadeToKeepLockup.compact`, sized to the reference logo.
struct KeepsakeLockup: View {
    let scale: CGFloat

    var body: some View {
        VStack(spacing: -3 * scale) {
            MadeToKeepWordmark(size: 45 * scale)
            MadeToKeepTrackedText(
                text: MadeToKeepBrand.secondary,
                font: MadeToKeepTheme.Typography.sans(size: 13.5 * scale, weight: .light),
                size: 13.5 * scale,
                tracking: 0.5
            )
            .padding(.leading, 13.5 * scale * 0.5)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(MadeToKeepBrand.fullName)
    }
}

// MARK: - Card

struct KeepsakeFormatCard: View {
    let option: KeepsakeFormatOption
    let scale: CGFloat

    private let burgundy = MadeToKeepTheme.ColorPalette.burgundy

    var body: some View {
        VStack(spacing: 0) {
            KeepsakeFormatIllustration(format: option.format, scale: scale)
                .frame(maxWidth: .infinity)
                .frame(height: 176 * scale)
                .padding(.top, 20 * scale)

            // The separator sits at the same height on every card.
            Rectangle()
                .fill(burgundy.opacity(0.2))
                .frame(height: 1)
                .padding(.horizontal, 30 * scale)
                .padding(.top, 10 * scale)

            Text(option.title)
                .font(MadeToKeepTheme.Typography.italicSerif(size: 39 * scale))
                .foregroundStyle(burgundy)
                .lineLimit(1)
                .fixedSize()
                // Native italic serifs run wider than the reference lettering; condense like the wordmark.
                .scaleEffect(x: 0.88, y: 1)
                .padding(.top, 4 * scale)

            MadeToKeepTrackedText(
                text: option.countLabel,
                font: MadeToKeepTheme.Typography.sans(size: 12.5 * scale, weight: .medium),
                size: 12.5 * scale,
                tracking: 0.22
            )
            .padding(.top, 2 * scale)

            Text(option.caption)
                .font(MadeToKeepTheme.Typography.sans(size: 16.5 * scale, weight: .regular))
                .foregroundStyle(MadeToKeepTheme.ColorPalette.mutedInk.opacity(0.92))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10 * scale)
                .padding(.top, 8 * scale)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// Printed-paper card surface. `isChosen` (or a press) shows the blush selected treatment with
/// a stronger burgundy edge and a small check seal; the motion is a tiny press only.
struct KeepsakeCardButtonStyle: ButtonStyle {
    let isChosen: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let selected = isChosen || configuration.isPressed
        configuration.label
            .background { KeepsakeCardSurface(isSelected: selected) }
            .overlay(alignment: .topTrailing) {
                if selected {
                    KeepsakeCheckSeal()
                        .padding(11)
                        .transition(.opacity.combined(with: .scale(scale: reduceMotion ? 1 : 0.8)))
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: KeepsakeCardSurface.cornerRadius))
            .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 0.988 : 1))
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: selected)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct KeepsakeCardSurface: View {
    static let cornerRadius: CGFloat = 8
    let isSelected: Bool

    private let burgundy = MadeToKeepTheme.ColorPalette.burgundy

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
        shape
            .fill(
                LinearGradient(
                    colors: isSelected ? Self.blush : Self.paper,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay {
                // Faint top highlight so the stock reads as paper, not a flat fill.
                shape
                    .strokeBorder(Color.white.opacity(isSelected ? 0.35 : 0.7), lineWidth: 1)
                    .padding(1)
            }
            .overlay {
                shape.strokeBorder(burgundy.opacity(isSelected ? 0.78 : 0.16), lineWidth: isSelected ? 1.4 : 1)
            }
            .shadow(color: isSelected ? burgundy.opacity(0.16) : .clear, radius: 2.5, x: 0, y: 0)
            .shadow(
                color: (isSelected ? burgundy : MadeToKeepTheme.ColorPalette.shadowTint).opacity(isSelected ? 0.14 : 0.08),
                radius: isSelected ? 14 : 10,
                x: 0,
                y: isSelected ? 6 : 4
            )
    }

    private static let paper = [
        Color(.sRGB, red: 0xFD / 255, green: 0xFA / 255, blue: 0xF6 / 255, opacity: 0.94),
        Color(.sRGB, red: 0xF9 / 255, green: 0xF4 / 255, blue: 0xEE / 255, opacity: 0.9)
    ]

    private static let blush = [
        Color(.sRGB, red: 0xF4 / 255, green: 0xDB / 255, blue: 0xD8 / 255, opacity: 1),
        Color(.sRGB, red: 0xF8 / 255, green: 0xE8 / 255, blue: 0xE4 / 255, opacity: 1)
    ]
}

struct KeepsakeCheckSeal: View {
    var diameter: CGFloat = 26

    var body: some View {
        Circle()
            .fill(MadeToKeepTheme.ColorPalette.burgundy)
            .frame(width: diameter, height: diameter)
            .overlay {
                Image(systemName: "checkmark")
                    .font(.system(size: diameter * 0.42, weight: .semibold))
                    .foregroundStyle(MadeToKeepTheme.ColorPalette.ivoryLight)
            }
            .shadow(color: MadeToKeepTheme.ColorPalette.burgundy.opacity(0.25), radius: 3, x: 0, y: 1)
            .accessibilityHidden(true)
    }
}

/// Thin outlined Back capsule on translucent paper.
struct KeepsakeBackButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isEnabled ? MadeToKeepTheme.ColorPalette.burgundy : MadeToKeepTheme.ColorPalette.secondaryText)
            .background {
                Capsule()
                    .fill(MadeToKeepTheme.ColorPalette.ivoryLight.opacity(configuration.isPressed ? 0.95 : 0.55))
                    .shadow(color: MadeToKeepTheme.ColorPalette.shadowTint.opacity(0.08), radius: 6, x: 0, y: 2)
            }
            .overlay {
                Capsule()
                    .strokeBorder(MadeToKeepTheme.ColorPalette.burgundy.opacity(isEnabled ? 0.32 : 0.16), lineWidth: 1)
            }
            .contentShape(Capsule())
            .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 0.985 : 1))
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - Illustrations

/// Native miniature of each printed layout. Sizes are the reference point sizes at scale 1.
struct KeepsakeFormatIllustration: View {
    let format: BoothFormat
    let scale: CGFloat

    var body: some View {
        Group {
            switch format {
            case .solo:
                KeepsakePrint(size: size(84, 113), matte: 6.5 * scale)
            case .duo:
                tiles(columns: 1, rows: 2, tile: size(81, 72), gap: 4 * scale, matte: 5 * scale)
            case .grid:
                tiles(columns: 2, rows: 2, tile: size(57, 59), gap: 4 * scale, matte: 4 * scale)
            case .strip:
                KeepsakePhotoStrip(photoSize: size(48, 50), count: 3, matte: 5.5 * scale, gap: 5 * scale)
            case .gridSix:
                tiles(columns: 2, rows: 3, tile: size(48, 50), gap: 3.5 * scale, matte: 3.5 * scale)
            case .passport:
                KeepsakePhotoPassIllustration(width: 136 * scale)
            }
        }
        .accessibilityHidden(true)
    }

    private func size(_ width: CGFloat, _ height: CGFloat) -> CGSize {
        CGSize(width: width * scale, height: height * scale)
    }

    private func tiles(columns: Int, rows: Int, tile: CGSize, gap: CGFloat, matte: CGFloat) -> some View {
        VStack(spacing: gap) {
            ForEach(0..<rows, id: \.self) { _ in
                HStack(spacing: gap) {
                    ForEach(0..<columns, id: \.self) { _ in
                        KeepsakePrint(size: tile, matte: matte)
                    }
                }
            }
        }
    }
}

/// One printed photograph: off-white matte with a soft paper shadow around a landscape image.
struct KeepsakePrint: View {
    let size: CGSize
    let matte: CGFloat

    var body: some View {
        KeepsakePhotoMotif()
            .padding(matte)
            .frame(width: size.width, height: size.height)
            .background(KeepsakePrintStock())
    }
}

/// Classic photo strip: one cohesive sheet holding several stacked photographs.
struct KeepsakePhotoStrip: View {
    let photoSize: CGSize
    let count: Int
    let matte: CGFloat
    let gap: CGFloat

    var body: some View {
        VStack(spacing: gap) {
            ForEach(0..<count, id: \.self) { _ in
                KeepsakePhotoMotif()
                    .frame(width: photoSize.width, height: photoSize.height)
            }
        }
        .padding(matte)
        .background(KeepsakePrintStock())
    }
}

/// Matte print paper with a faint edge and two-layer shadow.
struct KeepsakePrintStock: View {
    var body: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [
                        Color(.sRGB, red: 0xFE / 255, green: 0xFD / 255, blue: 0xFB / 255, opacity: 1),
                        Color(.sRGB, red: 0xF8 / 255, green: 0xF4 / 255, blue: 0xEF / 255, opacity: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay { Rectangle().strokeBorder(MadeToKeepTheme.ColorPalette.hairline.opacity(0.7), lineWidth: 0.5) }
            .shadow(color: MadeToKeepTheme.ColorPalette.shadowTint.opacity(0.16), radius: 1, x: 0, y: 0.5)
            .shadow(color: MadeToKeepTheme.ColorPalette.shadowTint.opacity(0.12), radius: 5, x: 0, y: 3)
    }
}

/// Restrained placeholder photograph: warm sky, a soft sun and two layered hills.
struct KeepsakePhotoMotif: View {
    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            let sun = min(width, height) * 0.17

            ZStack(alignment: .topLeading) {
                LinearGradient(colors: [Self.skyTop, Self.skyBottom], startPoint: .top, endPoint: .bottom)
                Circle()
                    .fill(Self.sun)
                    .frame(width: sun, height: sun)
                    .position(x: width * 0.66, y: height * 0.32)
                KeepsakeHill(crest: 0.5, left: 0.66, right: 0.6, peakX: 0.34)
                    .fill(Self.backHill)
                KeepsakeHill(crest: 0.68, left: 0.86, right: 0.74, peakX: 0.6)
                    .fill(Self.frontHill)
            }
            .frame(width: width, height: height)
        }
        .clipped()
    }

    private static let skyTop = Color(.sRGB, red: 0xE6 / 255, green: 0xDD / 255, blue: 0xD3 / 255, opacity: 1)
    private static let skyBottom = Color(.sRGB, red: 0xDC / 255, green: 0xD1 / 255, blue: 0xC5 / 255, opacity: 1)
    private static let sun = Color(.sRGB, red: 0xC9 / 255, green: 0xBC / 255, blue: 0xAF / 255, opacity: 1)
    private static let backHill = Color(.sRGB, red: 0xCF / 255, green: 0xC2 / 255, blue: 0xB4 / 255, opacity: 1)
    private static let frontHill = Color(.sRGB, red: 0xC2 / 255, green: 0xB3 / 255, blue: 0xA4 / 255, opacity: 1)
}

/// Soft rolling hill; values are fractions of the rect height (crest, edges) and width (peak).
struct KeepsakeHill: Shape {
    let crest: CGFloat
    let left: CGFloat
    let right: CGFloat
    let peakX: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let h = rect.height
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + h * left))
        path.addCurve(
            to: CGPoint(x: rect.minX + w * peakX, y: rect.minY + h * crest),
            control1: CGPoint(x: rect.minX + w * peakX * 0.4, y: rect.minY + h * left),
            control2: CGPoint(x: rect.minX + w * peakX * 0.6, y: rect.minY + h * crest)
        )
        path.addCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY + h * right),
            control1: CGPoint(x: rect.minX + w * (peakX + (1 - peakX) * 0.45), y: rect.minY + h * crest),
            control2: CGPoint(x: rect.minX + w * (peakX + (1 - peakX) * 0.7), y: rect.minY + h * right)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// Two stacked Photo Pass tickets: a hero pass with vertical script, photo, star and
/// KEEPSAKE tab, and a details pass with a portrait, signature script and ruled fields.
struct KeepsakePhotoPassIllustration: View {
    let width: CGFloat

    private let ink = MadeToKeepTheme.ColorPalette.burgundy

    var body: some View {
        let heroHeight = width * 0.62
        let detailsHeight = width * 0.6
        VStack(spacing: width * 0.035) {
            heroTicket(width: width, height: heroHeight)
            detailsTicket(width: width, height: detailsHeight)
        }
        .padding(.top, width * 0.04)
    }

    private func heroTicket(width: CGFloat, height: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ticketStock(width: width, height: height)

            Text("Photo Pass")
                .font(.custom("SnellRoundhand-Bold", size: height * 0.165))
                .foregroundStyle(ink)
                .fixedSize()
                .rotationEffect(.degrees(-90))
                .position(x: width * 0.135, y: height * 0.5)

            // Dotted divider between the script column and the photo.
            Rectangle()
                .fill(.clear)
                .overlay {
                    Rectangle()
                        .stroke(ink.opacity(0.5), style: StrokeStyle(lineWidth: 0.9, lineCap: .round, dash: [0.1, height * 0.045]))
                }
                .frame(width: 0.5, height: height * 0.74)
                .position(x: width * 0.255, y: height * 0.5)

            KeepsakePhotoMotif()
                .overlay { Rectangle().strokeBorder(ink.opacity(0.25), lineWidth: 0.5) }
                .frame(width: width * 0.64, height: height * 0.66)
                .position(x: width * 0.6, y: height * 0.52)

            KeepsakeStar()
                .fill(ink)
                .frame(width: height * 0.15, height: height * 0.15)
                .position(x: width * 0.31, y: height * 0.81)

            MadeToKeepTrackedText(
                text: "KEEPSAKE",
                font: MadeToKeepTheme.Typography.sans(size: height * 0.105, weight: .medium),
                size: height * 0.105,
                tracking: 0.24,
                color: ink
            )
            .fixedSize()
            .padding(.horizontal, height * 0.12)
            .padding(.vertical, height * 0.035)
            .background(Capsule().fill(Color(.sRGB, red: 0xFE / 255, green: 0xFC / 255, blue: 0xFA / 255, opacity: 1)))
            .overlay(Capsule().strokeBorder(ink.opacity(0.85), lineWidth: 0.9))
            .position(x: width * 0.86, y: height * 0.04)
        }
        .frame(width: width, height: height)
    }

    private func detailsTicket(width: CGFloat, height: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ticketStock(width: width, height: height)

            KeepsakePhotoMotif()
                .overlay { Rectangle().strokeBorder(ink.opacity(0.25), lineWidth: 0.5) }
                .frame(width: width * 0.3, height: height * 0.5)
                .position(x: width * 0.26, y: height * 0.42)

            Text("Made to Keep")
                .font(.custom("SnellRoundhand-Bold", size: height * 0.105))
                .foregroundStyle(ink)
                .fixedSize()
                .position(x: width * 0.26, y: height * 0.8)

            VStack(spacing: height * 0.105) {
                ForEach(0..<5, id: \.self) { _ in
                    Rectangle()
                        .fill(ink.opacity(0.55))
                        .frame(height: 0.8)
                }
            }
            .frame(width: width * 0.44)
            .position(x: width * 0.7, y: height * 0.5)
        }
        .frame(width: width, height: height)
    }

    private func ticketStock(width: CGFloat, height: CGFloat) -> some View {
        let corner = height * 0.09
        return RoundedRectangle(cornerRadius: corner, style: .continuous)
            .fill(Color(.sRGB, red: 0xFE / 255, green: 0xFC / 255, blue: 0xFA / 255, opacity: 1))
            .overlay {
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(ink.opacity(0.85), lineWidth: 1)
            }
            .overlay {
                // Dotted inner border stands in for the printed star border at this size.
                RoundedRectangle(cornerRadius: corner * 0.6, style: .continuous)
                    .stroke(ink.opacity(0.6), style: StrokeStyle(lineWidth: 1.1, lineCap: .round, dash: [0.1, height * 0.042]))
                    .padding(height * 0.06)
            }
            .shadow(color: MadeToKeepTheme.ColorPalette.shadowTint.opacity(0.12), radius: 4, x: 0, y: 2)
            .frame(width: width, height: height)
    }
}

struct KeepsakeStar: Shape {
    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outer = min(rect.width, rect.height) / 2
        let inner = outer * 0.42
        var path = Path()
        for index in 0..<10 {
            let radius = index.isMultiple(of: 2) ? outer : inner
            let angle = Double(index) * .pi / 5 - .pi / 2
            let point = CGPoint(x: center.x + CGFloat(cos(angle)) * radius, y: center.y + CGFloat(sin(angle)) * radius)
            index == 0 ? path.move(to: point) : path.addLine(to: point)
        }
        path.closeSubpath()
        return path
    }
}

// MARK: - Atmosphere

/// Screen-specific layer drawn over the shared paper: hairline arcs, soft corner depth and a
/// faint botanical shadow at the lower left. Kept very quiet so it never competes with cards.
struct KeepsakeSelectionAtmosphere: View {
    var body: some View {
        Canvas { context, size in
            let w = size.width
            let h = size.height
            let ink = MadeToKeepTheme.ColorPalette.shadowTint

            // Soft depth in the upper-right and lower-left corners.
            for (center, radius, opacity) in [
                (CGPoint(x: w * 1.02, y: h * 0.08), w * 0.42, 0.10),
                (CGPoint(x: -w * 0.05, y: h * 0.95), w * 0.55, 0.12)
            ] {
                context.fill(
                    Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)),
                    with: .radialGradient(
                        Gradient(colors: [ink.opacity(opacity), ink.opacity(0)]),
                        center: center,
                        startRadius: 0,
                        endRadius: radius
                    )
                )
            }

            // Extremely fine curved lines.
            var arcs = Path()
            arcs.addArc(center: CGPoint(x: w * 1.32, y: h * 0.36), radius: w * 0.62, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
            arcs.addArc(center: CGPoint(x: w * 1.25, y: h * 0.42), radius: w * 0.58, startAngle: .degrees(195), endAngle: .degrees(250), clockwise: false)
            arcs.move(to: CGPoint(x: w * 0.25, y: 0))
            arcs.addQuadCurve(to: CGPoint(x: 0, y: h * 0.17), control: CGPoint(x: w * 0.08, y: h * 0.04))
            arcs.addArc(center: CGPoint(x: w * 1.1, y: h * 1.08), radius: w * 0.36, startAngle: .degrees(190), endAngle: .degrees(260), clockwise: false)
            context.stroke(arcs, with: .color(MadeToKeepTheme.ColorPalette.taupe.opacity(0.22)), lineWidth: 0.6)

            // Faint, blurred leaf shadows along a curved stem.
            var leaves = context
            leaves.addFilter(.blur(radius: 7))
            let stemBase = CGPoint(x: -w * 0.02, y: h * 0.98)
            for index in 0..<7 {
                let t = CGFloat(index) / 6
                let point = CGPoint(x: stemBase.x + w * 0.2 * t, y: stemBase.y - h * 0.26 * t)
                var leaf = leaves
                leaf.translateBy(x: point.x, y: point.y)
                leaf.rotate(by: .degrees(index.isMultiple(of: 2) ? -58 : 18))
                leaf.fill(
                    Path(ellipseIn: CGRect(x: 0, y: -w * 0.012, width: w * 0.11, height: w * 0.024)),
                    with: .color(ink.opacity(0.1))
                )
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

#Preview("Choose Your Keepsake") {
    KeepsakeFormatSelectionView(
        options: KeepsakeFormatOption.all,
        chosenFormat: .solo,
        motionActive: true,
        onSelect: { _ in },
        onBack: { }
    )
    .background { MadeToKeepPaperBackground() }
}
