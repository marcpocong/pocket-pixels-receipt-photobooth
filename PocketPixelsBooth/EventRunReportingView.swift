import SwiftUI

nonisolated struct EventRunFinancialTotals: Equatable, Sendable {
    let verifiedLive: Int
    let verifiedTest: Int
    let operatorCash: Int
    let declaredCash: Int
    let unresolved: Int
    let review: Int

    static func matchingOrders(_ rows: [OperatorOrderRow], sessions: [EventRunSession]) -> [OperatorOrderRow] {
        let orderIDs = Set(sessions.flatMap(\.orderIDs))
        let sessionIDs = Set(sessions.map(\.sessionID))
        var seen = Set<String>()
        return rows.filter { (orderIDs.contains($0.id) || $0.checkoutSessionId.map { sessionIDs.contains($0) } == true || $0.sessionId.map { sessionIDs.contains($0) } == true) && seen.insert($0.id).inserted }
    }

    init(orders: [OperatorOrderRow]) throws {
        let eligible = orders.filter { $0.supersededByOrderId == nil && $0.entitlementState != "REVIEW_REQUIRED" && !["MANUAL_REVIEW", "LATE_PAID_REVIEW"].contains($0.state) }
        func sum(_ categories: Set<String>) throws -> Int {
            try eligible.filter { categories.contains($0.category) }.reduce(0) { result, row in
                let (total, overflow) = result.addingReportingOverflow(row.totalCentavos)
                guard !overflow, row.totalCentavos >= 0 else { throw PaymentsAPIError.invalidResponse }
                return total
            }
        }
        verifiedLive = try sum(["QRPH_VERIFIED_LIVE"])
        verifiedTest = try sum(["QRPH_VERIFIED_TEST"])
        operatorCash = try sum(["CASH_OPERATOR_CONFIRMED"])
        declaredCash = try sum(["CASH_SELF_REPORTED", "CASH_SELF_REPORTED_OFFLINE_SYNCED"])
        unresolved = orders.filter { $0.category == "QRPH_UNRESOLVED" }.count
        review = orders.count - eligible.count
    }
}

struct EventRunReportingView: View {
    @ObservedObject private var store = EventRunStore.shared
    @ObservedObject private var library = EventDesignLibraryStore.shared
    @ObservedObject private var operations = EventOperationalState.shared
    @State private var sessions: [EventRunSession] = []
    @State private var archives: [RecentSessionArchiveSummary] = []
    @State private var localError: String?
    @State private var selectedRunID: String?
    @State private var showsHistory = false
    @State private var loading = true
    @State private var message = ""
    @State private var pendingAction: String?
    @State private var designCandidate: SavedEventDesign?
    @State private var financials: EventRunFinancialTotals?
    @State private var financialError: String?
    @State private var financialLoading = false
    @State private var orders: [OperatorOrderRow] = []
    @State private var offlineCash: [OfflineCashRecord] = []
    @State private var offlineCashLoaded = false
    @State private var offlineCashError: String?
    @State private var unassignedOfflineCount = 0
    @State private var exportURL: URL?
    @State private var financialRequest = UUID()
    private let archiveDirectory: URL?
    private let loadsRemote: Bool

    init(store: EventRunStore? = nil, library: EventDesignLibraryStore? = nil, archiveDirectory: URL? = nil, loadsRemote: Bool = true) {
        _store = ObservedObject(wrappedValue: store ?? .shared)
        _library = ObservedObject(wrappedValue: library ?? .shared)
        self.archiveDirectory = archiveDirectory
        self.loadsRemote = loadsRemote
    }

    private var selected: EventRunRecord? { store.runs.first { $0.id == (selectedRunID ?? store.currentRunID) } }
    private var runSessions: [EventRunSession] { sessions.filter { $0.runID == selected?.id } }
    private var stats: EventRunStatistics { EventRunStatistics(sessions: runSessions) }
    private var blocked: String? { SessionSetupSafety.blockingReason }

    var body: some View {
        List {
            currentEventSection
            operationsSection
            activitySection
            financialSection
            librarySection
        }
        .navigationTitle("Event Operations & Reports")
        .scrollContentBackground(.hidden)
        .background(MadeToKeepPaperBackground())
        .tint(MadeToKeepTheme.ColorPalette.burgundy)
        .task(id: store.revision) { await loadLocal() }
        .onChange(of: selectedRunID) { _, _ in exportURL = nil; Task { await loadFinancials() } }
        .confirmationDialog("\(pendingAction == "new" ? "Start a fresh event run?" : "Change event-run status?")", isPresented: Binding(get: { pendingAction != nil }, set: { if !$0 { pendingAction = nil } })) {
            Button("Confirm") { perform() }
            Button("Cancel", role: .cancel) { }
        } message: { Text("Only this iPad's occurrence changes. Previous runs, financial records, receipt archives and galleries are retained. A fresh run reuses the current design and commercial event, with unchanged prices and guest admission. Use Session Setup to start accepting guests.") }
        .confirmationDialog("Delete unused design?", isPresented: Binding(get: { designCandidate != nil }, set: { if !$0 { designCandidate = nil } })) {
            Button("Delete Unused Design", role: .destructive) { deleteDesign() }
            Button("Cancel", role: .cancel) { }
        } message: { Text("Applied, commercially linked and historically referenced designs cannot be deleted. Artwork and customer records are never removed.") }
    }


