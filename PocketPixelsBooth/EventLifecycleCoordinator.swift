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
    case unavailable(String)
}

/// One truthful status derived from every state owner that affects guest admission. It never
/// treats a local `.active` run, or an active server event, as proof that guests are accepted.
nonisolated enum EventOperatorStatus: Equatable, Sendable {
    case noEvent
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
        case .draft: "Draft — Not Started"
        case .ready: "Ready to Start"
        case .starting: "Starting…"
        case .accepting: "Accepting Guests"
        case .unconfirmed: "Server Status Not Confirmed"
        case .pausedOnBooth: "Paused on This iPad"
        case .serverPaused: "Paid Event Paused"
        case .needsReview: "Needs Operator Review"
        case .ending: "Ending…"
        case .completed: "Event Ended"
        case .archived: "Event Archived"
        case .recoveryRequired: "Recovery Required"
        }
    }

    var detail: String {
        switch self {
        case .noEvent: "Set up an event to start accepting guests."
        case .draft: "Setup changes are saved but not started. Guests can't start yet."
        case .ready: "Review the setup and start when you're ready."
        case .starting: "Checking every setting before guests can start."
        case .accepting: "Guests can start new sessions on this iPad."
        case .unconfirmed(let reason): "This iPad is open to guests, but the payments server could not be checked: \(reason)"
        case .pausedOnBooth: "New sessions are paused on this iPad only. Other booths are not affected."
        case .serverPaused: "The paid event is paused for every booth. Paid purchases remain recoverable."
        case .needsReview(let reason), .recoveryRequired(let reason): reason
        case .ending: "Closing guest admission and confirming the event has ended."
        case .completed: "No new guests. History and reports are kept. Start a new occurrence to run again."
        case .archived: "Hidden from everyday use. Reports remain in Event History."
        }
    }

    var systemImage: String {
        switch self {
        case .accepting: "checkmark.circle.fill"
        case .pausedOnBooth, .serverPaused: "pause.circle.fill"
        case .starting, .ending: "hourglass"
        case .completed: "flag.checkered"
        case .archived: "archivebox"
        case .needsReview, .unconfirmed: "exclamationmark.circle.fill"
        case .recoveryRequired: "exclamationmark.octagon.fill"
        case .noEvent, .draft, .ready: "circle.dashed"
        }
    }

    var isAccepting: Bool { self == .accepting }
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
            let action = pending.kind == .endCommercialEvent ? "Ending the paid event" : "Pausing the paid event"
            return .recoveryRequired("\(action) was interrupted before it was confirmed. Check Status to finish it; nothing will be repeated automatically.")
        }
        guard let run = input.run else {
            // Upgrade path: a booth that accepted guests before event runs keeps accepting; the
            // first guest starts the first run.
            if !input.barrierBlocked, input.source == .localPrepaid, input.localPrepaidReady { return .accepting }
            return input.hasUnsavedSetup ? .draft : .noEvent
        }
        switch run.status {
        case .archived: return .archived
        case .completed: return .completed
        case .draft: return .ready
        case .active, .paused: break
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
         hasUnsavedSetup: @escaping @MainActor () -> Bool = { OperatorWorkspace.shared.hasUnsavedDrafts },
         makeSetup: @escaping @MainActor () -> SessionSetupCoordinator = { SessionSetupCoordinator() }) {
        self.runs = runs ?? .shared; self.acceptance = acceptance ?? .shared
        self.api = api; self.authorized = authorized; self.blockingReason = blockingReason; self.recoveryReason = recoveryReason
        self.source = source; self.loadLocal = loadLocal; self.saveLocal = saveLocal; self.binding = binding
        self.appliedContext = appliedContext; self.hasUnsavedSetup = hasUnsavedSetup; self.makeSetup = makeSetup
    }

    var status: EventOperatorStatus {
        let local = loadLocal()
        // A failed statistics write is shown as a warning; only unreadable state blocks operation.
        let errors = [runs.historyUnreadable ? runs.storageError : nil, acceptance.storageError].compactMap { $0 }
        return EventStatusModel.derive(.init(run: runs.current, appliedContext: appliedContext(), barrierBlocked: acceptance.state.blocked,
            acceptanceEventID: acceptance.state.eventID, acceptanceBinding: acceptance.state.serverBinding, binding: binding(), source: source(),
            localPrepaidReady: SessionAdmission.localConfigurationIsReady(source: .localPrepaid, local: local),
            commercial: commercial, recoveryReason: recoveryReason(), storageErrors: errors,
            pendingTransition: runs.pendingTransition, hasUnsavedSetup: hasUnsavedSetup(), operation: operation))
    }

    /// The paid event linked to the current occurrence, when it belongs to this connection.
    var linkedCommercialEventID: String? {
        guard let run = runs.current, let id = run.context.commercialEventID, run.context.serverBinding == binding() else { return nil }
        return id
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
            guard checkRequest == request else { return }
            commercial = .unavailable(error.localizedDescription)
        }
    }

    private func reconcilePending(with check: CommercialEventCheck) {
        guard let pending = runs.pendingTransition, pending.commercialEventID == check.eventID, pending.serverBinding == binding() else { return }
        do {
            switch (pending.kind, check.lifecycle) {
            case (.endCommercialEvent, .ended?), (.endCommercialEvent, .archived?):
                try completeLocalRun(for: pending)
                try runs.clearTransition(id: pending.id)
                message = "Confirmed: the paid event has ended. This iPad's run is complete; history and reports are kept."
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
        guard let eventID = linkedCommercialEventID, let run = runs.current else { message = "This run has no paid event to pause."; return }
        operation = .pausing; defer { operation = nil }
        let intent = EventTransitionIntent(id: UUID().uuidString.lowercased(), kind: .pauseCommercialEvent, runID: run.id,
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

    /// Ends the occurrence. With `.thisBoothAndCommercialEvent` the server transition is made and
    /// read back first; the local run completes only after confirmation, guarded by a durable intent.
    func end(scope: EndScope) async -> Bool {
        guard operation == nil else { return false }
        guard authorized() else { message = "Unlock Operator again before continuing."; return false }
        if let reason = blockingReason() { message = reason; return false }
        guard let run = runs.current, [.active, .paused].contains(run.status) else { message = "There is no active or paused event run to end."; return false }
        operation = .ending; defer { operation = nil }
        do {
            try closeAdmission()
            if scope == .thisBoothAndCommercialEvent {
                guard let eventID = linkedCommercialEventID else { throw SetupFailure("This run has no paid event on this payments connection.") }
                let intent = EventTransitionIntent(id: UUID().uuidString.lowercased(), kind: .endCommercialEvent, runID: run.id,
                                                   commercialEventID: eventID, serverBinding: binding(), createdAt: Date())
                try runs.beginTransition(intent)
                let client = try api()
                let detail = try await client.eventDetail(id: eventID)
                if [.active, .paused].contains(detail.event.lifecycle) {
                    _ = try await client.transitionEvent(id: eventID, action: "end", expectedVersion: detail.event.version, policyRevisionID: nil, acknowledgedUnitPriceCentavos: nil)
                }
                let confirmed = try await client.eventDetail(id: eventID)
                commercial = .confirmed(.init(eventID: eventID, lifecycle: confirmed.event.lifecycle, isAccountActiveEvent: false, checkedAt: Date()))
                guard [.ended, .archived].contains(confirmed.event.lifecycle) else {
                    try? runs.clearTransition(id: intent.id)
                    throw SetupFailure("The server reports the paid event is \(confirmed.event.lifecycle.displayName).")
                }
                try runs.transition(id: run.id, to: .completed)
                try runs.clearTransition(id: intent.id)
                message = "Event ended on this iPad and for every booth. Sales, sessions, galleries and receipts are kept for reports."
            } else {
                try runs.transition(id: run.id, to: .completed)
                message = linkedCommercialEventID == nil
                    ? "Event ended on this iPad. History and reports are kept."
                    : "Event ended on this iPad. The paid event stays open for other booths; end it separately when every booth is done."
            }
            return true
        } catch {
            message = "Ending was not confirmed: \(error.localizedDescription) New sessions on this iPad stay paused. Check Status before trying again."
            return false
        }
    }

    /// When the paid event was ended elsewhere, this completes the local run to match.
    func finishEndingLocally() async {
        guard operation == nil else { return }
        guard authorized() else { message = "Unlock Operator again before continuing."; return }
        guard let run = runs.current, [.active, .paused].contains(run.status) else { return }
        operation = .ending; defer { operation = nil }
        do {
            try closeAdmission()
            try runs.transition(id: run.id, to: .completed)
            message = "This iPad's run is complete. History and reports are kept."
        } catch { message = "Not completed: \(error.localizedDescription)" }
    }

    /// Fresh statistics for the same setup. Admission state and prices are unchanged.
    func startNewRun() -> Bool {
        do {
            _ = try runs.startNewRun(context: appliedContext())
            message = acceptance.state.blocked
                ? "A new event run started with fresh statistics. This iPad is still paused; resume when ready."
                : "A new event run started with fresh statistics. Earlier runs keep their history."
            return true
        } catch { message = error.localizedDescription; return false }
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
