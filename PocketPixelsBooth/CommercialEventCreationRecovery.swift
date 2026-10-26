import Foundation
import Combine

/// One operator-authorized creation of a commercial (paid) event. It is written before the
/// request is sent, and its ID is sent as the request's idempotency key, so a lost response is
/// resolved by exact identity — never by matching names or dates — and never by blindly retrying.
nonisolated struct CommercialEventCreationIntent: Codable, Equatable, Identifiable, Sendable {
    nonisolated enum Purpose: Codable, Equatable, Sendable {
        /// Connects a saved design to paid checkout.
        case connectDesign(designID: String)
        /// Creates the booth's regular (non-event) paid sessions.
        case regularSessions
        /// Follows an ended commercial event with a fresh one (design, or regular sessions when nil).
        case newOccurrence(designID: String?, replacing: String)
    }
    nonisolated enum State: String, Codable, Sendable {
        /// Sent, or about to be sent. Whether the server created an event is unknown.
        case requested
        /// The server's event was identified exactly; the local link is not yet saved.
        case created
        case linked
        /// The server confirmed nothing was created (or rejected the request outright).
        case notCreated
        /// Deliberately resolved by the operator, with a recorded reason.
        case superseded
    }

    let id: String
    let serverBinding: String
    let purpose: Purpose
    let name: String
    let venue: String
    let createdAt: Date
    var state: State
    var eventID: String?
    var resolution: String?
    var resolvedAt: Date?

    var isOpen: Bool { state == .requested || state == .created }
    var designID: String? {
        switch purpose {
        case .connectDesign(let id): id
        case .newOccurrence(let id, _): id
        case .regularSessions: nil
        }
    }
}

/// Durable, append-only journal of creation operations. Small, private, no credentials.
@MainActor final class CommercialEventCreationStore: ObservableObject {
    static let shared = CommercialEventCreationStore()
    static let retainedResolvedCount = 200

    @Published private(set) var intents: [CommercialEventCreationIntent] = []
    @Published private(set) var storageError: String?
    private let file: URL
    private let writer: (Data, URL) throws -> Void
    private var unreadable = false
    private var committing = false
    nonisolated private struct Journal: Codable, Sendable { var schemaVersion = 1; var intents: [CommercialEventCreationIntent] }

