//
//  PassportDetailsView.swift
//  PocketPixelsBooth
//
//  Kiosk-friendly keepsake details for the Passport format. Every field is optional.
//

import SwiftUI

struct PassportDetailsView: View {
    @ObservedObject var viewModel: BoothSessionViewModel
    let onCancel: () -> Void

    @FocusState private var focusedField: Field?
    @State private var showsMoreDetails = false

    enum Field: Hashable, CaseIterable {
        case name
        case nationality
        case profession
        case birthplace
    }

    var body: some View {
        GeometryReader { proxy in
            let contentWidth = max(1, min(proxy.size.width - PocketPixelsTheme.Spacing.screenPadding * 2, 720))

            ScrollViewReader { scroll in
                ScrollView {
                    VStack(spacing: 20) {
                        PassportStepHeader(
                            step: 1,
                            title: "Your Pocket Passport",
                            subtitle: "Add a few fun details for your keepsake. Everything is optional.",
                            isKeyboardVisible: focusedField != nil,
                            onDismissKeyboard: { focusedField = nil },
                            onCancel: onCancel
                        )

                        detailField(.name, title: "NAME", prompt: "Your name", text: binding(\.name, limit: PassportSessionData.nameLimit), limit: PassportSessionData.nameLimit)
                        birthdayCard
                        detailField(.nationality, title: "NATIONALITY", prompt: "e.g. Filipino", text: binding(\.nationality, limit: PassportSessionData.nationalityLimit), limit: PassportSessionData.nationalityLimit)
                        detailField(.profession, title: "PROFESSION", prompt: "e.g. Dance Floor Legend", text: binding(\.profession, limit: PassportSessionData.professionLimit), limit: PassportSessionData.professionLimit)

                        moreDetails
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
                    .disabled(focusedField == orderedFields.first)
                Button("Next") { moveFocus(by: 1) }
                    .disabled(focusedField == orderedFields.last)
                Spacer()
                Button("Done") { focusedField = nil }
                    .fontWeight(.bold)
            }
        }
        .onAppear {
            showsMoreDetails = !viewModel.passportDraft.birthplace.isEmpty
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

            TextField(prompt, text: text)
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(PocketPixelsTheme.ColorPalette.charcoal)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled(field == .name)
                .submitLabel(field == orderedFields.last ? .done : .next)
                .focused($focusedField, equals: field)
                .onSubmit { moveFocus(by: 1) }
                .padding(.horizontal, 18)
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
                .accessibilityLabel(title.capitalized)
                .accessibilityHint("Optional. Up to \(limit) characters.")
        }
        .passportCardStyle()
        .id(field)
    }

    private var birthdayCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("BIRTHDAY")
                    .font(.system(size: 15, weight: .bold, design: .monospaced))
                    .tracking(1.6)
                    .foregroundStyle(PocketPixelsTheme.ColorPalette.maroon)
                Spacer()
                if viewModel.passportDraft.birthday != nil || pendingMonth != nil {
                    Button("Clear") {
                        pendingMonth = nil
                        viewModel.passportDraft.birthday = nil
                    }
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(PocketPixelsTheme.ColorPalette.brandMaroon)
                    .accessibilityLabel("Clear birthday")
                }
            }

            Text("Birthday for your keepsake. Add a year to show your age; the year itself isn't printed.")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(PocketPixelsTheme.ColorPalette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                birthdayMenu(title: monthTitle, accessibility: "Birthday month") {
                    Picker("Month", selection: monthBinding) {
                        Text("No month").tag(Int?.none)
                        ForEach(1...12, id: \.self) { month in
                            Text(Self.monthNames[month - 1]).tag(Int?.some(month))
                        }
                    }
                }
                birthdayMenu(title: dayTitle, accessibility: "Birthday day") {
                    Picker("Day", selection: dayBinding) {
                        ForEach(1...PassportBirthday.maximumDay(month: currentMonth ?? 1, year: viewModel.passportDraft.birthday?.year), id: \.self) { day in
                            Text("\(day)").tag(day)
                        }
                    }
                }
                .disabled(currentMonth == nil)
                birthdayMenu(title: yearTitle, accessibility: "Birthday year, optional") {
                    Picker("Year", selection: yearBinding) {
                        Text("No year").tag(Int?.none)
                        ForEach(Array(stride(from: currentYear, through: 1920, by: -1)), id: \.self) { year in
                            Text(String(year)).tag(Int?.some(year))
                        }
                    }
                }
                .disabled(currentMonth == nil)
            }
        }
        .passportCardStyle()
    }

    private func birthdayMenu<Content: View>(title: String, accessibility: String, @ViewBuilder content: () -> Content) -> some View {
        Menu {
            content()
        } label: {
            HStack {
                Text(title)
                    .font(.system(size: 21, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 14, weight: .bold))
            }
            .foregroundStyle(PocketPixelsTheme.ColorPalette.charcoal)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: 58)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.92)))
            .overlay { RoundedRectangle(cornerRadius: 12).stroke(PocketPixelsTheme.ColorPalette.border.opacity(0.7), lineWidth: 1) }
        }
        .accessibilityLabel(accessibility)
        .accessibilityValue(title)
    }

    private var moreDetails: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button {
                withAnimation(PocketPixelsTheme.Motion.standardAnimation) {
                    showsMoreDetails.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: showsMoreDetails ? "minus.circle" : "plus.circle")
                    Text(showsMoreDetails ? "Fewer details" : "Add more details")
                }
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(PocketPixelsTheme.ColorPalette.brandMaroon)
                .frame(minHeight: 48)
            }
            .buttonStyle(.plain)

            if showsMoreDetails {
                detailField(.birthplace, title: "BIRTHPLACE", prompt: "e.g. Cebu City", text: binding(\.birthplace, limit: PassportSessionData.birthplaceLimit), limit: PassportSessionData.birthplaceLimit)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

            Text("These details stay on your printed keepsake and are not added to your online gallery.")
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

    @State private var pendingMonth: Int?

    private var currentMonth: Int? {
        viewModel.passportDraft.birthday?.month ?? pendingMonth
    }

    private var currentYear: Int {
        PassportText.calendar.component(.year, from: Date())
    }

    private var monthBinding: Binding<Int?> {
        Binding {
            currentMonth
        } set: { month in
            guard let month else {
                pendingMonth = nil
                viewModel.passportDraft.birthday = nil
                return
            }
            let existing = viewModel.passportDraft.birthday
            pendingMonth = month
            viewModel.passportDraft.birthday = PassportBirthday(month: month, day: existing?.day ?? 1, year: existing?.year).normalized()
        }
    }

    private var dayBinding: Binding<Int> {
        Binding {
            viewModel.passportDraft.birthday?.day ?? 1
        } set: { day in
            guard let month = currentMonth else { return }
            viewModel.passportDraft.birthday = PassportBirthday(month: month, day: day, year: viewModel.passportDraft.birthday?.year).normalized()
        }
    }

    private var yearBinding: Binding<Int?> {
        Binding {
            viewModel.passportDraft.birthday?.year
        } set: { year in
            guard let month = currentMonth else { return }
            viewModel.passportDraft.birthday = PassportBirthday(month: month, day: viewModel.passportDraft.birthday?.day ?? 1, year: year).normalized()
        }
    }

    private var monthTitle: String {
        currentMonth.map { Self.monthNames[$0 - 1] } ?? "Month"
    }

    private var dayTitle: String {
        guard currentMonth != nil, let day = viewModel.passportDraft.birthday?.day else { return "Day" }
        return "\(day)"
    }

    private var yearTitle: String {
        viewModel.passportDraft.birthday?.year.map(String.init) ?? "Year (optional)"
    }

    private func binding(_ keyPath: WritableKeyPath<PassportSessionData, String>, limit: Int) -> Binding<String> {
        Binding {
            viewModel.passportDraft[keyPath: keyPath]
        } set: { value in
            viewModel.passportDraft[keyPath: keyPath] = PassportText.limitedInput(value, limit: limit)
        }
    }

    private var orderedFields: [Field] {
        showsMoreDetails ? Field.allCases : [.name, .nationality, .profession]
    }

    private func moveFocus(by offset: Int) {
        guard let focusedField, let index = orderedFields.firstIndex(of: focusedField) else {
            self.focusedField = orderedFields.first
            return
        }
        let next = index + offset
        self.focusedField = orderedFields.indices.contains(next) ? orderedFields[next] : nil
    }

    private static let monthNames = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
}

/// Shared top bar for the three Passport steps.
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
                Text("PASSPORT · STEP \(step) OF 3")
                    .font(.system(size: 15, weight: .bold, design: .monospaced))
                    .tracking(1.4)
                    .foregroundStyle(PocketPixelsTheme.ColorPalette.maroon)
                    .accessibilityLabel("Passport, step \(step) of 3")
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
