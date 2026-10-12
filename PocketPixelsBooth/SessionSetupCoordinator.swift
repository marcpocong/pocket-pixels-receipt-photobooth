import Foundation
import Combine

nonisolated enum SessionBrandingChoice: String, Codable, CaseIterable {
    case current, studio, custom
    var title: String {
        switch self { case .current: "Keep current design"; case .studio: "Studio Default"; case .custom: "Current Custom Event Design" }
    }
    func applying(to original: EventProfile) throws -> EventProfile {
        guard self != .current else { return original }
        if self == .custom && original.showEventTextBlock && original.normalized().eventName.isEmpty {
            throw SetupFailure("Add a name in Branding & Design before applying custom event details.")
        }
        var result = original
        result.isEnabled = self == .custom; result.customerScreenEnabled = self == .custom
        return result
    }
}

nonisolated struct OperatorSessionSetupDraft: Codable, Equatable {
    var mode: CommercialPolicySource
    var eventID: String?
    var serverBinding: String
    var branding: SessionBrandingChoice
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
@MainActor final class SessionSetupCoordinator: ObservableObject {
    @Published var mode: CommercialPolicySource { didSet { persistSelection() } }
    @Published var branding: SessionBrandingChoice { didSet { persistSelection() } }
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
    private let workspace: OperatorWorkspace
    private let acceptance: SessionAcceptanceStore
    private let api: @MainActor () throws -> any SessionSetupAPI
    private let authorized: @MainActor () -> Bool
    private let blockingReason: @MainActor () -> String?
    private let loadLocal: @MainActor () -> CommercialEventRun
    private let saveLocal: @MainActor (CommercialEventRun) throws -> Void
    private let source: @MainActor () -> CommercialPolicySource
    private let saveSource: @MainActor (CommercialPolicySource) -> Void
    private let applyBranding: @MainActor (SessionBrandingChoice) throws -> Void
    private let brandingError: @MainActor (SessionBrandingChoice) -> String?

    init(eventID: String? = nil, workspace: OperatorWorkspace? = nil, acceptance: SessionAcceptanceStore? = nil,
         api: @escaping @MainActor () throws -> any SessionSetupAPI = {
             guard let c = PaymentsConfiguration.current() else { throw SetupFailure("Set up this iPad in Advanced → Payment Maintenance first.") }
             return PaymentsAPIClient(configuration: c)
         }, authorized: @escaping @MainActor () -> Bool = { OperatorAccessPermit.shared.isAuthorized },
         blockingReason: @escaping @MainActor () -> String? = { SessionSetupSafety.blockingReason },
         loadLocal: @escaping @MainActor () -> CommercialEventRun = { CommercialEventRunStore.load() },
         saveLocal: @escaping @MainActor (CommercialEventRun) throws -> Void = { try CommercialEventRunStore.publish($0) },
         source: @escaping @MainActor () -> CommercialPolicySource = { CommercialPolicySource.load() },
         saveSource: @escaping @MainActor (CommercialPolicySource) -> Void = { CommercialPolicySource.save($0) },
         brandingError: @escaping @MainActor (SessionBrandingChoice) -> String? = { choice in
             do { _ = try choice.applying(to: EventProfileStore.load()); return nil } catch { return error.localizedDescription }
         }, applyBranding: @escaping @MainActor (SessionBrandingChoice) throws -> Void = { choice in
             guard choice != .current else { return }
             EventProfileStore.save(try choice.applying(to: EventProfileStore.load()))
         }) {
        let workspace = workspace ?? .shared
        self.workspace = workspace; self.acceptance = acceptance ?? .shared
        self.api = api; self.authorized = authorized; self.blockingReason = blockingReason
        self.loadLocal = loadLocal; self.saveLocal = saveLocal; self.source = source; self.saveSource = saveSource; self.applyBranding = applyBranding; self.brandingError = brandingError
        let staged = workspace.snapshot.sessionSetup
        mode = eventID != nil ? .serverManaged : (staged?.mode ?? source()); branding = staged?.branding ?? .current
        prepaid = workspace.snapshot.prepaidDraft ?? loadLocal()
        selectedID = eventID ?? (staged?.serverBinding == workspace.serverBinding ? staged?.eventID : nil)
    }

    var dirtyPaid: Bool {
        guard let detail else { return false }
        guard let latest = detail.latestRevision else { return true }
        return name.trimmingCharacters(in: .whitespacesAndNewlines) != detail.event.name
            || venue.trimmingCharacters(in: .whitespacesAndNewlines) != detail.event.venue
            || policy.requestBody() != ServerPolicyDraft(revision: latest).requestBody()
    }
    var validation: String? {
        if let reason = blockingReason() { return reason }
        if let error = brandingError(branding) { return error }
        if needsRefresh { return "Check Current Status before reviewing again. The previous action may have reached the server." }
        if mode == .localPrepaid { return prepaid.activePolicy.validationMessage }
        if conflict { return "Server Settings Changed — Review Required." }
        if loadedBinding != workspace.serverBinding { return "Check Current Status for this payments connection." }
        guard let detail, detail.event.id == selectedID else { return "Choose an event and load its settings." }
        if [.ended, .archived].contains(detail.event.lifecycle) { return "This event is closed. Choose or create another event." }
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Enter an event name." }
        if policy.commercialMode != .payPerPrint { return "This saved event is prepaid. Choose a pay-per-print event." }
        return policy.validationMessage()
    }

    private func persistSelection() {
        workspace.saveSessionSetup(.init(mode: mode, eventID: selectedID, serverBinding: workspace.serverBinding, branding: branding))
    }
    private func persistPaid() {
        guard !loading, let selectedID, let baseVersion else { return }
        workspace.saveServerDraft(.init(eventID: selectedID, serverBinding: workspace.serverBinding, baseVersion: baseVersion, name: name, venue: venue, policy: policy))
    }
    func refresh() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do {
            if mode == .localPrepaid, source() == .localPrepaid { needsRefresh = false; return }
            events = try await api().listEvents()
            if selectedID == nil {
                // Prefer the current event or an unpublished draft. Never changes its lifecycle.
                selectedID = events.first(where: { $0.lifecycle == "ACTIVE" })?.id
                    ?? events.first(where: { $0.lifecycle == "DRAFT" })?.id
            }
            if let selectedID { try await loadPaid(selectedID) }
            needsRefresh = false
        } catch { message = error.localizedDescription }
    }
    func select(_ id: String) async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        detail = nil; selectedID = id; persistSelection()
        do { try await loadPaid(id); needsRefresh = false } catch { message = error.localizedDescription }
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
    func create(name: String, venue: String) async {
        guard !busy, authorized(), !needsRefresh else { return }
        busy = true; defer { busy = false }
        do {
            let created = try await api().createEvent(name: name, venue: venue)
            selectedID = created.id; persistSelection()
            workspace.saveNewEvent(name: "", venue: "")
            try await loadPaid(created.id)
            events = try await api().listEvents()
            message = "New event saved. It is not accepting guests."
        } catch { needsRefresh = true; message = "Creation was not confirmed. Check Current Status and the event list before creating again. \(error.localizedDescription)" }
    }
    private func checkPermit(requireIdle: Bool = true) throws {
        guard authorized() else { throw SetupFailure("Unlock Operator again before continuing.") }
        if let operationBinding, operationBinding != workspace.serverBinding { throw SetupFailure("The payments connection changed. Review setup for the current connection.") }
        if requireIdle, let reason = blockingReason() { throw SetupFailure(reason) }
    }
    func saveOnly() async {
        guard !busy, authorized(), mode == .serverManaged, validation == nil else { return }
        busy = true; defer { busy = false }
        do { try await savePaid(); message = "Saved — Not Yet Applied. Guests keep the currently applied settings." }
        catch { await handleFailure(error) }
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
                run.activePolicy.commercialMode = .privatePrepaid; run.activePolicy.unitPriceCentavos = 0
                run.activePolicy.cashEnabled = false; run.activePolicy.qrPhEnabled = false; run.activePolicy.offlineValidUntil = nil
                run.lifecycle = .active; run.updatedAt = Date()
                try saveLocal(run); try applyBranding(branding)
                try checkPermit(); saveSource(.localPrepaid)
                try acceptance.save(.init(mode: .localPrepaid))
                prepaid = run; workspace.savePrepaidDraft(nil)
            } else {
                guard let id = selectedID, let expectedVersion = baseVersion else { throw SetupFailure("Choose an event.") }
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
                try checkPermit(); try applyBranding(branding); saveSource(.serverManaged)
                try acceptance.save(.init(blocked: false, eventID: id, serverBinding: workspace.serverBinding, mode: .serverManaged))
                baseVersion = event.event.version; workspace.removeServerDraft(eventID: id)
            }
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
