import Foundation
import Combine
import OSLog

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
    var unattendedQR: Bool? = nil
}

/// A durable, fail-closed barrier around multi-step operator transitions. It never grants a
/// payment entitlement. Existing installs retain their current behavior until an explicit action.
@MainActor final class SessionAcceptanceStore: ObservableObject {
    static let shared = SessionAcceptanceStore()
    nonisolated struct State: Codable, Equatable, Sendable {
        var blocked = false
        var eventID: String?
        var serverBinding: String?
        var mode: CommercialPolicySource?
        var boothMode: BoothOperatingMode? = nil
        var unattendedQR: Bool? = nil
        var startingEventID: String? = nil
        var startingBinding: String? = nil
    }
    @Published private(set) var state = State()
    @Published private(set) var storageError: String?
    @Published private(set) var setupOperationID: UUID?
    func beginSetupOperation() throws -> UUID {
        guard setupOperationID == nil else { throw SetupFailure("Event setup is still finishing on this iPad. Leaving the screen does not cancel it. Wait for its result before starting again.") }
        let id = UUID(); setupOperationID = id; return id
    }
    func finishSetupOperation(_ id: UUID) { if setupOperationID == id { setupOperationID = nil } }
    private let file: URL
    private var committing = false
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
        guard !committing else { throw SetupFailure("Session settings are still being saved.") }
        if let storageError { throw SetupFailure(storageError) }
        // A failed write must not allow another guest in this process.
        state.blocked = true
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try write(JSONEncoder().encode(next), file)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete, .posixPermissions: 0o600], ofItemAtPath: file.path)
        state = next
    }
    func saveAsync(_ next: State) async throws {
        guard !committing else { throw SetupFailure("Session settings are still being saved.") }
        if let storageError { throw SetupFailure(storageError) }
        committing = true; state.blocked = true
        defer { committing = false }
        let job = DurableJSONWrite(value: next, file: file, write: write)
        try await Task.detached(priority: .userInitiated) { try job.perform() }.value
        state = next
    }
    func permits(eventID: String, binding: String) -> Bool {
        !state.blocked && state.startingEventID == nil && (state.eventID == nil || (state.eventID == eventID && state.serverBinding == binding))
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
    func createEvent(name: String, venue: String, operationID: String) async throws -> OperatorCreatedEvent
    func eventCreation(operationID: String) async throws -> OperatorEventCreationLookup
    func saveDraft(eventID: String, expectedVersion: Int, name: String, venue: String, policy: ServerPolicyDraft.RequestBody) async throws -> OperatorEventUpdate
    func transitionEvent(id: String, action: String, expectedVersion: Int, policyRevisionID: String?, acknowledgedUnitPriceCentavos: Int?) async throws -> OperatorEventTransition
    func activeEvent() async throws -> ActiveEventResponse
}
extension PaymentsAPIClient: SessionSetupAPI {}

nonisolated enum EventSetupPhase: String, Sendable {
    case savingEvent = "Saving event", linkingPayments = "Linking payments", loadingSettings = "Loading settings"
    case activating = "Activating", verifying = "Verifying", completed = "Completed"
}

nonisolated struct EventSetupRequestTimeout: LocalizedError, Sendable {
    let phase: EventSetupPhase
    let mutation: Bool
    var errorDescription: String? {
        mutation
            ? "\(phase.rawValue) timed out. The server may have saved the change. Check its original status before trying again."
            : "\(phase.rawValue) timed out. Check Current Status to retry this read when the connection is ready."
    }
}

/// An absolute deadline supplements URLSession's inactivity timeout. Cancellation of a write
/// means an unknown outcome, never proof that the server cancelled or rolled it back.
nonisolated struct EventSetupRequests: SessionSetupAPI {
    let base: any SessionSetupAPI
    var timeout: TimeInterval = 15
    let progress: @MainActor @Sendable (EventSetupPhase) -> Void
    private func run<T: Sendable>(_ phase: EventSetupPhase, mutation: Bool = false,
                                 _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        await progress(phase)
        let started = Date()
        defer {
            Logger(subsystem: "com.pocketpixels.PocketPixelsBooth", category: "EventSetup")
                .info("phase=\(phase.rawValue, privacy: .public) mutation=\(mutation) duration_ms=\(Int(Date().timeIntervalSince(started) * 1000))")
        }
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(0.001, timeout) * 1_000_000_000))
                throw EventSetupRequestTimeout(phase: phase, mutation: mutation)
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
    func listEvents() async throws -> [OperatorEventSummary] { try await run(.loadingSettings) { try await base.listEvents() } }
    func eventDetail(id: String) async throws -> OperatorEventDetail { try await run(.loadingSettings) { try await base.eventDetail(id: id) } }
    func createEvent(name: String, venue: String, operationID: String) async throws -> OperatorCreatedEvent {
        try await run(.linkingPayments, mutation: true) { try await base.createEvent(name: name, venue: venue, operationID: operationID) }
    }
    func eventCreation(operationID: String) async throws -> OperatorEventCreationLookup {
        try await run(.verifying) { try await base.eventCreation(operationID: operationID) }
    }
    func saveDraft(eventID: String, expectedVersion: Int, name: String, venue: String, policy: ServerPolicyDraft.RequestBody) async throws -> OperatorEventUpdate {
        try await run(.savingEvent, mutation: true) { try await base.saveDraft(eventID: eventID, expectedVersion: expectedVersion, name: name, venue: venue, policy: policy) }
    }
    func transitionEvent(id: String, action: String, expectedVersion: Int, policyRevisionID: String?, acknowledgedUnitPriceCentavos: Int?) async throws -> OperatorEventTransition {
        try await run(.activating, mutation: true) { try await base.transitionEvent(id: id, action: action, expectedVersion: expectedVersion, policyRevisionID: policyRevisionID, acknowledgedUnitPriceCentavos: acknowledgedUnitPriceCentavos) }
    }
    func activeEvent() async throws -> ActiveEventResponse { try await run(.verifying) { try await base.activeEvent() } }
}

@MainActor enum SessionSetupSafety {
    enum RecoveryIssue: Equatable {
        case receiptCheck, interruptedGuest, storageUnavailable, interruptedCheckout, damagedPrintRecords, unfinishedSend, saveFailed

        var message: String {
            switch self {
            case .receiptCheck: "Check the previous receipt in Fix Printer before switching booth setup. It may already have printed."
            case .interruptedGuest: "Open Help & Recovery to finish or keep the interrupted guest session before switching booth setup."
            case .storageUnavailable: "Saved recovery records could not be opened. Open Help & Recovery before switching booth setup."
            case .interruptedCheckout: "Open Help & Recovery → Payment Recovery to Close Session & Continue or resume the original checkout."
            case .damagedPrintRecords: "Saved print records need review in Advanced → Payment Maintenance before switching booth setup."
            case .unfinishedSend: "Wait for the current receipt to finish before switching booth setup."
            case .saveFailed: "Recovery could not be saved. Open Help & Recovery and Retry Saving Resolution."
            }
        }

