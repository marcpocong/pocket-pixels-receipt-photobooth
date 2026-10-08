//
//  PocketPixelsTheme.swift
//  PocketPixelsBooth
//
//  The file name is a legacy project reference; the type inside is the Made to Keep Studios
//  visual system. Brand copy lives in `MadeToKeepBrand`, fonts in `MadeToKeepTheme.Typography`.
//

import SwiftUI
import UIKit

enum MadeToKeepTheme {
    /// Sampled from the Made to Keep reference design (median wordmark ink #70060B, sheet paper #F7F1E9).
    enum ColorPalette {
        /// Deep oxblood used for all brand typography and outlines.
        static let burgundy = Color(.sRGB, red: 0x70 / 255, green: 0x06 / 255, blue: 0x0B / 255, opacity: 1)
        static let burgundySoft = Color(.sRGB, red: 0x8A / 255, green: 0x2E / 255, blue: 0x33 / 255, opacity: 1)
        static let ivory = Color(.sRGB, red: 0xF7 / 255, green: 0xF1 / 255, blue: 0xE9 / 255, opacity: 1)
        static let ivoryLight = Color(.sRGB, red: 0xFB / 255, green: 0xF7 / 255, blue: 0xF1 / 255, opacity: 1)
        static let ivoryShade = Color(.sRGB, red: 0xEE / 255, green: 0xE6 / 255, blue: 0xDC / 255, opacity: 1)
        /// Soft gray-taupe of the reference's printed header, `BY M&K` and `081719`.
        static let taupe = Color(.sRGB, red: 0xA3 / 255, green: 0x99 / 255, blue: 0x90 / 255, opacity: 1)
        static let ink = Color(.sRGB, red: 0x2B / 255, green: 0x24 / 255, blue: 0x22 / 255, opacity: 1)
        static let mutedInk = Color(.sRGB, red: 0x6B / 255, green: 0x5F / 255, blue: 0x57 / 255, opacity: 1)
        static let hairline = Color(.sRGB, red: 0xD9 / 255, green: 0xCC / 255, blue: 0xBF / 255, opacity: 1)
        static let shadowTint = Color(.sRGB, red: 0x6E / 255, green: 0x5A / 255, blue: 0x48 / 255, opacity: 1)

        // Role names kept from the original palette so every screen re-tints from one place.
        static let brandMaroon = burgundy
        static let brandBlush = ivoryShade
        static let paper = ivory
        static let paperWarm = ivoryShade
        static let acrylic = ivoryLight
        static let surface = ivoryLight
        static let surfacePressed = ivoryShade
        static let amberGlow = shadowTint
        static let charcoal = ink
        static let secondaryText = mutedInk
        static let border = hairline
        static let lightText = ivoryLight
        static let warningSurface = Color(.sRGB, red: 0xF5 / 255, green: 0xE6 / 255, blue: 0xDE / 255, opacity: 1)
        static let warningText = burgundy

        static let maroon = burgundy
        static let maroonMuted = burgundySoft
    }

    enum Spacing {
        static let screenPadding: CGFloat = 42
        static let section: CGFloat = 26
        static let card: CGFloat = 20
    }

    enum Radius {
        static let button: CGFloat = 999
        static let card: CGFloat = 4
        static let receipt: CGFloat = 2
        static let photo: CGFloat = 2
    }

    enum Stroke {
        /// The reference CTA and rules are ~2 px at 1048 px wide, i.e. ~1.6 pt on an 11-inch iPad.
        static let hairline: CGFloat = 1
        static let outline: CGFloat = 1.6
    }

    /// Wide letter spacing used throughout the reference, expressed in em.
    nonisolated enum Tracking {
        static let descriptor: CGFloat = 0.207
        static let studios: CGFloat = 0.206
        static let helper: CGFloat = 0.334
        static let callToAction: CGFloat = 0.255
        static let label: CGFloat = 0.22
        static let wordmark: CGFloat = -0.05
    }

    enum Layout {
        static let maxContentWidth: CGFloat = 1010
        static let startButtonWidth: CGFloat = 282
        static let buttonHeight: CGFloat = 64
        static let formatCardHeight: CGFloat = 292
        static let formatPreviewHeight: CGFloat = 152
    }

    enum Motion {
        static let quick: TimeInterval = 0.15
        static let standard: TimeInterval = 0.25
        static let entrance: TimeInterval = 0.32
        static let stagger: TimeInterval = 0.055
        static let pressedScale: CGFloat = 0.99
        static let subtleScale: CGFloat = 0.985
        static let entranceOffset: CGFloat = 10
        static let receiptOffset: CGFloat = -14
        static let shutterFlashOpacity: CGFloat = 0.56
        static let shutterFlashDuration: TimeInterval = 0.14
        static let idleFloatDistance: CGFloat = 3
        static let idleFloatDuration: TimeInterval = 3.4
        static let printerFeedDuration: TimeInterval = 5

        static let quickAnimation = Animation.easeOut(duration: quick)
        static let standardAnimation = Animation.easeOut(duration: standard)
        static let entranceAnimation = Animation.easeOut(duration: entrance)
        static let screenTransitionAnimation = Animation.easeInOut(duration: 0.28)
        static let idleFloatAnimation = Animation.easeInOut(duration: idleFloatDuration).repeatForever(autoreverses: true)
    }

