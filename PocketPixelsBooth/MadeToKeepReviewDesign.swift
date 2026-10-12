//
//  MadeToKeepReviewDesign.swift
//  PocketPixelsBooth
//
//  Editorial photo-review design system, established by the Duo review screen and shared by
//  every format (Solo, Duo, Grid, Strip, Grid 6, Photo Pass):
//
//  - `MadeToKeepReviewTypography`   Fonts (and their measured line heights) for review copy.
//  - `MadeToKeepReviewHeader`       Lockup, format descriptor, rule, heading and subtitle.
//  - `MadeToKeepPhotoSectionLabel`  "— PHOTO 1 —" numbered section label.
//  - `MadeToKeepPrintedPhotoFrame`  Ivory photographic-print mount around a captured photo.
//  - `MadeToKeepReviewButtonStyle`  Primary (CONTINUE) and compact (RETAKE) outlined capsules.
//  - `MadeToKeepReviewTextButtonStyle` Borderless tracked CANCEL action.
//  - `MadeToKeepReviewAtmosphere`   Faint curved lines and botanical shadow behind content.
//  - `MadeToKeepReviewFormatSpec`   Per-format crop aspects and candidate arrangements.
//  - `MadeToKeepPhotoReviewLayout`  Geometry budget that picks an arrangement and sizes photos.
//  - `MadeToKeepPhotoReviewView`    The review screen itself, driven by a format spec.
//

import SwiftUI
import UIKit

// MARK: - Typography

/// Review-screen type scale. Each face exposes a `UIFont` so layout metrics can budget exact
/// line heights instead of guessing, which keeps the Duo screen fitting without clipping.
enum MadeToKeepReviewTypography {
    static let eyebrowSize: CGFloat = 14
    static let eyebrowTracking: CGFloat = 0.26
    static let headingSize: CGFloat = 70
    /// Native Bodoni italic is wider than the reference heading; condense it like the wordmark.
    static let headingHorizontalScale: CGFloat = 0.88
    static let subtitleSize: CGFloat = 18
    static let sectionLabelSize: CGFloat = 12.5
    static let sectionLabelTracking: CGFloat = 0.32
    static let compactButtonSize: CGFloat = 15
    static let compactButtonTracking: CGFloat = 0.22
    static let primaryButtonSize: CGFloat = 26
    static let primaryButtonTracking: CGFloat = 0.2
    static let textButtonSize: CGFloat = 15
    static let textButtonTracking: CGFloat = 0.24

    /// Delicate humanist sans used for supporting copy and tracked labels.
    static func sansUIFont(size: CGFloat, weight: UIFont.Weight = .regular) -> UIFont {
        let name = switch weight {
        case .medium, .semibold: "AvenirNext-Medium"
        case .bold, .heavy, .black: "AvenirNext-DemiBold"
        default: "AvenirNext-Regular"
        }
        return UIFont(name: name, size: size) ?? .systemFont(ofSize: size, weight: weight)
    }

    static func sans(size: CGFloat, weight: UIFont.Weight = .regular) -> Font {
        Font(sansUIFont(size: size, weight: weight))
    }

    static func lineHeight(_ font: UIFont) -> CGFloat {
        ceil(font.lineHeight)
    }

    static var eyebrowLineHeight: CGFloat { lineHeight(sansUIFont(size: eyebrowSize, weight: .medium)) }
    static var headingLineHeight: CGFloat { lineHeight(MadeToKeepTheme.Typography.italicSerifUIFont(size: headingSize)) }
    static var subtitleLineHeight: CGFloat { lineHeight(sansUIFont(size: subtitleSize)) }
    static var sectionLabelLineHeight: CGFloat { lineHeight(sansUIFont(size: sectionLabelSize, weight: .medium)) }
    static var lockupHeight: CGFloat {
        let wordmark = MadeToKeepWordmarkMetrics(size: MadeToKeepLockup.Scale.review.wordmarkSize).lineHeight
        let studios = lineHeight(UIFont.systemFont(ofSize: MadeToKeepLockup.Scale.review.studiosSize, weight: .light))
        return wordmark + studios + MadeToKeepLockup.Scale.review.spacing
    }
}

// MARK: - Header

/// Centered editorial review header: lockup, tracked format descriptor, short rule, a large
/// condensed italic heading and a quiet supporting sentence.
struct MadeToKeepReviewHeader: View {
    let eyebrow: String
    var title: String = "Love these?"
    let subtitle: String
    var gapScale: CGFloat = 1