        var destination: OperatorWorkspaceRoute {
            switch self {
            case .receiptCheck, .interruptedGuest, .storageUnavailable, .unfinishedSend, .saveFailed: .recovery
            case .interruptedCheckout: .recovery
            case .damagedPrintRecords: .payments
            }
        }
    }

    enum Operation: CaseIterable {
        case openRegularBooth, startUnrelatedGuest, saveSettings, changeEvent, initiatePaidCheckout, sendCopy, changePaymentConnection
    }
    struct Decision: Equatable {
        let reason: String?
        let destination: OperatorWorkspaceRoute
        var allowed: Bool { reason == nil }
    }
    static func decision(for operation: Operation) -> Decision {
        decision(for: operation, activeGuest: EventOperationalState.shared.customerSessionActive || (ActiveGuestInteraction.model.map { $0.state != .welcome && $0.state != .thankYou } ?? false),
                 printerWorking: PrinterCoordinator.shared.isWorking,
                 needsReceiptCheck: EventOperationalState.shared.hasUnresolvedPrint || PrinterCoordinator.shared.requiresRecovery,
                 hasPendingSession: EventOperationalState.shared.hasPendingSessionRecovery,
                 checkpoints: .shared, outbox: .shared, currentCheckoutID: ActiveGuestInteraction.model?.sessionIdentifier)
    }
    static func decision(for operation: Operation, activeGuest: Bool, printerWorking: Bool, needsReceiptCheck: Bool,
                         hasPendingSession: Bool, checkpoints: CheckoutCheckpointStore?, outbox: PrintOutcomeOutbox?, currentCheckoutID: String? = nil) -> Decision {
        // Saving staged settings cannot mutate an admitted guest's frozen configuration.
        if operation == .saveSettings { return Decision(reason: nil, destination: .sessionSetup) }
        if operation == .changePaymentConnection {
            return Decision(reason: paymentConnectionChangeReason(activeGuest: activeGuest, printerWorking: printerWorking,
                needsReceiptCheck: needsReceiptCheck, hasPendingSession: hasPendingSession, checkpoints: checkpoints, outbox: outbox), destination: .payments)
        }
        if printerWorking { return Decision(reason: "Wait for the active print transport to finish. It cannot safely be closed while sending.", destination: .recovery) }
        if activeGuest && operation != .initiatePaidCheckout && operation != .sendCopy {
            return Decision(reason: "Close Session & Continue in Help & Recovery before changing operation.", destination: .recovery)
        }
        // The current guest owns its checkout and snapshot; those are not competing recovery.
        let pending = operation == .initiatePaidCheckout || operation == .sendCopy ? false : hasPendingSession
        var issue = recoveryIssue(needsReceiptCheck: needsReceiptCheck, hasPendingSession: pending, checkpoints: checkpoints, outbox: outbox)
        if operation == .initiatePaidCheckout || operation == .sendCopy, issue == .interruptedCheckout,
           checkpoints?.integrityFault == nil,
           checkpoints?.unresolved.contains(where: { !$0.isParked && $0.id != currentCheckoutID }) == false { issue = nil }
        return Decision(reason: issue?.message, destination: issue?.destination ?? .recovery)
    }
    static var blockingReason: String? { decision(for: .changeEvent).reason }
    /// Current financial or physical-print obligations, excluding historical outcome reports.
    static var recoveryReason: String? {
        currentRecoveryIssue?.message
    }

    static var recoveryDestination: OperatorWorkspaceRoute { currentRecoveryIssue?.destination ?? .payments }

    private static var currentRecoveryIssue: RecoveryIssue? {
        let operations = EventOperationalState.shared
        return recoveryIssue(needsReceiptCheck: operations.hasUnresolvedPrint || PrinterCoordinator.shared.requiresRecovery,
                              hasPendingSession: operations.hasPendingSessionRecovery,
                              checkpoints: CheckoutCheckpointStore.shared, outbox: PrintOutcomeOutbox.shared)
    }

    static func recoveryReason(needsReceiptCheck: Bool, hasPendingSession: Bool,
                               checkpoints: CheckoutCheckpointStore?, outbox: PrintOutcomeOutbox?) -> String? {
        recoveryIssue(needsReceiptCheck: needsReceiptCheck, hasPendingSession: hasPendingSession, checkpoints: checkpoints, outbox: outbox)?.message
    }

    static func recoveryIssue(needsReceiptCheck: Bool, hasPendingSession: Bool,
                              checkpoints: CheckoutCheckpointStore?, outbox: PrintOutcomeOutbox?) -> RecoveryIssue? {
        if needsReceiptCheck { return .receiptCheck }
        if hasPendingSession { return .interruptedGuest }
        guard let checkpoints, let outbox else { return .storageUnavailable }
        if checkpoints.integrityFault != nil { return .interruptedCheckout }
        if checkpoints.unresolved.contains(where: { !$0.isParked }) { return .interruptedCheckout }
        if outbox.integrityFault != nil { return .damagedPrintRecords }
        if outbox.persistenceFailure != nil { return .saveFailed }
        if !outbox.inspectionEntryIDs.isEmpty { return .receiptCheck }
        if outbox.hasUnfinishedPhysicalSend { return .unfinishedSend }
        // Reports contain their original session/entitlement identity. Sending them never prints,
        // and switching events cannot change their meaning. A retained uncertain outcome must
        // stay uncertain without becoming a permanent global lock after recovery was handled.
        return nil
    }

    static var paymentConnectionChangeReason: String? { decision(for: .changePaymentConnection).reason }

    static func paymentConnectionChangeReason(activeGuest: Bool, printerWorking: Bool, needsReceiptCheck: Bool, hasPendingSession: Bool,
                                             checkpoints: CheckoutCheckpointStore?, outbox: PrintOutcomeOutbox?) -> String? {
        if activeGuest || printerWorking { return "Finish the current guest session and print job before changing the payments connection." }
        if let issue = recoveryIssue(needsReceiptCheck: needsReceiptCheck, hasPendingSession: hasPendingSession, checkpoints: checkpoints, outbox: outbox) { return issue.message }
        if checkpoints?.unresolved.isEmpty == false || checkpoints?.all.contains(where: { $0.resolution?.hasPrefix("operator:") == true }) == true {
            return "Outstanding Payments belong to this payments connection. Reconcile the original checkouts before changing servers."
        }
        if outbox?.hasUnresolvedServerReports == true { return "Send or review saved print reports in Payment Maintenance before changing the payments connection." }
        return nil
    }
}

