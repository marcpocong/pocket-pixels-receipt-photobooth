import SwiftUI

/// Legacy persisted stage values remain readable for older navigation/draft consumers.
/// The workspace no longer requires progressing through these stages.
nonisolated enum OperatorSetupStage: Int, CaseIterable, Identifiable, Sendable {
    case details, payment, experience, review
    var id: Int { rawValue }
    var title: String {
        switch self { case .details: "Event Details"; case .payment: "Payment & Prints"; case .experience: "Receipt & Branding"; case .review: "Review & Start" }
    }
}

struct SessionSetupView: View {
    @StateObject private var setup: SessionSetupCoordinator
    @ObservedObject private var workspace: OperatorWorkspace
    @ObservedObject private var acceptance: SessionAcceptanceStore
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var devicePrintOptions = ReceiptPrintSettingsStore.load()
    @State private var previewSelection = ReceiptPreviewSelection()
    @State private var review = false
    @Environment(\.dismiss) private var dismiss
    private let opensNewEventDraft: Bool
    @State private var previousEventPicker = false
    @State private var confirmDiscard = false
    @State private var paymentExpanded = false
    @State private var receiptExpanded = false
    @State private var guestExpanded = false
    @State private var galleryExpanded = false
    @State private var reviewExpanded = false
    @State private var validationAttempt = false
    @FocusState private var eventNameFocused: Bool
    init(eventID: String? = nil, coordinator: SessionSetupCoordinator? = nil, opensNewEventDraft: Bool = false, editingLiveEvent: Bool = false, usePreviousEvent: Bool = false) {
        // StateObject owns construction: parent view updates must not recreate a coordinator
        // and reload configuration while its existing operation is still running.
        _setup = StateObject(wrappedValue: coordinator ?? SessionSetupCoordinator(eventID: eventID, editingLiveEvent: editingLiveEvent))
        let workspace = coordinator?.workspaceForEditing ?? .shared
        _workspace = ObservedObject(wrappedValue: workspace)
        _acceptance = ObservedObject(wrappedValue: coordinator?.acceptanceForPresentation ?? .shared)
        self.opensNewEventDraft = opensNewEventDraft
        _previousEventPicker = State(initialValue: usePreviousEvent)

    }

