import Foundation
import Combine

/// How guests pay, as the operator chooses it. Maps onto the existing commercial-policy model:
/// no payment is the local prepaid domain; the paid choices are a server pay-per-print policy
/// with QR Ph and/or cash enabled. There is no separate authorization engine per choice.
nonisolated enum GuestPaymentChoice: String, Codable, CaseIterable, Identifiable, Sendable {
    case noPayment, qrOnly, cashOnly, qrAndCash

    var id: String { rawValue }

    init(qrPhEnabled: Bool, cashEnabled: Bool) {
        switch (qrPhEnabled, cashEnabled) {
        case (true, true): self = .qrAndCash
        case (false, true): self = .cashOnly
        default: self = .qrOnly
        }
    }

    var isPaid: Bool { self != .noPayment }
    var acceptsQRPh: Bool { self == .qrOnly || self == .qrAndCash }
    var acceptsCash: Bool { self == .cashOnly || self == .qrAndCash }

    var title: String {
        switch self {
        case .noPayment: "No Payment Required"
        case .qrOnly: "QR Ph Only"
        case .cashOnly: "Cash Only"
        case .qrAndCash: "QR Ph + Cash"
        }
    }

    var subtitle: String {
        switch self {
        case .noPayment: "Guests start free. ₱0 — complimentary or prepaid."
        case .qrOnly: "Guests scan to pay. Verified by the payment provider."
        case .cashOnly: "Guests pay the attendant, then tap “I’ve paid” to start."
        case .qrAndCash: "Guests choose QR Ph or declare cash paid to the attendant."
        }
    }

    var systemImage: String {
        switch self {
        case .noPayment: "gift"
        case .qrOnly: "qrcode"
        case .cashOnly: "banknote"
        case .qrAndCash: "qrcode.viewfinder"
        }
    }

    /// Guest-facing method labels with their provenance, for review and status screens.
    var methodSummary: String {
        switch self {
        case .noPayment: "No payment — complimentary / prepaid"
        case .qrOnly: "QR Ph — provider verified"
        case .cashOnly: "Cash — customer declared"
        case .qrAndCash: "QR Ph — provider verified · Cash — customer declared"
        }
    }
}

/// One event's saved local design: identity, optional personalized receipt and guest screens.
/// Server-managed events are linked per payments environment, so TEST and LIVE never share a
/// binding. Artwork bytes stay in the immutable EventHeaderAssetStore; only the identifier lives here.
nonisolated struct SavedEventDesign: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var name: String
    var venue: String
    /// Personalize Receipt with Event Logo. New events start off.
    var personalizeReceipt: Bool
    /// Custom welcome and thank-you screens for this event.
    var guestScreensEnabled: Bool
    /// Design body: logo reference, receipt layout, typography, captions, guest-screen wording,
    /// Photo Pass settings. Its enable flags are derived from the switches above when applied.
    var profile: EventProfile
    /// Payments binding (`environment:baseURL`) → server event ID.
    var serverEvents: [String: String]
    var createdAt: Date
    var updatedAt: Date
    var archivedAt: Date? = nil
    /// Reversible visibility tombstone. Identity, settings and commercial ownership are retained.
    var removedAt: Date? = nil
    /// Binding → commercial events this design used for earlier, ended occurrences. Append-only:
    /// a new paid occurrence links a fresh commercial event, and the old one's orders stay with it.
    var retiredServerEvents: [String: [String]]? = nil
    /// Reusable no-payment copy/format settings. Older saved events inherit device settings.
    /// This is staged configuration; saving it never changes the active booth policy.
    var prepaidPolicy: PaymentPolicySnapshot? = nil

    static func new(name: String, venue: String, now: Date = Date()) -> SavedEventDesign {
        var profile = EventProfile.pocketPixelsDefault
        profile.receiptHeader = .coBrandedRecommended
        profile.receiptHeader.mode = .pocketPixelsDefault
        // The co-branded reference prints no event text; operators can add it in the editor.
        profile.showEventTextBlock = false
        profile.eventDate = now
        return SavedEventDesign(id: "evt-\(UUID().uuidString.lowercased())", name: name, venue: venue, personalizeReceipt: false,
                                guestScreensEnabled: false, profile: profile, serverEvents: [:], createdAt: now, updatedAt: now)
    }

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled Event" : trimmed
    }

    var logoIdentifier: String? { profile.receiptHeader.assetIdentifier }
    var layout: ReceiptBrandingMode { profile.receiptHeader.brandingMode ?? .coBranded }

    func serverEventID(binding: String) -> String? { serverEvents[binding] }

    /// Every commercial event this design has ever been linked to in one environment.
    func allServerEventIDs(binding: String) -> [String] {
        (retiredServerEvents?[binding] ?? []) + (serverEvents[binding].map { [$0] } ?? [])
    }
    var hasCommercialHistory: Bool { !serverEvents.isEmpty || !(retiredServerEvents ?? [:]).values.allSatisfy(\.isEmpty) }

    /// Same operator-editable content. Timestamps and server links (owned by the library) are ignored.
    func hasSameContent(as other: SavedEventDesign?) -> Bool {
        guard var other else { return false }
        other.updatedAt = updatedAt
        other.serverEvents = serverEvents
        other.retiredServerEvents = retiredServerEvents
        return other == self
    }

    /// The exact profile applied to future guest sessions while this event is active. With the
    /// logo switched off the receipt is the ordinary Made to Keep design: no logo space, no
    /// placeholder. The saved logo reference is kept for later.
    func appliedProfile() -> EventProfile {
        var value = profile
        value.eventName = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(EventProfile.eventNameLimit))
        if value.location.isEmpty { value.location = String(venue.prefix(EventProfile.locationLimit)) }
        value.isEnabled = personalizeReceipt
        value.receiptHeader.mode = personalizeReceipt ? .customEventHeader : .pocketPixelsDefault
        value.customerScreenEnabled = guestScreensEnabled
        return value.normalized()
    }
}

