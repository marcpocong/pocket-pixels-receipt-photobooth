//
//  MadeToKeepBrand.swift
//  PocketPixelsBooth
//
//  Customer- and operator-visible Made to Keep Studios identity. Internal identifiers
//  (module/target, bundle ID, storage keys, `PP-` session IDs, the current gallery host and
//  persisted raw values) intentionally stay legacy for compatibility.
//

import SwiftUI
import UIKit

nonisolated enum MadeToKeepBrand {
    static let fullName = "Made to Keep Studios"
    static let shortName = "Made to Keep"
    static let wordmark = "made to keep"
    static let secondary = "studios"
    static let descriptor = "RECEIPT PHOTOBOOTH"
    static let tagline = "little moments, made to keep."
    static let welcomeCallToAction = "MAKE A MEMORY"
    static let welcomeHelper = "tap to begin"
    static let headerLeading = "made to keep"
    static let headerTrailing = "photobooth"
    static let signature = "BY M&K"
    static let edition = "081719"
    static let footerIdentity = "MADE TO KEEP STUDIOS"

    static let formatHeadline = "CHOOSE YOUR KEEPSAKE"
    static let thankYouHeadline = "A LITTLE MOMENT, MADE TO KEEP."
    static let operatorHeaderTitle = fullName
    static let standardModeSummary = "Made to Keep standard mode"
    static let standardModeGuestDescription = "Guests see the standard Made to Keep Studios booth."
    static let defaultEventName = "Made to Keep default"
    static let defaultReceiptTitle = "Made to Keep Receipt"
    static let welcomeAccessibilityLabel = "Make a memory. Start a Made to Keep Studios photo session."

    /// Legacy visible strings that must never appear in customer/operator copy again.
    static let retiredVisibleStrings = ["Pocket Pixels", "@pocketpixels.ceb"]
}

// MARK: - Paper

/// Warm ivory printed-paper background used behind every guest screen. Event themes add a
/// very light tonal wash so the Made to Keep paper always reads first.
struct MadeToKeepPaperBackground: View {
    var tint: [Color]? = nil

    var body: some View {
        // Overlays never contribute to layout, so the square texture can't widen its container.
        MadeToKeepTheme.ColorPalette.ivory
            .overlay {
                if UIImage(named: "MadeToKeepPaperTexture") != nil {
                    Image("MadeToKeepPaperTexture")
                        .resizable()
                        .scaledToFill()
                }
            }
            .overlay {
                if let tint, tint.count > 1 {
                    LinearGradient(colors: tint, startPoint: .top, endPoint: .bottom)
                        .opacity(0.22)
                        .blendMode(.multiply)
                }
            }
            .clipped()
            .ignoresSafeArea()
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

// MARK: - Typographic pieces

/// Text with letter spacing expressed in em, matching the reference's wide tracking.
struct MadeToKeepTrackedText: View {
    let text: String
    let font: Font
    let size: CGFloat
    let tracking: CGFloat
    var color: Color = MadeToKeepTheme.ColorPalette.burgundy

    var body: some View {
        Text(text)
            .font(font)
            .tracking(size * tracking)
            .foregroundStyle(color)
    }
}

struct MadeToKeepRule: View {
    var width: CGFloat = 54
    var thickness: CGFloat = MadeToKeepTheme.Stroke.outline
    var color: Color = MadeToKeepTheme.ColorPalette.burgundy

    var body: some View {
        Rectangle()
            .fill(color)
            .frame(width: width, height: thickness)
            .accessibilityHidden(true)
    }
}

/// Condensed high-contrast italic `made to keep`. Native italic serifs on iOS are wider than
/// the reference lettering, so the wordmark is horizontally condensed to the reference
/// proportions while remaining crisp vector text.
struct MadeToKeepWordmark: View {
    let size: CGFloat
    var color: Color = MadeToKeepTheme.ColorPalette.burgundy
    /// Optional exact ink width; when nil the reference condensation ratio is used.
    var targetWidth: CGFloat? = nil

    var body: some View {
        let metrics = MadeToKeepWordmarkMetrics(size: size, targetWidth: targetWidth)
        Text(MadeToKeepBrand.wordmark)
            .font(MadeToKeepTheme.Typography.wordmark(size: size))
            .tracking(size * MadeToKeepTheme.Tracking.wordmark)
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize()
            .scaleEffect(x: metrics.horizontalScale, y: 1)
            .frame(width: metrics.condensedWidth, height: metrics.lineHeight)
            .accessibilityLabel(MadeToKeepBrand.shortName)
    }
}

nonisolated struct MadeToKeepWordmarkMetrics {
    /// Ratio measured against the reference wordmark with Bodoni 72 Book Italic at -0.05 em.
    static let referenceHorizontalScale: CGFloat = 0.855

    let naturalWidth: CGFloat
    let lineHeight: CGFloat
    let horizontalScale: CGFloat

    var condensedWidth: CGFloat { naturalWidth * horizontalScale }

    init(size: CGFloat, targetWidth: CGFloat? = nil) {
        let font = MadeToKeepTheme.Typography.italicSerifUIFont(size: size)
        let attributed = NSAttributedString(
            string: MadeToKeepBrand.wordmark,
            attributes: [.font: font, .kern: size * MadeToKeepTheme.Tracking.wordmark]
        )
        let bounds = attributed.boundingRect(with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin], context: nil)
        naturalWidth = max(1, ceil(bounds.width))
        lineHeight = ceil(font.lineHeight)
        if let targetWidth, targetWidth > 0 {
            horizontalScale = min(1, max(0.7, targetWidth / naturalWidth))
        } else {
            horizontalScale = Self.referenceHorizontalScale
        }
    }
}

/// Compact Made to Keep Studios lockup for screen headers.
struct MadeToKeepLockup: View {
    enum Scale {
        case compact
        case medium

