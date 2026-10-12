import SwiftUI

struct SessionSetupView: View {
    @StateObject private var setup = SessionSetupCoordinator()
    @ObservedObject private var workspace = OperatorWorkspace.shared
    @ObservedObject private var acceptance = SessionAcceptanceStore.shared
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var review = false
    @State private var confirmDiscard = false
    @State private var confirmPause = false
    @State private var createEvent = false
    @State private var newName = OperatorWorkspace.shared.snapshot.newEventName
    @State private var newVenue = OperatorWorkspace.shared.snapshot.newEventVenue
    init(eventID: String? = nil, coordinator: SessionSetupCoordinator? = nil) {
        _setup = StateObject(wrappedValue: coordinator ?? SessionSetupCoordinator(eventID: eventID))
    }

    var body: some View {
        Form {
            Section {
                Text("How will guests use the booth?").font(.title2.weight(.semibold))
                if horizontalSizeClass == .regular { HStack(alignment: .top, spacing: 16) { modeChoices } }
                else { VStack(spacing: 16) { modeChoices } }
                Text("Your choices stay in setup until you review and start accepting guests.")
                    .font(.footnote).foregroundStyle(.secondary)
                if acceptance.state.blocked {
                    Label("New sessions are paused on this iPad", systemImage: "pause.circle.fill").foregroundStyle(.orange)
                }
            }
            if setup.needsRefresh {
                Section("Action Needs Review") {
                    Text(setup.message)
                    Button("Check Current Status") { Task { await setup.refresh() } }
                }
            }
            if setup.mode == .localPrepaid { prepaidSections } else { paidSections }
            Section("Branding") {
                Picker("Design for new sessions", selection: $setup.branding) {
                    ForEach(SessionBrandingChoice.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Text("Design and payment mode are independent. Saved artwork is retained when you use studio branding.")
                    .font(.footnote).foregroundStyle(.secondary)
                NavigationLink("Customize Branding & Design", value: OperatorWorkspaceRoute.branding)
            }
            Section {
                if let validation = setup.validation { Label(validation, systemImage: "info.circle").foregroundStyle(.orange) }
                if !setup.message.isEmpty { Text(setup.message).font(.callout) }
                if let error = acceptance.storageError ?? workspace.persistenceError { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                if setup.needsRefresh { Button("Check Current Status") { Task { await setup.refresh() } } }
            } footer: {
                Text("Pausing preserves paid purchases and print recovery. Starting changes only future guest sessions.")
            }
        }
        .navigationTitle("Session Setup")
        .tint(OperatorPalette.ink)
        .scrollContentBackground(.hidden).background(OperatorPalette.canvas)
        .disabled(setup.busy)
        .overlay { if setup.busy { ProgressView("Checking setup…").padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)) } }
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 20) {
                Button("Pause New Sessions", role: .destructive) { confirmPause = true }.buttonStyle(.bordered).controlSize(.large)
                Button { review = true } label: {
                    Label("Review Setup", systemImage: "checklist").font(.headline).frame(maxWidth: .infinity, minHeight: 48)
                }.buttonStyle(.borderedProminent).disabled(setup.validation != nil)
            }.padding(.horizontal, 24).padding(.vertical, 14).background(.regularMaterial).tint(OperatorPalette.ink).disabled(setup.busy)
        }
        .task { if setup.mode == .serverManaged { await setup.refresh() } }
        .onChange(of: setup.mode) { _, mode in if mode == .serverManaged { Task { await setup.refresh() } } }
        .onReceive(NotificationCenter.default.publisher(for: OperatorWorkspace.didUnlock)) { _ in
            if setup.mode == .serverManaged { Task { await setup.refresh() } }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { review = false; confirmPause = false; confirmDiscard = false; createEvent = false; workspace.checkpoint() }
        }
        .sheet(isPresented: $review) { reviewSheet }
        .sheet(isPresented: $createEvent) { newEventSheet }
        .confirmationDialog("Discard this event's local edits?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard & Reload", role: .destructive) { Task { await setup.discardPaidEdits() } }
        } message: { Text("Reloads saved settings for this event. Nothing is applied to guests.") }
        .confirmationDialog("Pause new sessions?", isPresented: $confirmPause, titleVisibility: .visible) {
            Button("Pause New Sessions", role: .destructive) { Task { await setup.pause() } }
        } message: { Text("Pauses the booth's current operating mode, even if you are editing a different setup. Paid guests keep their purchased entitlement.") }
    }

    @ViewBuilder private var modeChoices: some View {
        modeCard(.localPrepaid, title: "Prepaid / Free", icon: "gift", description: "Guests can take photos without paying at the booth. Ideal for private parties, weddings, sponsored events, and prepaid bookings.")
        modeCard(.serverManaged, title: "Pay Per Print", icon: "qrcode", description: "Guests select their copies, pay through QR Ph, and take photos after payment is verified.")
    }
    private func modeCard(_ mode: CommercialPolicySource, title: String, icon: String, description: String) -> some View {
        Button { setup.mode = mode } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack { Label(title, systemImage: icon).font(.title3.weight(.semibold)); Spacer(); Image(systemName: setup.mode == mode ? "checkmark.circle.fill" : "circle") }
                Text(description).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(20).frame(minWidth: 250, maxWidth: .infinity, minHeight: 164, alignment: .topLeading)
            .background(setup.mode == mode ? OperatorPalette.selected : Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
            .overlay { RoundedRectangle(cornerRadius: 18).stroke(setup.mode == mode ? OperatorPalette.ink : .secondary.opacity(0.25), lineWidth: setup.mode == mode ? 2 : 1) }
        }.buttonStyle(.plain).accessibilityAddTraits(setup.mode == mode ? .isSelected : [])
    }

    @ViewBuilder private var prepaidSections: some View {
        Section("Prepaid / Free Setup") {
            TextField("Event or session name (optional)", text: $setup.prepaid.name)
            LabeledContent("Current prepaid status", value: CommercialEventRunStore.load().lifecycle.displayName)
            Stepper("Maximum copies: \(setup.prepaid.activePolicy.maxCopies)", value: Binding(get: { setup.prepaid.activePolicy.maxCopies }, set: {
                setup.prepaid.activePolicy.maxCopies = $0; setup.prepaid.activePolicy.defaultCopies = min(setup.prepaid.activePolicy.defaultCopies, $0)
            }), in: PaymentPolicySnapshot.copyRange)
            Stepper("Included copies: \(setup.prepaid.activePolicy.defaultCopies)", value: $setup.prepaid.activePolicy.defaultCopies, in: 1...setup.prepaid.activePolicy.maxCopies)
            Toggle("Allow guests to choose copies", isOn: $setup.prepaid.activePolicy.prepaidGuestCopyChoice)
            Text("No payment required. Works without a payments connection.").foregroundStyle(.secondary)
        }
        Section("Available Formats") {
            ForEach(BoothFormat.allCases, id: \.self) { format in
                Toggle(format.displayName, isOn: Binding(get: { setup.prepaid.activePolicy.supports(format) }, set: { enabled in
                    var formats = setup.prepaid.activePolicy.supportedFormatRawValues
                    formats.removeAll { $0 == format.rawValue }; if enabled { formats.append(format.rawValue) }
                    setup.prepaid.activePolicy.supportedFormatRawValues = formats
                }))
            }
        }
    }

    @ViewBuilder private var paidSections: some View {
        Section("Pay Per Print Event") {
            LabeledContent("Payments environment", value: PaymentsConfiguration.current()?.environment.uppercased() ?? "Not connected")
            Picker("Event", selection: Binding(get: { setup.selectedID ?? "" }, set: { id in Task { await setup.select(id) } })) {
                Text("Choose an event").tag("")
                ForEach(setup.events) { event in Text("\(event.name) · \(CommercialEventLifecycle(rawValue: event.lifecycle)?.displayName ?? event.lifecycle)").tag(event.id) }
            }
            Button("Check Current Status") { Task { await setup.refresh() } }
            Button("Create New Event") { createEvent = true }.disabled(setup.needsRefresh)
            if let detail = setup.detail {
                LabeledContent("Event status", value: detail.event.lifecycle.displayName)
                if let active = detail.activePolicy {
                    LabeledContent("Currently applied", value: "\(PHPPriceFormatter.string(centavos: active.unitPriceCentavos))/copy · default \(active.defaultCopies) · maximum \(active.maxCopies)")
                } else { Text("Saved setup has not been applied to guests.").foregroundStyle(.secondary) }
                if detail.hasUnpublishedRevision { Label("Saved — Not Yet Applied", systemImage: "pencil.circle").foregroundStyle(.orange) }
                if setup.dirtyPaid { Label("Unsaved Changes", systemImage: "pencil").foregroundStyle(.orange) }
            }
        }
        if setup.detail != nil {
            Section("Price & Copies") {
                TextField("Event name", text: $setup.name)
                TextField("Venue (optional)", text: $setup.venue)
                HStack { Text("Price per physical copy"); Spacer(); Text("₱"); TextField("0.00", text: $setup.policy.priceText).keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(maxWidth: 140) }
                Stepper("Maximum copies: \(setup.policy.maxCopies)", value: Binding(get: { setup.policy.maxCopies }, set: {
                    setup.policy.maxCopies = $0; setup.policy.defaultCopies = min(setup.policy.defaultCopies, $0)
                }), in: PaymentPolicySnapshot.copyRange)
                Stepper("Default copies: \(setup.policy.defaultCopies)", value: $setup.policy.defaultCopies, in: 1...setup.policy.maxCopies)
                Toggle("QR Ph", isOn: $setup.policy.qrPhEnabled)
                DisclosureGroup("Advanced Payment Options") {
                    Toggle("Guest-declared cash — unverified", isOn: $setup.policy.cashEnabled)
                    Text("A guest saying “I've Paid” is not proof of payment. Use cash only with an attendant checking payment.").font(.footnote).foregroundStyle(.secondary)
                    Toggle("Allow signed offline cash", isOn: $setup.policy.offlineCashEnabled).disabled(!setup.policy.cashEnabled)
                    if setup.policy.offlineCashEnabled {
                        DatePicker("Offline cash allowed until", selection: $setup.policy.offlineValidUntil, in: Date()...)
                        Text("Offline permissions are time-limited. A disconnected iPad learns of a pause when it reconnects.").font(.footnote)
                    }
                }
            }
            Section("Guest Total Preview") {
                if let price = setup.policy.unitPriceCentavos, price > 0 {
                    ForEach(1...max(1, min(10, setup.policy.maxCopies)), id: \.self) { count in
                        LabeledContent("\(count) \(count == 1 ? "copy" : "copies")", value: PHPPriceFormatter.string(centavos: price * count))
                    }
                } else { Text("Enter a valid price to see guest totals.") }
                Text("Guests pay the total before taking photos. These settings apply only after you start accepting guests.").font(.footnote).foregroundStyle(.secondary)
            }
            Section("Available Formats") {
                ForEach(BoothFormat.allCases, id: \.self) { format in
                    Toggle(format.displayName, isOn: Binding(get: { setup.policy.supports(format) }, set: { setup.policy.setFormat(format, enabled: $0) }))
                }
            }
            if setup.conflict, let latest = setup.detail?.latestRevision {
                Section("Server Settings Changed — Review Required") {
                    Text("Your edits are retained. Compare them with the saved settings before continuing.")
                    LabeledContent("Saved name / venue", value: "\(setup.detail?.event.name ?? "") · \(setup.detail?.event.venue ?? "")")
                    LabeledContent("Saved price", value: PHPPriceFormatter.string(centavos: latest.unitPriceCentavos))
                    LabeledContent("Saved copies", value: "Default \(latest.defaultCopies) · maximum \(latest.maxCopies)")
                    LabeledContent("Saved methods", value: paymentMethods(latest.qrphEnabled, latest.cashEnabled))
                    LabeledContent("Saved offline cash", value: latest.offlineValidUntil.map { $0.formatted() } ?? "Disabled")
                    LabeledContent("Saved formats", value: formatNames(latest.supportedFormats))
                    Button("I've Reviewed — Keep My Edits") { setup.keepReviewedEdits() }.disabled(setup.needsRefresh)
                    Button("Discard My Edits…", role: .destructive) { confirmDiscard = true }
                }
            }
            Section {
                Button("Save Setup Without Starting") { Task { await setup.saveOnly() } }.disabled(setup.validation != nil || !setup.dirtyPaid)
                Text("Saves this event's settings without opening the booth. Existing guests keep their purchased price.").font(.footnote).foregroundStyle(.secondary)
            }
        }
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
                Section("New Pay Per Print Event") {
                    TextField("Event name", text: $newName)
                    TextField("Venue (optional)", text: $newVenue)
                    Text("Created as saved setup only. No guests can pay until you review and start accepting guests.").font(.footnote)
                    Button("Create Event") { Task { createEvent = false; await setup.create(name: newName, venue: newVenue) } }
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }.navigationTitle("Create Event")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { createEvent = false } } }
        }
        .onChange(of: newName) { _, _ in workspace.saveNewEvent(name: newName, venue: newVenue) }
        .onChange(of: newVenue) { _, _ in workspace.saveNewEvent(name: newName, venue: newVenue) }
    }
}

