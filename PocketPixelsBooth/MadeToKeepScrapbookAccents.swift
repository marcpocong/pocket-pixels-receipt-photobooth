//
//  MadeToKeepScrapbookAccents.swift
//  PocketPixelsBooth
//
//  Small hand-drawn accents for the camera and receipt screens: a torn paper corner, a looping
//  burgundy line, sketched hearts and sparkle strokes, and a sepia print peeking from a corner.
//  All vector, drawn behind content near the screen edges, hidden from VoiceOver and never
//  hit-testable, so they can't cover a photo, a receipt or a control.
//

import SwiftUI

struct MadeToKeepScrapbookAccents: View {
    var body: some View {
        Canvas { context, size in
            let unit = min(size.width, size.height)
            let ink = MadeToKeepTheme.ColorPalette.burgundy

            // Torn paper scrap with tape, upper left.
            var scrap = Path()
            scrap.move(to: CGPoint(x: 0, y: unit * 0.02))
            scrap.addLine(to: CGPoint(x: unit * 0.20, y: 0))
            scrap.addLine(to: CGPoint(x: unit * 0.24, y: unit * 0.035))
            scrap.addLine(to: CGPoint(x: unit * 0.17, y: unit * 0.075))
            scrap.addLine(to: CGPoint(x: unit * 0.10, y: unit * 0.115))
            scrap.addLine(to: CGPoint(x: unit * 0.045, y: unit * 0.13))
            scrap.addLine(to: CGPoint(x: 0, y: unit * 0.15))
            scrap.closeSubpath()
            var shadowed = context
            shadowed.addFilter(.shadow(color: MadeToKeepTheme.ColorPalette.shadowTint.opacity(0.18), radius: 4, x: 1, y: 2))
            shadowed.fill(scrap, with: .color(MadeToKeepTheme.ColorPalette.ivoryShade))

            // Looping line from the upper right edge.
            var loop = Path()
            loop.move(to: CGPoint(x: size.width - unit * 0.09, y: 0))
            loop.addCurve(
                to: CGPoint(x: size.width - unit * 0.03, y: unit * 0.13),
                control1: CGPoint(x: size.width - unit * 0.11, y: unit * 0.06),
                control2: CGPoint(x: size.width - unit * 0.01, y: unit * 0.07)
            )
            loop.addCurve(
                to: CGPoint(x: size.width, y: unit * 0.11),
                control1: CGPoint(x: size.width - unit * 0.05, y: unit * 0.17),
                control2: CGPoint(x: size.width - unit * 0.075, y: unit * 0.10)
            )
            context.stroke(loop, with: .color(ink.opacity(0.75)), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))

            // Two long sweeping lines, lower left.
            for (index, offset) in [0.0, 0.07].enumerated() {
                var sweep = Path()
                sweep.move(to: CGPoint(x: 0, y: size.height - unit * (0.20 - offset)))
                sweep.addQuadCurve(
                    to: CGPoint(x: unit * (0.17 - offset), y: size.height),
                    control: CGPoint(x: unit * (0.13 - offset * 0.5), y: size.height - unit * (0.12 - offset))
                )
                context.stroke(sweep, with: .color(ink.opacity(index == 0 ? 0.7 : 0.5)), style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
            }

            // A sepia print peeking from the lower right corner.
            var print = context
            print.translateBy(x: size.width - unit * 0.05, y: size.height - unit * 0.12)
            print.rotate(by: .degrees(-14))
            let card = CGRect(x: 0, y: 0, width: unit * 0.13, height: unit * 0.16)
            print.addFilter(.shadow(color: MadeToKeepTheme.ColorPalette.shadowTint.opacity(0.22), radius: 5, x: 0, y: 2))
            print.fill(Path(card), with: .color(MadeToKeepTheme.ColorPalette.ivoryLight))
            print.fill(Path(card.insetBy(dx: unit * 0.008, dy: unit * 0.008)), with: .linearGradient(
                Gradient(colors: [Color(red: 0.73, green: 0.66, blue: 0.58), Color(red: 0.86, green: 0.81, blue: 0.74)]),
                startPoint: card.origin, endPoint: CGPoint(x: card.maxX, y: card.maxY)))

            // Sketched heart with sparkle strokes, lower right above the print.
            let heartCenter = CGPoint(x: size.width - unit * 0.075, y: size.height - unit * 0.24)
            let heartSize = unit * 0.045
            context.stroke(Self.heart(center: heartCenter, size: heartSize), with: .color(ink.opacity(0.8)), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
            context.stroke(Self.sparkle(at: CGPoint(x: heartCenter.x - heartSize * 1.1, y: heartCenter.y - heartSize * 1.2), length: heartSize * 0.7, angle: -60),
                           with: .color(ink.opacity(0.8)), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    static func heart(center: CGPoint, size: CGFloat) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: center.x, y: center.y + size * 0.9))
        path.addCurve(to: CGPoint(x: center.x - size, y: center.y - size * 0.25),
                      control1: CGPoint(x: center.x - size * 0.45, y: center.y + size * 0.5),
                      control2: CGPoint(x: center.x - size * 1.05, y: center.y + size * 0.2))
        path.addCurve(to: CGPoint(x: center.x, y: center.y - size * 0.3),
                      control1: CGPoint(x: center.x - size * 0.95, y: center.y - size * 0.95),
                      control2: CGPoint(x: center.x - size * 0.15, y: center.y - size * 0.9))
        path.addCurve(to: CGPoint(x: center.x + size * 0.95, y: center.y - size * 0.3),
                      control1: CGPoint(x: center.x + size * 0.15, y: center.y - size * 0.95),
                      control2: CGPoint(x: center.x + size * 0.95, y: center.y - size * 0.95))
        path.addCurve(to: CGPoint(x: center.x + size * 0.05, y: center.y + size * 0.95),
                      control1: CGPoint(x: center.x + size * 0.95, y: center.y + size * 0.25),
                      control2: CGPoint(x: center.x + size * 0.4, y: center.y + size * 0.55))
        return path
    }

    /// Three short "pop" strokes fanning out from a point, like a hand-drawn sparkle.
    static func sparkle(at point: CGPoint, length: CGFloat, angle: Double) -> Path {
        var path = Path()
        for spread in [-38.0, 0, 38] {
            let radians = (angle + spread) * .pi / 180
            let start = CGPoint(x: point.x + cos(radians) * length * 0.25, y: point.y + sin(radians) * length * 0.25)
            let end = CGPoint(x: point.x + cos(radians) * length, y: point.y + sin(radians) * length)
            path.move(to: start)
            path.addLine(to: end)
        }
        return path
    }
}

/// Three sparkle strokes for a corner of a framed photo or receipt.
struct MadeToKeepSparkleMark: View {
    var length: CGFloat = 26
    var angle: Double = -130

