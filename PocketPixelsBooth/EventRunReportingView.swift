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
        case overview = "Overview", activity = "Sessions", sales = "Sales", printing = "Printing", galleries = "Galleries", history = "History", manage = "Manage"
        static let reportSections: [Tab] = [.overview, .activity, .printing, .galleries, .sales, .history]
        var id: String { rawValue }
    }

    @ObservedObject private var workspace: OperatorWorkspace
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
    @State private var selectedArchiveIDs: Set<String> = []
    @State private var sessionSearch = ""
    @State private var sessionFormat = "all"
    @State private var sessionFilter = "all"
    @StateObject private var archiveModel: RecentSessionsViewModel
    @State private var attributionSelection: AttributionSelection?
    private let archiveDirectory: URL?
    private let loadsRemote: Bool

    init(store: EventRunStore? = nil, library: EventDesignLibraryStore? = nil, archiveDirectory: URL? = nil, loadsRemote: Bool = true,
         attributions: LegacyAttributionStore? = nil, initialTab: Tab? = nil, workspace: OperatorWorkspace? = nil) {
        let workspace = workspace ?? .shared
        let selectedStore = store ?? .shared
        _workspace = ObservedObject(wrappedValue: workspace)
        let restoredRun = selectedStore.runs.first { $0.id == workspace.snapshot.reportRunID }
        _selectedRunID = State(initialValue: restoredRun?.id)
        _showsArchived = State(initialValue: restoredRun?.status == .archived)
        _store = ObservedObject(wrappedValue: store ?? .shared)
        _library = ObservedObject(wrappedValue: library ?? .shared)
        _attributionStore = ObservedObject(wrappedValue: attributions ?? .shared)
        let restoredTab = Tab(rawValue: workspace.snapshot.reportTab ?? "")
        _tab = State(initialValue: initialTab ?? restoredTab.flatMap { Tab.reportSections.contains($0) ? $0 : nil } ?? .overview)
        _archiveModel = StateObject(wrappedValue: RecentSessionsViewModel(store: try? RecentSessionArchiveStore(directoryURL: archiveDirectory)))
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
            let storageErrors = [store.storageError, attributionStore.storageError, library.storageError].compactMap { $0 }
            if !storageErrors.isEmpty {
                Section("Records need review") {
                    ForEach(Array(storageErrors.enumerated()), id: \.offset) { _, error in
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(OperatorPalette.danger)
                    }
                }
            }
            Section {
                if Tab.reportSections.contains(tab) {
                    Picker("Section", selection: $tab) { ForEach(Tab.reportSections) { Text($0.rawValue).tag($0) } }
                        .pickerStyle(.menu).frame(minHeight: 44).accessibilityIdentifier("report-tabs")
                }
                if tab != .manage { runPicker }
                if Tab.reportSections.contains(tab) {
                    Text("Scope: \(selected.map { "\($0.context.name.isEmpty ? "Regular Booth" : $0.context.name) · this iPad · one event run" } ?? (store.historyUnreadable ? "Event history unavailable" : "No current event run"))")
                        .font(.callout).foregroundStyle(OperatorPalette.secondaryText).accessibilityIdentifier("report-scope")
                    Toggle("Include archived runs", isOn: $showsArchived)
                    if let run = selected, let eventID = run.context.commercialEventID {
                        NavigationLink("Whole commercial event · all iPads & runs", value: OperatorWorkspaceRoute.eventReport(eventID))
                            .disabled(run.context.serverBinding != OperatorWorkspace.shared.serverBinding)
                        if run.context.serverBinding != OperatorWorkspace.shared.serverBinding {
                            Text("Select this run's saved payments connection in System before opening whole-event sales.").font(.footnote).foregroundStyle(OperatorPalette.secondaryText)
                        }
                    }
                }
            }
            switch tab {
            case .overview: overviewTab
            case .activity: activityTab
            case .printing: printingTab
            case .galleries: galleriesTab
            case .sales: salesTab
            case .history: historyTab
            case .manage: manageTab
            }
            if !message.isEmpty { Section { Text(message).font(.callout) } }
        }
        .navigationTitle(tab == .history ? "Event History" : tab == .manage ? "Saved Events" : "Reports")
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .background(OperatorPalette.canvas)
        .tint(MadeToKeepTheme.ColorPalette.burgundy)
        .task(id: store.revision) {
            // A burst of journal writes (gallery verification, print reconciliation) bumps the
            // revision repeatedly; each bump cancels this task, so the burst costs one reload of
            // every session file, archive and order page instead of one per write.
            if sessions.isEmpty && archives.isEmpty && loading { await loadLocal(); return }
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await loadLocal()
        }
        .onChange(of: tab) { _, value in
            if Tab.reportSections.contains(value) { workspace.saveReportSelection(tab: value.rawValue, runID: selectedRunID) }
        }
        .onChange(of: showsArchived) { _, includesArchived in
            if !includesArchived, selected?.status == .archived { selectedRunID = nil }
        }
        .onChange(of: selectedRunID) { _, _ in
            workspace.saveReportSelection(tab: tab.rawValue, runID: selectedRunID)
            exportURL = nil; financialLoadedAt = nil
            Task { await loadFinancials() }
        }
        .confirmationDialog(dialogTitle, isPresented: Binding(get: { pendingAction != nil }, set: { if !$0 { pendingAction = nil } }), titleVisibility: .visible) {
            Button(pendingAction == "delete" ? "Delete Unused Run" : "Archive Run", role: pendingAction == "delete" ? .destructive : nil) { perform() }
            Button("Cancel", role: .cancel) { }
        } message: { Text(dialogMessage) }
        .confirmationDialog("Delete unused design \(designCandidate?.displayName ?? "")?", isPresented: Binding(get: { designCandidate != nil }, set: { if !$0 { designCandidate = nil } })) {
            Button("Delete Unused Design", role: .destructive) { deleteDesign() }
            Button("Cancel", role: .cancel) { }
        } message: { Text("Applied, commercially linked and historically referenced designs cannot be deleted. Artwork and customer records are never removed.") }
        .sheet(item: $attributionSelection) { selection in
            LegacyAttributionSheet(archives: selection.archives, store: store, attributions: attributionStore, exactSessionIDs: Set(sessions.map(\.sessionID))) { result in
                if let result { message = result; selectedArchiveIDs = [] }
                attributionSelection = nil
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
        if let localError { Section { Label(localError, systemImage: "exclamationmark.triangle").foregroundStyle(OperatorPalette.danger) } }
        if let run = selected {
            if !loading, localError == nil {
                Section("At a glance · this run on this iPad") {
                    OperatorRunMetricsView(statistics: run.isHistorical ? nil : stats).listRowBackground(Color.clear)
                    if let attributed = history?.attributedByRun[run.id], attributed > 0 {
                        LabeledContent("Earlier sessions attributed by operator (not exact)", value: String(attributed))
                    }
                    if run.isHistorical || run.recordedAfterUpgrade == true {
                        Text("Earlier activity is incomplete. Operator-attributed history is separate from exact journal statistics.").font(.footnote).foregroundStyle(OperatorPalette.secondaryText)
                    }
                    Text("Copies are transport-delivered; paper output is not sensor-confirmed. Reprints are reported separately.").font(.footnote).foregroundStyle(OperatorPalette.secondaryText)
                }
                OperatorReportCharts(insights: OperatorRunInsights(runID: run.id, sessions: sessions))
                exceptionsSection
            }
            Section("Event details") {
                DisclosureGroup("Timing, design & payment") {
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
                }
        } else if !loading {
            Section { Text(store.historyUnreadable ? "Event-run history is unavailable. Existing records are retained for recovery in System." : "No event run has started on this iPad. Earlier sessions are listed under History.").foregroundStyle(OperatorPalette.secondaryText) }
        }
        Section {
            Button("Event Setup") { workspace.navigate(to: .sessionSetup) }
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
            }
        }
    }

    @ViewBuilder private var printingTab: some View {
        if loading { Section { ProgressView("Reading print evidence…") } }
        if let localError { Section { Label(localError, systemImage: "exclamationmark.triangle").foregroundStyle(OperatorPalette.danger) } }
        if !loading, localError == nil, selected != nil {
            Section("Original copies · selected run") {
                LabeledContent("Sent to printer", value: String(stats.delivered))
                LabeledContent("Uncertain output", value: String(stats.uncertain))
                LabeledContent("Never started", value: String(stats.notStarted))
                Text("Transport delivery is not sensor-confirmed paper output. Unknown outcomes remain unknown; this screen never resends them.").font(.footnote).foregroundStyle(OperatorPalette.secondaryText)
            }
            Section("Operator reprints") {
                Text("Reprints are separate explicit batches in Print History; they are excluded from original-copy totals above.")
                NavigationLink("Open Print History", value: OperatorWorkspaceRoute.printHistory)
            }
        } else if !loading { Section { Text("Choose a recorded event run to inspect print evidence.") } }
    }
    @ViewBuilder private var galleriesTab: some View {
        if loading { Section { ProgressView("Reading gallery evidence…") } }
        if let localError { Section { Label(localError, systemImage: "exclamationmark.triangle").foregroundStyle(OperatorPalette.danger) } }
        if !loading, localError == nil, selected != nil {
            Section("Gallery delivery · selected run") {
                LabeledContent("Verified online", value: String(stats.galleriesVerified))
                LabeledContent("Awaiting verification", value: String(stats.galleriesAwaitingVerification))
                Text("Verified means this iPad recorded a public delivery confirmation. An archived receipt alone does not prove gallery delivery.").font(.footnote).foregroundStyle(OperatorPalette.secondaryText)
                NavigationLink("Waiting Uploads", value: OperatorWorkspaceRoute.waitingGalleries)
                Button("Find Original Gallery in Sessions") { workspace.select(.sessions) }
            }
        } else if !loading { Section { Text("Choose a recorded event run to inspect gallery delivery.") } }
    }

    // MARK: Activity

    @ViewBuilder private var activityTab: some View {
        if loading { Section { ProgressView("Reading saved sessions…") } }
        if let localError { Section { Label(localError, systemImage: "exclamationmark.triangle").foregroundStyle(OperatorPalette.danger) } }
        if !loading, localError == nil, let selected {
            Section {
                TextField("Search session or receipt format", text: $sessionSearch)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("report-session-search")
                Picker("Receipt format", selection: $sessionFormat) {
                    Text("All formats").tag("all")
                    ForEach(BoothFormat.allCases, id: \.rawValue) { Text($0.displayName).tag($0.rawValue) }
                }
                Picker("Status", selection: $sessionFilter) {
                    Text("All sessions").tag("all")
                    Text("Completed").tag("completed")
                    Text("Waiting gallery").tag("waiting")
                    Text("Print needs review").tag("review")
                }
            }
            Section("Sessions · newest first") {
                let rows = filteredRunSessions
                if rows.isEmpty { Text(runSessions.isEmpty ? "No sessions recorded for this run." : "No sessions match these filters.").foregroundStyle(OperatorPalette.secondaryText) }
                ForEach(rows) { session in
                    if let archive = archives.first(where: { $0.sessionIdentifier == session.sessionID && $0.eventRunID == selected.id }) {
                        NavigationLink {
                            ArchivedSessionDetailView(summary: archive, rootViewModel: archiveModel)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                RecentSessionRow(summary: archive, viewModel: archiveModel, showsOperationalContext: false)
                                journalOutcome(session).font(.caption).foregroundStyle(OperatorPalette.secondaryText)
                            }
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(BoothFormat(rawValue: session.format)?.displayName ?? session.format).font(.headline)
                            Text(session.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.callout)
                            Text(session.sessionID).font(.caption.monospaced()).foregroundStyle(OperatorPalette.secondaryText)
                            journalOutcome(session).font(.caption).foregroundStyle(OperatorPalette.secondaryText)
                            Text("Receipt archive unavailable; reprint is unavailable here.").font(.caption).foregroundStyle(OperatorPalette.secondaryText)
                        }.padding(.vertical, 6)
                    }
                }
            }
            Section {
                Button("Prepare Run CSV") { export() }
                if let exportURL { ShareLink("Share Run CSV", item: exportURL) }
                LabeledContent("Archive reprint requests (separate)", value: String(archives.filter { $0.eventRunID == selected.id }.reduce(0) { $0 + $1.reprintCount }))
                NavigationLink("Earlier & Unassigned Sessions", value: OperatorWorkspaceRoute.eventHistory)
            } footer: { Text("Uncertain output is never retried automatically. Open a receipt for an intentional operator reprint after resolving recovery.") }
        } else if selected == nil, !loading {
            Section {
                Text("No current event run. Select a previous run above, or open earlier sessions.").foregroundStyle(OperatorPalette.secondaryText)
                NavigationLink("Earlier & Unassigned Sessions", value: OperatorWorkspaceRoute.eventHistory)
                NavigationLink("All Recent Receipts & Reprints", value: OperatorWorkspaceRoute.recentSessions)
            }
        }
        exceptionsSection
    }

    private var filteredRunSessions: [EventRunSession] {
        OperatorSessionFilter.apply(runSessions, query: sessionSearch, format: sessionFormat, status: sessionFilter)
    }
    private func journalOutcome(_ session: EventRunSession) -> Text {
        let counts = EventRunStatistics(sessions: [session])
        let gallery = session.galleryVerifiedAt != nil ? "Gallery verified" : session.galleryPreparedAt != nil ? "Gallery waiting" : "Gallery not recorded"
        return Text("\(session.completedAt == nil ? "In progress / incomplete" : "Completed") · \(counts.delivered) copies sent · \(counts.uncertain) uncertain · \(gallery)")
    }

    // MARK: Sales

    @ViewBuilder private var salesTab: some View {
        if let run = selected, let eventID = run.context.commercialEventID {
            Section {
                LabeledContent("Environment", value: run.context.serverBinding?.hasPrefix("live:") == true ? "LIVE" : "TEST · excluded from revenue")
                if financialLoading { ProgressView("Checking every order page…") }
                if let financialError { Label(financialError, systemImage: "exclamationmark.triangle").foregroundStyle(OperatorPalette.danger) }
                if let financials {
                    money("QR Ph verified — LIVE", financials.verifiedLive)
                    money("QR Ph verified — TEST (not revenue)", financials.verifiedTest)
                    money("Cash confirmed by attendant", financials.operatorCash)
                    money("Cash declared by guest (unverified)", financials.declaredCash)
                    LabeledContent("Unresolved QR payments", value: String(financials.unresolved))
                    LabeledContent("Held / replaced orders excluded", value: String(financials.review))
                }
                if offlineCashLoaded { money("Offline cash waiting to sync (unverified)", offlineCash.reduce(0) { $0 + $1.totalCentavos }) }
                else if let offlineCashError { Label(offlineCashError, systemImage: "exclamationmark.triangle").foregroundStyle(OperatorPalette.warning) }
                else if !financialLoading { Text("Offline cash totals have not been loaded.").font(.footnote) }
                if unassignedOfflineCount > 0 { Text("\(unassignedOfflineCount) legacy cash record(s) lack an environment and are excluded from the amount above.").foregroundStyle(OperatorPalette.warning) }
                if let financialLoadedAt { Text("Last refreshed \(financialLoadedAt.formatted(date: .omitted, time: .shortened)).").font(.footnote).foregroundStyle(OperatorPalette.secondaryText) }
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
                    .disabled(run.context.serverBinding != OperatorWorkspace.shared.serverBinding)
            } header: { Text("Whole paid event") } footer: {
                Text("The paid event report includes physical cash counts, every order and the complete financial CSV.")
            }
            if !orders.isEmpty {
                Section("Orders in this run") {
                    ForEach(orders) { order in
                        VStack(alignment: .leading) {
                            Text("\(PHPPriceFormatter.string(centavos: order.totalCentavos)) · \(order.copies)× \(order.boothFormat)")
                            Text("\(order.category) · \(order.state)").font(.caption).foregroundStyle(OperatorPalette.secondaryText)
                        }
                    }
                }
            }
        } else if selected != nil {
            Section { Text("This run didn't collect payments (prepaid or free). Its sessions and prints are under Sessions.").foregroundStyle(OperatorPalette.secondaryText) }
        }
        if selected == nil { Section { Text("Select an event run above, or open an authoritative whole-event report below.").foregroundStyle(OperatorPalette.secondaryText) } }
        Section {
            NavigationLink("Whole Commercial Event · All iPads & Runs") { PaymentsOperatorView(salesOnly: true) }
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
                            .font(.caption).foregroundStyle(OperatorPalette.secondaryText)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }
            }
            if pickerRuns.isEmpty { Text("No event runs yet.").foregroundStyle(OperatorPalette.secondaryText) }
        } header: { Text("Event runs") } footer: { Text("Tap a run to see its activity. Each new occurrence has its own run and statistics.") }
        Section {
            if let history {
                LabeledContent("Earlier sessions without a run", value: String(history.unassignedCount))
                if history.unassignedPrintCopies > 0 { LabeledContent("Print copies without a run", value: String(history.unassignedPrintCopies)) }
                if history.corruptArchives > 0 { Label("\(history.corruptArchives) archived session(s) could not be read and are excluded.", systemImage: "exclamationmark.triangle").foregroundStyle(OperatorPalette.warning) }
                ForEach(history.unassigned) { group in
                    DisclosureGroup {
                        ForEach(group.archives) { archive in
                            Button { toggle(archive) } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 12) {
                                    Image(systemName: selectedArchiveIDs.contains(archive.archiveID) ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(MadeToKeepTheme.ColorPalette.burgundy)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("\(archive.createdAt.formatted(date: .omitted, time: .shortened)) · \(archive.format.displayName)")
                                            .foregroundStyle(MadeToKeepTheme.ColorPalette.ink)
                                        Text(archive.eventName.flatMap { $0.isEmpty ? nil : "Receipt: \($0)" } ?? "No receipt event name").font(.caption).foregroundStyle(OperatorPalette.secondaryText)
                                    }
                                }
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            }
                            .disabled(store.historyUnreadable)
                            .accessibilityAddTraits(selectedArchiveIDs.contains(archive.archiveID) ? .isSelected : [])
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(group.day.formatted(date: .complete, time: .omitted)).font(.headline).foregroundStyle(MadeToKeepTheme.ColorPalette.ink)
                            Text("\(group.archives.count) sessions · " + group.byFormat.keys.sorted().map { "\(group.byFormat[$0] ?? 0) \(BoothFormat(rawValue: $0)?.displayName ?? $0)" }.joined(separator: ", "))
                                .font(.caption).foregroundStyle(OperatorPalette.secondaryText)
                            if !group.names.isEmpty { Text("Receipt names: \(group.names.joined(separator: ", "))").font(.caption2).foregroundStyle(OperatorPalette.secondaryText) }
                        }
                        .frame(minHeight: 44, alignment: .leading)
                    }
                }
                if !history.unassigned.isEmpty {
                    Button("Review & Attribute Selected (\(selectedArchiveIDs.count))…") {
                        let chosen = history.unassigned.flatMap(\.archives).filter { selectedArchiveIDs.contains($0.archiveID) }
                        attributionSelection = AttributionSelection(archives: chosen)
                    }
                    .disabled(selectedArchiveIDs.isEmpty || store.historyUnreadable)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("review-attribution")
                    if !selectedArchiveIDs.isEmpty { Button("Clear Selection") { selectedArchiveIDs = [] }.frame(minHeight: 44) }
                }
            } else if !loading, localError == nil { Text("Earlier sessions have not been checked.").foregroundStyle(OperatorPalette.secondaryText) }
            if let error = attributionStore.storageError { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(OperatorPalette.warning) }
        } header: { Text("Unassigned earlier activity") } footer: {
            Text(HistoricalActivityReport.unassignedReason + " Open a day and select the individual sessions you know belong to one event, then review and attribute them. Two events on the same day stay separate. Attributions are permanent, audited and shown separately. Sales are never attributed.")
        }
        Section {
            NavigationLink("Paid Event History & Archive") { PaymentsOperatorView(salesOnly: true, allowsEventMaintenance: true) }
        }
    }

    // MARK: Manage

    @ViewBuilder private var manageTab: some View {
        Section { Toggle("Include archived designs and runs", isOn: $showsArchived) }
        Section {
            if let current = store.current { LabeledContent("Current run", value: label(current)) }
            NavigationLink(value: OperatorWorkspaceRoute.sessionSetup) {
                Label("Start a New Occurrence in Event Setup", systemImage: "calendar.badge.plus").frame(minHeight: 44)
            }
            .accessibilityIdentifier("manage-new-occurrence")
            if let selected, selected.status == .completed || selected.status == .draft {
                Button("Archive Selected Run…") { pendingAction = "archive" }.disabled(blocked != nil).frame(minHeight: 44)
            }
            if let selected, store.unusedRunDeletionReason(id: selected.id, archives: archives, inspectionComplete: localError == nil && !loading) == nil {
                Button("Delete Unused Local Run…", role: .destructive) { pendingAction = "delete" }.disabled(blocked != nil).frame(minHeight: 44)
            }
            Picker("Selected run", selection: $selectedRunID) {
                Text("Current run").tag(String?.none)
                ForEach(pickerRuns) { Text(label($0)).tag(Optional($0.id)) }
            }
            if let blocked { Text(blocked).font(.footnote).foregroundStyle(OperatorPalette.warning) }
            if let error = store.storageError { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(OperatorPalette.danger) }
        } header: { Text("Event runs") } footer: {
            Text("Reports never change the running event. For fresh statistics, end the event from Current Event, then use Start New Occurrence in Event Setup: it reviews the design and payment setup and keeps the ended run's history. Archiving hides an ended run from everyday lists; its sessions, receipts, galleries, entitlements and reports stay saved.")
        }
        Section {
            ForEach(library.library.events.filter { showsArchived || $0.archivedAt == nil }) { design in
                HStack {
                    VStack(alignment: .leading) {
                        Text(design.displayName)
                        Text(design.archivedAt == nil ? "Saved design" : "Archived design — history retained").font(.caption).foregroundStyle(OperatorPalette.secondaryText)
                    }
                    Spacer()
                    Menu("Manage") {
                        if design.archivedAt == nil { Button("Archive Design") { archiveDesign(design) } }
                        else { Button("Restore Design") { restoreDesign(design) } }
                        if library.deletionIneligibility(id: design.id, runs: store.runs, archives: archives,
                            historyAvailable: localError == nil && !loading && store.storageError == nil
                                && OperatorWorkspace.shared.persistenceError == nil
                                && OperatorWorkspace.shared.designDraft(id: design.id) == nil
                                && OperatorWorkspace.shared.snapshot.sessionSetup?.designID != design.id
                                && CommercialEventCreationStore.shared.storageError == nil
                                && !CommercialEventCreationStore.shared.intents.contains(where: { $0.isOpen && $0.designID == design.id })) == nil {
                            Button("Delete Unused Design…", role: .destructive) { designCandidate = design }
                        }
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
            archiveModel.refresh()
            history = HistoricalActivityReport(archives: saved, sessions: loaded, runs: store.runs, attributions: attributionStore.attributions, printEntries: entries)
            await loadFinancials()
        } catch { localError = "Operational history unavailable: \(error.localizedDescription)"; history = nil; loading = false }
    }

    private func loadFinancials() async {
        let request = UUID(); financialRequest = request
        financials = nil; financialError = nil; financialLoadedAt = nil; orders = []; offlineCash = []; financialLoading = false; unmatchedCommercialOrders = nil
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

    private var dialogTitle: String { "\(pendingAction == "delete" ? "Delete unused" : "Archive") run \(selected?.context.name ?? "")?" }
    private var dialogMessage: String {
        if pendingAction == "delete" { return "Only this empty local run is removed. Deletion is refused if any commercial, session, receipt or later-occurrence dependency exists or inspection is incomplete." }
        return "The run is hidden from everyday lists. Its sessions, receipts, galleries, payments and reports are kept and stay available under History."
    }

    private func perform() {
        defer { pendingAction = nil }
        do {
            if pendingAction == "delete", let run = selected {
                try store.deleteUnusedRun(id: run.id, archives: archives, inspectionComplete: localError == nil && !loading)
                selectedRunID = nil; message = "Unused local run removed. Other history and records are kept."
            }
            if pendingAction == "archive", let run = selected {
                try store.transition(id: run.id, to: .archived); selectedRunID = nil
                message = "Run archived. Its history and reports were retained."
            }
        } catch { message = error.localizedDescription }
    }

    private func toggle(_ archive: RecentSessionArchiveSummary) {
        if selectedArchiveIDs.contains(archive.archiveID) { selectedArchiveIDs.remove(archive.archiveID) } else { selectedArchiveIDs.insert(archive.archiveID) }
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
            guard localError == nil, !loading, OperatorWorkspace.shared.persistenceError == nil,
                  OperatorWorkspace.shared.designDraft(id: designCandidate.id) == nil,
                  OperatorWorkspace.shared.snapshot.sessionSetup?.designID != designCandidate.id,
                  CommercialEventCreationStore.shared.storageError == nil,
                  !CommercialEventCreationStore.shared.intents.contains(where: { $0.isOpen && $0.designID == designCandidate.id }) else { throw SetupFailure("Load event history and finish saved drafts or pending event creation before deleting a design.") }
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

private struct AttributionSelection: Identifiable {
    let id = UUID()
    let archives: [RecentSessionArchiveSummary]
}

/// Explicit, audited attribution of individually selected legacy sessions to one occurrence.
/// The exact selection is reviewed, a reason is required, the batch is validated in full before
/// anything is written, and the result lists exactly what was saved.
private struct LegacyAttributionSheet: View {
    let archives: [RecentSessionArchiveSummary]
    @ObservedObject var store: EventRunStore
    @ObservedObject var attributions: LegacyAttributionStore
    let exactSessionIDs: Set<String>
    let onDone: (String?) -> Void
    @State private var targetRunID: String?
    @State private var createsRecord = true
    @State private var name = ""
    @State private var note = ""
    @State private var error: String?
    @State private var saved: (run: EventRunRecord, entries: [LegacySessionAttribution])?

    private var sorted: [RecentSessionArchiveSummary] { archives.sorted { $0.createdAt < $1.createdAt } }
    private var names: [String] { Array(Set(archives.compactMap(\.eventName).filter { !$0.isEmpty })).sorted() }

    var body: some View {
        NavigationStack {
            Form {
                if let saved {
                    Section("Saved") {
                        Label("\(saved.entries.count) session(s) attributed to \(saved.run.context.name)", systemImage: "checkmark.seal")
                        ForEach(sorted) { archive in
                            Text("\(archive.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(archive.format.displayName)").font(.callout)
                        }
                        LabeledContent("Reason", value: saved.entries.first?.note ?? "")
                        LabeledContent("Confirmation", value: String((saved.entries.first?.batchID ?? "").prefix(8)))
                        Text("Shown as operator-attributed, never as exact run statistics. Receipts, galleries and payment records were not changed, and no sales were attributed.").font(.footnote)
                    }
                } else {
                    Section("Selected sessions (\(archives.count))") {
                        ForEach(sorted) { archive in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(archive.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(archive.format.displayName)")
                                Text(archive.eventName.flatMap { $0.isEmpty ? nil : "Receipt: \($0)" } ?? "No receipt event name").font(.caption).foregroundStyle(OperatorPalette.secondaryText)
                            }
                        }
                        Text(HistoricalActivityReport.unassignedReason).font(.footnote).foregroundStyle(OperatorPalette.secondaryText)
                    }
                    Section("Attribute to") {
                        Toggle("Create an earlier-event record", isOn: $createsRecord)
                        if createsRecord {
                            TextField("Event name", text: $name).textInputAutocapitalization(.words)
                        } else {
                            Picker("Existing run", selection: $targetRunID) {
                                Text("Choose…").tag(String?.none)
                                ForEach(store.runs.reversed()) { Text("\($0.context.name) · \($0.createdAt.formatted(date: .abbreviated, time: .shortened))\($0.isHistorical ? " · earlier event" : "")").tag(Optional($0.id)) }
                            }
                        }
                        TextField("Reason (required)", text: $note)
                    }
                    Section {
                        Button("Attribute \(archives.count) Session\(archives.count == 1 ? "" : "s")") { attribute() }
                            .disabled(note.trimmingCharacters(in: .whitespaces).isEmpty || (createsRecord ? name.trimmingCharacters(in: .whitespaces).isEmpty : targetRunID == nil))
                            .accessibilityIdentifier("confirm-attribution")
                        if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(OperatorPalette.danger) }
                    } footer: {
                        Text("All selected sessions are saved together or not at all. Permanent and audited; counts appear separately as operator-attributed. Receipts, galleries and payment records are not changed, and no sales are attributed.")
                    }
                }
            }
            .navigationTitle(saved == nil ? "Review Earlier Sessions" : "Attribution Saved")
            .toolbar {
                ToolbarItem(placement: saved == nil ? .cancellationAction : .confirmationAction) {
                    Button(saved == nil ? "Cancel" : "Done") {
                        onDone(saved.map { "\($0.entries.count) earlier session(s) attributed to \($0.run.context.name). They are reported separately from exact statistics." })
                    }
                }
            }
            .onAppear { if name.isEmpty { name = names.first ?? "" } }
        }
    }

    private func attribute() {
        error = nil
        do {
            let run: EventRunRecord
            if createsRecord {
                let first = sorted.first?.createdAt ?? Date(), last = sorted.last?.createdAt ?? Date()
                // Validate the whole batch against the record it would create, before creating it.
                let provisional = EventRunRecord(id: "provisional", context: EventRunContext(designID: nil, commercialEventID: nil, serverBinding: nil, name: name),
                                                 createdAt: first, status: .completed, endedAt: last, historical: true)
                try attributions.validate(archives, to: provisional, knownRuns: [provisional], note: note, exact: exactSessionIDs)
                run = try store.createHistoricalRun(name: name, designID: archives.compactMap(\.eventDesignID).first, startedAt: first, endedAt: last)
            } else {
                guard let id = targetRunID, let existing = store.runs.first(where: { $0.id == id }) else { return }
                run = existing
            }
            let entries = try attributions.attribute(archives, to: run, knownRuns: store.runs, note: note, exact: exactSessionIDs)
            saved = (run, entries)
        } catch { self.error = error.localizedDescription }
    }
}
