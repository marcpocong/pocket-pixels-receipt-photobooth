import Foundation
import Combine

/// Stable primary destinations. Existing typed detail routes remain decodable.
nonisolated enum OperatorPrimaryDestination: String, Codable, CaseIterable, Identifiable, Sendable {
    case home, booth, sessions, events, reports, system
    // `system` remains decodable for existing navigation files, as a utility destination.
    static let allCases: [Self] = [.home, .booth, .sessions, .events, .reports]
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var systemImage: String {
        switch self {
        case .home: "house"
        case .booth: "camera"
        case .sessions: "photo.stack"
        case .events: "calendar"
        case .reports: "chart.bar.xaxis"
        case .system: "slider.horizontal.3"
        }
    }
}

nonisolated enum OperatorWorkspaceRoute: Codable, Hashable, Sendable {
    case liveEvent, manageEvent, payments, charging, eventSetup, boothCheck, receiptDesign, stickers, samplePrints
    case equipment, advanced, printer, recovery, camera, gallery, waitingGalleries, recentSessions, storage, printHistory
    case serverEvent(String)
    case sessionSetup, branding, sales, eventReport(String), eventMaintenance(String)
    case savedDrafts, draftReview(SavedDraftID)
    case newEvent, customizeEvent, previousEvent, savedEvent(String), eventHistory, eventLibrary, regularBooth, regularFooter, monitoring

    var primaryDestination: OperatorPrimaryDestination {
        switch self {
        case .recentSessions: .sessions
        case .regularBooth, .regularFooter: .booth
        case .sales, .eventReport: .reports
        case .equipment, .advanced, .printer, .recovery, .camera, .gallery, .waitingGalleries,
             .storage, .printHistory, .payments, .monitoring, .boothCheck: .system
        default: .events
        }
    }

    var title: String {
        switch self {
        case .liveEvent: "Edit Live Event"
        case .newEvent: "Quick Start Event"
        case .customizeEvent: "Customize New Event"
        case .previousEvent: "Use Previous Event"
        case .savedEvent: "Event Setup"
        case .eventHistory: "Event History"
        case .eventLibrary: "Saved Events"
        case .regularBooth: "Regular Booth"
        case .regularFooter: "Receipt & Footer"
        case .monitoring: "Monitoring"
        case .savedDrafts, .draftReview: "Saved Drafts"
        case .manageEvent: "Event Library & History"
        case .sales: "Reports & Statistics"
        case .payments: "Payment Maintenance"
        case .charging, .sessionSetup: "Event Setup"
        case .eventSetup, .branding: "Branding & Design"
        case .boothCheck: "Booth Check"
        case .receiptDesign: "Receipt Design & Branding"
        case .stickers: "Sticker Studio"
        case .samplePrints: "Print Display Samples"
        case .equipment: "Equipment"
        case .advanced: "Advanced"
        case .printer: "Printer Setup"
        case .recovery: "Help & Recovery"
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
    nonisolated struct Snapshot: Codable, Sendable {
        var schemaVersion = 1
        var resumeSetup = false
        var path: [OperatorWorkspaceRoute] = []
        // Optional additions preserve the v1 file and every pre-dashboard route/draft.
        var primaryDestination: OperatorPrimaryDestination?
        var sectionPaths: [String: [OperatorWorkspaceRoute]]?
        var setupStage: Int?
        var reportTab: String?
        var reportRunID: String?
        var serverDrafts: [String: OperatorServerSetupDraft] = [:]
        var brandingDraft: EventProfile?
        var prepaidDraft: CommercialEventRun?
        var newEventName = ""
        var newEventVenue = ""
        var sessionSetup: OperatorSessionSetupDraft?
        /// Unsaved event design edits keyed by saved-event ID, so switching events never mixes
        /// one event's logo into another's.
        var designDrafts: [String: SavedEventDesign]?
        var regularBoothDraft: RegularBoothSettings?
        var unfinishedEventID: String?
    }

    @Published private(set) var primaryDestination: OperatorPrimaryDestination
    @Published var path: [OperatorWorkspaceRoute] {
        didSet {
            snapshot.path = path
            var paths = snapshot.sectionPaths ?? [:]
            paths[primaryDestination.rawValue] = path
            snapshot.sectionPaths = paths
            persist()
        }
    }
    @Published private(set) var snapshot: Snapshot
    @Published private(set) var persistenceError: String?
    @Published private(set) var savingDraft = false
    private var pendingDraftWrite: Task<Void, Never>?
    private let file: URL
    private let write: (Data, URL) throws -> Void
    private var unreadableOriginal = false
    private let backgroundWrites: Bool
    private let diskQueue = DispatchQueue(label: "com.pocketpixels.workspace-drafts", qos: .utility)
    private var writeRevision = 0
    private let diskResult = WorkspaceDraftResult()

    init(directory: URL? = nil, backgroundWrites: Bool? = nil, write: @escaping (Data, URL) throws -> Void = { try DurableFileWriter.write($0, to: $1) }) {
        let root = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        file = root.appendingPathComponent("OperatorWorkspaceV1", isDirectory: true).appendingPathComponent("setup.json")
        self.write = write
        self.backgroundWrites = backgroundWrites ?? (directory == nil)
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
        var destination = loaded.primaryDestination ?? loaded.path.first?.primaryDestination ?? .home
        // Migrate only former browser/settings roots. Preserve deeper paths and all drafts.
        var paths = loaded.sectionPaths ?? [:]
        for (legacyKey, routes) in paths {
            if let first = routes.first, first == .recentSessions || first == .regularBooth {
                let target = first.primaryDestination
                if paths[target.rawValue] == nil { paths[target.rawValue] = Array(routes.dropFirst()) }
                paths[legacyKey] = []
            }
        }
        if let first = loaded.path.first, first == .recentSessions || first == .regularBooth {
            destination = first.primaryDestination
            loaded.path.removeFirst()
        }
        loaded.sectionPaths = paths
        // Older homes pushed Reports or Equipment as a detail. Those are primary roots now;
        // retain any deeper route while removing the redundant back-to-the-same-screen step.
        if loaded.primaryDestination == nil,
           (destination == .reports && loaded.path.first == .sales) || (destination == .system && loaded.path.first == .equipment) {
            loaded.path.removeFirst()
        }
        loaded.primaryDestination = destination
        snapshot = loaded
        primaryDestination = destination
        path = loaded.path
    }

    /// The guest shortcut reflects unfinished edits, never navigation or a legacy resume flag.
    var hasPendingSetup: Bool { hasUnsavedDrafts }
    var hasUnsavedDrafts: Bool { hasUnsavedEventSetup || snapshot.regularBoothDraft != nil }
    /// Regular defaults are for a different operating mode and cannot change the event
    /// that Resume revalidates. Keep its original staged-event guard scoped to event edits.
    var hasUnsavedEventSetup: Bool {
        !snapshot.serverDrafts.isEmpty || snapshot.brandingDraft != nil || snapshot.prepaidDraft != nil
            || !snapshot.newEventName.isEmpty || !snapshot.newEventVenue.isEmpty || snapshot.sessionSetup != nil
            || !(snapshot.designDrafts ?? [:]).isEmpty
    }
    var currentSection: String { path.last?.title ?? primaryDestination.title }
    var serverBinding: String {
        guard let configuration = PaymentsConfiguration.current() else { return "unpaired" }
        return "\(configuration.environment):\(configuration.baseURL.absoluteString)"
    }

    /// Changing sections checkpoints navigation only; draft and live event stores are untouched.
    func select(_ destination: OperatorPrimaryDestination) {
        guard destination != primaryDestination else { return }
        var paths = snapshot.sectionPaths ?? [:]
        paths[primaryDestination.rawValue] = path
        snapshot.sectionPaths = paths
        primaryDestination = destination
        snapshot.primaryDestination = destination
        path = paths[destination.rawValue] ?? []
    }

    func navigate(to route: OperatorWorkspaceRoute) {
        select(route.primaryDestination)
        path = [.sales, .equipment, .recentSessions, .regularBooth].contains(route) ? [] : [route]
    }

    func showCurrentReport() {
        saveReportSelection(tab: "Overview", runID: nil)
        navigate(to: .sales)
    }

    func open() { persist() }
    func checkpoint() { pendingDraftWrite?.cancel(); pendingDraftWrite = nil; enqueueWrite() }
    func saveUnfinishedEventID(_ id: String?) { snapshot.unfinishedEventID = id; persist() }
    func saveSetupStage(_ stage: Int) { snapshot.setupStage = stage; persist() }
    func saveReportSelection(tab: String, runID: String?) {
        snapshot.reportTab = tab; snapshot.reportRunID = runID; persist()
    }
    func finish(keepingDrafts: Bool) {
        if keepingDrafts { persist(); return }
        snapshot = Snapshot()
        primaryDestination = .home
        path = []
        persist()
    }

    func serverDraft(eventID: String) -> OperatorServerSetupDraft? {
        snapshot.serverDrafts["\(serverBinding):\(eventID)"]
    }
    func saveServerDraft(_ draft: OperatorServerSetupDraft) {
        guard snapshot.serverDrafts["\(draft.serverBinding):\(draft.eventID)"] != draft else { return }
        snapshot.serverDrafts["\(draft.serverBinding):\(draft.eventID)"] = draft
        persist()
    }
    func removeServerDraft(eventID: String) {
        guard snapshot.serverDrafts["\(serverBinding):\(eventID)"] != nil else { return }
        snapshot.serverDrafts.removeValue(forKey: "\(serverBinding):\(eventID)")
        persist()
    }
    func saveRegularBoothDraft(_ draft: RegularBoothSettings?) { guard snapshot.regularBoothDraft != draft else { return }; snapshot.regularBoothDraft = draft; persist() }
    func saveBrandingDraft(_ draft: EventProfile?) { guard snapshot.brandingDraft != draft else { return }; snapshot.brandingDraft = draft; persist() }
    func savePrepaidDraft(_ draft: CommercialEventRun?) { guard snapshot.prepaidDraft != draft else { return }; snapshot.prepaidDraft = draft; persist() }
    func saveSessionSetup(_ draft: OperatorSessionSetupDraft?) { guard snapshot.sessionSetup != draft else { return }; snapshot.sessionSetup = draft; persist() }
    func designDraft(id: String) -> SavedEventDesign? { snapshot.designDrafts?[id] }
    func saveDesignDraft(_ draft: SavedEventDesign?, id: String) {
        guard snapshot.designDrafts?[id] != draft else { return }
        var drafts = snapshot.designDrafts ?? [:]
        drafts[id] = draft
        snapshot.designDrafts = drafts.isEmpty ? nil : drafts
        persist()
    }
    func saveNewEvent(name: String, venue: String) {
        guard snapshot.newEventName != name || snapshot.newEventVenue != venue else { return }
        snapshot.newEventName = name; snapshot.newEventVenue = venue; persist()
    }

    func restoreEventDrafts(from original: Snapshot, designID: String?, eventID: String?) {
        if let designID {
            var drafts = snapshot.designDrafts ?? [:]
            drafts[designID] = original.designDrafts?[designID]
            snapshot.designDrafts = drafts.isEmpty ? nil : drafts
        }
        if let eventID {
            let key = "\(serverBinding):\(eventID)"
            snapshot.serverDrafts[key] = original.serverDrafts[key]
        }
        snapshot.prepaidDraft = original.prepaidDraft
        snapshot.sessionSetup = original.sessionSetup
        persist()
    }

    var storedDraftIDs: [SavedDraftID] {
        var ids = (snapshot.designDrafts ?? [:]).keys.map { SavedDraftID.design($0) }
        ids += snapshot.serverDrafts.values.map { .payment(binding: $0.serverBinding, eventID: $0.eventID) }
        if snapshot.brandingDraft != nil { ids.append(.branding) }
        if snapshot.regularBoothDraft != nil { ids.append(.regularBooth) }
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
        case .regularBooth: candidate.regularBoothDraft = nil
        case .newEvent: candidate.newEventName = ""; candidate.newEventVenue = ""
        }
        candidate.resumeSetup = !candidate.serverDrafts.isEmpty || candidate.brandingDraft != nil || candidate.prepaidDraft != nil
            || candidate.sessionSetup != nil || !candidate.newEventName.isEmpty || !candidate.newEventVenue.isEmpty || !(candidate.designDrafts ?? [:]).isEmpty || candidate.regularBoothDraft != nil
        do {
            diskQueue.sync {}
            try write(JSONEncoder().encode(candidate), file)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete, .posixPermissions: 0o600], ofItemAtPath: file.path)
            snapshot = candidate
            writeRevision += 1
            let result = diskResult
            diskQueue.sync { result.error = nil }
            persistenceError = nil
        } catch {
            persistenceError = "The draft could not be discarded. Your edits are still saved; try again."
            throw SetupFailure(persistenceError!)
        }
    }

    /// Flush before reporting an explicit save as durable. Navigation and keystrokes enqueue
    /// ordered writes without making the UI wait for F_FULLFSYNC.
    func flush() async {
        guard backgroundWrites else { return }
        pendingDraftWrite?.cancel(); pendingDraftWrite = nil
        enqueueWrite()
        let result = diskResult
        persistenceError = await withCheckedContinuation { continuation in
            diskQueue.async { continuation.resume(returning: result.error) }
        }
    }

    private func persist() {
        guard !unreadableOriginal else { return }
        if snapshot.resumeSetup != hasUnsavedDrafts { snapshot.resumeSetup = hasUnsavedDrafts }
        guard backgroundWrites else { enqueueWrite(); return }
        savingDraft = true
        pendingDraftWrite?.cancel()
        pendingDraftWrite = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            guard let self else { return }
            self.pendingDraftWrite = nil
            self.enqueueWrite()
        }
    }

    private func enqueueWrite() {
        guard !unreadableOriginal else { return }
        let value = snapshot, file = file, write = write
        writeRevision += 1
        let revision = writeRevision
        let job = WorkspaceDraftWrite(value: value, file: file, write: write)
        let result = diskResult
        if backgroundWrites {
            diskQueue.async { [weak self] in
                let error = job.perform()
                result.error = error
                Task { @MainActor [weak self] in
                    guard let self, self.writeRevision == revision else { return }
                    self.persistenceError = error
                    if self.pendingDraftWrite == nil { self.savingDraft = false }
                }
            }
        } else { persistenceError = job.perform() }
    }
}

/// Only draft bytes cross this serial queue. Admission, creation intents and print journals
/// keep their own durability barriers; a background draft write cannot authorize a guest.
nonisolated private struct WorkspaceDraftWrite: @unchecked Sendable {
    let value: OperatorWorkspace.Snapshot
    let file: URL
    let write: (Data, URL) throws -> Void
    func perform() -> String? {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try write(JSONEncoder().encode(value), file)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete, .posixPermissions: 0o600], ofItemAtPath: file.path)
            return nil
        } catch { return "Setup could not be saved on this iPad. Keep the app open; your edits are still in memory." }
    }
}

nonisolated private final class WorkspaceDraftResult: @unchecked Sendable { var error: String? }
