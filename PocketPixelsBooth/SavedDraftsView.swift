import SwiftUI

struct SavedDraftsView: View {
    @ObservedObject var workspace: OperatorWorkspace
    @ObservedObject var library: EventDesignLibraryStore
    var loadsRemote = true
    @State private var remote: [SavedDraftID: OperatorEventDetail] = [:]
    @State private var discardCandidate: SavedDraftEntry?
    @State private var message = ""

    init(workspace: OperatorWorkspace = .shared, library: EventDesignLibraryStore = .shared, loadsRemote: Bool = true) {
        self.workspace = workspace; self.library = library; self.loadsRemote = loadsRemote
    }
    private var entries: [SavedDraftEntry] { SavedDraftCatalog.entries(workspace: workspace, library: library.library, remote: remote) }
    var body: some View {
        List {
            Section {
                Text("Edits are saved on this iPad. Review what changed, then save or discard each draft. Your guests keep the applied setup.")
                    .foregroundStyle(.secondary)
            }
            if entries.isEmpty {
                ContentUnavailableView("No saved drafts", systemImage: "checkmark.circle", description: Text("Your setup has no unfinished local changes."))
            }
            ForEach(Array(Set(entries.map(\.eventName))).sorted(), id: \.self) { name in
                SwiftUI.Section {
                    ForEach(entries.filter { $0.eventName == name }, content: draftRow)
                } header: { Text(name) }
            }
            if !message.isEmpty { Section { Text(message).foregroundStyle(.red) } }
        }
        .navigationTitle("Saved Drafts")
        .confirmationDialog(discardCandidate.map { "Discard \($0.category.lowercased()) changes for \($0.eventName)?" } ?? "Discard changes?",
                            isPresented: Binding(get: { discardCandidate != nil }, set: { if !$0 { discardCandidate = nil } }), titleVisibility: .visible) {
            if let entry = discardCandidate {
                Button("Discard These Changes", role: .destructive) {
                    do { try workspace.discardDraft(entry.id); message = "" } catch { message = error.localizedDescription }
                    discardCandidate = nil
                }
            }
            Button("Cancel", role: .cancel) { discardCandidate = nil }
        } message: { Text("Only this draft is removed. Saved designs, artwork, other drafts and the guest setup are kept.") }
        .task { await refresh() }
        .refreshable { await refresh() }
    }
    // Returning an opaque View keeps older SDKs from selecting Charts' ForEach overload.
    private func draftRow(_ entry: SavedDraftEntry) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(entry.category).font(.headline)
            SavedDraftChangesView(changes: Array(entry.changes.prefix(3)))
            if entry.changes.count > 3 { Text("\(entry.changes.count - 3) more changes").font(.caption).foregroundStyle(.secondary) }
            if let notice = entry.notice { Text(notice).font(.footnote).foregroundStyle(.secondary) }
            HStack {
                NavigationLink("Review", value: OperatorWorkspaceRoute.draftReview(entry.id)).buttonStyle(.borderedProminent)
                Button("Discard Changes", role: .destructive) { discardCandidate = entry }.buttonStyle(.bordered)
            }
        }.padding(.vertical, 10)
    }

    private func refresh() async {
        guard loadsRemote, OperatorAccessPermit.shared.isAuthorized else { return }
        if let configuration = PaymentsConfiguration.current() {
            let client = PaymentsAPIClient(configuration: configuration)
            var eventIDs = Set(workspace.snapshot.serverDrafts.values.filter { $0.serverBinding == workspace.serverBinding }.map(\.eventID))
            if let selection = workspace.snapshot.sessionSetup, selection.serverBinding == workspace.serverBinding, let event = selection.eventID { eventIDs.insert(event) }
            if workspace.snapshot.sessionSetup != nil, let event = SessionAcceptanceStore.shared.state.eventID { eventIDs.insert(event) }
            for event in eventIDs.sorted() {
                let id = SavedDraftID.payment(binding: workspace.serverBinding, eventID: event)
                if let detail = try? await client.eventDetail(id: event) { remote[id] = detail }
            }
        }
        do { try SavedDraftCatalog.removeEquivalentDrafts(workspace: workspace, library: library.library, remote: remote) }
        catch { message = error.localizedDescription }
    }
}

