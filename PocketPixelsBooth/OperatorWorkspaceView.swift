import SwiftUI

struct OperatorActionFeedback: Identifiable, Equatable {
    let id = UUID()
    let message: String
    var isError = false
}

/// Success clears after six seconds; actionable failures stay until explicitly dismissed.
struct OperatorFeedbackBanner: View {
    let feedback: OperatorActionFeedback
    let dismiss: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: feedback.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(feedback.isError ? OperatorPalette.danger : OperatorPalette.ink)
            Text(feedback.message).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
            Button(action: dismiss) { Image(systemName: "xmark").frame(width: 44, height: 44) }
                .accessibilityLabel("Dismiss message").buttonStyle(.plain)
        }
        .padding(.leading, 16).padding(.vertical, 6)
        .background(OperatorPalette.surface, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .contain).accessibilityAddTraits(.updatesFrequently)
        .task(id: feedback.id) {
            guard !feedback.isError else { return }
            do { try await Task.sleep(for: .seconds(6)); dismiss() } catch { }
        }
    }
}

/// One authenticated workspace and one detail stack. Resizing never replaces the stack or drafts.
struct OperatorWorkspaceView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var operations = EventOperationalState.shared
    @ObservedObject private var printer = PrinterCoordinator.shared
    @ObservedObject private var workspace: OperatorWorkspace
    @StateObject private var sessions = RecentSessionsViewModel()
    @StateObject private var lifecycle: EventLifecycleCoordinator
    private let loadsRemote: Bool

    init(workspace: OperatorWorkspace? = nil, lifecycle: EventLifecycleCoordinator? = nil, loadsRemote: Bool = true) {
        _workspace = ObservedObject(wrappedValue: workspace ?? .shared)
        _lifecycle = StateObject(wrappedValue: lifecycle ?? EventLifecycleCoordinator())
        self.loadsRemote = loadsRemote
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let error = workspace.persistenceError {
                Text(error).font(.footnote).foregroundStyle(OperatorPalette.danger).padding(.horizontal)
            }
            GeometryReader { geometry in
                let sidebar = OperatorWorkspaceLayout.usesSidebar(width: geometry.size.width, height: geometry.size.height)
                HStack(spacing: 0) {
                    if sidebar {
                        VStack(alignment: .leading, spacing: 24) {
                            Text("OPERATOR\nWORKSPACE").font(.caption.weight(.semibold)).tracking(1.8)
                                .foregroundStyle(OperatorPalette.ink.opacity(0.6)).padding(.horizontal, 16)
                            navigation(vertical: true)
                            Spacer()
                            Text("Little moments,\nmade to keep.")
                                .font(.system(.callout, design: .serif)).foregroundStyle(OperatorPalette.secondaryText).padding(16)
                        }
                        .padding(16).padding(.top, 12).frame(width: 176)
                        .background(OperatorPalette.surface)
                        Divider()
                    }
                    VStack(spacing: 0) {
                        NavigationStack(path: $workspace.path) {
                            primaryContent
                                .toolbar(.hidden, for: .navigationBar)
                                .navigationDestination(for: OperatorWorkspaceRoute.self) { route in
                                    Group {
                                        if route == .regularBooth || route == .recentSessions {
                                            Color.clear.task { workspace.navigate(to: route) }
                                        } else if route == .regularFooter { RegularBoothSettingsView(workspace: workspace, footerOnly: true) }
                                        else { route.destination }
                                    }.toolbar(.visible, for: .navigationBar)
                                }
                        }
                        if !sidebar && workspace.path.isEmpty && !(workspace.primaryDestination == .sessions && sessions.selectedArchiveID != nil) {
                            navigation(vertical: false)
                                .padding(.horizontal, 8).padding(.vertical, 6)
                                .background(OperatorPalette.surface)
                                .overlay(alignment: .top) { Divider() }
                        }
                    }
                }
            }
        }
        .background(OperatorPalette.canvas)
        .tint(OperatorPalette.ink)
        .environment(\.colorScheme, .light)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text(workspace.currentSection).font(.headline).lineLimit(2)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            Button { workspace.navigate(to: .recovery) } label: {
                Image(systemName: "lifepreserver").frame(width: 44, height: 44)
            }.accessibilityLabel("Help & Recovery").accessibilityIdentifier("operator-help")
            Button { workspace.navigate(to: .equipment) } label: {
                Image(systemName: "gearshape").frame(width: 44, height: 44)
            }.accessibilityLabel("System & Settings").accessibilityIdentifier("operator-system")
            returnButton
        }
        .padding(.horizontal, 16).padding(.vertical, 4).background(OperatorPalette.surface)
    }

    private var returnButton: some View {
        Button("Return to Booth") {
            workspace.finish(keepingDrafts: true)
            dismiss()
        }
        .buttonStyle(.borderedProminent).frame(minHeight: 48)
        .disabled(operations.isPreflightRunning || printer.isWorking)
        .accessibilityIdentifier("operator-return-to-booth")
    }

    @ViewBuilder private var primaryContent: some View {
        switch workspace.primaryDestination {
        case .home: OperatorDashboardView(lifecycle: lifecycle, workspace: workspace, loadsRemote: loadsRemote)
        case .booth: RegularBoothSettingsView(workspace: workspace)
        case .sessions: RecentSessionsView(viewModel: sessions)
        case .events: OperatorEventsView(workspace: workspace, runs: lifecycle.runs, lifecycle: lifecycle)
        case .reports: EventRunReportingView(store: lifecycle.runs, loadsRemote: loadsRemote, workspace: workspace)
        case .system: OperatorEquipmentView()
        }
    }

    private func navigation(vertical: Bool) -> some View {
        let layout = vertical ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
        return layout {
            ForEach(OperatorPrimaryDestination.allCases) { destination in
                Button { workspace.select(destination) } label: {
                    let selected = workspace.primaryDestination == destination
                    let labelLayout = vertical ? AnyLayout(HStackLayout(spacing: 12)) : AnyLayout(VStackLayout(spacing: 4))
                    labelLayout {
                        Image(systemName: destination.systemImage).frame(width: 22)
                        Text(destination.title).font((vertical ? Font.callout : Font.caption).weight(selected ? .semibold : .medium))
                        if vertical { Spacer(minLength: 0) }
                    }
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .padding(.horizontal, vertical ? 14 : 6)
                    .foregroundStyle(selected ? OperatorPalette.ink : OperatorPalette.ink)
                    .background(selected ? OperatorPalette.selected : .clear, in: RoundedRectangle(cornerRadius: 10))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("operator-nav-\(destination.rawValue)")
                .accessibilityLabel(destination.title)
                .accessibilityAddTraits(workspace.primaryDestination == destination ? .isSelected : [])
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Operator navigation")
    }
}

nonisolated enum OperatorWorkspaceLayout {
    static func usesSidebar(width: CGFloat, height: CGFloat) -> Bool { width >= 1_000 && width > height }
}

struct OperatorEventsView: View {
    @ObservedObject var workspace: OperatorWorkspace
    @ObservedObject var runs: EventRunStore
    @ObservedObject private var library: EventDesignLibraryStore
    @State private var showsArchived = false
    @State private var showsRemoved = false
    @State private var deletionDesignID: String?
    @State private var deletionRunID: String?
    @State private var feedback: OperatorActionFeedback?
    @State private var managementError: String?
    @State private var confirmsRegular = false
    @StateObject private var lifecycle: EventLifecycleCoordinator
    private let creationPending: @MainActor (String) -> Bool
    private let sessionArchives: () throws -> RecentSessionArchiveStore

    init(workspace: OperatorWorkspace, runs: EventRunStore, library: EventDesignLibraryStore = .shared,
         lifecycle: EventLifecycleCoordinator? = nil,
         sessionArchives: @escaping () throws -> RecentSessionArchiveStore = { try RecentSessionArchiveStore() },
         creationPending: @escaping @MainActor (String) -> Bool = { id in
             CommercialEventCreationStore.shared.intents.contains { $0.isOpen && $0.designID == id }
         }) {
        self.workspace = workspace; self.runs = runs; _library = ObservedObject(wrappedValue: library)
        _lifecycle = StateObject(wrappedValue: lifecycle ?? EventLifecycleCoordinator(runs: runs))
        self.creationPending = creationPending
        self.sessionArchives = sessionArchives
    }
    private func manage(_ success: String, _ action: () throws -> Void) {
        do { try action(); feedback = .init(message: success) }
        catch { managementError = error.localizedDescription }
    }
    private func needsEnd(_ id: String?) -> Bool {
        guard let id else { return false }
        return library.library.appliedEventID == id || runs.runs.contains { $0.context.designID == id && [.active, .paused].contains($0.status) }
    }
    private func deleteDesign(_ id: String) {
        Task {
            if needsEnd(id) {
                guard runs.current == nil || runs.current?.context.designID == id else {
                    managementError = "The current run belongs to another event. Review Current Event before removing this design."; return
                }
                let ended = runs.current != nil ? await lifecycle.end(scope: .thisBooth) : await lifecycle.returnToRegular()
                guard ended else { managementError = lifecycle.message; return }
            }
            manage("Event removed. History, customer media and financial records are kept. Restore it under Show Removed Events.") {
                try library.removeEvent(id: id, runs: runs.runs, historyAvailable: !runs.historyUnreadable,
                    pendingCreation: creationPending(id))
            }
        }
    }
    private func deleteRun(_ id: String) {
        Task {
            if let run = runs.runs.first(where: { $0.id == id }), [.active, .paused].contains(run.status) {
                guard runs.currentRunID == id else { managementError = "This run needs review in Current Event before removal."; return }
                guard await lifecycle.end(scope: .thisBooth) else { managementError = lifecycle.message; return }
            }
            manage("Run removed. Its original sessions, reports and payment associations are kept.") { try runs.removeRun(id: id) }
        }
    }

    private func performRegularTransition() {
        Task {
            let succeeded: Bool
            if runs.current != nil { succeeded = await lifecycle.end(scope: .thisBooth) }
            else { succeeded = await lifecycle.returnToRegular() }
            feedback = .init(message: lifecycle.message, isError: !succeeded)
        }
    }

    private func designRemovalTitle(_ design: SavedEventDesign) -> String {
        needsEnd(design.id) ? "End Event then Remove" : "Remove Event"
    }

    var body: some View {
        List {
            Section("Current Event") {
                Button { workspace.select(.home) } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(runs.historyUnreadable ? "Event status unavailable" : (runs.operational?.context.name ?? "Regular Booth")).font(.headline)
                            Text("Status and safe event controls on Home").font(.callout).foregroundStyle(OperatorPalette.secondaryText)
                        }
                    } icon: { Image(systemName: "house") }
                    .frame(minHeight: 52)
                }
                if runs.operational?.status == .active {
                    NavigationLink(value: OperatorWorkspaceRoute.liveEvent) { Label("Edit Live Event", systemImage: "square.and.pencil") }
                }
                NavigationLink(value: OperatorWorkspaceRoute.sessionSetup) { Label("Review Current Setup", systemImage: "checklist") }
                if library.library.appliedEventID != nil || runs.current != nil {
                    Button(runs.operational == nil ? "Switch to Regular Booth" : "End Event on This iPad") { confirmsRegular = true }
                        .buttonStyle(.bordered).frame(minHeight: 44)
                }
            }
            Section {
                NavigationLink(value: OperatorWorkspaceRoute.newEvent) { Label("Start Event", systemImage: "plus.circle") }
                NavigationLink(value: OperatorWorkspaceRoute.savedDrafts) {
                    Label("Saved Drafts · \(SavedDraftCatalog.entries(workspace: workspace, library: library.library).count)", systemImage: "doc.text")
                }
            } footer: { Text("Setup is staged. Guests keep their current configuration until an explicit Review & Start.") }
            Section("Saved Event Designs") {
                Toggle("Show Archived Events", isOn: $showsArchived)
                ForEach(library.library.events.filter { $0.removedAt == nil && (showsArchived || $0.archivedAt == nil) }.sorted { $0.updatedAt > $1.updatedAt }) { event in
                    HStack {
                        NavigationLink(value: OperatorWorkspaceRoute.savedEvent(event.id)) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(event.displayName).font(.headline)
                                Text(event.archivedAt != nil ? "Archived local design" : (event.venue.isEmpty ? "Local saved design" : event.venue))
                                    .font(.callout).foregroundStyle(OperatorPalette.secondaryText)
                            }.padding(.vertical, 4)
                        }
                        Menu {
                            NavigationLink("Edit", value: OperatorWorkspaceRoute.savedEvent(event.id))
                            NavigationLink("View History", value: OperatorWorkspaceRoute.eventHistory)
                            if event.archivedAt == nil {
                                Button("Archive") { manage("Design archived. History is kept.") { try library.archiveDesign(id: event.id) } }
                            } else {
                                Button("Restore") { manage("Design restored to the reusable library.") { try library.restoreDesign(id: event.id) } }
                            }
                            Button(designRemovalTitle(event), role: .destructive) { deletionDesignID = event.id }
                        } label: { Label("Manage", systemImage: "ellipsis.circle").frame(minWidth: 44, minHeight: 44) }
                        .buttonStyle(.borderless).accessibilityIdentifier("manage-design-\(event.id)").accessibilityLabel("Manage \(event.displayName)")
                    }.accessibilityIdentifier("saved-design-\(event.id)")
                }
                NavigationLink("Event History & Earlier Sessions", value: OperatorWorkspaceRoute.eventHistory)
                NavigationLink("Manage Saved Events & Archived Designs", value: OperatorWorkspaceRoute.eventLibrary)
            }
            Section("Local Event Runs") {
                ForEach(runs.visibleRuns(library: library.library, includingArchived: showsArchived).sorted { $0.createdAt > $1.createdAt }) { run in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(run.context.name).font(.headline)
                            Text("\(run.status.rawValue.capitalized) · \(run.createdAt.formatted(date: .abbreviated, time: .omitted))").font(.caption)
                        }
                        Spacer()
                        Menu {
                            NavigationLink("View History", value: OperatorWorkspaceRoute.eventHistory)
                            if run.status == .archived {
                                Button("Restore Run") { manage("Run restored to history.") { try runs.restoreArchivedRun(id: run.id) } }
                            } else { Button("Archive Run") { manage("Run archived. Reports are kept.") { try runs.transition(id: run.id, to: .archived) } } }
                            Button([.active, .paused].contains(run.status) ? "End Event then Remove Run" : "Remove Run", role: .destructive) { deletionRunID = run.id }
                        } label: { Label("Manage", systemImage: "ellipsis.circle").frame(minWidth: 44, minHeight: 44) }
                        .buttonStyle(.borderless)
                    }
                }
                Text("Saved designs are reusable configurations. Local runs are historical occurrences. Removing an event hides its linked runs and keeps reports, receipts and financial records.").font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                Button(showsRemoved ? "Hide Removed Events" : "Show Removed Events") { showsRemoved.toggle() }
                if showsRemoved {
                    ForEach(library.library.events.filter { $0.removedAt != nil }) { event in
                        LabeledContent(event.displayName) {
                            Button("Restore Removed Event") {
                                manage("Event restored. It is not accepting guests.") { try library.restoreRemovedEvent(id: event.id) }
                            }.accessibilityIdentifier("restore-removed-event-" + event.id)
                        }
                    }
                    ForEach(runs.runs.filter { $0.removedAt != nil && !library.library.removedEventIDs.contains($0.context.designID ?? "") }) { run in
                        LabeledContent(run.context.name) {
                            Button("Restore Removed Run") { manage("Run restored to history.") { try runs.restoreRemovedRun(id: run.id) } }
                        }
                    }
                }
            }
            Section("Guest Experience") {
                NavigationLink(value: OperatorWorkspaceRoute.branding) { Label("Event Customization", systemImage: "paintpalette") }
                NavigationLink(value: OperatorWorkspaceRoute.samplePrints) { Label("Preview & Sample Prints", systemImage: "printer.dotmatrix") }
                NavigationLink(value: OperatorWorkspaceRoute.regularBooth) { Label("Regular Booth Configuration", systemImage: "camera") }
            }
            if let error = runs.storageError { Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(OperatorPalette.danger) } }
            if let error = library.storageError { Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(OperatorPalette.danger) } }
        }
        .safeAreaInset(edge: .top) {
            if let feedback { OperatorFeedbackBanner(feedback: feedback) { self.feedback = nil }.padding(.horizontal).padding(.top, 8) }
        }
        .alert("Event action could not finish", isPresented: Binding(get: { managementError != nil }, set: { if !$0 { managementError = nil } })) {
            if library.library.appliedEventID != nil || runs.operational != nil {
                Button(runs.operational == nil ? "Switch to Regular Booth" : "End Event on This iPad", role: .destructive) { performRegularTransition() }
            }
            Button("OK", role: .cancel) { managementError = nil }
        } message: { Text(managementError ?? "") }
        .confirmationDialog("Remove \(library.design(id: deletionDesignID)?.displayName ?? "saved design")?", isPresented: Binding(get: { deletionDesignID != nil }, set: { if !$0 { deletionDesignID = nil } }), titleVisibility: .visible) {
            Button(needsEnd(deletionDesignID) ? "End Event then Remove" : "Remove Event", role: .destructive) { if let id = deletionDesignID { deleteDesign(id) }; deletionDesignID = nil }
            Button("Cancel", role: .cancel) { deletionDesignID = nil }
        } message: { Text("Hides this event and its linked historical runs. Running events end on this iPad first. Customer media, prints and financial records are kept. Restore it under Show Removed Events.") }
        .confirmationDialog(runs.operational == nil ? "Switch to Regular Booth?" : "End Event on This iPad?", isPresented: $confirmsRegular, titleVisibility: .visible) {
            Button("Switch to Regular Booth", role: .destructive) {
                performRegularTransition()
            }
            Button("Cancel", role: .cancel) { }
        } message: { Text("Guest admission and unfinished receipts are checked again. This iPad returns to Regular Booth; other booths, event history and payments are kept. Remove the saved design afterward.") }
        .confirmationDialog("Remove this event run?", isPresented: Binding(get: { deletionRunID != nil }, set: { if !$0 { deletionRunID = nil } }), titleVisibility: .visible) {
            Button("Remove Run", role: .destructive) { if let id = deletionRunID { deleteRun(id) }; deletionRunID = nil }
            Button("Cancel", role: .cancel) { deletionRunID = nil }
        } message: { Text("Hides this run from normal lists. A running event ends on this iPad first. Sessions, receipts, payment records and reports remain associated with its original ID. You can restore the run later.") }
        .navigationTitle("Events").navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden).background(OperatorPalette.canvas)
        .environment(\.defaultMinListRowHeight, 52)
    }
}

/// Opens a reusable setup through the existing staging coordinator, without activation.
struct OperatorSavedEventSetupView: View {
    let designID: String
    @StateObject private var setup = SessionSetupCoordinator()
    var body: some View {
        SessionSetupView(coordinator: setup)
            .task(id: designID) {
                // setEventMode may pick a default design; chooseDesign then selects the requested one.
                await setup.setEventMode(true)
                await setup.chooseDesign(designID)
            }
    }
}
