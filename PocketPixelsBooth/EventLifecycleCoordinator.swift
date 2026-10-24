import Foundation
import Combine

// MARK: - Operator-facing status

/// What the server says about the commercial event an occurrence is linked to.
nonisolated struct CommercialEventCheck: Equatable, Sendable {
    let eventID: String
    let lifecycle: CommercialEventLifecycle?
    /// The account's single active event is this one.
    let isAccountActiveEvent: Bool
    let checkedAt: Date
}

nonisolated enum CommercialCheckState: Equatable, Sendable {
    case notNeeded
    case checking
    case confirmed(CommercialEventCheck)
    /// The payments server answered that the event doesn't exist for this account.
    case notFound(eventID: String)
    case unavailable(String)
}

/// One truthful status derived from every state owner that affects guest admission. It never
/// treats a local `.active` run, or an active server event, as proof that guests are accepted.
nonisolated enum EventOperatorStatus: Equatable, Sendable {
    case noEvent
    case regular
    case draft
    case ready
    case starting
    case accepting
    case unconfirmed(String)
    case pausedOnBooth
    case serverPaused
    case needsReview(String)
    case ending
    case completed
    case archived
    case recoveryRequired(String)

    var title: String {
        switch self {
        case .noEvent: "No Event Configured"
        case .regular: "Regular Booth"
        case .draft: "Draft — Not Started"
        case .ready: "Ready to Start"
        case .starting: "Starting…"
        case .accepting: "Accepting Guests"
        case .unconfirmed: "Server Status Not Confirmed"
        case .pausedOnBooth: "Paused on This iPad"
        case .serverPaused: "Commercial Event Paused"
        case .needsReview: "Needs Attention"
        case .ending: "Ending…"
        case .completed: "Event Ended"
        case .archived: "Event Archived"
        case .recoveryRequired: "Recovery Required"
        }
    }

    var detail: String {
        switch self {
        case .noEvent: "Review the saved booth configuration. Return to Regular Booth when no event is in control."
        case .regular: "Ready for guests · No payment required · Standard Made to Keep branding"
        case .draft: "Setup changes are saved but not started. Guests can't start yet."
        case .ready: "Review the setup and start when you're ready."
        case .starting: "Checking every setting before guests can start."
        case .accepting: "Guests can start new sessions on this iPad."
        case .unconfirmed(let reason): "This iPad is open to guests, but the payments server could not be checked: \(reason)"
        case .pausedOnBooth: "New sessions are paused on this iPad only. Other booths are not affected."
        case .serverPaused: "The paid event is paused for every booth. Paid purchases remain recoverable."
        case .needsReview(let reason), .recoveryRequired(let reason): reason
        case .ending: "Closing guest admission and confirming the event has ended."
        case .completed: "History and reports are kept. Choose Return to Regular Booth to finish the saved transition."
        case .archived: "Hidden from everyday use. Reports remain in Event History."
        }
    }

    var systemImage: String {
        switch self {
        case .accepting, .regular: "checkmark.circle.fill"
        case .pausedOnBooth, .serverPaused: "pause.circle.fill"
        case .starting, .ending: "hourglass"
        case .completed: "flag.checkered"
        case .archived: "archivebox"
        case .needsReview, .unconfirmed: "exclamationmark.circle.fill"
        case .recoveryRequired: "exclamationmark.octagon.fill"
        case .noEvent, .draft, .ready: "circle.dashed"
        }
    }

    var isAccepting: Bool { self == .accepting || self == .regular }
    var isWarning: Bool {
        switch self { case .needsReview, .recoveryRequired, .unconfirmed: true; default: false }
    }
}

nonisolated struct EventStatusInputs: Sendable {
    var run: EventRunRecord?
    var appliedContext: EventRunContext
    var barrierBlocked: Bool
    var acceptanceEventID: String?
    var acceptanceBinding: String?
    var binding: String
    var source: CommercialPolicySource
    var localPrepaidReady: Bool
    var commercial: CommercialCheckState
    var recoveryReason: String?
    var storageErrors: [String]
    var pendingTransition: EventTransitionIntent?
    var hasUnsavedSetup: Bool
    var operation: EventLifecycleCoordinator.Operation?
    /// The local prepaid policy is valid but paused (Pause This Booth before runs existed).
    var localPrepaidPaused = false
    var regularMode = false
}

