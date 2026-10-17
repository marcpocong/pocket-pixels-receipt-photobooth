import SwiftUI

private typealias Brand = MadeToKeepTheme.ColorPalette

/// The everyday home for running an event: one truthful status and the four actions an
/// attendant needs. Setup, reports and maintenance stay one tap away, not mixed in.
struct CurrentEventCard: View {
    @StateObject private var lifecycle: EventLifecycleCoordinator
    @ObservedObject private var runs: EventRunStore
    @ObservedObject private var acceptance = SessionAcceptanceStore.shared
    @ObservedObject private var library = EventDesignLibraryStore.shared
    @ObservedObject private var operations = EventOperationalState.shared
    @ObservedObject private var printer = PrinterCoordinator.shared
    @State private var server: ServerBoothStatus?
    @State private var confirm: Confirmation?
    @State private var showsEnd = false
    private let loadsRemote: Bool

    enum Confirmation: String, Identifiable { case pauseBooth, pauseCommercial, resume, finishEnding, recordRun; var id: String { rawValue } }

    init(lifecycle: EventLifecycleCoordinator? = nil, loadsRemote: Bool = true) {
        let model = lifecycle ?? EventLifecycleCoordinator()
        _lifecycle = StateObject(wrappedValue: model)
        _runs = ObservedObject(wrappedValue: model.runs)
        self.loadsRemote = loadsRemote
    }