/// Staged settings and explicit operator orchestration; provider/payment/print logic stays elsewhere.
/// Event Mode, the event's saved design and the payment choice are independent decisions: any
/// payment choice works with or without Event Mode, and an event works with or without its logo.
@MainActor final class SessionSetupCoordinator: ObservableObject {
    nonisolated static let regularEventName = "Regular Sessions"

    @Published var unattendedQR = false { didSet { persistSelection() } }
    @Published var mode: CommercialPolicySource { didSet { persistSelection() } }
    @Published var eventModeEnabled: Bool { didSet { persistSelection() } }
    @Published private(set) var designID: String?
    /// The selected event's design draft. Edits stay here (and in the workspace) until Save Design
    /// or Start Accepting Guests; nothing reaches guests before activation.
    @Published var design: SavedEventDesign? { didSet { designDidChange(oldValue) } }
    @Published private(set) var requestedMethods: GuestPaymentChoice? { didSet { persistSelection() } }
    @Published var prepaid: CommercialEventRun {
        didSet {
            guard !loading else { return }
            workspace.savePrepaidDraft(SavedDraftDiff.prepaid(prepaid, loadLocal()).isEmpty ? nil : prepaid)
            if !loading, mode == .localPrepaid, eventModeEnabled, var next = design, next.prepaidPolicy != prepaid.activePolicy {
                next.prepaidPolicy = prepaid.activePolicy
                design = next
            }
        }
    }
    @Published var name = "" { didSet { persistPaid() } }
    @Published var venue = "" { didSet { persistPaid() } }
    @Published var policy = ServerPolicyDraft() { didSet { persistPaid() } }
    @Published private(set) var selectedID: String?
    @Published private(set) var detail: OperatorEventDetail?
    @Published private(set) var events: [OperatorEventSummary] = []
    @Published private(set) var message = ""
    @Published private(set) var busy = false
    @Published private(set) var phase: EventSetupPhase = .loadingSettings
    private var refreshTask: Task<Void, Never>?
    private var verifiedCreation: OperatorEventDetail?
    private let requestTimeout: TimeInterval
    let editingLiveEvent: Bool
    private var liveRunID: String?
    private var liveBaselineDesign: SavedEventDesign?
    private var liveDraftsBeforeEditing: OperatorWorkspace.Snapshot?
    private var liveLoadedPolicy = false
    @Published private(set) var conflict = false
    @Published private(set) var needsRefresh = false
    /// The operator's explicit choice to follow an ended occurrence with a fresh one.
    @Published var startsNewOccurrence = false
    private var baseVersion: Int?
    private let draftTarget: SavedDraftID?
    private var loading = false
    private var operationBinding: String?
    private var loadedBinding: String?
    private var pendingServerEventID: String?
    private let workspace: OperatorWorkspace
    private let acceptance: SessionAcceptanceStore
    let eventRuns: EventRunStore
    let library: EventDesignLibraryStore
    let creations: CommercialEventCreationStore
    private let makeAPI: @MainActor () throws -> any SessionSetupAPI
    private func api() throws -> any SessionSetupAPI {
        EventSetupRequests(base: try makeAPI(), timeout: requestTimeout, progress: { [weak self] in self?.phase = $0 })
    }
    private let authorized: @MainActor () -> Bool
    private let blockingReason: @MainActor () -> String?
    private let loadLocal: @MainActor () -> CommercialEventRun
    private let saveLocal: @MainActor (CommercialEventRun) throws -> Void
    private let source: @MainActor () -> CommercialPolicySource
    private let saveSource: @MainActor (CommercialPolicySource) -> Void
    private let currentProfile: @MainActor () -> EventProfile
    private let applyProfile: @MainActor (EventProfile) throws -> Void
    private let artworkAvailable: @MainActor (String?) -> Bool
    private var creationObserver: AnyCancellable?