    var body: some View {
        let type = MadeToKeepReviewTypography.self
        VStack(spacing: 0) {
            MadeToKeepLockup(scale: .review)
                .frame(height: type.lockupHeight)

            MadeToKeepTrackedText(
                text: eyebrow,
                font: type.sans(size: type.eyebrowSize, weight: .medium),
                size: type.eyebrowSize,
                tracking: type.eyebrowTracking
            )
            .lineLimit(1)
            .frame(height: type.eyebrowLineHeight)
            .padding(.top, MadeToKeepReviewSpacing.lockupToEyebrow * gapScale)
            .accessibilityAddTraits(.isHeader)

            MadeToKeepRule(width: MadeToKeepReviewSpacing.ruleWidth, thickness: MadeToKeepReviewSpacing.ruleThickness)
                .padding(.top, MadeToKeepReviewSpacing.eyebrowToRule * gapScale)

            Text(title)
                .font(MadeToKeepTheme.Typography.italicSerif(size: type.headingSize))
                .tracking(type.headingSize * -0.02)
                .foregroundStyle(MadeToKeepTheme.ColorPalette.burgundy)
                .lineLimit(1)
                .fixedSize()
                .scaleEffect(x: type.headingHorizontalScale, y: 1)
                .frame(height: type.headingLineHeight)
                .padding(.top, MadeToKeepReviewSpacing.ruleToHeading * gapScale)
                .accessibilityAddTraits(.isHeader)

            Text(subtitle)
                .font(type.sans(size: type.subtitleSize))
                .foregroundStyle(MadeToKeepTheme.ColorPalette.mutedInk)
                .multilineTextAlignment(.center)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(height: type.subtitleLineHeight)
                .padding(.top, MadeToKeepReviewSpacing.headingToSubtitle * gapScale)
        }
    }

    /// Height of the header at a given gap scale; matches the explicit frames above.
    static func height(gapScale: CGFloat) -> CGFloat {
        let type = MadeToKeepReviewTypography.self
        let spacing = MadeToKeepReviewSpacing.self
        let fixed = type.lockupHeight + type.eyebrowLineHeight + spacing.ruleThickness + type.headingLineHeight + type.subtitleLineHeight
        let gaps = spacing.lockupToEyebrow + spacing.eyebrowToRule + spacing.ruleToHeading + spacing.headingToSubtitle
        return fixed + gaps * gapScale
    }
}

// MARK: - Section label

/// Small tracked "PHOTO 1" label with hairline rules. Centered sections use rules on both
/// sides; side-rail cells use a single rule pointing toward their photo.
struct MadeToKeepPhotoSectionLabel: View {
    enum Rules {
        case both
        case leading
        case trailing
    }

    static let maximumRuleWidth: CGFloat = 48
    static let ruleSpacing: CGFloat = 18

    let text: String
    var ruleWidth: CGFloat = maximumRuleWidth
    var rules: Rules = .both

    /// Rule width that keeps the label inside `width`; zero when there is no room for rules.
    static func ruleWidth(fitting width: CGFloat, text: String) -> CGFloat {
        let available = (width - textWidth(text)) / 2 - ruleSpacing
        return available < 20 ? 0 : min(maximumRuleWidth, available)
    }

    static func textWidth(_ text: String) -> CGFloat {
        let type = MadeToKeepReviewTypography.self
        let kern = type.sectionLabelSize * type.sectionLabelTracking
        let attributed = NSAttributedString(
            string: text.uppercased(),
            attributes: [.font: type.sansUIFont(size: type.sectionLabelSize, weight: .medium), .kern: kern]
        )
        return ceil(attributed.size().width + kern)
    }

    var body: some View {
        let type = MadeToKeepReviewTypography.self
        HStack(spacing: ruleWidth > 0 ? Self.ruleSpacing : 0) {
            if rules != .trailing, ruleWidth > 0 { rule }
            // Trailing tracking would push the word off-center; pad the leading edge to match.
            Text(text.uppercased())
                .font(type.sans(size: type.sectionLabelSize, weight: .medium))
                .tracking(type.sectionLabelSize * type.sectionLabelTracking)
                .foregroundStyle(MadeToKeepTheme.ColorPalette.mutedInk)
                .padding(.leading, type.sectionLabelSize * type.sectionLabelTracking)
                .lineLimit(1)
                .fixedSize()
            if rules != .leading, ruleWidth > 0 { rule }
        }
        .frame(height: type.sectionLabelLineHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }

    private var rule: some View {
        MadeToKeepRule(width: ruleWidth, thickness: MadeToKeepTheme.Stroke.hairline, color: MadeToKeepTheme.ColorPalette.taupe.opacity(0.8))
    }
}

// MARK: - Printed photo frame

/// Physical-print mount: warm ivory border, a faint hairline edge and a soft two-layer paper
/// shadow. The content is sized by the caller and never has effects drawn over it.
struct MadeToKeepPrintedPhotoFrame<Content: View>: View {
    let photoSize: CGSize
    var border: CGFloat = MadeToKeepPrintedPhotoFrameMetrics.border
    @ViewBuilder let content: Content

