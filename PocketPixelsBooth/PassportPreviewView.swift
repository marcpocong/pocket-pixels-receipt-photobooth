//
//  PassportPreviewView.swift
//  PocketPixelsBooth
//
//  Shows the actual rendered Photo Pass cards (same ReceiptComposer layout and renderer as the
//  printed receipt), generated once when this screen opens rather than on every edit.
//

import SwiftUI

struct PassportPreviewView: View {
    @ObservedObject var viewModel: BoothSessionViewModel
    let onCancel: () -> Void

    var body: some View {
        GeometryReader { proxy in
            let contentWidth = max(1, min(proxy.size.width - MadeToKeepTheme.Spacing.screenPadding * 2, 760))
            let actionHeight: CGFloat = 170
            let headerHeight: CGFloat = 200
            let previewMaxHeight = max(240, proxy.size.height - actionHeight - headerHeight)

            VStack(spacing: 18) {
                PassportStepHeader(
                    step: 3,
                    title: "Your Photo Pass",
                    subtitle: "Check your keepsake. You can still edit your name, note, or signature.",
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
                    .buttonStyle(MadeToKeepPrimaryButtonStyle())
                    .disabled(!viewModel.canContinueToReceipt || viewModel.passportPreviewImage == nil)
                    .accessibilityHint("Builds your printable receipt and gallery.")

                    HStack(spacing: 14) {
                        Button("Back to Details") {
                            viewModel.backToPassportDetails()
                        }
                        .buttonStyle(MadeToKeepSecondaryButtonStyle())

                        Button("Redo Signature") {
                            viewModel.redoPassportSignature()
                        }
                        .buttonStyle(MadeToKeepSecondaryButtonStyle())
                    }
                }
                .frame(width: min(contentWidth, 560))
                .padding(.bottom, 12)
            }
            .padding(.top, 28)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, MadeToKeepTheme.Spacing.screenPadding)
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
                .overlay {
                    Rectangle()
                        .strokeBorder(MadeToKeepTheme.ColorPalette.hairline, lineWidth: 1)
                }
                .shadow(color: MadeToKeepTheme.ColorPalette.amberGlow.opacity(0.14), radius: 18, x: 0, y: 8)
                .accessibilityLabel(previewAccessibilityLabel)
        } else if viewModel.passportPreviewFailed {
            Text("We couldn't prepare the preview. Please ask the booth operator for help.")
                .font(MadeToKeepTheme.Typography.sans(size: 18, weight: .regular))
                .foregroundStyle(MadeToKeepTheme.ColorPalette.mutedInk)
                .multilineTextAlignment(.center)
                .frame(width: maxWidth, height: min(maxHeight, 320))
        } else {
            VStack(spacing: 14) {
                ProgressView()
                    .tint(MadeToKeepTheme.ColorPalette.maroon)
                    .scaleEffect(1.3)
                Text("preparing your photo pass...")
                    .font(MadeToKeepTheme.Typography.italicSerif(size: 26))
                    .foregroundStyle(MadeToKeepTheme.ColorPalette.secondaryText)
            }
            .frame(width: maxWidth, height: min(maxHeight, 320))
        }
    }

    private var previewAccessibilityLabel: String {
        let draft = viewModel.passportDraft
        let event = viewModel.photoPassAutoFilledContent
        var parts = ["Photo Pass preview with your hero photo and portrait"]
        if !draft.name.isEmpty { parts.append("Name \(draft.name)") }
        parts.append("Date \(event.date.capitalized)")
        if !event.event.isEmpty { parts.append("Event \(event.event.capitalized)") }
        if !event.location.isEmpty { parts.append("Location \(event.location.capitalized)") }
        if !draft.notes.isEmpty { parts.append("Note \(draft.notes)") }
        parts.append(draft.signature.isEmpty ? "No signature" : "Signed")
        return parts.joined(separator: ", ")
    }
}

/// Format-selection artwork: a miniature of the two Photo Pass cards (star borders, vertical
/// script wordmark, hero frame, portrait and field grid), drawn natively at icon size.
struct PassportFormatPreview: View {
    let size: CGSize

    private let ink = MadeToKeepTheme.ColorPalette.brandMaroon

    var body: some View {
        let gap = size.height * 0.04
        let cardHeight = (size.height - gap) / 2
        let cardWidth = min(size.width, cardHeight * 1.53)

        VStack(spacing: gap) {
            heroCard
                .frame(width: cardWidth, height: cardHeight)
            detailsCard
                .frame(width: cardWidth, height: cardHeight)
        }
        .accessibilityHidden(true)
    }

    private var heroCard: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            let inset = height * 0.16
            ZStack(alignment: .topLeading) {
                card(width: width, height: height)
                Text("Photo Pass")
                    .font(.custom("SnellRoundhand-Bold", size: height * 0.22))
                    .foregroundStyle(ink)
                    .fixedSize()
                    .rotationEffect(.degrees(-90))
                    .frame(width: width * 0.2, height: height - inset * 2)
                    .position(x: inset + width * 0.08, y: height / 2)
                frame(width: width * 0.6, height: height * 0.66)
                    .position(x: width * 0.6, y: height * 0.5)
                star(size: height * 0.16)
                    .position(x: width * 0.88, y: height * 0.2)
                star(size: height * 0.15)
                    .position(x: width * 0.31, y: height * 0.8)
            }
        }
    }

    private var detailsCard: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            ZStack(alignment: .topLeading) {
                card(width: width, height: height)
                frame(width: width * 0.27, height: height * 0.56)
                    .position(x: width * 0.22, y: height * 0.4)
                Text("Photo Pass")
                    .font(.custom("SnellRoundhand-Bold", size: height * 0.12))
                    .foregroundStyle(ink)
                    .fixedSize()
                    .position(x: width * 0.22, y: height * 0.8)
                VStack(spacing: 0) {
                    ForEach(0..<5, id: \.self) { row in
                        Rectangle()
                            .stroke(ink.opacity(0.6), lineWidth: 0.8)
                            .frame(height: height * (row == 2 || row == 3 ? 0.17 : 0.13))
                    }
                }
                .frame(width: width * 0.52)
                .position(x: width * 0.69, y: height * 0.5)
            }
        }
    }

    private func card(width: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: height * 0.08)
            .fill(Color.white.opacity(0.95))
            .overlay {
                RoundedRectangle(cornerRadius: height * 0.08)
                    .stroke(ink.opacity(0.8), lineWidth: 1.6)
            }
            .overlay {
                // Dotted inner border stands in for the printed star border at this size.
                RoundedRectangle(cornerRadius: height * 0.05)
                    .stroke(ink.opacity(0.55), style: StrokeStyle(lineWidth: 1.4, lineCap: .round, dash: [0.1, height * 0.06]))
                    .padding(height * 0.065)
            }
            .frame(width: width, height: height)
    }

    private func frame(width: CGFloat, height: CGFloat) -> some View {
        Rectangle()
            .fill(MadeToKeepTheme.ColorPalette.brandBlush.opacity(0.4))
            .overlay { Rectangle().stroke(ink.opacity(0.7), lineWidth: 1) }
            .frame(width: width, height: height)
    }

    private func star(size: CGFloat) -> some View {
        Image(systemName: "star.fill")
            .font(.system(size: size))
            .foregroundStyle(ink)
    }
}
