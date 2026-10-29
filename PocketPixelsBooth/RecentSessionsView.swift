//
//  RecentSessionsView.swift
//  PocketPixelsBooth
//

import Combine
import SwiftUI
import UIKit

nonisolated enum RecentSessionScope: String, CaseIterable, Identifiable {
    case currentEvent = "Current Event", regularBooth = "Regular Booth", allHistory = "All History"
    var id: String { rawValue }

    func includes(_ summary: RecentSessionArchiveSummary, runID: String?) -> Bool {
        switch self {
        case .allHistory: return true
        case .currentEvent: return runID != nil && summary.eventRunID == runID
        case .regularBooth:
            // Known legacy booth records have no event profile or run/design association.
            // Unreadable and ambiguous event records stay available in All History.
            return summary.rasterFingerprint != "CORRUPT" && summary.eventRunID == nil
                && summary.eventDesignID == nil && summary.isKnownRegularBooth
        }
    }
}

@MainActor
final class RecentSessionsViewModel: ObservableObject {
    @Published private(set) var summaries: [RecentSessionArchiveSummary] = []
    @Published private(set) var galleryStatuses: [String: ArchivedGalleryStatus] = [:]
    @Published private(set) var printStatuses: [String: ArchivedPrintSummary] = [:]
    @Published private(set) var filteredSummaries: [RecentSessionArchiveSummary] = []
    @Published private(set) var groupedSummaries: [(String, [RecentSessionArchiveSummary])] = []
    @Published private(set) var isLoading = false
    @Published private(set) var hasLoaded = false
    @Published var scope: RecentSessionScope = .allHistory { didSet { selectedArchiveID = nil; eventFilter = nil; rebuildFilters() } }
    @Published private(set) var currentEventRunID: String?
    @Published private(set) var currentEventName: String?
    private var contextInitialized = false
    func configureContext(run: EventRunRecord?, eventApplied: Bool) {
        let current = eventApplied && run.map { [.active, .paused].contains($0.status) } == true ? run : nil
        let changed = !contextInitialized || currentEventRunID != current?.id || (currentEventName != nil) != eventApplied
        currentEventRunID = current?.id
        currentEventName = eventApplied ? (current?.displayName ?? "Event association unavailable") : nil
        if changed {
            contextInitialized = true
            scope = eventApplied ? .currentEvent : .regularBooth
        }
    }
    @Published var searchText = "" { didSet { rebuildFilters() } }
    @Published var formatFilter: BoothFormat? { didSet { rebuildFilters() } }
    @Published var showsOnlyAttention = false { didSet { rebuildFilters() } }
    @Published var todayOnly = false { didSet { rebuildFilters() } }
    @Published var eventFilter: String? { didSet { rebuildFilters() } }
    @Published var dateFrom: Date? { didSet { rebuildFilters() } }
    @Published var dateThrough: Date? { didSet { rebuildFilters() } }
    @Published var usesPhotoGrid = true
    @Published var showsHidden = false { didSet { rebuildFilters() } }
    @Published var selectedArchiveID: String? {
        willSet {
            if newValue != nil && newValue != selectedArchiveID { detailReturnOffset = browserOffset }
        }
    }
    // Geometry updates do not publish or rebuild every row during a scroll.
    private var browserOffsets: [Bool: CGFloat] = [:]
    private(set) var detailReturnOffset: CGFloat = 0
    var browserOffset: CGFloat { browserOffsets[usesPhotoGrid] ?? 0 }
    func recordBrowserOffset(_ offset: CGFloat) {
        browserOffsets[usesPhotoGrid] = max(0, offset)
    }
    @Published var statusMessage = ""
    @Published private(set) var loadError: String?
    let thumbnails = SessionThumbnailCache()
    private let store: RecentSessionArchiveStore?
    private let summaryLoader: (@Sendable () throws -> [RecentSessionArchiveSummary])?
    private var refreshTask: Task<Void, Never>?
    private var statusTask: Task<Void, Never>?
    private var subscriptions = Set<AnyCancellable>()
    private var verifiedArchives = Set<String>()
    private var verificationRevision = 0
    private var incrementalProofRevisions: [String: Int] = [:]
    private var verificationTask: Task<Void, Never>?
    private var recheckObservations: [String: ArchivedGalleryStatus] = [:]
    @Published private(set) var isVerifying = false
    @Published private(set) var verificationResult = ""
    private let verificationStore: GalleryVerificationStore?
    private let recheckSession: URLSession?
    private let photosWriter: any PhotosLibraryWriting
    private let mediaDeletionInspector: @MainActor (RecentSessionArchiveSummary) throws -> RecordCleanupDecision
    private let managementAuthorized: @MainActor () -> Bool
    private var searchIndex: [String: String] = [:]
    private var pendingIndex: [String: GalleryPendingUploadSummary] = [:]
    static let unreadableSectionTitle = "Unreadable archives"

