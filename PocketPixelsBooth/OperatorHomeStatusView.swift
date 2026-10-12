import SwiftUI

struct OperatorBoothStatusCard: View {
    @ObservedObject private var acceptance = SessionAcceptanceStore.shared
    @ObservedObject private var operations = EventOperationalState.shared
    @ObservedObject private var printer = PrinterCoordinator.shared
    @State private var server: ServerBoothStatus?
    @State private var source = CommercialPolicySource.load()
    @State private var local = CommercialEventRunStore.load()
    @State private var preparedEvent: OperatorEventDetail?

    private var accepting: Bool {
        guard !acceptance.state.blocked, SessionSetupSafety.blockingReason == nil else { return false }
        if source == .localPrepaid { return local.acceptsNewSessions && local.activePolicy.validationMessage == nil }
        guard let event = server?.event else { return false }
        return acceptance.permits(eventID: event.id, binding: OperatorWorkspace.shared.serverBinding)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("BOOTH STATUS").font(.caption.weight(.semibold)).tracking(2).foregroundStyle(.secondary)
            Text("Made to Keep Studios").font(.largeTitle.weight(.semibold))
            if source == .localPrepaid {
                if !local.name.isEmpty { Text(local.name).font(.title3) }
                Text("Prepaid / Free · No payment required").font(.headline)
                Text("\(local.activePolicy.defaultCopies) included · maximum \(local.activePolicy.maxCopies) copies").foregroundStyle(.secondary)
            } else if let event = server?.event {
                Text(event.name).font(.title3)
                Text("Pay Per Print · \(PHPPriceFormatter.string(centavos: event.unitPriceCentavos))/copy").font(.headline)
                Text("Default \(event.defaultCopies) · maximum \(event.maxCopies) copies · \([event.qrphEnabled ? "QR Ph" : nil, event.cashEnabled ? "Cash — unverified" : nil].compactMap { $0 }.joined(separator: ", "))").foregroundStyle(.secondary)
            } else if let preparedEvent, let policy = preparedEvent.latestRevision {
                Text(preparedEvent.event.name).font(.title3)
                Text("Pay Per Print · \(PHPPriceFormatter.string(centavos: policy.unitPriceCentavos))/copy").font(.headline)
                Text("Default \(policy.defaultCopies) · maximum \(policy.maxCopies) copies · \([policy.qrphEnabled ? "QR Ph" : nil, policy.cashEnabled ? "Cash — unverified" : nil].compactMap { $0 }.joined(separator: ", "))").foregroundStyle(.secondary)
                Text(preparedEvent.event.lifecycle == .draft ? "Prepared setup — not yet applied" : preparedEvent.event.lifecycle.displayName).font(.callout).foregroundStyle(.secondary)
            } else {
                Text("Pay Per Print").font(.headline)
                Text(server?.inactiveDescription ?? "No active paid event").foregroundStyle(.secondary)
                Text("Choose an event in Session Setup to review its price and copies.").font(.callout).foregroundStyle(.secondary)
            }
            Divider()
            Label(accepting ? "Accepting guests" : "Not accepting guests", systemImage: accepting ? "checkmark.circle.fill" : "pause.circle.fill")
                .font(.headline).foregroundStyle(accepting ? .green : .orange)
            LabeledContent("Printer", value: printer.state.message).font(.callout)
            if printer.requiresRecovery || operations.hasUnresolvedPrint {
                NavigationLink("Fix Printer — preserved receipt needs attention", value: OperatorWorkspaceRoute.recovery)
            }
            if let reason = SessionSetupSafety.blockingReason { Text(reason).font(.callout).foregroundStyle(.orange) }
            if source == .serverManaged, server?.error != nil { Text("Could not check payments. Check the connection in Equipment before starting.").font(.callout).foregroundStyle(.orange) }
            if let error = acceptance.storageError { Text(error).foregroundStyle(.red) }
        }
        .padding(28).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22))
        .task { await refresh() }
        .onReceive(NotificationCenter.default.publisher(for: OperatorWorkspace.didUnlock)) { _ in Task { await refresh() } }
    }
    private func refresh() async {
        source = CommercialPolicySource.load(); local = CommercialEventRunStore.load()
        if source == .serverManaged {
            server = await ServerBoothStatus.load()
            preparedEvent = nil
            if server?.event == nil, let configuration = PaymentsConfiguration.current() {
                let client = PaymentsAPIClient(configuration: configuration)
                if let events = try? await client.listEvents() {
                    let staged = OperatorWorkspace.shared.snapshot.sessionSetup
                    let stagedID = staged?.serverBinding == OperatorWorkspace.shared.serverBinding ? staged?.eventID : nil
                    let id = stagedID ?? events.first(where: { $0.lifecycle == "DRAFT" })?.id
                        ?? acceptance.state.eventID ?? events.first(where: { $0.lifecycle == "PAUSED" })?.id
                    if let id { preparedEvent = try? await client.eventDetail(id: id) }
                }
            }
        }
    }
}

struct OperatorBrandingView: View {
    var body: some View {
        List {
            Section {
                Text("Create the look of your booth. Branding works with both Prepaid / Free and Pay Per Print; it does not start or pause sessions.")
            }
            Section("Design") {
                NavigationLink("Custom Event Design", value: OperatorWorkspaceRoute.eventSetup)
                NavigationLink("Receipt Design", value: OperatorWorkspaceRoute.receiptDesign)
                NavigationLink("Sticker Studio", value: OperatorWorkspaceRoute.stickers)
            }
            Section("Preview") {
                NavigationLink("Preview Guest Experience") {
                    ScrollView { CustomerExperiencePreviewView(profile: EventProfileStore.load()).padding() }.navigationTitle("Guest Preview")
                }
            }
        }.navigationTitle("Branding & Design").tint(OperatorPalette.ink)
    }
}
