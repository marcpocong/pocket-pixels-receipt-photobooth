//
//  PassportDetailsView.swift
//  PocketPixelsBooth
//
//  Kiosk-friendly Photo Pass details: the customer's name and an optional short note. Date,
//  event and location are filled in from the event profile and shown read-only.
//

import SwiftUI

struct PassportDetailsView: View {
    @ObservedObject var viewModel: BoothSessionViewModel
    let onCancel: () -> Void

    @FocusState private var focusedField: Field?

    enum Field: Hashable, CaseIterable {
        case name
        case notes
    }

    var body: some View {
        GeometryReader { proxy in
            let contentWidth = max(1, min(proxy.size.width - PocketPixelsTheme.Spacing.screenPadding * 2, 720))

            ScrollViewReader { scroll in
                ScrollView {
                    VStack(spacing: 20) {
                        PassportStepHeader(
                            step: 1,
                            title: "Your Photo Pass",
                            subtitle: "Add your name and, if you like, a short note. Both are optional.",
                            isKeyboardVisible: focusedField != nil,
                            onDismissKeyboard: { focusedField = nil },
                            onCancel: onCancel
                        )

                        detailField(
                            .name,
                            title: "NAME",
                            prompt: "Your name",
                            text: binding(\.name, limit: PassportSessionData.nameLimit),
                            limit: PassportSessionData.nameLimit
                        )
                        detailField(
                            .notes,
                            title: "NOTE (OPTIONAL)",
                            prompt: "e.g. Keep this little moment.",
                            text: binding(\.notes, limit: PassportSessionData.notesLimit),
                            limit: PassportSessionData.notesLimit
                        )
                        autoFilledDetails
                    }
                    .frame(width: contentWidth)
                    .padding(.vertical, 28)
                    .frame(maxWidth: .infinity)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: focusedField) { _, field in
                    guard let field else { return }
                    withAnimation(PocketPixelsTheme.Motion.standardAnimation) {
                        scroll.scrollTo(field, anchor: .center)
                    }
                }
                // The action bar rides above the keyboard so Continue is never covered.
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    actionBar(width: contentWidth)
                }
            }
        }
        .padding(.horizontal, PocketPixelsTheme.Spacing.screenPadding)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Button("Previous") { moveFocus(by: -1) }
                    .disabled(focusedField == Field.allCases.first)
                Button("Next") { moveFocus(by: 1) }
                    .disabled(focusedField == Field.allCases.last)
                Spacer()
                Button("Done") { focusedField = nil }
                    .fontWeight(.bold)
            }
        }
    }

    // MARK: Fields

    private func detailField(_ field: Field, title: String, prompt: String, text: Binding<String>, limit: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.system(size: 15, weight: .bold, design: .monospaced))
                    .tracking(1.6)
                    .foregroundStyle(PocketPixelsTheme.ColorPalette.maroon)
                Spacer()
                Text("\(text.wrappedValue.count)/\(limit)")
                    .font(.system(size: 14, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(PocketPixelsTheme.ColorPalette.secondaryText)
                    .accessibilityHidden(true)
            }

            TextField(prompt, text: text, axis: field == .notes ? .vertical : .horizontal)
                .lineLimit(field == .notes ? 1...3 : 1...1)
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(PocketPixelsTheme.ColorPalette.charcoal)
                .textInputAutocapitalization(field == .name ? .words : .sentences)
                .autocorrectionDisabled(field == .name)
                .submitLabel(field == Field.allCases.last ? .done : .next)
                .focused($focusedField, equals: field)
                .onSubmit { moveFocus(by: 1) }
                .padding(.horizontal, 18)
                .padding(.vertical, field == .notes ? 12 : 0)
                .frame(minHeight: 64)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.white.opacity(0.92))
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(
                            focusedField == field ? PocketPixelsTheme.ColorPalette.brandMaroon : PocketPixelsTheme.ColorPalette.border.opacity(0.7),
                            lineWidth: focusedField == field ? 2 : 1
                        )
                }
                .accessibilityLabel(field == .name ? "Name" : "Note")
                .accessibilityHint("Optional. Up to \(limit) characters.")
        }
        .passportCardStyle()
        .id(field)
    }

    /// Read-only event details the operator already configured; the customer never retypes them.
    private var autoFilledDetails: some View {
        let content = viewModel.photoPassAutoFilledContent
        let rows: [(String, String)] = [
            ("DATE", content.date),
            ("EVENT", content.event),
            ("LOCATION", content.location)
        ].filter { !$0.1.isEmpty }

        return VStack(alignment: .leading, spacing: 10) {
            Text("ALSO ON YOUR PASS")
                .font(.system(size: 15, weight: .bold, design: .monospaced))
                .tracking(1.6)
                .foregroundStyle(PocketPixelsTheme.ColorPalette.maroon)
            ForEach(rows, id: \.0) { label, value in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(label.lowercased() + ":")
                        .font(.system(size: 16, weight: .semibold, design: .monospaced))
                        .foregroundStyle(PocketPixelsTheme.ColorPalette.secondaryText)
                        .frame(width: 104, alignment: .leading)
                    Text(value)
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(PocketPixelsTheme.ColorPalette.charcoal)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
            Text("Filled in for you, then you can sign.")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(PocketPixelsTheme.ColorPalette.secondaryText)
        }
        .passportCardStyle()
    }

    private func actionBar(width: CGFloat) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 16) {
                Button("Back to Photos") {
                    focusedField = nil
                    viewModel.backToReview()
                }
                .buttonStyle(PocketPixelsSecondaryButtonStyle())
                .disabled(!viewModel.canReturnToReview)

                Button {
                    focusedField = nil
                    viewModel.continueFromPassportDetails()
                } label: {
                    Text(viewModel.passportDraft.hasAnyDetails ? "Continue" : "Skip Details")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PocketPixelsPrimaryButtonStyle())
                .accessibilityHint("Next, add your signature.")
            }
            .frame(width: width)

            Text("Your name, note and signature stay on your printed keepsake and are not added to your online gallery.")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(PocketPixelsTheme.ColorPalette.secondaryText)
                .multilineTextAlignment(.center)
                .frame(width: width)
        }
        .padding(.top, 14)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity)
        .background(
            PocketPixelsTheme.ColorPalette.paper
                .shadow(color: PocketPixelsTheme.ColorPalette.charcoal.opacity(0.08), radius: 8, x: 0, y: -3)
                .ignoresSafeArea(edges: .bottom)
        )
    }

    // MARK: Bindings

    private func binding(_ keyPath: WritableKeyPath<PassportSessionData, String>, limit: Int) -> Binding<String> {
        Binding {
            viewModel.passportDraft[keyPath: keyPath]
        } set: { value in
            viewModel.passportDraft[keyPath: keyPath] = PassportText.limitedInput(value, limit: limit)
        }
    }

    private func moveFocus(by offset: Int) {
        let fields = Field.allCases
        guard let focusedField, let index = fields.firstIndex(of: focusedField) else {
            self.focusedField = fields.first
            return
        }
        let next = index + offset
        self.focusedField = fields.indices.contains(next) ? fields[next] : nil
    }
}