nonisolated enum EventStatusModel {
    static func derive(_ input: EventStatusInputs) -> EventOperatorStatus {
        if let error = input.storageErrors.first { return .recoveryRequired(error) }
        switch input.operation {
        case .starting: return .starting
        case .ending: return .ending
        default: break
        }
        if let pending = input.pendingTransition {
            let action: String = switch pending.kind {
            case .endCommercialEvent: "Ending the paid event"
            case .pauseCommercialEvent: "Pausing the paid event"
            case .returnToRegular: "Returning to Regular Booth"
            }
            return .recoveryRequired("\(action) was interrupted before it was confirmed. Check Status to finish it; nothing will be repeated automatically.")
        }
        if input.regularMode {
            if let reason = input.recoveryReason { return .needsReview(reason) }
            return input.barrierBlocked ? .pausedOnBooth : .regular
        }
        guard let run = input.run else { return withoutRun(input) }
        switch run.status {
        case .archived: return .archived
        case .completed: return .completed
        case .draft: return .ready
        case .active, .paused: break
        }
        if case .notFound(let id) = input.commercial, id == run.context.commercialEventID {
            return .needsReview(notFoundReason)
        }
        if !run.context.matches(input.appliedContext) {
            return .needsReview("The applied setup no longer matches the running event. Review and start it in Event Setup.")
        }
        if run.status == .paused || input.barrierBlocked {
            if case .confirmed(let check) = input.commercial, check.eventID == run.context.commercialEventID {
                if check.lifecycle == .ended || check.lifecycle == .archived { return .needsReview("The paid event was ended for every booth. Finish ending this iPad's run.") }
                if check.lifecycle == .paused { return .serverPaused }
            }
            return .pausedOnBooth
        }
        if let reason = input.recoveryReason { return .needsReview(reason) }
        if input.source == .localPrepaid {
            guard run.context.commercialEventID == nil else { return .needsReview("This run belongs to a paid event, but the booth is set to no payment. Review Event Setup.") }
            return input.localPrepaidReady ? .accepting : .needsReview("Prepaid settings need review in Event Setup.")
        }
        guard let eventID = run.context.commercialEventID, run.context.serverBinding == input.binding else {
            return .needsReview("This run belongs to a different payments connection. Review Event Setup.")
        }
        guard input.acceptanceEventID == nil || (input.acceptanceEventID == eventID && input.acceptanceBinding == input.binding) else {
            return .needsReview("This iPad was started for a different paid event. Review Event Setup.")
        }
        switch input.commercial {
        case .notNeeded, .checking: return .unconfirmed("checking now")
        case .unavailable(let reason): return .unconfirmed(reason)
        case .notFound: return .needsReview(notFoundReason)
        case .confirmed(let check):
            guard check.eventID == eventID else { return .unconfirmed("the checked event differs") }
            switch check.lifecycle {
            case .active?: return check.isAccountActiveEvent ? .accepting : .needsReview("Another paid event is active for this account.")
            case .paused?: return .serverPaused
            case .ended?, .archived?: return .needsReview("The paid event was ended for every booth. Finish ending this iPad's run.")
            case .draft?: return .needsReview("The paid event has not been started. Review and start it in Event Setup.")
            case nil: return .unconfirmed("lifecycle not reported")
            }
        }
    }

    static let notFoundReason = "The paid event this iPad was started for was not found on this payments connection (wrong environment or account?). Review Event Setup."

    /// An install upgraded from a build without event runs can be running an event with no run
    /// recorded yet. The committed admission barrier is the evidence of what this iPad was started
    /// for; the server confirms its lifecycle. A legitimate running event is never "unconfigured",
    /// and an identity that can't be established is shown as needing review, never as success.
    private static func withoutRun(_ input: EventStatusInputs) -> EventOperatorStatus {
        if input.source == .localPrepaid {
            if !input.barrierBlocked, input.localPrepaidReady { return input.recoveryReason.map { .needsReview($0) } ?? .accepting }
            if input.barrierBlocked, input.localPrepaidPaused { return .pausedOnBooth }
            return input.hasUnsavedSetup ? .draft : .noEvent
        }
        guard let eventID = input.acceptanceEventID else {
            // Admission open with no committed paid event: guests would be admitted for whatever
            // event is active on the account. That identity is not proven for this iPad.
            if input.barrierBlocked { return input.hasUnsavedSetup ? .draft : .noEvent }
            return .needsReview("Guests can start paid sessions, but this iPad has no record of which paid event it was started for. Review and start the event in Event Setup.")
        }
        guard input.acceptanceBinding == input.binding else {
            return .needsReview("This iPad was started for a paid event on a different payments connection. Review Event Setup.")
        }
        switch input.commercial {
        case .notNeeded, .checking: return input.barrierBlocked ? .pausedOnBooth : .unconfirmed("checking now")
        case .unavailable(let reason): return input.barrierBlocked ? .pausedOnBooth : .unconfirmed(reason)
        case .notFound: return .needsReview(notFoundReason)
        case .confirmed(let check):
            guard check.eventID == eventID else { return .unconfirmed("the checked event differs") }
            switch check.lifecycle {
            case .active?:
                if input.barrierBlocked { return .pausedOnBooth }
                // Same rule as with a run: preserved payment or print obligations need review first.
                if let reason = input.recoveryReason { return .needsReview(reason) }
                return check.isAccountActiveEvent ? .accepting : .needsReview("Another paid event is active for this account.")
            case .paused?: return .serverPaused
            case .ended?, .archived?: return .needsReview("The paid event this iPad was started for has ended. Choose Return to Regular Booth after reviewing recovery; its sales are kept.")
            case .draft?: return .needsReview("The paid event has not been started. Review and start it in Event Setup.")
            case nil: return .unconfirmed("lifecycle not reported")
            }
        }
    }
}

