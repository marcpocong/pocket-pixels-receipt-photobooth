import Foundation
import Combine

/// Retained only so setup drafts written by earlier builds keep decoding. Branding is now the
/// selected event's saved design (or the studio default with Event Mode off).
nonisolated enum SessionBrandingChoice: String, Codable, CaseIterable {
    case current, studio, custom
}

nonisolated struct OperatorSessionSetupDraft: Codable, Equatable {
    var mode: CommercialPolicySource
    var eventID: String?
    var serverBinding: String
    /// Legacy field; always written so an older build can still read this file.
    var branding: SessionBrandingChoice? = .current
    var eventModeEnabled: Bool?
    var designID: String?
    /// The paid methods the operator chose ("How will guests pay?"), applied to whichever
    /// server event carries the paid policy.
    var requestedMethods: GuestPaymentChoice?
}

/// A durable, fail-closed barrier around multi-step operator transitions. It never grants a
/// payment entitlement. Existing installs retain their current behavior until an explicit action.
@MainActor final class SessionAcceptanceStore: ObservableObject {
    static let shared = SessionAcceptanceStore()
    nonisolated struct State: Codable, Equatable {
        var blocked = false
        var eventID: String?
        var serverBinding: String?
        var mode: CommercialPolicySource?
    }
    @Published private(set) var state = State()
    @Published private(set) var storageError: String?
    private let file: URL
    private let write: (Data, URL) throws -> Void
    nonisolated static var committedMode: CommercialPolicySource? {
        guard let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
              let bytes = try? Data(contentsOf: root.appendingPathComponent("SessionAcceptanceV1/state.json")),
              let state = try? JSONDecoder().decode(State.self, from: bytes) else { return nil }
        return state.mode
    }
    init(directory: URL? = nil, write: @escaping (Data, URL) throws -> Void = { try DurableFileWriter.write($0, to: $1) }) {
        let root = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        file = root.appendingPathComponent("SessionAcceptanceV1/state.json")
        self.write = write
        if FileManager.default.fileExists(atPath: file.path) {
            do { state = try JSONDecoder().decode(State.self, from: Data(contentsOf: file)) }
            catch { state.blocked = true; storageError = "Session status could not be read. New sessions are paused; Advanced can help recover the saved file." }
        }
    }
    func save(_ next: State) throws {
        if let storageError { throw SetupFailure(storageError) }
        // A failed write must not allow another guest in this process.
        state.blocked = true
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try write(JSONEncoder().encode(next), file)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete, .posixPermissions: 0o600], ofItemAtPath: file.path)
        state = next
    }
    func permits(eventID: String, binding: String) -> Bool {
        !state.blocked && (state.eventID == nil || (state.eventID == eventID && state.serverBinding == binding))
    }
}

nonisolated struct SetupFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

nonisolated protocol SessionSetupAPI: Sendable {
    func listEvents() async throws -> [OperatorEventSummary]
    func eventDetail(id: String) async throws -> OperatorEventDetail
    func createEvent(name: String, venue: String) async throws -> OperatorCreatedEvent
    func saveDraft(eventID: String, expectedVersion: Int, name: String, venue: String, policy: ServerPolicyDraft.RequestBody) async throws -> OperatorEventUpdate
    func transitionEvent(id: String, action: String, expectedVersion: Int, policyRevisionID: String?, acknowledgedUnitPriceCentavos: Int?) async throws -> OperatorEventTransition
    func activeEvent() async throws -> ActiveEventResponse
}
extension PaymentsAPIClient: SessionSetupAPI {}

@MainActor enum SessionSetupSafety {
    static var blockingReason: String? {
        let operations = EventOperationalState.shared
        if operations.customerSessionActive || PrinterCoordinator.shared.isWorking { return "Finish the guest session and printing before changing session operation." }
        if operations.hasUnresolvedPrint || PrinterCoordinator.shared.requiresRecovery || operations.recoverableSession != nil { return "Resolve the preserved guest session in Fix Printer or Payment Recovery before switching modes." }
        guard let checkpoints = CheckoutCheckpointStore.shared, let outbox = PrintOutcomeOutbox.shared else { return "Recovery storage is unavailable. Open Advanced before changing operation." }
        if checkpoints.integrityFault != nil || !checkpoints.unresolved.isEmpty { return "Resolve interrupted checkouts in Payment Recovery before changing operation." }
        let s = outbox.summary
        if outbox.integrityFault != nil || s.pending + s.conflicts + s.uncertain + s.awaiting > 0 { return "Resolve pending print accounting in Advanced before changing operation." }
        return nil
    }
}

