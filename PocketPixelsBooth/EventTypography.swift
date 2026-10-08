//
//  EventTypography.swift
//  PocketPixelsBooth
//
//  Event receipt typography: persisted, version-tolerant settings plus deterministic font
//  resolution. Only Apple fonts that ship with iPadOS are used (see Docs/Typography.md); no font
//  files are bundled and no operator-supplied fonts are loaded.
//

import Foundation
import UIKit

// MARK: - Persisted model

nonisolated enum EventTypographyPreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case classic
    case editorial
    case modern
    case bold
    case typewriter
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .classic: "Classic"
        case .editorial: "Editorial"
        case .modern: "Modern"
        case .bold: "Bold"
        case .typewriter: "Typewriter"
        case .custom: "Custom"
        }
    }

    var summary: String {
        switch self {
        case .classic: "The original Made to Keep serif keepsake."
        case .editorial: "Elegant book serif with generous spacing."
        case .modern: "Clean, contemporary sans-serif."
        case .bold: "Condensed heavy title for big statements."
        case .typewriter: "Vintage typewriter character."
        case .custom: "Choose fonts, sizes and spacing yourself."
        }
    }
}

/// Curated font families. Every case resolves to a font that ships with iPadOS, with a fixed
/// system fallback, so a profile always renders the same way on every booth iPad.
nonisolated enum EventFontFamily: String, Codable, CaseIterable, Identifiable, Sendable {
    case classicSerif
    case editorialSerif
    case modernSans
    case roundedSans
    case condensedSans
    case typewriter
    case monospaced

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .classicSerif: "Classic Serif"
        case .editorialSerif: "Editorial Serif"
        case .modernSans: "Modern Sans"
        case .roundedSans: "Rounded Sans"
        case .condensedSans: "Condensed"
        case .typewriter: "Typewriter"
        case .monospaced: "Mono"
        }
    }
}

nonisolated enum EventFontWeight: String, Codable, CaseIterable, Identifiable, Sendable {
    case regular
    case medium
    case semibold
    case bold
    case heavy

    var id: String { rawValue }
    var displayName: String { rawValue.capitalized }

    var uiFontWeight: UIFont.Weight {
        switch self {
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        case .heavy: .heavy
        }
    }
}

nonisolated enum EventTextAlignment: String, Codable, CaseIterable, Identifiable, Sendable {
    case left
    case center
    case right

    var id: String { rawValue }
    var displayName: String { rawValue.capitalized }

    var nsTextAlignment: NSTextAlignment {
        switch self {
        case .left: .left
        case .center: .center
        case .right: .right
        }
    }
}

