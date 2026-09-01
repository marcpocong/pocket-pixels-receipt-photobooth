//
//  PocketPixelsTheme.swift
//  PocketPixelsBooth
//

import SwiftUI

enum PocketPixelsTheme {
    enum ColorPalette {
        static let paper = Color(red: 0.98, green: 0.955, blue: 0.91)
        static let paperWarm = Color(red: 0.94, green: 0.90, blue: 0.84)
        static let surface = Color(red: 1.0, green: 0.985, blue: 0.95)
        static let surfacePressed = Color(red: 0.91, green: 0.86, blue: 0.80)
        static let charcoal = Color(red: 0.12, green: 0.105, blue: 0.095)
        static let secondaryText = Color(red: 0.43, green: 0.37, blue: 0.33)
        static let maroon = Color(red: 0.55, green: 0.12, blue: 0.18)
        static let maroonMuted = Color(red: 0.70, green: 0.36, blue: 0.40)
        static let border = Color(red: 0.73, green: 0.65, blue: 0.58)
        static let lightText = Color(red: 1.0, green: 0.97, blue: 0.92)
        static let warningSurface = Color(red: 0.99, green: 0.91, blue: 0.84)
        static let warningText = Color(red: 0.53, green: 0.25, blue: 0.16)
    }

    enum Spacing {
        static let screenPadding: CGFloat = 42
        static let section: CGFloat = 26
        static let card: CGFloat = 20
    }

    enum Radius {
        static let button: CGFloat = 8
        static let card: CGFloat = 8
        static let receipt: CGFloat = 4
    }

    enum Layout {
        static let maxContentWidth: CGFloat = 1010
        static let startButtonWidth: CGFloat = 282
        static let buttonHeight: CGFloat = 66
        static let formatCardHeight: CGFloat = 292
        static let formatPreviewHeight: CGFloat = 152
    }
}

struct PocketPixelsPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 26, weight: .black))
            .foregroundStyle(PocketPixelsTheme.ColorPalette.lightText)
            .frame(height: PocketPixelsTheme.Layout.buttonHeight)
            .padding(.horizontal, 34)
            .background(
                RoundedRectangle(cornerRadius: PocketPixelsTheme.Radius.button)
                    .fill(isEnabled ? PocketPixelsTheme.ColorPalette.maroon : PocketPixelsTheme.ColorPalette.border)
            )
            .opacity(configuration.isPressed ? 0.86 : 1)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct PocketPixelsSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 20, weight: .bold))
            .foregroundStyle(isEnabled ? PocketPixelsTheme.ColorPalette.charcoal : PocketPixelsTheme.ColorPalette.secondaryText)
            .frame(minHeight: 48)
            .padding(.horizontal, 18)
            .background(
                RoundedRectangle(cornerRadius: PocketPixelsTheme.Radius.button)
                    .fill(PocketPixelsTheme.ColorPalette.surface.opacity(configuration.isPressed ? 0.40 : 0.55))
            )
            .overlay {
                RoundedRectangle(cornerRadius: PocketPixelsTheme.Radius.button)
                    .stroke(PocketPixelsTheme.ColorPalette.border.opacity(isEnabled ? 0.46 : 0.28), lineWidth: 1)
            }
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct FormatCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.88 : 1)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .shadow(
                color: PocketPixelsTheme.ColorPalette.charcoal.opacity(configuration.isPressed ? 0.04 : 0.07),
                radius: configuration.isPressed ? 4 : 8,
                x: 0,
                y: configuration.isPressed ? 2 : 5
            )
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