    var body: some View {
        ScrollViewReader { reader in
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if setup.busy {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(setup.phase.rawValue + "…")
                        Text("You can leave this screen. The operation continues; leaving does not cancel a server change.").font(.footnote).foregroundStyle(.secondary)
                    }.accessibilityIdentifier("event-operation-phase")
                } else if !setup.message.isEmpty && !setup.editingLiveEvent {
                    Text(setup.message).font(.callout).accessibilityIdentifier("event-operation-result")
                }
                if let pending = setup.pendingCreation { CreationRecoveryCard(setup: setup, intent: pending) }
                ForEach(setup.creationsElsewhere) { other in
                    SetupCard {
                        Label("A paid-event creation on another payments connection needs confirmation", systemImage: "arrow.left.arrow.right.circle").font(.headline).foregroundStyle(OperatorPalette.warning)
                        Text("\"\(other.name)\" was requested on \(other.serverBinding.hasPrefix("live:") ? "LIVE" : "TEST"). Switch back to that connection to resolve it; nothing from it is attached here.").font(.callout)
                    }
                }
                if setup.needsRefresh {
                    SetupCard {
                        Label("Action Needs Review", systemImage: "exclamationmark.arrow.circlepath").font(.headline).foregroundStyle(OperatorPalette.warning)
                        Text(setup.message)
                        Button("Check Current Status") { Task { await setup.refresh() } }.buttonStyle(.borderedProminent)
                    }
                }
                eventSection.disabled(setup.busy).id("event-details")
                if setup.design != nil {
                    workspacePanels
                }
            }
            .frame(maxWidth: 980, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("event-workspace-scroll")
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done Editing") { endEditing() }.accessibilityIdentifier("event-finish-editing")
            }
        }
        .onChange(of: validationAttempt) { _, _ in reader.scrollTo("event-details", anchor: .top) }
        .navigationTitle(setup.editingLiveEvent ? "Edit Live Event" : (opensNewEventDraft ? "New Event" : "Edit Event"))
        .navigationBarTitleDisplayMode(.inline)
        .tint(OperatorPalette.ink)
        .background(OperatorPalette.canvas)
        .safeAreaInset(edge: .top) {
            VStack(spacing: 8) {
                if setup.editingLiveEvent, !setup.busy, !setup.message.isEmpty {
                    OperatorFeedbackBanner(feedback: .init(message: setup.message, isError: setup.needsRefresh)) { setup.clearMessage() }
                        .padding(.horizontal).padding(.top, 8)
                }
                if receiptExpanded {
                    SetupCard {
                        HStack {
                            Text("Live Receipt Preview").font(.headline)
                            Spacer()
                            Button("Close Receipt Controls") { endEditing(); receiptExpanded = false }.font(.callout).frame(minHeight: 44)
                        }
                        EventReceiptComposerPreview(profile: setup.effectiveProfile, printOptions: devicePrintOptions, compact: true, selection: $previewSelection)
                    }.accessibilityElement(children: .contain).accessibilityIdentifier("event-pinned-preview")
                        .padding(.horizontal, 24).padding(.vertical, 8)
                }
            }.background(OperatorPalette.canvas)
        }
        .safeAreaInset(edge: .bottom) { bottomBar }
        .task {
            if opensNewEventDraft { await setup.prepareNewWorkspace() }
            else if setup.mode == .serverManaged { await setup.refresh() }
        }
        .onDisappear { workspace.checkpoint() }
        .onAppear { setup.reloadDesignFromStorage(); devicePrintOptions = ReceiptPrintSettingsStore.load() }
        .onReceive(NotificationCenter.default.publisher(for: ReceiptPrintSettingsStore.didChangeNotification)) { _ in
            devicePrintOptions = ReceiptPrintSettingsStore.load()
        }
        .onReceive(NotificationCenter.default.publisher(for: OperatorWorkspace.didUnlock)) { _ in
            if setup.mode == .serverManaged { Task { await setup.refresh() } }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { review = false; confirmDiscard = false; workspace.checkpoint() }
        }

        .sheet(isPresented: $review) { reviewSheet }
        .sheet(isPresented: $previousEventPicker) {
            NavigationStack {
                List(setup.savedEvents) { event in
                    Button(event.displayName) {
                        previousEventPicker = false
                        Task { await setup.prepareNewWorkspace(templateID: event.id) }
                    }.frame(minHeight: 44)
                }.navigationTitle("Use Previous Event")
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { previousEventPicker = false } } }
            }
        }
        .confirmationDialog("Discard this event's local edits?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard & Reload", role: .destructive) { Task { await setup.discardPaidEdits() } }
        } message: { Text("Reloads saved settings for this event. Nothing is applied to guests.") }

        }
    }

    // MARK: Header

    private var header: some View {
        let applied = setup.editingLiveEvent ? !setup.hasUnsavedChanges : setup.isCurrentlyApplied
        return HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(setup.design?.displayName ?? "New Event").font(.system(.title2, design: .serif).weight(.semibold))
                Text(setup.editingLiveEvent ? "Applies to future guests. Current sessions keep their settings." : "Configure, preview, then review and start.")
                    .font(.callout).foregroundStyle(OperatorPalette.secondaryText)
                if acceptance.state.blocked { StatusPill(text: "New sessions paused", systemImage: "pause.circle.fill", color: OperatorPalette.warning) }
            }
            Spacer(minLength: 12)
            if applied && setup.design != nil { StatusPill(text: "Applied", systemImage: "checkmark.circle.fill", color: OperatorPalette.ready) }
        }
    }

    // MARK: 1. Session / Event

    @ViewBuilder private var eventSection: some View {
        SetupCard {
            if let design = Binding($setup.design) {
                LabeledField(title: "Event name") {
                    TextField("Event name", text: limited(design.name, EventProfile.eventNameLimit))
                        .accessibilityIdentifier("event-name").focused($eventNameFocused)
                }
                if design.wrappedValue.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Enter an event name.").font(.footnote).foregroundStyle(OperatorPalette.warning)
                }
                LabeledField(title: "Venue (optional)") {
                    TextField("Venue (optional)", text: limited(design.venue, EventProfile.locationLimit))
                }
                Label(workspace.persistenceError != nil ? "Save Failed — retry Save for Later" : (workspace.savingDraft ? "Saving…" : "Saved on this iPad"),
                      systemImage: workspace.persistenceError != nil ? "exclamationmark.triangle" : "checkmark.icloud")
                    .font(.footnote).accessibilityIdentifier("event-draft-status")
            } else {
                Button("New Event") { Task { await setup.prepareNewWorkspace() } }.buttonStyle(.borderedProminent)
                Text("Regular Booth defaults can also be edited from Booth → Receipt & Footer.").font(.footnote)
            }
        }
    }

    @ViewBuilder private var workspacePanels: some View {
        inlineSection("Payment & Prints", summary: "\(setup.paymentChoice.title) · \(copiesSummary)", id: "event-payment-prints", expanded: $paymentExpanded) {
            paymentSection
        }
        SetupCard {
            sectionHeading("Receipt Design", summary: setup.effectiveProfile.receiptDesign.typography.preset.displayName,
                           id: "event-customize-receipt", expanded: $receiptExpanded)
            if !receiptExpanded { EventReceiptComposerPreview(profile: setup.effectiveProfile, printOptions: devicePrintOptions, compact: true, selection: $previewSelection) }
            if receiptExpanded { EventDesignEditorView(setup: setup, inline: true, showsPreview: false) }
        }.disabled(setup.busy)
        inlineSection("Guest Experience", summary: "\(setup.design?.guestScreensEnabled == true ? "Event welcome" : "Studio welcome") · Stickers \(stickerEnabled ? "enabled" : "disabled")", id: "event-guest-experience", expanded: $guestExpanded) {
            if let design = Binding($setup.design) {
                guestScreens(design)
                Divider()
                Button { design.wrappedValue.profile.stickerStudioEnabled = !stickerEnabled } label: {
                    HStack {
                        Label("Sticker Studio", systemImage: stickerEnabled ? "checkmark.circle.fill" : "circle")
                        Spacer()
                        Text(stickerEnabled ? "Enabled" : "Disabled")
                    }.frame(maxWidth: .infinity, minHeight: 44)
                }.buttonStyle(.bordered)
                    .accessibilityAddTraits(stickerEnabled ? .isSelected : [])
                    .accessibilityIdentifier("event-sticker-studio")
                    .accessibilityValue(stickerEnabled ? "Enabled" : "Disabled")
                Text("Allow guests to add stickers and emoji before printing, or skip this step.").font(.footnote).foregroundStyle(.secondary)
                if stickerEnabled {
                    LabeledContent("Guest sticker limit", value: "\(StickerStudioSettingsStore.load().guestStickerLimit)")
                    LabeledContent("Collections", value: stickerCollections)
                }
                CustomerExperiencePreviewView(profile: setup.effectiveProfile)
            }
        }
        inlineSection("Gallery & QR", summary: (setup.effectiveProfile.receiptDesign.footerStyleOverride ?? devicePrintOptions.footerStyle).displayName,
                      id: "event-gallery-qr", expanded: $galleryExpanded) {
            EventGalleryPresentationControls(setup: setup)
        }
        inlineSection("Review", summary: setup.validation ?? "Ready to review and start", id: "event-review-summary", expanded: $reviewExpanded) {
            SetupSummaryRows(setup: setup)
        }
    }

    private var copiesSummary: String {
        let count = setup.mode == .localPrepaid ? setup.prepaid.activePolicy.defaultCopies : setup.policy.defaultCopies
        return "\(count) \(count == 1 ? "copy" : "copies")"
    }

    private var stickerEnabled: Bool { setup.design?.profile.stickerStudioEnabled ?? StickerStudioSettingsStore.load().isEnabled }

    private var stickerCollections: String {
        let settings = StickerStudioSettingsStore.load()
        return [settings.emojiCollectionEnabled ? "Emoji" : nil, settings.builtInStickersEnabled ? "Built-in" : nil,
                settings.operatorCollectionEnabled ? "Operator library" : nil].compactMap { $0 }.joined(separator: " · ")
    }

    private func inlineSection<Content: View>(_ title: String, summary: String, id: String, expanded: Binding<Bool>, @ViewBuilder content: @escaping () -> Content) -> some View {
        SetupCard {
            sectionHeading(title, summary: summary, id: id, expanded: expanded)
            if expanded.wrappedValue { Divider(); content() }
        }.disabled(setup.busy)
    }

    private func sectionHeading(_ title: String, summary: String, id: String, expanded: Binding<Bool>) -> some View {
        Button { endEditing(); expanded.wrappedValue.toggle() } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline)
                    Text(summary).font(.caption).foregroundStyle(OperatorPalette.secondaryText).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 8)
                Image(systemName: expanded.wrappedValue ? "chevron.up" : "chevron.down")
            }.frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier(id).accessibilityValue(expanded.wrappedValue ? "Expanded" : "Collapsed")
    }

    @ViewBuilder private func guestScreens(_ design: Binding<SavedEventDesign>) -> some View {
        Toggle(isOn: design.guestScreensEnabled) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Event Welcome & Thank-you").font(.headline)
                Text("Show the event name and your messages on the guest welcome and thank-you screens.").font(.callout).foregroundStyle(OperatorPalette.secondaryText)
            }
        }
        .toggleStyle(.switch)
        if design.wrappedValue.guestScreensEnabled {
            Group {
                VStack(spacing: 12) {
                    TextField("Title (defaults to event name)", text: limited(design.profile.customerTitle, EventProfile.customerTitleLimit))
                    TextField("Subtitle", text: limited(design.profile.customerSubtitle, EventProfile.customerSubtitleLimit))
                    TextField("Welcome message", text: limited(design.profile.customerWelcomeMessage, EventProfile.customerMessageLimit))
                    TextField("Thank-you message", text: limited(design.profile.customerThankYouMessage, EventProfile.customerMessageLimit))
                    Picker("Theme", selection: design.profile.customerTheme) {
                        ForEach(CustomerScreenTheme.allCases) { Text($0.displayName).tag($0) }
                    }
                }
                .textFieldStyle(.roundedBorder)
                .padding(.top, 8)
            }
            .font(.callout)
        }
    }

    // MARK: 2. Payment

    @ViewBuilder private var paymentSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("How will guests pay?").font(.title3.weight(.semibold))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: typeSize.isAccessibilitySize ? 1 : 2), spacing: 10) {
                ForEach(GuestPaymentChoice.allCases.filter { !setup.editingLiveEvent || $0.isPaid == (setup.mode == .serverManaged) }) { choice in
                    PaymentOptionCard(choice: choice, selected: setup.paymentChoice == choice) { endEditing(); Task { await setup.choosePayment(choice) } }
                }
            }
            Divider()
            if setup.mode == .localPrepaid { freeSettings } else { paidSettings }
            if setup.paymentChoice == .qrOnly {
                Toggle("Unattended · QR Ph only", isOn: $setup.unattendedQR)
                Text("Checks camera, printer, connection and checkout storage before issuing a payment QR. Guests can save an unresolved checkout for owner-assisted recovery.").font(.footnote).foregroundStyle(OperatorPalette.secondaryText)
            }
        }
    }

    @ViewBuilder private var freeSettings: some View {
        Label("No guest payment required.", systemImage: "gift").font(.headline)
        SetupCopyControl(title: "Included copies", value: $setup.prepaid.activePolicy.defaultCopies, range: 1...setup.prepaid.activePolicy.maxCopies)
        SetupCopyControl(title: "Maximum copies", value: Binding(get: { setup.prepaid.activePolicy.maxCopies }, set: {
            setup.prepaid.activePolicy.maxCopies = $0; setup.prepaid.activePolicy.defaultCopies = min(setup.prepaid.activePolicy.defaultCopies, $0)
        }), range: PaymentPolicySnapshot.copyRange)
        Toggle("Allow guests to choose copies", isOn: $setup.prepaid.activePolicy.prepaidGuestCopyChoice)
        formatChips(isOn: { setup.prepaid.activePolicy.supports($0) }, set: { format, enabled in
            var formats = setup.prepaid.activePolicy.supportedFormatRawValues
            formats.removeAll { $0 == format.rawValue }; if enabled { formats.append(format.rawValue) }
            setup.prepaid.activePolicy.supportedFormatRawValues = formats
        })
        Text("Works without a payments connection.").font(.footnote).foregroundStyle(OperatorPalette.secondaryText)
    }

    @ViewBuilder private var paidSettings: some View {
        if setup.targetServerEventID == nil {
            Text("Payments are prepared automatically after Review & Start. Saving a draft stays on this iPad.").font(.footnote)
        }
        if setup.targetServerEventID == nil || setup.detail != nil {
            HStack {
                Text("Price per copy").font(.headline)
                Spacer()
                Text("₱")
                TextField("0.00", text: $setup.policy.priceText).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                    .font(.title3.monospacedDigit()).frame(maxWidth: 160).textFieldStyle(.roundedBorder)
            }
            SetupCopyControl(title: "Default copies", value: $setup.policy.defaultCopies, range: 1...setup.policy.maxCopies)
            SetupCopyControl(title: "Maximum copies", value: Binding(get: { setup.policy.maxCopies }, set: {
                setup.policy.maxCopies = $0; setup.policy.defaultCopies = min(setup.policy.defaultCopies, $0)
            }), range: PaymentPolicySnapshot.copyRange)
            formatChips(isOn: { setup.policy.supports($0) }, set: { setup.policy.setFormat($0, enabled: $1) })
            totalPreview
            Label(setup.paymentChoice.methodSummary, systemImage: "checkmark.shield").font(.callout)
            if setup.paymentChoice.acceptsCash {
                Text("Online cash is declared by the customer before the camera opens. It is not verified payment. Signed offline cash still requires attendant authentication.")
                    .font(.footnote).foregroundStyle(OperatorPalette.secondaryText)
            }
            DisclosureGroup("Advanced Payment Options") {
                VStack(alignment: .leading, spacing: 12) {
                    if setup.paymentChoice.acceptsCash {
                        Toggle("Allow signed offline cash", isOn: $setup.policy.offlineCashEnabled)
                        if setup.policy.offlineCashEnabled {
                            DatePicker("Offline cash allowed until", selection: $setup.policy.offlineValidUntil, in: Date()...)
                            Text("Offline permissions are signed and time-limited. A disconnected iPad learns of a pause when it reconnects.").font(.footnote).foregroundStyle(OperatorPalette.secondaryText)
                        }
                    }
                    if !setup.eventModeEnabled {
                        Picker("Paid sessions record", selection: Binding(get: { setup.selectedID ?? "" }, set: { id in Task { await setup.select(id) } })) {
                            ForEach(setup.events.filter { !["ENDED", "ARCHIVED"].contains($0.lifecycle) }) { Text($0.name).tag($0.id) }
                        }
                    }
                    Button("Check Current Status") { Task { await setup.refresh() } }
                }
                .padding(.top, 8)
            }
            .font(.callout)
            if setup.conflict, let detail = setup.detail, let latest = detail.latestRevision {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Server Settings Changed — Review Required", systemImage: "exclamationmark.triangle.fill").font(.headline).foregroundStyle(OperatorPalette.warning)
                    Text("Your edits are retained. Compare them with the saved settings before continuing.")
                    LabeledContent("Saved name / venue", value: "\(detail.event.name) · \(detail.event.venue)")
                    LabeledContent("Saved price", value: PHPPriceFormatter.string(centavos: latest.unitPriceCentavos))
                    LabeledContent("Saved copies", value: "Default \(latest.defaultCopies) · maximum \(latest.maxCopies)")
                    LabeledContent("Saved methods", value: paymentMethods(latest.qrphEnabled, latest.cashEnabled))
                    LabeledContent("Saved offline cash", value: latest.offlineValidUntil.map { $0.formatted() } ?? "Disabled")
                    LabeledContent("Saved formats", value: formatNames(latest.supportedFormats))
                    HStack {
                        Button("I've Reviewed — Keep My Edits") { setup.keepReviewedEdits() }.buttonStyle(.borderedProminent).disabled(setup.needsRefresh)
                        Button("Discard My Edits…", role: .destructive) { confirmDiscard = true }.buttonStyle(.bordered)
                    }
                }
                .padding(14)
                .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
            }
        } else {
            HStack(spacing: 12) {
                ProgressView()
                Text("Loading paid settings…").foregroundStyle(OperatorPalette.secondaryText)
                Spacer()
                Button("Check Current Status") { Task { await setup.refresh() } }
            }
        }
    }

    @ViewBuilder private var totalPreview: some View {
        if let price = setup.policy.unitPriceCentavos, price > 0 {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(1...max(1, min(10, setup.policy.maxCopies)), id: \.self) { count in
                        VStack(spacing: 2) {
                            Text("\(count) \(count == 1 ? "copy" : "copies")").font(.caption).foregroundStyle(OperatorPalette.secondaryText)
                            Text(PHPPriceFormatter.string(centavos: price * count)).font(.callout.weight(.semibold).monospacedDigit())
                        }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
        } else {
            Text("Enter a valid price to see guest totals.").font(.callout).foregroundStyle(OperatorPalette.secondaryText)
        }
    }

    private func formatChips(isOn: @escaping (BoothFormat) -> Bool, set: @escaping (BoothFormat, Bool) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Available formats").font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 10)], spacing: 10) {
                ForEach(BoothFormat.allCases, id: \.self) { format in
                    let enabled = isOn(format)
                    Button { set(format, !enabled) } label: {
                        Label(format.displayName, systemImage: enabled ? "checkmark.circle.fill" : "circle")
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(enabled ? OperatorPalette.selected : Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
                            .overlay { RoundedRectangle(cornerRadius: 10).stroke(enabled ? OperatorPalette.ink : .clear, lineWidth: 1.5) }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(enabled ? .isSelected : [])
                }
            }
        }
    }

    private var bottomBar: some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 12))
        return layout {
            if setup.editingLiveEvent {
                Button("Cancel Changes") { setup.cancelLiveChanges() }
                    .buttonStyle(.bordered).disabled(setup.busy || setup.needsRefresh).frame(minHeight: 48)
                Button {
                    if setup.mode == .serverManaged && setup.dirtyPaid { review = true }
                    else { Task { _ = await setup.applyLiveChanges() } }
                } label: {
                    Text("Apply to Next Sessions").font(.headline).frame(maxWidth: .infinity, minHeight: 48)
                }.buttonStyle(.borderedProminent)
                    .disabled(setup.busy || !setup.hasUnsavedChanges || setup.validation != nil)
                    .accessibilityIdentifier("apply-live-event")
            } else {
            Button {
                Task { if await setup.saveForLater() { dismiss() } }
            } label: { Text("Save for Later").frame(minHeight: 44) }
                .buttonStyle(.bordered).disabled(setup.busy || setup.design == nil)
                .accessibilityIdentifier("save-setup-draft")
            Button {
                endEditing()
                if setup.design?.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true { validationAttempt.toggle(); eventNameFocused = true }
                else { review = true }
            } label: {
                Label("Review & Start", systemImage: "play.fill").font(.headline).frame(maxWidth: .infinity, minHeight: 48)
            }.buttonStyle(.borderedProminent).disabled(setup.busy || setup.design == nil)
                .accessibilityIdentifier("review-setup")
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 10).background(.regularMaterial).tint(OperatorPalette.ink)
    }

    private var reviewSheet: some View {
        SessionSetupReviewView(setup: setup, onBack: { review = false }, onFinished: { started in
            review = false
            if started && !setup.editingLiveEvent { NotificationCenter.default.post(name: OperatorWorkspace.didStartSessions, object: nil) }
        })
    }

    private func endEditing() {
        eventNameFocused = false
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private func limited(_ text: Binding<String>, _ limit: Int) -> Binding<String> {
        Binding(get: { text.wrappedValue }, set: { text.wrappedValue = String($0.prefix(limit)) })
    }
}