/// Shared top bar for the three Photo Pass steps.
struct PassportStepHeader: View {
    let step: Int
    let title: String
    let subtitle: String
    var isKeyboardVisible = false
    var onDismissKeyboard: (() -> Void)?
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            HStack(alignment: .center) {
                PocketPixelsLightboxLockup(scale: .compact)
                    .frame(width: 160, alignment: .leading)
                Spacer()
                Text("PHOTO PASS · STEP \(step) OF 3")
                    .font(.system(size: 15, weight: .bold, design: .monospaced))
                    .tracking(1.4)
                    .foregroundStyle(PocketPixelsTheme.ColorPalette.maroon)
                    .accessibilityLabel("Photo Pass, step \(step) of 3")
                Spacer()
                if isKeyboardVisible, let onDismissKeyboard {
                    Button {
                        onDismissKeyboard()
                    } label: {
                        Label("Hide Keyboard", systemImage: "keyboard.chevron.compact.down")
                            .labelStyle(.iconOnly)
                            .font(.system(size: 20, weight: .semibold))
                            .frame(width: 48, height: 48)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(PocketPixelsTheme.ColorPalette.brandMaroon)
                    .accessibilityLabel("Hide keyboard")
                }
                Button("Cancel", action: onCancel)
                    .buttonStyle(PocketPixelsSecondaryButtonStyle())
            }

            Text(title)
                .font(.system(size: 44, weight: .black))
                .foregroundStyle(PocketPixelsTheme.ColorPalette.brandMaroon)
                .multilineTextAlignment(.center)
                .padding(.top, 8)

            Text(subtitle)
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(PocketPixelsTheme.ColorPalette.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

extension View {
    func passportCardStyle() -> some View {
        padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PocketPixelsTheme.ColorPalette.acrylic.opacity(0.94))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .stroke(PocketPixelsTheme.ColorPalette.brandMaroon.opacity(0.18), lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}
