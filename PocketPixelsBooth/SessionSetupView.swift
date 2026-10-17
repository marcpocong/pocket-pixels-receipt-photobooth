import SwiftUI

nonisolated enum OperatorSetupStage: Int, CaseIterable, Identifiable, Sendable {
    case details, payment, experience, review
    var id: Int { rawValue }
    var title: String {
        switch self { case .details: "Event Details"; case .payment: "Payment & Prints"; case .experience: "Guest Experience"; case .review: "Review & Start" }
    }
}

struct SessionSetupView: View {
    @StateObject private var setup: SessionSetupCoordinator
    @ObservedObject private var workspace = OperatorWorkspace.shared
    @ObservedObject private var acceptance = SessionAcceptanceStore.shared
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var devicePrintOptions = ReceiptPrintSettingsStore.load()
    @State private var review = false
    @State private var stage: OperatorSetupStage = .details
    @State private var draftMessage = ""
    @State private var confirmDiscard = false
    @State private var confirmPause = false
    @State private var createEvent = false
    @State private var previewExpanded = true
    @State private var newName = OperatorWorkspace.shared.snapshot.newEventName
    @State private var newVenue = OperatorWorkspace.shared.snapshot.newEventVenue
    init(eventID: String? = nil, coordinator: SessionSetupCoordinator? = nil, opensNewEventDraft: Bool = false) {
        let model = coordinator ?? SessionSetupCoordinator(eventID: eventID)
        _setup = StateObject(wrappedValue: model)
        _workspace = ObservedObject(wrappedValue: model.workspaceForEditing)
        _newName = State(initialValue: model.workspaceForEditing.snapshot.newEventName)
        _newVenue = State(initialValue: model.workspaceForEditing.snapshot.newEventVenue)
        _createEvent = State(initialValue: opensNewEventDraft)
        _stage = State(initialValue: opensNewEventDraft ? .details : (OperatorSetupStage(rawValue: model.workspaceForEditing.snapshot.setupStage ?? 0) ?? .details))
    }

