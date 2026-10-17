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

/// One reporting home: Overview, Activity, Sales, History and Manage share a single run picker.
/// Operational numbers come from this iPad's exact session journal; money comes only from the
/// authoritative server orders and is never inferred from names, dates or local guesses.
struct EventRunReportingView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case overview = "Overview", activity = "Activity", sales = "Sales", history = "History", manage = "Manage"
        var id: String { rawValue }
    }

    @ObservedObject private var store: EventRunStore
    @ObservedObject private var library: EventDesignLibraryStore
    @ObservedObject private var attributionStore: LegacyAttributionStore
    @ObservedObject private var operations = EventOperationalState.shared
    @State private var tab: Tab
    @State private var sessions: [EventRunSession] = []
    @State private var archives: [RecentSessionArchiveSummary] = []
    @State private var history: HistoricalActivityReport?
    @State private var localError: String?
    @State private var selectedRunID: String?
    @State private var showsArchived = false
    @State private var loading = true
    @State private var message = ""
    @State private var pendingAction: String?
    @State private var designCandidate: SavedEventDesign?
    @State private var financials: EventRunFinancialTotals?
    @State private var financialError: String?
    @State private var financialLoading = false
    @State private var financialLoadedAt: Date?
    @State private var orders: [OperatorOrderRow] = []
    @State private var unmatchedCommercialOrders: Int?
    @State private var offlineCash: [OfflineCashRecord] = []
    @State private var offlineCashLoaded = false
    @State private var offlineCashError: String?
    @State private var unassignedOfflineCount = 0
    @State private var exportURL: URL?
    @State private var financialRequest = UUID()
    @State private var attributionGroup: HistoricalActivityReport.DayGroup?
    private let archiveDirectory: URL?
    private let loadsRemote: Bool

    init(store: EventRunStore? = nil, library: EventDesignLibraryStore? = nil, archiveDirectory: URL? = nil, loadsRemote: Bool = true,
         attributions: LegacyAttributionStore? = nil, initialTab: Tab = .overview) {
        _store = ObservedObject(wrappedValue: store ?? .shared)
        _library = ObservedObject(wrappedValue: library ?? .shared)
        _attributionStore = ObservedObject(wrappedValue: attributions ?? .shared)
        _tab = State(initialValue: initialTab)
        self.archiveDirectory = archiveDirectory
        self.loadsRemote = loadsRemote
    }

    private var selected: EventRunRecord? { store.runs.first { $0.id == (selectedRunID ?? store.currentRunID) } }
    private var runSessions: [EventRunSession] { sessions.filter { $0.runID == selected?.id } }
    private var stats: EventRunStatistics { EventRunStatistics(sessions: runSessions) }
    private var blocked: String? { SessionSetupSafety.blockingReason }
    private var pickerRuns: [EventRunRecord] { store.runs.filter { showsArchived || $0.status != .archived }.reversed() }

    var body: some View {
        List {
            Section {
                Picker("Section", selection: $tab) { ForEach(Tab.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("report-tabs")
                if tab != .manage { runPicker }
            }
            switch tab {
            case .overview: overviewTab
            case .activity: activityTab
            case .sales: salesTab
            case .history: historyTab
            case .manage: manageTab
            }
            if !message.isEmpty { Section { Text(message).font(.callout) } }
        }
        .navigationTitle("Reports & Statistics")
        .scrollContentBackground(.hidden)
        .background(MadeToKeepPaperBackground())
        .tint(MadeToKeepTheme.ColorPalette.burgundy)
        .task(id: store.revision) { await loadLocal() }
        .onChange(of: selectedRunID) { _, _ in exportURL = nil; Task { await loadFinancials() } }
        .confirmationDialog(dialogTitle, isPresented: Binding(get: { pendingAction != nil }, set: { if !$0 { pendingAction = nil } }), titleVisibility: .visible) {
            Button("Archive Run") { perform() }
            Button("Cancel", role: .cancel) { }
        } message: { Text(dialogMessage) }
        .confirmationDialog("Delete unused design?", isPresented: Binding(get: { designCandidate != nil }, set: { if !$0 { designCandidate = nil } })) {
            Button("Delete Unused Design", role: .destructive) { deleteDesign() }
            Button("Cancel", role: .cancel) { }
        } message: { Text("Applied, commercially linked and historically referenced designs cannot be deleted. Artwork and customer records are never removed.") }
        .sheet(item: $attributionGroup) { group in
            LegacyAttributionSheet(group: group, store: store, attributions: attributionStore, exactSessionIDs: Set(sessions.map(\.sessionID))) { result in
                message = result; attributionGroup = nil
                Task { await loadLocal() }
            }
        }
    }

    // MARK: Shared

    @ViewBuilder private var runPicker: some View {
        Picker("Event run", selection: $selectedRunID) {
            Text(store.current.map { "Current — \(label($0))" } ?? "Current run").tag(String?.none)
            ForEach(pickerRuns) { run in Text(label(run)).tag(Optional(run.id)) }
        }
        .accessibilityIdentifier("run-picker")
    }

    private func label(_ run: EventRunRecord) -> String {
        "\(run.context.name.isEmpty ? "Regular Sessions" : run.context.name) · \(run.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(statusText(run))"
    }
    private func statusText(_ run: EventRunRecord) -> String {
        if run.isHistorical { return "earlier event" }
        switch run.status { case .draft: return "draft"; case .active: return "active"; case .paused: return "paused"; case .completed: return "ended"; case .archived: return "archived" }
    }

    // MARK: Overview

    @ViewBuilder private var overviewTab: some View {
        if loading { Section { ProgressView("Reading saved activity…") } }
        if let localError { Section { Label(localError, systemImage: "exclamationmark.triangle").foregroundStyle(.red) } }
        if let run = selected {
            Section("Event") {
                LabeledContent("Event", value: run.context.name.isEmpty ? "Regular Sessions" : run.context.name)
                LabeledContent("Status", value: statusText(run).capitalized)
                LabeledContent("Design", value: library.design(id: run.context.designID)?.displayName ?? "Studio branding")
                LabeledContent("Payment", value: run.context.commercialEventID == nil ? "No payment (prepaid / free)" : "Paid — \(run.context.serverBinding?.hasPrefix("live:") == true ? "LIVE" : "TEST")")
                LabeledContent("Started", value: run.createdAt.formatted(date: .abbreviated, time: .shortened))
                if let ended = run.endedAt { LabeledContent("Ended", value: ended.formatted(date: .abbreviated, time: .shortened)) }
                if let previous = run.previousRunID, let earlier = store.runs.first(where: { $0.id == previous }) {
                    LabeledContent("Follows", value: earlier.createdAt.formatted(date: .abbreviated, time: .shortened))
                }
            }
            if !loading, localError == nil {
                Section("At a glance") {
                    LabeledContent("Completed sessions", value: String(stats.completed))
                    LabeledContent("Copies delivered to printer", value: String(stats.delivered))
                    LabeledContent("Galleries verified", value: String(stats.galleriesVerified))
                    LabeledContent("Galleries pending", value: String(stats.galleriesAwaitingVerification))
                    if let attributed = history?.attributedByRun[run.id], attributed > 0 {
                        LabeledContent("Earlier sessions attributed by operator", value: String(attributed))
                    }
                }
                exceptionsSection
            }
        } else if !loading {
            Section { Text("No event run has started on this iPad. Earlier sessions are listed under History.").foregroundStyle(.secondary) }
        }
        Section {
            NavigationLink("Event Setup", value: OperatorWorkspaceRoute.sessionSetup)
        } footer: { Text("Start, pause and end the event from Current Event on the operator home screen.") }
    }

    @ViewBuilder private var exceptionsSection: some View {
        let memberIDs = Set(runSessions.map(\.sessionID))
        let savedCheckouts = CheckoutCheckpointStore.shared?.unresolved.filter { memberIDs.contains($0.id) }.count ?? 0
        if stats.uncertain + stats.notStarted > 0 || savedCheckouts > 0 || store.storageError != nil {
            Section("Needs attention") {
                if stats.uncertain > 0 { Label("\(stats.uncertain) copies have uncertain print output — check paper in Fix Printer.", systemImage: "printer.dotmatrix") }
                if stats.notStarted > 0 { Label("\(stats.notStarted) copies never started printing.", systemImage: "exclamationmark.circle") }
                if savedCheckouts > 0 { Label("\(savedCheckouts) saved checkout(s) still need Payment Recovery review.", systemImage: "creditcard.trianglebadge.exclamationmark") }
                if let error = store.storageError { Label(error, systemImage: "externaldrive.badge.exclamationmark").foregroundStyle(.orange) }
            }
        }
    }

    // MARK: Activity

    @ViewBuilder private var activityTab: some View {
        Section("Activity — this iPad") {
            if loading { ProgressView("Reading saved activity…") }
            if let localError { Label(localError, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
            if !loading, localError == nil, let selected {
                LabeledContent("Completed sessions", value: String(stats.completed))
                ForEach(stats.completedByFormat.keys.sorted(), id: \.self) { format in
                    LabeledContent("  \(BoothFormat(rawValue: format)?.displayName ?? format)", value: String(stats.completedByFormat[format] ?? 0))
                }
                LabeledContent("Copies transport-delivered", value: String(stats.delivered))
                LabeledContent("Copies uncertain / in flight", value: String(stats.uncertain))
                LabeledContent("Copies not started", value: String(stats.notStarted))
                LabeledContent("Public galleries verified", value: String(stats.galleriesVerified))
                LabeledContent("Galleries awaiting verification", value: String(stats.galleriesAwaitingVerification))
                LabeledContent("Archive reprint requests", value: String(archives.filter { $0.eventRunID == selected.id }.reduce(0) { $0 + $1.reprintCount }))
                if let attributed = history?.attributedByRun[selected.id], attributed > 0 {
                    LabeledContent("Operator-attributed earlier sessions (not exact)", value: String(attributed))
                }
                if runSessions.isEmpty { Text("No sessions recorded for this run.").foregroundStyle(.secondary) }
                Button("Prepare Run CSV") { export() }
                if let exportURL { ShareLink("Share Run CSV", item: exportURL) }
            } else if selected == nil, !loading { Text("No event run has started. Earlier sessions are listed under History.") }
        }
        Section {
            NavigationLink("Recent Sessions, Receipts & Reprints", value: OperatorWorkspaceRoute.recentSessions)
            NavigationLink("Waiting Galleries (\(operations.pendingUploadCount))", value: OperatorWorkspaceRoute.waitingGalleries)
        } footer: {
            Text("Completion is recorded after the original print batch succeeds. Transport delivery is not sensor-confirmed paper output. Reprints are listed separately.")
        }
    }

    // MARK: Sales

    @ViewBuilder private var salesTab: some View {
        if let run = selected, let eventID = run.context.commercialEventID {
            Section {
                if financialLoading { ProgressView("Checking every order page…") }
                if let financialError { Label(financialError, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                if let financials {
                    money("QR Ph verified — LIVE", financials.verifiedLive)
                    money("QR Ph verified — TEST (not revenue)", financials.verifiedTest)
                    money("Cash confirmed by attendant", financials.operatorCash)
                    money("Cash declared by guest (unverified)", financials.declaredCash)
                    LabeledContent("Unresolved QR payments", value: String(financials.unresolved))
                    LabeledContent("Held / replaced orders excluded", value: String(financials.review))
                }
                if offlineCashLoaded { money("Offline cash waiting to sync (unverified)", offlineCash.reduce(0) { $0 + $1.totalCentavos }) }
                else if let offlineCashError { Label(offlineCashError, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                else if !financialLoading { Text("Offline cash totals have not been loaded.").font(.footnote) }
                if unassignedOfflineCount > 0 { Text("\(unassignedOfflineCount) legacy cash record(s) lack an environment and are excluded from the amount above.").foregroundStyle(.orange) }
                if let financialLoadedAt { Text("Last refreshed \(financialLoadedAt.formatted(date: .omitted, time: .shortened)).").font(.footnote).foregroundStyle(.secondary) }
                Button("Refresh Sales") { Task { await loadFinancials() } }.disabled(financialLoading)
            } header: { Text("This run — exact order evidence") } footer: {
                Text("Matches saved order IDs, original checkout IDs and claimed session IDs for this occurrence, never names or dates. Refunds, fees and payouts are not tracked.")
            }
            Section {
                if let unmatched = unmatchedCommercialOrders {
                    LabeledContent("Orders not linked to any run on this iPad", value: String(unmatched))
                    if unmatched > 0 { Text("These belong to other iPads or to sessions before runs were recorded. They stay in the paid event's totals and are never guessed into a run.").font(.footnote) }
                }
                NavigationLink("Paid Event Report — all runs and iPads", value: OperatorWorkspaceRoute.eventReport(eventID))
            } header: { Text("Whole paid event") } footer: {
                Text("The paid event report includes physical cash counts, every order and the complete financial CSV.")
            }
            if !orders.isEmpty {
                Section("Orders in this run") {
                    ForEach(orders) { order in
                        VStack(alignment: .leading) {
                            Text("\(PHPPriceFormatter.string(centavos: order.totalCentavos)) · \(order.copies)× \(order.boothFormat)")
                            Text("\(order.category) · \(order.state)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } else if selected != nil {
            Section { Text("This run didn't collect payments (prepaid or free). Its sessions and prints are under Activity.").foregroundStyle(.secondary) }
        }
        Section {
            NavigationLink("All Paid Events & Sales") { PaymentsOperatorView(salesOnly: true) }
        } footer: { Text("Uses the separate operator credential for this payments connection.") }
    }

    // MARK: History

    @ViewBuilder private var historyTab: some View {
        Section {
            Toggle("Include archived runs", isOn: $showsArchived)
            ForEach(pickerRuns) { run in
                Button {
                    selectedRunID = run.id == store.currentRunID ? nil : run.id
                    tab = .activity
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(run.context.name.isEmpty ? "Regular Sessions" : run.context.name).font(.headline).foregroundStyle(MadeToKeepTheme.ColorPalette.ink)
                        Text("\(run.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(statusText(run)) · \(sessions.filter { $0.runID == run.id && $0.completedAt != nil }.count) sessions")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }
            }
            if pickerRuns.isEmpty { Text("No event runs yet.").foregroundStyle(.secondary) }
        } header: { Text("Event runs") } footer: { Text("Tap a run to see its activity. Each new occurrence has its own run and statistics.") }
        Section {
            if let history {
                LabeledContent("Earlier sessions without a run", value: String(history.unassignedCount))
                if history.unassignedPrintCopies > 0 { LabeledContent("Print copies without a run", value: String(history.unassignedPrintCopies)) }
                if history.corruptArchives > 0 { Label("\(history.corruptArchives) archived session(s) could not be read and are excluded.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                ForEach(history.unassigned) { group in
                    Button { attributionGroup = group } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(group.day.formatted(date: .complete, time: .omitted)).font(.headline).foregroundStyle(MadeToKeepTheme.ColorPalette.ink)
                            Text("\(group.archives.count) sessions · " + group.byFormat.keys.sorted().map { "\(group.byFormat[$0] ?? 0) \(BoothFormat(rawValue: $0)?.displayName ?? $0)" }.joined(separator: ", "))
                                .font(.caption).foregroundStyle(.secondary)
                            if !group.names.isEmpty { Text("Receipt names: \(group.names.joined(separator: ", "))").font(.caption2).foregroundStyle(.secondary) }
                        }
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }
                    .disabled(store.historyUnreadable)
                }
            } else if !loading, localError == nil { Text("Earlier sessions have not been checked.").foregroundStyle(.secondary) }
            if let error = attributionStore.storageError { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
        } header: { Text("Unassigned earlier activity") } footer: {
            Text(HistoricalActivityReport.unassignedReason + " Tap a day to review it and, if you know which event it was, attribute it explicitly. Attributions are permanent, audited and shown separately. Sales are never attributed.")
        }
        Section {
            NavigationLink("Paid Event History & Archive") { PaymentsOperatorView(salesOnly: true, allowsEventMaintenance: true) }
        }
    }

    // MARK: Manage

    @ViewBuilder private var manageTab: some View {
        Section {
            if let current = store.current { LabeledContent("Current run", value: label(current)) }
            NavigationLink(value: OperatorWorkspaceRoute.sessionSetup) {
                Label("Start a New Occurrence in Event Setup", systemImage: "calendar.badge.plus").frame(minHeight: 44)
            }
            .accessibilityIdentifier("manage-new-occurrence")
            if let selected, selected.status == .completed || selected.status == .draft {
                Button("Archive Selected Run…") { pendingAction = "archive" }.disabled(blocked != nil).frame(minHeight: 44)
            }
            Picker("Selected run", selection: $selectedRunID) {
                Text("Current run").tag(String?.none)
                ForEach(pickerRuns) { Text(label($0)).tag(Optional($0.id)) }
            }
            if let blocked { Text(blocked).font(.footnote).foregroundStyle(.orange) }
            if let error = store.storageError { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
        } header: { Text("Event runs") } footer: {
            Text("Reports never change the running event. For fresh statistics, end the event from Current Event, then use Start New Occurrence in Event Setup: it reviews the design and payment setup and keeps the ended run's history. Archiving hides an ended run from everyday lists; its sessions, receipts, galleries, entitlements and reports stay saved.")
        }
        Section {
            ForEach(library.library.events) { design in
                HStack {
                    VStack(alignment: .leading) {
                        Text(design.displayName)
                        Text(design.archivedAt == nil ? "Saved design" : "Archived design — history retained").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Menu("Manage") {
                        if design.archivedAt == nil { Button("Archive Design") { archiveDesign(design) } }
                        else { Button("Restore Design") { restoreDesign(design) } }
                        Button("Delete Unused Design…", role: .destructive) { designCandidate = design }
                    }
                }.frame(minHeight: 48)
            }
            NavigationLink("Event Setup — create or reuse a design", value: OperatorWorkspaceRoute.sessionSetup)
        } header: { Text("Reusable designs") } footer: {
            Text("Archiving a design never archives its runs or paid events. Only designs with no run, archive or paid-event history can be deleted.")
        }
    }

    // MARK: Loading

    private func money(_ title: String, _ centavos: Int) -> some View { LabeledContent(title, value: PHPPriceFormatter.string(centavos: centavos)) }

    private func loadLocal() async {
        let directory = store.directory
        loading = true
        do {
            let entries = PrintOutcomeOutbox.shared?.entries ?? []
            await store.reconcilePrintEvidence(entries)
            let loaded = try await Task.detached { try EventRunStore.loadSessions(directory: directory) }.value
            let archiveDirectory = archiveDirectory
            let saved = try await Task.detached { try RecentSessionArchiveStore(directoryURL: archiveDirectory).summaries() }.value
            guard !Task.isCancelled else { return }
            sessions = loaded; archives = saved; localError = nil; loading = false
            history = HistoricalActivityReport(archives: saved, sessions: loaded, runs: store.runs, attributions: attributionStore.attributions, printEntries: entries)
            await loadFinancials()
        } catch { localError = "Operational history unavailable: \(error.localizedDescription)"; history = nil; loading = false }
    }

    private func loadFinancials() async {
        let request = UUID(); financialRequest = request
        financials = nil; financialError = nil; orders = []; offlineCash = []; financialLoading = false; unmatchedCommercialOrders = nil
        offlineCashLoaded = false; offlineCashError = nil; unassignedOfflineCount = 0
        guard let run = selected, let eventID = run.context.commercialEventID else { return }
        guard loadsRemote else { financialError = "Synthetic preview — remote reporting disabled."; return }
        guard localError == nil, let configuration = PaymentsConfiguration.current(), run.context.serverBinding == OperatorWorkspace.shared.serverBinding else {
            financialError = "Use the operator credential and payments environment saved with this run. Totals are unavailable until its exact server is selected."; return
        }
        let members = runSessions
        let everyRun = sessions
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
            unmatchedCommercialOrders = CommercialAttribution.unmatchedOrders(rows, allSessions: everyRun).count
            financialLoadedAt = Date()
        } catch {
            guard financialRequest == request else { return }
            financialError = "Run sales unavailable: \(error.localizedDescription). This does not mean sales are zero. Check the separate operator credential in Payment Maintenance."
        }
    }

    // MARK: Actions

    private var dialogTitle: String { "Archive this run?" }
    private var dialogMessage: String {
        "The run is hidden from everyday lists. Its sessions, receipts, galleries, payments and reports are kept and stay available under History."
    }

    private func perform() {
        defer { pendingAction = nil }
        do {
            if pendingAction == "archive", let run = selected {
                try store.transition(id: run.id, to: .archived); selectedRunID = nil
                message = "Run archived. Its history and reports were retained."
            }
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
        do {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("event-run-\(selected.id).csv")
            try Data(EventRunCSV.make(run: selected, sessions: runSessions).utf8).write(to: url, options: [.atomic, .completeFileProtection])
            exportURL = url
        } catch { message = "CSV export failed: \(error.localizedDescription)" }
    }
}

/// Operational CSV for one occurrence. Contains identities and outcomes only — no gallery
/// tokens, URLs, photos, credentials or customer details.
nonisolated enum EventRunCSV {
    static let header = "run_id,event_name,session_id,created_at_utc,format,completed_at_utc,transport_delivered,uncertain,not_started,gallery_verified_at_utc"

    static func make(run: EventRunRecord, sessions: [EventRunSession]) -> String {
        func cell(_ text: String) -> String {
            // Neutralize spreadsheet formulas as well as quotes.
            let safe = ["=", "+", "-", "@"].contains(where: text.hasPrefix) ? "'" + text : text
            return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        let rows = sessions.filter { $0.runID == run.id }.sorted { $0.createdAt < $1.createdAt }.map { record in
            [run.id, run.context.name, record.sessionID, record.createdAt.ISO8601Format(), record.format, record.completedAt?.ISO8601Format() ?? "",
             String(record.printOutcomes.values.filter { $0 == "delivered" }.count),
             String(record.printOutcomes.values.filter { $0 == "uncertain" || $0 == "inFlight" }.count),
             String(record.printOutcomes.values.filter { $0 == "notStarted" }.count),
             record.galleryVerifiedAt?.ISO8601Format() ?? ""].map(cell).joined(separator: ",")
        }
        return ([header] + rows).joined(separator: "\r\n") + "\r\n"
    }
}

/// Explicit, audited attribution of one day's legacy sessions to an occurrence.
private struct LegacyAttributionSheet: View {
    let group: HistoricalActivityReport.DayGroup
    @ObservedObject var store: EventRunStore
    @ObservedObject var attributions: LegacyAttributionStore
    let exactSessionIDs: Set<String>
    let onDone: (String) -> Void
    @State private var targetRunID: String?
    @State private var createsRecord = true
    @State private var name = ""
    @State private var note = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Sessions") {
                    LabeledContent("Day", value: group.day.formatted(date: .complete, time: .omitted))
                    LabeledContent("Sessions", value: String(group.archives.count))
                    if let first = group.archives.first, let last = group.archives.last {
                        LabeledContent("Between", value: "\(first.createdAt.formatted(date: .omitted, time: .shortened)) – \(last.createdAt.formatted(date: .omitted, time: .shortened))")
                    }
                    if !group.names.isEmpty { LabeledContent("Receipt names", value: group.names.joined(separator: ", ")) }
                    Text(HistoricalActivityReport.unassignedReason).font(.footnote).foregroundStyle(.secondary)
                }
                Section("Attribute to") {
                    Toggle("Create an earlier-event record", isOn: $createsRecord)
                    if createsRecord {
                        TextField("Event name", text: $name).textInputAutocapitalization(.words)
                    } else {
                        Picker("Existing run", selection: $targetRunID) {
                            Text("Choose…").tag(String?.none)
                            ForEach(store.runs.reversed()) { Text("\($0.context.name) · \($0.createdAt.formatted(date: .abbreviated, time: .omitted))").tag(Optional($0.id)) }
                        }
                    }
                    TextField("Reason (required)", text: $note)
                }
                Section {
                    Button("Attribute \(group.archives.count) Sessions") { attribute() }
                        .disabled(note.trimmingCharacters(in: .whitespaces).isEmpty || (createsRecord ? name.trimmingCharacters(in: .whitespaces).isEmpty : targetRunID == nil))
                    if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                } footer: {
                    Text("Permanent and audited. Counts appear separately as operator-attributed, never as exact run statistics. Receipts, galleries and payment records are not changed, and no sales are attributed.")
                }
            }
            .navigationTitle("Review Earlier Sessions")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { onDone("") } } }
            .onAppear { if name.isEmpty { name = group.names.first ?? "" } }
        }
    }

    private func attribute() {
        do {
            let run: EventRunRecord
            if createsRecord {
                let first = group.archives.first?.createdAt ?? group.day, last = group.archives.last?.createdAt ?? group.day
                run = try store.createHistoricalRun(name: name, designID: group.archives.compactMap(\.eventDesignID).first, startedAt: first, endedAt: last)
            } else {
                guard let id = targetRunID, let existing = store.runs.first(where: { $0.id == id }) else { return }
                run = existing
            }
            var count = 0
            for archive in group.archives where !attributions.attributions.contains(where: { $0.archiveID == archive.archiveID }) {
                try attributions.attribute(archive, to: run, note: note, exact: exactSessionIDs)
                count += 1
            }
            onDone("\(count) earlier session(s) attributed to \(run.context.name). They are reported separately from exact statistics.")
        } catch { self.error = error.localizedDescription }
    }
}