/// Operator-chosen values used only when the preset is `.custom`. Sizes are preferences: the
/// receipt layout may shrink text within a safe range so it always fits its region.
nonisolated struct EventTypographyCustomStyle: Codable, Equatable, Sendable {
    nonisolated static let titleSizeRange = 14.0...40.0
    nonisolated static let detailsSizeRange = 9.0...18.0
    nonisolated static let trackingRange = -0.5...4.0
    nonisolated static let lineSpacingRange = 0.0...8.0

    var titleFont: EventFontFamily
    var titleWeight: EventFontWeight
    var titleSize: Double
    var titleTracking: Double
    var detailsFont: EventFontFamily
    var detailsWeight: EventFontWeight
    var detailsSize: Double
    var detailsTracking: Double
    var lineSpacing: Double
    var alignment: EventTextAlignment

    nonisolated static let `default` = EventTypographyCustomStyle(
        titleFont: .classicSerif,
        titleWeight: .bold,
        titleSize: 22,
        titleTracking: 0,
        detailsFont: .modernSans,
        detailsWeight: .semibold,
        detailsSize: 12,
        detailsTracking: 0.4,
        lineSpacing: 1,
        alignment: .center
    )

    init(
        titleFont: EventFontFamily,
        titleWeight: EventFontWeight,
        titleSize: Double,
        titleTracking: Double,
        detailsFont: EventFontFamily,
        detailsWeight: EventFontWeight,
        detailsSize: Double,
        detailsTracking: Double,
        lineSpacing: Double,
        alignment: EventTextAlignment
    ) {
        self.titleFont = titleFont
        self.titleWeight = titleWeight
        self.titleSize = titleSize
        self.titleTracking = titleTracking
        self.detailsFont = detailsFont
        self.detailsWeight = detailsWeight
        self.detailsSize = detailsSize
        self.detailsTracking = detailsTracking
        self.lineSpacing = lineSpacing
        self.alignment = alignment
    }

    private enum CodingKeys: String, CodingKey {
        case titleFont, titleWeight, titleSize, titleTracking
        case detailsFont, detailsWeight, detailsSize, detailsTracking
        case lineSpacing, alignment
    }

    /// Tolerant decoding: missing or unknown values (for example a font added by a newer build)
    /// fall back to defaults instead of making the whole event profile unreadable.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = Self.default
        titleFont = container.tolerantEnum(EventFontFamily.self, forKey: .titleFont) ?? fallback.titleFont
        titleWeight = container.tolerantEnum(EventFontWeight.self, forKey: .titleWeight) ?? fallback.titleWeight
        titleSize = (try? container.decodeIfPresent(Double.self, forKey: .titleSize)) ?? fallback.titleSize
        titleTracking = (try? container.decodeIfPresent(Double.self, forKey: .titleTracking)) ?? fallback.titleTracking
        detailsFont = container.tolerantEnum(EventFontFamily.self, forKey: .detailsFont) ?? fallback.detailsFont
        detailsWeight = container.tolerantEnum(EventFontWeight.self, forKey: .detailsWeight) ?? fallback.detailsWeight
        detailsSize = (try? container.decodeIfPresent(Double.self, forKey: .detailsSize)) ?? fallback.detailsSize
        detailsTracking = (try? container.decodeIfPresent(Double.self, forKey: .detailsTracking)) ?? fallback.detailsTracking
        lineSpacing = (try? container.decodeIfPresent(Double.self, forKey: .lineSpacing)) ?? fallback.lineSpacing
        alignment = container.tolerantEnum(EventTextAlignment.self, forKey: .alignment) ?? fallback.alignment
    }

    func normalized() -> EventTypographyCustomStyle {
        var value = self
        value.titleSize = titleSize.safelyClamped(to: Self.titleSizeRange, fallback: Self.default.titleSize)
        value.detailsSize = detailsSize.safelyClamped(to: Self.detailsSizeRange, fallback: Self.default.detailsSize)
        value.titleTracking = titleTracking.safelyClamped(to: Self.trackingRange, fallback: 0)
        value.detailsTracking = detailsTracking.safelyClamped(to: Self.trackingRange, fallback: 0)
        value.lineSpacing = lineSpacing.safelyClamped(to: Self.lineSpacingRange, fallback: 0)
        return value
    }
}

nonisolated struct EventTypographyConfiguration: Codable, Equatable, Sendable {
    var preset: EventTypographyPreset
    var custom: EventTypographyCustomStyle

    /// Classic reproduces the receipt typography used before typography was configurable, so
    /// existing events print exactly as they did.
    nonisolated static let `default` = EventTypographyConfiguration(preset: .classic, custom: .default)

    init(preset: EventTypographyPreset, custom: EventTypographyCustomStyle = .default) {
        self.preset = preset
        self.custom = custom
    }

    private enum CodingKeys: String, CodingKey {
        case preset, custom
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        preset = container.tolerantEnum(EventTypographyPreset.self, forKey: .preset) ?? .classic
        custom = (try? container.decodeIfPresent(EventTypographyCustomStyle.self, forKey: .custom)) ?? .default
    }

    func normalized() -> EventTypographyConfiguration {
        EventTypographyConfiguration(preset: preset, custom: custom.normalized())
    }

    var resolved: ResolvedEventTypography {
        preset == .custom ? .custom(custom.normalized()) : .preset(preset)
    }
}

/// Receipt design modules that are not artwork. Artwork stays in `EventProfile.receiptHeader`
/// (its original persisted key); future layout/design modules belong here.
nonisolated struct EventReceiptDesignConfiguration: Codable, Equatable, Sendable {
    var typography: EventTypographyConfiguration
    /// Optional event caption that replaces the format's default editorial caption. Up to two
    /// lines separated by a newline; empty keeps the default caption.
    var editorialCaption: String

    nonisolated static let `default` = EventReceiptDesignConfiguration(typography: .default)

    init(typography: EventTypographyConfiguration, editorialCaption: String = "") {
        self.typography = typography
        self.editorialCaption = editorialCaption
    }

    private enum CodingKeys: String, CodingKey {
        case typography
        case editorialCaption
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        typography = (try? container.decodeIfPresent(EventTypographyConfiguration.self, forKey: .typography)) ?? .default
        editorialCaption = (try? container.decodeIfPresent(String.self, forKey: .editorialCaption)) ?? ""
    }

    func normalized() -> EventReceiptDesignConfiguration {
        EventReceiptDesignConfiguration(
            typography: typography.normalized(),
            editorialCaption: ReceiptEditorialCaption.normalized(editorialCaption)
        )
    }
}