    private var regular: Bool { horizontalSizeClass == .regular }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
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
                stageNavigation
                SetupSection(number: stage.rawValue + 1, title: stage.title) {
                    switch stage {
                    case .details: eventSection
                    case .payment: paymentSection
                    case .experience: receiptSection
                    case .review: summarySection
                    }
                }
                if !draftMessage.isEmpty { Text(draftMessage).font(.callout).foregroundStyle(OperatorPalette.secondaryText).accessibilityIdentifier("setup-draft-message") }
            }
            .frame(maxWidth: 980, alignment: .leading)
            .padding(.horizontal, regular ? 32 : 16)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Event Setup")
        .navigationBarTitleDisplayMode(.inline)
        .tint(OperatorPalette.ink)
        .background(OperatorPalette.canvas)
        .disabled(setup.busy)
        .overlay { if setup.busy { ProgressView("Checking setup…").padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)) } }
        .safeAreaInset(edge: .bottom) { bottomBar }
        .task { if setup.mode == .serverManaged { await setup.refresh() } }
        .onAppear { setup.reloadDesignFromStorage(); devicePrintOptions = ReceiptPrintSettingsStore.load() }
        .onReceive(NotificationCenter.default.publisher(for: ReceiptPrintSettingsStore.didChangeNotification)) { _ in
            devicePrintOptions = ReceiptPrintSettingsStore.load()
        }
        .onReceive(NotificationCenter.default.publisher(for: OperatorWorkspace.didUnlock)) { _ in
            if setup.mode == .serverManaged { Task { await setup.refresh() } }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { review = false; confirmPause = false; confirmDiscard = false; createEvent = false; workspace.checkpoint() }
        }
        .onChange(of: stage) { _, value in workspace.saveSetupStage(value.rawValue) }
        .sheet(isPresented: $review) { reviewSheet }
        .sheet(isPresented: $createEvent) { newEventSheet }
        .confirmationDialog("Discard this event's local edits?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard & Reload", role: .destructive) { Task { await setup.discardPaidEdits() } }
        } message: { Text("Reloads saved settings for this event. Nothing is applied to guests.") }
        .confirmationDialog("Pause new sessions?", isPresented: $confirmPause, titleVisibility: .visible) {
            Button("Pause This Booth", role: .destructive) { Task { await setup.pause() } }
        } message: { Text("Pauses new sessions on this iPad only, even if you are editing a different setup. A shared paid event stays open for other booths. Paid guests keep their purchased entitlement.") }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Prepare your event").font(.system(.title2, design: .serif).weight(.semibold))
            Text("Choose the event, how guests pay and the receipt design. Nothing changes for guests until you review and start.")
                .font(.callout).foregroundStyle(OperatorPalette.secondaryText)
            HStack(spacing: 10) {
                StatusPill(text: setup.isCurrentlyApplied ? "Currently applied" : (setup.hasUnsavedChanges ? "Unsaved changes" : "Saved — not yet applied"),
                           systemImage: setup.isCurrentlyApplied ? "checkmark.circle.fill" : "pencil.circle",
                           color: setup.isCurrentlyApplied ? OperatorPalette.ready : OperatorPalette.warning)
                if acceptance.state.blocked { StatusPill(text: "New sessions paused", systemImage: "pause.circle.fill", color: OperatorPalette.warning) }
            }
        }
    }

    // MARK: 1. Session / Event

    @ViewBuilder private var eventSection: some View {
        SetupCard {
            Toggle(isOn: Binding(get: { setup.eventModeEnabled }, set: { value in Task { await setup.setEventMode(value) } })) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Event Mode").font(.title3.weight(.semibold))
                    Text(setup.eventModeEnabled
                         ? "Guests get this event's name, optional welcome screens and optional receipt logo."
                         : "Regular Made to Keep sessions. Saved events and logos are kept for later.")
                        .font(.callout).foregroundStyle(OperatorPalette.secondaryText)
                }
            }
            .toggleStyle(.switch)
            .frame(minHeight: 56)

            if setup.eventModeEnabled {
                Divider()
                eventPicker
                if let design = Binding($setup.design) {
                    VStack(spacing: 12) {
                        LabeledField(title: "Event name") {
                            TextField("e.g. CIM Graduation Ball", text: limited(design.name, EventProfile.eventNameLimit)).textInputAutocapitalization(.words)
                        }
                        LabeledField(title: "Venue (optional)") {
                            TextField("Venue", text: limited(design.venue, EventProfile.locationLimit)).textInputAutocapitalization(.words)
                        }
                    }
                    Divider()
                    Label("Guests will see: \(design.wrappedValue.displayName)", systemImage: "person.2")
                        .font(.callout).foregroundStyle(OperatorPalette.secondaryText)
                }
            }
        }
    }

    private var eventPicker: some View {
        HStack(spacing: 12) {
            Menu {
                if !setup.savedEvents.isEmpty {
                    Section("Saved Events") {
                        ForEach(setup.savedEvents) { event in
                            Button { Task { await setup.chooseDesign(event.id) } } label: {
                                Label(event.displayName, systemImage: event.id == setup.designID ? "checkmark" : (event.personalizeReceipt ? "photo" : "calendar"))
                            }
                        }
                    }
                }
                if setup.mode == .serverManaged, !setup.unlinkedServerEvents.isEmpty {
                    Section("Paid Events on the Payments Server") {
                        ForEach(setup.unlinkedServerEvents) { event in
                            Button(event.name) { Task { await setup.useServerEvent(event) } }
                        }
                    }
                }
                Divider()
                Button { createEvent = true } label: { Label("New Event…", systemImage: "plus") }
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("EVENT").font(.caption.weight(.semibold)).tracking(1.5).foregroundStyle(OperatorPalette.secondaryText)
                        Text(setup.design?.displayName ?? "Choose or create an event").font(.title3.weight(.semibold))
                    }
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                }
                .padding(16)
                .frame(maxWidth: .infinity, minHeight: 64)
                .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            Button { createEvent = true } label: { Label("New Event", systemImage: "plus").frame(minHeight: 44) }
                .buttonStyle(.bordered)
        }
    }

    @ViewBuilder private func guestScreens(_ design: Binding<SavedEventDesign>) -> some View {
        Toggle(isOn: design.guestScreensEnabled) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Custom Welcome Screens").font(.headline)
                Text("Show the event name and your messages on the guest welcome and thank-you screens.").font(.callout).foregroundStyle(OperatorPalette.secondaryText)
            }
        }
        .toggleStyle(.switch)
        if design.wrappedValue.guestScreensEnabled {
            DisclosureGroup("Welcome screen details") {
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
        SetupCard {
            Text("How will guests pay?").font(.title3.weight(.semibold))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: regular ? 2 : 1), spacing: 14) {
                ForEach(GuestPaymentChoice.allCases) { choice in
                    PaymentOptionCard(choice: choice, selected: setup.paymentChoice == choice) { Task { await setup.choosePayment(choice) } }
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
        Stepper("Included copies: \(setup.prepaid.activePolicy.defaultCopies)", value: $setup.prepaid.activePolicy.defaultCopies, in: 1...setup.prepaid.activePolicy.maxCopies)
        Stepper("Maximum copies: \(setup.prepaid.activePolicy.maxCopies)", value: Binding(get: { setup.prepaid.activePolicy.maxCopies }, set: {
            setup.prepaid.activePolicy.maxCopies = $0; setup.prepaid.activePolicy.defaultCopies = min(setup.prepaid.activePolicy.defaultCopies, $0)
        }), in: PaymentPolicySnapshot.copyRange)
        Toggle("Allow guests to choose copies", isOn: $setup.prepaid.activePolicy.prepaidGuestCopyChoice)
        formatChips(isOn: { setup.prepaid.activePolicy.supports($0) }, set: { format, enabled in
            var formats = setup.prepaid.activePolicy.supportedFormatRawValues
            formats.removeAll { $0 == format.rawValue }; if enabled { formats.append(format.rawValue) }
            setup.prepaid.activePolicy.supportedFormatRawValues = formats
        })
        Text("Works without a payments connection.").font(.footnote).foregroundStyle(OperatorPalette.secondaryText)
    }

    @ViewBuilder private var paidSettings: some View {
        LabeledContent("Payments environment", value: PaymentsConfiguration.current()?.environment.uppercased() ?? "Not connected").font(.callout)
        if setup.targetServerEventID == nil {
            VStack(alignment: .leading, spacing: 10) {
                Text(setup.eventModeEnabled ? "Connect this event to paid checkout" : "Set up regular paid sessions").font(.headline)
                Text("Creates a saved paid event on the payments server for this environment. It does not accept guests until you review and start.")
                    .font(.callout).foregroundStyle(OperatorPalette.secondaryText)
                Button {
                    Task { await setup.connectPaidCheckout() }
                } label: { Label(setup.eventModeEnabled ? "Connect to Paid Checkout" : "Set Up Regular Paid Sessions", systemImage: "link").frame(minHeight: 44) }
                .buttonStyle(.borderedProminent)
                .disabled(setup.needsRefresh || (setup.eventModeEnabled && setup.design == nil))
            }
        } else if let detail = setup.detail {
            HStack {
                StatusPill(text: detail.event.lifecycle.displayName, systemImage: detail.event.lifecycle == .active ? "dot.radiowaves.left.and.right" : "circle.dashed",
                           color: detail.event.lifecycle == .active ? OperatorPalette.ready : .secondary)
                if detail.hasUnpublishedRevision { StatusPill(text: "Saved — Not Yet Applied", systemImage: "pencil.circle", color: OperatorPalette.warning) }
                if setup.dirtyPaid { StatusPill(text: "Unsaved Changes", systemImage: "pencil", color: OperatorPalette.warning) }
            }
            HStack {
                Text("Price per copy").font(.headline)
                Spacer()
                Text("₱")
                TextField("0.00", text: $setup.policy.priceText).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                    .font(.title3.monospacedDigit()).frame(maxWidth: 160).textFieldStyle(.roundedBorder)
            }
            Stepper("Default copies: \(setup.policy.defaultCopies)", value: $setup.policy.defaultCopies, in: 1...setup.policy.maxCopies)
            Stepper("Maximum copies: \(setup.policy.maxCopies)", value: Binding(get: { setup.policy.maxCopies }, set: {
                setup.policy.maxCopies = $0; setup.policy.defaultCopies = min(setup.policy.defaultCopies, $0)
            }), in: PaymentPolicySnapshot.copyRange)
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
            if setup.conflict, let latest = detail.latestRevision {
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

    // MARK: 3. Receipt & Branding

    @ViewBuilder private var receiptSection: some View {
        SetupCard {
            LabeledContent("Default gallery code", value: devicePrintOptions.footerStyle.displayName).font(.callout)
            Text("Event-specific gallery code, branding and welcome screens stay staged until Review & Start.").font(.footnote).foregroundStyle(OperatorPalette.secondaryText)
            Divider()
            if setup.eventModeEnabled, let design = Binding($setup.design) {
                guestScreens(design)
                Divider()
                EventReceiptDesignPanel(design: design, isDirty: setup.designDirty, save: { setup.saveDesign() }, discard: { setup.discardDesignChanges() })
                NavigationLink {
                    EventDesignEditorView(setup: setup)
                } label: {
                    Label("More Design Options — typography, caption, event details, Photo Pass", systemImage: "paintbrush").font(.callout)
                }
            } else {
                Label("Studio Default Receipt", systemImage: "doc.plaintext").font(.headline)
                Text(setup.eventModeEnabled
                     ? "Choose an event to personalize its receipt."
                     : "Regular sessions print the Made to Keep receipt. Turn on Event Mode to personalize receipts with an event logo.")
                    .font(.callout).foregroundStyle(OperatorPalette.secondaryText)
            }
            Divider()
            NavigationLink {
                ScrollView { CustomerExperiencePreviewView(profile: setup.effectiveProfile).padding() }
                    .navigationTitle("Guest Experience Preview")
            } label: { Label("Preview Guest Experience", systemImage: "ipad") }
            NavigationLink(value: OperatorWorkspaceRoute.stickers) { Label("Sticker Options", systemImage: "face.smiling") }
            Text("Sticker library changes are device-wide. The preview uses this staged event's branding.").font(.footnote).foregroundStyle(OperatorPalette.secondaryText)
            DisclosureGroup("Preview Receipt", isExpanded: $previewExpanded) {
                EventReceiptComposerPreview(profile: setup.effectiveProfile, printOptions: devicePrintOptions)
                    .padding(.top, 8)
            }
            .font(.headline)
        }
    }

    // MARK: 4. Review

    private var summarySection: some View {
        SetupCard {
            SetupSummaryRows(setup: setup)
            Button("Save Reviewed Setup Without Starting") { Task { await setup.saveOnly() } }
                .buttonStyle(.bordered).disabled(setup.validation != nil || !setup.hasUnsavedChanges)
            if let validation = setup.validation { Label(validation, systemImage: "info.circle").foregroundStyle(OperatorPalette.warning) }
            if setup.canStartNewPaidOccurrence {
                Button { Task { await setup.startNewPaidOccurrence() } } label: {
                    Label("Start New Paid Occurrence", systemImage: "arrow.triangle.2.circlepath").frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("new-paid-occurrence")
                Text("Creates a fresh paid event for this design with the same price and methods as a draft. The ended event keeps its orders and reports.")
                    .font(.footnote).foregroundStyle(OperatorPalette.secondaryText)
            }
            Label(setup.occurrenceSummary, systemImage: "calendar.badge.clock").font(.callout)
            if case .requiresNewOccurrence = setup.occurrencePlan {
                Toggle("Start New Occurrence — fresh statistics", isOn: $setup.startsNewOccurrence).frame(minHeight: 44)
            }
            if !setup.message.isEmpty, !setup.needsRefresh { Text(setup.message).font(.callout) }
            if let error = acceptance.storageError ?? workspace.persistenceError ?? setup.library.storageError {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(OperatorPalette.danger)
            }
            Text("Pausing preserves paid purchases and print recovery. Starting changes only future guest sessions.")
                .font(.footnote).foregroundStyle(OperatorPalette.secondaryText)
        }
    }

    private var stageNavigation: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                ForEach(OperatorSetupStage.allCases) { item in
                    Button { stage = item } label: {
                        Text("\(item.rawValue + 1). \(item.title)").font(.callout.weight(stage == item ? .semibold : .regular))
                            .padding(.horizontal, 12).frame(minHeight: 48)
                            .background(stage == item ? OperatorPalette.selected : .clear, in: RoundedRectangle(cornerRadius: 10))
                    }.buttonStyle(.plain).accessibilityAddTraits(stage == item ? .isSelected : [])
                }
            }.fixedSize(horizontal: true, vertical: false)
            Picker("Setup stage", selection: $stage) {
                ForEach(OperatorSetupStage.allCases) { Text("\($0.rawValue + 1). \($0.title)").tag($0) }
            }.pickerStyle(.menu).frame(minHeight: 48)
        }
        .accessibilityIdentifier("setup-stages")
    }

    private var bottomBar: some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 12))
        return layout {
            Button("Save Draft") {
                workspace.checkpoint()
                draftMessage = workspace.persistenceError ?? "Draft saved on this iPad. Guests keep the current setup."
            }
            .buttonStyle(.bordered).frame(minHeight: 48).accessibilityIdentifier("save-setup-draft")
            if stage != .details {
                Button("Back") { stage = OperatorSetupStage(rawValue: stage.rawValue - 1) ?? .details }
                    .buttonStyle(.bordered).frame(minHeight: 48)
            }
            if stage == .review {
                Button { review = true } label: {
                    Label("Review & Start", systemImage: "checklist").font(.headline).frame(maxWidth: .infinity, minHeight: 48)
                }
                .buttonStyle(.borderedProminent).disabled(setup.validation != nil).accessibilityIdentifier("review-setup")
            } else {
                Button { stage = OperatorSetupStage(rawValue: stage.rawValue + 1) ?? .review } label: {
                    Label("Continue", systemImage: "arrow.right").font(.headline).frame(maxWidth: .infinity, minHeight: 48)
                }.buttonStyle(.borderedProminent).accessibilityIdentifier("setup-continue")
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 14).background(.regularMaterial).tint(OperatorPalette.accent).disabled(setup.busy)
    }

    private var reviewSheet: some View {
        SessionSetupReviewView(setup: setup, onBack: { review = false }, onFinished: { started in
            review = false
            if started { NotificationCenter.default.post(name: OperatorWorkspace.didStartSessions, object: nil) }
        })
    }

    private var newEventSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Event name", text: $newName)
                    TextField("Venue (optional)", text: $newVenue)
                } header: { Text("New Event") } footer: {
                    Text(setup.mode == .serverManaged
                         ? "Saved and connected to paid checkout. No guests can pay until you review and start."
                         : "Saved on this iPad. Nothing changes for guests until you review and start.")
                }
            }
            .navigationTitle("New Event")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { createEvent = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { Task { createEvent = false; await setup.createEvent(name: newName, venue: newVenue); newName = ""; newVenue = "" } }
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .onChange(of: newName) { _, _ in workspace.saveNewEvent(name: newName, venue: newVenue) }
        .onChange(of: newVenue) { _, _ in workspace.saveNewEvent(name: newName, venue: newVenue) }
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
        LabeledContent("Session", value: setup.eventModeEnabled ? "Event Mode" : "Regular Session")
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
        LabeledContent("Guest screens", value: setup.eventModeEnabled && design?.guestScreensEnabled == true ? "Event welcome screens" : "Made to Keep standard")
        LabeledContent("Status", value: setup.isCurrentlyApplied ? "Currently applied" : (setup.hasUnsavedChanges ? "Unsaved changes" : "Saved — not yet applied"))
        Divider()
        LabeledContent("Camera check", value: operations.cameraCheckPassed ? "Checked this foreground session" : "Not checked — use Booth Check")
        LabeledContent("Printer", value: printer.state.message)
        LabeledContent("Gallery connectivity", value: operations.queueError != nil ? "Upload storage needs review" : "\(operations.networkPathStatus) · \(operations.pendingUploadCount) waiting on this iPad")
        if let reason = SessionSetupSafety.blockingReason {
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
                Section("Your Next Guest Session") { SetupSummaryRows(setup: setup) }
                Section("Event Run") {
                    Text(setup.occurrenceSummary)
                    if case .requiresNewOccurrence = setup.occurrencePlan {
                        Toggle("Start New Occurrence — fresh statistics", isOn: $setup.startsNewOccurrence).frame(minHeight: 44)
                            .accessibilityIdentifier("start-new-occurrence")
                    }
                }
                Section("Receipt Preview") {
                    EventReceiptComposerPreview(profile: setup.effectiveProfile, printOptions: ReceiptPrintSettingsStore.load(), showsSamplePrintLink: false, maximumPreviewWidth: 300)
                }
                Section {
                    Text("This starts new guest sessions with the setup shown above. Sessions already in progress keep their original design and purchased entitlement.")
                    if let validation = setup.validation { Text(validation).foregroundStyle(OperatorPalette.warning) }
                    Button {
                        Task {
                            let started = await setup.startAccepting()
                            onFinished(started)
                        }
                    } label: { Text("Start Accepting Guests").font(.headline).frame(maxWidth: .infinity, minHeight: 48) }
                    .buttonStyle(.borderedProminent).disabled(setup.busy || setup.validation != nil || needsOccurrenceChoice)
                }
            }
            .navigationTitle("Review Setup").tint(OperatorPalette.ink)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Back to Setup") { onBack() }.disabled(setup.busy) } }
            .interactiveDismissDisabled(setup.busy)
        }
    }
}

// MARK: Building blocks

private struct SetupSection<Content: View>: View {
    let number: Int
    let title: String
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text("\(number)").font(.subheadline.weight(.bold)).frame(width: 28, height: 28)
                    .background(OperatorPalette.ink, in: Circle()).foregroundStyle(Color(uiColor: .systemBackground))
                Text(title.uppercased()).font(.subheadline.weight(.semibold)).tracking(1.6)
            }
            .accessibilityElement(children: .combine).accessibilityAddTraits(.isHeader)
            content()
        }
    }
}

private struct SetupCard<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 16) { content() }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
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
                    Text(choice.subtitle).font(.footnote).foregroundStyle(OperatorPalette.secondaryText).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle").font(.title3)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
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
