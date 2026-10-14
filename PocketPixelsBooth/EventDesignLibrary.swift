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
        case .cashOnly: "Guests pay the attendant, who confirms on this iPad."
        case .qrAndCash: "Guests choose QR Ph or cash confirmed by the attendant."
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
        case .cashOnly: "Cash — attendant confirmed"
        case .qrAndCash: "QR Ph — provider verified · Cash — attendant confirmed"
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

    /// Same operator-editable content. Timestamps and server links (owned by the library) are ignored.
    func hasSameContent(as other: SavedEventDesign?) -> Bool {
        guard var other else { return false }
        other.updatedAt = updatedAt
        other.serverEvents = serverEvents
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

    func design(id: String?) -> SavedEventDesign? {
        guard let id else { return nil }
        return events.first { $0.id == id }
    }

    func design(linkedTo serverEventID: String, binding: String) -> SavedEventDesign? {
        events.first { $0.serverEvents[binding] == serverEventID }
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

    init(directory: URL? = nil,
         write: @escaping (Data, URL) throws -> Void = { try DurableFileWriter.write($0, to: $1) },
         legacyProfile: () -> EventProfile = { EventProfileStore.load() },
         legacyName: () -> String = { CommercialEventRunStore.load().name }) {
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
    func save(_ design: SavedEventDesign) throws {
        var next = library
        var value = design
        value.updatedAt = Date()
        if let index = next.events.firstIndex(where: { $0.id == design.id }) {
            // Server links are recorded by `link`; a design draft never removes one.
            value.serverEvents = next.events[index].serverEvents.merging(design.serverEvents) { _, draft in draft }
            next.events[index] = value
        } else { next.events.append(value) }
        try commit(next)
    }

    func create(name: String, venue: String) throws -> SavedEventDesign {
        let design = SavedEventDesign.new(name: name.trimmingCharacters(in: .whitespacesAndNewlines), venue: venue.trimmingCharacters(in: .whitespacesAndNewlines))
        try save(design)
        return design
    }

    /// Links a saved event to a server event in one payments environment. A server event is
    /// linked to at most one saved event per environment.
    func link(designID: String, binding: String, serverEventID: String) throws {
        var next = library
        for index in next.events.indices where next.events[index].serverEvents[binding] == serverEventID && next.events[index].id != designID {
            next.events[index].serverEvents.removeValue(forKey: binding)
        }
        guard let index = next.events.firstIndex(where: { $0.id == designID }) else { throw SetupFailure("That event is no longer saved.") }
        next.events[index].serverEvents[binding] = serverEventID
        next.events[index].updatedAt = Date()
        try commit(next)
    }

    /// The saved event for a server event, creating a plain (logo off) design the first time.
    func adopt(serverEventID: String, name: String, venue: String, binding: String) throws -> SavedEventDesign {
        if let existing = library.design(linkedTo: serverEventID, binding: binding) { return existing }
        var design = SavedEventDesign.new(name: name, venue: venue)
        design.serverEvents[binding] = serverEventID
        try save(design)
        return design
    }

    func setRegularServerEvent(_ serverEventID: String, binding: String) throws {
        var next = library
        next.regularServerEvents[binding] = serverEventID
        try commit(next)
    }

    func recordApplied(eventModeEnabled: Bool, eventID: String?) throws {
        var next = library
        next.appliedEventModeEnabled = eventModeEnabled
        next.appliedEventID = eventModeEnabled ? eventID : nil
        try commit(next)
    }

    private func commit(_ next: EventDesignLibrary) throws {
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