/// The reviewed setup as rows; shared by the summary card and the review sheet.
struct SetupSummaryRows: View {
    @ObservedObject var setup: SessionSetupCoordinator
    @ObservedObject private var printer = PrinterCoordinator.shared
    @ObservedObject private var operations = EventOperationalState.shared

    var body: some View {
        let design = setup.design
        LabeledContent("Session", value: setup.eventModeEnabled ? "Event" : "Regular Booth")
        if setup.eventModeEnabled { LabeledContent("Event", value: design?.displayName ?? "None selected") }
        LabeledContent("Payment", value: setup.paymentChoice.methodSummary)
        if setup.mode == .serverManaged {
            LabeledContent("Price per copy", value: setup.policy.unitPriceCentavos.map { PHPPriceFormatter.string(centavos: $0) } ?? "Invalid price")
            LabeledContent("Copies", value: "Default \(setup.policy.defaultCopies) · maximum \(setup.policy.maxCopies)")
            LabeledContent("Offline cash", value: setup.policy.offlineCashEnabled && setup.paymentChoice.acceptsCash ? "Enabled until \(setup.policy.offlineValidUntil.formatted())" : "Disabled")
            LabeledContent("Formats", value: formatNames(Array(setup.policy.supportedFormats)))
            LabeledContent("Payments environment", value: PaymentsConfiguration.current()?.environment.uppercased() ?? "Not connected")
        } else {
            LabeledContent("Included / maximum copies", value: "\(setup.prepaid.activePolicy.defaultCopies) / \(setup.prepaid.activePolicy.maxCopies)")
            LabeledContent("Guest copy choice", value: setup.prepaid.activePolicy.prepaidGuestCopyChoice ? "Allowed" : "Fixed included quantity")
            LabeledContent("Formats", value: formatNames(setup.prepaid.activePolicy.supportedFormatRawValues))
        }
        let personalized = setup.eventModeEnabled && design?.personalizeReceipt == true
        LabeledContent("Personalized receipt", value: personalized ? "On" : "Off — Made to Keep standard")
        if personalized {
            LabeledContent("Event logo", value: setup.logoIsUsable ? "Ready" : (design?.logoIdentifier == nil ? "Missing" : "Can’t be read"))
            LabeledContent("Receipt layout", value: design?.layout.displayName ?? "")
        }
        LabeledContent("Receipt caption", value: design?.profile.receiptDesign.editorialCaption.isEmpty == false ? design!.profile.receiptDesign.editorialCaption : "None")
        LabeledContent("Gallery code", value: (design?.profile.receiptDesign.footerStyleOverride ?? ReceiptPrintSettingsStore.load().footerStyle).displayName)
        LabeledContent("Guest experience", value: setup.eventModeEnabled && design?.guestScreensEnabled == true ? "Event welcome screens" : "Made to Keep standard")
        let stickers = setup.eventModeEnabled ? (design?.profile.stickerStudioEnabled ?? StickerStudioSettingsStore.load().isEnabled) : StickerStudioSettingsStore.load().isEnabled
        LabeledContent("Sticker Studio", value: stickers ? "Enabled" : "Disabled")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Sticker Studio")
            .accessibilityValue(stickers ? "Enabled" : "Disabled")
            .accessibilityIdentifier("review-sticker-status")
        LabeledContent("Status", value: setup.isCurrentlyApplied ? "Currently applied" : (setup.hasUnsavedChanges ? "Changes staged" : "Saved — not yet applied"))
        Divider()
        LabeledContent("Camera check", value: operations.cameraCheckPassed ? "Checked this foreground session" : "Not checked — use Booth Check")
        LabeledContent("Printer", value: printer.operatorState.label)
        LabeledContent("Gallery connectivity", value: operations.queueError != nil ? "Upload storage needs review" : "\(operations.networkPathStatus) · \(operations.pendingUploadCount) waiting on this iPad")
        if let reason = setup.validation {
            Label(reason, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(OperatorPalette.warning)
        }
    }
}

struct SessionSetupReviewView: View {
    @ObservedObject var setup: SessionSetupCoordinator
    let onBack: () -> Void
    let onFinished: (Bool) -> Void
    private var needsOccurrenceChoice: Bool {
        if case .requiresNewOccurrence = setup.occurrencePlan { return !setup.startsNewOccurrence }
        return false
    }
    var body: some View {
        NavigationStack {
            Form {
                if setup.busy { Section { ProgressView(setup.phase.rawValue + "…"); Text("Leaving this review does not cancel the operation.").font(.footnote) } }
                Section("Your Next Guest Session") { SetupSummaryRows(setup: setup) }
                Section("Event Run") {
                    Text(setup.occurrenceSummary)
                    if case .requiresNewOccurrence = setup.occurrencePlan {
                        Toggle("Start New Occurrence — fresh statistics", isOn: $setup.startsNewOccurrence).frame(minHeight: 44)
                            .accessibilityIdentifier("start-new-occurrence")
                    }
                }
                Section("Receipt Preview") {
                    EventReceiptComposerPreview(profile: setup.effectiveProfile, printOptions: ReceiptPrintSettingsStore.load(), showsSamplePrintLink: false, maximumPreviewWidth: 300, compact: true)
                }
                Section {
                    Text("This starts new guest sessions with the setup shown above. Sessions already in progress keep their original design and purchased entitlement.")
                    if let validation = setup.validation { Text(validation).foregroundStyle(OperatorPalette.warning) }
                    if setup.needsRefresh {
                        Text(setup.message)
                        Button("Check Current Status") { Task { await setup.refresh() } }
                    }
                    if setup.canStartNewPaidOccurrence {
                        Button("Start New Paid Occurrence") { Task { await setup.startNewPaidOccurrence() } }
                    }
                }
            }
            .accessibilityIdentifier("event-review-form")
            .safeAreaInset(edge: .bottom) {
                    Button {
                        Task {
                            let started = setup.editingLiveEvent ? await setup.applyLiveChanges() : await setup.startAccepting()
                            if started { onFinished(true) }
                        }
                    } label: { Text(setup.editingLiveEvent ? "Apply to Next Sessions" : "Start Accepting Guests").font(.headline).frame(maxWidth: .infinity, minHeight: 48) }
                    .buttonStyle(.borderedProminent).disabled(setup.busy || setup.validation != nil || needsOccurrenceChoice)
                .padding().background(.regularMaterial)
            }
            .navigationTitle(setup.editingLiveEvent ? "Review Live Changes" : "Review Setup").navigationBarTitleDisplayMode(.inline).tint(OperatorPalette.ink)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Back to Setup") { onBack() } } }
        }
    }
}

// MARK: Building blocks

private struct SetupCopyControl: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 12))
        layout {
            Text(title).frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 4) {
                Button { value = max(range.lowerBound, value - 1) } label: {
                    Image(systemName: "minus").frame(width: 44, height: 44)
                        .background(OperatorPalette.selected, in: RoundedRectangle(cornerRadius: 10))
                        .foregroundStyle(value <= range.lowerBound ? Color.secondary : OperatorPalette.ink).contentShape(Rectangle())
                }.disabled(value <= range.lowerBound).accessibilityLabel("Decrease " + title.lowercased())
                Text("\(value)").monospacedDigit().frame(minWidth: 36).accessibilityLabel("\(title): \(value)")
                Button { value = min(range.upperBound, value + 1) } label: {
                    Image(systemName: "plus").frame(width: 44, height: 44)
                        .background(OperatorPalette.selected, in: RoundedRectangle(cornerRadius: 10))
                        .foregroundStyle(value >= range.upperBound ? Color.secondary : OperatorPalette.ink).contentShape(Rectangle())
                }.disabled(value >= range.upperBound).accessibilityLabel("Increase " + title.lowercased())
            }.buttonStyle(.plain).fixedSize(horizontal: true, vertical: false)
        }
    }
}

