import SwiftUI

/// The single editor for a server-managed event: load the server state, edit a local copy, save it
/// as a versioned server draft, then explicitly publish that exact acknowledged revision. Nothing
/// here reports success until the server has confirmed it.
struct ServerEventEditorView: View {
    let eventID: String
    let reportsOnly: Bool
    let maintenance: Bool
    @State private var maintenanceNeedsRefresh = false

    @State private var detail: OperatorEventDetail?
    @State private var name = ""
    @State private var venue = ""
    @State private var draft = ServerPolicyDraft()
    @State private var baseline: (name: String, venue: String, draft: ServerPolicyDraft)?
    @State private var message = ""
    @State private var isBusy = false
    @State private var hasVersionConflict = false
    @State private var pendingAction: LifecycleAction?
    @State private var summary: OperatorSalesSummary?
    @State private var reportError: String?
    @State private var reportRequest = UUID()
    @State private var conflictsError: String?
    @State private var ordersError: String?
    @State private var ordersLoading = false
    @State private var ordersRequest = UUID()
    @State private var localOfflineCount = 0
    @State private var localOfflineCentavos = 0
    @State private var legacyOfflineCount = 0
    @State private var localOfflineError: String? = "Local offline cash has not been loaded."
    @State private var countText = ""
    @State private var countReason = "End-of-event physical count"
    @State private var orderFilter = "all"
    @State private var orders: [OperatorOrderRow] = []
    @State private var nextOrderCursor: String?
    @State private var conflicts: [OperatorOfflineConflict] = []
    @State private var exportURL: URL?
    @State private var exportComplete = true
    @State private var baseServerVersion: Int?
    @State private var confirmDiscard = false
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var workspace = OperatorWorkspace.shared

    init(eventID: String, reportsOnly: Bool = false, maintenance: Bool = false) {
        self.eventID = eventID
        self.reportsOnly = reportsOnly
        self.maintenance = maintenance
        let restored = OperatorWorkspace.shared.serverDraft(eventID: eventID)
        _name = State(initialValue: restored?.name ?? "")
        _venue = State(initialValue: restored?.venue ?? "")
        _draft = State(initialValue: restored?.policy ?? ServerPolicyDraft())
        _baseServerVersion = State(initialValue: restored?.baseVersion)
    }

    private var client: PaymentsAPIClient? { PaymentsConfiguration.current().map { PaymentsAPIClient(configuration: $0) } }

    enum LifecycleAction: String, Identifiable {
        case publish, activate, pause, resume, end, archive
        var id: String { rawValue }
    }

    private var hasUnsavedChanges: Bool {
        guard let baseline else { return false }
        return baseline.name != name || baseline.venue != venue || !baseline.draft.matchesForEditing(draft)
    }

