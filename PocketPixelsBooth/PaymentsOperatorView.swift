import SwiftUI

/// Specialized payment maintenance and read-only sales. Everyday setup lives in Session Setup.
struct PaymentsOperatorView: View {
    var salesOnly = false
    var allowsEventMaintenance = false
    @State private var configuration = PaymentsConfiguration.current()
    @State private var events: [OperatorEventSummary] = []
    @State private var diagnostics: OperatorDiagnostics?
    @State private var status = ""
    @State private var isLoading = false
    @State private var eventsError: String?
    @State private var refreshRequest = UUID()
    @State private var eventsLoaded = false
    @State private var eventsLoadedAt: Date?
    @State private var eventsBinding: String?
    @State private var deviceError: String?
    @State private var showsHistory = false
    @State private var pairingURL = PaymentsConfiguration.current()?.baseURL.absoluteString ?? ""
    @State private var pairingToken = ""
    @State private var operatorToken = ""
    @State private var pairedDevice: DeviceInfoResponse.Device?
    @State private var localPending = 0
    @State private var localConflicts: [OfflineCashRecord] = []
    @State private var ledgerFault: String?
    @State private var ledgerLoaded = false
    @ObservedObject private var recovery = PaymentRecoveryCoordinator.shared

    private var client: PaymentsAPIClient? { configuration.map { PaymentsAPIClient(configuration: $0) } }

    private var pairingBlockedReason: String? {
        if let reason = SessionSetupSafety.paymentConnectionChangeReason { return reason }
        if !ledgerLoaded { return "Checking offline cash records before changing the payments connection." }
        if ledgerFault != nil || localPending > 0 || !localConflicts.isEmpty { return "Sync or review the original offline cash ledger before changing the payments connection." }
        return nil
    }