// MARK: - Resolved styles

nonisolated enum EventTextRole: String, CaseIterable, Sendable {
    case eyebrow
    case title
    case subtitle
    case metadata
    case message
}

nonisolated enum EventTextWrapping: Sendable, Equatable {
    case words
    case characters

    var lineBreakMode: NSLineBreakMode {
        switch self {
        case .words: .byWordWrapping
        case .characters: .byCharWrapping
        }
    }
}

/// One concrete font face. Creates the same UIFont every time for the same inputs.
nonisolated struct EventFontSpec: Equatable, Sendable {
    var family: EventFontFamily
    var weight: EventFontWeight
    var monospacedDigits: Bool = false

    func font(size: CGFloat) -> UIFont {
        EventFontLibrary.font(family: family, weight: weight, size: size, monospacedDigits: monospacedDigits)
    }
}

/// How one role of the event text block is set. `preferredSize` is a preference: layout tries
/// sizes from `preferredSize` down to `minimumSize` until the text fits in `targetLines`, and at
/// the minimum size wraps onto further lines rather than clipping or truncating.
nonisolated struct EventTextRoleStyle: Equatable, Sendable {
    var face: EventFontSpec
    var preferredSize: CGFloat
    var minimumSize: CGFloat
    var sizeStep: CGFloat = 1
    var tracking: CGFloat = 0
    var lineSpacing: CGFloat = 0
    var targetLines: Int = 2
    var uppercased: Bool = false
    var wrapping: EventTextWrapping = .words

    /// Font sizes tried in order. Always ends with `minimumSize` and contains no invalid values.
    var candidateSizes: [CGFloat] {
        let minimum = max(6, minimumSize.isFinite ? minimumSize : 6)
        let preferred = max(minimum, preferredSize.isFinite ? preferredSize : minimum)
        let step = max(0.5, sizeStep.isFinite ? sizeStep : 1)
        var sizes: [CGFloat] = []
        var size = preferred
        while size > minimum, sizes.count < 64 {
            sizes.append(size)
            size -= step
        }
        sizes.append(minimum)
        return sizes
    }
}