    init(store: RecentSessionArchiveStore? = nil, summaryLoader: (@Sendable () throws -> [RecentSessionArchiveSummary])? = nil, verificationStore: GalleryVerificationStore? = nil, recheckSession: URLSession? = nil, photosWriter: any PhotosLibraryWriting = SystemPhotosLibraryWriter(),
        managementAuthorized: @escaping @MainActor () -> Bool = { OperatorAccessPermit.shared.isAuthorized },
        mediaDeletionInspector: @escaping @MainActor (RecentSessionArchiveSummary) throws -> RecordCleanupDecision = { try SessionMediaOperations.sessionDeletionDecision($0) },
        pendingUploadPublisher: AnyPublisher<[GalleryPendingUploadSummary], Never>? = nil) {
        self.verificationStore = verificationStore ?? (try? GalleryVerificationStore())
        self.recheckSession = recheckSession
        self.photosWriter = photosWriter
        self.managementAuthorized = managementAuthorized
        self.mediaDeletionInspector = mediaDeletionInspector
        self.summaryLoader = summaryLoader
        do { self.store = try store ?? RecentSessionArchiveStore() }
        catch { self.store = nil; statusMessage = "Recent Sessions storage needs attention: \(error.localizedDescription)" }
        let operations = EventOperationalState.shared
        operations.$auditRecords.sink { [weak self] records in
            guard let self else { return }
            let groups = Dictionary(grouping: records, by: \.sessionIdentifier)
            self.printStatuses = groups.mapValues { ArchivedPrintSummary.resolve(records: $0) }
            self.rebuildFilters()
        }.store(in: &subscriptions)
        let pendingUpdates = pendingUploadPublisher ?? operations.$pendingUploads.eraseToAnyPublisher()
        pendingUpdates.sink { [weak self] pending in
            guard let self else { return }
            self.updatePendingUploadSnapshot(pending)
        }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: .originalPhotoRetentionFailed)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.retentionFailure = .init(message: "Original photo retention failed. Saved receipts and printing remain available. Check storage before the next session.", isError: true)
            }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: GalleryVerificationStore.changed)
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                guard let identity = notification.userInfo?["identity"] as? String else { return }
                self?.refreshVerification(identity: identity)
            }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)
            .sink { [weak self] _ in
                guard let cache = self?.thumbnails else { return }
                Task { await cache.removeAll() }
            }.store(in: &subscriptions)
    }

    var events: [String] { Array(Set(summaries.map { $0.eventName ?? "Regular Booth" })).sorted() }
    var selectedSummary: RecentSessionArchiveSummary? { filteredSummaries.first { $0.archiveID == selectedArchiveID } }
    var storagePath: String { store?.storagePath ?? "Unavailable" }

    private func rebuildFilters() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let calendar = Calendar.current
        let end = dateThrough.flatMap { calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: $0)) }
        filteredSummaries = summaries.filter { summary in
            if !scope.includes(summary, runID: currentEventRunID) { return false }
            if summary.isHidden && !showsHidden { return false }
            if let formatFilter, summary.format != formatFilter || summary.rasterFingerprint == "CORRUPT" { return false }
            if showsOnlyAttention && !needsAttention(summary) { return false }
            if todayOnly && !calendar.isDateInToday(summary.createdAt) { return false }
            if let eventFilter, (summary.eventName ?? "Regular Booth") != eventFilter { return false }
            if let dateFrom, summary.createdAt < calendar.startOfDay(for: dateFrom) { return false }
            if let end, summary.createdAt >= end { return false }
            return query.isEmpty || (searchIndex[summary.archiveID]?.contains(query) ?? false)
        }
        var groups: [(String, [RecentSessionArchiveSummary])] = []
        var indices: [String: Int] = [:]
        for summary in filteredSummaries {
            let title: String
            if summary.rasterFingerprint == "CORRUPT" || summary.createdAt == .distantPast { title = Self.unreadableSectionTitle }
            else if calendar.isDateInToday(summary.createdAt) { title = "Today" }
            else if calendar.isDateInYesterday(summary.createdAt) { title = "Yesterday" }
            else { title = Self.sectionDateFormatter.string(from: summary.createdAt) }
            if let index = indices[title] { groups[index].1.append(summary) }
            else { indices[title] = groups.count; groups.append((title, [summary])) }
        }
        groupedSummaries = groups
    }

    func clearFilters() {
        searchText = ""; formatFilter = nil; showsOnlyAttention = false; todayOnly = false
        eventFilter = nil; dateFrom = nil; dateThrough = nil
    }
    func galleryStatus(for summary: RecentSessionArchiveSummary) -> ArchivedGalleryStatus { galleryStatuses[summary.archiveID] ?? .unknown }
    func printSummary(for summary: RecentSessionArchiveSummary) -> ArchivedPrintSummary { printStatuses[summary.sessionIdentifier] ?? .notRecorded }
    func needsAttention(_ summary: RecentSessionArchiveSummary) -> Bool {
        summary.rasterFingerprint == "CORRUPT" || galleryStatus(for: summary).isAttention || printSummary(for: summary).isAttention
    }
    func thumbnail(for summary: RecentSessionArchiveSummary) async -> UIImage? {
        guard let store, let filename = summary.thumbnailFilenames.first else { return nil }
        return await thumbnails.image(archiveID: summary.archiveID, filename: filename, store: store)
    }
    func updatePendingUploadSnapshot(_ pending: [GalleryPendingUploadSummary]) {
        pendingIndex = Dictionary(grouping: pending, by: \.galleryToken).compactMapValues(\.first)
        rebuildGalleryStatuses()
    }
    private func acceptIncrementalProof(_ archiveID: String) {
        verificationRevision += 1
        incrementalProofRevisions[archiveID] = verificationRevision
        verifiedArchives.insert(archiveID)
        // A new successful public read supersedes an earlier failed recheck. The queue may
        // still publish its old entry until the worker clears it immediately after this commit.
        recheckObservations[archiveID] = nil
    }
    private func rebuildGalleryStatuses() {
        galleryStatuses = Dictionary(uniqueKeysWithValues: summaries.map { summary in
            (summary.archiveID, recheckObservations[summary.archiveID] ?? ArchivedGalleryStatus.resolve(linkIsValid: summary.frozenGalleryURL.map { ArchivedGalleryLink(galleryURL: $0, galleryToken: summary.archiveID).isValid } ?? GalleryTokenGenerator.isValidGalleryToken(summary.archiveID),
                pendingItem: pendingIndex[summary.archiveID], verifiedAt: verifiedArchives.contains(summary.archiveID) ? Date.distantPast : nil))
        })
        rebuildFilters()
    }
    private func refreshVerification(identity: String) {
        guard let summary = summaries.first(where: { summary in
            summary.frozenGalleryURL.map { GalleryVerificationStore.identity(sessionID: summary.sessionIdentifier, token: summary.archiveID, url: $0) == identity } ?? false
        }), let url = summary.frozenGalleryURL, let verificationStore else { return }
        Task {
            let exists = await Task.detached(priority: .utility) {
                (try? verificationStore.evidence(sessionID: summary.sessionIdentifier, token: summary.archiveID, url: url)) != nil
            }.value
            guard exists, summaries.contains(where: { $0.archiveID == summary.archiveID && $0.sessionIdentifier == summary.sessionIdentifier && $0.frozenGalleryURL == url }) else { return }
            acceptIncrementalProof(summary.archiveID)
            galleryStatuses[summary.archiveID] = ArchivedGalleryStatus.resolve(linkIsValid: true,
                pendingItem: pendingIndex[summary.archiveID], verifiedAt: Date())
            rebuildFilters()
        }
    }

    private func refreshVerification() {
        statusTask?.cancel()
        let snapshot = summaries
        let evidenceStore = verificationStore
        let revisionAtStart = verificationRevision
        statusTask = Task {
            let result = await Task.detached(priority: .utility) { () -> (Set<String>, Bool) in
                var verified = Set<String>(); var failed = false
                for summary in snapshot {
                    guard !Task.isCancelled else { break }
                    guard let url = summary.frozenGalleryURL else { continue }
                    do {
                        if try evidenceStore?.evidence(sessionID: summary.sessionIdentifier, token: summary.archiveID, url: url) != nil {
                            verified.insert(summary.archiveID)
                        }
                    } catch { failed = true }
                }
                return (verified, failed)
            }.value
            guard !Task.isCancelled else { return }
            let newerProofs = Set(incrementalProofRevisions.filter { $0.value > revisionAtStart }.keys)
            verifiedArchives = result.0.union(newerProofs)
            if result.1 { announce("Some local gallery evidence could not be read. Recheck the original gallery after checking storage.", isError: true) }
            rebuildGalleryStatuses()
        }
    }

    /// Explicit operator action; one read at a time, at least one second apart. No upload or token creation.
    func verifyGalleries(_ selected: [RecentSessionArchiveSummary], includeReady: Bool = false) {
        guard !isVerifying else { return }
        isVerifying = true
        verificationTask = Task {
            var ready = 0, unknown = 0, failed = 0, skipped = 0
            var rateLimited = false
            let config = URLSessionConfiguration.ephemeral
            config.waitsForConnectivity = false; config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 45
            let session = recheckSession ?? URLSession(configuration: config, delegate: GoogleGalleryURLSessionDelegate(), delegateQueue: nil)
            let verifier = GoogleDriveGalleryUploadService(urlSession: session, verificationStore: verificationStore)
            defer { if recheckSession == nil { session.invalidateAndCancel() }; isVerifying = false }
            for summary in selected {
                if Task.isCancelled { skipped += selected.count - ready - unknown - failed - skipped; break }
                if !includeReady && galleryStatus(for: summary) == .verified { skipped += 1; continue }
                guard let url = summary.frozenGalleryURL, ArchivedGalleryLink(galleryURL: url, galleryToken: summary.archiveID).isValid else { skipped += 1; continue }
                recheckObservations[summary.archiveID] = .uploading
                galleryStatuses[summary.archiveID] = .uploading
                do {
                    let target = GalleryVerificationTarget(sessionID: summary.sessionIdentifier, token: summary.archiveID, url: url, photoCount: summary.photoCount)
                    try await verifier.verifyOriginalGallery(target)
                    pendingIndex[summary.archiveID] = nil
                    acceptIncrementalProof(summary.archiveID); galleryStatuses[summary.archiveID] = .verified; ready += 1
                } catch is CancellationError {
                    galleryStatuses[summary.archiveID] = .unknown; skipped += 1
                } catch GalleryPublicVerificationError.rateLimited {
                    galleryStatuses[summary.archiveID] = .needsAttention("The gallery service asked us to pause. Retry later")
                    failed += 1; rateLimited = true
                } catch GalleryPublicVerificationError.unavailable {
                    galleryStatuses[summary.archiveID] = .unavailable; failed += 1
                } catch GalleryUploadError.deliveryUnknown {
                    galleryStatuses[summary.archiveID] = .unknown; unknown += 1
                } catch {
                    galleryStatuses[summary.archiveID] = .needsAttention("Could not verify or save proof. Check network and local storage, then retry"); failed += 1
                }
                recheckObservations[summary.archiveID] = galleryStatuses[summary.archiveID]
                verificationResult = "\(ready) verified · \(unknown) still unknown · \(failed) failed · \(skipped) skipped"
                rebuildFilters()
                if rateLimited { skipped += selected.count - ready - unknown - failed - skipped; break }
                do { try await Task.sleep(for: .seconds(1)) } catch { }
            }
            verificationResult = "\(ready) verified · \(unknown) still unknown · \(failed) failed · \(skipped) skipped" + (Task.isCancelled ? " · cancelled" : rateLimited ? " · paused by gallery service" : "")
            announce(verificationResult, isError: failed > 0 || unknown > 0 || rateLimited)
        }
    }
    func cancelVerification() { verificationTask?.cancel() }

    func refresh() {
        guard let store else { loadError = "Recent Sessions storage is unavailable. Check local storage and retry."; hasLoaded = true; return }
        refreshTask?.cancel(); isLoading = true
        let loader = summaryLoader
        refreshTask = Task {
            let worker = Task.detached(priority: .utility) { Result { try loader?() ?? store.summaries(includePayloadSize: false) } }
            let result = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
            guard !Task.isCancelled else { return }
            switch result {
            case .success(let loaded):
                loadError = nil
                if !summaries.isEmpty {
                    let prior = Dictionary(uniqueKeysWithValues: summaries.map { ($0.archiveID, $0) })
                    for changed in loaded where prior[changed.archiveID].map({ $0.sessionIdentifier != changed.sessionIdentifier || $0.frozenGalleryURL != changed.frozenGalleryURL }) == true {
                        verifiedArchives.remove(changed.archiveID)
                        recheckObservations[changed.archiveID] = nil
                        incrementalProofRevisions[changed.archiveID] = nil
                    }
                }
                summaries = loaded
                searchIndex = Dictionary(uniqueKeysWithValues: loaded.map {
                    ($0.archiveID, [$0.sessionIdentifier, $0.archiveID, $0.format.displayName, $0.format.rawValue, $0.eventName ?? "Regular Booth"].joined(separator: " ").lowercased())
                })
                rebuildGalleryStatuses(); refreshVerification()
                statusMessage = loaded.isEmpty ? "No recent sessions yet." : "\(loaded.count) sessions · saved receipts on this iPad"
            case .failure(let error):
                loadError = "Session records could not be read. Originals are retained. " + error.localizedDescription
                statusMessage = loadError ?? error.localizedDescription
            }
            isLoading = false; hasLoaded = true; refreshTask = nil
        }
    }

    func loadArchive(_ archiveID: String) throws -> RecentSessionArchive {
        guard let store else {
            throw RecentSessionArchiveError.archiveNotFound
        }
        return try store.load(archiveID: archiveID)
    }

    func loadArchiveResult(_ archiveID: String) async -> Result<RecentSessionArchive, Error> {
        guard let store else {
            return .failure(RecentSessionArchiveError.archiveNotFound)
        }

        return await Task.detached(priority: .userInitiated) {
            Result {
                try store.load(archiveID: archiveID)
            }
        }.value
    }

    @Published private(set) var isExporting = false
    @Published private(set) var exportMessage = ""
    @Published var actionFeedback: OperatorActionFeedback?
    @Published var retentionFailure: OperatorActionFeedback?
    func dismissFeedback() { actionFeedback = nil; exportMessage = "" }
    private func announce(_ message: String, isError: Bool = false) {
        actionFeedback = .init(message: message, isError: isError)
    }
    func availablePhotos(_ archiveID: String) async throws -> [SessionPhotoSource] {
        guard let store else { throw MediaExportError.unavailable }
        return try await Task.detached(priority: .userInitiated) {
            let archive = try store.load(archiveID: archiveID)
            return try SessionMediaExport.photos(archive: archive, store: store,
                pending: try? GalleryPendingUploadStore(), recovery: try? AppRecoveryStore())
        }.value
    }
    func exportReceipt(_ archiveID: String) {
        guard !isExporting else { return }
        isExporting = true; exportMessage = "Saving receipt…"
        Task {
            defer { isExporting = false }
            do {
                let archive = try await loadArchiveResult(archiveID).get()
                try await SessionMediaExport.save(data: [archive.receiptPreviewPNGData], writer: photosWriter)
                exportMessage = "Receipt saved to Photos"
                announce(exportMessage)
            } catch {
                exportMessage = (error as? MediaExportError)?.localizedDescription ?? "Could not save; source media or storage unavailable."
                announce(exportMessage, isError: true)
            }
        }
    }
    func exportPhotos(_ archiveID: String, index: Int? = nil) {
        guard !isExporting else { return }
        isExporting = true; exportMessage = "Saving photos…"
        Task {
            defer { isExporting = false }
            do {
                let sources = try await availablePhotos(archiveID)
                let selected = index.map { target in sources.filter { $0.id == target } } ?? sources
                try await SessionMediaExport.save(data: selected.map(\.data), writer: photosWriter)
                exportMessage = "\(selected.count) \(selected.count == 1 ? "photo" : "photos") saved to Photos"
                announce(exportMessage)
            } catch {
                exportMessage = (error as? MediaExportError)?.localizedDescription ?? "Could not save; source media or storage unavailable."
                announce(exportMessage, isError: true)
            }
        }
    }

    func setHidden(_ ids: Set<String>, hidden: Bool) {
        guard managementAuthorized(), let store else { announce("Unlock operator controls first.", isError: true); return }
        var saved = 0, failed = 0
        for id in ids {
            do {
                try store.setHidden(archiveID: id, hidden: hidden)
                if let index = summaries.firstIndex(where: { $0.archiveID == id }) { summaries[index].isHidden = hidden }
                saved += 1
            } catch { failed += 1 }
        }
        rebuildFilters()
        announce(failed == 0 ? "\(saved) \(saved == 1 ? "session" : "sessions") \(hidden ? "hidden" : "restored")." : "\(saved) changed · \(failed) could not be saved. Check local storage and retry.", isError: failed > 0)
    }

    func deletionDecision(_ summary: RecentSessionArchiveSummary) -> RecordCleanupDecision {
        do { return try mediaDeletionInspector(summary) }
        catch { return .init(category: .cannotInspect, reason: "Recovery dependencies could not be read. Hide this session and review storage.") }
    }
    func deletionSize(_ id: String) async -> Int {
        guard let store else { return 0 }
        return await Task.detached(priority: .utility) { store.storageBytes(archiveID: id) }.value
    }
    func deleteSelected(_ candidates: [RecentSessionArchiveSummary]) async -> [String: String] {
        guard managementAuthorized(), let store else { return ["error": "Unlock operator controls and check local storage."] }
        var results: [String: String] = [:]
        let originalScope = scope, originalRun = currentEventRunID
        for summary in candidates {
            guard managementAuthorized(), scope == originalScope, currentEventRunID == originalRun else {
                results[summary.archiveID] = "Operator access or session scope changed. Review this session again."; continue
            }
            let decision = deletionDecision(summary)
            guard decision.category == .eligible else { results[summary.archiveID] = decision.reason; continue }
            SessionMediaOperations.deleting.insert(summary.sessionIdentifier)
            let result = await Task.detached(priority: .utility) { Result { try store.delete(archiveID: summary.archiveID) } }.value
            SessionMediaOperations.deleting.remove(summary.sessionIdentifier)
            switch result {
            case .success:
                results[summary.archiveID] = "Deleted local media."
                summaries.removeAll { $0.archiveID == summary.archiveID }
                galleryStatuses[summary.archiveID] = nil
                if selectedArchiveID == summary.archiveID { selectedArchiveID = nil }
                rebuildFilters()
                await thumbnails.remove(archiveID: summary.archiveID)
            case .failure:
                results[summary.archiveID] = "Deletion could not finish. Its saved intent prevents stale media writes; retry cleanup after checking storage."
            }
        }
        rebuildFilters()
        return results
    }
    func delete(_ archiveID: String) {
        guard let summary = summaries.first(where: { $0.archiveID == archiveID }) else { return }
        Task { let result = await deleteSelected([summary]); statusMessage = result[archiveID] ?? "Nothing deleted." }
    }
    func clearAll() { statusMessage = "Select sessions and review Delete Selected before removing local media." }

    func markReprinted(_ archiveID: String, copies: Int) {
        guard let store else {
            statusMessage = "Recent Sessions storage is unavailable."
            return
        }

        do {
            try store.markReprinted(archiveID: archiveID, copies: copies)
            // Refresh just the changed metadata. Preview/cache/filter identities stay stable.
            if let changed = try store.summary(archiveID: archiveID), let index = summaries.firstIndex(where: { $0.archiveID == archiveID }) {
                summaries[index] = changed
                rebuildFilters()
            }
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    static let rowTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    static let detailDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private static let sectionDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

}

@MainActor
final class ArchivedReceiptReprintController: ObservableObject {
    @Published private(set) var quantity = 1
    @Published private(set) var printerState = PrinterConnectionState.disconnected
    @Published private(set) var currentCopy = 0
    @Published private(set) var completedCopies = 0
    @Published private(set) var isReprinting = false
    @Published var statusMessage = "Ready to reprint."

    private let printerCoordinator: PrinterCoordinator
    private let archiveStore: () throws -> RecentSessionArchiveStore
    init(printerCoordinator: PrinterCoordinator? = nil,
         archiveStore: @escaping () throws -> RecentSessionArchiveStore = { try RecentSessionArchiveStore() }) {
        self.printerCoordinator = printerCoordinator ?? .shared
        self.archiveStore = archiveStore
    }
    private var reprintTask: Task<Void, Never>?

    var canReprint: Bool {
        !isReprinting && printerCoordinator.canPerformOperatorPrint
    }

    var buttonTitle: String {
        quantity == 1 ? "Reprint 1 Copy" : "Reprint \(quantity) Copies"
    }

    var reprintUnavailableMessage: String? {
        guard !isReprinting else { return nil }
        if !OperatorAccessPermit.shared.isAuthorized { return "Unlock Operator before printing." }
        return printerCoordinator.operatorPrintBlockReason
    }

    func decreaseQuantity() {
        setQuantity(quantity - 1)
    }

    func increaseQuantity() {
        setQuantity(quantity + 1)
    }

    private func setQuantity(_ newValue: Int) {
        quantity = min(10, max(1, newValue))
    }

    func reprint(
        archive: RecentSessionArchive,
        wifiHost: String,
        wifiPort: UInt16?,
        completion: @escaping (Int) -> Void
    ) {
        EventOperationalState.shared.refresh()
        guard canReprint else {
            statusMessage = "Printer is busy or needs recovery."
            return
        }

        guard let wifiPort else {
            printerState = .failure("Enter a valid TCP port from 1 to 65535.")
            statusMessage = printerState.message
            return
        }

        guard !SessionMediaOperations.deleting.contains(archive.summary.sessionIdentifier),
              (try? archiveStore().summary(archiveID: archive.summary.archiveID)) != nil else {
            statusMessage = "This local receipt was deleted or is being cleaned up. Nothing was sent."; return
        }
        let copies = quantity
        let rasterizedImage = archive.rasterizedImage
        let archiveID = archive.summary.archiveID
        let sessionID = archive.summary.sessionIdentifier
        let fingerprint = archive.summary.rasterFingerprint
        let currentRasterFingerprint = RecentSessionArchiveStore.rasterFingerprint(for: rasterizedImage)
        guard currentRasterFingerprint == fingerprint else {
            printerState = .failure("Archived receipt integrity check failed. Nothing was sent.")
            statusMessage = printerState.message
            debugLog("[RecentSessions] reprint blocked archive=\(GalleryTokenGenerator.redacted(archiveID)) archivedFingerprint=\(fingerprint) currentFingerprint=\(currentRasterFingerprint)")
            return
        }

        let batchID = UUID()
        completedCopies = 0
        currentCopy = 0
        SessionMediaOperations.reprinting.insert(sessionID)
        isReprinting = true
        statusMessage = copies == 1 ? "Reprinting receipt..." : "Reprinting copy 1 of \(copies)..."
        debugLog("[RecentSessions] reprint start session=\(sessionID) archive=\(GalleryTokenGenerator.redacted(archiveID)) copies=\(copies) archivedFingerprint=\(fingerprint) reprintFingerprint=\(RecentSessionArchiveStore.rasterFingerprint(for: rasterizedImage))")

        reprintTask = Task { [weak self] in
            defer { SessionMediaOperations.reprinting.remove(sessionID) }
            guard let self else { return }
            defer {
                self.isReprinting = false
                self.reprintTask = nil
            }

            for copy in 1...copies {
                guard !Task.isCancelled else { return }
                self.currentCopy = copy
                self.statusMessage = copies == 1 ? "Reprinting receipt..." : "Reprinting copy \(copy) of \(copies)..."
                let result = await self.reprintSingleCopy(
                    rasterizedImage: rasterizedImage,
                    wifiHost: wifiHost,
                    wifiPort: wifiPort,
                    copy: copy,
                    copies: copies,
                    fingerprint: fingerprint,
                    batchID: batchID,
                    sessionID: sessionID
                )

                switch result {
                case .success:
                    self.completedCopies = copy
                    completion(1)
                case .failure:
                    self.statusMessage = self.printerState.requiresPrinterRestart
                        ? "\(self.completedCopies) of \(copies) copies sent. The last receipt may have printed; check the paper in Help & Recovery."
                        : "\(self.completedCopies) of \(copies) copies sent. The next copy failed before it was sent. Check the printer connection."
                    debugLog("[RecentSessions] reprint stopped session=\(sessionID) completed=\(self.completedCopies) requested=\(copies)")
                    return
                }
            }

            self.statusMessage = "Reprint complete."
            debugLog("[RecentSessions] reprint complete session=\(sessionID) copies=\(copies) fingerprint=\(fingerprint)")
        }
    }

    private func reprintSingleCopy(
        rasterizedImage: ThermalRasterizedImage,
        wifiHost: String,
        wifiPort: UInt16,
        copy: Int,
        copies: Int,
        fingerprint: String,
        batchID: UUID,
        sessionID: String
    ) async -> Result<Void, Error> {
        do {
            try ThermalImageRasterizer.validateRasterCommand(
                rasterizedImage.rasterCommand,
                imageWidth: rasterizedImage.width,
                imageHeight: rasterizedImage.height,
                bytesPerRow: rasterizedImage.widthBytes,
                rasterDataCount: rasterizedImage.rasterData.count
            )
            try RasterCommandSanitizer.validateOutboundJob(
                heading: ThermalImageRasterizer.receiptPrintHeading(),
                rasterCommand: rasterizedImage.rasterCommand,
                finishing: ThermalImageRasterizer.photoTestFinishing(),
                rasterDataRange: 8..<rasterizedImage.rasterCommand.count
            )
        } catch {
            printerState = .failure(error.localizedDescription)
            statusMessage = error.localizedDescription
            return .failure(error)
        }

        return await withCheckedContinuation { continuation in
            debugLog("[RecentSessions] copy=\(copy)/\(copies) transport start fingerprint=\(fingerprint)")
            printerCoordinator.printReceipt(
                rasterizedImage: rasterizedImage,
                wifiHost: wifiHost,
                wifiPort: wifiPort,
                sessionIdentifier: sessionID,
                source: .archivedReprint,
                copyIndex: copy,
                copyCount: copies,
                batchID: batchID,
                transportPolicy: printerCoordinator.productionReceiptTransportPolicy
            ) { [weak self] state in
                guard let self else { return }
                self.printerState = state
                switch state {
                case .recoveryRequired(let message), .failure(let message):
                    self.statusMessage = message
                case .success:
                    break
                default:
                    self.statusMessage = copies == 1 ? "Reprinting receipt..." : "Reprinting copy \(copy) of \(copies)..."
                }
            } completion: { result in
                debugLog("[RecentSessions] copy=\(copy)/\(copies) transport complete fingerprint=\(fingerprint)")
                continuation.resume(returning: result)
            }
        }
    }
}

struct RecentSessionsView: View {
    @FocusState private var searchFocused: Bool
    var initialSearch = ""
    @StateObject private var viewModel: RecentSessionsViewModel
    @Environment(\.dynamicTypeSize) private var typeSize
    @ObservedObject private var runs = EventRunStore.shared
    @ObservedObject private var eventLibrary = EventDesignLibraryStore.shared
    @State private var filtersPresented = false
    @State private var galleryActionsPresented = false
    @State private var selecting = false
    @State private var selectedIDs = Set<String>()
    @State private var cleanupRequest: SessionCleanupRequest?
    @State private var scrollPosition: ScrollPosition
    init(initialSearch: String = "", viewModel: RecentSessionsViewModel? = nil, initialSelection: Set<String>? = nil) {
        self.initialSearch = initialSearch
        _selecting = State(initialValue: initialSelection != nil)
        _selectedIDs = State(initialValue: initialSelection ?? [])
        let model = viewModel ?? RecentSessionsViewModel()
        _viewModel = StateObject(wrappedValue: model)
        _scrollPosition = State(initialValue: ScrollPosition(idType: String.self, y: model.browserOffset))
    }

    var body: some View {
        GeometryReader { geometry in
            let wide = OperatorWorkspaceLayout.usesSidebar(width: geometry.size.width, height: geometry.size.height)
            let hasSelection = viewModel.selectedSummary != nil
            HStack(spacing: 0) {
                browser(wide: wide, width: wide && hasSelection ? min(400, geometry.size.width * 0.4) : geometry.size.width)
                    .frame(width: wide && hasSelection ? min(400, geometry.size.width * 0.4) : geometry.size.width)
                    .frame(width: !wide && hasSelection ? 0 : (wide && hasSelection ? min(400, geometry.size.width * 0.4) : geometry.size.width), alignment: .leading)
                    .clipped().opacity(!wide && hasSelection ? 0 : 1)
                    .allowsHitTesting(wide || !hasSelection).accessibilityHidden(!wide && hasSelection)
                if let selected = viewModel.selectedSummary {
                    if wide { Divider() }
                    VStack(spacing: 0) {
                        HStack {
                            Button { viewModel.selectedArchiveID = nil } label: {
                                Label(wide ? "Close Detail" : "Sessions", systemImage: "chevron.left").frame(minHeight: 44)
                            }.accessibilityIdentifier("sessions-back")
                            Spacer()
                            Text(selected.format.displayName).font(.subheadline).foregroundStyle(OperatorPalette.secondaryText)
                        }.padding(.horizontal, 16).background(OperatorPalette.surface)
                        ArchivedSessionDetailView(summary: selected, rootViewModel: viewModel)
                            .id(selected.archiveID)
                    }.frame(maxWidth: .infinity)
                }
            }
        }
        .background(OperatorPalette.canvas)
        .navigationTitle("Sessions").navigationBarTitleDisplayMode(.inline)
        .task {
            if !viewModel.hasLoaded {
                viewModel.searchText = initialSearch
            }
            // Re-entering a retained workspace picks up newly archived guests without
            // resetting filters/selection, clearing the cache or showing a loading screen.
            updateScopeContext()
            viewModel.refresh()
        }
        .onChange(of: runs.current) { _, _ in updateScopeContext() }
        .onChange(of: eventLibrary.library.appliedEventID) { _, _ in updateScopeContext() }
        .onChange(of: viewModel.scope) { _, _ in selectedIDs.removeAll(); selecting = false; cleanupRequest = nil }
        .sheet(isPresented: $filtersPresented) { filterSheet }
        .sheet(item: $cleanupRequest, onDismiss: { selectedIDs.formIntersection(Set(viewModel.summaries.map(\.archiveID))) }) { request in SessionCleanupReview(candidates: request.candidates, model: viewModel) }
    }

    private func updateScopeContext() {
        viewModel.configureContext(run: runs.current, eventApplied: !RegularBoothMode.isEnabled && (eventLibrary.library.appliedEventID != nil || runs.current != nil))
    }

    private func browser(wide: Bool, width: CGFloat) -> some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Picker("Session Scope", selection: $viewModel.scope) {
                    ForEach(RecentSessionScope.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented)
                if viewModel.scope == .currentEvent {
                    Text(viewModel.currentEventName ?? "No active event. Choose Regular Booth or All History.")
                        .font(.subheadline.weight(.medium)).frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").accessibilityHidden(true)
                    TextField("Search session, event or format", text: $viewModel.searchText)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("sessions-search").focused($searchFocused).submitLabel(.search)
                        .onSubmit { searchFocused = false }
                    if !viewModel.searchText.isEmpty {
                        Button { viewModel.searchText = "" } label: { Image(systemName: "xmark.circle.fill").frame(width: 44, height: 44) }
                            .accessibilityLabel("Clear search")
                    }
                    Button(selecting ? "Done" : "Select") { selecting.toggle(); selectedIDs.removeAll() }
                        .buttonStyle(.bordered).frame(minHeight: 44).accessibilityIdentifier("sessions-select")
                }.padding(.horizontal, 12).frame(minHeight: 54)
                    .background(OperatorPalette.surface, in: RoundedRectangle(cornerRadius: 14))
                // Keep one action-button instance when export feedback changes layout. Native
                // buttons avoid the nested Menu accessibility proxy seen in CI's iOS 26.2 tree.
                if width >= 620 && !typeSize.isAccessibilitySize {
                    HStack(spacing: 8) { filterControls; Spacer(minLength: 0); displayControl; galleryActions }
                } else {
                    VStack(alignment: .leading, spacing: 8) { filterControls; HStack { displayControl; Spacer(); galleryActions } }
                }
            }.padding(16).fixedSize(horizontal: false, vertical: true)
            if selecting {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { selectionCount; Spacer(); selectionControls }
                    VStack(alignment: .leading, spacing: 4) { selectionCount; HStack { selectionControls } }
                }.frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.bottom, 8)
                    .fixedSize(horizontal: false, vertical: true).background(OperatorPalette.canvas)
            }
            if let failure = viewModel.retentionFailure {
                OperatorFeedbackBanner(feedback: failure) { viewModel.retentionFailure = nil }.padding(.horizontal, 16).padding(.bottom, 8)
            }
            if viewModel.isExporting { ProgressView(viewModel.exportMessage).padding(8).accessibilityAddTraits(.updatesFrequently) }
            if viewModel.isVerifying {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(viewModel.verificationResult.isEmpty ? "Checking original galleries…" : viewModel.verificationResult).font(.caption)
                    Spacer()
                    Button("Cancel Recheck") { viewModel.cancelVerification() }.frame(minHeight: 44)
                }.padding(.horizontal, 16)
            }
            if let feedback = viewModel.actionFeedback {
                OperatorFeedbackBanner(feedback: feedback) { viewModel.dismissFeedback() }.padding(.horizontal, 16).padding(.bottom, 8)
            }
            if let error = viewModel.loadError, !viewModel.summaries.isEmpty {
                Label(error, systemImage: "exclamationmark.triangle").font(.callout).padding(.horizontal, 16)
            }
            ScrollViewReader { _ in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if !viewModel.hasLoaded {
                            ProgressView("Loading sessions…").frame(maxWidth: .infinity, minHeight: 220)
                        } else if let error = viewModel.loadError, viewModel.summaries.isEmpty {
                            ContentUnavailableView("Sessions unavailable", systemImage: "exclamationmark.triangle", description: Text(error))
                            Button("Retry Loading") { viewModel.refresh() }.buttonStyle(.bordered).frame(minHeight: 44).padding()
                        } else if viewModel.filteredSummaries.isEmpty {
                            ContentUnavailableView(viewModel.summaries.isEmpty ? "No sessions yet" : "No matching sessions", systemImage: "photo.stack",
                                description: Text(viewModel.summaries.isEmpty ? "Finished receipts appear here with their original gallery and print history." : "Change the search or filters to find an earlier guest."))
                            if !viewModel.summaries.isEmpty { Button("Clear Filters") { viewModel.clearFilters() }.frame(minHeight: 44).padding() }
                        } else {
                            ForEach(viewModel.groupedSummaries, id: \.0) { title, summaries in
                                HStack { Text(title).font(.headline); Spacer(); Text("\(summaries.count)").font(.caption).monospacedDigit() }
                                    .foregroundStyle(OperatorPalette.secondaryText).padding(.horizontal, 16).padding(.vertical, 12)
                                    .accessibilityAddTraits(.isHeader)
                                if viewModel.usesPhotoGrid {
                                    LazyVGrid(columns: [GridItem(.adaptive(minimum: typeSize.isAccessibilitySize ? 320 : 235), spacing: 12)], spacing: 12) {
                                        ForEach(summaries) { summary in sessionButton(summary, grid: true).id(summary.archiveID) }
                                    }.padding(.horizontal, 16)
                                } else {
                                    ForEach(summaries) { summary in
                                        sessionButton(summary, grid: false).id(summary.archiveID)

                                    }.padding(.horizontal, 16)
                                }
                            }
                        }
                    }.padding(.bottom, 16)
                }
                .scrollPosition($scrollPosition)
                .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.y }) { _, offset in
                    viewModel.recordBrowserOffset(offset)
                }
                .scrollDismissesKeyboard(.interactively)
                .refreshable { viewModel.refresh() }
                .onChange(of: viewModel.selectedArchiveID) { _, current in
                    // In landscape the list stays visible and may have been scrolled
                    // independently. Portrait returns to the offset captured on selection.
                    if current == nil && !wide { scrollPosition.scrollTo(y: viewModel.detailReturnOffset) }
                }
                .onChange(of: viewModel.usesPhotoGrid) { _, _ in
                    scrollPosition.scrollTo(y: viewModel.browserOffset)
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if selecting && !selectedIDs.isEmpty {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 16) { selectionCount; Spacer(); selectedActions }
                    VStack(alignment: .leading, spacing: 8) { selectionCount; HStack { selectedActions } }
                }.frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16).fixedSize(horizontal: false, vertical: true).background(.regularMaterial)
                    .accessibilityIdentifier("sessions-bulk-actions")
            }
        }
        .onChange(of: viewModel.filteredSummaries.map(\.archiveID)) { _, visible in
            selectedIDs.formIntersection(Set(visible))
        }
    }

    private var selectionCount: some View {
        Text("\(selectedIDs.count) selected").font(.subheadline.weight(.semibold)).monospacedDigit()
            .accessibilityIdentifier("sessions-selection-count")
    }
    @ViewBuilder private var selectionControls: some View {
        Button("Select All Visible") { selectedIDs = Set(viewModel.filteredSummaries.map(\.archiveID)) }
            .frame(minHeight: 44).buttonStyle(.bordered).fixedSize(horizontal: true, vertical: true)
        if !selectedIDs.isEmpty {
            Button("Deselect") { selectedIDs.removeAll() }.frame(minHeight: 44).buttonStyle(.bordered).fixedSize(horizontal: true, vertical: true)
        }
    }
    private var galleryActions: some View {
        Button { galleryActionsPresented = true } label: {
            Label("More", systemImage: "ellipsis").frame(minWidth: 44, minHeight: 44)
        }
        .buttonStyle(.bordered).accessibilityLabel("Gallery Actions and More").accessibilityIdentifier("sessions-gallery-actions")
        .confirmationDialog("Gallery Actions", isPresented: $galleryActionsPresented, titleVisibility: .visible) {
            Button("Recheck Unverified Galleries") {
                viewModel.verifyGalleries(selectedIDs.isEmpty ? viewModel.filteredSummaries : viewModel.filteredSummaries.filter { selectedIDs.contains($0.archiveID) })
            }.disabled(viewModel.isVerifying)
            if viewModel.isVerifying { Button("Cancel Recheck") { viewModel.cancelVerification() } }
            Button(viewModel.showsHidden ? "Hide Hidden Sessions" : "Show Hidden") { viewModel.showsHidden.toggle() }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var filterControls: some View {
        HStack(spacing: 8) {
            Button { viewModel.todayOnly.toggle() } label: { Text(viewModel.todayOnly ? "Today ✓" : "All dates").frame(minHeight: 44) }
                .buttonStyle(.bordered).accessibilityLabel("Today only").accessibilityAddTraits(viewModel.todayOnly ? .isSelected : [])
            Button { filtersPresented = true } label: { Label("Filters", systemImage: "line.3.horizontal.decrease").frame(minHeight: 44) }
                .buttonStyle(.bordered).accessibilityIdentifier("sessions-filters")
        }
    }
    private var displayControl: some View {
        Button { viewModel.usesPhotoGrid.toggle() } label: {
            Label(viewModel.usesPhotoGrid ? "List" : "Photos", systemImage: viewModel.usesPhotoGrid ? "list.bullet" : "square.grid.2x2").frame(minHeight: 44)
        }.buttonStyle(.bordered).accessibilityIdentifier("sessions-display")
    }
    @ViewBuilder private var selectedActions: some View {
        Button("Hide Selected") { viewModel.setHidden(selectedIDs, hidden: true); selectedIDs.removeAll() }.frame(minHeight: 44).buttonStyle(.bordered)
        Button("Delete Selected", role: .destructive) {
            cleanupRequest = SessionCleanupRequest(candidates: viewModel.filteredSummaries.filter { selectedIDs.contains($0.archiveID) })
        }.frame(minHeight: 44).buttonStyle(.borderedProminent).tint(OperatorPalette.danger)
    }
    private func sessionButton(_ summary: RecentSessionArchiveSummary, grid: Bool) -> some View {
        let selected = selectedIDs.contains(summary.archiveID)
        return ZStack(alignment: .topTrailing) {
            Button {
                if selecting {
                    if !selectedIDs.insert(summary.archiveID).inserted { selectedIDs.remove(summary.archiveID) }
                } else { viewModel.selectedArchiveID = summary.archiveID }
            } label: {
                RecentSessionRow(summary: summary, viewModel: viewModel, photoGrid: grid).equatable()
            }.buttonStyle(.plain).accessibilityIdentifier("session-\(summary.archiveID)")
                .accessibilityValue(selecting ? (selected ? "Selected" : "Not selected") : "")
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityHint(selecting ? "Double-tap to toggle selection" : "Opens session detail")
            if selecting {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title2).foregroundStyle(selected ? OperatorPalette.accent : OperatorPalette.ink)
                    .frame(width: 44, height: 44).background(.regularMaterial, in: Circle())
                    .padding(8).allowsHitTesting(false).accessibilityHidden(true)
            } else {
                Menu {
                    Button("View Session") { viewModel.selectedArchiveID = summary.archiveID }
                    Button("View Original Receipt") { viewModel.selectedArchiveID = summary.archiveID }
                    Button("Save Receipt to Photos") { viewModel.exportReceipt(summary.archiveID) }
                    Button("Save Available Photos") { viewModel.exportPhotos(summary.archiveID) }
                    Button(summary.isHidden ? "Restore Visibility" : "Hide Session") { viewModel.setHidden([summary.archiveID], hidden: !summary.isHidden) }
                    Button("Delete Session", role: .destructive) { cleanupRequest = SessionCleanupRequest(candidates: [summary]) }
                } label: {
                    Image(systemName: "ellipsis").font(.headline).frame(width: 44, height: 44)
                        .background(.regularMaterial, in: Circle())
                }.buttonStyle(.borderless).accessibilityLabel("Manage session").padding(8)
            }
        }
        .background(OperatorPalette.surface, in: RoundedRectangle(cornerRadius: 16))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay { if selected { RoundedRectangle(cornerRadius: 16).strokeBorder(OperatorPalette.accent, lineWidth: 3) } }
        .padding(.bottom, grid ? 0 : 10)
    }
    private var filterSheet: some View {
        NavigationStack {
            Form {
                Section("Date") {
                    Toggle("Today", isOn: $viewModel.todayOnly)
                    Toggle("Date range", isOn: Binding(get: { viewModel.dateFrom != nil }, set: { enabled in
                        viewModel.dateFrom = enabled ? Calendar.current.startOfDay(for: Date()) : nil
                        viewModel.dateThrough = enabled ? Date() : nil
                        viewModel.todayOnly = false
                    }))
                    if viewModel.dateFrom != nil {
                        DatePicker("From", selection: Binding(get: { viewModel.dateFrom ?? Date() }, set: { viewModel.dateFrom = $0 }), displayedComponents: .date)
                        DatePicker("Through", selection: Binding(get: { viewModel.dateThrough ?? Date() }, set: { viewModel.dateThrough = $0 }), displayedComponents: .date)
                    }
                }
                Section("Session") {
                    Picker("Event", selection: $viewModel.eventFilter) {
                        Text("All events & Regular Booth").tag(Optional<String>.none)
                        ForEach(viewModel.events, id: \.self) { Text($0).tag(Optional($0)) }
                    }
                    Picker("Format", selection: $viewModel.formatFilter) {
                        Text("All formats").tag(Optional<BoothFormat>.none)
                        ForEach(BoothFormat.allCases) { Text($0.displayName).tag(Optional($0)) }
                    }
                    Toggle("Needs attention", isOn: $viewModel.showsOnlyAttention)
                    Text("Unknown print history stays visible here. It does not by itself block the next guest.").font(.footnote)
                }
                Section { Button("Clear Filters") { viewModel.clearFilters() } }
            }.navigationTitle("Filter Sessions").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { filtersPresented = false } } }
        }
    }
}