    /// Native iOS faces chosen to match the reference, each with a safe fallback chain so a
    /// missing face can never crash or silently become upright system text.
    nonisolated enum Typography {
        /// High-contrast italic serif for `made to keep` and the tagline.
        static let italicSerifNames = ["BodoniSvtyTwoITCTT-BookIta", "Didot-Italic", "Georgia-Italic"]
        /// High-contrast upright serif for the CTA and editorial capitals.
        static let uprightSerifNames = ["BodoniSvtyTwoITCTT-Book", "Didot", "Georgia"]
        static let boldSerifNames = ["BodoniSvtyTwoITCTT-Bold", "Didot-Bold", "Georgia-Bold"]

        static func italicSerifUIFont(size: CGFloat) -> UIFont {
            resolvedFont(italicSerifNames, size: size) ?? serifFallback(size: size, italic: true)
        }

        static func uprightSerifUIFont(size: CGFloat) -> UIFont {
            resolvedFont(uprightSerifNames, size: size) ?? serifFallback(size: size, italic: false)
        }

        static func boldSerifUIFont(size: CGFloat) -> UIFont {
            resolvedFont(boldSerifNames, size: size) ?? serifFallback(size: size, italic: false, bold: true)
        }

        static func wordmark(size: CGFloat) -> Font { Font(italicSerifUIFont(size: size)) }
        static func italicSerif(size: CGFloat) -> Font { Font(italicSerifUIFont(size: size)) }
        static func serif(size: CGFloat) -> Font { Font(uprightSerifUIFont(size: size)) }
        static func boldSerif(size: CGFloat) -> Font { Font(boldSerifUIFont(size: size)) }

        /// Understated sans for descriptors, helpers and utilitarian copy.
        static func sans(size: CGFloat, weight: Font.Weight = .regular) -> Font {
            .system(size: size, weight: weight)
        }

        /// Text-style based sans for body copy that should follow Dynamic Type.
        static func body(_ style: Font.TextStyle = .body, weight: Font.Weight = .regular) -> Font {
            .system(style, weight: weight)
        }

        private static func resolvedFont(_ names: [String], size: CGFloat) -> UIFont? {
            for name in names {
                if let font = UIFont(name: name, size: size) {
                    return font
                }
            }
            return nil
        }

        private static func serifFallback(size: CGFloat, italic: Bool, bold: Bool = false) -> UIFont {
            let base = UIFont.systemFont(ofSize: size, weight: bold ? .bold : .regular)
            var traits: UIFontDescriptor.SymbolicTraits = []
            if italic { traits.insert(.traitItalic) }
            let serif = base.fontDescriptor.withDesign(.serif) ?? base.fontDescriptor
            let descriptor = serif.withSymbolicTraits(traits.union(serif.symbolicTraits)) ?? serif
            return UIFont(descriptor: descriptor, size: size)
        }
    }
}

/// Thin burgundy outlined capsule, the reference CTA treatment. Interaction is a tiny opacity
/// and scale response only.
struct MadeToKeepPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(MadeToKeepTheme.Typography.serif(size: 21))
            .tracking(21 * 0.16)
            .textCase(.uppercase)
            .foregroundStyle(isEnabled ? MadeToKeepTheme.ColorPalette.burgundy : MadeToKeepTheme.ColorPalette.mutedInk.opacity(0.6))
            .frame(minHeight: MadeToKeepTheme.Layout.buttonHeight)
            .padding(.horizontal, 34)
            .background(
                Capsule()
                    .fill(MadeToKeepTheme.ColorPalette.ivoryLight.opacity(configuration.isPressed ? 0.98 : 0.82))
            )
            .overlay {
                Capsule()
                    .strokeBorder(
                        (isEnabled ? MadeToKeepTheme.ColorPalette.burgundy : MadeToKeepTheme.ColorPalette.hairline),
                        lineWidth: MadeToKeepTheme.Stroke.outline
                    )
            }
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.78 : 1)
            .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? MadeToKeepTheme.Motion.pressedScale : 1))
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Quiet secondary action: tracked sans label with a hairline capsule.
struct MadeToKeepSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .medium))
            .tracking(16 * 0.12)
            .textCase(.uppercase)
            .foregroundStyle(isEnabled ? MadeToKeepTheme.ColorPalette.burgundy : MadeToKeepTheme.ColorPalette.mutedInk.opacity(0.55))
            .frame(minHeight: 48)
            .padding(.horizontal, 20)
            .background(
                Capsule()
                    .fill(MadeToKeepTheme.ColorPalette.ivoryLight.opacity(configuration.isPressed ? 0.95 : 0.6))
            )
            .overlay {
                Capsule()
                    .strokeBorder(MadeToKeepTheme.ColorPalette.burgundy.opacity(isEnabled ? 0.45 : 0.18), lineWidth: MadeToKeepTheme.Stroke.hairline)
            }
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.8 : 1)
            .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? MadeToKeepTheme.Motion.pressedScale : 1))
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct FormatCardButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.84 : 1)
            .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 0.985 : 1))
            .shadow(
                color: MadeToKeepTheme.ColorPalette.shadowTint.opacity(configuration.isPressed ? 0.05 : 0.10),
                radius: configuration.isPressed ? 3 : 7,
                x: 0,
                y: configuration.isPressed ? 1 : 4
            )
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