// MARK: - Coordinator

/// The single orchestration point for an occurrence's lifecycle on this iPad. It composes the
/// existing owners — the run journal, the durable admission barrier, the local prepaid policy and
/// the authoritative Payments Worker — and never becomes a second payment or print authority.
@MainActor final class EventLifecycleCoordinator: ObservableObject {
    nonisolated enum Operation: Equatable, Sendable { case starting, pausing, ending, checking }
    nonisolated enum EndScope: Equatable, Sendable {
        /// Closes this iPad's occurrence. A shared commercial event stays open for other booths.
        case thisBooth
        /// Also ends the commercial event for every booth, after server confirmation.
        case thisBoothAndCommercialEvent
    }

    @Published private(set) var commercial: CommercialCheckState = .notNeeded
    @Published private(set) var operation: Operation?
    @Published private(set) var message = ""
    @Published private(set) var lastCheckedAt: Date?

    let runs: EventRunStore
    var acceptanceForPresentation: SessionAcceptanceStore { acceptance }
    private let acceptance: SessionAcceptanceStore
    private let api: @MainActor () throws -> any SessionSetupAPI
    private let authorized: @MainActor () -> Bool
    private let blockingReason: @MainActor () -> String?
    private let recoveryReason: @MainActor () -> String?
    private let source: @MainActor () -> CommercialPolicySource
    private let loadLocal: @MainActor () -> CommercialEventRun
    private let saveLocal: @MainActor (CommercialEventRun) throws -> Void
    private let binding: @MainActor () -> String
    private let appliedContext: @MainActor () -> EventRunContext
    private let hasUnsavedSetup: @MainActor () -> Bool
    private let makeSetup: @MainActor () -> SessionSetupCoordinator
    private var checkRequest = UUID()
    private let applyRegularConfiguration: @MainActor () throws -> Void