    var body: some View {
        content
            .frame(width: photoSize.width, height: photoSize.height)
            .clipped()
            .padding(border)
            .background(MadeToKeepTheme.ColorPalette.ivoryLight)
            .overlay {
                Rectangle()
                    .strokeBorder(MadeToKeepTheme.ColorPalette.hairline.opacity(0.9), lineWidth: MadeToKeepTheme.Stroke.hairline)
            }
            // Contact shadow plus a wide, low-opacity lift: reads as paper, not a floating card.
            .shadow(color: MadeToKeepTheme.ColorPalette.shadowTint.opacity(0.10), radius: 1, x: 0, y: 1)
            .shadow(color: MadeToKeepTheme.ColorPalette.shadowTint.opacity(0.13), radius: 10, x: 0, y: 5)
    }
}

enum MadeToKeepPrintedPhotoFrameMetrics {
    static let border: CGFloat = 8

    static func frameSize(photoSize: CGSize, border: CGFloat = border) -> CGSize {
        CGSize(width: photoSize.width + border * 2, height: photoSize.height + border * 2)
    }
}

// MARK: - Buttons

/// Outlined review capsules. `.primary` is the wide serif CONTINUE; `.compact` is the tracked
/// sans RETAKE / RETAKE ALL. Both keep at least a 44-point touch target.
struct MadeToKeepReviewButtonStyle: ButtonStyle {
    enum Kind {
        case primary
        case compact
    }

    var kind: Kind = .compact
    var height: CGFloat? = nil
    var horizontalPadding: CGFloat? = nil
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let type = MadeToKeepReviewTypography.self
        let burgundy = MadeToKeepTheme.ColorPalette.burgundy
        configuration.label
            .font(kind == .primary
                ? MadeToKeepTheme.Typography.serif(size: type.primaryButtonSize)
                : type.sans(size: type.compactButtonSize, weight: .medium))
            .tracking(kind == .primary
                ? type.primaryButtonSize * type.primaryButtonTracking
                : type.compactButtonSize * type.compactButtonTracking)
            .textCase(.uppercase)
            .lineLimit(1)
            .foregroundStyle(isEnabled ? burgundy : MadeToKeepTheme.ColorPalette.mutedInk.opacity(0.55))
            .padding(.horizontal, horizontalPadding ?? (kind == .primary ? 34 : 30))
            .frame(maxWidth: kind == .primary ? .infinity : nil)
            .frame(height: max(44, height ?? MadeToKeepReviewSpacing.compactButtonHeight))
            .background(
                Capsule()
                    .fill(MadeToKeepTheme.ColorPalette.ivoryLight.opacity(configuration.isPressed ? 0.95 : 0.55))
            )
            .overlay {
                Capsule()
                    .strokeBorder(
                        isEnabled
                            ? burgundy.opacity(kind == .primary ? 0.92 : 0.42)
                            : MadeToKeepTheme.ColorPalette.hairline,
                        lineWidth: kind == .primary ? MadeToKeepTheme.Stroke.outline : MadeToKeepTheme.Stroke.hairline
                    )
            }
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.8 : 1)
            .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? MadeToKeepTheme.Motion.pressedScale : 1))
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Borderless tracked uppercase action, used for CANCEL.
struct MadeToKeepReviewTextButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        let type = MadeToKeepReviewTypography.self
        configuration.label
            .font(type.sans(size: type.textButtonSize, weight: .medium))
            .tracking(type.textButtonSize * type.textButtonTracking)
            .textCase(.uppercase)
            .foregroundStyle(MadeToKeepTheme.ColorPalette.mutedInk)
            .padding(.horizontal, 24)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

// MARK: - Spacing

/// Review vertical rhythm, in points at full scale. Gaps compress together (never the photo
/// frames' aspect) when the viewport is short.
enum MadeToKeepReviewSpacing {
    static let topInset: CGFloat = 14
    static let bottomInset: CGFloat = 8
    static let horizontalInset: CGFloat = 36

    static let lockupToEyebrow: CGFloat = 18
    static let eyebrowToRule: CGFloat = 10
    static let ruleToHeading: CGFloat = 6
    static let headingToSubtitle: CGFloat = 0
    static let headerToFirstSection: CGFloat = 22