struct SavedDraftChangesView: View {
    let changes: [SavedDraftChange]
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(changes) { change in
                VStack(alignment: .leading, spacing: 3) {
                    Text(change.label).font(.subheadline.weight(.medium))
                    Text("\(change.before ?? "Previous value unavailable") → \(change.after)")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }.accessibilityElement(children: .combine)
            }
        }
    }
}

struct SavedDraftReviewView: View {
    let draftID: SavedDraftID
    @ObservedObject var workspace: OperatorWorkspace
    @ObservedObject var library: EventDesignLibraryStore
    var loadsRemote = true
    @State private var remote: [SavedDraftID: OperatorEventDetail] = [:]
    @State private var message = ""
    @State private var confirmDiscard = false
    @State private var savedStudioDesignID: String?

    init(draftID: SavedDraftID, workspace: OperatorWorkspace = .shared, library: EventDesignLibraryStore = .shared, loadsRemote: Bool = true) {
        self.draftID = draftID; self.workspace = workspace; self.library = library; self.loadsRemote = loadsRemote
    }
    private var entry: SavedDraftEntry? { SavedDraftCatalog.entries(workspace: workspace, library: library.library, remote: remote).first { $0.id == draftID } }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let entry {
                    Text(entry.eventName).font(.largeTitle.bold())
                    Text(entry.category).font(.title2)
                    Text("Saved locally. These changes have not been applied to guests.").foregroundStyle(.secondary)
                    if let notice = entry.notice { Label(notice, systemImage: "info.circle").foregroundStyle(.secondary) }
                    GroupBox("What changed") { SavedDraftChangesView(changes: entry.changes).frame(maxWidth: .infinity, alignment: .leading) }
                    actions
                    Button("Discard Changes", role: .destructive) { confirmDiscard = true }.buttonStyle(.bordered)
                    if let profile = previewProfile {
                        GroupBox("Draft receipt preview") {
                            EventReceiptComposerPreview(profile: profile, printOptions: ReceiptPrintSettingsStore.load(), showsSamplePrintLink: false, maximumPreviewWidth: 300)
                        }.frame(maxWidth: .infinity)
                    }
                } else {
                    ContentUnavailableView("Draft resolved", systemImage: "checkmark.circle", description: Text("No unfinished changes remain for this draft. Other drafts are kept."))
                }
                if !message.isEmpty { Text(message).foregroundStyle(.secondary) }
            }.padding(28).frame(maxWidth: 850).frame(maxWidth: .infinity)
        }
        .navigationTitle("Review Draft")
        .confirmationDialog(entry.map { "Discard \($0.category.lowercased()) changes for \($0.eventName)?" } ?? "Discard changes?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard These Changes", role: .destructive) {
                do { try workspace.discardDraft(draftID); message = "Changes discarded. Your guests keep the applied setup." }
                catch { message = error.localizedDescription }
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Saved designs, artwork and other drafts are kept. Nothing is published or activated.") }
        .task {
            guard loadsRemote, OperatorAccessPermit.shared.isAuthorized,
                  case .payment(let binding, let eventID) = draftID, binding == workspace.serverBinding,
                  let configuration = PaymentsConfiguration.current() else { return }
            if let detail = try? await PaymentsAPIClient(configuration: configuration).eventDetail(id: eventID) { remote[draftID] = detail }
        }
    }
    private var previewProfile: EventProfile? {
        switch draftID {
        case .design(let id): return workspace.designDraft(id: id)?.appliedProfile()
        case .branding: return workspace.snapshot.brandingDraft?.normalized()
        default: return nil
        }
    }
    @ViewBuilder private var actions: some View {
        switch draftID {
        case .design(let id):
            if library.design(id: id) != nil {
                NavigationLink("Edit Receipt Design") { SavedDesignDraftEditor(id: id, workspace: workspace, library: library) }.buttonStyle(.bordered)
                Button("Save Design") { saveDesign(id) }.buttonStyle(.borderedProminent)
                Text("Saves this event's design. Guests keep their current receipt until you explicitly review and start that setup.").font(.footnote).foregroundStyle(.secondary)
            }
        case .payment(let binding, let eventID):
            if binding == workspace.serverBinding {
                NavigationLink("Review Payment Settings") {
                    SessionSetupView(coordinator: SessionSetupCoordinator(eventID: eventID, draftTarget: draftID, workspace: workspace, library: library))
                }.buttonStyle(.borderedProminent)
                Text("Save settings in the existing editor. Publishing or starting acceptance requires its separate confirmation.").font(.footnote).foregroundStyle(.secondary)
            }
        case .sessionSelection:
            if workspace.snapshot.sessionSetup?.mode == .localPrepaid || workspace.snapshot.sessionSetup?.serverBinding == workspace.serverBinding {
                NavigationLink("Edit Session Setup") {
                    SessionSetupView(coordinator: SessionSetupCoordinator(draftTarget: draftID, workspace: workspace, library: library))
                }.buttonStyle(.borderedProminent)
            }
        case .regularBooth:
            NavigationLink("Edit Booth Defaults") { RegularBoothSettingsView(workspace: workspace) }.buttonStyle(.borderedProminent)
        case .prepaid:
            NavigationLink("Edit Included Copies and Formats") {
                SessionSetupView(coordinator: SessionSetupCoordinator(draftTarget: draftID, workspace: workspace, library: library))
            }.buttonStyle(.borderedProminent)
        case .newEvent:
            NavigationLink("Continue New Event") {
                SessionSetupView(coordinator: SessionSetupCoordinator(draftTarget: .newEvent, workspace: workspace, library: library), opensNewEventDraft: true)
            }.buttonStyle(.borderedProminent)
        case .branding:
            Button("Save as Studio Design") { saveStudioDesign() }.buttonStyle(.borderedProminent)
            Text("Keeps this older studio draft as a saved event design you can edit in Branding & Design. It does not apply it to guests.").font(.footnote).foregroundStyle(.secondary)
        }
    }
    private func saveDesign(_ id: String) {
        guard OperatorAccessPermit.shared.isAuthorized, var draft = workspace.designDraft(id: id), let saved = library.design(id: id) else { return }
        do {
            draft.serverEvents = saved.serverEvents
            draft.createdAt = saved.createdAt
            try library.save(draft)
            try workspace.discardDraft(.design(id))
            message = "Design saved. Guests keep their current setup."
        } catch { message = error.localizedDescription }
    }
    private func saveStudioDesign() {
        guard OperatorAccessPermit.shared.isAuthorized, let profile = workspace.snapshot.brandingDraft else { return }
        do {
            if savedStudioDesignID == nil {
                let name = profile.eventName.trimmingCharacters(in: .whitespacesAndNewlines)
                var design = SavedEventDesign.new(name: name.isEmpty ? "Studio Draft" : name, venue: profile.location)
                design.profile = profile; design.personalizeReceipt = profile.isEnabled; design.guestScreensEnabled = profile.customerScreenEnabled
                try library.save(design); savedStudioDesignID = design.id
            }
            try workspace.discardDraft(.branding)
            message = "Studio design saved. Guests keep their current setup."
        } catch { message = error.localizedDescription }
    }
}