        var wordmarkSize: CGFloat { self == .compact ? 34 : 56 }
        var studiosSize: CGFloat { self == .compact ? 11 : 17 }
        var spacing: CGFloat { self == .compact ? -2 : -4 }
    }

    let scale: Scale
    var color: Color = MadeToKeepTheme.ColorPalette.burgundy

    var body: some View {
        VStack(spacing: scale.spacing) {
            MadeToKeepWordmark(size: scale.wordmarkSize, color: color)
            MadeToKeepTrackedText(
                text: MadeToKeepBrand.secondary,
                font: MadeToKeepTheme.Typography.sans(size: scale.studiosSize, weight: .light),
                size: scale.studiosSize,
                tracking: 0.42,
                color: color
            )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(MadeToKeepBrand.fullName)
    }
}

/// Editorial screen heading: tracked eyebrow, short rule, italic serif title and a muted line.
struct MadeToKeepEditorialHeader: View {
    var eyebrow: String? = MadeToKeepBrand.descriptor
    let title: String
    var subtitle: String? = nil
    var titleSize: CGFloat = 50
    var alignment: HorizontalAlignment = .center

    var body: some View {
        VStack(alignment: alignment, spacing: 10) {
            if let eyebrow {
                MadeToKeepTrackedText(
                    text: eyebrow,
                    font: MadeToKeepTheme.Typography.sans(size: 14, weight: .medium),
                    size: 14,
                    tracking: MadeToKeepTheme.Tracking.descriptor
                )
                .accessibilityAddTraits(.isHeader)
                MadeToKeepRule(width: 44)
                    .padding(.vertical, 2)
            }

            Text(title)
                .font(MadeToKeepTheme.Typography.italicSerif(size: titleSize))
                .foregroundStyle(MadeToKeepTheme.ColorPalette.burgundy)
                .multilineTextAlignment(textAlignment)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .accessibilityAddTraits(.isHeader)

            if let subtitle {
                Text(subtitle)
                    .font(MadeToKeepTheme.Typography.sans(size: 18, weight: .regular))
                    .foregroundStyle(MadeToKeepTheme.ColorPalette.mutedInk)
                    .multilineTextAlignment(textAlignment)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var textAlignment: TextAlignment {
        switch alignment {
        case .leading: .leading
        case .trailing: .trailing
        default: .center
        }
    }
}

/// Tracked uppercase sans label in burgundy, used for photo roles and small section labels.
struct MadeToKeepLabel: View {
    let text: String
    var size: CGFloat = 13
    var color: Color = MadeToKeepTheme.ColorPalette.burgundy

    var body: some View {
        MadeToKeepTrackedText(
            text: text.uppercased(),
            font: MadeToKeepTheme.Typography.sans(size: size, weight: .medium),
            size: size,
            tracking: MadeToKeepTheme.Tracking.label,
            color: color
        )
    }
}