    var body: some View {
        Form {
            if maintenance, let detail {
                Section("Close or Archive Event") {
                    LabeledContent("Event status", value: detail.event.lifecycle.displayName)
                    Text("Session Setup manages price, copies, payment methods and starting or pausing sessions. Closing an event retains payment history and purchased entitlements.")
                    if [.active, .paused].contains(detail.event.lifecycle) {
                        Button("End Event", role: .destructive) { pendingAction = .end }.disabled(maintenanceNeedsRefresh)
                    } else if [.draft, .ended].contains(detail.event.lifecycle) {
                        Button("Archive Event", role: .destructive) { pendingAction = .archive }.disabled(maintenanceNeedsRefresh)
                    }
                    if !message.isEmpty { Text(message) }
                    Button("Refresh Current Status") { Task { await reload(keepEdits: true) } }
                }
            }
            if !reportsOnly { statusSection }
            if !reportsOnly, let detail, ![.ended, .archived].contains(detail.event.lifecycle) {
                detailsSection
                pricingSection
                formatsSection
                saveSection(detail)
            }
            if !reportsOnly, let detail { lifecycleSection(detail) }
            salesSections
        }
        .navigationTitle(detail?.event.name ?? "Server Event")
        .disabled(isBusy)
        .overlay { if isBusy { ProgressView().controlSize(.large) } }
        .task { await reload(keepEdits: workspace.serverDraft(eventID: eventID) != nil) }
        .onChange(of: name) { _, _ in persistDraft() }
        .onChange(of: venue) { _, _ in persistDraft() }
        .onChange(of: draft) { _, _ in persistDraft() }
        .onReceive(NotificationCenter.default.publisher(for: OperatorWorkspace.didUnlock)) { _ in
            Task { await reload(keepEdits: hasUnsavedChanges || workspace.serverDraft(eventID: eventID) != nil) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { persistDraft(); pendingAction = nil; confirmDiscard = false }
        }
        .confirmationDialog("Discard local edits?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard Local Edits & Reload", role: .destructive) {
                guard OperatorAccessPermit.shared.isAuthorized else { return }
                if !reportsOnly { workspace.removeServerDraft(eventID: eventID) }
                Task { await reload(keepEdits: false) }
            }
            Button("Keep Editing", role: .cancel) {}
        } message: { Text("This replaces only this event's local setup draft with its current server values. Nothing is published.") }
        .confirmationDialog(confirmationTitle, isPresented: Binding(get: { pendingAction != nil }, set: { if !$0 { pendingAction = nil } }), titleVisibility: .visible, presenting: pendingAction) { action in
            Button(confirmationButton(action), role: [.end, .archive].contains(action) ? .destructive : nil) {
                Task { await perform(action) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { action in
            Text(confirmationMessage(action))
        }
    }

    // MARK: Status

    @ViewBuilder private var statusSection: some View {
        Section("Status") {
            if let detail {
                LabeledContent("Environment", value: PaymentsConfiguration.current()?.environment.uppercased() ?? "NOT CONFIGURED")
                LabeledContent("Lifecycle", value: detail.event.lifecycle.rawValue)
                LabeledContent("Customer acceptance", value: detail.event.lifecycle == .active ? "Active" : "Closed to new sessions")
                LabeledContent("Event ID", value: detail.event.id)
                LabeledContent("Server version", value: "\(detail.event.version)")
                if let active = detail.activePolicy {
                    LabeledContent("Live for guests", value: "Revision \(active.revision) · \(priceLabel(active))")
                    policySummary(active, prefix: "Published")
                } else {
                    LabeledContent("Live for guests", value: "Nothing published")
                }
                if detail.hasUnpublishedRevision, let latest = detail.latestRevision {
                    LabeledContent("Saved server draft", value: "Revision \(latest.revision) · \(priceLabel(latest)) · not published")
                    policySummary(latest, prefix: "Draft")
                }
                LabeledContent("This editor", value: hasUnsavedChanges ? "Unsaved changes on this iPad" : "Matches the server")
                    .foregroundStyle(hasUnsavedChanges ? .orange : .primary)
                LabeledContent("Outstanding paid entitlements", value: "\(detail.outstandingEntitlements)")
            } else {
                Text("Loading from the server…").foregroundStyle(.secondary)
            }
            if !message.isEmpty {
                Text(message).font(.footnote)
            }
            if hasVersionConflict {
                Text("Local edits began at server version \(baseServerVersion ?? 0); the current version is \(detail?.event.version ?? 0). Saving and publishing are blocked until you review.")
                    .foregroundStyle(.orange)
                if let latest = detail?.latestRevision {
                    LabeledContent("Your price / server price", value: "\(draft.priceText) / \(PesoAmount.editingText(centavos: latest.unitPriceCentavos))")
                    LabeledContent("Your copies / server copies", value: "\(draft.defaultCopies)–\(draft.maxCopies) / \(latest.defaultCopies)–\(latest.maxCopies)")
                    LabeledContent("Server name", value: detail?.event.name ?? "")
                    LabeledContent("Server venue", value: detail?.event.venue ?? "")
                    LabeledContent("Server methods", value: [latest.qrphEnabled ? "QR Ph" : nil, latest.cashEnabled ? "Cash" : nil].compactMap { $0 }.joined(separator: ", "))
                    LabeledContent("Server formats", value: latest.supportedFormats.joined(separator: ", "))
                }
                Button("I've Reviewed — Keep My Edits for the Current Version") {
                    guard OperatorAccessPermit.shared.isAuthorized else { return }
                    baseServerVersion = detail?.event.version
                    hasVersionConflict = false
                    persistDraft()
                    message = "Your reviewed edits are still local. Save Draft to Server when ready."
                }
            }
            if hasUnsavedChanges || workspace.serverDraft(eventID: eventID) != nil {
                Button("Discard Local Edits…", role: .destructive) { confirmDiscard = true }
            }
            Button("Refresh Server — Keep Local Edits") { Task { await reload(keepEdits: hasUnsavedChanges) } }
        }
    }

    // MARK: Editing

    @ViewBuilder private func policySummary(_ policy: OperatorPolicyRevision, prefix: String) -> some View {
        LabeledContent("\(prefix) copies", value: "Default \(policy.defaultCopies) · maximum \(policy.maxCopies)")
        LabeledContent("\(prefix) payment methods", value: policy.commercialMode == .privatePrepaid ? "Prepaid" :
            [policy.qrphEnabled ? "QR Ph" : nil, policy.cashEnabled ? "Cash (customer declared)" : nil].compactMap { $0 }.joined(separator: ", "))
        LabeledContent("\(prefix) offline cash", value: policy.cashEnabled && policy.offlineValidUntil != nil ? "Allowed until \(policy.offlineValidUntil!.formatted())" : "Disabled")
    }

    @ViewBuilder private var detailsSection: some View {
        Section("Event") {
            TextField("Event name", text: $name)
            TextField("Venue", text: $venue)
        }
    }

    @ViewBuilder private var pricingSection: some View {
        Section {
            Picker("Guest charging", selection: $draft.commercialMode) {
                ForEach(CommercialEventMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            if draft.commercialMode == .payPerPrint {
                HStack {
                    Text("Price per copy")
                    Spacer()
                    Text("₱").foregroundStyle(.secondary)
                    TextField("0.00", text: $draft.priceText)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 140)
                        .accessibilityLabel("Price per copy in pesos")
                }
                if let centavos = draft.unitPriceCentavos, centavos > 0 {
                    Text("Guests will see \(PHPPriceFormatter.string(centavos: centavos)) per copy.").font(.footnote).foregroundStyle(.secondary)
                }
                Toggle("QR Ph", isOn: $draft.qrPhEnabled)
                Toggle("Cash — guest self-reported", isOn: $draft.cashEnabled)
                Toggle("Allow offline cash (signed, time-limited)", isOn: $draft.offlineCashEnabled)
                    .disabled(!draft.cashEnabled)
                if draft.offlineCashEnabled {
                    DatePicker("Offline cash allowed until", selection: $draft.offlineValidUntil, in: Date()...)
                    Text("Each iPad receives a signed policy valid for at most a few hours within this limit. A disconnected iPad cannot learn of a pause until it reconnects.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } else {
                Toggle("Guests may choose copies", isOn: $draft.prepaidGuestCopyChoice)
            }
            Stepper("Maximum copies: \(draft.maxCopies)", value: Binding(get: { draft.maxCopies }, set: { draft.maxCopies = $0; draft.defaultCopies = min(draft.defaultCopies, $0) }), in: PaymentPolicySnapshot.copyRange)
            Stepper("Default copies: \(draft.defaultCopies)", value: $draft.defaultCopies, in: 1...draft.maxCopies)
            if let validation = draft.validationMessage() {
                Label(validation, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            }
        } header: {
            Text("Charging Policy")
        }
    }

    @ViewBuilder private var formatsSection: some View {
        Section("Formats") {
            ForEach(BoothFormat.allCases, id: \.self) { format in
                Toggle(format.displayName, isOn: Binding(
                    get: { draft.supports(format) },
                    set: { draft.setFormat(format, enabled: $0) }
                ))
            }
        }
    }

    @ViewBuilder private func saveSection(_ detail: OperatorEventDetail) -> some View {
        Section {
            Button("Save Draft to Server") { Task { await saveDraft(detail) } }
                .disabled(!hasUnsavedChanges || hasVersionConflict || draft.requestBody() == nil || name.trimmingCharacters(in: .whitespaces).isEmpty)
            if let latest = detail.latestRevision, detail.hasUnpublishedRevision || detail.event.lifecycle == .draft {
                Button(detail.event.lifecycle == .draft ? "Publish & Activate Revision \(latest.revision)" : "Publish Revision \(latest.revision) to Guests") {
                    pendingAction = detail.event.lifecycle == .draft ? .activate : .publish
                }
                .disabled(hasUnsavedChanges || hasVersionConflict)
                if hasUnsavedChanges {
                    Text("Save the draft first. Only a saved server revision can be published.").font(.footnote).foregroundStyle(.secondary)
                }
            }
        } footer: {
            Text("Saving creates a new server draft revision; guests keep the published policy until you publish. Guests already checking out keep the price they were shown.")
        }
    }

    @ViewBuilder private func lifecycleSection(_ detail: OperatorEventDetail) -> some View {
        Section {
            switch detail.event.lifecycle {
            case .draft:
                Button("Archive Draft", role: .destructive) { pendingAction = .archive }
            case .active:
                Button("Pause New Sessions") { pendingAction = .pause }
                Button("End Event", role: .destructive) { pendingAction = .end }
            case .paused:
                Button("Resume") { pendingAction = .resume }
                Button("End Event", role: .destructive) { pendingAction = .end }
            case .ended:
                Button("Archive Event", role: .destructive) { pendingAction = .archive }
            case .archived:
                Text("Archived. Reports remain available.").foregroundStyle(.secondary)
            }
        } header: {
            Text("Lifecycle")
        } footer: {
            Text("Pausing or ending stops new checkouts and revokes offline policies at the server. Paid entitlements that already exist remain usable.")
        }
    }

    // MARK: Sales

    @ViewBuilder private var salesSections: some View {
        Section("Report Status") {
            LabeledContent("Environment", value: PaymentsConfiguration.current()?.environment.uppercased() ?? "NOT CONFIGURED")
            Text("Financial totals cover this commercial event across all runs and iPads. Event-run statistics are available in Sales & Reports.").font(.footnote)
            if let reportError { Label(reportError, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
            if let conflictsError { Label(conflictsError, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            if summary == nil, reportError == nil { Text("Loading financial report…") }
            Button("Refresh Financial Report") { Task { await reload(keepEdits: true) } }
            NavigationLink("Operator API Credentials", value: OperatorWorkspaceRoute.payments)
            if legacyOfflineCount > 0 { Text("\(legacyOfflineCount) legacy offline cash record(s) have no saved environment. Review in Payment Maintenance; their amounts are excluded here.").foregroundStyle(.orange) }
            if let localOfflineError { Label(localOfflineError, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            else { LabeledContent("Offline cash waiting on this iPad", value: "\(localOfflineCount) · \(PHPPriceFormatter.string(centavos: localOfflineCentavos))") }
        }
        if let summary {
            Section("Sales Provenance — server authoritative") {
                LabeledContent("QR Ph verified (LIVE)", value: PHPPriceFormatter.string(centavos: summary.verifiedQRPhLiveCentavos))
                LabeledContent("QR Ph verified (TEST, excluded)", value: PHPPriceFormatter.string(centavos: summary.verifiedQRPhTestCentavos))
                LabeledContent("Cash confirmed by attendant", value: summary.cashOperatorConfirmedCentavos.map { PHPPriceFormatter.string(centavos: $0) } ?? "Not reported by server")
                LabeledContent("Cash guest-declared (unverified)", value: PHPPriceFormatter.string(centavos: summary.cashSelfReportedCentavos))
                if let offline = summary.cashSelfReportedOfflineSyncedCentavos, offline > 0 {
                    LabeledContent("  of which synced from offline", value: PHPPriceFormatter.string(centavos: offline))
                }
                if let physical = summary.physicalCashCount {
                    LabeledContent("Cash physically counted", value: PHPPriceFormatter.string(centavos: physical.countedCentavos))
                    LabeledContent("Variance (counted − all cash orders)", value: PHPPriceFormatter.string(centavos: physical.varianceCentavos))
                    if physical.provisional || localOfflineError != nil { Label("Provisional: offline cash is still unsynced or in conflict", systemImage: "exclamationmark.triangle") }
                } else {
                    Text("Cash reconciliation: NOT RECONCILED").foregroundStyle(.secondary)
                }
                if let unresolved = summary.unresolvedQRCount, unresolved > 0 {
                    Label("\(unresolved) QR Ph payment(s) unresolved", systemImage: "clock.badge.questionmark")
                }
                LabeledContent("Offline conflicts — server total", value: summary.offlineConflictCount.map(String.init) ?? "Not reported by server")
                if let late = summary.lateQRPaidReviewCentavos, late > 0 {
                    Label("\(PHPPriceFormatter.string(centavos: late)) paid late on replaced checkouts — review for refund", systemImage: "exclamationmark.bubble")
                }
                Text("Refunds, complimentary prints, provider fees and bank payouts are not tracked. Settlement: \(summary.settlementStatus.replacingOccurrences(of: "_", with: " ").lowercased()).")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Print Copies") {
                LabeledContent("Purchased", value: "\(summary.printUtilization.purchased)")
                LabeledContent("Transport delivered", value: summary.printUtilization.delivered.map(String.init) ?? "Not reported by server")
                LabeledContent("Legacy confirmed", value: "\(summary.printUtilization.confirmed)")
                Text("Transport delivery does not verify paper output with a sensor.").font(.footnote)
                LabeledContent("Uncertain (inspect paper)", value: "\(summary.printUtilization.uncertain)")
                LabeledContent("Failed", value: "\(summary.printUtilization.failed)")
            }
            Section {
                HStack {
                    Text("Counted cash")
                    Spacer()
                    Text("₱").foregroundStyle(.secondary)
                    TextField("0.00", text: $countText).keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(maxWidth: 140)
                }
                TextField("Reason", text: $countReason)
                Button("Save New Count") { Task { await saveCount() } }
                    .disabled(PesoAmount.centavos(fromPesoText: countText) == nil || countReason.trimmingCharacters(in: .whitespaces).isEmpty)
            } header: {
                Text("End-of-Event Cash Count")
            } footer: {
                Text("Each count is appended and audited; it never overwrites guest-declared cash.")
            }
        }
        Section("Orders") {
            Picker("Show", selection: $orderFilter) {
                Text("All").tag("all"); Text("Unresolved QR").tag("unresolved"); Text("Needs review").tag("review")
                Text("Cash").tag("cash"); Text("QR Ph").tag("qr")
            }
            .onChange(of: orderFilter) { _, _ in Task { await loadOrders(reset: true) } }
            if let ordersError { Label(ordersError, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
            if ordersLoading { ProgressView("Loading orders…") }
            if orders.isEmpty, !ordersLoading, ordersError == nil { Text("No orders match this filter.").foregroundStyle(.secondary) }
            ForEach(orders) { order in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(PHPPriceFormatter.string(centavos: order.totalCentavos)) · \(order.copies)× \(order.boothFormat)")
                    Text("\(order.category) · \(order.state)\(order.lastReconcileError != nil ? " · provider check failed" : "")")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(order.createdAt, format: .dateTime.month().day().hour().minute()).font(.caption2).foregroundStyle(.secondary)
                }
            }
            if nextOrderCursor != nil {
                Button("Load More") { Task { await loadOrders(reset: false) } }.disabled(ordersLoading)
            }
        }
        if !conflicts.isEmpty {
            Section("Recent Offline Cash Conflicts — up to 50") {
                ForEach(conflicts) { conflict in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(conflict.reason.replacingOccurrences(of: "_", with: " ")) · seq \(conflict.localSequence.map(String.init) ?? "?")")
                        Text("Device \(conflict.deviceId) · \(conflict.copies.map { "\($0) copies" } ?? "")").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        Section("Export") {
            Button("Prepare Event CSV") { Task { await export() } }
            if let exportURL {
                ShareLink(item: exportURL) { Label("Share CSV", systemImage: "square.and.arrow.up") }
                if !exportComplete { Label("Export was split into pages; every page is included in this file.", systemImage: "doc.on.doc") }
            }
        }
    }

    // MARK: Actions

    private func reload(keepEdits: Bool) async {
        guard let client else { summary = nil; reportError = "This iPad is not paired with the payments server."; return }
        let request = UUID(); reportRequest = request
        let binding = workspace.serverBinding
        summary = nil; reportError = nil
        isBusy = true
        defer { if reportRequest == request { isBusy = false } }
        await loadLocalCash(environment: client.environment, request: request, binding: binding)
        guard ownsReport(request, binding: binding) else { return }
        do {
            let loaded = try await client.eventDetail(id: eventID)
            guard ownsReport(request, binding: binding) else { return }
            detail = loaded
            maintenanceNeedsRefresh = false
            let source = loaded.latestRevision ?? loaded.activePolicy
            let serverDraft = source.map(ServerPolicyDraft.init(revision:)) ?? ServerPolicyDraft()
            baseline = (loaded.event.name, loaded.event.venue, serverDraft)
            if !keepEdits {
                name = loaded.event.name
                venue = loaded.event.venue
                draft = serverDraft
                hasVersionConflict = false
                baseServerVersion = loaded.event.version
                if !reportsOnly { workspace.removeServerDraft(eventID: eventID) }
            } else {
                hasVersionConflict = baseServerVersion.map { $0 != loaded.event.version } ?? false
                if baseServerVersion == nil { baseServerVersion = loaded.event.version }
                message = hasVersionConflict
                    ? "The server changed while you were away. Your local edits are preserved; review the differences below."
                    : "Local setup restored. These edits are not saved on the server or published."
            }
            do {
                let refreshed = try await client.eventSummary(id: eventID, pendingLocalCount: localOfflineCount + legacyOfflineCount)
                guard ownsReport(request, binding: binding) else { return }
                summary = refreshed; reportError = nil
            }
            catch { guard ownsReport(request, binding: binding) else { return }; summary = nil; reportError = "Financial totals unavailable: \(error.localizedDescription). Check operator authorization for this environment; unavailable does not mean zero." }
            do {
                let refreshed = try await client.offlineConflicts(eventID: eventID)
                guard ownsReport(request, binding: binding) else { return }
                conflicts = refreshed; conflictsError = nil
            }
            catch { guard ownsReport(request, binding: binding) else { return }; conflicts = []; conflictsError = "Offline conflict report unavailable: \(error.localizedDescription)" }
            await loadOrders(reset: true)
        } catch {
            guard ownsReport(request, binding: binding) else { return }
            summary = nil
            reportError = "Financial report unavailable: \(error.localizedDescription). Check the operator credential in Advanced → Payment Maintenance."
            message = "Could not load the event: \(error.localizedDescription)"
        }
    }

    private func loadLocalCash(environment: String, request: UUID, binding: String) async {
        localOfflineError = "Local offline cash has not been loaded."
        localOfflineCount = 0; localOfflineCentavos = 0; legacyOfflineCount = 0
        guard let ledger = OfflineCashLedger.shared else { localOfflineError = "Local offline-cash storage is unavailable; reconciliation remains provisional."; return }
        if let fault = await ledger.integrityFault { localOfflineError = fault; return }
        let records = await ledger.pendingRecords()
        guard ownsReport(request, binding: binding) else { return }
        do {
            let local = try OfflineCashReportingSnapshot(records: records, eventID: eventID, environment: environment)
            localOfflineCount = local.pending.count; localOfflineCentavos = local.centavos
            legacyOfflineCount = local.unassigned.count; localOfflineError = nil
        } catch { localOfflineError = "Local cash totals unavailable: \(error.localizedDescription)" }
    }

    private func ownsReport(_ request: UUID, binding: String) -> Bool {
        reportRequest == request && workspace.serverBinding == binding && !Task.isCancelled
    }

    private func saveDraft(_ current: OperatorEventDetail) async {
        guard !hasVersionConflict else { return }
        guard let client, let body = draft.requestBody() else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let result = try await client.saveDraft(eventID: eventID, expectedVersion: baseServerVersion ?? current.event.version, name: name, venue: venue, policy: body)
            message = "Saved on the server as revision \(result.draftRevision?.revision ?? 0). It is not live until you publish it."
            await reload(keepEdits: false)
        } catch let error as PaymentsAPIError where error.code == "version_conflict" {
            hasVersionConflict = true
            message = "Not saved: someone else changed this event. Your edits are still here; reload to see the server version."
        } catch {
            message = "Not saved: \(error.localizedDescription)"
        }
    }

    private func perform(_ action: LifecycleAction) async {
        if [.activate, .publish].contains(action), hasUnsavedChanges || hasVersionConflict { return }
        guard let client, let current = detail else { return }
        if let reason = SessionSetupSafety.blockingReason { message = reason; return }
        isBusy = true
        defer { isBusy = false }
        let revision = current.latestRevision
        do {
            let result: OperatorEventTransition
            switch action {
            case .publish, .activate:
                guard let revision else { message = "Save a draft first."; return }
                result = try await client.transitionEvent(id: eventID, action: action.rawValue, expectedVersion: current.event.version,
                                                          policyRevisionID: revision.id, acknowledgedUnitPriceCentavos: revision.unitPriceCentavos)
            default:
                result = try await client.transitionEvent(id: eventID, action: action.rawValue, expectedVersion: current.event.version)
            }
            message = "Server confirmed: event is \(result.lifecycle)\(action == .publish || action == .activate ? " with revision \(revision?.revision ?? 0)" : "")."
            await reload(keepEdits: false)
            // Keep this iPad's occurrence in step with the confirmed commercial lifecycle.
            if let lifecycle = detail?.event.lifecycle, detail?.event.id == eventID,
               let note = EventLifecycleCoordinator.syncAfterServerTransition(eventID: eventID, lifecycle: lifecycle, binding: workspace.serverBinding) {
                message += " " + note
            }
        } catch let error as PaymentsAPIError where error.code == "version_conflict" {
            hasVersionConflict = true
            message = "Not changed: the event was updated elsewhere. Reload and review before trying again."
        } catch {
            maintenanceNeedsRefresh = true
            message = "Action not confirmed: \(error.localizedDescription). Refresh current status before trying again."
        }
    }

    private func persistDraft() {
        guard !reportsOnly else { return }
        guard let baseVersion = baseServerVersion, baseline != nil else { return }
        if hasUnsavedChanges {
            workspace.saveServerDraft(OperatorServerSetupDraft(eventID: eventID, serverBinding: workspace.serverBinding,
                baseVersion: baseVersion, name: name, venue: venue, policy: draft))
        } else { workspace.removeServerDraft(eventID: eventID) }
    }

    private func saveCount() async {
        guard let client, let centavos = PesoAmount.centavos(fromPesoText: countText) else { return }
        let binding = workspace.serverBinding
        do {
            guard let ledger = OfflineCashLedger.shared, await ledger.integrityFault == nil else {
                message = "Cash count not saved: recover the local offline journal first."; return
            }
            let pending = await ledger.pendingRecords().filter { $0.eventID == eventID }.count
            guard workspace.serverBinding == binding, !Task.isCancelled else { return }
            let saved = try await client.recordCashCount(eventID: eventID, countedCentavos: centavos, reason: countReason, pendingLocalCount: pending)
            guard workspace.serverBinding == binding else { return }
            message = "Count of \(PHPPriceFormatter.string(centavos: saved.countedCentavos)) recorded\(saved.provisional ? " (provisional)" : "")."
            countText = ""
            do {
                let refreshed = try await client.eventSummary(id: eventID, pendingLocalCount: pending)
                guard workspace.serverBinding == binding, !Task.isCancelled else { return }
                summary = refreshed; reportError = nil
            }
            catch { guard workspace.serverBinding == binding else { return }; summary = nil; reportError = "Count was saved, but updated totals are unavailable: \(error.localizedDescription)" }
        } catch {
            message = "Count not saved: \(error.localizedDescription)"
        }
    }

    private func loadOrders(reset: Bool) async {
        guard let client, reset || !ordersLoading else { return }
        let request = UUID(); ordersRequest = request
        let filter = orderFilter
        let binding = workspace.serverBinding
        ordersLoading = true; ordersError = nil
        if reset { orders = []; nextOrderCursor = nil }
        defer { if ordersRequest == request { ordersLoading = false } }
        do {
            let page = try await client.eventOrders(id: eventID, filter: filter, cursor: reset ? nil : nextOrderCursor)
            guard ordersRequest == request, orderFilter == filter, workspace.serverBinding == binding, !Task.isCancelled else { return }
            let existing = Set(orders.map(\.id))
            orders = reset ? page.orders : orders + page.orders.filter { !existing.contains($0.id) }
            nextOrderCursor = page.nextCursor
        } catch {
            guard ordersRequest == request, workspace.serverBinding == binding else { return }
            ordersError = "Orders unavailable: \(error.localizedDescription)"
        }
    }

    private func export() async {
        guard let client else { return }
        let binding = workspace.serverBinding
        do {
            exportURL = nil
            let combined = try await client.completeEventCSV(eventID: eventID)
            guard workspace.serverBinding == binding, !Task.isCancelled else { return }
            exportComplete = true
            let url = FileManager.default.temporaryDirectory.appending(path: "\(eventID)-sales.csv")
            try combined.write(to: url, options: [.atomic, .completeFileProtection])
            exportURL = url
        } catch {
            message = "Export failed: \(error.localizedDescription)"
        }
    }

    // MARK: Text

    private func priceLabel(_ revision: OperatorPolicyRevision) -> String {
        revision.commercialMode == .payPerPrint ? "\(PHPPriceFormatter.string(centavos: revision.unitPriceCentavos))/copy" : "Private / Prepaid"
    }

    private var confirmationTitle: String {
        switch pendingAction {
        case .publish, .activate: "Publish to guests?"
        case .pause: "Pause new sessions?"
        case .resume: "Resume this event?"
        case .end: "End this event?"
        case .archive: "Archive this event?"
        case nil: ""
        }
    }

    private func confirmationButton(_ action: LifecycleAction) -> String {
        switch action {
        case .publish: "Publish Revision \(detail?.latestRevision?.revision ?? 0)"
        case .activate: "Publish & Activate"
        case .pause: "Pause"
        case .resume: "Resume"
        case .end: "End Event"
        case .archive: "Archive"
        }
    }

    private func confirmationMessage(_ action: LifecycleAction) -> String {
        switch action {
        case .publish, .activate:
            guard let latest = detail?.latestRevision else { return "" }
            let methods = [latest.qrphEnabled ? "QR Ph" : nil, latest.cashEnabled ? "cash (customer declared)" : nil].compactMap { $0 }.joined(separator: " and ")
            return "Guests starting a new checkout will see revision \(latest.revision): \(priceLabel(latest)), up to \(latest.maxCopies) copies\(methods.isEmpty ? "" : ", paid by \(methods)"). Guests already checking out keep their price."
        case .pause: return "Pauses this paid event for every booth. No new checkouts can start. Paid entitlements remain usable. Offline policies are revoked when iPads reconnect."
        case .resume: return "Guests can start new checkouts with the published revision."
        case .end: return "Ends this paid event for every booth. No new sessions can start; an event that has ended cannot be restarted. Existing paid entitlements remain recoverable and every report is kept."
        case .archive: return "The event is hidden from active use. Reports remain available."
        }
    }
}