    init(eventID: String? = nil, editingLiveEvent: Bool = false, requestTimeout: TimeInterval = 15, draftTarget: SavedDraftID? = nil, workspace: OperatorWorkspace? = nil, acceptance: SessionAcceptanceStore? = nil, library: EventDesignLibraryStore? = nil,
         eventRuns: EventRunStore? = nil, creations: CommercialEventCreationStore? = nil,
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
        self.editingLiveEvent = editingLiveEvent
        self.draftTarget = draftTarget
        self.workspace = workspace; self.acceptance = acceptance ?? .shared; self.library = library; self.eventRuns = eventRuns ?? .shared
        self.creations = creations ?? .shared
        self.makeAPI = api; self.requestTimeout = requestTimeout; self.authorized = authorized; self.blockingReason = blockingReason
        self.loadLocal = loadLocal; self.saveLocal = saveLocal; self.source = source; self.saveSource = saveSource
        self.currentProfile = currentProfile; self.applyProfile = applyProfile; self.artworkAvailable = artworkAvailable
        let staged = workspace.snapshot.sessionSetup
        let saved = library.library
        mode = eventID != nil ? .serverManaged : (staged?.mode ?? source())
        requestedMethods = staged?.requestedMethods
        unattendedQR = staged?.unattendedQR ?? self.acceptance.state.unattendedQR ?? false
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
        if let draftTarget {
            switch draftTarget {
            case .design(let id):
                requestedMethods = nil
                mode = .localPrepaid; eventModeEnabled = true; designID = id; selectedID = nil; pendingServerEventID = nil
            case .payment(_, let id):
                requestedMethods = nil
                mode = .serverManaged; eventModeEnabled = true; selectedID = id; pendingServerEventID = id
                designID = saved.design(linkedTo: id, binding: workspace.serverBinding)?.id
            case .prepaid:
                requestedMethods = nil
                mode = .localPrepaid; eventModeEnabled = saved.appliedEventModeEnabled; designID = saved.appliedEventID; selectedID = nil
            default: break
            }
        }
        design = designID.flatMap { workspace.designDraft(id: $0) ?? saved.design(id: $0) }
        if design == nil { designID = nil }
        if mode == .localPrepaid, workspace.snapshot.prepaidDraft == nil, let policy = design?.prepaidPolicy {
            loading = true; prepaid.activePolicy = policy; loading = false
        }
        if editingLiveEvent {
            liveDraftsBeforeEditing = workspace.snapshot
            loading = true
            mode = source(); eventModeEnabled = saved.appliedEventModeEnabled
            designID = saved.appliedEventID; selectedID = self.acceptance.state.eventID
            pendingServerEventID = nil; requestedMethods = nil
            prepaid = loadLocal()
            if var applied = saved.design(id: designID) {
                let profile = currentProfile().normalized()
                applied.profile = profile
                applied.name = profile.eventName.isEmpty ? applied.name : profile.eventName
                applied.venue = loadLocal().venue.isEmpty ? applied.venue : loadLocal().venue
                applied.personalizeReceipt = profile.isEnabled
                applied.guestScreensEnabled = profile.customerScreenEnabled
                design = applied
            }
            liveRunID = self.eventRuns.currentRunID
            liveBaselineDesign = design
            loading = false
        }
        creationObserver = self.creations.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    var workspaceForEditing: OperatorWorkspace { workspace }
    var acceptanceForPresentation: SessionAcceptanceStore { acceptance }

    // MARK: Payment choice

    /// "How will guests pay?" as one choice, mapped onto the existing policy model.
    var paymentChoice: GuestPaymentChoice {
        guard mode == .serverManaged else { return .noPayment }
        if detail != nil { return GuestPaymentChoice(qrPhEnabled: policy.qrPhEnabled, cashEnabled: policy.cashEnabled) }
        return requestedMethods ?? .qrOnly
    }

    func choosePayment(_ choice: GuestPaymentChoice) async {
        if choice != .qrOnly { unattendedQR = false }
        guard choice != paymentChoice else { return }
        if choice == .noPayment {
            mode = .localPrepaid
            if let policy = design?.prepaidPolicy {
                let wasLoading = loading
                loading = true; prepaid.activePolicy = policy; loading = wasLoading
            }
            return
        }
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

    var savedEvents: [SavedEventDesign] { library.library.events.filter { $0.archivedAt == nil && $0.removedAt == nil }.sorted { $0.updatedAt > $1.updatedAt } }

    /// Server events not yet linked to a saved event in this environment.
    var unlinkedServerEvents: [OperatorEventSummary] {
        let binding = workspace.serverBinding
        let known = library.library.knownServerEventIDs(binding: binding)
        return events.filter { !known.contains($0.id) && !["ENDED", "ARCHIVED"].contains($0.lifecycle) }
    }

    var designDirty: Bool {
        guard let design else { return false }
        return !SavedDraftDiff.design(design, library.design(id: design.id)).isEmpty
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
        if mode == .localPrepaid, let policy = design?.prepaidPolicy {
            let wasLoading = loading
            loading = true; prepaid.activePolicy = policy; loading = wasLoading
        }
        persistSelection()
    }

    /// Creates a new saved event (logo off). In a paid setup it is also connected to paid checkout.
    func createEvent(name: String, venue: String) async {
        if let refreshTask { await refreshTask.value }
        guard !busy else { message = "An event operation is still running. Wait for its result before creating another event."; return }
        if mode == .serverManaged, pendingCreation != nil { message = "Check Original Request before creating another paid event."; return }
        guard authorized() else { message = "Unlock Operator again before continuing."; return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { message = "Enter an event name."; return }
        busy = true; phase = .savingEvent
        do {
            let created = try await library.createAsync(name: trimmed, venue: venue)
            workspace.saveNewEvent(name: "", venue: "")
            eventModeEnabled = true
            selectDesign(created.id)
            message = "New event saved. It is not accepting guests."
            busy = false
            if mode == .serverManaged { await connectPaidCheckout() }
            else { phase = .completed }
        } catch { busy = false; message = error.localizedDescription }
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
            var value = design
            if let saved = library.design(id: design.id) {
                value.serverEvents = saved.serverEvents
                value.createdAt = saved.createdAt
            }
            try library.save(value)
            let saved = library.design(id: design.id)
            self.design = saved
            workspace.saveDesignDraft(nil, id: design.id)
            message = "Design saved — not yet applied. Guests keep the current design until you start accepting guests."
        } catch { message = error.localizedDescription }
    }

    /// Picks up design edits made through another screen (drafts are shared via the workspace).
    func reloadDesignFromStorage() {
        guard !editingLiveEvent else { return }
        guard let id = designID, let stored = workspace.designDraft(id: id) ?? library.design(id: id), stored != design else { return }
        design = stored
    }

    func discardDesignChanges() {
        guard authorized(), let id = design?.id, let saved = library.design(id: id) else { return }
        design = saved
        workspace.saveDesignDraft(nil, id: id)
    }

    private func designDidChange(_ old: SavedEventDesign?) {
        guard !loading else { return }
        guard let design else { return }
        if let old, old.venue != design.venue, design.profile.location == old.venue {
            var updated = design; updated.profile.location = design.venue; self.design = updated; return
        }
        let saved = library.design(id: design.id)
        workspace.saveDesignDraft(SavedDraftDiff.design(design, saved).isEmpty ? nil : design, id: design.id)
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
        studio.receiptDesign.footerStyleOverride = nil
        studio.galleryReceiptStyleOverride = nil
        studio.isEnabled = false
        studio.customerScreenEnabled = false
        return studio.normalized()
    }

    var logoIsUsable: Bool { design.map { artworkAvailable($0.logoIdentifier) } ?? false }

    // MARK: Validation and status

    var dirtyPaid: Bool {
        guard let detail else { return false }
        guard let latest = editingLiveEvent ? (detail.activePolicy ?? detail.latestRevision) : detail.latestRevision else { return true }
        let draft = OperatorServerSetupDraft(eventID: detail.event.id, serverBinding: workspace.serverBinding,
                                            baseVersion: baseVersion ?? detail.event.version, name: name, venue: venue, policy: policy)
        let baseline = PaymentDraftBaseline(name: detail.event.name, venue: detail.event.venue, policy: ServerPolicyDraft(revision: latest))
        return !SavedDraftDiff.payment(draft, baseline).isEmpty
    }
    /// The occurrence identity this setup would run under once started.
    var runContext: EventRunContext {
        let paid = mode == .serverManaged
        return EventRunContext(designID: eventModeEnabled ? designID : nil, commercialEventID: paid ? selectedID : nil,
                               serverBinding: paid ? workspace.serverBinding : nil,
                               name: eventModeEnabled ? (design?.displayName ?? name) : (paid ? (name.isEmpty ? Self.regularEventName : name) : "Regular Sessions"))
    }
    var occurrencePlan: EventOccurrencePlan { eventRuns.occurrencePlan(for: runContext) }

    /// Plain-language statement of what Start does to event-run statistics.
    var occurrenceSummary: String {
        switch occurrencePlan {
        case .createFirst: "Starts this iPad's first event run with fresh statistics."
        case .continueActive: "Continues the event run already in progress. Statistics keep counting."
        case .resumePaused: "Resumes the paused event run with the same statistics."
        case .requiresNewOccurrence: startsNewOccurrence
            ? "Starts a new occurrence with fresh statistics. The ended run keeps its history and reports."
            : "This event's run has ended. Turn on Start New Occurrence to begin fresh statistics; the ended run keeps its history."
        case .switchSetup(_, let status): [.active, .paused].contains(status)
            ? "Starts a new event run for this setup and completes the current run. Its history and reports are kept."
            : "Starts a new event run for this setup. Earlier runs keep their history."
        }
    }

    /// The selected paid event has ended, so reuse needs a fresh commercial event.
    var canStartNewPaidOccurrence: Bool {
        guard mode == .serverManaged, let detail, detail.event.id == targetServerEventID else { return false }
        return [.ended, .archived].contains(detail.event.lifecycle)
    }

    /// Saving a draft/design never changes guest admission or the active receipt snapshot.
    /// Recovery and active-session barriers apply only when publishing/activating it.
    var saveValidation: String? {
        if let error = library.storageError { return error }
        if mode == .serverManaged, needsRefresh { return "Check Current Status before saving paid settings again." }
        if eventModeEnabled {
            guard let design else { return "Choose or create an event, or turn off Event Mode." }
            if design.archivedAt != nil { return "This design is archived. Choose an active design." }
            if design.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Enter an event name." }
        }
        if mode == .localPrepaid { return prepaid.activePolicy.validationMessage }
        if conflict { return "Server Settings Changed — Review Required." }
        if pendingCreation != nil { return "A paid event may already have been created. Confirm it under Event Creation Needs Confirmation first." }
        if targetServerEventID == nil {
            return eventModeEnabled ? "Connect this event to paid checkout to set a price." : "Set up regular paid sessions to set a price."
        }
        if loadedBinding != workspace.serverBinding { return "Check Current Status for this payments connection." }
        guard let detail, detail.event.id == selectedID else { return "Loading paid settings… Check Current Status if this persists." }
        if [.ended, .archived].contains(detail.event.lifecycle) {
            return "This paid event has ended. Use Start New Paid Occurrence to reuse this design with a fresh paid event; the ended event keeps its sales."
        }
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Enter an event name." }
        if policy.commercialMode != .payPerPrint { return "This saved event is prepaid. Choose a pay-per-print event." }
        return policy.validationMessage()
    }

    var requiresPaymentReview: Bool { mode == .serverManaged || source() == .serverManaged }

    var validation: String? {
        if let reason = blockingReason() { return reason }
        if eventRuns.historyUnreadable { return eventRuns.storageError ?? "Event-run history could not be read." }
        if eventRuns.pendingTransition != nil { return "An earlier event change was interrupted. Check its status in Current Event first." }
        if needsRefresh { return "Check Current Status before reviewing again. The previous action may have reached the server." }
        if let reason = saveValidation { return reason }
        if eventModeEnabled, let design {
            if design.personalizeReceipt && !artworkAvailable(design.logoIdentifier) {
                return design.logoIdentifier == nil
                    ? "Add an event logo, or turn off Personalize Receipt."
                    : "The saved logo can’t be read. Choose another file, or turn off Personalize Receipt."
            }
        }
        return nil
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
        if editingLiveEvent {
            return design != liveBaselineDesign || (mode == .serverManaged && dirtyPaid)
                || (mode == .localPrepaid && prepaid.activePolicy != loadLocal().activePolicy)
                || unattendedQR != (acceptance.state.unattendedQR ?? false)
        }
        return designDirty || (mode == .serverManaged && dirtyPaid) || (mode == .localPrepaid && workspace.snapshot.prepaidDraft != nil)
    }

    private func persistSelection() {
        guard !loading else { return }
        if let draftTarget, draftTarget != .sessionSelection && draftTarget != .newEvent { return }
        let applied = library.library
        let sameDesignSelection = eventModeEnabled == applied.appliedEventModeEnabled
            && (!eventModeEnabled || designID == applied.appliedEventID)
        let samePaymentSelection = mode == source()
            && (mode != .serverManaged || (selectedID == acceptance.state.eventID
                && acceptance.state.serverBinding == workspace.serverBinding
                && unattendedQR == (acceptance.state.unattendedQR ?? false)
                && (requestedMethods == nil || requestedMethods == detail?.activePolicy.map {
                    GuestPaymentChoice(qrPhEnabled: $0.qrphEnabled, cashEnabled: $0.cashEnabled)
                })))
        // Pausing changes admission, not the applied setup. Viewing it isn't an unsaved edit.
        if sameDesignSelection && samePaymentSelection {
            workspace.saveSessionSetup(nil)
        } else {
            workspace.saveSessionSetup(.init(mode: mode, eventID: selectedID, serverBinding: workspace.serverBinding,
                                             eventModeEnabled: eventModeEnabled, designID: designID, requestedMethods: requestedMethods, unattendedQR: unattendedQR))
        }
    }
    private func persistPaid() {
        guard !loading, let selectedID, let baseVersion else { return }
        if !dirtyPaid && !conflict {
            workspace.removeServerDraft(eventID: selectedID)
            return
        }
        let existingBaseline = workspace.serverDraft(eventID: selectedID)?.baseline
        let baseline = existingBaseline ?? (detail.flatMap { value in
            guard value.event.version == baseVersion, let revision = value.latestRevision else { return nil as PaymentDraftBaseline? }
            return PaymentDraftBaseline(name: value.event.name, venue: value.event.venue, policy: ServerPolicyDraft(revision: revision))
        })
        workspace.saveServerDraft(.init(eventID: selectedID, serverBinding: workspace.serverBinding, baseVersion: baseVersion,
                                       name: name, venue: venue, policy: policy, baseline: baseline))
    }

    // MARK: Server events

    func refresh() async {
        if let refreshTask { await refreshTask.value; return }
        guard !busy else { return } // A mutation owns its own verification; never overlap it.
        let task = Task { await self.performRefresh() }
        refreshTask = task
        await task.value
        refreshTask = nil
    }

    private func performRefresh() async {
        if case .payment(let binding, _) = draftTarget, binding != workspace.serverBinding {
            needsRefresh = true
            message = "This draft belongs to a different payments connection. Reconnect before reviewing its server settings."
            return
        }
        guard !busy else { return }
        busy = true; defer { busy = false }
        do {
            if mode == .localPrepaid, source() == .localPrepaid { needsRefresh = false; return }
            if let pending = pendingServerEventID {
                pendingServerEventID = nil
                bindSelection(to: pending)
            }
            if targetServerEventID == nil {
                events = try await api().listEvents()
                adoptCommittedEventIfNeeded()
            }
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
        if let refreshTask { await refreshTask.value }
        guard !busy, authorized(), !needsRefresh, mode == .serverManaged, targetServerEventID == nil else { return }
        if let reason = creationBlocker { message = reason; return }
        busy = true; defer { busy = false }
        let binding = workspace.serverBinding
        do {
            if eventModeEnabled {
                guard var design else { throw SetupFailure("Choose or create an event first.") }
                guard !design.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SetupFailure("Enter an event name first.") }
                if library.design(id: design.id) == nil { try await library.saveAsync(design) }
                let intent = try await createCommercialEvent(name: design.displayName, venue: design.venue, purpose: .connectDesign(designID: design.id))
                try await completeLink(intent)
                design.serverEvents[binding] = intent.eventID
                self.design = design
            } else {
                events = try await api().listEvents()
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
                    try await library.setRegularServerEventAsync(reusable.id, binding: binding)
                } else {
                    let intent = try await createCommercialEvent(name: Self.regularEventName, venue: "", purpose: .regularSessions)
                    try await completeLink(intent)
                }
            }
            guard let target = targetServerEventID else { throw SetupFailure("The paid checkout link was not saved.") }
            selectedID = target; persistSelection()
            try await loadPaid(target)
            phase = .completed
            message = "Paid checkout ready. It is not accepting guests until you review and start."
        } catch {
            creationFailed(error, fallback: "Paid checkout was not confirmed. Check Current Status before trying again.")
        }
    }

    /// Reuses this design (or regular sessions) after its paid event ended: creates a fresh
    /// commercial event, moves the ended one to append-only history, and carries the reviewed
    /// price and methods into an unpublished draft. Nothing reaches guests until Start.
    func startNewPaidOccurrence() async {
        guard !busy, authorized(), !needsRefresh, canStartNewPaidOccurrence, let ended = detail else { return }
        if let reason = blockingReason() { message = reason; return }
        if let reason = creationBlocker { message = reason; return }
        busy = true; defer { busy = false }
        let carried = policy
        do {
            let eventName = eventModeEnabled ? (design?.displayName ?? name) : Self.regularEventName
            if eventModeEnabled, let design, library.design(id: design.id) == nil { try await library.saveAsync(design) }
            let intent = try await createCommercialEvent(name: eventName, venue: eventModeEnabled ? (design?.venue ?? "") : "",
                                                         purpose: .newOccurrence(designID: eventModeEnabled ? designID : nil, replacing: ended.event.id))
            try await completeLink(intent)
            guard let createdID = intent.eventID else { throw SetupFailure("The new paid event was not confirmed.") }
            selectedID = createdID; detail = nil; baseVersion = nil; persistSelection()
            try await loadPaid(createdID)
            policy = carried
            if policy.offlineValidUntil < Date() { policy.offlineCashEnabled = false }
            phase = .completed
            message = "New paid occurrence prepared as a draft. The ended event keeps its orders and reports. Review the price, then start."
        } catch {
            creationFailed(error, fallback: "The new paid occurrence was not confirmed. Check Current Status before trying again.")
        }
    }

    // MARK: Commercial-event creation recovery

    /// The unresolved paid-event creation on this payments connection, if any.
    var pendingCreation: CommercialEventCreationIntent? { creations.open(binding: workspace.serverBinding) }
    /// Unresolved creations on another connection (switch back to resolve them).
    var creationsElsewhere: [CommercialEventCreationIntent] { creations.openElsewhere(binding: workspace.serverBinding) }
    /// Draft paid events not linked to anything, offered for an explicit operator choice.
    var draftCandidatesForCreation: [OperatorEventSummary] { unlinkedServerEvents.filter { $0.lifecycle == "DRAFT" } }

    private var creationBlocker: String? {
        if creations.isUnreadable { return creations.storageError }
        if pendingCreation != nil { return "An earlier paid-event creation needs confirmation first. Nothing new was created." }
        return nil
    }

    /// Stable operation ID → durable intent → idempotent create → exact verification. The local
    /// link is made by the caller only after this returns a verified event.
    private func createCommercialEvent(name: String, venue: String, purpose: CommercialEventCreationIntent.Purpose) async throws -> CommercialEventCreationIntent {
        let binding = workspace.serverBinding
        let intent = CommercialEventCreationIntent(id: UUID().uuidString.lowercased(), serverBinding: binding, purpose: purpose,
                                                   name: name, venue: venue, createdAt: Date(), state: .requested)
        let client = try api()   // a configuration failure sends nothing, so it records nothing
        try await creations.beginAsync(intent)
        let created: OperatorCreatedEvent
        do {
            created = try await client.createEvent(name: name, venue: venue, operationID: intent.id)
        } catch let error as PaymentsAPIError where error.provesNoMutation {
            try? await creations.markNotCreatedAsync(id: intent.id, reason: "rejected: \(error.code ?? "request refused")")
            throw error
        }
        if let echoed = created.operationId, echoed != intent.id { throw SetupFailure("The server answered for a different request. Check the original request.") }
        // The response names the event on the connection the request was sent to.
        try await creations.markCreatedAsync(id: intent.id, eventID: created.id)
        guard workspace.serverBinding == binding else { throw SetupFailure("The payments connection changed. Switch back to finish linking the new paid event.") }
        let verified = try await api().eventDetail(id: created.id)
        guard verified.event.id == created.id else { throw PaymentsAPIError.invalidResponse }
        verifiedCreation = verified
        return creations.intent(id: intent.id) ?? intent
    }

    /// Saves the local link for a verified creation and closes it. Local only and repeatable:
    /// an already-saved link is recognised, and a conflicting link is refused, not replaced.
    private func completeLink(_ intent: CommercialEventCreationIntent) async throws {
        guard let eventID = intent.eventID, intent.state == .created || intent.state == .linked else { throw SetupFailure("The created paid event has not been confirmed.") }
        guard intent.serverBinding == workspace.serverBinding else { throw SetupFailure("This paid event belongs to a different payments connection. Switch back to link it.") }
        let binding = intent.serverBinding
        switch intent.purpose {
        case .connectDesign(let id):
            guard let saved = library.design(id: id) else { throw SetupFailure("The saved event for this paid event no longer exists. Review the draft instead.") }
            let current = saved.serverEventID(binding: binding)
            guard current == nil || current == eventID else { throw SetupFailure("This design was connected to another paid event meanwhile. Review the draft instead.") }
            if current == nil { try await library.linkAsync(designID: id, binding: binding, serverEventID: eventID) }
        case .regularSessions:
            let current = library.library.regularServerEvents[binding]
            guard current == nil || current == eventID else { throw SetupFailure("Regular sessions were connected to another paid event meanwhile. Review the draft instead.") }
            if current == nil { try await library.setRegularServerEventAsync(eventID, binding: binding) }
        case .newOccurrence(let id, let replacing):
            let current = id.map { library.design(id: $0)?.serverEventID(binding: binding) } ?? library.library.regularServerEvents[binding]
            if current != eventID {
                try await library.linkNewCommercialOccurrenceAsync(designID: id, binding: binding, expectedCurrent: replacing, newServerEventID: eventID)
            }
        }
        try await creations.markLinkedAsync(id: intent.id)
        if let id = intent.designID, id == designID, let stored = library.design(id: id) {
            design?.serverEvents = stored.serverEvents
            design?.retiredServerEvents = stored.retiredServerEvents
        }
    }

    private func creationFailed(_ error: Error, fallback: String) {
        if pendingCreation != nil {
            message = "Event creation needs confirmation: a paid event may already exist on the server. Use Check Original Request — nothing will be created again automatically. (\(error.localizedDescription))"
        } else {
            needsRefresh = true
            message = "\(fallback) \(error.localizedDescription)"
        }
    }

    /// Check Original Request: exact, read-only lookup of what the operation produced.
    func checkOriginalCreation() async {
        guard !busy, authorized(), let intent = pendingCreation else { return }
        busy = true; defer { busy = false }
        if intent.state == .created { message = "The original request created a paid event. Complete Linking to finish."; return }
        do {
            let found = try await api().eventCreation(operationID: intent.id)
            guard found.operationId == intent.id, workspace.serverBinding == intent.serverBinding else { throw PaymentsAPIError.invalidResponse }
            try await creations.markCreatedAsync(id: intent.id, eventID: found.event.id)
            message = "Found the paid event created by the original request (\(found.event.name), \(found.event.lifecycle.capitalized)). Complete Linking to finish."
        } catch let error as PaymentsAPIError where error.code == "creation_not_found" {
            do {
                try await creations.markNotCreatedAsync(id: intent.id, reason: "server: no event for this operation")
                message = "Confirmed: the original request did not create a paid event. You can create it again."
            } catch { message = error.localizedDescription }
        } catch let error as PaymentsAPIError where error.code == "not_found" {
            message = "This payments server can't look up the original request yet (it needs the creation-recovery update). Review Existing Draft to choose it explicitly, or ask the owner."
        } catch {
            message = "The original request couldn't be checked: \(error.localizedDescription) Nothing was changed; try again when online."
        }
    }

    /// Complete Linking: saves the local link for an exactly identified event.
    func completeCreationLinking() async {
        guard !busy, authorized(), let intent = pendingCreation, intent.state == .created, let eventID = intent.eventID else { return }
        busy = true; defer { busy = false }
        do {
            let fetched = try await api().eventDetail(id: eventID)
            guard fetched.event.id == eventID, workspace.serverBinding == intent.serverBinding else { throw SetupFailure("The payments connection changed.") }
            try await completeLink(intent)
            selectedID = eventID; verifiedCreation = fetched
            try await loadPaid(eventID)
            needsRefresh = false; phase = .completed
            message = "Linked. Review the paid settings before accepting guests."
        } catch { message = "Linking was not completed: \(error.localizedDescription) Nothing else was changed." }
    }

    /// Review Existing Draft: the operator explicitly chooses which existing draft the original
    /// request produced (for servers without exact lookup). Recorded with the operator's reason.
    func useDraftForPendingCreation(_ eventID: String, reason: String) async {
        guard !busy, authorized(), let intent = pendingCreation, intent.state == .requested,
              draftCandidatesForCreation.contains(where: { $0.id == eventID }) else { return }
        do {
            try creations.supersede(id: intent.id, reason: reason, selectedEventID: eventID)
            message = "Draft selected and recorded with your reason."
            await completeCreationLinking()
        } catch { message = error.localizedDescription }
    }

    /// Deliberately closes the original request without linking anything, with a recorded reason.
    /// Any draft it may have created stays on the server, listed, unable to accept guests.
    func abandonPendingCreation(reason: String) {
        guard !busy, authorized(), let intent = pendingCreation else { return }
        do {
            try creations.supersede(id: intent.id, reason: reason, selectedEventID: nil)
            message = "The original request was closed and recorded. Any draft it created stays listed under Paid Events and never accepts guests on its own."
        } catch { message = error.localizedDescription }
    }

    private func loadPaid(_ id: String) async throws {
        let binding = workspace.serverBinding
        let fetched: OperatorEventDetail
        if let verified = verifiedCreation, verified.event.id == id { fetched = verified; verifiedCreation = nil }
        else { fetched = try await api().eventDetail(id: id) }
        guard binding == workspace.serverBinding else { throw SetupFailure("The payments connection changed. Check Current Status.") }
        guard selectedID == id else { return }
        loading = true; defer { loading = false }
        detail = fetched
        loadedBinding = binding
        if editingLiveEvent, !liveLoadedPolicy {
            name = fetched.event.name; venue = fetched.event.venue
            policy = (fetched.activePolicy ?? fetched.latestRevision).map(ServerPolicyDraft.init(revision:)) ?? ServerPolicyDraft()
            baseVersion = fetched.event.version; conflict = false; liveLoadedPolicy = true
            if var applied = design { applied.name = name; applied.venue = venue; design = applied; liveBaselineDesign = applied }
        } else if let draft = workspace.serverDraft(eventID: id) {
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
        baseVersion = detail.event.version; conflict = false
        workspace.removeServerDraft(eventID: detail.event.id)
        persistPaid()
    }
    func discardPaidEdits() async {
        guard authorized(), let selectedID else { return }
        workspace.removeServerDraft(eventID: selectedID); await select(selectedID)
    }
    private func checkPermit(requireIdle: Bool = true) throws {
        guard authorized() else { throw SetupFailure("Unlock Operator again before continuing.") }
        if let operationBinding, operationBinding != workspace.serverBinding { throw SetupFailure("The payments connection changed. Review setup for the current connection.") }
        if requireIdle, let reason = blockingReason() { throw SetupFailure(reason) }
        if editingLiveEvent {
            guard let run = eventRuns.current, run.id == liveRunID, run.status == .active,
                  run.context.matches(runContext), source() == mode else {
                throw SetupFailure("The live event changed. Reopen Edit Live Event to review the current event.")
            }
        }
    }
    /// Saves everything without opening the booth: the event design locally and, for paid
    /// setups, the server event's settings. Guests keep the currently applied setup.
    func saveOnly() async {
        guard !busy, authorized() else { return }
        if let reason = saveValidation { message = reason; return }
        busy = true; defer { busy = false }
        do {
            stageReusablePrepaidPolicy()
            if eventModeEnabled, let design, designDirty {
                try await library.saveAsync(design)
                self.design = library.design(id: design.id)
                workspace.saveDesignDraft(nil, id: design.id)
            }
            if mode == .serverManaged { try await savePaid() }
            await workspace.flush()
            if let error = workspace.persistenceError { throw SetupFailure(error) }
            phase = .completed
            message = "Saved — Not Yet Applied. Guests keep the currently applied settings."
        } catch let failure as SetupFailure where mode == .localPrepaid {
            message = failure.localizedDescription
        } catch { await handleFailure(error) }
    }
    private func stageReusablePrepaidPolicy() {
        guard mode == .localPrepaid, eventModeEnabled, var next = design, next.prepaidPolicy != prepaid.activePolicy else { return }
        next.prepaidPolicy = prepaid.activePolicy
        design = next
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
    func applyLiveChanges() async -> Bool {
        guard editingLiveEvent else { message = "Open Edit Live Event from Current Event."; return false }
        let applied = await startAccepting()
        if applied {
            liveBaselineDesign = design
            liveDraftsBeforeEditing = workspace.snapshot
            message = "Changes applied to next sessions. The event and run IDs, existing guests and purchased entitlements are unchanged."
        }
        return applied
    }

    func clearMessage() { message = "" }

    func cancelLiveChanges() {
        guard editingLiveEvent, !busy else { return }
        guard !needsRefresh else { message = "Check Current Status before discarding edits; a server change may have committed."; return }
        loading = true
        design = liveBaselineDesign; prepaid = loadLocal(); requestedMethods = nil
        unattendedQR = acceptance.state.unattendedQR ?? false
        if let detail {
            name = detail.event.name; venue = detail.event.venue
            policy = (detail.activePolicy ?? detail.latestRevision).map(ServerPolicyDraft.init(revision:)) ?? ServerPolicyDraft()
            baseVersion = detail.event.version
        }
        loading = false; conflict = false
        if let original = liveDraftsBeforeEditing {
            workspace.restoreEventDrafts(from: original, designID: designID, eventID: selectedID)
        }
        message = "Changes cancelled. The live event keeps its applied settings."
    }

    /// Called only from the reviewed setup's explicit confirmation. Failure leaves the barrier closed.
    func startAccepting() async -> Bool {
        if let refreshTask { await refreshTask.value }
        guard !busy else { message = "The current event operation is still running."; return false }
        if let reason = validation { message = reason; return false }
        let operation: UUID
        do { operation = try acceptance.beginSetupOperation() }
        catch { message = error.localizedDescription; return false }
        phase = .savingEvent
        busy = true; operationBinding = workspace.serverBinding
        defer { busy = false; operationBinding = nil; acceptance.finishSetupOperation(operation) }
        do {
            try checkPermit()
            if unattendedQR && paymentChoice != .qrOnly { throw SetupFailure("Unattended operation requires QR Ph only. Choose QR Ph only or turn off Unattended.") }
            if eventModeEnabled, library.design(id: designID)?.archivedAt != nil { throw SetupFailure("The selected design was archived. Choose an active design before applying this setup.") }
            // Decide the occurrence before any change, so an ended run can't be silently reopened.
            let plannedContext = runContext
            let plan = eventRuns.occurrencePlan(for: plannedContext)
            if editingLiveEvent, plan != .continueActive(runID: liveRunID ?? "") {
                throw SetupFailure("The event is no longer running. Reopen Current Event before applying changes.")
            }
            if case .requiresNewOccurrence = plan, !startsNewOccurrence {
                message = "This event's run has ended. Choose Start New Occurrence to begin fresh statistics; the ended run keeps its history."
                return false
            }
            // The reviewed design is saved first; saving never changes what guests receive.
            stageReusablePrepaidPolicy()
            if eventModeEnabled, let design, designDirty {
                try await library.saveAsync(design)
                self.design = library.design(id: design.id)
                workspace.saveDesignDraft(nil, id: design.id)
            }
            let profile = effectiveProfile
            // A guest may have arrived while the staged design was being flushed. Recheck
            // before closing admission; it keeps its original snapshot and the booth stays open.
            try checkPermit()
            try await acceptance.saveAsync(.init(blocked: true, eventID: acceptance.state.eventID, serverBinding: acceptance.state.serverBinding, mode: source(), startingEventID: mode == .serverManaged ? selectedID : nil, startingBinding: mode == .serverManaged ? workspace.serverBinding : nil))
            let nextAcceptance: SessionAcceptanceStore.State
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
                nextAcceptance = .init(mode: .localPrepaid, boothMode: .event)
                prepaid = run; workspace.savePrepaidDraft(nil)
            } else {
                guard let id = selectedID, id == targetServerEventID, let expectedVersion = baseVersion else { throw SetupFailure("Choose an event.") }
                if editingLiveEvent, !dirtyPaid, detail?.event.lifecycle == .active {
                    try checkPermit(); try applyProfile(profile)
                    nextAcceptance = .init(eventID: id, serverBinding: workspace.serverBinding, mode: .serverManaged, boothMode: .event, unattendedQR: unattendedQR)
                } else {
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
                nextAcceptance = .init(blocked: false, eventID: id, serverBinding: workspace.serverBinding, mode: .serverManaged, boothMode: .event, unattendedQR: unattendedQR)
                baseVersion = event.event.version; workspace.removeServerDraft(eventID: id)
                }
            }
            // Applied identity now anchors durable run reports. Commit it before opening admission.
            try await library.recordAppliedAsync(eventModeEnabled: eventModeEnabled, eventID: designID)
            guard runContext.matches(plannedContext) else { throw SetupFailure("The selected event changed while starting. Review setup again.") }
            // The occurrence is committed before admission opens; the first guest never creates it.
            try await eventRuns.commitStartAsync(context: plannedContext, expected: plan, allowNewOccurrence: startsNewOccurrence)
            try await acceptance.saveAsync(nextAcceptance)
            requestedMethods = nil; startsNewOccurrence = false
            workspace.saveSessionSetup(nil)
            await workspace.flush()
            phase = .completed
            message = "Accepting guests. The next session will use the reviewed setup."
            return true
        } catch { await handleFailure(error); return false }
    }
    /// Pause This Booth: closes admission on this iPad only. A server-managed event stays open
    /// for other booths; pausing the commercial event is a separate, explicit action.
    func pause() async {
        guard acceptance.setupOperationID == nil else { message = "Event setup is still finishing. Wait for its result before pausing."; return }
        guard !busy else { return }
        busy = true; defer { busy = false }
        do {
            try checkPermit(requireIdle: false)
            try await acceptance.saveAsync(.init(blocked: true, eventID: acceptance.state.eventID, serverBinding: acceptance.state.serverBinding, mode: source()))
            if source() == .localPrepaid {
                var run = loadLocal(); run.lifecycle = .paused; run.updatedAt = Date(); try saveLocal(run)
            }
            if let current = eventRuns.current, current.status == .active { try eventRuns.pauseCurrentRunForAdmission() }
            message = source() == .serverManaged
                ? "This booth is paused. The paid event stays open for other booths. Previously authorized purchases remain recoverable."
                : "New sessions paused. Previously authorized purchases remain recoverable."
        } catch {
            message = "This booth's pause was not fully saved: \(error.localizedDescription)"
            if acceptance.state.blocked { message += " New sessions on this iPad remain paused." }
        }
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
    /// A valid prepaid setup that was paused on this iPad.
    static func localConfigurationIsPaused(_ local: CommercialEventRun) -> Bool {
        local.lifecycle == .paused && local.activePolicy.commercialMode == .privatePrepaid && local.activePolicy.validationMessage == nil
    }
}