/// Identity-only history, separate from a reusable receipt/guest-screen configuration.
nonisolated struct RemovedEventDesignReference: Codable, Equatable, Sendable {
    let id: String
    let name: String
    let createdAt: Date
    let removedAt: Date
    let serverEventIDs: [String: [String]]
}

/// The library file. Selection here is what was last applied, not the operator's draft.
nonisolated struct EventDesignLibrary: Codable, Equatable, Sendable {
    var schemaVersion = 1
    var events: [SavedEventDesign] = []
    var appliedEventModeEnabled = false
    var appliedEventID: String?
    /// Payments binding → the server event that carries regular (non-event) paid sessions.
    var regularServerEvents: [String: String] = [:]
    /// Set once the legacy device-wide profile has been considered for import.
    var migratedLegacyProfile = false
    /// Binding → regular-session commercial events replaced after they ended. Append-only.
    var retiredRegularServerEvents: [String: [String]]? = nil
    var removedDesigns: [RemovedEventDesignReference]? = nil

    func historicalName(id: String?) -> String? {
        guard let id else { return nil }
        return events.first(where: { $0.id == id })?.displayName ?? removedDesigns?.first(where: { $0.id == id })?.name
    }

    func design(id: String?) -> SavedEventDesign? {
        guard let id else { return nil }
        return events.first { $0.id == id && $0.removedAt == nil }
    }

    func design(linkedTo serverEventID: String, binding: String) -> SavedEventDesign? {
        events.first { $0.serverEvents[binding] == serverEventID && $0.removedAt == nil }
    }

    var removedEventIDs: Set<String> {
        Set(events.filter { $0.removedAt != nil }.map(\.id)).union((removedDesigns ?? []).map(\.id))
    }
    func removedServerEventIDs(binding: String) -> Set<String> {
        Set(events.filter { $0.removedAt != nil }.flatMap { $0.allServerEventIDs(binding: binding) })
            .union((removedDesigns ?? []).flatMap { $0.serverEventIDs[binding] ?? [] })
    }

    /// Commercial events already owned by a design or by regular sessions, current or retired.
    func knownServerEventIDs(binding: String) -> Set<String> {
        var ids = Set(events.flatMap { $0.allServerEventIDs(binding: binding) })
        if let regular = regularServerEvents[binding] { ids.insert(regular) }
        ids.formUnion(retiredRegularServerEvents?[binding] ?? [])
        ids.formUnion((removedDesigns ?? []).flatMap { $0.serverEventIDs[binding] ?? [] })
        return ids
    }

    /// An existing install's device-wide profile becomes its first saved event, unchanged.
    static func migrating(legacy profile: EventProfile, legacyName: String, now: Date = Date()) -> EventDesignLibrary {
        var library = EventDesignLibrary(migratedLegacyProfile: true)
        let normalized = profile.normalized()
        let meaningful = normalized.isEventModeActive || !normalized.eventName.isEmpty || normalized.receiptHeader.assetIdentifier != nil
            || !normalized.customerTitle.isEmpty
        guard meaningful else { return library }
        let name = [normalized.eventName, legacyName, "Saved Event"].first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? "Saved Event"
        let design = SavedEventDesign(
            id: "evt-\(UUID().uuidString.lowercased())",
            name: name,
            venue: normalized.location,
            personalizeReceipt: normalized.isEnabled && normalized.receiptHeader.mode == .customEventHeader,
            guestScreensEnabled: normalized.customerScreenEnabled,
            profile: normalized,
            serverEvents: [:],
            createdAt: now,
            updatedAt: now
        )
        library.events = [design]
        library.appliedEventModeEnabled = normalized.isEventModeActive
        library.appliedEventID = normalized.isEventModeActive ? design.id : nil
        return library
    }
}

