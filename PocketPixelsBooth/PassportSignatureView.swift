//
//  PassportSignatureView.swift
//  PocketPixelsBooth
//
//  A simple signing pad. Strokes are stored as normalized coordinates in a fixed 4:1 canvas,
//  so the signature is screen-size independent. The in-progress stroke stays local to the
//  pad and is committed to the session only when the finger or Pencil lifts.
//

import SwiftUI

struct PassportSignatureView: View {
    @ObservedObject var viewModel: BoothSessionViewModel
    let onCancel: () -> Void

    var body: some View {
        GeometryReader { proxy in
            let contentWidth = max(1, min(proxy.size.width - MadeToKeepTheme.Spacing.screenPadding * 2, 860))
            let signature = viewModel.passportDraft.signature

            VStack(spacing: 22) {
                PassportStepHeader(
                    step: 2,
                    title: "Add your signature",
                    subtitle: "Sign with your finger or Apple Pencil. Signing is optional.",
                    onCancel: onCancel
                )
                .frame(width: contentWidth)

                PassportSignaturePad(signature: signature) { stroke in
                    viewModel.updatePassportSignature(signature.appending(stroke))
                }
                .frame(width: contentWidth)

                HStack(spacing: 14) {
                    Button {
                        viewModel.updatePassportSignature(signature.removingLastStroke())
                    } label: {
                        Label("Undo", systemImage: "arrow.uturn.backward")
                    }
                    .buttonStyle(MadeToKeepSecondaryButtonStyle())
                    .disabled(signature.isEmpty)
                    .accessibilityLabel("Undo last signature stroke")

                    Button {
                        viewModel.updatePassportSignature(.empty)
                    } label: {
                        Label("Clear", systemImage: "xmark.circle")
                    }
                    .buttonStyle(MadeToKeepSecondaryButtonStyle())
                    .disabled(signature.isEmpty)
                    .accessibilityLabel("Clear signature")
                }

                Spacer(minLength: 0)

                HStack(spacing: 16) {
                    Button("Back to Details") {
                        viewModel.backToPassportDetails()
                    }
                    .buttonStyle(MadeToKeepSecondaryButtonStyle())

                    Button {
                        viewModel.continueFromPassportSignature()
                    } label: {
                        Text(signature.isEmpty ? "Continue Without Signature" : "Continue")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(MadeToKeepPrimaryButtonStyle())
                    .accessibilityHint("Shows a preview of your Photo Pass.")
                }
                .frame(width: min(contentWidth, 720))
                .padding(.bottom, 12)
            }
            .padding(.top, 28)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, MadeToKeepTheme.Spacing.screenPadding)
    }
}

struct PassportSignaturePad: View {
    let signature: PassportSignature
    let onStrokeCompleted: (PassportSignature.Stroke) -> Void

    @State private var activePoints: [CGPoint] = []

    private static let ink = MadeToKeepTheme.ColorPalette.charcoal
    private static let minimumPointSpacing: CGFloat = 1.5

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: MadeToKeepTheme.Radius.card)
                    .fill(MadeToKeepTheme.ColorPalette.ivoryLight)

                Canvas { context, canvasSize in
                    let bounds = CGRect(origin: .zero, size: canvasSize)
                    let style = StrokeStyle(lineWidth: max(3, canvasSize.height * 0.028), lineCap: .round, lineJoin: .round)
                    context.stroke(Path(signature.path(in: bounds)), with: .color(Self.ink), style: style)
                    if let stroke = PassportSignature.stroke(from: activePoints, canvasSize: canvasSize) {
                        context.stroke(Path(PassportSignature(strokes: [stroke]).path(in: bounds)), with: .color(Self.ink), style: style)
                    }
                }

                // Signing line and hint; both are decoration only and never part of the stored signature.
                VStack(alignment: .leading, spacing: 6) {
                    if signature.isEmpty && activePoints.isEmpty {
                        Text("sign here")
                            .font(MadeToKeepTheme.Typography.italicSerif(size: 28))
                            .foregroundStyle(MadeToKeepTheme.ColorPalette.taupe)
                    }
                    HStack(spacing: 10) {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .light))
                        Rectangle()
                            .frame(height: 1)
                    }
                    .foregroundStyle(MadeToKeepTheme.ColorPalette.burgundy.opacity(0.55))
                }
                .padding(.horizontal, 28)
                .padding(.bottom, size.height * 0.16)
                .allowsHitTesting(false)
            }
            .overlay {
                RoundedRectangle(cornerRadius: MadeToKeepTheme.Radius.card)
                    .strokeBorder(MadeToKeepTheme.ColorPalette.burgundy.opacity(0.4), lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: MadeToKeepTheme.Radius.card))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        let point = CGPoint(
                            x: min(max(value.location.x, 0), size.width),
                            y: min(max(value.location.y, 0), size.height)
                        )
                        if let last = activePoints.last,
                           hypot(point.x - last.x, point.y - last.y) < Self.minimumPointSpacing {
                            return
                        }
                        guard activePoints.count < PassportSignature.maximumPointsPerStroke else { return }
                        activePoints.append(point)
                    }
                    .onEnded { _ in
                        if let stroke = PassportSignature.stroke(from: activePoints, canvasSize: size) {
                            onStrokeCompleted(stroke)
                        }
                        activePoints = []
                    }
            )
        }
        .aspectRatio(PassportSignature.canvasAspectRatio, contentMode: .fit)
        .shadow(color: MadeToKeepTheme.ColorPalette.shadowTint.opacity(0.12), radius: 10, x: 0, y: 4)
        .accessibilityElement()
        .accessibilityLabel("Signature pad")
        .accessibilityValue(signature.isEmpty ? "Empty" : "Signed")
        .accessibilityHint("Draw your signature with your finger or Apple Pencil. Signing is optional; you can continue without one.")
        .accessibilityAddTraits(.allowsDirectInteraction)
    }
}