    private var status: EventOperatorStatus { lifecycle.status }
    private var run: EventRunRecord? { runs.current }
    private var local: CommercialEventRun { CommercialEventRunStore.load() }
    private var paid: Bool { CommercialPolicySource.load() == .serverManaged }
    private var busy: Bool { lifecycle.operation != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            facts
            warnings
            actions
            if !lifecycle.message.isEmpty {
                Text(lifecycle.message).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("current-event-message")
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.ivoryLight, in: RoundedRectangle(cornerRadius: 22))
        .overlay { RoundedRectangle(cornerRadius: 22).stroke(Brand.burgundy.opacity(0.18)) }
        // The ivory card keeps its editorial palette; system colors inside it stay legible.
        .environment(\.colorScheme, .light)
        .task { await refresh() }
        .onReceive(NotificationCenter.default.publisher(for: OperatorWorkspace.didUnlock)) { _ in Task { await refresh() } }
        .confirmationDialog(confirmTitle, isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }), titleVisibility: .visible, presenting: confirm) { item in
            Button(confirmButton(item), role: [.resume, .recordRun].contains(item) ? nil : .destructive) { Task { await perform(item) } }
            Button("Cancel", role: .cancel) {}
        } message: { item in Text(confirmMessage(item)) }
        .sheet(isPresented: $showsEnd) { EndEventSheet(lifecycle: lifecycle, isPresented: $showsEnd) }
    }

    // MARK: Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("CURRENT EVENT").font(.caption.weight(.semibold)).tracking(2).foregroundStyle(Brand.burgundy)
            Text(eventName).font(.system(.largeTitle, design: .serif).weight(.semibold)).foregroundStyle(Brand.ink)
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
            Text(status.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var facts: some View {
        VStack(spacing: 10) {
            fact("Design", run.flatMap { library.design(id: $0.context.designID)?.displayName } ?? (run == nil ? appliedDesign : "Studio branding"))
            if let run { fact("Started", run.createdAt.formatted(date: .abbreviated, time: .shortened)) }
            else if lifecycle.canRecordUpgradedRun { fact("Event run", "Not recorded yet — statistics start with the first guest or Record Event Run") }
            fact("Payment", paymentLine)
            fact("Guest admission", acceptance.state.blocked ? "Closed on this iPad" : "Open on this iPad")
            fact("Printer", printer.requiresRecovery ? "Recovery required" : printer.state.message)
            fact("Galleries waiting", "\(operations.pendingUploadCount)")
            if paid, let checked = lifecycle.lastCheckedAt { fact("Server checked", checked.formatted(date: .omitted, time: .shortened)) }
        }
        .font(.callout)
    }

    @ViewBuilder private var warnings: some View {
        if let reason = SessionSetupSafety.recoveryReason {
            NavigationLink(value: printer.requiresRecovery || operations.hasUnresolvedPrint ? OperatorWorkspaceRoute.recovery : OperatorWorkspaceRoute.payments) {
                Label(reason, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).frame(minHeight: 44, alignment: .leading)
            }
        }
        if let error = runs.storageError, !runs.historyUnreadable {
            Label("Statistics could not be saved: \(error)", systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange)
        }
    }

    @ViewBuilder private var actions: some View {
        let columns = [GridItem(.adaptive(minimum: 200), spacing: 12)]
        LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
            primaryAction
            if run == nil || run?.status == .active, !acceptance.state.blocked {
                actionButton("Pause Booth", systemImage: "pause.fill") { confirm = .pauseBooth }
                    .accessibilityIdentifier("pause-booth")
            }
            if lifecycle.linkedCommercialEventID != nil, run == nil || [.active, .paused].contains(run?.status), lifecycle.confirmedCommercialLifecycle == .active {
                actionButton("Pause Paid Event", systemImage: "pause.circle") { confirm = .pauseCommercial }
            }
            if lifecycle.canRecordUpgradedRun {
                actionButton("Record Event Run", systemImage: "list.bullet.rectangle") { confirm = .recordRun }
                    .accessibilityIdentifier("record-event-run")
            }
            if [.active, .paused].contains(run?.status) {
                actionButton("End Event", systemImage: "flag.checkered", role: .destructive) { showsEnd = true }
                    .accessibilityIdentifier("end-event")
            }
            NavigationLink(value: OperatorWorkspaceRoute.sales) {
                Label("View Reports", systemImage: "chart.bar").frame(maxWidth: .infinity, minHeight: 48)
            }.buttonStyle(.bordered).accessibilityIdentifier("view-reports")
            if paid || runs.pendingTransition != nil {
                actionButton("Check Status", systemImage: "arrow.clockwise") { Task { await refresh() } }
            }
        }
        .controlSize(.large)
        .tint(Brand.burgundy)
        .disabled(busy)
    }

    @ViewBuilder private var primaryAction: some View {
        switch status {
        case .pausedOnBooth, .serverPaused:
            Button { confirm = .resume } label: { Label("Resume Event", systemImage: "play.fill").frame(maxWidth: .infinity, minHeight: 48) }
                .buttonStyle(.borderedProminent).accessibilityIdentifier("resume-event")
        case .needsReview(let reason) where reason.contains("ended for every booth"):
            Button { confirm = .finishEnding } label: { Label("Finish Ending on This iPad", systemImage: "flag.checkered").frame(maxWidth: .infinity, minHeight: 48) }
                .buttonStyle(.borderedProminent)
        default:
            NavigationLink(value: OperatorWorkspaceRoute.sessionSetup) {
                Label(setupTitle, systemImage: "slider.horizontal.3").frame(maxWidth: .infinity, minHeight: 48)
            }
            .buttonStyle(.borderedProminent).accessibilityIdentifier("event-setup")
        }
    }

    private var setupTitle: String {
        switch status {
        case .completed, .archived: "Start New Occurrence"
        case .accepting, .unconfirmed: "Edit Event Setup"
        default: "Set Up & Start"
        }
    }

    private func actionButton(_ title: String, systemImage: String, role: ButtonRole? = nil, action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) { Label(title, systemImage: systemImage).frame(maxWidth: .infinity, minHeight: 48) }
            .buttonStyle(.bordered)
    }

    private func fact(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 16)
            Text(value).multilineTextAlignment(.trailing).foregroundStyle(Brand.ink)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Derived text

    private var eventName: String {
        if let run { return run.context.name.isEmpty ? "Regular Sessions" : run.context.name }
        return library.design(id: library.library.appliedEventID)?.displayName ?? "Made to Keep Studios"
    }
    private var appliedDesign: String { library.design(id: library.library.appliedEventID)?.displayName ?? "Studio branding" }
    private var paymentLine: String {
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
        case .accepting: .green
        case .recoveryRequired: .red
        case .needsReview, .unconfirmed, .pausedOnBooth, .serverPaused: .orange
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
                             : "Other booths on the same paid event keep taking guests. End the paid event when every booth is done.")
                    }
                }
                Section("Before ending") {
                    if let reason = SessionSetupSafety.blockingReason { Label(reason, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                    else { Label("No guest, payment or print is in progress.", systemImage: "checkmark.circle") }
                    LabeledContent("Galleries still uploading", value: "\(operations.pendingUploadCount)")
                    if operations.pendingUploadCount > 0 { Text("Keep the app open online afterwards; waiting galleries keep uploading.").font(.footnote) }
                }
                Section("Kept after ending") {
                    Text("Sessions, receipts, photos, galleries, print history, payment orders and entitlements, and this run's reports. Nothing is deleted.")
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
                    if result == false { Label(lifecycle.message, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                }
            }
            .navigationTitle("End Event")
            .tint(MadeToKeepTheme.ColorPalette.burgundy)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { isPresented = false }.disabled(lifecycle.operation != nil) } }
            .interactiveDismissDisabled(lifecycle.operation != nil)
        }
    }
}
