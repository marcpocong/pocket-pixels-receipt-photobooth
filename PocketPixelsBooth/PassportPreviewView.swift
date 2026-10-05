//
//  PassportPreviewView.swift
//  PocketPixelsBooth
//
//  Shows the actual rendered Passport cards (same layout and renderer as the printed receipt),
//  generated once when this screen opens rather than on every edit.
//

import SwiftUI

struct PassportPreviewView: View {
    @ObservedObject var viewModel: BoothSessionViewModel
    let onCancel: () -> Void

    var body: some View {
        GeometryReader { proxy in
            let contentWidth = max(1, min(proxy.size.width - PocketPixelsTheme.Spacing.screenPadding * 2, 760))
            let actionHeight: CGFloat = 170
            let headerHeight: CGFloat = 200
            let previewMaxHeight = max(240, proxy.size.height - actionHeight - headerHeight)

            VStack(spacing: 18) {
                PassportStepHeader(
                    step: 3,
                    title: "Your Pocket Passport",
                    subtitle: "Check your keepsake. You can still edit details or redo your signature.",
                    onCancel: onCancel
                )
                .frame(width: contentWidth)

                preview(maxWidth: min(contentWidth, 560), maxHeight: previewMaxHeight)
                    .frame(maxHeight: .infinity)

                VStack(spacing: 14) {
                    Button {
                        viewModel.continueToReceipt()
                    } label: {
                        Text("Looks Great — Continue")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PocketPixelsPrimaryButtonStyle())
                    .disabled(!viewModel.canContinueToReceipt || viewModel.passportPreviewImage == nil)
                    .accessibilityHint("Builds your printable receipt and gallery.")

                    HStack(spacing: 14) {
                        Button("Back to Details") {
                            viewModel.backToPassportDetails()
                        }
                        .buttonStyle(PocketPixelsSecondaryButtonStyle())

                        Button("Redo Signature") {
                            viewModel.redoPassportSignature()
                        }
                        .buttonStyle(PocketPixelsSecondaryButtonStyle())
                    }
                }
                .frame(width: min(contentWidth, 560))
                .padding(.bottom, 12)
            }
            .padding(.top, 28)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, PocketPixelsTheme.Spacing.screenPadding)
    }

    @ViewBuilder
    private func preview(maxWidth: CGFloat, maxHeight: CGFloat) -> some View {
        if let image = viewModel.passportPreviewImage, image.size.width > 0, image.size.height > 0 {
            let scale = min(maxWidth / image.size.width, maxHeight / image.size.height)
            Image(uiImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: image.size.width * scale, height: image.size.height * scale)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(PocketPixelsTheme.ColorPalette.border.opacity(0.58), lineWidth: 1)
                }
                .shadow(color: PocketPixelsTheme.ColorPalette.amberGlow.opacity(0.14), radius: 18, x: 0, y: 8)
                .accessibilityLabel(previewAccessibilityLabel)
        } else if viewModel.passportPreviewFailed {
            Text("We couldn't prepare the preview. Please ask the booth operator for help.")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(PocketPixelsTheme.ColorPalette.secondaryText)
                .multilineTextAlignment(.center)
                .frame(width: maxWidth, height: min(maxHeight, 320))
        } else {
            VStack(spacing: 14) {
                ProgressView()
                    .tint(PocketPixelsTheme.ColorPalette.maroon)
                    .scaleEffect(1.3)
                Text("Preparing your passport...")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(PocketPixelsTheme.ColorPalette.secondaryText)
            }
            .frame(width: maxWidth, height: min(maxHeight, 320))
        }
    }

    private var previewAccessibilityLabel: String {
        let draft = viewModel.passportDraft
        var parts = ["Pocket Passport preview with your hero photo and passport portrait"]
        if !draft.name.isEmpty { parts.append("Name \(draft.name)") }
        if let birthday = draft.birthday { parts.append("Birthday \(birthday.displayText.capitalized)") }
        if !draft.nationality.isEmpty { parts.append("Nationality \(draft.nationality)") }
        if !draft.profession.isEmpty { parts.append("Profession \(draft.profession)") }
        parts.append(draft.signature.isEmpty ? "No signature" : "Signed")
        return parts.joined(separator: ", ")
    }
}