/// Durable, protected store for saved event designs. A failed write never reports success and
/// never replaces the in-memory saved state; an unreadable file is preserved untouched.
@MainActor final class EventDesignLibraryStore: ObservableObject {
    static let shared = EventDesignLibraryStore()
    static let didChange = Notification.Name("madeToKeep.eventDesignLibrary.didChange")

    @Published private(set) var library: EventDesignLibrary
    @Published private(set) var storageError: String?
    private let file: URL
    private let write: (Data, URL) throws -> Void
    private var unreadableOriginal = false
    private var committing = false
    private let operationAuthorized: @MainActor () -> Bool
    private let operationBlockingReason: @MainActor () -> String?

    init(directory: URL? = nil,
         write: @escaping (Data, URL) throws -> Void = { try DurableFileWriter.write($0, to: $1) },
         legacyProfile: () -> EventProfile = { EventProfileStore.load() },
         legacyName: () -> String = { CommercialEventRunStore.load().name },
         operationAuthorized: @escaping @MainActor () -> Bool = { OperatorAccessPermit.shared.isAuthorized },
         operationBlockingReason: @escaping @MainActor () -> String? = { SessionSetupSafety.blockingReason }) {
        self.operationAuthorized = operationAuthorized
        self.operationBlockingReason = operationBlockingReason
        let root = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        file = root.appendingPathComponent("EventDesignLibraryV1", isDirectory: true).appendingPathComponent("library.json")
        self.write = write
        if FileManager.default.fileExists(atPath: file.path) {
            do {
                let decoded = try JSONDecoder().decode(EventDesignLibrary.self, from: Data(contentsOf: file))
                guard decoded.schemaVersion == 1 else { throw CocoaError(.fileReadCorruptFile) }
                library = decoded
            } catch {
                library = EventDesignLibrary(migratedLegacyProfile: true)
                unreadableOriginal = true
                storageError = "Saved event designs could not be read. The file is preserved; changes cannot be saved until it is recovered."
            }
        } else {
            let legacyName = legacyName()
            library = .migrating(legacy: legacyProfile(), legacyName: legacyName == CommercialEventRun.legacy.name ? "" : legacyName)
            // Persist once so migrated identities stay stable across launches. A failure leaves
            // the migration in memory and is retried on the next save.
            try? persist(library)
        }
    }

    func design(id: String?) -> SavedEventDesign? { library.design(id: id) }

    /// Inserts or replaces one event's saved design.
    func save(_ design: SavedEventDesign) throws { try commit(candidateSaving(design)) }

    func saveAsync(_ design: SavedEventDesign) async throws { try await commitAsync(candidateSaving(design)) }

    private func candidateSaving(_ design: SavedEventDesign) throws -> EventDesignLibrary {
        guard !library.removedEventIDs.contains(design.id) else {
            throw SetupFailure("This saved design was removed. Create a new event to use these edits; its historical identity is retained.")
        }
        var next = library
        var value = design
        value.updatedAt = Date()
        if let index = next.events.firstIndex(where: { $0.id == design.id }) {
            // Server links are recorded by `link`; a design draft never removes one.
            value.archivedAt = next.events[index].archivedAt
            value.removedAt = next.events[index].removedAt
            value.retiredServerEvents = next.events[index].retiredServerEvents
            // The library owns links: a stale draft can add a missing link but never replace one.
            value.serverEvents = next.events[index].serverEvents.merging(design.serverEvents) { stored, _ in stored }
            next.events[index] = value
        } else { next.events.append(value) }
        return next
    }

