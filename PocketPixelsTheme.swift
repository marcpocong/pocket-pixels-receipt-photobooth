//
//  PocketPixelsTheme.swift
//  PocketPixelsBooth
//

import SwiftUI

enum PocketPixelsTheme {
    enum ColorPalette {
        static let brandMaroon = Color(red: 0.467, green: 0.129, blue: 0.188)
        static let brandBlush = Color(red: 0.976, green: 0.851, blue: 0.780)
        static let paper = Color(red: 1.0, green: 0.973, blue: 0.949)
        static let paperWarm = Color(red: 1.0, green: 0.941, blue: 0.902)
        static let acrylic = Color(red: 1.0, green: 0.992, blue: 0.976)
        static let surface = Color(red: 1.0, green: 0.992, blue: 0.976)
        static let surfacePressed = Color(red: 0.976, green: 0.851, blue: 0.780)
        static let amberGlow = Color(red: 0.898, green: 0.627, blue: 0.353)
        static let charcoal = Color(red: 0.165, green: 0.129, blue: 0.118)
        static let secondaryText = Color(red: 0.439, green: 0.361, blue: 0.329)
        static let border = Color(red: 0.835, green: 0.706, blue: 0.639)
        static let lightText = Color(red: 1.0, green: 0.973, blue: 0.949)
        static let warningSurface = Color(red: 1.0, green: 0.921, blue: 0.866)
        static let warningText = Color(red: 0.467, green: 0.129, blue: 0.188)

        static let maroon = brandMaroon
        static let maroonMuted = Color(red: 0.62, green: 0.30, blue: 0.34)
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

    enum Motion {
        static let quick: TimeInterval = 0.15
        static let standard: TimeInterval = 0.25
        static let entrance: TimeInterval = 0.32
        static let stagger: TimeInterval = 0.055
        static let pressedScale: CGFloat = 0.98
        static let subtleScale: CGFloat = 0.985
        static let entranceOffset: CGFloat = 10
        static let receiptOffset: CGFloat = -14
        static let shutterFlashOpacity: CGFloat = 0.56
        static let shutterFlashDuration: TimeInterval = 0.14
        static let idleFloatDistance: CGFloat = 3
        static let idleFloatDuration: TimeInterval = 3.4

        static let quickAnimation = Animation.easeOut(duration: quick)
        static let standardAnimation = Animation.easeOut(duration: standard)
        static let entranceAnimation = Animation.easeOut(duration: entrance)
        static let screenTransitionAnimation = Animation.easeInOut(duration: 0.28)
        static let idleFloatAnimation = Animation.easeInOut(duration: idleFloatDuration).repeatForever(autoreverses: true)
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
                    .fill(isEnabled ? PocketPixelsTheme.ColorPalette.brandMaroon : PocketPixelsTheme.ColorPalette.border)
                    .shadow(color: PocketPixelsTheme.ColorPalette.amberGlow.opacity(isEnabled ? 0.16 : 0), radius: 12, x: 0, y: 5)
            )
            .opacity(configuration.isPressed ? 0.86 : 1)
            .scaleEffect(configuration.isPressed ? PocketPixelsTheme.Motion.pressedScale : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct PocketPixelsSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 20, weight: .bold))
            .foregroundStyle(isEnabled ? PocketPixelsTheme.ColorPalette.brandMaroon : PocketPixelsTheme.ColorPalette.secondaryText)
            .frame(minHeight: 48)
            .padding(.horizontal, 18)
            .background(
                RoundedRectangle(cornerRadius: PocketPixelsTheme.Radius.button)
                    .fill(PocketPixelsTheme.ColorPalette.brandBlush.opacity(configuration.isPressed ? 0.45 : 0.24))
            )
            .overlay {
                RoundedRectangle(cornerRadius: PocketPixelsTheme.Radius.button)
                    .stroke(PocketPixelsTheme.ColorPalette.brandMaroon.opacity(isEnabled ? 0.28 : 0.16), lineWidth: 1)
            }
            .scaleEffect(configuration.isPressed ? PocketPixelsTheme.Motion.pressedScale : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct FormatCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.88 : 1)
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .shadow(
                color: PocketPixelsTheme.ColorPalette.charcoal.opacity(configuration.isPressed ? 0.04 : 0.07),
                radius: configuration.isPressed ? 4 : 8,
                x: 0,
                y: configuration.isPressed ? 2 : 5
            )
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