    init(runs: EventRunStore? = nil, acceptance: SessionAcceptanceStore? = nil,
         api: @escaping @MainActor () throws -> any SessionSetupAPI = {
             guard let c = PaymentsConfiguration.current() else { throw SetupFailure("Pair this iPad in Advanced → Payment Maintenance first.") }
             return PaymentsAPIClient(configuration: c)
         },
         authorized: @escaping @MainActor () -> Bool = { OperatorAccessPermit.shared.isAuthorized },
         blockingReason: @escaping @MainActor () -> String? = { SessionSetupSafety.blockingReason },
         recoveryReason: @escaping @MainActor () -> String? = { SessionSetupSafety.recoveryReason },
         source: @escaping @MainActor () -> CommercialPolicySource = { CommercialPolicySource.load() },
         loadLocal: @escaping @MainActor () -> CommercialEventRun = { CommercialEventRunStore.load() },
         saveLocal: @escaping @MainActor (CommercialEventRun) throws -> Void = { try CommercialEventRunStore.publish($0) },
         binding: @escaping @MainActor () -> String = { OperatorWorkspace.shared.serverBinding },
         appliedContext: @escaping @MainActor () -> EventRunContext = { EventRunStore.currentContext() },
         hasUnsavedSetup: @escaping @MainActor () -> Bool = { OperatorWorkspace.shared.hasUnsavedEventSetup },
         makeSetup: @escaping @MainActor () -> SessionSetupCoordinator = { SessionSetupCoordinator() },
         applyRegularConfiguration: @escaping @MainActor () throws -> Void = {
             try EventDesignLibraryStore.shared.recordApplied(eventModeEnabled: false, eventID: nil)
             EventProfileStore.save(.pocketPixelsDefault)
             CommercialPolicySource.save(.localPrepaid)
         }) {
        self.applyRegularConfiguration = applyRegularConfiguration
        self.runs = runs ?? .shared; self.acceptance = acceptance ?? .shared
        self.api = api; self.authorized = authorized; self.blockingReason = blockingReason; self.recoveryReason = recoveryReason
        self.source = source; self.loadLocal = loadLocal; self.saveLocal = saveLocal; self.binding = binding
        self.appliedContext = appliedContext; self.hasUnsavedSetup = hasUnsavedSetup; self.makeSetup = makeSetup
    }

    var status: EventOperatorStatus {
        let local = loadLocal()
        if acceptance.state.startingEventID != nil {
            return .recoveryRequired("Starting the paid event was interrupted. Review and finish Start in Event Setup before changing operation. No free fallback is enabled.")
        }
        // A failed statistics write is shown as a warning; only unreadable state blocks operation.
        let errors = [runs.historyUnreadable ? runs.storageError : nil, acceptance.storageError].compactMap { $0 }
        return EventStatusModel.derive(.init(run: runs.current, appliedContext: appliedContext(), barrierBlocked: acceptance.state.blocked,
            acceptanceEventID: acceptance.state.eventID, acceptanceBinding: acceptance.state.serverBinding, binding: binding(), source: source(),
            localPrepaidReady: SessionAdmission.localConfigurationIsReady(source: .localPrepaid, local: local),
            commercial: commercial, recoveryReason: recoveryReason(), storageErrors: errors,
            pendingTransition: runs.pendingTransition, hasUnsavedSetup: hasUnsavedSetup(), operation: operation,
            localPrepaidPaused: SessionAdmission.localConfigurationIsPaused(local),
            regularMode: RegularBoothMode.isEnabled(acceptance: acceptance, runs: runs)))
    }

    /// The paid event linked to the current occurrence, when it belongs to this connection. With
    /// no run yet (an upgraded install), the paid event this iPad's admission was committed for.
    var linkedCommercialEventID: String? {
        if let run = runs.current {
            guard let id = run.context.commercialEventID, run.context.serverBinding == binding() else { return nil }
            return id
        }
        guard source() == .serverManaged, let id = acceptance.state.eventID, acceptance.state.serverBinding == binding() else { return nil }
        return id
    }

    /// An upgraded install that is running (or paused in) an event with no run recorded yet.
    var canRecordUpgradedRun: Bool {
        guard acceptance.state.boothMode != .regular, runs.current == nil, runs.pendingTransition == nil, !runs.historyUnreadable else { return false }
        switch status { case .accepting, .unconfirmed, .pausedOnBooth, .serverPaused: return true; default: return false }
    }

    /// The commercial lifecycle as last confirmed by the server, if it was checked.
    var confirmedCommercialLifecycle: CommercialEventLifecycle? {
        if case .confirmed(let check) = commercial { return check.lifecycle }
        return nil
    }

    // MARK: Read-only status and reconciliation

