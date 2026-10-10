import SwiftUI

/// The single editor for a server-managed event: load the server state, edit a local copy, save it
/// as a versioned server draft, then explicitly publish that exact acknowledged revision. Nothing
/// here reports success until the server has confirmed it.
struct ServerEventEditorView: View {
    let eventID: String

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
    @State private var countText = ""
    @State private var countReason = "End-of-event physical count"
    @State private var orderFilter = "all"
    @State private var orders: [OperatorOrderRow] = []
    @State private var nextOrderCursor: String?
    @State private var conflicts: [OperatorOfflineConflict] = []
    @State private var exportURL: URL?
    @State private var exportComplete = true

    private var client: PaymentsAPIClient? { PaymentsConfiguration.current().map { PaymentsAPIClient(configuration: $0) } }

    enum LifecycleAction: String, Identifiable {
        case publish, activate, pause, resume, end, archive
        var id: String { rawValue }
    }

    private var hasUnsavedChanges: Bool {
        guard let baseline else { return false }
        return baseline.name != name || baseline.venue != venue || baseline.draft != draft
    }

    var body: some View {
        Form {
            statusSection
            if let detail, ![.ended, .archived].contains(detail.event.lifecycle) {
                detailsSection
                pricingSection
                formatsSection
                saveSection(detail)
            }
            if let detail { lifecycleSection(detail) }
            salesSections
        }
        .navigationTitle(detail?.event.name ?? "Server Event")
        .disabled(isBusy)
        .overlay { if isBusy { ProgressView().controlSize(.large) } }
        .task { await reload(keepEdits: false) }
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
                LabeledContent("Lifecycle", value: detail.event.lifecycle.rawValue)
                LabeledContent("Event ID", value: detail.event.id)
                LabeledContent("Server version", value: "\(detail.event.version)")
                if let active = detail.activePolicy {
                    LabeledContent("Live for guests", value: "Revision \(active.revision) · \(priceLabel(active))")
                } else {
                    LabeledContent("Live for guests", value: "Nothing published")
                }
                if detail.hasUnpublishedRevision, let latest = detail.latestRevision {
                    LabeledContent("Saved server draft", value: "Revision \(latest.revision) · \(priceLabel(latest)) · not published")
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
                Button("Reload from Server (discards edits on this iPad)", role: .destructive) { Task { await reload(keepEdits: false) } }
            }
        }
    }

    // MARK: Editing

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
                    get: { draft.supportedFormats.contains(format.rawValue) },
                    set: { enabled in
                        if enabled { draft.supportedFormats.insert(format.rawValue) } else { draft.supportedFormats.remove(format.rawValue) }
                    }
                ))
            }
        }
    }

    @ViewBuilder private func saveSection(_ detail: OperatorEventDetail) -> some View {
        Section {
            Button("Save Draft to Server") { Task { await saveDraft(detail) } }
                .disabled(!hasUnsavedChanges || draft.requestBody() == nil || name.trimmingCharacters(in: .whitespaces).isEmpty)
            if let latest = detail.latestRevision, detail.hasUnpublishedRevision || detail.event.lifecycle == .draft {
                Button(detail.event.lifecycle == .draft ? "Publish & Activate Revision \(latest.revision)" : "Publish Revision \(latest.revision) to Guests") {
                    pendingAction = detail.event.lifecycle == .draft ? .activate : .publish
                }
                .disabled(hasUnsavedChanges)
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
        if let summary {
            Section("Sales Provenance") {
                LabeledContent("QR Ph verified (LIVE)", value: PHPPriceFormatter.string(centavos: summary.verifiedQRPhLiveCentavos))
                LabeledContent("QR Ph verified (TEST, excluded)", value: PHPPriceFormatter.string(centavos: summary.verifiedQRPhTestCentavos))
                LabeledContent("Cash self-reported (unverified)", value: PHPPriceFormatter.string(centavos: summary.cashSelfReportedCentavos))
                if let offline = summary.cashSelfReportedOfflineSyncedCentavos, offline > 0 {
                    LabeledContent("  of which synced from offline", value: PHPPriceFormatter.string(centavos: offline))
                }
                if let physical = summary.physicalCashCount {
                    LabeledContent("Cash physically counted", value: PHPPriceFormatter.string(centavos: physical.countedCentavos))
                    LabeledContent("Variance (counted − self-reported)", value: PHPPriceFormatter.string(centavos: physical.varianceCentavos))
                    if physical.provisional { Label("Provisional: offline cash is still unsynced or in conflict", systemImage: "exclamationmark.triangle") }
                } else {
                    Text("Cash reconciliation: NOT RECONCILED").foregroundStyle(.secondary)
                }
                if let unresolved = summary.unresolvedQRCount, unresolved > 0 {
                    Label("\(unresolved) QR Ph payment(s) unresolved", systemImage: "clock.badge.questionmark")
                }
                if let late = summary.lateQRPaidReviewCentavos, late > 0 {
                    Label("\(PHPPriceFormatter.string(centavos: late)) paid late on replaced checkouts — review for refund", systemImage: "exclamationmark.bubble")
                }
                Text("Refunds, complimentary prints, provider fees and bank payouts are not tracked. Settlement: \(summary.settlementStatus.replacingOccurrences(of: "_", with: " ").lowercased()).")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Print Copies") {
                LabeledContent("Purchased", value: "\(summary.printUtilization.purchased)")
                LabeledContent("Confirmed", value: "\(summary.printUtilization.confirmed)")
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
            ForEach(orders) { order in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(PHPPriceFormatter.string(centavos: order.totalCentavos)) · \(order.copies)× \(order.boothFormat)")
                    Text("\(order.category) · \(order.state)\(order.lastReconcileError != nil ? " · provider check failed" : "")")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(order.createdAt, format: .dateTime.month().day().hour().minute()).font(.caption2).foregroundStyle(.secondary)
                }
            }
            if nextOrderCursor != nil {
                Button("Load More") { Task { await loadOrders(reset: false) } }
            }
        }
        if !conflicts.isEmpty {
            Section("Offline Cash Conflicts (server)") {
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
        guard let client else { message = "This iPad is not paired with the payments server."; return }
        isBusy = true
        defer { isBusy = false }
        do {
            let loaded = try await client.eventDetail(id: eventID)
            detail = loaded
            let source = loaded.latestRevision ?? loaded.activePolicy
            let serverDraft = source.map(ServerPolicyDraft.init(revision:)) ?? ServerPolicyDraft()
            baseline = (loaded.event.name, loaded.event.venue, serverDraft)
            if !keepEdits {
                name = loaded.event.name
                venue = loaded.event.venue
                draft = serverDraft
                hasVersionConflict = false
            }
            summary = try? await client.eventSummary(id: eventID, pendingLocalCount: await OfflineCashLedger.shared?.pendingRecords().count ?? 0)
            conflicts = (try? await client.offlineConflicts(eventID: eventID)) ?? []
            await loadOrders(reset: true)
        } catch {
            message = "Could not load the event: \(error.localizedDescription)"
        }
    }

    private func saveDraft(_ current: OperatorEventDetail) async {
        guard let client, let body = draft.requestBody() else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let result = try await client.saveDraft(eventID: eventID, expectedVersion: current.event.version, name: name, venue: venue, policy: body)
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
        guard let client, let current = detail else { return }
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
        } catch let error as PaymentsAPIError where error.code == "version_conflict" {
            hasVersionConflict = true
            message = "Not changed: the event was updated elsewhere. Reload and review before trying again."
        } catch {
            message = "Not changed: \(error.localizedDescription)"
        }
    }

    private func saveCount() async {
        guard let client, let centavos = PesoAmount.centavos(fromPesoText: countText) else { return }
        do {
            let pending = await OfflineCashLedger.shared?.pendingRecords().count ?? 0
            let saved = try await client.recordCashCount(eventID: eventID, countedCentavos: centavos, reason: countReason, pendingLocalCount: pending)
            message = "Count of \(PHPPriceFormatter.string(centavos: saved.countedCentavos)) recorded\(saved.provisional ? " (provisional)" : "")."
            countText = ""
            summary = try? await client.eventSummary(id: eventID, pendingLocalCount: pending)
        } catch {
            message = "Count not saved: \(error.localizedDescription)"
        }
    }

    private func loadOrders(reset: Bool) async {
        guard let client else { return }
        do {
            let page = try await client.eventOrders(id: eventID, filter: orderFilter, cursor: reset ? nil : nextOrderCursor)
            orders = reset ? page.orders : orders + page.orders
            nextOrderCursor = page.nextCursor
        } catch {
            message = "Orders not loaded: \(error.localizedDescription)"
        }
    }

    private func export() async {
        guard let client else { return }
        do {
            var combined = Data()
            var cursor: String?
            var pages = 0
            repeat {
                let page = try await client.exportCSV(eventID: eventID, cursor: cursor)
                // Later pages repeat the header row; keep only the first.
                if pages == 0 { combined.append(page.data) } else if let text = String(data: page.data, encoding: .utf8), let newline = text.range(of: "\r\n") {
                    combined.append(Data(text[newline.upperBound...].utf8))
                }
                pages += 1
                cursor = page.complete ? nil : page.nextCursor
            } while cursor != nil && pages < 40
            exportComplete = pages == 1
            if cursor != nil { message = "Export stopped after \(pages) pages; the file is incomplete." }
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
            let methods = [latest.qrphEnabled ? "QR Ph" : nil, latest.cashEnabled ? "cash (self-reported)" : nil].compactMap { $0 }.joined(separator: " and ")
            return "Guests starting a new checkout will see revision \(latest.revision): \(priceLabel(latest)), up to \(latest.maxCopies) copies\(methods.isEmpty ? "" : ", paid by \(methods)"). Guests already checking out keep their price."
        case .pause: return "No new checkouts can start. Paid entitlements remain usable. Offline policies are revoked when iPads reconnect."
        case .resume: return "Guests can start new checkouts with the published revision."
        case .end: return "No new sessions can start. Existing paid entitlements remain recoverable."
        case .archive: return "The event is hidden from active use. Reports remain available."
        }
    }
}