    func createAsync(name: String, venue: String) async throws -> SavedEventDesign {
        let design = SavedEventDesign.new(name: name.trimmingCharacters(in: .whitespacesAndNewlines), venue: venue.trimmingCharacters(in: .whitespacesAndNewlines))
        try await saveAsync(design)
        return design
    }

    func create(name: String, venue: String) throws -> SavedEventDesign {
        let design = SavedEventDesign.new(name: name.trimmingCharacters(in: .whitespacesAndNewlines), venue: venue.trimmingCharacters(in: .whitespacesAndNewlines))
        try save(design)
        return design
    }

    /// Links a saved event to a server event in one payments environment. A server event is
    /// linked to at most one saved event per environment.
    func link(designID: String, binding: String, serverEventID: String) throws { try commit(candidateLink(designID: designID, binding: binding, serverEventID: serverEventID)) }
    func linkAsync(designID: String, binding: String, serverEventID: String) async throws { try await commitAsync(candidateLink(designID: designID, binding: binding, serverEventID: serverEventID)) }

    private func candidateLink(designID: String, binding: String, serverEventID: String) throws -> EventDesignLibrary {
        guard !library.removedServerEventIDs(binding: binding).contains(serverEventID) else {
            throw SetupFailure("That commercial event belongs to a removed saved design. Its original history is retained.")
        }
        var next = library
        guard !next.events.contains(where: { $0.id != designID && $0.allServerEventIDs(binding: binding).contains(serverEventID) }),
              next.regularServerEvents[binding] != serverEventID,
              !(next.retiredRegularServerEvents?[binding] ?? []).contains(serverEventID) else {
            throw SetupFailure("That paid event already belongs to another event. Its original association was kept.")
        }
        guard let index = next.events.firstIndex(where: { $0.id == designID }) else { throw SetupFailure("That event is no longer saved.") }
        next.events[index].serverEvents[binding] = serverEventID
        next.events[index].updatedAt = Date()
        return next
    }

    /// The saved event for a server event, creating a plain (logo off) design the first time.
    func adopt(serverEventID: String, name: String, venue: String, binding: String) throws -> SavedEventDesign {
        if let existing = library.design(linkedTo: serverEventID, binding: binding) { return existing }
        guard !library.removedServerEventIDs(binding: binding).contains(serverEventID) else {
            throw SetupFailure("This commercial event is retained in history. Start a new event for a new occurrence.")
        }
        var design = SavedEventDesign.new(name: name, venue: venue)
        design.serverEvents[binding] = serverEventID
        try save(design)
        return design
    }

    /// Starts a new paid occurrence of a design whose commercial event has ended: the ended
    /// event moves to the design's append-only history and the fresh one becomes current.
    /// `expectedCurrent` guards against a concurrent relink. Old orders are never reassigned.
    func linkNewCommercialOccurrence(designID: String?, binding: String, expectedCurrent: String, newServerEventID: String) throws { try commit(candidateOccurrence(designID: designID, binding: binding, expectedCurrent: expectedCurrent, newServerEventID: newServerEventID)) }
    func linkNewCommercialOccurrenceAsync(designID: String?, binding: String, expectedCurrent: String, newServerEventID: String) async throws { try await commitAsync(candidateOccurrence(designID: designID, binding: binding, expectedCurrent: expectedCurrent, newServerEventID: newServerEventID)) }

    private func candidateOccurrence(designID: String?, binding: String, expectedCurrent: String, newServerEventID: String) throws -> EventDesignLibrary {
        guard expectedCurrent != newServerEventID else { throw SetupFailure("A new occurrence needs a new commercial event.") }
        var next = library
        guard !next.knownServerEventIDs(binding: binding).contains(newServerEventID) else { throw SetupFailure("That commercial event already belongs to another occurrence.") }
        if let designID {
            guard let index = next.events.firstIndex(where: { $0.id == designID }) else { throw SetupFailure("That event is no longer saved.") }
            guard next.events[index].serverEvents[binding] == expectedCurrent else { throw SetupFailure("This design's paid event changed. Check Current Status.") }
            var retired = next.events[index].retiredServerEvents ?? [:]
            retired[binding, default: []].append(expectedCurrent)
            next.events[index].retiredServerEvents = retired
            next.events[index].serverEvents[binding] = newServerEventID
            next.events[index].updatedAt = Date()
        } else {
            guard next.regularServerEvents[binding] == expectedCurrent else { throw SetupFailure("Regular sessions' paid event changed. Check Current Status.") }
            var retired = next.retiredRegularServerEvents ?? [:]
            retired[binding, default: []].append(expectedCurrent)
            next.retiredRegularServerEvents = retired
            next.regularServerEvents[binding] = newServerEventID
        }
        return next
    }