    /// Reads authoritative state. Never mutates the server; resolves an interrupted transition
    /// only from a confirmed read-back.
    func refresh() async {
        let request = UUID(); checkRequest = request
        if let pending = runs.pendingTransition, pending.returnsToRegular == true, pending.serverConfirmed == true {
            do { try commitRegular(pending) } catch { message = "Finish Ending Event: \(error.localizedDescription)" }
            return
        }
        guard let eventID = runs.pendingTransition?.commercialEventID ?? linkedCommercialEventID else {
            commercial = .notNeeded; return
        }
        let expectedBinding = binding()
        commercial = .checking
        do {
            let client = try api()
            var check: CommercialEventCheck?
            if let active = try? await client.activeEvent(), active.event?.id == eventID {
                check = .init(eventID: eventID, lifecycle: .active, isAccountActiveEvent: true, checkedAt: Date())
            }
            if check == nil {
                let detail = try await client.eventDetail(id: eventID)
                check = .init(eventID: eventID, lifecycle: detail.event.lifecycle, isAccountActiveEvent: false, checkedAt: Date())
            }
            guard checkRequest == request, binding() == expectedBinding, let check else { return }
            commercial = .confirmed(check); lastCheckedAt = check.checkedAt
            reconcilePending(with: check)
        } catch {
            guard checkRequest == request, binding() == expectedBinding else { return }
            if case .rejected(_, _, 404, _) = error as? PaymentsAPIError { commercial = .notFound(eventID: eventID); lastCheckedAt = Date(); return }
            commercial = .unavailable(error.localizedDescription)
        }
    }

    private func reconcilePending(with check: CommercialEventCheck) {
        guard let pending = runs.pendingTransition, pending.commercialEventID == check.eventID, pending.serverBinding == binding() else { return }
        do {
            switch (pending.kind, check.lifecycle) {
            case (.endCommercialEvent, .ended?), (.endCommercialEvent, .archived?):
                if pending.returnsToRegular == true {
                    var confirmed = pending; confirmed.serverConfirmed = true
                    try runs.beginTransition(confirmed); try commitRegular(confirmed)
                } else {
                    try completeLocalRun(for: pending)
                    try runs.clearTransition(id: pending.id)
                }
                message = "Confirmed: the paid event has ended. This iPad's run is complete; history and reports are kept."
            case (.returnToRegular, _):
                // This intent records an explicit local-only end; a successful scoped read verifies
                // the original event without changing it for the other booths.
                guard check.lifecycle != nil else { throw SetupFailure("Paid event status is unknown.") }
                var confirmed = pending; confirmed.serverConfirmed = true
                try runs.beginTransition(confirmed); try commitRegular(confirmed)
            case (.pauseCommercialEvent, .paused?):
                try runs.clearTransition(id: pending.id)
                message = "Confirmed: the paid event is paused for every booth."
            case (.pauseCommercialEvent, .ended?), (.pauseCommercialEvent, .archived?):
                try runs.clearTransition(id: pending.id)
                message = "The paid event has ended elsewhere. Finish ending this iPad's run."
            default:
                message = "The earlier change was not applied: the paid event is \(check.lifecycle?.displayName ?? "unknown"). Review, then try again explicitly."
                try runs.clearTransition(id: pending.id)
            }
        } catch { message = "Status confirmed, but this iPad's records could not be updated: \(error.localizedDescription)" }
    }

    private func completeLocalRun(for pending: EventTransitionIntent) throws {
        guard let current = runs.current, current.id == pending.runID, [.active, .paused].contains(current.status) else { return }
        try closeAdmission()
        try runs.transition(id: current.id, to: .completed)
    }

    private func closeAdmission() throws {
        var barrier = acceptance.state; barrier.blocked = true
        try acceptance.save(barrier)
    }

    // MARK: Pause

