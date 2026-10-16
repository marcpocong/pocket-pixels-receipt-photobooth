//
//  MadeToKeepWelcomeView.swift
//  PocketPixelsBooth
//
//  Faithful native recreation of the Made to Keep reference welcome poster.
//
//  The reference is 1048 × 1501 px, effectively the 834 × 1194 pt 11-inch iPad portrait canvas.
//  Every element below is positioned in reference pixels (measured from the master artwork)
//  and multiplied by one poster scale. Only the decorative paper / collage / safety pin layer is
//  a bitmap (`MadeToKeepWelcomeBackdrop`, the reference with every word and the CTA removed);
//  all typography and the CTA are live SwiftUI.
//

import SwiftUI
import UIKit

struct MadeToKeepWelcomeEventIdentity: Equatable {
    var title: String
    var subtitle: String
    var message: String

    var isEmpty: Bool { title.isEmpty && subtitle.isEmpty && message.isEmpty }
}

struct MadeToKeepWelcomeView: View {
    var eventIdentity: MadeToKeepWelcomeEventIdentity?
    var isStartDisabled = false
    var showsPrinterWarning = false
    var motionActive = true
    let onStart: () -> Void
    var onAdminLongPress: (() -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let layout = MadeToKeepPosterLayout(container: proxy.size)

            ZStack {
                MadeToKeepPaperBackground()

                poster(scale: layout.scale)
                    .frame(width: layout.posterSize.width, height: layout.posterSize.height)
                    .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .ignoresSafeArea()
    }

    // MARK: Poster

    private func poster(scale s: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            backdrop(scale: s)

            printedHeader(scale: s)
            bottomMarks(scale: s)

            if let eventIdentity, !eventIdentity.isEmpty {
                eventBlock(eventIdentity, scale: s)
            }

            brandStack(scale: s)

            callToAction(scale: s)

            helper(scale: s)
                .allowsHitTesting(false)

            if showsPrinterWarning {
                printerWarning(scale: s)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: MadeToKeepPosterLayout.referenceSize.width * s, height: MadeToKeepPosterLayout.referenceSize.height * s, alignment: .topLeading)
        .opacity(motionActive || reduceMotion ? 1 : 0)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.45), value: motionActive)
    }

    @ViewBuilder
    private func backdrop(scale s: CGFloat) -> some View {
        let size = CGSize(width: MadeToKeepPosterLayout.referenceSize.width * s, height: MadeToKeepPosterLayout.referenceSize.height * s)
        Group {
            if UIImage(named: "MadeToKeepWelcomeBackdrop") != nil {
                Image("MadeToKeepWelcomeBackdrop")
                    .resizable()
                    .interpolation(.high)
            } else {
                MadeToKeepTheme.ColorPalette.ivory
            }
        }
        .frame(width: size.width, height: size.height)
        // Feathered edges so the poster melts into the surrounding paper when letterboxed.
        .mask {
            LinearGradient(stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: 0.035),
                .init(color: .black, location: 0.965),
                .init(color: .clear, location: 1)
            ], startPoint: .leading, endPoint: .trailing)
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    /// `made to keep photobooth`, printed in soft taupe and tilted with the paper sheet.
    private func printedHeader(scale s: CGFloat) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 22 * s) {
            Text(MadeToKeepBrand.headerLeading)
                .font(.system(size: 37.4 * s, weight: .regular))
                .tracking(2.3 * s)
            Text(MadeToKeepBrand.headerTrailing)
                .font(Font(UIFont(name: "Didot-Italic", size: 46 * s) ?? MadeToKeepTheme.Typography.italicSerifUIFont(size: 46 * s)))
                .tracking(0.4 * s)
                // The reference script leans further than Didot Italic and lifts toward the pin.
                .transformEffect(CGAffineTransform(a: 1, b: 0, c: -0.2, d: 1, tx: 0, ty: 0))
                .rotationEffect(.degrees(-3), anchor: .leading)
        }
        .foregroundStyle(MadeToKeepTheme.ColorPalette.taupe.opacity(0.8))
        .fixedSize()
        .rotationEffect(.degrees(-5.45))
        .posterCenter(x: 494, y: 146, scale: s)
        .accessibilityHidden(true)
    }

    private func bottomMarks(scale s: CGFloat) -> some View {
        Group {
            Text(MadeToKeepBrand.signature)
                .font(.system(size: 31.2 * s, weight: .regular))
                .tracking(1.4 * s)
                .fixedSize()
                .rotationEffect(.degrees(-6))
                .posterCenter(x: 238, y: 1370, scale: s)

            Text(MadeToKeepBrand.edition)
                .font(.system(size: 27.4 * s, weight: .regular))
                .tracking(-0.4 * s)
                .monospacedDigit()
                .fixedSize()
                .rotationEffect(.degrees(-5.5))
                .posterCenter(x: 929, y: 1302, scale: s)
        }
        .foregroundStyle(MadeToKeepTheme.ColorPalette.taupe.opacity(0.78))
        .accessibilityHidden(true)
    }

    /// Wordmark lockup: descriptor, rule, `made to keep`, `studios`, tagline.
    private func brandStack(scale s: CGFloat) -> some View {
        Group {
            Text(MadeToKeepBrand.descriptor)
                .font(.system(size: 25.55 * s, weight: .medium))
                .tracking(5.28 * s)
                .foregroundStyle(MadeToKeepTheme.ColorPalette.burgundy)
                .fixedSize()
                .posterBaseline(x: 525 + 2.64, baseline: 412, scale: s)
                .accessibilityHidden(true)

            MadeToKeepRule(width: 68 * s, thickness: max(1, 2.4 * s))
                .posterCenter(x: 522.5, y: 462, scale: s)

            MadeToKeepWordmark(size: 192 * s, targetWidth: 726 * s)
                .overlay {
                    if let onAdminLongPress {
                        adminLongPressTarget(scale: s, action: onAdminLongPress)
                    }
                }
                .accessibilityLabel("\(MadeToKeepBrand.fullName). Receipt photobooth. \(MadeToKeepBrand.tagline)")
                .accessibilityAddTraits(.isHeader)
                .posterBaseline(x: 529.5, baseline: 666, scale: s)

            Text(MadeToKeepBrand.secondary)
                .font(.system(size: 61.05 * s, weight: .light))
                .tracking(12.59 * s)
                .foregroundStyle(MadeToKeepTheme.ColorPalette.burgundy)
                .fixedSize()
                .posterBaseline(x: 526.5 + 6.3, baseline: 723, scale: s)
                .accessibilityHidden(true)

            Text(MadeToKeepBrand.tagline)
                .font(MadeToKeepTheme.Typography.italicSerif(size: 45.05 * s))
                .tracking(-0.36 * s)
                .foregroundStyle(MadeToKeepTheme.ColorPalette.burgundy)
                .fixedSize()
                .posterBaseline(x: 526.5, baseline: 830, scale: s)
                .accessibilityHidden(true)
        }
    }

    /// CTA capsule bounds in reference pixels (origin 222, 909).
    private static let ctaCanvas = CGSize(width: 603, height: 124)

    /// The whole outlined capsule is the real Start Session button.
    private func callToAction(scale s: CGFloat) -> some View {
        Button(action: onStart) {
            ZStack(alignment: .topLeading) {
                Capsule()
                    .fill(MadeToKeepTheme.ColorPalette.ivoryLight.opacity(0.18))
                Capsule()
                    .strokeBorder(MadeToKeepTheme.ColorPalette.burgundy, lineWidth: max(1, 2.2 * s))

                Text(MadeToKeepBrand.welcomeCallToAction)
                    .font(MadeToKeepTheme.Typography.serif(size: 34.04 * s))
                    .tracking(8.67 * s)
                    .foregroundStyle(MadeToKeepTheme.ColorPalette.burgundy)
                    .fixedSize()
                    // Positions relative to the capsule's reference origin (222, 909).
                    .posterBaseline(x: 497.5 - 222 + 4.3, baseline: 983 - 909, scale: s, canvas: Self.ctaCanvas)

                MadeToKeepArrow()
                    .stroke(MadeToKeepTheme.ColorPalette.burgundy, style: StrokeStyle(lineWidth: max(1, 2.2 * s), lineCap: .round, lineJoin: .round))
                    .frame(width: 44 * s, height: 31 * s)
                    .posterCenter(x: 740.5 - 222, y: 971 - 909, scale: s, canvas: Self.ctaCanvas)
            }
            .frame(width: 603 * s, height: 124 * s, alignment: .topLeading)
            .contentShape(Capsule())
        }
        .buttonStyle(MadeToKeepWelcomeButtonStyle())
        .disabled(isStartDisabled)
        .opacity(isStartDisabled ? 0.55 : 1)
        .accessibilityLabel(Text("Make a memory"))
        .accessibilityHint(Text("Starts a new photo session"))
        .accessibilityIdentifier("madeToKeep.welcome.start")
        .posterCenter(x: 523, y: 970.5, scale: s)
    }

    private func helper(scale s: CGFloat) -> some View {
        Text(MadeToKeepBrand.welcomeHelper)
            .font(.system(size: 23.63 * s, weight: .regular))
            .tracking(7.89 * s)
            .foregroundStyle(MadeToKeepTheme.ColorPalette.burgundy)
            .fixedSize()
            .posterBaseline(x: 523.5 + 3.95, baseline: 1072, scale: s)
            .accessibilityHidden(true)
    }

    /// Event Mode keeps the Made to Keep poster and adds the event in the quiet band above the
    /// descriptor, on a soft paper wash so it stays legible over the faded collage.
    private func eventBlock(_ identity: MadeToKeepWelcomeEventIdentity, scale s: CGFloat) -> some View {
        VStack(spacing: 8 * s) {
            if !identity.subtitle.isEmpty {
                Text(identity.subtitle.uppercased())
                    .font(.system(size: 19 * s, weight: .medium))
                    .tracking(19 * s * 0.2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            if !identity.title.isEmpty {
                Text(identity.title)
                    .font(MadeToKeepTheme.Typography.italicSerif(size: 54 * s))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }
            if !identity.message.isEmpty {
                Text(identity.message)
                    .font(MadeToKeepTheme.Typography.italicSerif(size: 26 * s))
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
            }
        }
        .foregroundStyle(MadeToKeepTheme.ColorPalette.burgundy)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 44 * s)
        .padding(.vertical, 18 * s)
        .frame(width: 700 * s)
        .background {
            Ellipse()
                .fill(MadeToKeepTheme.ColorPalette.ivoryLight.opacity(0.86))
                .blur(radius: 26 * s)
        }
        .posterCenter(x: 525, y: 292, scale: s)
        .accessibilityElement(children: .combine)
        .accessibilityLabel([identity.title, identity.subtitle, identity.message].filter { !$0.isEmpty }.joined(separator: ". "))
    }

    private func printerWarning(scale s: CGFloat) -> some View {
        Label("Printer needs attention before receipt printing.", systemImage: "printer")
            .font(.system(size: max(13, 21 * s), weight: .medium))
            .foregroundStyle(MadeToKeepTheme.ColorPalette.burgundy)
            .padding(.horizontal, 22 * s)
            .padding(.vertical, 12 * s)
            .background(Capsule().fill(MadeToKeepTheme.ColorPalette.ivoryLight.opacity(0.94)))
            .overlay(Capsule().strokeBorder(MadeToKeepTheme.ColorPalette.burgundy.opacity(0.35), lineWidth: 1))
            .fixedSize()
            .posterCenter(x: 524, y: 1170, scale: s)
    }

    private func adminLongPressTarget(scale _: CGFloat, action: @escaping () -> Void) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 2.5, maximumDistance: 44)
                    .onEnded { _ in action() }
            )
            .accessibilityHidden(true)
    }
}