    func setRegularServerEvent(_ serverEventID: String, binding: String) throws { try commit(candidateRegular(serverEventID, binding: binding)) }
    func setRegularServerEventAsync(_ serverEventID: String, binding: String) async throws { try await commitAsync(candidateRegular(serverEventID, binding: binding)) }

    private func candidateRegular(_ serverEventID: String, binding: String) throws -> EventDesignLibrary {
        guard !library.removedServerEventIDs(binding: binding).contains(serverEventID) else {
            throw SetupFailure("That commercial event belongs to a removed saved design. Start a new event for Regular Booth checkout.")
        }
        var next = library
        next.regularServerEvents[binding] = serverEventID
        return next
    }

    func recordApplied(eventModeEnabled: Bool, eventID: String?) throws {
        if eventModeEnabled {
            guard let design = design(id: eventID), design.archivedAt == nil else { throw SetupFailure("Choose an active saved design before applying Event Mode.") }
        }
        var next = library
        next.appliedEventModeEnabled = eventModeEnabled
        next.appliedEventID = eventModeEnabled ? eventID : nil
        try commit(next)
    }

    func archiveDesign(id: String, now: Date = Date()) throws {
        guard operationAuthorized() else { throw PaymentsAPIError.unauthorized }
        guard id != library.appliedEventID else { throw SetupFailure("Choose a different design in Session Setup before archiving the applied design.") }
        guard let index = library.events.firstIndex(where: { $0.id == id }) else { throw SetupFailure("Design not found.") }
        var next = library
        next.events[index].archivedAt = now
        try commit(next)
    }

    func restoreDesign(id: String) throws {
        guard operationAuthorized() else { throw PaymentsAPIError.unauthorized }
        guard let index = library.events.firstIndex(where: { $0.id == id }) else { throw SetupFailure("Design not found.") }
        var next = library; next.events[index].archivedAt = nil
        try commit(next)
    }

    func deletionIneligibility(id: String, runs: [EventRunRecord], archives: [RecentSessionArchiveSummary], historyAvailable: Bool) -> String? {
        guard historyAvailable, storageError == nil, !archives.contains(where: { $0.rasterFingerprint == "CORRUPT" }) else { return "Dependency inspection is incomplete. Recover history before deleting." }
        guard let design = design(id: id) else { return "Design not found." }
        if library.appliedEventID == id || design.hasCommercialHistory || runs.contains(where: { $0.context.designID == id })
            || archives.contains(where: { $0.eventDesignID == id }) {
            return "This design has applied, commercial or historical dependencies. Archive it instead."
        }
        return nil
    }

    func deleteUnusedDesign(id: String, runs: [EventRunRecord], archives: [RecentSessionArchiveSummary], historyAvailable: Bool, deletedSessions: [RecentSessionArchiveStore.DeletedSessionEvidence]? = nil) throws {
        guard operationAuthorized() else { throw PaymentsAPIError.unauthorized }
        if let reason = operationBlockingReason() { throw SetupFailure(reason) }
        let deleted = try deletedSessions ?? RecentSessionArchiveStore().deletedSessionEvidence()
        if deleted.contains(where: { $0.eventDesignID == id }) {
            throw SetupFailure("Local session media was removed, but this design has historical use. Archive it instead.")
        }
        if let reason = deletionIneligibility(id: id, runs: runs, archives: archives, historyAvailable: historyAvailable) { throw SetupFailure(reason) }
        guard historyAvailable, !archives.contains(where: { $0.rasterFingerprint == "CORRUPT" }) else { throw SetupFailure("Recover unreadable event history before deleting a design. Archiving retains all dependencies.") }
        guard let design = design(id: id) else { throw SetupFailure("Design not found.") }
        guard library.appliedEventID != id, !design.hasCommercialHistory,
              !runs.contains(where: { $0.context.designID == id }),
              !archives.contains(where: { $0.eventDesignID == id }) else {
            throw SetupFailure("This design is applied or may have protected history. Archive it instead; photos, artwork and payment records are retained.")
        }
        var next = library; next.events.removeAll { $0.id == id }
        try commit(next)
    }