    /// Pause This Booth. Closes admission on this iPad only; it never changes a shared paid event.
    func pauseBooth() async {
        guard operation == nil else { return }
        guard authorized() else { message = "Unlock Operator again before continuing."; return }
        operation = .pausing; defer { operation = nil }
        do {
            try closeAdmission()
            if source() == .localPrepaid { var local = loadLocal(); local.lifecycle = .paused; local.updatedAt = Date(); try saveLocal(local) }
            try runs.pauseCurrentRunForAdmission()
            message = linkedCommercialEventID == nil
                ? "This booth is paused. Paid purchases and print recovery are preserved."
                : "This booth is paused. The paid event stays open for other booths. Paid purchases and print recovery are preserved."
        } catch {
            message = "Pause not fully saved: \(error.localizedDescription)" + (acceptance.state.blocked ? " New sessions on this iPad remain paused." : "")
        }
    }

    /// Pause Commercial Event. An explicit, server-wide transition for every booth on the event.
    func pauseCommercialEvent() async {
        guard operation == nil else { return }
        guard authorized() else { message = "Unlock Operator again before continuing."; return }
        guard let eventID = linkedCommercialEventID else { message = "This run has no paid event to pause."; return }
        operation = .pausing; defer { operation = nil }
        let intent = EventTransitionIntent(id: UUID().uuidString.lowercased(), kind: .pauseCommercialEvent, runID: runs.current?.id,
                                           commercialEventID: eventID, serverBinding: binding(), createdAt: Date())
        do {
            try closeAdmission()
            try runs.pauseCurrentRunForAdmission()
            try runs.beginTransition(intent)
            let client = try api()
            let detail = try await client.eventDetail(id: eventID)
            if detail.event.lifecycle == .active {
                _ = try await client.transitionEvent(id: eventID, action: "pause", expectedVersion: detail.event.version, policyRevisionID: nil, acknowledgedUnitPriceCentavos: nil)
            }
            let confirmed = try await client.eventDetail(id: eventID)
            commercial = .confirmed(.init(eventID: eventID, lifecycle: confirmed.event.lifecycle, isAccountActiveEvent: false, checkedAt: Date()))
            guard confirmed.event.lifecycle == .paused else { throw SetupFailure("The server reports the paid event is \(confirmed.event.lifecycle.displayName).") }
            try runs.clearTransition(id: intent.id)
            message = "The paid event is paused for every booth. This iPad is paused too. Paid purchases remain recoverable."
        } catch {
            message = "Pausing the paid event was not confirmed: \(error.localizedDescription) This iPad stays paused. Check Status before trying again."
        }
    }

    // MARK: Resume / Start

    /// Resume goes through the same reviewed Start as Event Setup, so the saved context, payment
    /// policy and server lifecycle are revalidated before admission opens.
    func resume() async -> Bool {
        guard operation == nil else { return false }
        if RegularBoothMode.isEnabled(acceptance: acceptance, runs: runs) {
            guard authorized(), blockingReason() == nil else { message = blockingReason() ?? "Unlock Operator again before continuing."; return false }
            do { try acceptance.save(.init(mode: .localPrepaid, boothMode: .regular)); message = "Regular Booth is ready for guests."; return true }
            catch { message = error.localizedDescription; return false }
        }
        guard runs.current?.status != .completed, runs.current?.status != .archived else {
            message = "An ended event isn't resumed. Use Start New Occurrence in Event Setup."; return false
        }
        if hasUnsavedSetup() { message = "Setup has unsaved changes. Review them in Event Setup, then start."; return false }
        operation = .starting; defer { operation = nil }
        let setup = makeSetup()
        await setup.refresh()
        if let validation = setup.validation { message = validation; return false }
        let started = await setup.startAccepting()
        message = started ? "Accepting guests on this iPad." : setup.message
        await refresh()
        return started
    }

    // MARK: End

