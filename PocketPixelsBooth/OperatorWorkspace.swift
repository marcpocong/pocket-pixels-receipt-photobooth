import Foundation
import Combine

nonisolated enum OperatorWorkspaceRoute: Codable, Hashable, Sendable {
    case manageEvent, payments, charging, eventSetup, boothCheck, receiptDesign, stickers, samplePrints
    case equipment, advanced, printer, recovery, camera, gallery, waitingGalleries, recentSessions, storage, printHistory
    case serverEvent(String)
    case sessionSetup, branding, sales, eventReport(String), eventMaintenance(String)
    case savedDrafts, draftReview(SavedDraftID)

    var title: String {
        switch self {
        case .savedDrafts, .draftReview: "Saved Drafts"
        case .manageEvent, .sales: "Sales & History"
        case .payments: "Payment Maintenance"
        case .charging, .sessionSetup: "Session Setup"
        case .eventSetup, .branding: "Branding & Design"
        case .boothCheck: "Booth Check"
        case .receiptDesign: "Receipt Design & Branding"
        case .stickers: "Sticker Studio"
        case .samplePrints: "Print Display Samples"
        case .equipment: "Equipment"
        case .advanced: "Advanced"
        case .printer: "Printer Setup"
        case .recovery: "Fix Printer"
        case .camera: "Camera Check"
        case .gallery: "Gallery Setup"
        case .waitingGalleries: "Waiting Galleries"
        case .recentSessions: "Recent Sessions"
        case .storage: "Storage"
        case .printHistory: "Print History"
        case .serverEvent: "Server Event"
        case .eventReport: "Event Sales"
        case .eventMaintenance: "Event Maintenance"
        }
    }
}

nonisolated struct OperatorServerSetupDraft: Codable, Equatable, Sendable {
    let eventID: String
    let serverBinding: String
    var baseVersion: Int
    var name: String
    var venue: String
    var policy: ServerPolicyDraft
    var baseline: PaymentDraftBaseline? = nil

    func conflicts(with serverVersion: Int) -> Bool { baseVersion != serverVersion }
}

/// Only non-sensitive setup data. Authentication, API tokens and customer records never enter this file.
@MainActor final class OperatorWorkspace: ObservableObject {
    static let shared = OperatorWorkspace()
    static let didUnlock = Notification.Name("pocketPixels.operator.didUnlock")
    static let didStartSessions = Notification.Name("pocketPixels.operator.didStartSessions")
    static let didResumeCheckout = Notification.Name("pocketPixels.operator.didResumeCheckout")
    nonisolated struct Snapshot: Codable {
        var schemaVersion = 1
        var resumeSetup = false
        var path: [OperatorWorkspaceRoute] = []
        var serverDrafts: [String: OperatorServerSetupDraft] = [:]
        var brandingDraft: EventProfile?
        var prepaidDraft: CommercialEventRun?
        var newEventName = ""
        var newEventVenue = ""
        var sessionSetup: OperatorSessionSetupDraft?
        /// Unsaved event design edits keyed by saved-event ID, so switching events never mixes
        /// one event's logo into another's.
        var designDrafts: [String: SavedEventDesign]?
    }

    @Published var path: [OperatorWorkspaceRoute] { didSet { snapshot.path = path; persist() } }
    @Published private(set) var snapshot: Snapshot
    @Published private(set) var persistenceError: String?
    private let file: URL
    private let write: (Data, URL) throws -> Void
    private var unreadableOriginal = false