    var body: some View {
        Canvas { context, size in
            context.stroke(
                MadeToKeepScrapbookAccents.sparkle(at: CGPoint(x: size.width, y: size.height), length: length, angle: angle),
                with: .color(MadeToKeepTheme.ColorPalette.burgundy.opacity(0.85)),
                style: StrokeStyle(lineWidth: 1.8, lineCap: .round)
            )
        }
        .frame(width: length * 1.2, height: length * 1.2)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Solid burgundy capsule with ivory serif capitals: the single primary action on a screen
/// (PRINT RECEIPT, START PHOTOS). Disabled reads as muted, never as a live action.
struct MadeToKeepFilledButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(MadeToKeepTheme.Typography.serif(size: 24))
            .tracking(24 * 0.16)
            .textCase(.uppercase)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .foregroundStyle(MadeToKeepTheme.ColorPalette.ivoryLight.opacity(isEnabled ? 1 : 0.8))
            .frame(minHeight: 72)
            .padding(.horizontal, 34)
            .background(
                Capsule().fill(isEnabled ? MadeToKeepTheme.ColorPalette.burgundy : MadeToKeepTheme.ColorPalette.mutedInk.opacity(0.45))
            )
            .shadow(color: MadeToKeepTheme.ColorPalette.burgundy.opacity(isEnabled ? 0.22 : 0), radius: 12, x: 0, y: 6)
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? MadeToKeepTheme.Motion.pressedScale : 1))
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Paper receipt edge: straight top and sides, a softly scalloped tear along the bottom.
struct MadeToKeepReceiptPaperShape: Shape {
    var scallopWidth: CGFloat = 12
    var scallopDepth: CGFloat = 4

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let radius: CGFloat = 6
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        path.addQuadCurve(to: CGPoint(x: rect.minX + radius, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + radius), control: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - scallopDepth))
        let count = max(1, Int(rect.width / scallopWidth))
        let step = rect.width / CGFloat(count)
        for index in 0..<count {
            let startX = rect.maxX - CGFloat(index) * step
            path.addQuadCurve(
                to: CGPoint(x: startX - step, y: rect.maxY - scallopDepth),
                control: CGPoint(x: startX - step / 2, y: rect.maxY + scallopDepth)
            )
        }
        path.closeSubpath()
        return path
    }
}
