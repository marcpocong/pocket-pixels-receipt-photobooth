import SwiftUI

/// Server events, pairing and diagnostics. Each event opens `ServerEventEditorView`, the single
/// place where paid policy is edited, published and moved through its lifecycle.
struct PaymentsOperatorView: View {
    @State private var configuration = PaymentsConfiguration.current()
    @State private var events: [OperatorEventSummary] = []
    @State private var diagnostics: OperatorDiagnostics?
    @State private var eventName = ""
    @State private var venue = ""
    @State private var status = ""
    @State private var isLoading = false
    @State private var pairingURL = PaymentsConfiguration.current()?.baseURL.absoluteString ?? ""
    @State private var pairingToken = ""
    @State private var pairedDevice: DeviceInfoResponse.Device?
    @State private var localPending = 0
    @State private var localConflicts: [OfflineCashRecord] = []
    @State private var ledgerFault: String?
    @ObservedObject private var recovery = PaymentRecoveryCoordinator.shared
    @State private var resumeCandidate: CheckoutRecoveryItem?
    @State private var dismissCandidate: CheckoutRecoveryItem?

    private var client: PaymentsAPIClient? { configuration.map { PaymentsAPIClient(configuration: $0) } }

    var body: some View {
        List {
            Section("Payments Server") {
                LabeledContent("Environment", value: configuration?.environment.uppercased() ?? "NOT CONFIGURED")
                if let pairedDevice {
                    LabeledContent("This iPad", value: "\(pairedDevice.displayName ?? pairedDevice.id) · \(pairedDevice.scopes.joined(separator: ", "))")
                    LabeledContent("Account", value: pairedDevice.accountId)
                }
                if let diagnostics {
                    LabeledContent("Live payments", value: diagnostics.liveEnabled ? "ENABLED" : "Disabled")
                    LabeledContent("Offline signing", value: diagnostics.offlineSigningConfigured ? "Configured" : "Not configured — offline cash off")
                    LabeledContent("Unresolved QR Ph", value: "\(diagnostics.unresolvedIntentCount)")
                    LabeledContent("Needs review", value: "\(diagnostics.reviewOrderCount + diagnostics.offlineConflictCount)")
                }
                if !status.isEmpty {
                    Text(status).font(.footnote).foregroundStyle(.secondary)
                }
                Button(isLoading ? "Refreshing…" : "Refresh") { Task { await refresh() } }
                    .disabled(isLoading || client == nil)
            }

            recoverySection
            printAccountingSection
            pairingSection
            offlineLedgerSection

            Section("Create Draft Event") {
                TextField("Event name", text: $eventName)
                TextField("Venue", text: $venue)
                Button("Create Draft on Server") { Task { await createEvent() } }
                    .disabled(eventName.trimmingCharacters(in: .whitespaces).isEmpty || client == nil)
            }

            Section("Server Events") {
                if events.isEmpty {
                    Text(client == nil ? "Pair this iPad to load events." : "No events yet.").foregroundStyle(.secondary)
                }
                ForEach(events) { event in
                    NavigationLink {
                        ServerEventEditorView(eventID: event.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(event.name).font(.headline)
                            Text(summaryLine(event)).font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(minHeight: 44, alignment: .leading)
                    }
                    .accessibilityLabel("\(event.name), \(event.lifecycle)")
                }
            }
        }
        .navigationTitle("Commercial Events & Sales")
        .task { await refresh() }
    }

    private func summaryLine(_ event: OperatorEventSummary) -> String {
        var parts = [event.lifecycle]
        if let revision = event.activeRevision { parts.append("revision \(revision)") } else { parts.append("not published") }
        if let price = event.activeUnitPriceCentavos, price > 0 { parts.append("\(PHPPriceFormatter.string(centavos: price))/copy") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var recoverySection: some View {
        Section {
            if let fault = CheckoutCheckpointStore.shared?.integrityFault {
                Label(fault, systemImage: "exclamationmark.octagon").foregroundStyle(.red)
                Button("Acknowledge (server orders remain listed)", role: .destructive) {
                    try? CheckoutCheckpointStore.shared?.acknowledgeIntegrityFault()
                    Task { await recovery.refresh() }
                }
            }
            if recovery.items.isEmpty {
                Text("No interrupted paid checkouts on this iPad.").foregroundStyle(.secondary)
            }
            ForEach(recovery.items) { item in
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(item.checkpoint.copies)× \(item.checkpoint.format) · \(PHPPriceFormatter.string(centavos: item.checkpoint.unitPriceCentavos * item.checkpoint.copies))")
                        .font(.headline)
                    Text(item.classification.operatorDescription).font(.subheadline)
                    Text("Checkout \(item.checkpoint.id) · started \(item.checkpoint.createdAt.formatted(date: .omitted, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        if item.classification.isResumable {
                            Button("Resume for This Guest") { resumeCandidate = item }
                                .buttonStyle(.borderedProminent)
                        }
                        Button("Dismiss on iPad") { dismissCandidate = item }
                            .buttonStyle(.bordered)
                    }
                }
                .padding(.vertical, 4)
            }
            if let armed = recovery.armedResume {
                Label("Armed: the next tap on the welcome screen continues checkout \(armed.item.id) (until \(armed.expiresAt.formatted(date: .omitted, time: .shortened))).", systemImage: "hand.tap")
                Button("Cancel Armed Resume") { recovery.disarmResume() }
            }
            Button("Check Interrupted Checkouts") { Task { await recovery.refresh() } }
            if !recovery.lastRefreshMessage.isEmpty {
                Text(recovery.lastRefreshMessage).font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text("Interrupted Paid Checkouts")
        } footer: {
            Text("Resume only with the paying guest present. Resuming continues the original checkout with the same copies; it never charges again or shows earlier photos. Dismissing hides the item here only — the paid entitlement stays outstanding on the server.")
        }
        .confirmationDialog("Resume this paid session?", isPresented: Binding(get: { resumeCandidate != nil }, set: { if !$0 { resumeCandidate = nil } }), titleVisibility: .visible, presenting: resumeCandidate) { item in
            Button("Resume for Guest Present Now") {
                if !recovery.armResume(item) { status = "This checkout is no longer resumable." }
                resumeCandidate = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: { item in
            Text("Close the operator screen and ask the guest to tap the welcome screen within 5 minutes. \(item.classification.operatorDescription)")
        }
        .confirmationDialog("Dismiss this checkout on this iPad?", isPresented: Binding(get: { dismissCandidate != nil }, set: { if !$0 { dismissCandidate = nil } }), titleVisibility: .visible, presenting: dismissCandidate) { item in
            Button("Dismiss — Guest Left or Resolved Elsewhere", role: .destructive) {
                recovery.dismiss(item, reason: "guest_left_or_resolved")
                dismissCandidate = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The reason is kept in this iPad's records. Server orders, payments and entitlements are not changed.")
        }
    }

    @ViewBuilder private var printAccountingSection: some View {
        Section {
            let summary = recovery.outboxSummary
            LabeledContent("Reports waiting to send", value: "\(summary.pending)")
            LabeledContent("Copies of uncertain output", value: "\(summary.uncertain)")
            if summary.awaiting > 0 { LabeledContent("Copies in flight", value: "\(summary.awaiting)") }
            if summary.conflicts > 0 {
                Label("\(summary.conflicts) print record(s) refused by the server — review below", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                ForEach(PrintOutcomeOutbox.shared?.conflicts ?? []) { entry in
                    Text("Copy \(entry.copyIndex) of \(entry.copyCount) · \(entry.localState.rawValue) · \(entry.lastError ?? "refused")")
                        .font(.caption)
                }
            }
            if let fault = PrintOutcomeOutbox.shared?.integrityFault {
                Label(fault, systemImage: "exclamationmark.octagon").foregroundStyle(.red)
            }
            Button("Send Print Reports Now") { Task { await recovery.syncOutbox() } }
                .disabled(client == nil)
        } header: {
            Text("Print Accounting")
        } footer: {
            Text("Delivered means the printer accepted every byte; paper is not sensor-verified. Uncertain copies need a paper check in Fix Printer; nothing is reprinted automatically.")
        }
    }

    @ViewBuilder private var pairingSection: some View {
        Section {
            TextField("https://payments-test.example.workers.dev", text: $pairingURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            SecureField("Device credential", text: $pairingToken)
                .textContentType(.oneTimeCode)
            Button("Pair This iPad") { Task { await pair() } }
                .disabled(PaymentsConfiguration.validatedURL(pairingURL) == nil || pairingToken.count < 32)
            if configuration != nil {
                Button("Unpair This iPad", role: .destructive) { unpair() }
            }
        } header: {
            Text("Device Pairing")
        } footer: {
            Text("The credential is stored only in this iPad's Keychain and is never shown again. The environment is read from the server.")
        }
    }

    @ViewBuilder private var offlineLedgerSection: some View {
        Section("Offline Cash on This iPad") {
            if OfflineCashLedger.shared == nil {
                Label("Offline cash storage is unavailable on this iPad.", systemImage: "xmark.octagon").foregroundStyle(.red)
            }
            if let ledgerFault {
                Label(ledgerFault, systemImage: "exclamationmark.octagon").foregroundStyle(.red)
                Button("Acknowledge and Start a New Journal", role: .destructive) { Task { await acknowledgeLedgerFault() } }
            }
            LabeledContent("Waiting to sync", value: "\(localPending)")
            ForEach(localConflicts) { record in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(PHPPriceFormatter.string(centavos: record.totalCentavos)) · \(record.copies) copies · seq \(record.localSequence)")
                    Text("Rejected: \(record.failureMessage ?? "unknown")").font(.caption).foregroundStyle(.red)
                }
            }
            Button("Sync Offline Cash Now") { Task { await syncOffline() } }
                .disabled(client == nil || localPending == 0)
        }
    }

    private func refresh() async {
        configuration = PaymentsConfiguration.current()
        await loadLedger()
        await recovery.refresh()
        guard let client else { status = "Payments API is not configured."; return }
        isLoading = true
        defer { isLoading = false }
        do {
            pairedDevice = try await client.device().device
            events = try await client.listEvents()
            diagnostics = try? await client.diagnostics()
            status = "Loaded \(events.count) server events at \(Date().formatted(date: .omitted, time: .shortened))."
        } catch {
            status = "Not refreshed: \(error.localizedDescription)"
        }
    }

    private func loadLedger() async {
        guard let ledger = OfflineCashLedger.shared else { return }
        localPending = await ledger.pendingRecords().count
        localConflicts = await ledger.conflictRecords()
        ledgerFault = await ledger.integrityFault
    }

    private func acknowledgeLedgerFault() async {
        guard let ledger = OfflineCashLedger.shared else { return }
        do {
            try await ledger.acknowledgeIntegrityFaultAndStartNewJournal()
            status = "A new offline cash journal was started. The unreadable file was kept for review."
        } catch {
            status = "Could not start a new journal: \(error.localizedDescription)"
        }
        await loadLedger()
    }

    private func syncOffline() async {
        guard let client, let ledger = OfflineCashLedger.shared else { return }
        do {
            let result = try await ledger.syncPending(using: client)
            status = "Offline sync: \(result.synced) synced, \(result.conflicts) rejected for review."
        } catch {
            status = "Offline sync failed: \(error.localizedDescription)"
        }
        await loadLedger()
    }

    private func pair() async {
        guard let url = PaymentsConfiguration.validatedURL(pairingURL) else { return }
        let store = PaymentDeviceCredentialStore()
        do {
            try store.save(pairingToken)
            pairingToken = ""
            // Ask the server which environment and device this credential belongs to.
            let probe = PaymentsAPIClient(configuration: PaymentsConfiguration(baseURL: url, environment: "test"))
            let info = try await probe.device()
            PaymentsConfiguration.savePaired(baseURL: url, environment: info.environment)
            pairedDevice = info.device
            status = "Paired as \(info.device.id) in \(info.environment.uppercased())."
            await refresh()
        } catch {
            try? store.delete()
            PaymentsConfiguration.clearPaired()
            configuration = nil
            status = "Pairing failed: \(error.localizedDescription)"
        }
    }

    private func unpair() {
        try? PaymentDeviceCredentialStore().delete()
        PaymentsConfiguration.clearPaired()
        configuration = nil
        pairedDevice = nil
        events = []
        diagnostics = nil
        status = "This iPad is no longer paired. Server-managed sessions are unavailable."
    }

    private func createEvent() async {
        guard let client else { return }
        do {
            _ = try await client.createEvent(name: eventName, venue: venue)
            eventName = ""
            venue = ""
            await refresh()
        } catch {
            status = "Event not created: \(error.localizedDescription)"
        }
    }
}
