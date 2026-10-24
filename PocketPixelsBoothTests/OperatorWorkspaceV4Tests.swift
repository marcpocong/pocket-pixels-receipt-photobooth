import SwiftUI
import XCTest
@testable import PocketPixelsBooth

@MainActor final class OperatorWorkspaceV4Tests: XCTestCase {
    private var root: URL!
    override func setUp() { root = FileManager.default.temporaryDirectory.appendingPathComponent("workspace-v4-\(UUID())") }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    func testLegacySessionBoothAndSystemPathsKeepDeeperRoutesAndDrafts() throws {
        for route in [OperatorWorkspaceRoute.recentSessions, .regularBooth, .equipment] {
            let workspace = OperatorWorkspace(directory: root)
            workspace.select(route == .equipment ? .system : .reports)
            workspace.path = [route, .storage]
            workspace.saveNewEvent(name: "Keep this draft", venue: "Portrait")
            let restored = OperatorWorkspace(directory: root)
            XCTAssertEqual(restored.primaryDestination, route.primaryDestination)
            XCTAssertEqual(restored.path, route == .equipment ? [.equipment, .storage] : [.storage])
            XCTAssertEqual(restored.snapshot.newEventName, "Keep this draft")
        }
        let workspace = OperatorWorkspace(directory: root)
        workspace.navigate(to: .recentSessions)
        XCTAssertEqual(workspace.primaryDestination, .sessions); XCTAssertTrue(workspace.path.isEmpty)
        workspace.navigate(to: .regularBooth)
        XCTAssertEqual(workspace.primaryDestination, .booth); XCTAssertTrue(workspace.path.isEmpty)
        workspace.navigate(to: .recovery)
        XCTAssertEqual(workspace.primaryDestination, .system); XCTAssertEqual(workspace.path, [.recovery])
    }

    func testBoothDraftSurvivesTabsRelaunchAndFailedDiscard() throws {
        let workspace = OperatorWorkspace(directory: root)
        var draft = RegularBoothSettings(); draft.maxCopies = 7
        var profile = draft.profile; profile.receiptDesign.editorialCaption = "A NIGHT TO KEEP"; draft.receiptProfile = profile
        workspace.saveRegularBoothDraft(draft)
        XCTAssertTrue(workspace.hasUnsavedDrafts)
        XCTAssertFalse(workspace.hasUnsavedEventSetup, "Regular defaults cannot become an unrelated event-resume gate")
        workspace.select(.booth); workspace.path = [.regularFooter]
        workspace.select(.events); workspace.saveNewEvent(name: "Independent event", venue: "")
        XCTAssertTrue(workspace.hasUnsavedEventSetup, "The existing event-draft guard remains intact")
        workspace.select(.booth)
        XCTAssertEqual(workspace.path, [.regularFooter])
        let restored = OperatorWorkspace(directory: root)
        XCTAssertEqual(restored.snapshot.regularBoothDraft, draft)
        XCTAssertTrue(restored.hasUnsavedDrafts)
        XCTAssertTrue(SavedDraftCatalog.entries(workspace: restored, library: .init()).contains { $0.id == .regularBooth })
        let failing = OperatorWorkspace(directory: root, write: { _, _ in throw CocoaError(.fileWriteOutOfSpace) })
        XCTAssertThrowsError(try failing.discardDraft(.regularBooth, authorized: { true }))
        XCTAssertEqual(failing.snapshot.regularBoothDraft, draft)
        XCTAssertEqual(OperatorWorkspace(directory: root).snapshot.regularBoothDraft, draft)
        try restored.discardDraft(.regularBooth, authorized: { true })
        XCTAssertNil(restored.snapshot.regularBoothDraft)
        XCTAssertEqual(restored.snapshot.newEventName, "Independent event")
    }