    /// The operator's End confirmation explicitly switches this iPad to Regular Booth. The
    /// journal survives every boundary: server mutation, local completion, design and barrier.
    func end(scope: EndScope) async -> Bool {
        guard operation == nil else { return false }
        guard authorized() else { message = "Unlock Operator again before continuing."; return false }
        if let reason = blockingReason() { message = reason; return false }
        guard runs.pendingTransition == nil else { message = "Finish Ending Event using Check Status first."; return false }
        guard let run = runs.current, [.active, .paused, .completed, .archived].contains(run.status) else {
            message = "There is no event run to end."; return false
        }
        operation = .ending; defer { operation = nil }
        do {
            let eventID = run.context.commercialEventID
            if let starting = acceptance.state.startingEventID, starting != eventID {
                throw SetupFailure("Finish reviewing the interrupted paid-event Start in Event Setup before ending this occurrence.")
            }
            if eventID != nil, run.context.serverBinding != binding() { throw SetupFailure("Restore the original payments connection before ending this event.") }
            var intent = EventTransitionIntent(id: UUID().uuidString.lowercased(),
                kind: scope == .thisBoothAndCommercialEvent ? .endCommercialEvent : .returnToRegular,
                runID: run.id, commercialEventID: eventID ?? "", serverBinding: binding(), createdAt: Date(),
                returnsToRegular: true, serverConfirmed: eventID == nil)
            try closeAdmission()
            try runs.beginTransition(intent)
            if let eventID {
                let client = try api()
                let detail = try await client.eventDetail(id: eventID)
                if scope == .thisBoothAndCommercialEvent, [.active, .paused].contains(detail.event.lifecycle) {
                    _ = try await client.transitionEvent(id: eventID, action: "end", expectedVersion: detail.event.version, policyRevisionID: nil, acknowledgedUnitPriceCentavos: nil)
                }
                let confirmed = try await client.eventDetail(id: eventID)
                guard scope == .thisBooth || [.ended, .archived].contains(confirmed.event.lifecycle) else {
                    try runs.clearTransition(id: intent.id)
                    throw SetupFailure("Ending the paid event was not confirmed.")
                }
                guard authorized(), binding() == intent.serverBinding else { throw SetupFailure("Operator access or payments connection changed. Check Status to finish ending.") }
                intent.serverConfirmed = true
                try runs.beginTransition(intent)
            }
            try commitRegular(intent)
            message = scope == .thisBoothAndCommercialEvent
                ? "Event ended for every booth. Regular Booth is ready here; history and payments are kept."
                : "Regular Booth is ready. This event's history is kept; other booths are unchanged."
            return true
        } catch {
            message = "Finish Ending Event: \(error.localizedDescription) New guests remain paused until the transition is verified."
            return false
        }
    }

    private func commitRegular(_ intent: EventTransitionIntent) throws {
        if let reason = blockingReason() { throw SetupFailure(reason) }
        guard !runs.historyUnreadable, acceptance.storageError == nil else { throw SetupFailure("Recover event and admission storage before returning to Regular Booth.") }
        try closeAdmission()
        try runs.completeAndDetachForRegular(intentID: intent.id)
        try applyRegularConfiguration()
        // Keep the barrier closed until the journal is cleared. A crash on either side is
        // recoverable; guests also check the pending journal before admission.
        try acceptance.save(.init(blocked: true, mode: .localPrepaid, boothMode: .regular))
        try runs.clearTransition(id: intent.id)
        try acceptance.save(.init(mode: .localPrepaid, boothMode: .regular))
        commercial = .notNeeded
    }

    /// Migration of an ended legacy pointer is explicit. For active/paused events the End
    /// confirmation is required instead. No server failure can select free operation.
    func returnToRegular() async -> Bool {
        if let pending = runs.pendingTransition, pending.returnsToRegular == true {
            await refresh()
            return RegularBoothMode.isEnabled(acceptance: acceptance, runs: runs) && !acceptance.state.blocked
        }
        if let run = runs.current {
            guard [.completed, .archived].contains(run.status) else { message = "Use End Event to leave an active or paused event."; return false }
            return await end(scope: .thisBooth)
        }
        guard authorized(), operation == nil else { message = "Unlock Operator again before continuing."; return false }
        if let reason = blockingReason() { message = reason; return false }
        do {
            let paidID = acceptance.state.startingEventID ?? acceptance.state.eventID
            let paidBinding = acceptance.state.startingBinding ?? acceptance.state.serverBinding
            guard (source() == .localPrepaid && paidID == nil) || (paidID != nil && paidBinding == binding()) else { throw SetupFailure("The paid event binding needs review in Event Setup before switching modes.") }
            var intent = EventTransitionIntent(id: UUID().uuidString.lowercased(), kind: .returnToRegular, runID: nil,
                commercialEventID: paidID ?? "", serverBinding: binding(), createdAt: Date(), returnsToRegular: true, serverConfirmed: paidID == nil)
            try closeAdmission(); try runs.beginTransition(intent)
            if let paidID {
                _ = try await api().eventDetail(id: paidID)
                guard authorized(), binding() == intent.serverBinding else { throw SetupFailure("Operator access or payments connection changed.") }
                intent.serverConfirmed = true; try runs.beginTransition(intent)
            }
            try commitRegular(intent)
            message = "Regular Booth is ready. Saved designs and drafts are kept."; return true
        } catch { message = "Return to Regular Booth could not finish: \(error.localizedDescription)"; return false }
    }