/// Format-selection artwork: two small stacked landscape passport cards drawn natively.
struct PassportFormatPreview: View {
    let size: CGSize

    var body: some View {
        let gap = size.height * 0.07
        let cardHeight = (size.height - gap) / 2
        let cardWidth = min(size.width, cardHeight * 1.9)

        VStack(spacing: gap) {
            heroCard
                .frame(width: cardWidth, height: cardHeight)
            identityCard
                .frame(width: cardWidth, height: cardHeight)
        }
        .accessibilityHidden(true)
    }

    private var heroCard: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            let inset = height * 0.13
            HStack(spacing: inset) {
                VStack(alignment: .leading, spacing: height * 0.07) {
                    bar(width: width * 0.16, height: height * 0.06, opacity: 0.30)
                    bar(width: width * 0.30, height: height * 0.13, opacity: 0.62)
                    bar(width: width * 0.24, height: height * 0.13, opacity: 0.62)
                    Spacer(minLength: 0)
                    Image(systemName: "star.fill")
                        .font(.system(size: max(6, height * 0.16)))
                        .foregroundStyle(PocketPixelsTheme.ColorPalette.brandMaroon.opacity(0.55))
                }
                .frame(maxHeight: .infinity, alignment: .topLeading)
                photoBlock
                    .frame(width: (height - inset * 2) * 4 / 3)
            }
            .padding(inset)
            .frame(width: width, height: height)
            .background(cardBackground)
        }
    }

    private var identityCard: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            let inset = height * 0.13
            HStack(alignment: .top, spacing: inset) {
                photoBlock
                    .frame(width: (height - inset * 2) * 0.62)
                VStack(alignment: .leading, spacing: height * 0.11) {
                    ForEach(0..<3, id: \.self) { row in
                        VStack(alignment: .leading, spacing: height * 0.03) {
                            bar(width: width * 0.12, height: height * 0.05, opacity: 0.30)
                            bar(width: width * (row == 0 ? 0.42 : 0.32), height: height * 0.07, opacity: 0.55)
                        }
                    }
                    Spacer(minLength: 0)
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: height * 0.06))
                        path.addCurve(to: CGPoint(x: width * 0.26, y: height * 0.02), control1: CGPoint(x: width * 0.08, y: -height * 0.08), control2: CGPoint(x: width * 0.14, y: height * 0.16))
                    }
                    .stroke(PocketPixelsTheme.ColorPalette.brandMaroon.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .frame(height: height * 0.1)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .padding(inset)
            .frame(width: width, height: height)
            .background(cardBackground)
        }
    }

    private var photoBlock: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(PocketPixelsTheme.ColorPalette.brandBlush.opacity(0.55))
            .overlay {
                GeometryReader { proxy in
                    Circle()
                        .fill(PocketPixelsTheme.ColorPalette.paperWarm.opacity(0.75))
                        .frame(width: min(proxy.size.width, proxy.size.height) * 0.42)
                        .position(x: proxy.size.width * 0.5, y: proxy.size.height * 0.42)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 3)
                    .stroke(PocketPixelsTheme.ColorPalette.brandMaroon.opacity(0.28), lineWidth: 1)
            }
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 9)
            .fill(Color.white.opacity(0.9))
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .stroke(PocketPixelsTheme.ColorPalette.brandMaroon.opacity(0.45), lineWidth: 1.5)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(PocketPixelsTheme.ColorPalette.brandMaroon.opacity(0.18), lineWidth: 1)
                    .padding(3)
            }
    }

    private func bar(width: CGFloat, height: CGFloat, opacity: Double) -> some View {
        Capsule()
            .fill(PocketPixelsTheme.ColorPalette.brandMaroon.opacity(opacity))
            .frame(width: max(1, width), height: max(1, height))
    }
}