/// Maps the 1048 × 1501 reference onto any container. Near-portrait containers fill edge to
/// edge (the 11-inch portrait canvas differs from the reference by 0.04%); other shapes,
/// such as landscape, letterbox the poster on matching paper.
struct MadeToKeepPosterLayout {
    static let referenceSize = CGSize(width: 1048, height: 1501)
    static let contentBandHeight: CGFloat = 1380

    let scale: CGFloat
    let posterSize: CGSize

    init(container: CGSize) {
        let width = max(1, container.width)
        let height = max(1, container.height)
        // When letterboxing, the reference's outer paper margins (above the perforated sheet and
        // below it) may crop: fit the 1048 × 1380 content band rather than the full 1501 height.
        let fitScale = min(width / Self.referenceSize.width, height / Self.contentBandHeight)
        let fillScale = max(width / Self.referenceSize.width, height / Self.referenceSize.height)
        let aspectDelta = abs((width / height) / (Self.referenceSize.width / Self.referenceSize.height) - 1)
        scale = aspectDelta < 0.06 ? fillScale : fitScale
        posterSize = CGSize(width: Self.referenceSize.width * scale, height: Self.referenceSize.height * scale)
    }
}

/// Simple long-stem arrow matching the reference CTA.
struct MadeToKeepArrow: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let midY = rect.midY
        path.move(to: CGPoint(x: rect.minX, y: midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: midY))
        path.move(to: CGPoint(x: rect.maxX - rect.height * 0.5, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: midY))
        path.addLine(to: CGPoint(x: rect.maxX - rect.height * 0.5, y: rect.maxY))
        return path
    }
}