/// Staged settings and explicit operator orchestration; provider/payment/print logic stays elsewhere.
/// Event Mode, the event's saved design and the payment choice are independent decisions: any
/// payment choice works with or without Event Mode, and an event works with or without its logo.
@MainActor final class SessionSetupCoordinator: ObservableObject {
    nonisolated static let regularEventName = "Regular Sessions"

    @Published var mode: CommercialPolicySource { didSet { persistSelection() } }
    @Published var eventModeEnabled: Bool { didSet { persistSelection() } }
    @Published private(set) var designID: String?
    /// The selected event's design draft. Edits stay here (and in the workspace) until Save Design
    /// or Start Accepting Guests; nothing reaches guests before activation.
    @Published var design: SavedEventDesign? { didSet { designDidChange(oldValue) } }
    @Published private(set) var requestedMethods: GuestPaymentChoice? { didSet { persistSelection() } }
    @Published var prepaid: CommercialEventRun { didSet { workspace.savePrepaidDraft(prepaid == loadLocal() ? nil : prepaid) } }
    @Published var name = "" { didSet { persistPaid() } }
    @Published var venue = "" { didSet { persistPaid() } }
    @Published var policy = ServerPolicyDraft() { didSet { persistPaid() } }
    @Published private(set) var selectedID: String?
    @Published private(set) var detail: OperatorEventDetail?
    @Published private(set) var events: [OperatorEventSummary] = []
    @Published private(set) var message = ""
    @Published private(set) var busy = false
    @Published private(set) var conflict = false
    @Published private(set) var needsRefresh = false
    private var baseVersion: Int?
    private var loading = false
    private var operationBinding: String?
    private var loadedBinding: String?
    private var pendingServerEventID: String?
    private let workspace: OperatorWorkspace
    private let acceptance: SessionAcceptanceStore
    let library: EventDesignLibraryStore
    private let api: @MainActor () throws -> any SessionSetupAPI
    private let authorized: @MainActor () -> Bool
    private let blockingReason: @MainActor () -> String?
    private let loadLocal: @MainActor () -> CommercialEventRun
    private let saveLocal: @MainActor (CommercialEventRun) throws -> Void
    private let source: @MainActor () -> CommercialPolicySource
    private let saveSource: @MainActor (CommercialPolicySource) -> Void
    private let currentProfile: @MainActor () -> EventProfile
    private let applyProfile: @MainActor (EventProfile) throws -> Void
    private let artworkAvailable: @MainActor (String?) -> Bool

    init(eventID: String? = nil, workspace: OperatorWorkspace? = nil, acceptance: SessionAcceptanceStore? = nil, library: EventDesignLibraryStore? = nil,
         api: @escaping @MainActor () throws -> any SessionSetupAPI = {
             guard let c = PaymentsConfiguration.current() else { throw SetupFailure("Set up this iPad in Advanced → Payment Maintenance first.") }
             return PaymentsAPIClient(configuration: c)
         }, authorized: @escaping @MainActor () -> Bool = { OperatorAccessPermit.shared.isAuthorized },
         blockingReason: @escaping @MainActor () -> String? = { SessionSetupSafety.blockingReason },
         loadLocal: @escaping @MainActor () -> CommercialEventRun = { CommercialEventRunStore.load() },
         saveLocal: @escaping @MainActor (CommercialEventRun) throws -> Void = { try CommercialEventRunStore.publish($0) },
         source: @escaping @MainActor () -> CommercialPolicySource = { CommercialPolicySource.load() },
         saveSource: @escaping @MainActor (CommercialPolicySource) -> Void = { CommercialPolicySource.save($0) },
         currentProfile: @escaping @MainActor () -> EventProfile = { EventProfileStore.load() },
         applyProfile: @escaping @MainActor (EventProfile) throws -> Void = { EventProfileStore.save($0) },
         artworkAvailable: @escaping @MainActor (String?) -> Bool = { identifier in
             (try? EventHeaderAssetStore())?.loadArtwork(identifier: identifier) != nil
         }) {
        let workspace = workspace ?? .shared
        let library = library ?? .shared
        self.workspace = workspace; self.acceptance = acceptance ?? .shared; self.library = library
        self.api = api; self.authorized = authorized; self.blockingReason = blockingReason
        self.loadLocal = loadLocal; self.saveLocal = saveLocal; self.source = source; self.saveSource = saveSource
        self.currentProfile = currentProfile; self.applyProfile = applyProfile; self.artworkAvailable = artworkAvailable
        let staged = workspace.snapshot.sessionSetup
        let saved = library.library
        mode = eventID != nil ? .serverManaged : (staged?.mode ?? source())
        requestedMethods = staged?.requestedMethods
        prepaid = workspace.snapshot.prepaidDraft ?? loadLocal()
        if let eventID {
            // Opened for one server event: Event Mode with that event's saved design.
            eventModeEnabled = true
            pendingServerEventID = eventID
            designID = saved.design(linkedTo: eventID, binding: workspace.serverBinding)?.id
            selectedID = eventID
        } else {
            eventModeEnabled = staged?.eventModeEnabled ?? saved.appliedEventModeEnabled
            designID = staged?.designID ?? saved.appliedEventID ?? (saved.events.count == 1 ? saved.events.first?.id : nil)
            selectedID = staged?.serverBinding == workspace.serverBinding ? staged?.eventID : nil
        }
        design = designID.flatMap { workspace.designDraft(id: $0) ?? saved.design(id: $0) }
        if design == nil { designID = nil }
    }

