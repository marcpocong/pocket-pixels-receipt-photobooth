import SwiftUI
import XCTest
@testable import PocketPixelsBooth

@MainActor final class OperatorWorkspaceV41VisualTests: XCTestCase {
    private var root: URL!
    override func setUp() async throws { root = FileManager.default.temporaryDirectory.appendingPathComponent("v41-visual-\(UUID())") }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }
    private func fixture() async throws -> V41VisualFixture {
        let store = try RecentSessionArchiveStore(directoryURL: root.appendingPathComponent("archive"))
        let first = try V41ArchiveFixture.payload(), second = try V41ArchiveFixture.payload(token: String(repeating: "b", count: 64), sessionID: "PP-20261025-110000")
        try store.save(first); try store.save(second)
        try store.attachOriginalPhotos(archiveID: first.committedSession.galleryToken, sessionID: first.committedSession.sessionIdentifier,
            photos: first.committedSession.photos.compactMap { $0.jpegData(compressionQuality: 0.95) })
        let evidence = try GalleryVerificationStore(directory: root.appendingPathComponent("evidence"))
        try evidence.record(sessionID: first.committedSession.sessionIdentifier, token: first.committedSession.galleryToken, url: first.committedSession.galleryURL, source: "synthetic-test")
        let model = RecentSessionsViewModel(store: store, verificationStore: evidence)
        model.refresh()
        for _ in 0..<100 where !model.hasLoaded || model.galleryStatuses[first.committedSession.galleryToken] != .verified { try await Task.sleep(for: .milliseconds(10)) }
        let checkpoints = try CheckoutCheckpointStore(directory: root.appendingPathComponent("payments"))
        let test = OperatorWorkspaceV41ManagementTests()
        let active = test.checkpoint("PP-20261025-090000", method: "QRPH", phase: .awaitingProvider)
        let parked = test.checkpoint(method: "QRPH", phase: .awaitingProvider)
        try checkpoints.begin(active); try checkpoints.begin(parked)
        XCTAssertTrue(checkpoints.park(id: parked.id, reason: "guest left"))
        let archived = test.checkpoint("PP-20261024-080000", method: "QRPH", phase: .awaitingProvider)
        try checkpoints.begin(archived); XCTAssertTrue(checkpoints.park(id: archived.id, reason: "guest left"))
        XCTAssertTrue(checkpoints.update(id: archived.id) { $0.hiddenAt = Date() })
        let reader = V41RecoveryReader(); reader.response = try test.server(state: "UNKNOWN_RECONCILIATION")
        let recovery = PaymentRecoveryCoordinator(checkpointStore: { checkpoints }, reader: { reader }, outboxClient: { nil }, managementAuthorized: { true }, inspectManagementDependencies: { _ in .init() })
        await recovery.refresh()
        let runs = EventRunStore(directory: root.appendingPathComponent("runs"), authorized: { true }, blockingReason: { nil })
        let workspace = OperatorWorkspace(directory: root.appendingPathComponent("workspace"))
        let library = EventDesignLibraryStore(directory: root.appendingPathComponent("designs"), legacyProfile: { .pocketPixelsDefault }, legacyName: { "" }, operationAuthorized: { true }, operationBlockingReason: { nil })
        _ = try library.create(name: "Garden Celebration", venue: "Synthetic venue")
        let unused = try library.create(name: "Unused Test Setup", venue: "")
        _ = try runs.createHistoricalRun(name: "Garden Celebration", designID: unused.id, startedAt: Date().addingTimeInterval(-86_400), endedAt: Date())
        return V41VisualFixture(model: model, summaries: try store.summaries().sorted { $0.archiveID < $1.archiveID }, recovery: recovery, workspace: workspace, runs: runs, library: library)
    }
    private func capture<V: View>(_ view: V, name: String, size: CGSize = .init(width: 834, height: 1194), offset: CGFloat = 0) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let host = UIHostingController(rootView: view)
        let window = UIWindow(windowScene: scene); window.frame = CGRect(origin: .zero, size: size)
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        try await Task.sleep(for: .milliseconds(500)); host.view.layoutIfNeeded()
        if offset > 0 {
            func scrolls(_ view: UIView) -> [UIScrollView] { (view as? UIScrollView).map { [$0] } ?? view.subviews.flatMap(scrolls) }
            if let scroll = scrolls(host.view).filter({ $0.contentSize.height > $0.bounds.height }).max(by: { $0.bounds.width < $1.bounds.width }) {
                scroll.setContentOffset(CGPoint(x: 0, y: min(offset, max(0, scroll.contentSize.height - scroll.bounds.height))), animated: false)
            }
        }
        try await Task.sleep(for: .milliseconds(200))
        let image = UIGraphicsImageRenderer(size: size).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        XCTAssertGreaterThan(image.pngData()?.count ?? 0, 15_000)
        add(ScreenshotHarness.attachment(image, name: name))
        try image.pngData()?.write(to: URL(fileURLWithPath: "/tmp/v41-\(name).png"))
    }
    func testPortraitManagementAndMediaScreens() async throws {
        let fixture = try await fixture()
        try await capture(NavigationStack { RecentSessionsView(viewModel: fixture.model) }, name: "sessions-portrait")
        try await capture(NavigationStack { RecentSessionsView(viewModel: fixture.model, initialSelection: Set(fixture.summaries.map(\.archiveID))) }, name: "sessions-bulk-selection")
        try await capture(SessionCleanupReview(candidates: fixture.summaries, model: fixture.model), name: "session-deletion-review")
        try await capture(NavigationStack { ArchivedSessionDetailView(summary: fixture.summaries[0], rootViewModel: fixture.model) }, name: "receipt-fit-first")
        try await capture(NavigationStack { ArchivedSessionDetailView(summary: fixture.summaries[0], rootViewModel: fixture.model) }, name: "original-photos-and-gallery", offset: 950)
        try await capture(NavigationStack { ArchivedSessionDetailView(summary: fixture.summaries[1], rootViewModel: fixture.model) }, name: "thumbnail-only-and-unverified-gallery", offset: 950)
        try await capture(NavigationStack { List { CheckoutRecoverySection(recovery: fixture.recovery, showsArchived: true) }.navigationTitle("Checkout Recovery") }, name: "checkout-recovery-management")
        try await capture(CheckoutCleanupReview(ids: fixture.recovery.items.map(\.id), recovery: fixture.recovery), name: "checkout-deletion-review")
        try await capture(NavigationStack { OperatorEventsView(workspace: fixture.workspace, runs: fixture.runs, library: fixture.library) }, name: "event-management")
        try await capture(NavigationStack { RecentSessionsView(viewModel: fixture.model) }, name: "sessions-landscape", size: .init(width: 1194, height: 834))
        try await capture(NavigationStack { RecentSessionsView(viewModel: fixture.model).environment(\.dynamicTypeSize, .accessibility2) }, name: "sessions-accessibility")
    }

}

@MainActor private struct V41VisualFixture {
    let model: RecentSessionsViewModel
    let summaries: [RecentSessionArchiveSummary]
    let recovery: PaymentRecoveryCoordinator
    let workspace: OperatorWorkspace
    let runs: EventRunStore
    let library: EventDesignLibraryStore
}

extension OperatorWorkspaceV41VisualTests {
    func testReducedWidthSessionsAndAccessibleSelection() async throws {
        let fixture = try await fixture()
        try await capture(NavigationStack { RecentSessionsView(viewModel: fixture.model) }, name: "sessions-reduced-width", size: .init(width: 600, height: 1000))
        try await capture(NavigationStack {
            RecentSessionsView(viewModel: fixture.model, initialSelection: Set(fixture.summaries.map(\.archiveID)))
                .environment(\.dynamicTypeSize, .accessibility3)
        }, name: "sessions-reduced-width-accessible-selection", size: .init(width: 600, height: 1000))
    }
}