struct SessionSetupReviewView: View {
    @ObservedObject var setup: SessionSetupCoordinator
    @ObservedObject private var printer = PrinterCoordinator.shared
    let onBack: () -> Void
    let onFinished: (Bool) -> Void
    var body: some View {
        NavigationStack {
            Form {
                Section("Your Next Guest Session") {
                    LabeledContent("Mode", value: setup.mode == .localPrepaid ? "Prepaid / Free" : "Pay Per Print")
                    LabeledContent("Event", value: setup.mode == .localPrepaid ? (setup.prepaid.name.isEmpty ? "Unnamed session" : setup.prepaid.name) : setup.name)
                    if setup.mode == .serverManaged {
                        LabeledContent("Price per copy", value: setup.policy.unitPriceCentavos.map { PHPPriceFormatter.string(centavos: $0) } ?? "Invalid price")
                        LabeledContent("Copies", value: "Default \(setup.policy.defaultCopies) · maximum \(setup.policy.maxCopies)")
                        LabeledContent("Payments", value: paymentMethods(setup.policy.qrPhEnabled, setup.policy.cashEnabled))
                        LabeledContent("Offline cash", value: setup.policy.offlineCashEnabled ? "Enabled until \(setup.policy.offlineValidUntil.formatted())" : "Disabled")
                        LabeledContent("Formats", value: formatNames(Array(setup.policy.supportedFormats)))
                        LabeledContent("Environment", value: PaymentsConfiguration.current()?.environment.uppercased() ?? "Not connected")
                    } else {
                        LabeledContent("Included copies / maximum", value: "\(setup.prepaid.activePolicy.defaultCopies) / \(setup.prepaid.activePolicy.maxCopies)")
                        LabeledContent("Guest copy choice", value: setup.prepaid.activePolicy.prepaidGuestCopyChoice ? "Allowed" : "Fixed included quantity")
                        LabeledContent("Formats", value: formatNames(setup.prepaid.activePolicy.supportedFormatRawValues))
                        Text("No payment required.")
                    }
                    LabeledContent("Branding", value: setup.branding == .current ? (EventProfileStore.load().isEventModeActive ? "Current custom branding" : "Studio Default") : setup.branding.title)
                    LabeledContent("Printer", value: printer.state.message)
                }
                Section {
                    Text("This starts new guest sessions with the setup shown above. Previously paid sessions keep their original entitlement.")
                    if let validation = setup.validation { Text(validation).foregroundStyle(.orange) }
                    Button {
                        Task {
                            let started = await setup.startAccepting()
                            onFinished(started)
                        }
                    } label: { Text("Start Accepting Guests").font(.headline).frame(maxWidth: .infinity, minHeight: 48) }
                    .buttonStyle(.borderedProminent).disabled(setup.busy || setup.validation != nil)
                }
            }
            .navigationTitle("Review Setup").tint(OperatorPalette.ink)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Back to Setup") { onBack() }.disabled(setup.busy) } }
            .interactiveDismissDisabled(setup.busy)
        }
    }
}

enum OperatorPalette {
    static let canvas = Color(uiColor: .systemGroupedBackground)
    static let ink = Color(uiColor: .label)
    static let selected = Color(uiColor: .tertiarySystemGroupedBackground)
}

private func paymentMethods(_ qr: Bool, _ cash: Bool) -> String {
    [qr ? "QR Ph" : nil, cash ? "Cash — unverified" : nil].compactMap { $0 }.joined(separator: ", ")
}
private func formatNames(_ values: [String]) -> String {
    BoothFormat.allCases.filter { $0.paymentRawValue(in: values) != nil }.map(\.displayName).joined(separator: ", ")
}