    // MARK: Payment choice

    /// "How will guests pay?" as one choice, mapped onto the existing policy model.
    var paymentChoice: GuestPaymentChoice {
        guard mode == .serverManaged else { return .noPayment }
        if detail != nil { return GuestPaymentChoice(qrPhEnabled: policy.qrPhEnabled, cashEnabled: policy.cashEnabled) }
        return requestedMethods ?? .qrOnly
    }

    func choosePayment(_ choice: GuestPaymentChoice) async {
        guard choice != paymentChoice else { return }
        if choice == .noPayment { mode = .localPrepaid; return }
        requestedMethods = choice
        let switching = mode != .serverManaged
        mode = .serverManaged
        applyRequestedMethods()
        if switching { await refresh() }
    }

    private func applyRequestedMethods() {
        guard detail != nil, let requested = requestedMethods else { return }
        if policy.qrPhEnabled != requested.acceptsQRPh { policy.qrPhEnabled = requested.acceptsQRPh }
        // Clearing cash also clears signed offline cash (ServerPolicyDraft enforces it).
        if policy.cashEnabled != requested.acceptsCash { policy.cashEnabled = requested.acceptsCash }
    }

    // MARK: Events and designs

    /// The server event that carries the paid policy for the current context: the event's own
    /// link in Event Mode, or the booth's regular-sessions event otherwise. Bound per environment.
    var targetServerEventID: String? {
        let binding = workspace.serverBinding
        return eventModeEnabled ? design?.serverEventID(binding: binding) : library.library.regularServerEvents[binding]
    }

    var savedEvents: [SavedEventDesign] { library.library.events.sorted { $0.updatedAt > $1.updatedAt } }

    /// Server events not yet linked to a saved event in this environment.
    var unlinkedServerEvents: [OperatorEventSummary] {
        let binding = workspace.serverBinding
        let linked = Set(library.library.events.compactMap { $0.serverEvents[binding] })
        let regular = library.library.regularServerEvents[binding]
        return events.filter { !linked.contains($0.id) && $0.id != regular && !["ENDED", "ARCHIVED"].contains($0.lifecycle) }
    }

    var designDirty: Bool {
        guard let design else { return false }
        return !design.hasSameContent(as: library.design(id: design.id))
    }

    func setEventMode(_ enabled: Bool) async {
        guard enabled != eventModeEnabled else { return }
        eventModeEnabled = enabled
        if enabled, design == nil, let first = savedEvents.first { selectDesign(first.id) }
        await syncServerSelection()
    }

    func chooseDesign(_ id: String) async {
        selectDesign(id)
        await syncServerSelection()
    }

    private func selectDesign(_ id: String) {
        guard let saved = library.design(id: id) else { return }
        designID = id
        design = workspace.designDraft(id: id) ?? saved
        persistSelection()
    }

