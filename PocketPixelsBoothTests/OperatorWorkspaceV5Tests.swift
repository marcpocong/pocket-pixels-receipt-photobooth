import SwiftUI
import XCTest
@testable import PocketPixelsBooth

@MainActor final class OperatorWorkspaceV5Tests: XCTestCase {
    private var root: URL!
    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("operator-v5-\(UUID())")
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    func testFiveDestinationsAndAllTypedRoutesKeepTheirIdentity() throws {
        XCTAssertEqual(OperatorPrimaryDestination.allCases, [.home, .booth, .sessions, .events, .reports])
        let routes: [OperatorWorkspaceRoute] = [.liveEvent, .manageEvent, .payments, .charging, .eventSetup,
            .boothCheck, .receiptDesign, .stickers, .samplePrints, .equipment, .advanced, .printer, .recovery,
            .camera, .gallery, .waitingGalleries, .recentSessions, .storage, .printHistory, .serverEvent("original"),
            .sessionSetup, .branding, .sales, .eventReport("original"), .eventMaintenance("original"), .savedDrafts,
            .draftReview(.regularBooth), .newEvent, .customizeEvent, .previousEvent, .savedEvent("design"), .prepareEvent("design"),
            .eventHistory, .eventLibrary, .regularBooth, .regularFooter, .monitoring]
        XCTAssertEqual(try JSONDecoder().decode([OperatorWorkspaceRoute].self, from: JSONEncoder().encode(routes)), routes)
        let workspace = OperatorWorkspace(directory: root)
        workspace.saveNewEvent(name: "A long celebration name with a saved editing draft", venue: "Garden")
        workspace.select(.booth); workspace.path = [.regularFooter]
        workspace.select(.events); workspace.path = [.savedDrafts, .draftReview(.regularBooth)]
        workspace.select(.home)
        workspace.select(.events)
        XCTAssertEqual(workspace.path, [.savedDrafts, .draftReview(.regularBooth)])
        workspace.finish(keepingDrafts: true)
        let restored = OperatorWorkspace(directory: root)
        XCTAssertEqual(restored.path, workspace.path)
        XCTAssertEqual(restored.snapshot.newEventName, workspace.snapshot.newEventName)
        restored.select(.booth)
        XCTAssertEqual(restored.path, [.regularFooter])
    }

    func testAllCurrentFollowUpsRemainVisibleAndNormalQueueIsProgress() {
        let checks = ["Unsafe Print State", "Archive Storage", "Pending Gallery Storage", "Camera Authorization", "Event Profile"]
            .map { EventReadinessCheck(severity: .critical, title: $0, status: .fail, detail: "Synthetic failure") }
        let status = OperatorStatusSummary(report: .init(checks: checks, generatedAt: Date()), hasUnresolvedPrint: true,
            printerRequiresRecovery: true, pendingUploadCount: 4, galleryStorageError: true)
        XCTAssertEqual(Set(status.actionableAttentionItems.map(\.id)), ["print-confirmation", "camera-access", "storage", "gallery-storage", "event-profile"])
        XCTAssertEqual(status.actionableAttentionItems.first?.destination, .recovery)
        let normalQueue = OperatorStatusSummary(report: .init(checks: [.init(severity: .important, title: "Pending Uploads", status: .warning, detail: "4")], generatedAt: Date()),
            hasUnresolvedPrint: false, printerRequiresRecovery: false, pendingUploadCount: 4, galleryStorageError: false)
        XCTAssertTrue(normalQueue.actionableAttentionItems.isEmpty)
        XCTAssertEqual(normalQueue.gallery.label, "4 waiting")
    }