    var body: some View {
        List {
            if !salesOnly { Section("Payments Server") {
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
            } }

            if !salesOnly {
            CheckoutRecoverySection()
            printAccountingSection
            pairingSection
            offlineLedgerSection
            }

            if !salesOnly, configuration != nil {
                Section("Operator API Access") {
                    SecureField("Separate operator credential", text: $operatorToken)
                        .textContentType(.oneTimeCode)
                    Button("Authorize Operator API") { Task { await pairOperator() } }
                        .disabled(operatorToken.count < 32)
                    Text("LIVE uses an operator-only credential, stored in this iPad's Keychain for this server. Booth credentials cannot administer events.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }

            if !salesOnly { Section("Session Settings") {
                NavigationLink("Open Session Setup", value: OperatorWorkspaceRoute.sessionSetup)
                Text("Everyday event settings and starting or pausing sessions are managed in Session Setup.")
            } }
            Section("Commercial Events — all runs") {
                Toggle("Include completed and archived events", isOn: $showsHistory)
                if isLoading { ProgressView("Loading events…") }
                if let eventsError { Label(eventsError, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                if client == nil { Text("Pair this iPad in Advanced → Payment Maintenance.") }
                if eventsLoaded, events.isEmpty { Text("No commercial events were returned by this server.").foregroundStyle(.secondary) }
                if let eventsLoadedAt {
                    Text(eventsError == nil ? "Last refreshed \(eventsLoadedAt.formatted(date: .omitted, time: .shortened))."
                                            : "Showing the list from \(eventsLoadedAt.formatted(date: .omitted, time: .shortened)); it may be out of date.")
                        .font(.footnote).foregroundStyle(eventsError == nil ? Color.secondary : Color.orange)
                }
                if let deviceError, !salesOnly { Label(deviceError, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange) }
                LabeledContent("Environment", value: configuration?.environment.uppercased() ?? "NOT CONFIGURED")
                Button("Refresh Event List") { Task { await refresh() } }.disabled(isLoading)
                if salesOnly { NavigationLink("Operator API Credentials", value: OperatorWorkspaceRoute.payments) }
                ForEach(events.filter { showsHistory || !["ENDED", "ARCHIVED"].contains($0.lifecycle) }) { event in
                    NavigationLink(value: OperatorWorkspaceRoute.eventReport(event.id)) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(event.name).font(.headline)
                            Text(summaryLine(event)).font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(minHeight: 44, alignment: .leading)
                    }
                    .accessibilityLabel("\(event.name), \(event.lifecycle)")
                    if !salesOnly || allowsEventMaintenance {
                        NavigationLink("Close or Archive \(event.name)", value: OperatorWorkspaceRoute.eventMaintenance(event.id))
                            .font(.callout)
                    }
                }
            }
        }
        .navigationTitle(salesOnly ? "Event Sales & Reports" : "Payment Maintenance")
        .task { await refresh() }
        .onReceive(NotificationCenter.default.publisher(for: OperatorWorkspace.didUnlock)) { _ in Task { await refresh() } }
    }

    private func summaryLine(_ event: OperatorEventSummary) -> String {
        var parts = [CommercialEventLifecycle(rawValue: event.lifecycle)?.displayName ?? event.lifecycle]
        if event.activeRevision == nil { parts.append("Not yet applied") }
        if let price = event.activeUnitPriceCentavos, price > 0 { parts.append("\(PHPPriceFormatter.string(centavos: price))/copy") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var printAccountingSection: some View {
        Section {
            let summary = recovery.outboxSummary
            LabeledContent("Reports waiting to send", value: "\(summary.pending)")
            LabeledContent("History: receipts with unknown outcome", value: "\(summary.uncertain)")
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
            Button("Send Print Reports Now") { Task { await recovery.syncOutbox(showFeedback: true) } }
                .disabled(client == nil || recovery.printReportSyncState == .syncing)
            switch recovery.printReportSyncState {
            case .idle:
                EmptyView()
            case .syncing:
                HStack {
                    ProgressView()
                    Text("Synchronizing print reports…", comment: "Operator status while print accounting reports are uploading.")
                }
            case .nothingToSynchronize:
                Label("Nothing to synchronize.", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            case .sent(let count):
                Label("Sent \(count) print report(s).", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .networkFailure(let retryCount):
                Label("Network failure. \(retryCount) report(s) will retry automatically.", systemImage: "wifi.exclamationmark")
                    .foregroundStyle(.orange)
            case .serverConflict(let count):
                Label("Server conflict for \(count) print report(s). Review the records above.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            case .retryScheduled(let count):
                Label("Retry already scheduled for \(count) print report(s).", systemImage: "clock.arrow.circlepath")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Print Accounting")
        } footer: {
            Text("Unknown outcomes stay in history even after a receipt check. They do not block everyday setup. Current receipt checks appear in Fix Printer. Sending reports never reprints a receipt. Delivered means all bytes were accepted; paper is not sensor-verified.")
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
                .disabled(PaymentsConfiguration.validatedURL(pairingURL) == nil || pairingToken.count < 32 || pairingBlockedReason != nil)
            if configuration != nil {
                Button("Unpair This iPad", role: .destructive) { unpair() }
                    .disabled(pairingBlockedReason != nil)
            }
            if let reason = pairingBlockedReason {
                Text(reason).font(.footnote).foregroundStyle(.secondary)
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

    /// Read-only reports load first and independently: an unavailable booth-device check,
    /// diagnostics or recovery refresh never blocks an authorized report.
    private func refresh() async {
        await loadLedger()
        let request = UUID(); refreshRequest = request
        let binding = OperatorWorkspace.shared.serverBinding
        configuration = PaymentsConfiguration.current()
        // Stale rows are only ever shown for the same payments connection.
        if eventsBinding != binding { events = []; eventsLoaded = false; eventsLoadedAt = nil; eventsBinding = nil }
        guard let client else { events = []; eventsLoaded = false; eventsLoadedAt = nil; eventsError = "Payments API is not configured."; return }
        isLoading = true
        do {
            let loadedEvents = try await client.listEvents()
            guard refreshRequest == request, OperatorWorkspace.shared.serverBinding == binding, !Task.isCancelled else { return }
            events = loadedEvents; eventsLoaded = true; eventsError = nil; eventsLoadedAt = Date(); eventsBinding = binding
            status = "Loaded \(events.count) server events at \(Date().formatted(date: .omitted, time: .shortened))."
        } catch {
            guard refreshRequest == request, OperatorWorkspace.shared.serverBinding == binding else { return }
            // Keep the last successful list visible but labeled stale; a failure is never zero sales.
            eventsError = "Event reports unavailable: \(error.localizedDescription). LIVE requires a separate operator credential for the selected server. This does not mean sales are zero."
            status = "Not refreshed: \(error.localizedDescription)"
        }
        if refreshRequest == request { isLoading = false }
        guard !salesOnly else { return }
        do {
            let device = try await client.device().device
            guard refreshRequest == request, OperatorWorkspace.shared.serverBinding == binding else { return }
            pairedDevice = device; deviceError = nil
        } catch {
            guard refreshRequest == request else { return }
            pairedDevice = nil; deviceError = "Booth device check unavailable: \(error.localizedDescription)"
        }
        let loadedDiagnostics = try? await client.diagnostics()
        guard refreshRequest == request, OperatorWorkspace.shared.serverBinding == binding else { return }
        diagnostics = loadedDiagnostics
        await loadLedger()
        await recovery.refresh()
    }

    private func loadLedger() async {
        guard let ledger = OfflineCashLedger.shared else { ledgerFault = "Offline cash storage is unavailable."; ledgerLoaded = true; return }
        localPending = await ledger.pendingRecords().count
        localConflicts = await ledger.conflictRecords()
        ledgerFault = await ledger.integrityFault
        ledgerLoaded = true
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
        await loadLedger()
        guard pairingBlockedReason == nil else { status = pairingBlockedReason ?? "Pairing is locked."; return }
        guard let url = PaymentsConfiguration.validatedURL(pairingURL) else { return }
        let store = PaymentDeviceCredentialStore()
        do {
            // Ask the server which environment and device this credential belongs to.
            let probe = PaymentsAPIClient(configuration: PaymentsConfiguration(baseURL: url, environment: "test"),
                                          credentialStore: PaymentPairingCredential(token: pairingToken))
            let info = try await probe.device()
            guard pairingBlockedReason == nil, OperatorAccessPermit.shared.isAuthorized else { throw PaymentsAPIError.unauthorized }
            guard info.device.scopes.contains("booth"),
                  info.environment != "live" || !info.device.scopes.contains("operator") else {
                throw PaymentsAPIError.configuration("LIVE booth pairing requires a booth-only credential. Authorize the operator separately.")
            }
            try store.save(pairingToken)
            pairingToken = ""
            PaymentsConfiguration.savePaired(baseURL: url, environment: info.environment)
            pairedDevice = info.device
            status = "Paired as \(info.device.id) in \(info.environment.uppercased())."
            await refresh()
        } catch {
            pairingToken = ""
            status = "Pairing failed: \(error.localizedDescription)"
        }
    }

    private func pairOperator() async {
        guard let configuration, let pairedDevice else { return }
        let token = operatorToken.trimmingCharacters(in: .whitespacesAndNewlines)
        operatorToken = ""
        do {
            let probe = PaymentsAPIClient(configuration: configuration, credentialStore: PaymentPairingCredential(token: token))
            let info = try await probe.device()
            guard info.environment == configuration.environment, info.device.accountId == pairedDevice.accountId,
                  info.device.scopes == ["operator"] else {
                throw PaymentsAPIError.configuration("Use an operator-only credential for the same account and environment.")
            }
            try PaymentOperatorCredentialStore(configuration: configuration).save(token)
            await refresh()
        } catch { status = "Operator pairing failed: \(error.localizedDescription)" }
    }

    private func unpair() {
        guard pairingBlockedReason == nil, OperatorAccessPermit.shared.isAuthorized else { return }
        do { try PaymentDeviceCredentialStore().delete() }
        catch { status = "Could not remove the saved credential: \(error.localizedDescription)"; return }
        PaymentsConfiguration.clearPaired()
        configuration = nil
        pairedDevice = nil
        events = []
        diagnostics = nil
        status = "This iPad is no longer paired. Server-managed sessions are unavailable."
    }

}

/// Shared by Help & Recovery and payment maintenance; financial follow-up never disappears
/// merely because an operator released the kiosk for a different guest.
struct CheckoutRecoverySection: View {
    @ObservedObject private var recovery = PaymentRecoveryCoordinator.shared
    @ObservedObject private var operations = EventOperationalState.shared
    @State private var resumeCandidate: CheckoutRecoveryItem?
    @State private var status = ""
    var body: some View {
        Section {
            if let fault = CheckoutCheckpointStore.shared?.integrityFault {
                Label(fault, systemImage: "exclamationmark.octagon").foregroundStyle(.red)
                Button("Acknowledge (server orders remain listed)", role: .destructive) {
                    do { try CheckoutCheckpointStore.shared?.acknowledgeIntegrityFault() }
                    catch { status = "Could not save the acknowledgement: \(error.localizedDescription)" }
                    Task { await recovery.refresh() }
                }
            }
            if CheckoutCheckpointStore.shared == nil {
                Label("Checkout storage is unavailable. Free iPad storage and reopen Help & Recovery; no records were cleared.", systemImage: "exclamationmark.octagon").foregroundStyle(.red)
            }
            if recovery.items.isEmpty, CheckoutCheckpointStore.shared != nil {
                Text("No interrupted paid checkouts on this iPad.").foregroundStyle(.secondary)
            }
            ForEach(recovery.activeItems + recovery.outstandingItems) { item in
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(item.checkpoint.copies)× \(item.checkpoint.format) · \(PHPPriceFormatter.string(centavos: item.checkpoint.unitPriceCentavos * item.checkpoint.copies))")
                        .font(.headline)
                    if item.checkpoint.isParked {
                        Label("Outstanding Payment · Guest Interaction Closed", systemImage: "tray.full").font(.headline)
                        Text("This item does not block unrelated guests or event setup. Resume only the original checkout; do not accept a second payment for it.").font(.footnote).foregroundStyle(.secondary)
                    }
                    Text(item.classification.operatorDescription).font(.subheadline)
                    let copies = PrintOutcomeOutbox.shared?.copiesThatMayHavePrinted(sessionID: item.id) ?? []
                    if !copies.isEmpty {
                        let attempted = Set(copies.map(\.copyIndex)).count
                        Text("\(attempted) of \(item.checkpoint.copies) copies may have printed · \(max(0, item.checkpoint.copies - attempted)) not yet attempted. Never resend an uncertain copy automatically.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if let reason = item.checkpoint.localCloseReason, let date = item.checkpoint.locallyClosedAt {
                        Text("Closed locally \(date.formatted()) · \(reason). Financial status unchanged.").font(.caption).foregroundStyle(.secondary)
                    }
                    if let failure = recovery.resolutionFailures[item.id] { Text(failure).foregroundStyle(.orange) }
                    Text("Checkout \(item.checkpoint.id) · started \(item.checkpoint.createdAt.formatted(date: .omitted, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                    if let reference = item.checkpoint.recoveryReference {
                        Text("Recovery reference: \(reference)")
                            .font(.caption.monospaced()).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Match the guest's saved reference, then verify this checkout. The reference alone does not authorize recovery.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        if item.classification.isResumable {
                            Button("Resume Original Checkout") { resumeCandidate = item }
                                .buttonStyle(.borderedProminent)
                        }
                        if !item.checkpoint.isParked {
                            OperatorCloseContinueButton(checkoutID: item.id,
                                title: recovery.resolutionFailures[item.id] == nil ? "Close Session & Continue" : "Retry Saving Resolution")
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            if !status.isEmpty { Text(status).foregroundStyle(.orange) }
            if !operations.recoveryActionMessage.isEmpty { Text(operations.recoveryActionMessage).font(.footnote) }
            if let armed = recovery.armedResume {
                Label("Armed: the next tap on the welcome screen continues checkout \(armed.item.id) (until \(armed.expiresAt.formatted(date: .omitted, time: .shortened))).", systemImage: "hand.tap")
                Button("Cancel Armed Resume") { recovery.disarmResume() }
            }
            Button("Check Interrupted Checkouts") { Task { await recovery.refresh() } }
            if !recovery.lastRefreshMessage.isEmpty {
                Text(recovery.lastRefreshMessage).font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text("Outstanding Payments & Interrupted Checkouts")
        } footer: {
            Text("Resume only with the paying guest present. Resuming continues the original checkout with the same copies; it never charges again or shows earlier photos. Close Session & Continue parks the guest workflow. The original payment stays listed here until authoritatively reconciled; paid entitlement and copy counts are preserved.")
        }
        .confirmationDialog("Resume this paid session?", isPresented: Binding(get: { resumeCandidate != nil }, set: { if !$0 { resumeCandidate = nil } }), titleVisibility: .visible, presenting: resumeCandidate) { item in
            Button("Resume for Guest Present Now") {
                guard OperatorAccessPermit.shared.isAuthorized, recovery.armResume(item) else {
                    status = "This checkout is no longer resumable."
                    resumeCandidate = nil
                    return
                }
                resumeCandidate = nil
                NotificationCenter.default.post(name: OperatorWorkspace.didResumeCheckout, object: nil)
            }
            Button("Cancel", role: .cancel) {}
        } message: { item in
            Text("This returns to the booth and keeps your setup drafts. Ask the guest to tap Make a Memory within 5 minutes. \(item.classification.operatorDescription)")
        }
        .task { await recovery.refresh() }
    }
}
