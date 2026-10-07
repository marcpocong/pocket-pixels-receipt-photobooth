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
            let contentWidth = max(1, min(proxy.size.width - PocketPixelsTheme.Spacing.screenPadding * 2, 860))
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
                    .buttonStyle(PocketPixelsSecondaryButtonStyle())
                    .disabled(signature.isEmpty)
                    .accessibilityLabel("Undo last signature stroke")

                    Button {
                        viewModel.updatePassportSignature(.empty)
                    } label: {
                        Label("Clear", systemImage: "xmark.circle")
                    }
                    .buttonStyle(PocketPixelsSecondaryButtonStyle())
                    .disabled(signature.isEmpty)
                    .accessibilityLabel("Clear signature")
                }

                Spacer(minLength: 0)

                HStack(spacing: 16) {
                    Button("Back to Details") {
                        viewModel.backToPassportDetails()
                    }
                    .buttonStyle(PocketPixelsSecondaryButtonStyle())

                    Button {
                        viewModel.continueFromPassportSignature()
                    } label: {
                        Text(signature.isEmpty ? "Continue Without Signature" : "Continue")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PocketPixelsPrimaryButtonStyle())
                    .accessibilityHint("Shows a preview of your Photo Pass.")
                }
                .frame(width: min(contentWidth, 720))
                .padding(.bottom, 12)
            }
            .padding(.top, 28)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, PocketPixelsTheme.Spacing.screenPadding)
    }
}

struct PassportSignaturePad: View {
    let signature: PassportSignature
    let onStrokeCompleted: (PassportSignature.Stroke) -> Void

    @State private var activePoints: [CGPoint] = []

    private static let ink = PocketPixelsTheme.ColorPalette.charcoal
    private static let minimumPointSpacing: CGFloat = 1.5

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: 18)
                    .fill(Color.white)

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
                        Text("Sign here")
                            .font(.system(size: 22, weight: .medium, design: .serif))
                            .foregroundStyle(PocketPixelsTheme.ColorPalette.secondaryText.opacity(0.6))
                    }
                    HStack(spacing: 10) {
                        Image(systemName: "xmark")
                            .font(.system(size: 18, weight: .bold))
                        Rectangle()
                            .frame(height: 2)
                    }
                    .foregroundStyle(PocketPixelsTheme.ColorPalette.secondaryText.opacity(0.45))
                }
                .padding(.horizontal, 28)
                .padding(.bottom, size.height * 0.16)
                .allowsHitTesting(false)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 18)
                    .stroke(PocketPixelsTheme.ColorPalette.brandMaroon.opacity(0.28), lineWidth: 1.5)
            }
            .clipShape(RoundedRectangle(cornerRadius: 18))
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
        .shadow(color: PocketPixelsTheme.ColorPalette.amberGlow.opacity(0.12), radius: 14, x: 0, y: 6)
        .accessibilityElement()
        .accessibilityLabel("Signature pad")
        .accessibilityValue(signature.isEmpty ? "Empty" : "Signed")
        .accessibilityHint("Draw your signature with your finger or Apple Pencil. Signing is optional; you can continue without one.")
        .accessibilityAddTraits(.allowsDirectInteraction)
    }
}