    /// Removes only reusable configuration. Reports, media, financial records and commercial
    /// ownership remain intact, so unrelated archive failures do not gate this operation.
    func removeSavedDesign(id: String, runs: [EventRunRecord], historyAvailable: Bool,
                           pendingCreation: Bool = false, now: Date = Date()) throws {
        guard operationAuthorized() else { throw PaymentsAPIError.unauthorized }
        guard historyAvailable else { throw SetupFailure("Event operation could not be checked. Recover event-run storage before removing this design.") }
        guard !pendingCreation else { throw SetupFailure("This event is waiting for a save operation to finish. Review Event Setup first.") }
        guard library.appliedEventID != id else {
            throw SetupFailure("This design is currently applied. End the running event, or switch to Regular Booth when idle, then remove it.")
        }
        guard !runs.contains(where: { $0.context.designID == id && [.active, .paused].contains($0.status) }) else {
            throw SetupFailure("This event is currently running. End it first; its history will be kept.")
        }
        guard let design = design(id: id) else { return } // idempotent; never remove another ID
        let bindings = Set(design.serverEvents.keys).union(design.retiredServerEvents?.keys.map { $0 } ?? [])
        let reference = RemovedEventDesignReference(id: id, name: design.displayName, createdAt: design.createdAt,
            removedAt: now, serverEventIDs: Dictionary(uniqueKeysWithValues: bindings.map { ($0, Array(design.allServerEventIDs(binding: $0)).sorted()) }))
        var next = library
        next.removedDesigns = (next.removedDesigns ?? []) + [reference]
        next.events.removeAll { $0.id == id }
        try commit(next)
    }

    /// Hides the saved event and every occurrence of that design through one durable flag.
    /// Run/session journals and server financial records are never mutated by removal.
    func removeEvent(id: String, runs: [EventRunRecord], historyAvailable: Bool,
                     pendingCreation: Bool = false, now: Date = Date()) throws {
        guard operationAuthorized() else { throw PaymentsAPIError.unauthorized }
        guard historyAvailable else { throw SetupFailure("Recover event-run storage before removing this event.") }
        guard !pendingCreation else { throw SetupFailure("Check the original event creation request before removing this event.") }
        guard library.appliedEventID != id,
              !runs.contains(where: { $0.context.designID == id && [.active, .paused].contains($0.status) }) else {
            throw SetupFailure("Use End Event then Remove to finish the running event and keep its history.")
        }
        guard let index = library.events.firstIndex(where: { $0.id == id }), library.events[index].removedAt == nil else { return }
        var next = library; next.events[index].removedAt = now
        try commit(next)
    }

    func restoreRemovedEvent(id: String) throws {
        guard operationAuthorized() else { throw PaymentsAPIError.unauthorized }
        guard let index = library.events.firstIndex(where: { $0.id == id }), library.events[index].removedAt != nil else {
            throw SetupFailure("The retained event configuration is unavailable.")
        }
        var next = library
        next.events[index].removedAt = nil
        next.events[index].archivedAt = nil
        try commit(next) // Never sets applied identity or starts a run.
    }

    func recordAppliedAsync(eventModeEnabled: Bool, eventID: String?) async throws {
        if eventModeEnabled {
            guard let design = design(id: eventID), design.archivedAt == nil else { throw SetupFailure("Choose an active saved event before applying.") }
        }
        var next = library; next.appliedEventModeEnabled = eventModeEnabled; next.appliedEventID = eventModeEnabled ? eventID : nil
        if next == library { return }
        try await commitAsync(next)
    }

    private func commitAsync(_ next: EventDesignLibrary) async throws {
        guard !unreadableOriginal, !committing else { throw SetupFailure(storageError ?? "An event save is still finishing. Try again when it completes.") }
        committing = true; defer { committing = false }
        let job = DurableJSONWrite(value: next, file: file, write: write)
        do { try await Task.detached(priority: .userInitiated) { try job.perform() }.value }
        catch { storageError = "Event design could not be saved on this iPad. Your edits are kept in setup; try again."; throw SetupFailure(storageError!) }
        library = next; storageError = nil
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    private func commit(_ next: EventDesignLibrary) throws {
        guard !committing else { throw SetupFailure("An event save is still finishing. Try again when it completes.") }
        if unreadableOriginal { throw SetupFailure(storageError ?? "Saved event designs are unavailable.") }
        try persist(next)
        library = next
        storageError = nil
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    private func persist(_ value: EventDesignLibrary) throws {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try write(JSONEncoder().encode(value), file)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete, .posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch {
            storageError = "Event design could not be saved on this iPad. Your edits are kept in setup; try again."
            throw SetupFailure(storageError!)
        }
    }
}