/// Value-only statuses and a local image task keep global operational invalidations out of rows.
struct RecentSessionRow: View, Equatable {
    let summary: RecentSessionArchiveSummary
    let viewModel: RecentSessionsViewModel
    var showsOperationalContext = true
    var photoGrid = false
    let gallery: ArchivedGalleryStatus
    let print: ArchivedPrintSummary
    init(summary: RecentSessionArchiveSummary, viewModel: RecentSessionsViewModel, showsOperationalContext: Bool = true, photoGrid: Bool = false) {
        self.summary = summary; self.viewModel = viewModel; self.showsOperationalContext = showsOperationalContext; self.photoGrid = photoGrid
        self.gallery = viewModel.galleryStatus(for: summary); self.print = viewModel.printSummary(for: summary)
    }
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.summary == rhs.summary && lhs.gallery == rhs.gallery && lhs.print == rhs.print
            && lhs.photoGrid == rhs.photoGrid && lhs.showsOperationalContext == rhs.showsOperationalContext && lhs.viewModel === rhs.viewModel
    }
    private var isCorrupt: Bool { summary.rasterFingerprint == "CORRUPT" }
    var body: some View {
        let layout = photoGrid ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0)) : AnyLayout(HStackLayout(spacing: 14))
        layout {
            if photoGrid {
                GeometryReader { geometry in
                    SessionThumbnailView(summary: summary, model: viewModel)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                }.aspectRatio(1, contentMode: .fit).clipped()
            } else {
                SessionThumbnailView(summary: summary, model: viewModel)
                    .frame(width: 84, height: 108).clipShape(RoundedRectangle(cornerRadius: 10))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(isCorrupt ? "Unreadable archive" : RecentSessionsViewModel.rowTimeFormatter.string(from: summary.createdAt))
                    .font(.headline).foregroundStyle(OperatorPalette.ink)
                Text(summary.eventName ?? "Regular Booth").font(.subheadline.weight(.medium)).foregroundStyle(OperatorPalette.ink).lineLimit(2, reservesSpace: photoGrid)
                Text(summary.format.displayName).font(.caption).foregroundStyle(OperatorPalette.secondaryText)
                if showsOperationalContext {
                    Text(isCorrupt ? "Archive needs attention" : print.title + " · " + gallery.shortTitle)
                        .font(.caption).foregroundStyle(isCorrupt || print.isAttention || gallery.isAttention ? OperatorPalette.warning : OperatorPalette.secondaryText)
                        .lineLimit(2, reservesSpace: photoGrid).fixedSize(horizontal: false, vertical: true)
                }
                if summary.reprintCount > 0 { Text("Operator reprints: \(summary.reprintCount)").font(.caption).foregroundStyle(OperatorPalette.secondaryText) }
            }.frame(maxWidth: .infinity, alignment: .leading)
                .padding(photoGrid ? 12 : 0).padding(.trailing, photoGrid ? 0 : 44)
        }
        .padding(photoGrid ? 0 : 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(OperatorPalette.surface)
        .contentShape(Rectangle()).accessibilityElement(children: .combine)

    }
}

