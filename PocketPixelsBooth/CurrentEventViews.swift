import SwiftUI

private typealias Brand = MadeToKeepTheme.ColorPalette

/// The everyday home for running an event: one truthful status and the four actions an
/// attendant needs. Setup, reports and maintenance stay one tap away, not mixed in.
struct CurrentEventCard: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    @StateObject private var lifecycle: EventLifecycleCoordinator
    @ObservedObject private var workspace: OperatorWorkspace
    @ObservedObject private var runs: EventRunStore
    @ObservedObject private var acceptance = SessionAcceptanceStore.shared
    @ObservedObject private var library = EventDesignLibraryStore.shared
    @ObservedObject private var operations = EventOperationalState.shared
    @ObservedObject private var printer = PrinterCoordinator.shared
    @State private var server: ServerBoothStatus?
    @State private var confirm: Confirmation?
    @State private var showsEnd = false
    @State private var showsHealth = false
    private let loadsRemote: Bool

    enum Confirmation: String, Identifiable { case pauseBooth, pauseCommercial, resume, finishEnding, recordRun, regular; var id: String { rawValue } }

    init(lifecycle: EventLifecycleCoordinator? = nil, loadsRemote: Bool = true, workspace: OperatorWorkspace? = nil) {
        _workspace = ObservedObject(wrappedValue: workspace ?? .shared)
        let model = lifecycle ?? EventLifecycleCoordinator()
        _lifecycle = StateObject(wrappedValue: model)
        _runs = ObservedObject(wrappedValue: model.runs)
        _acceptance = ObservedObject(wrappedValue: model.acceptanceForPresentation)
        self.loadsRemote = loadsRemote
    }

    private var status: EventOperatorStatus { lifecycle.status }
    private var run: EventRunRecord? { runs.operational }
    private var regular: Bool { RegularBoothMode.isEnabled(acceptance: acceptance, runs: runs) }
    private var local: CommercialEventRun { regular ? RegularBoothSettings.load().configuration : CommercialEventRunStore.load() }
    private var paid: Bool { CommercialPolicySource.load() == .serverManaged }
    private var busy: Bool { lifecycle.operation != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            facts
            warnings
            actions
            eventControls
            if !lifecycle.message.isEmpty {
                Text(lifecycle.message).font(.callout).foregroundStyle(OperatorPalette.secondaryText).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("current-event-message")
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.ivoryLight, in: RoundedRectangle(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).stroke(Brand.burgundy.opacity(0.18)) }
        // The ivory card keeps its editorial palette; system colors inside it stay legible.
        .environment(\.colorScheme, .light)
        .task { await refresh() }
        .onReceive(NotificationCenter.default.publisher(for: OperatorWorkspace.didUnlock)) { _ in Task { await refresh() } }
        .confirmationDialog(confirmTitle, isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }), titleVisibility: .visible, presenting: confirm) { item in
            Button(confirmButton(item), role: [.resume, .recordRun].contains(item) ? nil : .destructive) { Task { await perform(item) } }
            Button("Cancel", role: .cancel) {}
        } message: { item in Text(confirmMessage(item)) }
        .sheet(isPresented: $showsEnd) { EndEventSheet(lifecycle: lifecycle, isPresented: $showsEnd) }
        .sheet(isPresented: $showsHealth) { ProductionHealthSheet(lifecycle: lifecycle, isPresented: $showsHealth, loadsRemote: loadsRemote) }
    }

    // MARK: Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(eventName).font(.system(.title2, design: .serif).weight(.semibold)).foregroundStyle(Brand.ink)
                .accessibilityIdentifier("current-event-name")
            HStack(spacing: 10) {
                Label(status.title, systemImage: status.systemImage)
                    .font(.headline)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(statusColor.opacity(0.14), in: Capsule())
                    .foregroundStyle(statusColor)
                    .accessibilityIdentifier("current-event-status")
                if busy { ProgressView() }
            }
            Text(regular ? "Regular Booth defaults · no payment required" : status.detail).font(.callout).foregroundStyle(OperatorPalette.secondaryText).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var facts: some View {
        VStack(spacing: 10) {
            fact("Guest admission", guestAdmissionLine)
            let health = OperatorStatusSummary(report: operations.readinessReport, hasUnresolvedPrint: operations.hasUnresolvedPrint,
                printerRequiresRecovery: printer.requiresRecovery, pendingUploadCount: operations.pendingUploadCount, galleryStorageError: operations.queueError != nil)
            fact("Equipment", health.allSystemsReady ? "Checks passed" : health.summary)
            if run == nil && lifecycle.canRecordUpgradedRun { fact("Event run", "Not recorded yet — statistics start with the first guest or Record Event Run") }
            fact("Payment", paymentLine)
            if paid, let checked = lifecycle.lastCheckedAt { fact("Server checked", checked.formatted(date: .omitted, time: .shortened)) }
        }
        .font(.callout)
    }

    @ViewBuilder private var warnings: some View {
        if let reason = SessionSetupSafety.recoveryReason {
            NavigationLink(value: SessionSetupSafety.recoveryDestination) {
                Label(reason, systemImage: "exclamationmark.triangle.fill").foregroundStyle(OperatorPalette.warning).frame(minHeight: 44, alignment: .leading)
            }
        }
        if let error = runs.storageError, !runs.historyUnreadable {
            Label("Statistics could not be saved: \(error)", systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(OperatorPalette.warning)
        }
    }

    @ViewBuilder private var actions: some View {
        let columns = [GridItem(.adaptive(minimum: 200), spacing: 12)]
        LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
            primaryAction
            if [.active, .paused].contains(run?.status) {
                actionButton("End Event", systemImage: "flag.checkered", role: .destructive) { showsEnd = true }
                    .disabled(SessionSetupSafety.blockingReason != nil).accessibilityIdentifier("end-event")
            }
            if OperatorHomeActionPolicy(status: status).showsPause, !acceptance.state.blocked {
                actionButton("Pause Booth", systemImage: "pause.fill") { confirm = .pauseBooth }
                    .accessibilityIdentifier("pause-booth")
            }

            if paid || runs.pendingTransition != nil, !OperatorHomeActionPolicy(status: status).statusCheckIsPrimary {
                actionButton("Check Status", systemImage: "arrow.clockwise") { Task { await refresh() } }
            }

        }
        .controlSize(.large)
        .tint(Brand.burgundy)
        .disabled(busy)
    }

    @ViewBuilder private var primaryAction: some View {
        switch status {
        case .regular:
            Button { workspace.navigate(to: .regularBooth) } label: {
                Label("Edit Booth Settings", systemImage: "slider.horizontal.3").frame(maxWidth: .infinity, minHeight: 48)
            }.buttonStyle(.borderedProminent)
            Button { workspace.navigate(to: .newEvent) } label: {
                Label("Start Event", systemImage: "calendar.badge.plus").frame(maxWidth: .infinity, minHeight: 48)
            }.buttonStyle(.bordered)
        case .starting, .ending, .accepting:
            EmptyView()
        case .unconfirmed:
            Button { Task { await refresh() } } label: { Label("Check Status", systemImage: "arrow.clockwise").frame(maxWidth: .infinity, minHeight: 48) }
                .buttonStyle(.borderedProminent)
        case .recoveryRequired:
            Button { workspace.navigate(to: SessionSetupSafety.recoveryDestination) } label: {
                Label("Review Recovery", systemImage: "exclamationmark.octagon").frame(maxWidth: .infinity, minHeight: 48)
            }.buttonStyle(.borderedProminent)
        case .completed, .archived, .noEvent:
            Button { workspace.navigate(to: .sessionSetup) } label: {
                Label("Set Up Event", systemImage: "calendar.badge.plus").frame(maxWidth: .infinity, minHeight: 48)
            }.buttonStyle(.borderedProminent).accessibilityIdentifier("event-setup")
            actionButton("Return to Regular Booth", systemImage: "camera.fill") { confirm = .regular }
                .accessibilityIdentifier("return-to-regular-booth")
        case .pausedOnBooth, .serverPaused:
            Button {
                if paid { confirm = .resume }
                else { Task { await perform(.resume) } }
            } label: { Label(regular ? "Resume Booth" : "Resume Event", systemImage: "play.fill").frame(maxWidth: .infinity, minHeight: 48) }
                .buttonStyle(.borderedProminent).accessibilityIdentifier("resume-event")
        case .needsReview where run == nil && [.ended, .archived].contains(lifecycle.confirmedCommercialLifecycle):
            Button { confirm = .regular } label: { Label("Return to Regular Booth", systemImage: "camera").frame(maxWidth: .infinity, minHeight: 48) }
                .buttonStyle(.borderedProminent).accessibilityIdentifier("return-to-regular-booth")
        case .needsReview(let reason) where reason.contains("ended for every booth"):
            Button { confirm = .finishEnding } label: { Label("Finish Ending on This iPad", systemImage: "flag.checkered").frame(maxWidth: .infinity, minHeight: 48) }
                .buttonStyle(.borderedProminent)
        default:
            Button { workspace.navigate(to: .sessionSetup) } label: {
                Label(setupTitle, systemImage: "slider.horizontal.3").frame(maxWidth: .infinity, minHeight: 48)
            }
            .buttonStyle(.borderedProminent).accessibilityIdentifier("event-setup")
        }
    }

    @ViewBuilder private var eventControls: some View {
        if run != nil || lifecycle.canRecordUpgradedRun || lifecycle.linkedCommercialEventID != nil {
            Divider()
            DisclosureGroup("Event controls") {
                VStack(alignment: .leading, spacing: 12) {
                    if let run {
                        fact("Design", library.design(id: run.context.designID)?.displayName ?? "Studio branding")
                        fact("Started", run.createdAt.formatted(date: .abbreviated, time: .shortened))
                    }
                    actionButton("Detailed Booth Health", systemImage: "stethoscope") { showsHealth = true }
                    if lifecycle.canRecordUpgradedRun {
                        actionButton("Record Event Run", systemImage: "list.bullet.rectangle") { confirm = .recordRun }
                            .accessibilityIdentifier("record-event-run")
                    }
                    if lifecycle.linkedCommercialEventID != nil, run == nil || [.active, .paused].contains(run?.status), lifecycle.confirmedCommercialLifecycle == .active {
                        actionButton("Pause Paid Event for Every Booth", systemImage: "pause.circle") { confirm = .pauseCommercial }
                    }
                    Text("Ending requires a separate review. Sessions, galleries, payment recovery and history are retained.")
                        .font(.footnote).foregroundStyle(OperatorPalette.secondaryText)
                }.padding(.top, 12)
            }.font(.callout).tint(Brand.burgundy).disabled(busy)
        }
    }

    private var setupTitle: String {
        switch status {
        case .completed, .archived: "Set Up an Event"
        case .regular: "Set Up an Event"
        case .accepting, .unconfirmed: "Edit Event Setup"
        default: "Set Up & Start"
        }
    }

    private func actionButton(_ title: String, systemImage: String, role: ButtonRole? = nil, action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) { Label(title, systemImage: systemImage).frame(maxWidth: .infinity, minHeight: 48) }
            .buttonStyle(.bordered)
    }

    private func fact(_ title: String, _ value: String) -> some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4)) : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 16))
        return layout {
            Text(title).foregroundStyle(OperatorPalette.secondaryText)
            if !typeSize.isAccessibilitySize { Spacer(minLength: 0) }
            Text(value).multilineTextAlignment(typeSize.isAccessibilitySize ? .leading : .trailing)
                .foregroundStyle(Brand.ink).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading).accessibilityElement(children: .combine)
    }

    // MARK: Derived text

    private var eventName: String {
        if regular { return "Regular Booth" }
        if let run { return run.context.name.isEmpty ? "Regular Sessions" : run.context.name }
        return "Made to Keep Studios"
    }
    private var appliedDesign: String { library.design(id: library.library.appliedEventID)?.displayName ?? "Studio branding" }
    private var guestAdmissionLine: String {
        if acceptance.state.blocked { return "Not accepting new guests" }
        if status.isAccepting { return "Open · equipment checks shown below" }
        if case .unconfirmed = status { return "Payment status must be checked" }
        return "Needs operator attention"
    }
    private var paymentLine: String {
        if regular { return "No payment required" }
        if !paid {
            let policy = local.activePolicy
            return "No payment · \(policy.defaultCopies) included, up to \(policy.maxCopies)"
        }
        if let event = server?.event {
            let methods = [event.qrphEnabled ? "QR Ph" : nil, event.cashEnabled ? "Cash" : nil].compactMap { $0 }.joined(separator: " + ")
            return "\(methods) · \(PHPPriceFormatter.string(centavos: event.unitPriceCentavos))/copy"
        }
        return server?.error != nil ? "Paid — price not confirmed" : "Paid per print"
    }
    private var statusColor: Color {
        switch status {
        case .accepting, .regular: OperatorPalette.ready
        case .recoveryRequired: OperatorPalette.danger
        case .needsReview, .unconfirmed, .pausedOnBooth, .serverPaused: OperatorPalette.warning
        default: Brand.burgundy
        }
    }

    // MARK: Actions

    private func refresh() async {
        guard loadsRemote else { return }
        if paid { server = await ServerBoothStatus.load() }
        await lifecycle.refresh()
    }

    private func perform(_ item: Confirmation) async {
        confirm = nil
        switch item {
        case .pauseBooth: await lifecycle.pauseBooth()
        case .pauseCommercial: await lifecycle.pauseCommercialEvent()
        case .resume: _ = await lifecycle.resume()
        case .finishEnding: await lifecycle.finishEndingLocally()
        case .recordRun: _ = await lifecycle.recordUpgradedRun()
        case .regular: _ = await lifecycle.returnToRegular()
        }
        if loadsRemote, paid { server = await ServerBoothStatus.load() }
    }

    private var confirmTitle: String {
        switch confirm {
        case .pauseBooth: "Pause this booth?"
        case .pauseCommercial: "Pause the paid event for every booth?"
        case .resume: "Resume this event?"
        case .finishEnding: "Finish ending on this iPad?"
        case .recordRun: "Record an event run for this event?"
        case .regular: "Return to Regular Booth?"
        case nil: ""
        }
    }
    private func confirmButton(_ item: Confirmation) -> String {
        switch item {
        case .pauseBooth: "Pause This Booth"
        case .pauseCommercial: "Pause Paid Event"
        case .resume: "Resume Event"
        case .finishEnding: "Complete This iPad's Run"
        case .recordRun: "Record Event Run"
        case .regular: "Return to Regular Booth"
        }
    }
    private func confirmMessage(_ item: Confirmation) -> String {
        switch item {
        case .pauseBooth:
            return lifecycle.linkedCommercialEventID == nil
                ? "New guests can't start on this iPad. A guest already in a session finishes normally."
                : "New guests can't start on this iPad. The paid event stays open for other booths. Paid purchases and print recovery are kept."
        case .pauseCommercial:
            return "Every booth on this paid event stops taking new checkouts, including this one. Paid purchases remain usable. Resume restarts it for all booths."
        case .resume:
            return lifecycle.confirmedCommercialLifecycle == .paused
                ? "Rechecks the saved setup and price, resumes the paid event for every booth, then reopens this iPad."
                : "Rechecks the saved setup and payment settings, then reopens this iPad with the same event run."
        case .finishEnding:
            return "The paid event has already ended. This completes this iPad's run; its sessions, galleries and reports are kept."
        case .regular:
            return "Verify the previous event and recovery records, then enable local no-payment sessions with your Regular Booth defaults. Other booths are unchanged. History, saved designs and drafts are kept."
        case .recordRun:
            return "This event was running before this iPad recorded event runs. After the paid event is confirmed, a run is recorded so statistics start now. Guest admission, prices, payments and earlier sessions are not changed."
        }
    }
}