    init(directory: URL? = nil, write: @escaping (Data, URL) throws -> Void = { try DurableFileWriter.write($0, to: $1) }) {
        let root = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        file = root.appendingPathComponent("OperatorWorkspaceV1", isDirectory: true).appendingPathComponent("setup.json")
        self.write = write
        var loaded = Snapshot()
        if FileManager.default.fileExists(atPath: file.path) {
            do {
                loaded = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: file))
                guard loaded.schemaVersion == 1 else { throw CocoaError(.fileReadCorruptFile) }
            } catch {
                unreadableOriginal = true
                persistenceError = "Saved setup could not be read. Its file is preserved; new edits remain in memory only."
            }
        }
        snapshot = loaded
        path = loaded.path
    }

    /// The guest shortcut reflects unfinished edits, never navigation or a legacy resume flag.
    var hasPendingSetup: Bool { hasUnsavedDrafts }
    var hasUnsavedDrafts: Bool {
        !snapshot.serverDrafts.isEmpty || snapshot.brandingDraft != nil || snapshot.prepaidDraft != nil
            || !snapshot.newEventName.isEmpty || !snapshot.newEventVenue.isEmpty || snapshot.sessionSetup != nil
            || !(snapshot.designDrafts ?? [:]).isEmpty
    }
    var currentSection: String { path.last?.title ?? "Operator" }
    var serverBinding: String {
        guard let configuration = PaymentsConfiguration.current() else { return "unpaired" }
        return "\(configuration.environment):\(configuration.baseURL.absoluteString)"
    }

    func open() { persist() }
    func checkpoint() { persist() }
    func finish(keepingDrafts: Bool) {
        if keepingDrafts { persist(); return }
        snapshot = Snapshot()
        path = []
        persist()
    }

    func serverDraft(eventID: String) -> OperatorServerSetupDraft? {
        snapshot.serverDrafts["\(serverBinding):\(eventID)"]
    }
    func saveServerDraft(_ draft: OperatorServerSetupDraft) {
        snapshot.serverDrafts["\(draft.serverBinding):\(draft.eventID)"] = draft
        persist()
    }
    func removeServerDraft(eventID: String) {
        snapshot.serverDrafts.removeValue(forKey: "\(serverBinding):\(eventID)")
        persist()
    }
    func saveBrandingDraft(_ draft: EventProfile?) { snapshot.brandingDraft = draft; persist() }
    func savePrepaidDraft(_ draft: CommercialEventRun?) { snapshot.prepaidDraft = draft; persist() }
    func saveSessionSetup(_ draft: OperatorSessionSetupDraft?) { snapshot.sessionSetup = draft; persist() }
    func designDraft(id: String) -> SavedEventDesign? { snapshot.designDrafts?[id] }
    func saveDesignDraft(_ draft: SavedEventDesign?, id: String) {
        var drafts = snapshot.designDrafts ?? [:]
        drafts[id] = draft
        snapshot.designDrafts = drafts.isEmpty ? nil : drafts
        persist()
    }
    func saveNewEvent(name: String, venue: String) {
        snapshot.newEventName = name; snapshot.newEventVenue = venue; persist()
    }

    var storedDraftIDs: [SavedDraftID] {
        var ids = (snapshot.designDrafts ?? [:]).keys.map { SavedDraftID.design($0) }
        ids += snapshot.serverDrafts.values.map { .payment(binding: $0.serverBinding, eventID: $0.eventID) }
        if snapshot.brandingDraft != nil { ids.append(.branding) }
        if snapshot.prepaidDraft != nil { ids.append(.prepaid) }
        if snapshot.sessionSetup != nil { ids.append(.sessionSelection) }
        if !snapshot.newEventName.isEmpty || !snapshot.newEventVenue.isEmpty { ids.append(.newEvent) }
        return ids
    }

    /// Scoped, commit-after-write discard; a failed disk write keeps the visible draft intact.
    func discardDraft(_ id: SavedDraftID, authorized: () -> Bool = { OperatorAccessPermit.shared.isAuthorized }) throws {
        guard authorized() else { throw SetupFailure("Unlock Operator again before discarding changes.") }
        guard !unreadableOriginal else { throw SetupFailure("Saved drafts could not be read. The original file is preserved.") }
        var candidate = snapshot
        switch id {
        case .design(let key): candidate.designDrafts?.removeValue(forKey: key)
        case .payment(let binding, let event): candidate.serverDrafts.removeValue(forKey: "\(binding):\(event)")
        case .branding: candidate.brandingDraft = nil
        case .prepaid: candidate.prepaidDraft = nil
        case .sessionSelection: candidate.sessionSetup = nil
        case .newEvent: candidate.newEventName = ""; candidate.newEventVenue = ""
        }
        candidate.resumeSetup = !candidate.serverDrafts.isEmpty || candidate.brandingDraft != nil || candidate.prepaidDraft != nil
            || candidate.sessionSetup != nil || !candidate.newEventName.isEmpty || !candidate.newEventVenue.isEmpty || !(candidate.designDrafts ?? [:]).isEmpty
        do {
            try write(JSONEncoder().encode(candidate), file)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete, .posixPermissions: 0o600], ofItemAtPath: file.path)
            snapshot = candidate
            persistenceError = nil
        } catch {
            persistenceError = "The draft could not be discarded. Your edits are still saved; try again."
            throw SetupFailure(persistenceError!)
        }
    }

    private func persist() {
        guard !unreadableOriginal else { return }
        snapshot.resumeSetup = hasUnsavedDrafts
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try write(JSONEncoder().encode(snapshot), file)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete,
                .posixPermissions: 0o600], ofItemAtPath: file.path)
            persistenceError = nil
        } catch {
            persistenceError = "Setup could not be saved on this iPad. Keep the app open; your edits are still in memory."
        }
    }
}