struct ArchivedSessionDetailView: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    @ObservedObject private var operations = EventOperationalState.shared
    @ObservedObject private var printer = PrinterCoordinator.shared
    let summary: RecentSessionArchiveSummary
    @ObservedObject var rootViewModel: RecentSessionsViewModel

    @Environment(\.dismiss) private var dismiss
    @AppStorage("printerIP") private var printerIP = BoothConfiguration.defaultPrinterIP
    @AppStorage("printerPort") private var printerPort = BoothConfiguration.defaultPrinterPort
    @StateObject private var reprintController = ArchivedReceiptReprintController()
    @State private var archive: RecentSessionArchive?
    @State private var receiptImage: UIImage?
    @State private var thumbnails: [UIImage] = []
    @State private var photoSources: [SessionPhotoSource] = []
    @State private var selectedPhoto: SessionPhotoSource?
    @State private var photoLoadMessage = ""
    @State private var isReviewingDeletion = false
    @State private var galleryLink: ArchivedGalleryLink?
    @State private var galleryQR: UIImage?
    @State private var loadError: String?
    @State private var isLoadingArchive = false
    @State private var isConfirmingReprint = false
    @State private var isShowingFullReceiptPreview = false
    @State private var copiedNotice: String?

    var body: some View {
        GeometryReader { proxy in
            let wide = proxy.size.width >= 900
            ScrollView {
                Group {
                    if let archive {
                        if wide {
                            HStack(alignment: .top, spacing: 20) {
                                receiptCard(height: max(520, proxy.size.height - 60))
                                    .frame(width: min(440, proxy.size.width * 0.42))
                                VStack(spacing: 18) { infoCards(archive) }
                            }
                        } else {
                            VStack(spacing: 18) {
                                summaryCard(archive)
                                receiptCard(height: min(760, max(520, proxy.size.height * 0.62)))
                                photosCard
                                galleryCard(archive)
                                reprintCard(archive)
                                technicalCard(archive)
                                managementCard
                            }
                        }
                    } else if let loadError {
                        ContentUnavailableView(
                            "This archived session cannot be loaded.",
                            systemImage: "exclamationmark.triangle",
                            description: Text(loadError)
                        )
                        .frame(maxWidth: .infinity, minHeight: 320)
                    } else {
                        ProgressView("Loading archived receipt…")
                            .frame(maxWidth: .infinity, minHeight: 320)
                    }
                }
                .padding(24)
                .frame(maxWidth: 1180)
                .frame(maxWidth: .infinity)
            }
        }
        .safeAreaInset(edge: .top) {
            VStack(spacing: 8) {
                if let failure = rootViewModel.retentionFailure {
                    OperatorFeedbackBanner(feedback: failure) { rootViewModel.retentionFailure = nil }.padding(.horizontal, 16)
                }
                if rootViewModel.isExporting { ProgressView(rootViewModel.exportMessage).padding(8) }
                if let feedback = rootViewModel.actionFeedback {
                    OperatorFeedbackBanner(feedback: feedback) { rootViewModel.dismissFeedback() }.padding(.horizontal, 16)
                }
            }
        }
        .background(OperatorPalette.canvas.ignoresSafeArea())
        .navigationTitle(summary.eventName ?? "Archived Session")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Create a new OPERATOR REPRINT of this archived receipt?",
            isPresented: $isConfirmingReprint,
            titleVisibility: .visible
        ) {
            if let archive {
                Button(reprintController.buttonTitle) {
                    reprintController.reprint(
                        archive: archive,
                        wifiHost: printerIP,
                        wifiPort: parsedPort
                    ) { completedCopies in
                        rootViewModel.markReprinted(summary.archiveID, copies: completedCopies)
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Inspect any previous paper output first. This is a new batch, never automatic recovery.\n\(operations.printContext(sessionID: summary.sessionIdentifier))\n\(summary.sessionIdentifier)\n\(reprintController.quantity) \(reprintController.quantity == 1 ? "copy" : "copies")")
        }
        .onAppear {
            operations.refresh()
            loadArchive()
        }
        .sheet(isPresented: $isReviewingDeletion) { SessionCleanupReview(candidates: [summary], model: rootViewModel) }
        .sheet(item: $selectedPhoto) { photo in
            NavigationStack {
                VStack {
                    SessionPhotoPreview(source: photo)
                    Text(photo.quality.rawValue).font(.callout)
                    if rootViewModel.isExporting { ProgressView(rootViewModel.exportMessage) }
                    Button("Save Photo to Photos") { rootViewModel.exportPhotos(summary.archiveID, index: photo.id) }.frame(minHeight: 44).disabled(rootViewModel.isExporting)

                }.padding().navigationTitle("Photo \(photo.id + 1)")
                    .safeAreaInset(edge: .top) {
                        if let feedback = rootViewModel.actionFeedback {
                            OperatorFeedbackBanner(feedback: feedback) { rootViewModel.dismissFeedback() }.padding(.horizontal, 16)
                        }
                    }
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { selectedPhoto = nil } } }
            }
        }
        .sheet(isPresented: $isShowingFullReceiptPreview) {
            FullReceiptPreviewSheet(image: receiptImage)
        }
    }

    @ViewBuilder
    private func infoCards(_ archive: RecentSessionArchive) -> some View {
        summaryCard(archive)
        galleryCard(archive)
        photosCard
        reprintCard(archive)
        technicalCard(archive)
        managementCard
    }

    private var parsedPort: UInt16? {
        UInt16(printerPort.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Archive bytes are read and decoded off the main thread; the QR is drawn from the frozen URL.
    private func loadArchive() {
        guard !isLoadingArchive, archive == nil else { return }
        isLoadingArchive = true

        Task {
            let result = await rootViewModel.loadArchiveResult(summary.archiveID)
            switch result {
            case .success(let loadedArchive):
                let link = ArchivedGalleryLink(galleryURL: loadedArchive.galleryURL, galleryToken: loadedArchive.galleryToken)
                let decoded = await Task.detached(priority: .userInitiated) { () -> (UIImage?, [UIImage], UIImage?) in
                    (UIImage(data: loadedArchive.receiptPreviewPNGData),
                     loadedArchive.thumbnailData.compactMap { UIImage(data: $0)?.preparingThumbnail(of: CGSize(width: 240, height: 320)) },
                     link.makeQRImage())
                }.value
                archive = loadedArchive
                galleryLink = link
                receiptImage = decoded.0
                thumbnails = decoded.1
                galleryQR = decoded.2
                loadError = nil
                do { photoSources = try await rootViewModel.availablePhotos(summary.archiveID) }
                catch { photoLoadMessage = "Available photo sources could not be read. Check local storage; original media was not changed." }
            case .failure(let error):
                archive = nil
                loadError = error.localizedDescription
            }
            isLoadingArchive = false
        }
    }

    // MARK: Cards

    private func card<Content: View>(_ title: String, systemImage: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .textCase(.uppercase)
                .tracking(1.4)
                .foregroundStyle(OperatorPalette.accent)
                .accessibilityAddTraits(.isHeader)
            content()
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(OperatorPalette.surface))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(OperatorPalette.border))
    }

    private func summaryCard(_ archive: RecentSessionArchive) -> some View {
        card("Session", systemImage: "calendar") {
            VStack(alignment: .leading, spacing: 6) {
                Text(archive.summary.eventName ?? MadeToKeepBrand.fullName)
                    .font(MadeToKeepTheme.Typography.italicSerif(size: 30))
                    .foregroundStyle(OperatorPalette.accent)
                Text(RecentSessionsViewModel.detailDateFormatter.string(from: archive.summary.createdAt))
                    .font(.headline)
                    .foregroundStyle(OperatorPalette.ink)
                Text("\(archive.summary.format.displayName) · \(archive.summary.photoCount) \(archive.summary.photoCount == 1 ? "photo" : "photos") · \(Int(archive.summary.estimatedLengthMillimeters.rounded())) mm receipt")
                    .foregroundStyle(OperatorPalette.secondaryText)
                if let passport = archive.passport {
                    Text("\(passport.usesPhotoPassDesign ? "Photo Pass" : "Legacy Passport · \(passport.configuration.theme.displayName)") · \(passport.name.isEmpty ? "No name" : passport.name) · \(passport.signature.isEmpty ? "No signature" : "Signed")")
                        .font(.callout)
                        .foregroundStyle(OperatorPalette.secondaryText)
                }
                let print = rootViewModel.printSummary(for: archive.summary)
                Label(print.title, systemImage: print.systemImage)
                    .foregroundStyle(print.isAttention ? OperatorPalette.warning : OperatorPalette.ink)
                    .padding(.top, 4)
                if archive.summary.reprintCount > 0 {
                    Label("Operator reprints: \(archive.summary.reprintCount)\(archive.summary.lastReprintedAt.map { " · last \($0.formatted(date: .omitted, time: .shortened))" } ?? "")", systemImage: "arrow.triangle.2.circlepath")
                        .foregroundStyle(OperatorPalette.secondaryText)
                }
            }
        }
    }

    private func receiptCard(height: CGFloat) -> some View {
        card("Original Receipt", systemImage: "doc.text.image") {
            if let receiptImage {
                OperatorZoomableReceiptView(image: receiptImage, rendering: .smooth, accessibilityLabel: "Original receipt")
                    .frame(height: height)
                Button {
                    isShowingFullReceiptPreview = true
                } label: {
                    Label("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .tint(OperatorPalette.accent)
                Button { rootViewModel.exportReceipt(summary.archiveID) } label: {
                    Label("Save Receipt to Photos", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity, minHeight: 44)
                }.buttonStyle(.borderedProminent).tint(OperatorPalette.accent).disabled(rootViewModel.isExporting)

            } else {
                Text("This archive does not include a readable receipt preview.")
                    .foregroundStyle(OperatorPalette.secondaryText)
            }
        }
    }

    private func galleryStatus(_ archive: RecentSessionArchive) -> ArchivedGalleryStatus {
        rootViewModel.galleryStatus(for: archive.summary)
    }

    private func galleryCard(_ archive: RecentSessionArchive) -> some View {
        let status = galleryStatus(archive)
        return card("Customer Gallery", systemImage: "qrcode") {
            let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 16)) : AnyLayout(HStackLayout(alignment: .top, spacing: 20))
            layout {
                if let galleryQR, galleryLink?.url != nil {
                    Image(uiImage: galleryQR)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 190, height: 190)
                        .padding(10)
                        .background(Color.white)
                        .overlay(Rectangle().strokeBorder(MadeToKeepTheme.ColorPalette.hairline))
                        .accessibilityLabel("Original gallery QR code for this session")
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: galleryLink == nil ? "hourglass" : "qrcode")
                            .font(.system(size: 36))
                        Text(galleryLink == nil ? "Preparing QR…" : "No QR")
                            .font(.caption)
                    }
                    .foregroundStyle(OperatorPalette.secondaryText)
                    .frame(width: 210, height: 210)
                    .background(RoundedRectangle(cornerRadius: 8).fill(OperatorPalette.accent.opacity(0.05)))
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Scan to view your photos")
                        .font(MadeToKeepTheme.Typography.italicSerif(size: 24))
                        .foregroundStyle(OperatorPalette.accent)
                    Label(status.title, systemImage: status.systemImage)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(status == .verified ? OperatorPalette.ready : (status.isAttention ? OperatorPalette.warning : OperatorPalette.ink))
                    Text(status.detail)
                        .font(.callout)
                        .foregroundStyle(OperatorPalette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let url = galleryLink?.url {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { galleryActions(url) }
                    VStack(alignment: .leading, spacing: 10) { galleryActions(url) }
                }
                if let copiedNotice {
                    Text(copiedNotice)
                        .font(.footnote)
                        .foregroundStyle(OperatorPalette.secondaryText)
                        .accessibilityAddTraits(.updatesFrequently)
                }
            }
            Button(rootViewModel.isVerifying ? "Verifying…" : "Verify Gallery") { rootViewModel.verifyGalleries([summary], includeReady: true) }
                .buttonStyle(.bordered).frame(minHeight: 44).disabled(rootViewModel.isVerifying || galleryLink?.url == nil)
            if !rootViewModel.verificationResult.isEmpty { Text(rootViewModel.verificationResult).font(.footnote) }
            NavigationLink {
                PendingUploadsView()
            } label: {
                Label("Manage Gallery Upload", systemImage: "icloud.and.arrow.up")
                    .frame(minHeight: 44)
            }
            .tint(OperatorPalette.accent)
        }
    }

    @ViewBuilder
    private func galleryActions(_ url: URL) -> some View {
        Link(destination: url) {
            Label("Open Gallery", systemImage: "safari").frame(minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
        .tint(OperatorPalette.accent)
        Button {
            UIPasteboard.general.url = url
            copiedNotice = "Gallery link copied. Anyone with this link can view these photos."
        } label: {
            Label("Copy Gallery Link", systemImage: "doc.on.doc").frame(minHeight: 44)
        }
        .buttonStyle(.bordered)
        .tint(OperatorPalette.accent)
        ShareLink(item: url, message: Text("Your Made to Keep Studios photos")) {
            Label("Share Link", systemImage: "square.and.arrow.up").frame(minHeight: 44)
        }
        .buttonStyle(.bordered)
        .tint(OperatorPalette.accent)
    }

    private var photosCard: some View {
        card("Individual Photos", systemImage: "photo.on.rectangle") {
            if photoSources.isEmpty {
                Text(photoLoadMessage.isEmpty ? "No individual photos are available for export in this local archive." : photoLoadMessage)
                    .foregroundStyle(OperatorPalette.secondaryText)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(photoSources) { photo in
                            VStack(alignment: .leading, spacing: 4) {
                                Button { selectedPhoto = photo } label: {
                                    ExportPhotoThumbnail(data: photo.data).frame(width: 120, height: 152).clipped()
                                }.accessibilityLabel("View photo \(photo.id + 1), \(photo.quality.rawValue)")
                                Text(photo.quality.rawValue).font(.caption).frame(width: 120, alignment: .leading)
                                Button("Save Photo \(photo.id + 1)") { rootViewModel.exportPhotos(summary.archiveID, index: photo.id) }
                                    .frame(minHeight: 44).disabled(rootViewModel.isExporting)
                            }
                        }
                    }
                }
                Button("Save All Photos") { rootViewModel.exportPhotos(summary.archiveID) }.frame(minHeight: 44)
                    .buttonStyle(.bordered).disabled(rootViewModel.isExporting)
                Text(photoSources.contains(where: { $0.quality == .thumbnail })
                    ? "Only small thumbnails remain for these photos. Saved Photos copies remain after local archive deletion."
                    : "Save uses the retained individual photo data. Photos-library copies remain after local archive deletion.")
                    .font(.footnote).foregroundStyle(OperatorPalette.secondaryText)
            }
        }
    }
    private var managementCard: some View {
        let hidden = rootViewModel.summaries.first { $0.archiveID == summary.archiveID }?.isHidden ?? summary.isHidden
        return card("Session Management", systemImage: "tray") {
            Button(hidden ? "Restore Visibility" : "Hide Session") { rootViewModel.setHidden([summary.archiveID], hidden: !hidden) }.frame(minHeight: 44)
            Button("Delete Session", role: .destructive) { isReviewingDeletion = true }.frame(minHeight: 44)
        }
    }

    /// Operator-only and visually separate from previews: a new batch behind a confirmation.
    private func reprintCard(_ archive: RecentSessionArchive) -> some View {
        card("Operator Reprint", systemImage: "printer.dotmatrix") {
            OperatorPrinterControls(showInterruptedReceipt: false)
            Text("Prints a new copy of the exact archived receipt. Inspect any earlier paper first; this never resumes or recovers a previous print.")
                .font(.callout)
                .foregroundStyle(OperatorPalette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Text(operations.printContext(sessionID: summary.sessionIdentifier))
                .font(.footnote)
                .foregroundStyle(OperatorPalette.ink)

            HStack(spacing: 14) {
                HStack(spacing: 0) {
                    Button {
                        reprintController.decreaseQuantity()
                    } label: {
                        Image(systemName: "minus").frame(width: 48, height: 44)
                    }
                    .disabled(reprintController.quantity <= 1 || reprintController.isReprinting)
                    .accessibilityLabel("Fewer copies")

                    Text("\(reprintController.quantity)")
                        .font(.title3.monospacedDigit().weight(.bold))
                        .frame(width: 56, height: 44)
                        .accessibilityLabel("\(reprintController.quantity) \(reprintController.quantity == 1 ? "copy" : "copies")")

                    Button {
                        reprintController.increaseQuantity()
                    } label: {
                        Image(systemName: "plus").frame(width: 48, height: 44)
                    }
                    .disabled(reprintController.quantity >= 10 || reprintController.isReprinting)
                    .accessibilityLabel("More copies")
                }
                .buttonStyle(.bordered)

                Button(reprintController.buttonTitle) {
                    isConfirmingReprint = true
                }
                .buttonStyle(.borderedProminent)
                .tint(OperatorPalette.accent)
                .frame(minHeight: 44)
                .disabled(!reprintController.canReprint)
            }

            if reprintController.isReprinting {
                ProgressView(reprintController.statusMessage)
            } else if let message = reprintController.reprintUnavailableMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(OperatorPalette.danger)
            } else {
                Text(reprintController.statusMessage)
                    .font(.footnote)
                    .foregroundStyle(reprintController.printerState.requiresPrinterRestart ? OperatorPalette.danger : OperatorPalette.secondaryText)
            }
        }
    }

    private func technicalCard(_ archive: RecentSessionArchive) -> some View {
        card("Technical Details", systemImage: "wrench.and.screwdriver") {
            DisclosureGroup("Identifiers and integrity") {
                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent("Session ID") {
                        Text(archive.summary.sessionIdentifier).font(.callout.monospaced()).textSelection(.enabled)
                    }
                    Button {
                        UIPasteboard.general.string = archive.summary.sessionIdentifier
                        copiedNotice = "Session ID copied."
                    } label: {
                        Label("Copy Session ID", systemImage: "doc.on.doc").frame(minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    // The token is the gallery's only secret; never shown in full.
                    LabeledContent("Archive", value: GalleryTokenGenerator.redacted(archive.summary.archiveID))
                    LabeledContent("Raster fingerprint", value: archive.summary.rasterFingerprint)
                    LabeledContent("Receipt size", value: "\(archive.summary.receiptWidth) × \(archive.summary.receiptHeight) dots")
                    LabeledContent("Stored size", value: ByteCountFormatter.string(fromByteCount: Int64(archive.summary.payloadSizeBytes), countStyle: .file))
                    LabeledContent("Gallery queue", value: operations.galleryContext(sessionID: summary.sessionIdentifier))
                }
                .font(.callout)
                .padding(.top, 8)
            }
            .tint(OperatorPalette.accent)
        }
    }
}

/// Full-screen receipt inspector. Display only: nothing here can print or change the archive.
private struct FullReceiptPreviewSheet: View {
    let image: UIImage?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let image {
                    OperatorZoomableReceiptView(image: image, rendering: .smooth, accessibilityLabel: "Original receipt")
                        .padding()
                } else {
                    ContentUnavailableView(
                        "Receipt preview unavailable.",
                        systemImage: "photo",
                        description: Text("This archive does not include a readable receipt preview.")
                    )
                }
            }
            .navigationTitle("Original Receipt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

nonisolated private func debugLog(_ message: String) {
#if DEBUG
    print("[RecentSessionsView] \(message)")
#endif
}