/// Confirmed End Event, with the scope, open obligations and retained history spelled out.
struct EndEventSheet: View {
    @ObservedObject var lifecycle: EventLifecycleCoordinator
    @Binding var isPresented: Bool
    @ObservedObject private var operations = EventOperationalState.shared
    @State private var closesCommercial = false
    @State private var result: Bool?

    private var run: EventRunRecord? { lifecycle.runs.current }

    var body: some View {
        NavigationStack {
            Form {
                Section("Ending") {
                    LabeledContent("Event", value: run?.context.name ?? "—")
                    if let run {
                        LabeledContent("Started", value: run.createdAt.formatted(date: .abbreviated, time: .shortened))
                        LabeledContent("Run ID", value: String(run.id.prefix(8)))
                    }
                }
                if lifecycle.linkedCommercialEventID != nil {
                    Section {
                        Picker("Scope", selection: $closesCommercial) {
                            Text("This iPad only").tag(false)
                            Text("This iPad and the paid event").tag(true)
                        }
                        .pickerStyle(.inline).labelsHidden()
                    } header: { Text("What ends") } footer: {
                        Text(closesCommercial
                             ? "Ends the paid event for every booth. It cannot be restarted; reuse the design with a new paid occurrence."
                             : "This iPad switches to Regular Booth with no payment required. Other booths keep the paid event. The original server connection must be reachable to verify the switch.")
                    }
                }
                Section("Before ending") {
                    if let reason = SessionSetupSafety.blockingReason { Label(reason, systemImage: "exclamationmark.triangle").foregroundStyle(OperatorPalette.warning) }
                    else { Label("No guest, payment or print is in progress.", systemImage: "checkmark.circle") }
                    LabeledContent("Galleries still uploading", value: "\(operations.pendingUploadCount)")
                    if operations.pendingUploadCount > 0 { Text("Keep the app open online afterwards; waiting galleries keep uploading.").font(.footnote) }
                }
                Section("Kept after ending") {
                    Text("Sessions, receipts, photos, galleries, print history, payment orders and entitlements, and this run's reports. This iPad returns to Regular Booth with your saved defaults and no payment required.")
                        .font(.callout)
                }
                Section {
                    Button(role: .destructive) {
                        Task {
                            let ended = await lifecycle.end(scope: closesCommercial ? .thisBoothAndCommercialEvent : .thisBooth)
                            result = ended
                            if ended { isPresented = false }
                        }
                    } label: {
                        Text(closesCommercial ? "End Event for Every Booth" : "End Event on This iPad").font(.headline).frame(maxWidth: .infinity, minHeight: 48)
                    }
                    .disabled(lifecycle.operation != nil || SessionSetupSafety.blockingReason != nil)
                    .accessibilityIdentifier("confirm-end-event")
                    if lifecycle.operation == .ending { ProgressView("Confirming…") }
                    if result == false { Label(lifecycle.message, systemImage: "exclamationmark.triangle").foregroundStyle(OperatorPalette.danger) }
                }
            }
            .navigationTitle("End Event")
            .tint(MadeToKeepTheme.ColorPalette.burgundy)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { isPresented = false }.disabled(lifecycle.operation != nil) } }
            .interactiveDismissDisabled(lifecycle.operation != nil)
        }
    }
}