    func finishEndingLocally() async {
        guard case .confirmed(let check) = commercial, [.ended, .archived].contains(check.lifecycle) else {
            message = "Check Status to confirm that the paid event has ended."; return
        }
        _ = await end(scope: .thisBooth)
    }

    // MARK: Upgrade bootstrap

    /// Records the first event run for an occurrence that was already running when this iPad was
    /// upgraded to a build with event runs. Protected and explicit; it verifies the committed
    /// identity against the server first, never creates or changes a paid event, never changes
    /// admission, prices or payment policy, and never assigns earlier sessions to the run.
    /// Repeating it (or relaunching mid-way) can't create a second run.
    func recordUpgradedRun() async -> Bool {
        guard operation == nil else { return false }
        guard authorized() else { message = "Unlock Operator again before continuing."; return false }
        if runs.current != nil { message = "This iPad already has an event run. Nothing was changed."; return false }
        guard runs.pendingTransition == nil, !runs.historyUnreadable else { message = "Resolve the event-history warning in Current Event first."; return false }
        operation = .checking; defer { operation = nil }
        let context = appliedContext()
        if source() == .serverManaged {
            await refresh()
            guard let eventID = linkedCommercialEventID, context.commercialEventID == eventID, context.serverBinding == binding() else {
                message = "This iPad's paid event identity doesn't match its setup. Review and start the event in Event Setup instead."; return false
            }
            guard case .confirmed(let check) = commercial, check.eventID == eventID, [.active, .paused].contains(check.lifecycle) else {
                message = "The paid event couldn't be confirmed as running, so no run was recorded. Check Status, then try again."; return false
            }
        } else {
            let local = loadLocal()
            guard context.commercialEventID == nil, SessionAdmission.localConfigurationIsReady(source: .localPrepaid, local: local) || SessionAdmission.localConfigurationIsPaused(local) else {
                message = "The prepaid setup needs review in Event Setup before a run can be recorded."; return false
            }
        }
        do {
            let run = try runs.recordUpgradedRun(context: context, paused: acceptance.state.blocked)
            message = "Event run recorded for \(run.context.name.isEmpty ? "this event" : run.context.name). Statistics count from now; earlier sessions stay under History. Admission and prices are unchanged."
            return true
        } catch { message = "No run was recorded: \(error.localizedDescription)"; return false }
    }

    /// Keeps the local occurrence consistent after a commercial lifecycle change confirmed by the
    /// server elsewhere in the app (for example Event Maintenance). Never reopens admission.
    static func syncAfterServerTransition(eventID: String, lifecycle: CommercialEventLifecycle, binding: String,
                                          runs: EventRunStore = .shared, acceptance: SessionAcceptanceStore = .shared) -> String? {
        guard let current = runs.current, current.context.commercialEventID == eventID, current.context.serverBinding == binding else { return nil }
        do {
            switch lifecycle {
            case .paused where current.status == .active:
                var barrier = acceptance.state; barrier.blocked = true; try acceptance.save(barrier)
                try runs.pauseCurrentRunForAdmission()
                return "This iPad's run is paused to match."
            case .ended where [.active, .paused].contains(current.status), .archived where [.active, .paused].contains(current.status):
                var barrier = acceptance.state; barrier.blocked = true; try acceptance.save(barrier)
                try runs.transition(id: current.id, to: .completed)
                return "This iPad's run is complete to match. History and reports are kept."
            default: return nil
            }
        } catch { return "This iPad's run could not be updated to match: \(error.localizedDescription) Open Current Event to finish." }
    }
}