    @ViewBuilder private var currentEventSection: some View {
            Section("Current Event") {
                LabeledContent("Design", value: library.design(id: library.library.appliedEventID)?.displayName ?? "Studio branding")
                LabeledContent("Guest admission", value: (SessionAcceptanceStore.shared.state.blocked || (store.current != nil && store.current?.status != .active)) ? "Paused on this iPad" : "Uses the published payment policy")
                LabeledContent("Printer", value: PrinterCoordinator.shared.requiresRecovery ? "Recovery required" : PrinterCoordinator.shared.state.message)
                NavigationLink("Session Setup — event, copies and prices", value: OperatorWorkspaceRoute.sessionSetup)
                Text("Receipt Event Mode controls branding. Event-run status controls this occurrence; commercial-event lifecycle and pricing are managed in Session Setup.").font(.footnote)
            }
    }

    @ViewBuilder private var operationsSection: some View {
            Section("Event Operations") {
                if let current = store.current {
                    LabeledContent("Current run", value: current.context.name)
                    LabeledContent("Status", value: current.status.rawValue.capitalized)
                    Text(current.id).font(.caption).textSelection(.enabled)
                    if current.status == .active { Button("Pause This iPad’s Run") { pendingAction = "pause" }.disabled(blocked != nil) }
                    if current.status == .paused {
                        NavigationLink("Resume — Review Session Setup", value: OperatorWorkspaceRoute.sessionSetup).disabled(blocked != nil)
                        Text("Commercial payment policy must also be active before guests can start.").font(.footnote)
                    }
                    if [.active, .paused].contains(current.status) { Button("End This Run", role: .destructive) { pendingAction = "end" }.disabled(blocked != nil) }
                }
                Button("Start New Event Run") { pendingAction = "new" }.disabled(blocked != nil)
                if let blocked { Text(blocked).font(.footnote).foregroundStyle(.orange) }
                if let error = store.storageError { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                if !message.isEmpty { Text(message).font(.footnote) }
            }
    }

    @ViewBuilder private var activitySection: some View {
            Section("Sales & Reports — this iPad") {
                Picker("Occurrence", selection: $selectedRunID) {
                    Text("Current run").tag(String?.none)
                    ForEach(store.runs.filter { showsHistory || $0.status != .archived }.reversed()) { run in
                        Text("\(run.context.name) · \(run.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(run.status.rawValue)").tag(Optional(run.id))
                    }
                }
                Toggle("Include archived runs", isOn: $showsHistory)
                if loading { ProgressView("Reading saved activity…") }
                if let localError { Label(localError, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                if !loading, localError == nil, selected != nil {
                    LabeledContent("Completed sessions", value: String(stats.completed))
                    ForEach(stats.completedByFormat.keys.sorted(), id: \.self) { format in
                        LabeledContent("  \(BoothFormat(rawValue: format)?.displayName ?? format)", value: String(stats.completedByFormat[format] ?? 0))
                    }
                    LabeledContent("Copies transport-delivered", value: String(stats.delivered))
                    LabeledContent("Copies uncertain / in flight", value: String(stats.uncertain))
                    LabeledContent("Copies not started", value: String(stats.notStarted))
                    LabeledContent("Public galleries verified", value: String(stats.galleriesVerified))
                    LabeledContent("Galleries awaiting verification", value: String(stats.galleriesAwaitingVerification))
                    LabeledContent("Archive reprint requests", value: String(archives.filter { $0.eventRunID == selected?.id }.reduce(0) { $0 + $1.reprintCount }))
                    Text("Completion is recorded after the original print batch succeeds. Transport delivery is not sensor-confirmed paper output. Reprint requests are listed separately. Older archives remain in Recent Sessions without an invented run assignment.").font(.footnote)
                    if runSessions.isEmpty { Text("No sessions recorded for this run.").foregroundStyle(.secondary) }
                    Button("Prepare Run CSV") { export() }
                    if let exportURL { ShareLink("Share Run CSV", item: exportURL) }
                } else if selected == nil, !loading { Text("No event run has started. Historical archives remain in Recent Sessions.") }
                Button("Reset Dashboard Filters") { selectedRunID = nil; showsHistory = false; exportURL = nil }
                NavigationLink("Commercial Event Reports — all runs and iPads") { PaymentsOperatorView(salesOnly: true) }
                NavigationLink("Recent Sessions, Receipts & Reprints", value: OperatorWorkspaceRoute.recentSessions)
                NavigationLink("Waiting Galleries", value: OperatorWorkspaceRoute.waitingGalleries)
            }
    }

    @ViewBuilder private var financialSection: some View {
            if selected?.context.commercialEventID != nil {
                Section("Payments for this run — server order evidence") {
                    if financialLoading { ProgressView("Checking every order page…") }
                    if let financialError { Label(financialError, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                    if let financials {
                        money("QR Ph LIVE verified", financials.verifiedLive)
                        money("QR Ph TEST (excluded from LIVE)", financials.verifiedTest)
                        money("Attendant-confirmed cash", financials.operatorCash)
                        money("Guest-declared cash (unverified)", financials.declaredCash)
                        LabeledContent("Unresolved QR payments", value: String(financials.unresolved))
                        LabeledContent("Held / replaced orders excluded", value: String(financials.review))
                    }
                    if offlineCashLoaded { money("Offline cash waiting to sync (unverified)", offlineCash.reduce(0) { $0 + $1.totalCentavos }) }
                    else if let offlineCashError { Label(offlineCashError, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                    else { Text("Offline cash totals have not been loaded.").font(.footnote) }
                    if unassignedOfflineCount > 0 { Text("\(unassignedOfflineCount) legacy cash record(s) lack an environment and are excluded from the amount above.").foregroundStyle(.orange) }
                    let memberIDs = Set(runSessions.map(\.sessionID))
                    let savedCheckouts = CheckoutCheckpointStore.shared?.unresolved.filter { memberIDs.contains($0.id) }.count ?? 0
                    if savedCheckouts > 0 { Text("\(savedCheckouts) saved checkout record(s) for this run still need Payment Recovery review. Pending or unmatched records are never counted as verified revenue.").foregroundStyle(.orange) }
                    Text("Matches saved order IDs or exact session IDs for this occurrence, never names or dates. Unmatched older orders stay in the commercial event report. Physical cash reconciliation belongs to that report and covers all its runs.").font(.footnote)
                    ForEach(orders) { order in
                        VStack(alignment: .leading) {
                            Text("\(PHPPriceFormatter.string(centavos: order.totalCentavos)) · \(order.copies)× \(order.boothFormat)")
                            Text("\(order.category) · \(order.state)").font(.caption)
                        }
                    }
                    Button("Refresh Run Payments") { Task { await loadFinancials() } }
                }
            }
    }

    @ViewBuilder private var librarySection: some View {
            Section("Event Library & History") {
                NavigationLink("Commercial Event History & Archive") { PaymentsOperatorView(salesOnly: true, allowsEventMaintenance: true) }
                if let selected, [.completed, .draft].contains(selected.status) {
                    Button("Archive Selected Run") { pendingAction = "archive" }.disabled(blocked != nil)
                }
                Text("Archiving hides an occurrence from everyday selection; its sessions, receipts, galleries, entitlements and reports remain saved.").font(.footnote)
                ForEach(library.library.events) { design in
                    HStack {
                        VStack(alignment: .leading) { Text(design.displayName); Text(design.archivedAt == nil ? "Saved design" : "Archived design — history retained").font(.caption) }
                        Spacer()
                        Menu("Manage") {
                            if design.archivedAt == nil { Button("Archive Design") { archiveDesign(design) } }
                            else { Button("Restore Design") { restoreDesign(design) } }
                            Button("Delete Unused Design…", role: .destructive) { designCandidate = design }
                        }
                    }.frame(minHeight: 48)
                }
            }
    }

    private func money(_ title: String, _ centavos: Int) -> some View { LabeledContent(title, value: PHPPriceFormatter.string(centavos: centavos)) }

    private func loadLocal() async {
        let directory = store.directory
        loading = true
        do {
            await store.reconcilePrintEvidence(PrintOutcomeOutbox.shared?.entries ?? [])
            let loaded = try await Task.detached { try EventRunStore.loadSessions(directory: directory) }.value
            let archiveDirectory = archiveDirectory
            let saved = try await Task.detached { try RecentSessionArchiveStore(directoryURL: archiveDirectory).summaries() }.value
            guard !Task.isCancelled else { return }
            sessions = loaded; archives = saved; localError = nil; loading = false
            await loadFinancials()
        } catch { localError = "Operational history unavailable: \(error.localizedDescription)"; loading = false }
    }

    private func loadFinancials() async {
        let request = UUID(); financialRequest = request
        financials = nil; financialError = nil; orders = []; offlineCash = []; financialLoading = false
        offlineCashLoaded = false; offlineCashError = nil; unassignedOfflineCount = 0
        guard let run = selected, let eventID = run.context.commercialEventID else { return }
        guard loadsRemote else { financialError = "Synthetic preview — remote reporting disabled."; return }
        guard localError == nil, let configuration = PaymentsConfiguration.current(), run.context.serverBinding == OperatorWorkspace.shared.serverBinding else {
            financialError = "Use the operator credential and payments environment saved with this run. Totals are unavailable until its exact server is selected."; return
        }
        let members = runSessions
        financialLoading = true
        defer { if financialRequest == request { financialLoading = false } }
        if let ledger = OfflineCashLedger.shared {
            if let fault = await ledger.integrityFault { offlineCashError = fault }
            else {
                let records = await ledger.pendingRecords()
                guard financialRequest == request, selected?.id == run.id, !Task.isCancelled else { return }
                do {
                    let local = try OfflineCashReportingSnapshot(records: records, eventID: eventID, environment: configuration.environment, sessionIDs: Set(members.map(\.sessionID)))
                    offlineCash = local.pending; unassignedOfflineCount = local.unassigned.count; offlineCashLoaded = true
                } catch { offlineCashError = "Local cash totals unavailable: \(error.localizedDescription)" }
            }
        } else { offlineCashError = "Local offline cash storage is unavailable." }
        do {
            let rows = try await PaymentsAPIClient(configuration: configuration).allEventOrders(id: eventID, requireCheckoutIdentity: true)
            guard financialRequest == request, selected?.id == run.id, OperatorWorkspace.shared.serverBinding == run.context.serverBinding, !Task.isCancelled else { return }
            let matching = EventRunFinancialTotals.matchingOrders(rows, sessions: members)
            financials = try EventRunFinancialTotals(orders: matching); orders = matching
        } catch {
            guard financialRequest == request else { return }
            financialError = "Run payment report unavailable: \(error.localizedDescription). Check the separate operator credential in Payment Maintenance."
        }
    }

    private func perform() {
        defer { pendingAction = nil }
        do {
            if pendingAction == "new" { _ = try store.startNewRun(context: EventRunStore.currentContext()); selectedRunID = nil }
            else if let run = pendingAction == "archive" ? selected : store.current {
                let status: EventRunStatus = switch pendingAction { case "pause": .paused; case "resume": .active; case "end": .completed; default: .archived }
                if status == .paused || status == .completed {
                    try store.pauseOrEndCurrentRun(admission: .shared, status: status)
                } else { try store.transition(id: run.id, to: status) }
                if status == .archived { selectedRunID = nil }
            }
            message = "Event-run change saved. Historical and financial records were retained."
        } catch { message = error.localizedDescription }
    }

    private func restoreDesign(_ design: SavedEventDesign) {
        do { try library.restoreDesign(id: design.id); message = "Design restored to the event library. Guest setup is unchanged." }
        catch { message = error.localizedDescription }
    }

    private func archiveDesign(_ design: SavedEventDesign) {
        do { try library.archiveDesign(id: design.id); message = "Design archived; history and artwork retained." }
        catch { message = error.localizedDescription }
    }
    private func deleteDesign() {
        defer { designCandidate = nil }
        guard let designCandidate else { return }
        do {
            guard localError == nil, !loading else { throw SetupFailure("Load event history before deleting a design.") }
            try library.deleteUnusedDesign(id: designCandidate.id, runs: store.runs, archives: archives, historyAvailable: store.storageError == nil)
            message = "Unused design removed. Artwork, drafts and customer records were retained."
        } catch { message = error.localizedDescription }
    }
    private func export() {
        guard let selected, localError == nil else { return }
        func cell(_ text: String) -> String { "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        let header = "run_id,session_id,created_at_utc,format,completed_at_utc,transport_delivered,uncertain,gallery_verified_at_utc\r\n"
        let body = runSessions.map { record in
            [selected.id, record.sessionID, record.createdAt.ISO8601Format(), record.format,
             record.completedAt?.ISO8601Format() ?? "", String(record.printOutcomes.values.filter { $0 == "delivered" }.count),
             String(record.printOutcomes.values.filter { $0 == "uncertain" || $0 == "inFlight" }.count), record.galleryVerifiedAt?.ISO8601Format() ?? ""].map(cell).joined(separator: ",")
        }.joined(separator: "\r\n")
        do {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("event-run-\(selected.id).csv")
            try Data((header + body + "\r\n").utf8).write(to: url, options: [.atomic, .completeFileProtection])
            exportURL = url
        } catch { message = "CSV export failed: \(error.localizedDescription)" }
    }
}