private struct SetupCard<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content() }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct LabeledField<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(OperatorPalette.secondaryText)
            content().textFieldStyle(.roundedBorder).font(.title3)
        }
    }
}

private struct StatusPill: View {
    let text: String
    let systemImage: String
    let color: Color
    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(color.opacity(0.12), in: Capsule())
            .foregroundStyle(color == .secondary ? Color.secondary : color)
    }
}

private struct PaymentOptionCard: View {
    let choice: GuestPaymentChoice
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: choice.systemImage).font(.title2).frame(width: 32)
                VStack(alignment: .leading, spacing: 4) {
                    Text(choice.title).font(.headline)
                }
                Spacer(minLength: 0)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle").font(.title3)
            }
            .padding(.horizontal, 12).padding(.vertical, 4)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(selected ? OperatorPalette.selected : Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
            .overlay { RoundedRectangle(cornerRadius: 16).stroke(selected ? OperatorPalette.ink : .secondary.opacity(0.2), lineWidth: selected ? 2 : 1) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

enum OperatorPalette {
    static let canvas = MadeToKeepTheme.ColorPalette.paper
    static let ink = MadeToKeepTheme.ColorPalette.ink
    static let accent = MadeToKeepTheme.ColorPalette.burgundy
    static let secondaryText = MadeToKeepTheme.ColorPalette.secondaryText
    static let ready = Color(.sRGB, red: 0.15, green: 0.38, blue: 0.25, opacity: 1)
    static let warning = Color(.sRGB, red: 0.55, green: 0.31, blue: 0.08, opacity: 1)
    static let danger = Color(.sRGB, red: 0.64, green: 0.12, blue: 0.13, opacity: 1)
    static let surface = MadeToKeepTheme.ColorPalette.ivoryLight
    static let border = accent.opacity(0.14)
    static let selected = accent.opacity(0.08)
}

private func paymentMethods(_ qr: Bool, _ cash: Bool) -> String {
    [qr ? "QR Ph" : nil, cash ? "Cash" : nil].compactMap { $0 }.joined(separator: ", ")
}
private func formatNames(_ values: [String]) -> String {
    BoothFormat.allCases.filter { $0.paymentRawValue(in: values) != nil }.map(\.displayName).joined(separator: ", ")
}

/// Event creation needs confirmation: the original request may have created a paid event whose
/// response was lost. Every action is exact or explicitly chosen; none can create a duplicate.
private struct CreationRecoveryCard: View {
    @ObservedObject var setup: SessionSetupCoordinator
    let intent: CommercialEventCreationIntent
    @State private var reviewing = false
    @State private var selectedDraft: String?
    @State private var reason = ""
    @State private var abandoning = false

    var body: some View {
        SetupCard {
            Label("Event creation needs confirmation", systemImage: "exclamationmark.arrow.triangle.2.circlepath").font(.headline).foregroundStyle(OperatorPalette.warning)
                .accessibilityIdentifier("creation-recovery")
            Text(intent.state == .created
                 ? "The paid event \"\(intent.name)\" was created on the payments server, but it isn't linked on this iPad yet."
                 : "A paid event named \"\(intent.name)\" may already exist: the request was sent at \(intent.createdAt.formatted(date: .abbreviated, time: .shortened)) but its answer was lost. Nothing will be created again automatically.")
                .font(.callout)
            if !setup.message.isEmpty { Text(setup.message).font(.callout).foregroundStyle(OperatorPalette.secondaryText) }
            let columns = [GridItem(.adaptive(minimum: 220), spacing: 12)]
            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                if intent.state == .requested {
                    Button { Task { await setup.checkOriginalCreation() } } label: { Label("Check Original Request", systemImage: "magnifyingglass").frame(maxWidth: .infinity, minHeight: 44) }
                        .buttonStyle(.borderedProminent).accessibilityIdentifier("check-original-creation")
                    Button { reviewing.toggle() } label: { Label("Review Existing Draft", systemImage: "list.bullet").frame(maxWidth: .infinity, minHeight: 44) }
                        .buttonStyle(.bordered)
                } else {
                    Button { Task { await setup.completeCreationLinking() } } label: { Label("Complete Linking", systemImage: "link").frame(maxWidth: .infinity, minHeight: 44) }
                        .buttonStyle(.borderedProminent).accessibilityIdentifier("complete-creation-linking")
                }
                Button { abandoning.toggle() } label: { Label("Close Original Request…", systemImage: "xmark.circle").frame(maxWidth: .infinity, minHeight: 44) }
                    .buttonStyle(.bordered)
            }
            if reviewing && intent.state == .requested {
                if setup.draftCandidatesForCreation.isEmpty {
                    Text("No unlinked draft paid events are listed. Check Original Request, or refresh the list with Check Current Status.").font(.footnote)
                } else {
                    Picker("Draft created by the original request", selection: $selectedDraft) {
                        Text("Choose…").tag(String?.none)
                        ForEach(setup.draftCandidatesForCreation) { Text("\($0.name) · \($0.updatedAt.formatted(date: .abbreviated, time: .shortened))").tag(Optional($0.id)) }
                    }
                    Text("Choosing a draft is your decision; names and times are shown only to help. It is recorded with your reason.").font(.footnote).foregroundStyle(OperatorPalette.secondaryText)
                }
            }
            if (reviewing && selectedDraft != nil) || abandoning {
                TextField("Reason (required, kept with the record)", text: $reason).textFieldStyle(.roundedBorder)
                if reviewing, let selectedDraft {
                    Button("Use This Draft") { Task { await setup.useDraftForPendingCreation(selectedDraft, reason: reason) } }
                        .buttonStyle(.borderedProminent).disabled(reason.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if abandoning {
                    Button("Close Without Linking", role: .destructive) { setup.abandonPendingCreation(reason: reason) }
                        .buttonStyle(.bordered).disabled(reason.trimmingCharacters(in: .whitespaces).isEmpty)
                    Text("Use this only when you're sure the original request should not be used. A draft it may have created stays listed and never accepts guests on its own; you can then create the paid event again.")
                        .font(.footnote).foregroundStyle(OperatorPalette.secondaryText)
                }
            }
            Text("Return to Event Setup at any time; this stays here until it's resolved.").font(.footnote).foregroundStyle(OperatorPalette.secondaryText)
        }
    }
}