    func testOpeningBoothDoesNotCreateDraftAndReturningFromFooterKeepsLatestEdits() async throws {
        let workspace = OperatorWorkspace(directory: root)
        workspace.select(.booth)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene); window.frame = CGRect(x: 0, y: 0, width: 834, height: 1194)
        let host = UIHostingController(rootView: OperatorWorkspaceView(workspace: workspace, loadsRemote: false))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(workspace.snapshot.regularBoothDraft, "Opening untouched defaults must not create an edit from the generated studio profile date")
        workspace.path = [.regularFooter]
        try await Task.sleep(for: .milliseconds(300))
        var draft = RegularBoothSettings.load()
        var profile = draft.profile; profile.receiptDesign.editorialCaption = "LATEST FOOTER"; draft.receiptProfile = profile
        workspace.saveRegularBoothDraft(draft)
        workspace.path = []
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(workspace.snapshot.regularBoothDraft?.profile.receiptDesign.editorialCaption, "LATEST FOOTER", "Returning to the parent form cannot overwrite the footer with stale state")
        workspace.select(.events); workspace.path = [.regularBooth]
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(workspace.primaryDestination, .booth)
        XCTAssertTrue(workspace.path.isEmpty)
        workspace.select(.reports); workspace.path = [.recentSessions]
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(workspace.primaryDestination, .sessions)
        XCTAssertTrue(workspace.path.isEmpty)
    }

    func testThumbnailCancellationBoundsConcurrentReadersAndMemoryWarningEviction() async throws {
        let store = try RecentSessionArchiveStore(directoryURL: root)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 800)).image { context in
            UIColor.systemPink.setFill(); context.fill(CGRect(x: 0, y: 0, width: 600, height: 800))
        }
        let data = try XCTUnwrap(image.jpegData(compressionQuality: 0.8))
        let ids = (1...25).map { String(format: "%064x", $0) }
        for id in ids {
            let directory = root.appendingPathComponent(id)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appendingPathComponent("photo.jpg"))
        }
        let cache = SessionThumbnailCache(byteLimit: 256 * 256 * 4 * 3, countLimit: 3)
        await withTaskGroup(of: Void.self) { group in
            for id in ids { group.addTask { _ = await cache.image(archiveID: id, filename: "photo.jpg", store: store) } }
        }
        let bounded = await cache.statistics()
        XCTAssertLessThanOrEqual(bounded.count, 3); XCTAssertLessThanOrEqual(bounded.bytes, 256 * 256 * 4 * 3)
        await cache.removeAll()
        let task = Task { await cache.image(archiveID: ids[0], filename: "photo.jpg", store: store) }
        task.cancel()
        let cancelled = await task.value; XCTAssertNil(cancelled)
        let empty = await cache.statistics(); XCTAssertEqual(empty.count, 0); XCTAssertEqual(empty.bytes, 0)
        let model = RecentSessionsViewModel(store: store)
        _ = await model.thumbnails.image(archiveID: ids[0], filename: "photo.jpg", store: store)
        NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        try await Task.sleep(for: .milliseconds(100))
        let warned = await model.thumbnails.statistics(); XCTAssertEqual(warned.count, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(ids[0] + "/photo.jpg").path))
    }
    func testMetadataRefreshCancellationFiltersAndStorageFailureRemainTruthful() async throws {
        let store = try RecentSessionArchiveStore(directoryURL: root)
        let now = Date()
        func summary(_ id: String, date: Date, event: String?, format: BoothFormat) -> RecentSessionArchiveSummary {
            .init(archiveID: id, sessionIdentifier: "guest-" + id, createdAt: date, format: format, eventName: event,
                eventLocation: nil, photoCount: 1, receiptWidth: 576, receiptHeight: 1000, estimatedLengthMillimeters: 125,
                rasterFingerprint: "fixture", thumbnailFilenames: [], lastReprintedAt: nil, reprintCount: 0, payloadSizeBytes: 0)
        }
        let today = summary(String(repeating: "a", count: 64), date: now, event: "Wedding", format: .solo)
        let yesterday = summary(String(repeating: "b", count: 64), date: Calendar.current.date(byAdding: .day, value: -1, to: now)!, event: nil, format: .duo)
        let probe = MetadataLoadProbe(first: [yesterday], next: [today, yesterday])
        let model = RecentSessionsViewModel(store: store, summaryLoader: { try probe.load() })
        model.refresh()
        try await Task.sleep(for: .milliseconds(30))
        model.refresh()
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(model.summaries.map(\.id), [today.id, yesterday.id], "An older cancelled refresh cannot overwrite a newer archive snapshot")
        model.todayOnly = true; XCTAssertEqual(model.filteredSummaries.map(\.id), [today.id])
        model.todayOnly = false; model.eventFilter = "Regular Booth"; XCTAssertEqual(model.filteredSummaries.map(\.id), [yesterday.id])
        model.clearFilters(); model.dateFrom = yesterday.createdAt; model.dateThrough = yesterday.createdAt
        XCTAssertEqual(model.filteredSummaries.map(\.id), [yesterday.id])
        model.clearFilters(); model.formatFilter = .solo; model.searchText = "WEDDING"
        XCTAssertEqual(model.filteredSummaries.map(\.id), [today.id])
        model.selectedArchiveID = today.id
        model.refresh(); try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(model.selectedArchiveID, today.id)
        XCTAssertEqual(model.searchText, "WEDDING")
        probe.fails = true
        model.refresh(); try await Task.sleep(for: .milliseconds(100))
        XCTAssertNotNil(model.loadError)
        XCTAssertEqual(model.summaries.count, 2, "Failed refresh retains known metadata; it never claims archives were deleted")
    }

}

nonisolated private final class MetadataLoadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private let first: [RecentSessionArchiveSummary]
    private let next: [RecentSessionArchiveSummary]
    private var failure = false
    var fails: Bool { get { lock.lock(); defer { lock.unlock() }; return failure } set { lock.lock(); defer { lock.unlock() }; failure = newValue } }
    init(first: [RecentSessionArchiveSummary], next: [RecentSessionArchiveSummary]) { self.first = first; self.next = next }
    func load() throws -> [RecentSessionArchiveSummary] {
        lock.lock(); calls += 1; let call = calls; let failed = failure; lock.unlock()
        if failed { throw CocoaError(.fileReadCorruptFile) }
        if call == 1 { Thread.sleep(forTimeInterval: 0.18) }
        return call == 1 ? first : next
    }
}
