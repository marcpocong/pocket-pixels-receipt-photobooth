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