    /// Creates a new saved event (logo off). In a paid setup it is also connected to paid checkout.
    func createEvent(name: String, venue: String) async {
        guard authorized() else { message = "Unlock Operator again before continuing."; return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { message = "Enter an event name."; return }
        do {
            let created = try library.create(name: trimmed, venue: venue)
            workspace.saveNewEvent(name: "", venue: "")
            eventModeEnabled = true
            selectDesign(created.id)
            message = "New event saved. It is not accepting guests."
            if mode == .serverManaged { await connectPaidCheckout() }
        } catch { message = error.localizedDescription }
    }

    /// Adopts a server event created elsewhere as a saved event for this environment.
    func useServerEvent(_ summary: OperatorEventSummary) async {
        do {
            let adopted = try library.adopt(serverEventID: summary.id, name: summary.name, venue: summary.venue, binding: workspace.serverBinding)
            eventModeEnabled = true
            selectDesign(adopted.id)
            await syncServerSelection()
        } catch { message = error.localizedDescription }
    }

    func saveDesign() {
        guard authorized() else { message = "Unlock Operator again before saving."; return }
        guard let design else { return }
        do {
            try library.save(design)
            let saved = library.design(id: design.id)
            self.design = saved
            workspace.saveDesignDraft(nil, id: design.id)
            message = "Design saved — not yet applied. Guests keep the current design until you start accepting guests."
        } catch { message = error.localizedDescription }
    }

    /// Picks up design edits made through another screen (drafts are shared via the workspace).
    func reloadDesignFromStorage() {
        guard let id = designID, let stored = workspace.designDraft(id: id) ?? library.design(id: id), stored != design else { return }
        design = stored
    }

    func discardDesignChanges() {
        guard let id = design?.id, let saved = library.design(id: id) else { return }
        design = saved
        workspace.saveDesignDraft(nil, id: id)
    }

    private func designDidChange(_ old: SavedEventDesign?) {
        guard let design else { return }
        let saved = library.design(id: design.id)
        workspace.saveDesignDraft(design.hasSameContent(as: saved) ? nil : design, id: design.id)
        // A linked paid event keeps its server name in step with the event name.
        if eventModeEnabled, mode == .serverManaged, detail != nil, old?.id == design.id {
            let trimmed = design.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if old?.name != design.name, !trimmed.isEmpty, name != trimmed { name = trimmed }
            if old?.venue != design.venue, venue != design.venue { venue = design.venue }
        }
    }

    /// The profile Start Accepting Guests applies: the event's design, or the studio default.
    var effectiveProfile: EventProfile {
        if eventModeEnabled, let design { return design.appliedProfile() }
        var studio = currentProfile()
        studio.isEnabled = false
        studio.customerScreenEnabled = false
        return studio.normalized()
    }

    var logoIsUsable: Bool { design.map { artworkAvailable($0.logoIdentifier) } ?? false }

    // MARK: Validation and status

    var dirtyPaid: Bool {
        guard let detail else { return false }
        guard let latest = detail.latestRevision else { return true }
        return name.trimmingCharacters(in: .whitespacesAndNewlines) != detail.event.name
            || venue.trimmingCharacters(in: .whitespacesAndNewlines) != detail.event.venue
            || policy.requestBody() != ServerPolicyDraft(revision: latest).requestBody()
    }
    var validation: String? {
        if let reason = blockingReason() { return reason }
        if needsRefresh { return "Check Current Status before reviewing again. The previous action may have reached the server." }
        if eventModeEnabled {
            guard let design else { return "Choose or create an event, or turn off Event Mode." }
            if design.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Enter an event name." }
            if design.personalizeReceipt && !artworkAvailable(design.logoIdentifier) {
                return design.logoIdentifier == nil
                    ? "Add an event logo, or turn off Personalize Receipt."
                    : "The saved logo can’t be read. Choose another file, or turn off Personalize Receipt."
            }
        }
        if mode == .localPrepaid { return prepaid.activePolicy.validationMessage }
        if conflict { return "Server Settings Changed — Review Required." }
        if targetServerEventID == nil {
            return eventModeEnabled ? "Connect this event to paid checkout to set a price." : "Set up regular paid sessions to set a price."
        }
        if loadedBinding != workspace.serverBinding { return "Check Current Status for this payments connection." }
        guard let detail, detail.event.id == selectedID else { return "Loading paid settings… Check Current Status if this persists." }
        if [.ended, .archived].contains(detail.event.lifecycle) { return "This event is closed. Choose or create another event." }
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Enter an event name." }
        if policy.commercialMode != .payPerPrint { return "This saved event is prepaid. Choose a pay-per-print event." }
        return policy.validationMessage()
    }

    /// Whether guests are using exactly this setup right now.
    var isCurrentlyApplied: Bool {
        guard !acceptance.state.blocked, source() == mode, !designDirty, effectiveProfile == currentProfile().normalized() else { return false }
        if mode == .localPrepaid {
            let run = loadLocal(), applied = run.activePolicy, staged = prepaid.activePolicy
            return run.acceptsNewSessions && applied.defaultCopies == staged.defaultCopies && applied.maxCopies == staged.maxCopies
                && applied.prepaidGuestCopyChoice == staged.prepaidGuestCopyChoice && applied.supportedFormatRawValues == staged.supportedFormatRawValues
        }
        guard let detail, !dirtyPaid, detail.event.id == acceptance.state.eventID else { return false }
        return detail.event.lifecycle == .active && detail.activePolicy?.id == detail.latestRevision?.id
    }

    var hasUnsavedChanges: Bool {
        designDirty || (mode == .serverManaged && dirtyPaid) || (mode == .localPrepaid && workspace.snapshot.prepaidDraft != nil)
    }

    private func persistSelection() {
        let applied = library.library
        let sameDesignSelection = eventModeEnabled == applied.appliedEventModeEnabled
            && (!eventModeEnabled || designID == applied.appliedEventID)
        let samePaymentSelection = mode == source()
            && (mode != .serverManaged || (selectedID == acceptance.state.eventID
                && acceptance.state.serverBinding == workspace.serverBinding
                && (requestedMethods == nil || requestedMethods == detail?.activePolicy.map {
                    GuestPaymentChoice(qrPhEnabled: $0.qrphEnabled, cashEnabled: $0.cashEnabled)
                })))
        // Pausing changes admission, not the applied setup. Viewing it isn't an unsaved edit.
        if sameDesignSelection && samePaymentSelection {
            workspace.saveSessionSetup(nil)
        } else {
            workspace.saveSessionSetup(.init(mode: mode, eventID: selectedID, serverBinding: workspace.serverBinding,
                                             eventModeEnabled: eventModeEnabled, designID: designID, requestedMethods: requestedMethods))
        }
    }
    private func persistPaid() {
        guard !loading, let selectedID, let baseVersion else { return }
        if !dirtyPaid && !conflict {
            workspace.removeServerDraft(eventID: selectedID)
            return
        }
        workspace.saveServerDraft(.init(eventID: selectedID, serverBinding: workspace.serverBinding, baseVersion: baseVersion, name: name, venue: venue, policy: policy))
    }

    // MARK: Server events

    func refresh() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do {
            if mode == .localPrepaid, source() == .localPrepaid { needsRefresh = false; return }
            events = try await api().listEvents()
            if let pending = pendingServerEventID {
                pendingServerEventID = nil
                bindSelection(to: pending)
            }
            adoptCommittedEventIfNeeded()
            if let target = targetServerEventID {
                selectedID = target
                try await loadPaid(target)
            } else if mode == .serverManaged {
                selectedID = nil; detail = nil; baseVersion = nil
            }
            persistSelection()
            needsRefresh = false
        } catch { message = error.localizedDescription }
    }