    func testMonitoringEvidenceSeparatesUnknownFreshAndStaleFromTelegram() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(OperatorEvidence.monitoringDetail(lastAccepted: nil, configured: false, now: now).contains("Not configured"))
        XCTAssertTrue(OperatorEvidence.monitoringDetail(lastAccepted: nil, configured: true, now: now).contains("No accepted heartbeat"))
        let fresh = OperatorEvidence.monitoringDetail(lastAccepted: now.addingTimeInterval(-300), configured: true, now: now)
        let stale = OperatorEvidence.monitoringDetail(lastAccepted: now.addingTimeInterval(-601), configured: true, now: now)
        XCTAssertTrue(fresh.contains("Worker accepted heartbeat")); XCTAssertTrue(stale.contains("Stale observation"))
        XCTAssertTrue(fresh.contains("Telegram delivery is not verified")); XCTAssertTrue(stale.contains("Telegram delivery is not verified"))
    }

    private func capture<V: View>(_ view: V, name: String, type: DynamicTypeSize = .large) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let size = CGSize(width: 834, height: 1194)
        let host = UIHostingController(rootView: view.environment(\.dynamicTypeSize, type))
        let window = UIWindow(windowScene: scene); window.frame = CGRect(origin: .zero, size: size)
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        try await Task.sleep(for: .milliseconds(700))
        host.view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(size: size).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        let data = try XCTUnwrap(image.pngData())
        XCTAssertGreaterThan(data.count, 15_000, "A screen must render real content")
        let output = URL(fileURLWithPath: "/tmp/pp-v5-release-shots", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try data.write(to: output.appendingPathComponent("\(name).png"))
        let attachment = XCTAttachment(image: image); attachment.name = "V5 \(name)"; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testPortraitPrimaryAndNestedScreens() async throws {
        let wasAuthorized = OperatorAccessPermit.shared.isAuthorized
        OperatorAccessPermit.shared.authorize()
        defer { if !wasAuthorized { OperatorAccessPermit.shared.revoke() } }
        let workspace = OperatorWorkspace(directory: root.appendingPathComponent("workspace"))
        let runs = EventRunStore(directory: root.appendingPathComponent("runs"), authorized: { true }, blockingReason: { nil })
        let lifecycle = EventLifecycleCoordinator(runs: runs, acceptance: SessionAcceptanceStore(directory: root), authorized: { true }, blockingReason: { nil }, recoveryReason: { nil }, source: { .localPrepaid })
        let archive = try RecentSessionArchiveStore(directoryURL: root.appendingPathComponent("archive"))
        let payload = try V41ArchiveFixture.payload()
        try archive.save(payload)
        let summary = try XCTUnwrap(archive.summaries().first)
        let sessions = RecentSessionsViewModel(store: archive)
        sessions.refresh()
        for destination in OperatorPrimaryDestination.allCases {
            workspace.select(destination)
            try await capture(OperatorWorkspaceView(workspace: workspace, lifecycle: lifecycle, loadsRemote: false, sessionsViewModel: sessions), name: destination.rawValue)
        }
        let nested: [(String, AnyView)] = [
            ("system", AnyView(OperatorEquipmentView())),
            ("recovery", AnyView(OperatorRecoveryView())),
            ("waiting-galleries", AnyView(PendingUploadsView())),
            ("gallery-settings", AnyView(OperatorGallerySettingsView())),
            ("settings-form", AnyView(RegularBoothSettingsView(workspace: workspace, footerOnly: true))),
            ("print-history", AnyView(OperatorPrintAuditView())),
            ("monitoring", AnyView(BoothMonitoringView())),
            ("advanced", AnyView(OperatorAdvancedView())),
            ("saved-drafts", AnyView(SavedDraftsView())),
            ("sample-studio", AnyView(SamplePrintStudioView())),
            ("session-detail", AnyView(ArchivedSessionDetailView(summary: summary, rootViewModel: sessions)))
        ]
        for (name, screen) in nested { try await capture(NavigationStack { screen.toolbar(.visible, for: .navigationBar) }, name: name) }
        let design = SavedEventDesign.new(name: "Portrait design", venue: "Synthetic venue")
        try await capture(NavigationStack { ReceiptStudioView(design: .constant(design), profile: design.profile) }, name: "receipt-studio")
        try await capture(NavigationStack { ReceiptStudioView(design: .constant(design), profile: design.profile) }, name: "receipt-studio-accessibility", type: .accessibility2)
        workspace.select(.home)
        try await capture(OperatorWorkspaceView(workspace: workspace, lifecycle: lifecycle, loadsRemote: false, sessionsViewModel: sessions), name: "home-accessibility", type: .accessibility2)
        try await capture(NavigationStack { OperatorRecoveryView() }, name: "recovery-accessibility", type: .accessibility2)
        try await capture(NavigationStack { ArchivedSessionDetailView(summary: summary, rootViewModel: sessions) }, name: "detail-accessibility", type: .accessibility2)
        _ = try runs.startNewRun(context: .init(designID: nil, commercialEventID: nil, serverBinding: nil,
            name: "The Garden Celebration of Alexandra & Christopher — An Evening Made to Keep"))
        try await capture(NavigationStack { ScrollView { CurrentEventCard(lifecycle: lifecycle, loadsRemote: false, workspace: workspace).padding(24) }.operatorScreen() }, name: "long-event-name", type: .accessibility2)
        let simultaneous = OperatorStatusSummary(report: .init(checks: ["Unsafe Print State", "Archive Storage", "Pending Gallery Storage", "Camera Authorization", "Event Profile"].map {
            EventReadinessCheck(severity: .critical, title: $0, status: .fail, detail: "Synthetic failure")
        }, generatedAt: Date()), hasUnresolvedPrint: true, printerRequiresRecovery: true, pendingUploadCount: 3, galleryStorageError: true)
        try await capture(ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                OperatorSectionHeading(title: "Follow-ups", detail: "Synthetic simultaneous operator issues")
                OperatorAttentionCard(items: simultaneous.actionableAttentionItems, workspace: workspace)
            }.padding(24)
        }.operatorScreen(), name: "simultaneous-follow-ups")
    }
}