/// Selects the exact design without rewriting session selection or a different event's paid draft.
struct SavedDesignDraftEditor: View {
    @StateObject private var setup: SessionSetupCoordinator
    @State private var confirmsDiscard = false
    init(id: String, workspace: OperatorWorkspace = .shared, library: EventDesignLibraryStore = .shared) {
        _setup = StateObject(wrappedValue: SessionSetupCoordinator(draftTarget: .design(id), workspace: workspace, library: library))
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if let design = Binding($setup.design) {
                    Text(design.wrappedValue.displayName).font(.title.bold())
                    Text("Editing a saved draft. Guests keep the applied design.").foregroundStyle(.secondary)
                    EventReceiptDesignPanel(design: design, isDirty: setup.designDirty, save: { setup.saveDesign() }, discard: { confirmsDiscard = true })
                    NavigationLink("More Design Options") { EventDesignEditorView(setup: setup) }.buttonStyle(.bordered)
                } else { ContentUnavailableView("Design unavailable", systemImage: "doc.questionmark") }
                if !setup.message.isEmpty { Text(setup.message).foregroundStyle(.secondary) }
            }.padding(28).frame(maxWidth: 850).frame(maxWidth: .infinity)
        }.navigationTitle("Edit Draft Design")
        .onAppear { setup.reloadDesignFromStorage() }
        .confirmationDialog("Discard receipt design changes for \(setup.design?.displayName ?? "this event")?", isPresented: $confirmsDiscard, titleVisibility: .visible) {
            Button("Discard These Changes", role: .destructive) { setup.discardDesignChanges() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Only this design draft is discarded. Saved artwork, other drafts and the applied guest setup are kept.") }
    }
}