    static let labelToFrame: CGFloat = 10
    static let frameToRetake: CGFloat = 12
    static let betweenSections: CGFloat = 20
    static let sectionsToActions: CGFloat = 24

    static let primaryToSecondary: CGFloat = 14
    static let secondaryToCancel: CGFloat = 6

    static let ruleWidth: CGFloat = 50
    static let ruleThickness: CGFloat = 1.2

    static let compactButtonHeight: CGFloat = 44
    static let retakeAllHeight: CGFloat = 46
    static let primaryButtonHeight: CGFloat = 62
    static let cancelHeight: CGFloat = 44

    /// Side-rail cells: label and RETAKE beside the photo, used by the denser formats.
    static let railWidth: CGFloat = 128
    static let railGap: CGFloat = 16
    static let railLabelToButton: CGFloat = 12
    static let railButtonPadding: CGFloat = 22
}

// MARK: - Atmosphere

/// Barely-there decorative layer: a few long curved hairlines and a soft botanical shadow at
/// the lower-left edge. Drawn behind content so it can never sit on top of a photograph.
struct MadeToKeepReviewAtmosphere: View {
    var body: some View {
        Canvas { context, size in
            let w = size.width
            let h = size.height
            let line = GraphicsContext.Shading.color(MadeToKeepTheme.ColorPalette.burgundy.opacity(0.07))
            var arcs = Path()
            arcs.move(to: CGPoint(x: -w * 0.05, y: h * 0.36))
            arcs.addQuadCurve(to: CGPoint(x: w * 0.30, y: -h * 0.02), control: CGPoint(x: w * 0.08, y: h * 0.10))
            arcs.move(to: CGPoint(x: w * 0.70, y: -h * 0.02))
            arcs.addQuadCurve(to: CGPoint(x: w * 1.05, y: h * 0.42), control: CGPoint(x: w * 0.98, y: h * 0.08))
            arcs.move(to: CGPoint(x: w * 0.78, y: h * 1.02))
            arcs.addQuadCurve(to: CGPoint(x: w * 1.04, y: h * 0.62), control: CGPoint(x: w * 0.86, y: h * 0.74))
            arcs.move(to: CGPoint(x: -w * 0.04, y: h * 0.62))
            arcs.addQuadCurve(to: CGPoint(x: w * 0.30, y: h * 1.02), control: CGPoint(x: w * 0.20, y: h * 0.78))
            context.stroke(arcs, with: line, lineWidth: 0.8)

            // Out-of-focus grass/leaf shadow, as if cast by a stem just off the page.
            var botanical = context
            botanical.addFilter(.blur(radius: 7))
            let shade = GraphicsContext.Shading.color(MadeToKeepTheme.ColorPalette.shadowTint.opacity(0.22))
            let origin = CGPoint(x: -w * 0.02, y: h * 1.01)
            for (index, angle) in [-62.0, -48.0, -36.0, -24.0, -12.0].enumerated() {
                let length = h * (0.15 + 0.025 * Double(index % 3))
                let radians = angle * .pi / 180
                let tip = CGPoint(x: origin.x + cos(radians) * length, y: origin.y + sin(radians) * length)
                let bend = CGPoint(x: origin.x + cos(radians + 0.25) * length * 0.55, y: origin.y + sin(radians + 0.25) * length * 0.55)
                var stem = Path()
                stem.move(to: origin)
                stem.addQuadCurve(to: tip, control: bend)
                botanical.stroke(stem, with: shade, style: StrokeStyle(lineWidth: 5, lineCap: .round))
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}


// MARK: - Format specs

/// One way to arrange a format's review photos. Rows hold photo indices in reading order.
struct MadeToKeepReviewArrangement: Equatable {
    enum CellStyle: Equatable {
        /// Label above, framed photo, RETAKE below: the Duo standard.
        case stacked
        /// Label and RETAKE in a rail beside the photo. Two-cell rows mirror their rails
        /// outward so the photos sit together like the printed grid; single cells keep the
        /// photo centered with a balancing gap opposite the rail.
        case rail
    }

    let rows: [[Int]]
    let cellStyle: CellStyle
    let columnGap: CGFloat
    let rowGap: CGFloat

    static func stacked(_ rows: [[Int]], columnGap: CGFloat = 28, rowGap: CGFloat = MadeToKeepReviewSpacing.betweenSections) -> Self {
        Self(rows: rows, cellStyle: .stacked, columnGap: columnGap, rowGap: rowGap)
    }

    static func rail(_ rows: [[Int]], columnGap: CGFloat = 16, rowGap: CGFloat = 16) -> Self {
        Self(rows: rows, cellStyle: .rail, columnGap: columnGap, rowGap: rowGap)
    }
}

/// Per-format review description: the crop aspect of every photo (matching what the receipt
/// prints) and the arrangements the review may choose between for each orientation.
struct MadeToKeepReviewFormatSpec {
    let aspectRatios: [CGFloat]
    let portraitArrangements: [MadeToKeepReviewArrangement]
    let landscapeArrangements: [MadeToKeepReviewArrangement]
    var maximumPhotoHeight: CGFloat = 440
    var minimumPhotoHeight: CGFloat = 120

    var photoCount: Int { aspectRatios.count }

    static func spec(for format: BoothFormat) -> Self {
        let portrait: CGFloat = 3.0 / 4.0
        let landscape = ReceiptComposer.landscapePresentationAspectRatio
        switch format {
        case .solo:
            return Self(
                aspectRatios: [portrait],
                portraitArrangements: [.stacked([[0]])],
                landscapeArrangements: [.stacked([[0]]), .rail([[0]])],
                maximumPhotoHeight: 560,
                minimumPhotoHeight: 160
            )
        case .duo:
            return Self(
                aspectRatios: [landscape, landscape],
                portraitArrangements: [.stacked([[0], [1]])],
                landscapeArrangements: [.stacked([[0, 1]], columnGap: 40), .rail([[0, 1]], columnGap: 40)],
                minimumPhotoHeight: 150
            )
        case .grid:
            // Printed as a 2×2 grid; wide windows reflow into one numbered row.
            return Self(
                aspectRatios: Array(repeating: portrait, count: 4),
                portraitArrangements: [.stacked([[0, 1], [2, 3]]), .rail([[0, 1], [2, 3]])],
                landscapeArrangements: [.stacked([[0, 1, 2, 3]], columnGap: 24), .rail([[0, 1], [2, 3]])]
            )
        case .strip:
            // Printed as one column of three landscape frames.
            return Self(
                aspectRatios: Array(repeating: landscape, count: 3),
                portraitArrangements: [.rail([[0], [1], [2]]), .stacked([[0], [1], [2]])],
                landscapeArrangements: [.stacked([[0, 1, 2]], columnGap: 32), .rail([[0], [1], [2]])]
            )
        case .gridSix:
            // Printed as a 2×3 grid.
            return Self(
                aspectRatios: Array(repeating: portrait, count: 6),
                portraitArrangements: [.rail([[0, 1], [2, 3], [4, 5]]), .stacked([[0, 1], [2, 3], [4, 5]])],
                landscapeArrangements: [
                    .stacked([[0, 1, 2, 3, 4, 5]], columnGap: 16),
                    .stacked([[0, 1, 2], [3, 4, 5]], columnGap: 24),
                    .rail([[0, 1], [2, 3], [4, 5]])
                ]
            )
        case .passport:
            // Photo Pass: both photos are approved upright, side by side at equal heights. The hero
            // prints a quarter turn on the sideways upper card, exactly as framed here.
            return Self(
                aspectRatios: PassportPhotoRole.allCases.map {
                    PhotoPresentationGeometry.resolve(format: .passport, photoIndex: $0.rawValue).aspectRatio
                },
                portraitArrangements: [.stacked([[0, 1]], columnGap: 32)],
                landscapeArrangements: [.stacked([[0, 1]], columnGap: 40)],
                minimumPhotoHeight: 150
            )
        }
    }
}

// MARK: - Layout budget

/// Sizes review photos from the real viewport. Everything except the photos has a known height
/// (explicit frames on every text row), so the remaining space goes to the photos; every
/// photo in an arrangement shares one height and keeps its own crop aspect. Each candidate
/// arrangement for the orientation is measured and the one with the most photo area that fits
/// without scrolling wins. If none fits even with compressed gaps, `requiresScrolling` is set
/// instead of clipping controls.
struct MadeToKeepPhotoReviewLayout: Equatable {
    static let minimumGapScale: CGFloat = 0.5

    let arrangement: MadeToKeepReviewArrangement
    let aspectRatios: [CGFloat]
    let photoHeight: CGFloat
    let gapScale: CGFloat
    let contentHeight: CGFloat
    let requiresScrolling: Bool

    func photoSize(at index: Int) -> CGSize {
        let aspect = aspectRatios.indices.contains(index) ? aspectRatios[index] : 1
        return CGSize(width: (photoHeight * aspect).rounded(.down), height: photoHeight)
    }

    func frameSize(at index: Int) -> CGSize {
        MadeToKeepPrintedPhotoFrameMetrics.frameSize(photoSize: photoSize(at: index))
    }

    var totalPhotoArea: CGFloat {
        aspectRatios.indices.reduce(0) { total, index in
            let size = photoSize(at: index)
            return total + size.width * size.height
        }
    }

    init(available: CGSize, spec: MadeToKeepReviewFormatSpec) {
        let isWide = available.width > available.height * 1.15
        let candidates = isWide ? spec.landscapeArrangements : spec.portraitArrangements
        let results = candidates.map { Self(available: available, spec: spec, arrangement: $0) }
        let fitting = results.filter { !$0.requiresScrolling }
        if let best = fitting.max(by: { $0.totalPhotoArea < $1.totalPhotoArea }) ?? results.max(by: { $0.photoHeight < $1.photoHeight }) {
            self = best
        } else {
            self.init(available: available, spec: spec, arrangement: .stacked([Array(0..<spec.photoCount)]))
        }
    }

    init(available: CGSize, spec: MadeToKeepReviewFormatSpec, arrangement: MadeToKeepReviewArrangement) {
        let spacing = MadeToKeepReviewSpacing.self
        let border = MadeToKeepPrintedPhotoFrameMetrics.border
        let height = max(1, available.height - spacing.topInset - spacing.bottomInset)
        let width = max(1, available.width - spacing.horizontalInset * 2)
        let rows = CGFloat(max(1, arrangement.rows.count))
        let isRail = arrangement.cellStyle == .rail

        let cellChrome = isRail ? 0 : MadeToKeepReviewTypography.sectionLabelLineHeight + spacing.compactButtonHeight
        let cellGaps = isRail ? 0 : spacing.labelToFrame + spacing.frameToRetake
        let actions = spacing.primaryButtonHeight + spacing.retakeAllHeight + spacing.cancelHeight
        let fixed = MadeToKeepReviewHeader.height(gapScale: 0) + rows * (cellChrome + border * 2) + actions

        let headerGaps = MadeToKeepReviewHeader.height(gapScale: 1) - MadeToKeepReviewHeader.height(gapScale: 0)
        let gaps = headerGaps + spacing.headerToFirstSection + rows * cellGaps + (rows - 1) * arrangement.rowGap
            + spacing.sectionsToActions + spacing.primaryToSecondary + spacing.secondaryToCancel

        // Widest-row constraint: every photo in a row shares the height, so width / Σaspect.
        let railWidth = isRail ? 2 * (spacing.railWidth + spacing.railGap) : 0
        let widthLimitedHeight = arrangement.rows.map { row -> CGFloat in
            let count = CGFloat(row.count)
            let aspects = row.reduce(CGFloat(0)) { $0 + (spec.aspectRatios.indices.contains($1) ? spec.aspectRatios[$1] : 1) }
            let usable = width - (count - 1) * arrangement.columnGap - count * border * 2 - railWidth
            return max(1, usable / max(0.1, aspects))
        }.min() ?? 1
        let ceiling = min(widthLimitedHeight, spec.maximumPhotoHeight)

        // A rail must fit beside its photo.
        let railContent = MadeToKeepReviewTypography.sectionLabelLineHeight + spacing.railLabelToButton + spacing.compactButtonHeight
        let minimum = min(ceiling, max(spec.minimumPhotoHeight, isRail ? railContent - border * 2 : 0))

        func budgetedHeight(gapScale: CGFloat) -> CGFloat {
            (height - fixed - gaps * gapScale) / rows
        }

        // Photographs get the first claim on compressible space. Solve their largest useful
        // height at the compact editorial rhythm, then give any surplus back to the gaps.
        let compactBudget = budgetedHeight(gapScale: Self.minimumGapScale)
        var photoHeight = min(ceiling, max(minimum, compactBudget))
        let scale = min(1, max(Self.minimumGapScale, (height - fixed - photoHeight * rows) / max(1, gaps)))

        photoHeight = photoHeight.rounded(.down)
        self.arrangement = arrangement
        self.aspectRatios = spec.aspectRatios
        self.photoHeight = photoHeight
        gapScale = scale
        contentHeight = fixed + gaps * scale + photoHeight * rows
        requiresScrolling = contentHeight > height + 0.5
    }
}

// MARK: - Review screen

/// Editorial photo review for every format: header, numbered print-framed photos with
/// individual retakes, then CONTINUE / RETAKE ALL / CANCEL. Behavior comes from the caller.
struct MadeToKeepPhotoReviewView: View {
    struct Photo {
        /// Already cropped to the format's presentation aspect; `nil` shows a placeholder.
        let image: UIImage?
        /// Changes when a photo is retaken so the swap animates.
        let identifier: String
        let label: String
        let accessibilityLabel: String
        let retakeAccessibilityLabel: String
        let canRetake: Bool
    }

    let spec: MadeToKeepReviewFormatSpec
    let eyebrow: String
    var title: String = "Love these?"
    let subtitle: String
    var continueTitle: String = "Continue"
    let photos: [Photo]
    let canContinue: Bool
    let canRetakeAll: Bool
    let motionActive: Bool
    let onRetake: (Int) -> Void
    let onContinue: () -> Void
    let onRetakeAll: () -> Void
    let onCancel: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let layout = MadeToKeepPhotoReviewLayout(available: proxy.size, spec: spec)
            ScrollView(.vertical) {
                content(layout: layout)
                    .padding(.top, MadeToKeepReviewSpacing.topInset)
                    .padding(.bottom, MadeToKeepReviewSpacing.bottomInset)
                    .padding(.horizontal, MadeToKeepReviewSpacing.horizontalInset)
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .scrollDisabled(!layout.requiresScrolling)
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(layout.requiresScrolling ? .automatic : .hidden)
        }
        .background { MadeToKeepReviewAtmosphere() }
    }

    private func content(layout: MadeToKeepPhotoReviewLayout) -> some View {
        let spacing = MadeToKeepReviewSpacing.self
        let gap = layout.gapScale
        let arrangement = layout.arrangement
        let widestFrame = spec.aspectRatios.indices.map { layout.frameSize(at: $0).width }.max() ?? 0
        return VStack(spacing: 0) {
            MadeToKeepReviewHeader(eyebrow: eyebrow, title: title, subtitle: subtitle, gapScale: gap)
                .entrance(index: 0, active: motionActive, reduceMotion: reduceMotion)

            VStack(spacing: arrangement.rowGap * gap) {
                ForEach(Array(arrangement.rows.enumerated()), id: \.offset) { _, row in
                    // One rule width per row (the narrowest cell's), so labels match side by side.
                    // Inset so neighbouring cells' rules never run into each other.
                    let ruleWidth = row.map {
                        MadeToKeepPhotoSectionLabel.ruleWidth(fitting: layout.frameSize(at: $0).width - 24, text: label(at: $0))
                    }.min() ?? 0
                    HStack(alignment: .top, spacing: arrangement.columnGap) {
                        ForEach(Array(row.enumerated()), id: \.element) { position, index in
                            cell(index: index, position: position, rowCount: row.count, ruleWidth: ruleWidth, layout: layout)
                                .entrance(index: index + 1, active: motionActive, reduceMotion: reduceMotion)
                        }
                    }
                }
            }
            .padding(.top, spacing.headerToFirstSection * gap)

            actions(continueWidth: min(max(widestFrame * 1.4, 360), 520), gapScale: gap)
                .padding(.top, spacing.sectionsToActions * gap)
                .entrance(index: spec.photoCount + 1, active: motionActive, reduceMotion: reduceMotion)
        }
    }

    @ViewBuilder
    private func cell(index: Int, position: Int, rowCount: Int, ruleWidth: CGFloat, layout: MadeToKeepPhotoReviewLayout) -> some View {
        let spacing = MadeToKeepReviewSpacing.self
        switch layout.arrangement.cellStyle {
        case .stacked:
            VStack(spacing: 0) {
                MadeToKeepPhotoSectionLabel(text: label(at: index), ruleWidth: ruleWidth)
                framedPhoto(index: index, layout: layout)
                    .padding(.top, spacing.labelToFrame * layout.gapScale)
                retakeButton(index: index)
                    .padding(.top, spacing.frameToRetake * layout.gapScale)
            }
        case .rail:
            // The first cell of a two-cell row carries its rail on the outside (leading) edge.
            let railLeads = rowCount == 2 && position == 0
            HStack(spacing: spacing.railGap) {
                if railLeads {
                    rail(index: index, leading: true)
                } else if rowCount == 1 {
                    Color.clear.frame(width: spacing.railWidth, height: 1)
                }
                framedPhoto(index: index, layout: layout)
                if !railLeads {
                    rail(index: index, leading: false)
                }
            }
        }
    }

    private func rail(index: Int, leading: Bool) -> some View {
        let spacing = MadeToKeepReviewSpacing.self
        let text = label(at: index)
        // Single rule: whatever the rail has left after the label, up to a short accent.
        let room = spacing.railWidth - MadeToKeepPhotoSectionLabel.textWidth(text) - MadeToKeepPhotoSectionLabel.ruleSpacing
        let ruleWidth = room < 12 ? 0 : min(32, room)
        return VStack(alignment: leading ? .trailing : .leading, spacing: spacing.railLabelToButton) {
            // The rule points toward the photo.
            MadeToKeepPhotoSectionLabel(text: text, ruleWidth: ruleWidth, rules: leading ? .trailing : .leading)
            retakeButton(index: index, horizontalPadding: spacing.railButtonPadding)
        }
        .frame(width: spacing.railWidth, alignment: leading ? .trailing : .leading)
    }

    private func framedPhoto(index: Int, layout: MadeToKeepPhotoReviewLayout) -> some View {
        let photo = photos.indices.contains(index) ? photos[index] : nil
        let size = layout.photoSize(at: index)
        return MadeToKeepPrintedPhotoFrame(photoSize: size) {
            ZStack {
                MadeToKeepTheme.ColorPalette.ivoryShade
                if let image = photo?.image {
                    // Already cropped to the receipt's presentation aspect; fill never distorts.
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: size.width, height: size.height)
                        .id(photo?.identifier)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.975)))
                } else {
                    Text("Missing")
                        .font(MadeToKeepReviewTypography.sans(size: 18, weight: .medium))
                        .foregroundStyle(MadeToKeepTheme.ColorPalette.secondaryText)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(photo?.accessibilityLabel ?? "Photo \(index + 1)")
        .accessibilityAddTraits(.isImage)
        .animation(MadeToKeepTheme.Motion.standardAnimation, value: photo?.identifier)
    }

    private func retakeButton(index: Int, horizontalPadding: CGFloat? = nil) -> some View {
        let photo = photos.indices.contains(index) ? photos[index] : nil
        return Button("Retake") {
            onRetake(index)
        }
        .buttonStyle(MadeToKeepReviewButtonStyle(kind: .compact, horizontalPadding: horizontalPadding))
        .disabled(!(photo?.canRetake ?? false))
        .accessibilityLabel(photo?.retakeAccessibilityLabel ?? "Retake photo \(index + 1)")
    }

    private func label(at index: Int) -> String {
        photos.indices.contains(index) ? photos[index].label : "Photo \(index + 1)"
    }

    private func actions(continueWidth: CGFloat, gapScale: CGFloat) -> some View {
        let spacing = MadeToKeepReviewSpacing.self
        return VStack(spacing: 0) {
            Button(continueTitle, action: onContinue)
                .buttonStyle(MadeToKeepReviewButtonStyle(kind: .primary, height: spacing.primaryButtonHeight))
                .frame(width: continueWidth)
                .disabled(!canContinue)

            Button("Retake All", action: onRetakeAll)
                .buttonStyle(MadeToKeepReviewButtonStyle(kind: .compact, height: spacing.retakeAllHeight))
                .disabled(!canRetakeAll)
                .padding(.top, spacing.primaryToSecondary * gapScale)

            Button("Cancel", action: onCancel)
                .buttonStyle(MadeToKeepReviewTextButtonStyle())
                .frame(height: spacing.cancelHeight)
                .padding(.top, spacing.secondaryToCancel * gapScale)
        }
    }
}

private extension View {
    /// Staggered review entrance matching the booth's existing review motion tokens.
    func entrance(index: Int, active: Bool, reduceMotion: Bool) -> some View {
        opacity(active ? 1 : 0)
            .offset(y: reduceMotion ? 0 : (active ? 0 : 8))
            .animation(
                (reduceMotion ? Animation.easeOut(duration: MadeToKeepTheme.Motion.quick) : MadeToKeepTheme.Motion.entranceAnimation)
                    .delay(Double(index) * MadeToKeepTheme.Motion.stagger),
                value: active
            )
    }
}

#Preview("Grid 6 Review") {
    MadeToKeepPhotoReviewView(
        spec: .spec(for: .gridSix),
        eyebrow: BoothFormat.gridSix.reviewSummary,
        subtitle: "Retake any photo, or continue when you're ready.",
        photos: (0..<6).map {
            .init(image: nil, identifier: "\($0)", label: "Photo \($0 + 1)", accessibilityLabel: "Photo \($0 + 1)", retakeAccessibilityLabel: "Retake photo \($0 + 1)", canRetake: true)
        },
        canContinue: true,
        canRetakeAll: true,
        motionActive: true,
        onRetake: { _ in },
        onContinue: { },
        onRetakeAll: { },
        onCancel: { }
    )
    .background { MadeToKeepPaperBackground() }
}