    init(directory: URL? = nil, writer: @escaping (Data, URL) throws -> Void = { try DurableFileWriter.write($0, to: $1) }) {
        let root = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        file = root.appendingPathComponent("EventCreationV1/intents.json")
        self.writer = writer
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            let journal = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: file))
            guard journal.schemaVersion == 1, Set(journal.intents.map(\.id)).count == journal.intents.count else { throw CocoaError(.fileReadCorruptFile) }
            intents = journal.intents
        } catch {
            unreadable = true
            storageError = "Paid-event creation records could not be read. The file is preserved; new paid events can't be created until it is recovered."
        }
    }

    var isUnreadable: Bool { unreadable }

    /// The unresolved creation for a payments connection. At most one exists per connection.
    func open(binding: String) -> CommercialEventCreationIntent? {
        intents.last { $0.serverBinding == binding && $0.isOpen }
    }

    /// Unresolved creations on other payments connections (shown, never resolved from here).
    func openElsewhere(binding: String) -> [CommercialEventCreationIntent] {
        intents.filter { $0.serverBinding != binding && $0.isOpen }
    }

    func intent(id: String) -> CommercialEventCreationIntent? { intents.first { $0.id == id } }

    /// Fail-closed write before the network request. Refuses while another creation on the
    /// same connection is unresolved, so a second commercial event can't be created by accident.
    func begin(_ intent: CommercialEventCreationIntent) throws {
        if let open = open(binding: intent.serverBinding), open.id != intent.id {
            throw SetupFailure("An earlier paid-event creation still needs confirmation. Resolve it in Event Setup first.")
        }
        guard self.intent(id: intent.id) == nil else { return }
        try commit(intents + [intent])
    }

    func beginAsync(_ intent: CommercialEventCreationIntent) async throws {
        if let open = open(binding: intent.serverBinding), open.id != intent.id {
            throw SetupFailure("An earlier paid-event creation still needs confirmation. Resolve it in Event Setup first.")
        }
        guard self.intent(id: intent.id) == nil else { return }
        try await commitAsync(intents + [intent])
    }

    func markCreatedAsync(id: String, eventID: String) async throws {
        let next = try changing(id) { intent in
            guard intent.state == .requested || (intent.state == .created && intent.eventID == eventID) else {
                throw SetupFailure("This creation was already resolved differently. Nothing was changed.")
            }
            intent.state = .created; intent.eventID = eventID
        }
        try await commitAsync(next)
    }

    func markLinkedAsync(id: String) async throws {
        let next = try changing(id) { intent in
            guard intent.state == .created || intent.state == .linked, intent.eventID != nil else { throw SetupFailure("The created event has not been confirmed yet.") }
            intent.state = .linked; intent.resolvedAt = intent.resolvedAt ?? Date()
        }
        try await commitAsync(next)
    }

    func markNotCreatedAsync(id: String, reason: String) async throws {
        let next = try changing(id) { intent in
            guard intent.state == .requested else { throw SetupFailure("This creation already has a confirmed event.") }
            intent.state = .notCreated; intent.resolution = reason; intent.resolvedAt = Date()
        }
        try await commitAsync(next)
    }

    func markCreated(id: String, eventID: String) throws {
        try change(id) { intent in
            guard intent.state == .requested || (intent.state == .created && intent.eventID == eventID) else {
                throw SetupFailure("This creation was already resolved differently. Nothing was changed.")
            }
            intent.state = .created; intent.eventID = eventID
        }
    }

    func markLinked(id: String) throws {
        try change(id) { intent in
            guard intent.state == .created || intent.state == .linked, intent.eventID != nil else { throw SetupFailure("The created event has not been confirmed yet.") }
            intent.state = .linked; intent.resolvedAt = intent.resolvedAt ?? Date()
        }
    }

    func markNotCreated(id: String, reason: String) throws {
        try change(id) { intent in
            guard intent.state == .requested else { throw SetupFailure("This creation already has a confirmed event. Nothing was changed.") }
            intent.state = .notCreated; intent.resolution = reason; intent.resolvedAt = Date()
        }
    }

    /// Operator resolution with an audited reason: either an explicitly selected existing draft
    /// (then linked like a created event) or abandonment of the original request.
    func supersede(id: String, reason: String, selectedEventID: String?) throws {
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SetupFailure("Enter a reason. It is kept with this record.") }
        try change(id) { intent in
            guard intent.isOpen else { throw SetupFailure("This creation is already resolved.") }
            if let selectedEventID {
                guard intent.state == .requested || intent.eventID == selectedEventID else {
                    throw SetupFailure("The original request already has a confirmed event. Complete linking instead.")
                }
                intent.state = .created; intent.eventID = selectedEventID
                intent.resolution = "operator-selected: " + String(trimmed.prefix(200))
            } else {
                intent.state = .superseded; intent.resolvedAt = Date()
                intent.resolution = "operator-abandoned: " + String(trimmed.prefix(200))
            }
        }
    }

    private func change(_ id: String, _ body: (inout CommercialEventCreationIntent) throws -> Void) throws {
        try commit(changing(id, body))
    }

    private func changing(_ id: String, _ body: (inout CommercialEventCreationIntent) throws -> Void) throws -> [CommercialEventCreationIntent] {
        guard let index = intents.firstIndex(where: { $0.id == id }) else { throw SetupFailure("Creation record not found.") }
        var next = intents
        try body(&next[index])
        return next
    }

    private func prepared(_ next: [CommercialEventCreationIntent]) throws -> [CommercialEventCreationIntent] {
        guard !unreadable, !committing else { throw SetupFailure(storageError ?? "Creation records are unavailable.") }
        var pruned = next
        let resolved = pruned.filter { !$0.isOpen }
        if resolved.count > Self.retainedResolvedCount {
            let drop = Set(resolved.sorted { ($0.resolvedAt ?? $0.createdAt) < ($1.resolvedAt ?? $1.createdAt) }.prefix(resolved.count - Self.retainedResolvedCount).map(\.id))
            pruned.removeAll { drop.contains($0.id) }
        }
        return pruned
    }

    private func commitAsync(_ next: [CommercialEventCreationIntent]) async throws {
        let pruned = try prepared(next)
        committing = true; defer { committing = false }
        let job = DurableJSONWrite(value: Journal(intents: pruned), file: file, write: writer)
        do { try await Task.detached(priority: .userInitiated) { try job.perform() }.value }
        catch { storageError = "Paid-event creation record not saved: \(error.localizedDescription)"; throw error }
        intents = pruned; storageError = nil
    }

    private func commit(_ next: [CommercialEventCreationIntent]) throws {
        let pruned = try prepared(next)
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication, .posixPermissions: 0o700])
            try writer(JSONEncoder().encode(Journal(intents: pruned)), file)
            intents = pruned; storageError = nil
        } catch {
            storageError = "Paid-event creation record not saved: \(error.localizedDescription)"
            throw error
        }
    }
}

extension PaymentsAPIError {
    /// True only when the server cannot have committed the mutation: the request was refused
    /// before or by validation. Transport failures and 5xx responses stay ambiguous.
    var provesNoMutation: Bool {
        switch self {
        case .configuration, .unauthorized: true
        case .rejected(_, _, let status, _): (400..<500).contains(status) && status != 408
        case .unavailable, .outcomeUnknown, .invalidResponse: false
        }
    }
}