nonisolated struct ResolvedEventTypography: Equatable, Sendable {
    var eyebrow: EventTextRoleStyle
    var title: EventTextRoleStyle
    var subtitle: EventTextRoleStyle
    var metadata: EventTextRoleStyle
    var message: EventTextRoleStyle
    var alignment: EventTextAlignment

    func style(for role: EventTextRole) -> EventTextRoleStyle {
        switch role {
        case .eyebrow: eyebrow
        case .title: title
        case .subtitle: subtitle
        case .metadata: metadata
        case .message: message
        }
    }

    nonisolated static func preset(_ preset: EventTypographyPreset) -> ResolvedEventTypography {
        switch preset {
        case .classic, .custom:
            // Exact values used by ReceiptComposer before typography became configurable.
            return ResolvedEventTypography(
                eyebrow: EventTextRoleStyle(face: EventFontSpec(family: .monospaced, weight: .semibold), preferredSize: 11, minimumSize: 11, tracking: 1.8),
                title: EventTextRoleStyle(face: EventFontSpec(family: .classicSerif, weight: .bold), preferredSize: 22, minimumSize: 17, sizeStep: 2, lineSpacing: 1, wrapping: .characters),
                subtitle: EventTextRoleStyle(face: EventFontSpec(family: .classicSerif, weight: .semibold), preferredSize: 13, minimumSize: 13),
                metadata: EventTextRoleStyle(face: EventFontSpec(family: .modernSans, weight: .medium, monospacedDigits: true), preferredSize: 12, minimumSize: 12, tracking: 0.4),
                message: EventTextRoleStyle(face: EventFontSpec(family: .modernSans, weight: .semibold), preferredSize: 12, minimumSize: 12, tracking: 0.8, uppercased: true),
                alignment: .center
            )
        case .editorial:
            return ResolvedEventTypography(
                eyebrow: EventTextRoleStyle(face: EventFontSpec(family: .editorialSerif, weight: .regular), preferredSize: 12, minimumSize: 10, tracking: 2.6),
                title: EventTextRoleStyle(face: EventFontSpec(family: .editorialSerif, weight: .bold), preferredSize: 28, minimumSize: 18, sizeStep: 2, tracking: 0.4, lineSpacing: 2),
                subtitle: EventTextRoleStyle(face: EventFontSpec(family: .editorialSerif, weight: .semibold), preferredSize: 16, minimumSize: 12, tracking: 0.3, lineSpacing: 1),
                metadata: EventTextRoleStyle(face: EventFontSpec(family: .editorialSerif, weight: .regular), preferredSize: 13, minimumSize: 11, tracking: 1.4),
                message: EventTextRoleStyle(face: EventFontSpec(family: .editorialSerif, weight: .semibold), preferredSize: 13, minimumSize: 11, tracking: 0.6, lineSpacing: 1, targetLines: 3),
                alignment: .center
            )
        case .modern:
            return ResolvedEventTypography(
                eyebrow: EventTextRoleStyle(face: EventFontSpec(family: .modernSans, weight: .semibold), preferredSize: 11, minimumSize: 10, tracking: 2.4),
                title: EventTextRoleStyle(face: EventFontSpec(family: .modernSans, weight: .bold), preferredSize: 26, minimumSize: 17, sizeStep: 2, tracking: 0.3, lineSpacing: 1),
                subtitle: EventTextRoleStyle(face: EventFontSpec(family: .modernSans, weight: .semibold), preferredSize: 15, minimumSize: 12),
                metadata: EventTextRoleStyle(face: EventFontSpec(family: .modernSans, weight: .medium, monospacedDigits: true), preferredSize: 12, minimumSize: 11, tracking: 0.8),
                message: EventTextRoleStyle(face: EventFontSpec(family: .modernSans, weight: .semibold), preferredSize: 12, minimumSize: 11, tracking: 1.0, targetLines: 3, uppercased: true),
                alignment: .center
            )
        case .bold:
            return ResolvedEventTypography(
                eyebrow: EventTextRoleStyle(face: EventFontSpec(family: .condensedSans, weight: .bold), preferredSize: 12, minimumSize: 10, tracking: 2.6),
                title: EventTextRoleStyle(face: EventFontSpec(family: .condensedSans, weight: .heavy), preferredSize: 34, minimumSize: 20, sizeStep: 2, tracking: 0.6, targetLines: 2, uppercased: true),
                subtitle: EventTextRoleStyle(face: EventFontSpec(family: .condensedSans, weight: .bold), preferredSize: 16, minimumSize: 12, tracking: 0.6),
                metadata: EventTextRoleStyle(face: EventFontSpec(family: .condensedSans, weight: .semibold), preferredSize: 14, minimumSize: 11, tracking: 1.0),
                message: EventTextRoleStyle(face: EventFontSpec(family: .condensedSans, weight: .bold), preferredSize: 14, minimumSize: 11, tracking: 1.2, targetLines: 3, uppercased: true),
                alignment: .center
            )
        case .typewriter:
            return ResolvedEventTypography(
                eyebrow: EventTextRoleStyle(face: EventFontSpec(family: .monospaced, weight: .semibold), preferredSize: 11, minimumSize: 10, tracking: 1.8),
                title: EventTextRoleStyle(face: EventFontSpec(family: .typewriter, weight: .bold), preferredSize: 24, minimumSize: 16, sizeStep: 2, lineSpacing: 1),
                subtitle: EventTextRoleStyle(face: EventFontSpec(family: .typewriter, weight: .regular), preferredSize: 15, minimumSize: 12),
                metadata: EventTextRoleStyle(face: EventFontSpec(family: .typewriter, weight: .regular), preferredSize: 13, minimumSize: 11, tracking: 0.4),
                message: EventTextRoleStyle(face: EventFontSpec(family: .typewriter, weight: .semibold), preferredSize: 13, minimumSize: 11, tracking: 0.4, targetLines: 3),
                alignment: .center
            )
        }
    }

    nonisolated static func custom(_ style: EventTypographyCustomStyle) -> ResolvedEventTypography {
        let style = style.normalized()
        let title = CGFloat(style.titleSize)
        let details = CGFloat(style.detailsSize)
        let lineSpacing = CGFloat(style.lineSpacing)
        let detailsFace = EventFontSpec(family: style.detailsFont, weight: style.detailsWeight)
        let detailsTracking = CGFloat(style.detailsTracking)
        return ResolvedEventTypography(
            eyebrow: EventTextRoleStyle(face: detailsFace, preferredSize: max(9, details - 1), minimumSize: 9, tracking: max(1.4, detailsTracking)),
            title: EventTextRoleStyle(
                face: EventFontSpec(family: style.titleFont, weight: style.titleWeight),
                preferredSize: title,
                minimumSize: max(14, (title * 0.7).rounded(.down)),
                sizeStep: 1,
                tracking: CGFloat(style.titleTracking),
                lineSpacing: lineSpacing
            ),
            subtitle: EventTextRoleStyle(face: detailsFace, preferredSize: details + 1, minimumSize: max(9, details - 2), tracking: detailsTracking, lineSpacing: lineSpacing),
            metadata: EventTextRoleStyle(face: detailsFace, preferredSize: details, minimumSize: max(9, details - 2), tracking: detailsTracking, lineSpacing: lineSpacing),
            message: EventTextRoleStyle(face: detailsFace, preferredSize: details, minimumSize: max(9, details - 2), tracking: detailsTracking, lineSpacing: lineSpacing, targetLines: 3, uppercased: true),
            alignment: style.alignment
        )
    }
}