/// Tiny opacity/scale response only; no fills or bounces.
private struct MadeToKeepWelcomeButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.72 : 1)
            .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 0.992 : 1))
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private extension View {
    /// Places a view so its horizontal centre is at `x` and its first text baseline at `baseline`
    /// (reference pixels). Each placed element becomes its own full-canvas layer, so layers never
    /// grow the poster's bounds and every alignment is exact.
    func posterBaseline(x: CGFloat, baseline: CGFloat, scale: CGFloat, canvas: CGSize = MadeToKeepPosterLayout.referenceSize) -> some View {
        Color.clear
            .allowsHitTesting(false)
            .frame(width: canvas.width * scale, height: canvas.height * scale)
            .overlay(alignment: .topLeading) {
                alignmentGuide(.leading) { $0[HorizontalAlignment.center] }
                    .alignmentGuide(.top) { $0[.firstTextBaseline] }
                    .offset(x: x * scale, y: baseline * scale)
            }
    }

    /// Position the view's own bounds, without a full-poster hit-testing surface.
    func posterCenter(x: CGFloat, y: CGFloat, scale: CGFloat, canvas: CGSize = MadeToKeepPosterLayout.referenceSize) -> some View {
        Color.clear
            .allowsHitTesting(false)
            .frame(width: canvas.width * scale, height: canvas.height * scale)
            .overlay(alignment: .topLeading) {
                alignmentGuide(.leading) { $0[HorizontalAlignment.center] }
                    .alignmentGuide(.top) { $0[VerticalAlignment.center] }
                    .offset(x: x * scale, y: y * scale)
            }
    }
}
