import SwiftUI

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
        .tint(OperatorPalette.accent)
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
        case .events: OperatorEventsView(workspace: workspace, runs: lifecycle.runs)
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
                    .foregroundStyle(selected ? OperatorPalette.accent : OperatorPalette.ink)
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
    @State private var deletionDesignID: String?
    @State private var deletionRunID: String?
    @State private var managementMessage = ""

    init(workspace: OperatorWorkspace, runs: EventRunStore, library: EventDesignLibraryStore = .shared) {
        self.workspace = workspace; self.runs = runs; _library = ObservedObject(wrappedValue: library)
    }
    private func manage(_ action: () throws -> Void) {
        do { try action(); managementMessage = "Saved." }
        catch { managementMessage = error.localizedDescription }
    }
    private func deleteDesign(_ id: String) {
        manage {
            let archives = try RecentSessionArchiveStore().summaries(includePayloadSize: false)
            try library.deleteUnusedDesign(id: id, runs: runs.runs, archives: archives, historyAvailable: !runs.historyUnreadable, deletedSessions: try RecentSessionArchiveStore().deletedSessionEvidence())
        }
    }
    private func deleteRun(_ id: String) {
        manage {
            let archives = try RecentSessionArchiveStore().summaries(includePayloadSize: false)
            try runs.deleteUnusedRun(id: id, archives: archives, inspectionComplete: !runs.historyUnreadable)
        }
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
                NavigationLink(value: OperatorWorkspaceRoute.sessionSetup) { Label("Review Current Setup", systemImage: "checklist") }
            }
            Section {
                NavigationLink(value: OperatorWorkspaceRoute.newEvent) { Label("Start Event", systemImage: "plus.circle") }
                NavigationLink(value: OperatorWorkspaceRoute.savedDrafts) {
                    Label("Saved Drafts · \(SavedDraftCatalog.entries(workspace: workspace, library: library.library).count)", systemImage: "doc.text")
                }
            } footer: { Text("Setup is staged. Guests keep their current configuration until an explicit Review & Start.") }
            Section("Saved Events") {
                Toggle("Show Archived Events", isOn: $showsArchived)
                ForEach(library.library.events.filter { showsArchived || $0.archivedAt == nil }.sorted { $0.updatedAt > $1.updatedAt }) { event in
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
                                Button("Archive") { manage { try library.archiveDesign(id: event.id) } }
                            } else {
                                Button("Restore") { manage { try library.restoreDesign(id: event.id) } }
                            }
                            Button("Delete Permanently", role: .destructive) { deletionDesignID = event.id }
                        } label: { Label("Manage", systemImage: "ellipsis.circle").frame(minWidth: 44, minHeight: 44) }
                        .buttonStyle(.borderless)
                    }
                }
                NavigationLink("Event History & Earlier Sessions", value: OperatorWorkspaceRoute.eventHistory)
                NavigationLink("Manage Saved Events & Archived Designs", value: OperatorWorkspaceRoute.eventLibrary)
            }
            Section("Local Event Runs") {
                ForEach(runs.runs.filter { showsArchived || $0.status != .archived }.sorted { $0.createdAt > $1.createdAt }) { run in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(run.context.name).font(.headline)
                            Text("\(run.status.rawValue.capitalized) · \(run.createdAt.formatted(date: .abbreviated, time: .omitted))").font(.caption)
                        }
                        Spacer()
                        Menu {
                            NavigationLink("View History", value: OperatorWorkspaceRoute.eventHistory)
                            Button("Archive Run") { manage { try runs.transition(id: run.id, to: .archived) } }
                            Button("Delete Unused Local Run", role: .destructive) { deletionRunID = run.id }
                        } label: { Label("Manage", systemImage: "ellipsis.circle").frame(minWidth: 44, minHeight: 44) }
                        .buttonStyle(.borderless)
                    }
                }
                Text("Local cleanup keeps server-managed commercial events and financial history. Used designs and runs can be archived.").font(.footnote).foregroundStyle(.secondary)
                if !managementMessage.isEmpty { Text(managementMessage).font(.callout) }
            }
            Section("Guest Experience") {
                NavigationLink(value: OperatorWorkspaceRoute.branding) { Label("Event Customization", systemImage: "paintpalette") }
                NavigationLink(value: OperatorWorkspaceRoute.samplePrints) { Label("Preview & Sample Prints", systemImage: "printer.dotmatrix") }
                NavigationLink(value: OperatorWorkspaceRoute.regularBooth) { Label("Regular Booth Configuration", systemImage: "camera") }
            }
            if let error = runs.storageError { Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(OperatorPalette.danger) } }
            if let error = library.storageError { Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(OperatorPalette.danger) } }
        }
        .confirmationDialog("Delete this unused local event design?", isPresented: Binding(get: { deletionDesignID != nil }, set: { if !$0 { deletionDesignID = nil } }), titleVisibility: .visible) {
            Button("Delete Permanently", role: .destructive) { if let id = deletionDesignID { deleteDesign(id) }; deletionDesignID = nil }
            Button("Cancel", role: .cancel) { deletionDesignID = nil }
        } message: { Text("Eligibility is checked again before removal. Designs with applied, commercial or session history must be archived. No payment-server event is deleted.") }
        .confirmationDialog("Delete this unused local run?", isPresented: Binding(get: { deletionRunID != nil }, set: { if !$0 { deletionRunID = nil } }), titleVisibility: .visible) {
            Button("Delete Unused Local Run", role: .destructive) { if let id = deletionRunID { deleteRun(id) }; deletionRunID = nil }
            Button("Cancel", role: .cancel) { deletionRunID = nil }
        } message: { Text("Current runs, commercial identities and runs with session history are protected. Archive a completed run to retain its history.") }
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