// MARK: - Font library

/// Deterministic font resolution. Named faces are Apple fonts installed with iPadOS; each has a
/// fixed system fallback that is used only if the named face cannot be created.
nonisolated enum EventFontLibrary {
    /// PostScript names by weight for named families. Missing weights use the nearest listed face.
    nonisolated static let namedFaces: [EventFontFamily: [EventFontWeight: String]] = [
        .editorialSerif: [
            .regular: "Baskerville",
            .medium: "Baskerville-SemiBold",
            .semibold: "Baskerville-SemiBold",
            .bold: "Baskerville-Bold",
            .heavy: "Baskerville-Bold"
        ],
        .typewriter: [
            .regular: "AmericanTypewriter",
            .medium: "AmericanTypewriter-Semibold",
            .semibold: "AmericanTypewriter-Semibold",
            .bold: "AmericanTypewriter-Bold",
            .heavy: "AmericanTypewriter-Bold"
        ]
    ]

    nonisolated static func font(family: EventFontFamily, weight: EventFontWeight, size requestedSize: CGFloat, monospacedDigits: Bool = false) -> UIFont {
        let size = requestedSize.isFinite ? max(1, requestedSize) : 12
        let systemWeight = weight.uiFontWeight
        switch family {
        case .classicSerif:
            return designed(.serif, size: size, weight: systemWeight)
        case .modernSans:
            return monospacedDigits
                ? .monospacedDigitSystemFont(ofSize: size, weight: systemWeight)
                : .systemFont(ofSize: size, weight: systemWeight)
        case .roundedSans:
            return designed(.rounded, size: size, weight: systemWeight)
        case .condensedSans:
            return .systemFont(ofSize: size, weight: systemWeight, width: .condensed)
        case .monospaced:
            return .monospacedSystemFont(ofSize: size, weight: systemWeight)
        case .editorialSerif:
            return named(family: family, weight: weight, size: size) ?? designed(.serif, size: size, weight: systemWeight)
        case .typewriter:
            return named(family: family, weight: weight, size: size) ?? .monospacedSystemFont(ofSize: size, weight: systemWeight)
        }
    }

    /// True when the family's preferred face is installed (named families) or is a system design.
    nonisolated static func isPreferredFaceAvailable(_ family: EventFontFamily, weight: EventFontWeight) -> Bool {
        guard let name = namedFaces[family]?[weight] else { return true }
        return UIFont(name: name, size: 12) != nil
    }

    nonisolated private static func named(family: EventFontFamily, weight: EventFontWeight, size: CGFloat) -> UIFont? {
        guard let name = namedFaces[family]?[weight] else { return nil }
        return UIFont(name: name, size: size)
    }

    nonisolated private static func designed(_ design: UIFontDescriptor.SystemDesign, size: CGFloat, weight: UIFont.Weight) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        return base.fontDescriptor.withDesign(design).map { UIFont(descriptor: $0, size: size) } ?? base
    }
}

// MARK: - Helpers

nonisolated extension KeyedDecodingContainer {
    /// Decodes a String-backed enum, returning nil for missing keys or values unknown to this build.
    func tolerantEnum<Value: RawRepresentable>(_ type: Value.Type, forKey key: Key) -> Value? where Value.RawValue == String {
        guard let raw = try? decodeIfPresent(String.self, forKey: key) else { return nil }
        return Value(rawValue: raw)
    }
}

private extension Double {
    nonisolated func safelyClamped(to range: ClosedRange<Double>, fallback: Double) -> Double {
        guard isFinite else { return min(range.upperBound, max(range.lowerBound, fallback)) }
        return min(range.upperBound, max(range.lowerBound, self))
    }
}