    /// Loads the server event for the current context after Event Mode, event or payment changes.
    func syncServerSelection() async {
        guard mode == .serverManaged else { return }
        guard let target = targetServerEventID else {
            selectedID = nil; detail = nil; baseVersion = nil; persistSelection()
            if events.isEmpty { await refresh() }
            return
        }
        if detail?.event.id != target || loadedBinding != workspace.serverBinding { await select(target) }
    }

    /// Uses one server event for the current context (operator's explicit choice).
    func select(_ id: String) async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        bindSelection(to: id)
        detail = nil; selectedID = id; persistSelection()
        do { try await loadPaid(id); needsRefresh = false } catch { message = error.localizedDescription }
    }

    /// Records which saved event (or the regular sessions) a server event belongs to, per
    /// environment. Purely local; never changes a server event.
    private func bindSelection(to id: String) {
        let binding = workspace.serverBinding
        do {
            if eventModeEnabled {
                if let linked = library.library.design(linkedTo: id, binding: binding) {
                    if linked.id != designID { selectDesign(linked.id) }
                } else if var design, design.serverEventID(binding: binding) == nil {
                    try library.link(designID: design.id, binding: binding, serverEventID: id)
                    design.serverEvents[binding] = id
                    self.design = design
                } else {
                    let summary = events.first { $0.id == id }
                    let adopted = try library.adopt(serverEventID: id, name: summary?.name ?? "Paid Event", venue: summary?.venue ?? "", binding: binding)
                    selectDesign(adopted.id)
                }
            } else if library.library.regularServerEvents[binding] != id {
                try library.setRegularServerEvent(id, binding: binding)
            }
        } catch { message = error.localizedDescription }
    }

    /// Existing installs: the event this booth already accepts guests for keeps working without
    /// re-linking. Never guesses any other event.
    private func adoptCommittedEventIfNeeded() {
        let binding = workspace.serverBinding
        guard mode == .serverManaged, targetServerEventID == nil,
              acceptance.state.serverBinding == binding, let committed = acceptance.state.eventID,
              events.contains(where: { $0.id == committed }) else { return }
        if eventModeEnabled {
            guard design != nil, library.library.design(linkedTo: committed, binding: binding) == nil else { return }
        }
        bindSelection(to: committed)
    }

    /// Creates (or reuses) the server event that carries this context's paid policy. Explicit
    /// operator action; the link is remembered so revisiting setup never creates duplicates.
    func connectPaidCheckout() async {
        guard !busy, authorized(), !needsRefresh, mode == .serverManaged, targetServerEventID == nil else { return }
        busy = true; defer { busy = false }
        let binding = workspace.serverBinding
        do {
            if eventModeEnabled {
                guard var design else { throw SetupFailure("Choose or create an event first.") }
                guard !design.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SetupFailure("Enter an event name first.") }
                if library.design(id: design.id) == nil { try library.save(design) }
                let created = try await api().createEvent(name: design.displayName, venue: design.venue)
                try library.link(designID: design.id, binding: binding, serverEventID: created.id)
                design.serverEvents[binding] = created.id
                self.design = design
            } else {
                events = try await api().listEvents()
                let id: String
                // Earlier releases used the studio-prefixed name. Reuse that event without
                // changing its policy; never create a second commercial draft on an upgrade.
                let existing = events.filter {
                    ($0.name == Self.regularEventName || $0.name == "Made to Keep Studios — \(Self.regularEventName)")
                        && !["ENDED", "ARCHIVED"].contains($0.lifecycle)
                }
                guard existing.count <= 1 else { throw SetupFailure("Multiple regular-session events exist. Select the intended existing event in Event Mode before continuing.") }
                if let reusable = existing.first {
                    guard unlinkedServerEvents.contains(where: { $0.id == reusable.id }) else {
                        throw SetupFailure("Regular sessions are already linked to a saved event. Select that existing event in Event Mode before continuing.")
                    }
                    id = reusable.id
                }
                else { id = try await api().createEvent(name: Self.regularEventName, venue: "").id }
                try library.setRegularServerEvent(id, binding: binding)
            }
            guard let target = targetServerEventID else { throw SetupFailure("The paid checkout link was not saved.") }
            selectedID = target; persistSelection()
            try await loadPaid(target)
            events = try await api().listEvents()
            message = "Paid checkout ready. It is not accepting guests until you review and start."
        } catch {
            needsRefresh = true
            message = "Paid checkout was not confirmed. Check Current Status before trying again. \(error.localizedDescription)"
        }
    }

    private func loadPaid(_ id: String) async throws {
        let binding = workspace.serverBinding
        let fetched = try await api().eventDetail(id: id)
        guard binding == workspace.serverBinding else { throw SetupFailure("The payments connection changed. Check Current Status.") }
        guard selectedID == id else { return }
        loading = true; defer { loading = false }
        detail = fetched
        loadedBinding = binding
        if let draft = workspace.serverDraft(eventID: id) {
            name = draft.name; venue = draft.venue; policy = draft.policy; baseVersion = draft.baseVersion
            conflict = draft.conflicts(with: fetched.event.version)
        } else {
            name = fetched.event.name; venue = fetched.event.venue
            policy = fetched.latestRevision.map(ServerPolicyDraft.init(revision:)) ?? ServerPolicyDraft()
            baseVersion = fetched.event.version; conflict = false
        }
        loading = false
        // The operator's staged payment choice applies to whichever event carries the policy.
        applyRequestedMethods()
        persistPaid()
        persistSelection()
    }
    func keepReviewedEdits() {
        guard authorized(), let detail else { return }
        baseVersion = detail.event.version; conflict = false; persistPaid()
    }
    func discardPaidEdits() async {
        guard authorized(), let selectedID else { return }
        workspace.removeServerDraft(eventID: selectedID); await select(selectedID)
    }
    private func checkPermit(requireIdle: Bool = true) throws {
        guard authorized() else { throw SetupFailure("Unlock Operator again before continuing.") }
        if let operationBinding, operationBinding != workspace.serverBinding { throw SetupFailure("The payments connection changed. Review setup for the current connection.") }
        if requireIdle, let reason = blockingReason() { throw SetupFailure(reason) }
    }
    /// Saves everything without opening the booth: the event design locally and, for paid
    /// setups, the server event's settings. Guests keep the currently applied setup.
    func saveOnly() async {
        guard !busy, authorized(), validation == nil else { return }
        busy = true; defer { busy = false }
        do {
            if eventModeEnabled, let design, designDirty {
                try library.save(design)
                self.design = library.design(id: design.id)
                workspace.saveDesignDraft(nil, id: design.id)
            }
            if mode == .serverManaged { try await savePaid() }
            message = "Saved — Not Yet Applied. Guests keep the currently applied settings."
        } catch let failure as SetupFailure where mode == .localPrepaid {
            message = failure.localizedDescription
        } catch { await handleFailure(error) }
    }
    private func savePaid() async throws {
        guard let selectedID, let detail, let body = policy.requestBody(), let baseVersion else { throw SetupFailure("Review the event settings first.") }
        guard !conflict else { throw SetupFailure("Review changed server settings first.") }
        guard authorized() else { throw SetupFailure("Unlock Operator again before saving.") }
        if dirtyPaid {
            _ = try await api().saveDraft(eventID: selectedID, expectedVersion: baseVersion,
                name: name.trimmingCharacters(in: .whitespacesAndNewlines), venue: venue.trimmingCharacters(in: .whitespacesAndNewlines), policy: body)
            // Acknowledged save still needs a fresh read before subsequent publication.
            let refreshed = try await api().eventDetail(id: selectedID)
            guard let latest = refreshed.latestRevision,
                  ServerPolicyDraft(revision: latest).requestBody() == body,
                  refreshed.event.name == name.trimmingCharacters(in: .whitespacesAndNewlines),
                  refreshed.event.venue == venue.trimmingCharacters(in: .whitespacesAndNewlines) else {
                throw SetupFailure("Saved settings changed again. Review the current server settings.")
            }
            self.detail = refreshed; self.baseVersion = refreshed.event.version
            loading = true; name = refreshed.event.name; venue = refreshed.event.venue; policy = ServerPolicyDraft(revision: latest); loading = false
            workspace.removeServerDraft(eventID: selectedID)
        } else if detail.event.version != baseVersion { throw SetupFailure("Server settings changed. Review required.") }
    }
    private func transition(_ event: OperatorEventDetail, action: String, revision: OperatorPolicyRevision? = nil) async throws -> OperatorEventDetail {
        try checkPermit(requireIdle: action != "pause")
        _ = try await api().transitionEvent(id: event.event.id, action: action, expectedVersion: event.event.version,
                                          policyRevisionID: revision?.id, acknowledgedUnitPriceCentavos: revision?.unitPriceCentavos)
        return try await api().eventDetail(id: event.event.id)
    }
    /// Called only from the reviewed setup's explicit confirmation. Failure leaves the barrier closed.
    func startAccepting() async -> Bool {
        guard !busy, validation == nil else { return false }
        busy = true; operationBinding = workspace.serverBinding
        defer { busy = false; operationBinding = nil }
        do {
            try checkPermit()
            // The reviewed design is saved first; saving never changes what guests receive.
            if eventModeEnabled, let design, designDirty {
                try library.save(design)
                self.design = library.design(id: design.id)
                workspace.saveDesignDraft(nil, id: design.id)
            }
            let profile = effectiveProfile
            try acceptance.save(.init(blocked: true, eventID: acceptance.state.eventID, serverBinding: acceptance.state.serverBinding, mode: source()))
            if mode == .localPrepaid {
                // A paid → prepaid switch also pauses the current remote event; provider recovery stays live.
                if source() == .serverManaged {
                    let current = try await api().activeEvent()
                    if let active = current.event {
                        if let expected = acceptance.state.eventID, active.id != expected { throw SetupFailure("The active paid event changed. Review the current paid event before switching modes.") }
                        let event = try await api().eventDetail(id: active.id)
                        let paused = try await transition(event, action: "pause")
                        guard paused.event.lifecycle == .paused else { throw SetupFailure("Pausing the paid event was not confirmed.") }
                    }
                }
                try checkPermit()
                var run = prepaid
                run.name = eventModeEnabled ? (design?.displayName ?? "") : ""
                run.venue = eventModeEnabled ? (design?.venue ?? "") : ""
                run.activePolicy.commercialMode = .privatePrepaid; run.activePolicy.unitPriceCentavos = 0
                run.activePolicy.cashEnabled = false; run.activePolicy.qrPhEnabled = false; run.activePolicy.offlineValidUntil = nil
                run.lifecycle = .active; run.updatedAt = Date()
                try saveLocal(run); try applyProfile(profile)
                try checkPermit(); saveSource(.localPrepaid)
                try acceptance.save(.init(mode: .localPrepaid))
                prepaid = run; workspace.savePrepaidDraft(nil)
            } else {
                guard let id = selectedID, id == targetServerEventID, let expectedVersion = baseVersion else { throw SetupFailure("Choose an event.") }
                let fresh = try await api().eventDetail(id: id)
                guard fresh.event.version == expectedVersion else { self.detail = fresh; conflict = true; throw SetupFailure("Server Settings Changed — Review Required.") }
                try await savePaid()
                guard var event = detail, let revision = event.latestRevision, revision.commercialMode == .payPerPrint else { throw SetupFailure("No saved pay-per-print settings to apply.") }
                // Do not unexpectedly pause another event. The owner must choose/pause it first.
                let current = try await api().activeEvent()
                if let active = current.event, active.id != id { throw SetupFailure("Another paid event is active. Pause it before starting this event.") }
                if event.event.lifecycle == .draft {
                    event = try await transition(event, action: "activate", revision: revision)
                } else {
                    if event.activePolicy?.id != revision.id { event = try await transition(event, action: "publish", revision: revision) }
                    if event.event.lifecycle == .paused { event = try await transition(event, action: "resume") }
                }
                self.detail = event
                let confirmed = try await api().activeEvent()
                guard event.event.lifecycle == .active, event.activePolicy?.id == revision.id,
                      confirmed.event?.id == id, confirmed.event?.policyRevisionId == revision.id else { throw SetupFailure("Starting this event was not confirmed. Check Current Status.") }
                try checkPermit(); try applyProfile(profile); saveSource(.serverManaged)
                try acceptance.save(.init(blocked: false, eventID: id, serverBinding: workspace.serverBinding, mode: .serverManaged))
                baseVersion = event.event.version; workspace.removeServerDraft(eventID: id)
            }
            // Informational only: which event the library shows as applied.
            try? library.recordApplied(eventModeEnabled: eventModeEnabled, eventID: designID)
            requestedMethods = nil
            workspace.saveSessionSetup(nil); message = "Accepting guests. The next session will use the reviewed setup."
            return true
        } catch { await handleFailure(error); return false }
    }
    func pause() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do {
            try checkPermit(requireIdle: false)
            try acceptance.save(.init(blocked: true, eventID: acceptance.state.eventID, serverBinding: acceptance.state.serverBinding, mode: source()))
            if source() == .localPrepaid {
                var run = loadLocal(); run.lifecycle = .paused; run.updatedAt = Date(); try saveLocal(run)
            } else {
                let current = try await api().activeEvent()
                if let active = current.event {
                    if let expected = acceptance.state.eventID, active.id != expected { throw SetupFailure("The active paid event differs from this booth's setup. This iPad is paused; review the current event before pausing it remotely.") }
                    let event = try await api().eventDetail(id: active.id)
                    let result = try await transition(event, action: "pause")
                    guard result.event.lifecycle == .paused else { throw SetupFailure("Server pause was not confirmed.") }
                    if selectedID == active.id { self.detail = result; baseVersion = result.event.version; persistPaid() }
                }
            }
            message = "New sessions paused. Previously authorized purchases remain recoverable."
        } catch { await handleFailure(error) }
    }
    private func handleFailure(_ error: Error) async {
        needsRefresh = true
        message = "Action not confirmed: \(error.localizedDescription) Check Current Status before trying again."
        // Read only; never retry a potentially committed mutation.
        if let selectedID, let fetched = try? await api().eventDetail(id: selectedID) {
            detail = fetched; conflict = baseVersion != fetched.event.version
            message += " Current event: \(fetched.event.lifecycle.displayName)."
        }
        if acceptance.state.blocked { message += " New sessions on this iPad remain paused." }
    }
}

extension CommercialEventLifecycle {
    var displayName: String {
        switch self { case .draft: "Draft — not accepting guests"; case .active: "Currently Active"; case .paused: "Paused"; case .ended: "Ended"; case .archived: "Archived" }
    }
}

nonisolated enum SessionAdmission {
    static func localConfigurationIsReady(source: CommercialPolicySource, local: CommercialEventRun) -> Bool {
        source == .serverManaged || (local.acceptsNewSessions && local.activePolicy.commercialMode == .privatePrepaid && local.activePolicy.validationMessage == nil)
    }
}
