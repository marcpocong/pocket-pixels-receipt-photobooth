import XCTest
import SwiftUI
@testable import PocketPixelsBooth

@MainActor final class OperatorDashboardV2Tests: XCTestCase {
    private var root: URL!
    override func setUp() { root = FileManager.default.temporaryDirectory.appendingPathComponent("dashboard-v2-\(UUID())") }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    func testFourPrimaryDestinationsAndLegacyRouteMigration() throws {
        XCTAssertEqual(OperatorPrimaryDestination.allCases.map(\.title), ["Home", "Events", "Reports", "System"])
        XCTAssertEqual(EventRunReportingView.Tab.reportSections.map(\.rawValue), ["Overview", "Sessions", "Sales"])
        let workspace = OperatorWorkspace(directory: root)
        workspace.path = [.manageEvent, .serverEvent("saved-event")]
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(workspace.snapshot)) as? [String: Any])
        json.removeValue(forKey: "primaryDestination"); json.removeValue(forKey: "sectionPaths"); json.removeValue(forKey: "setupStage")
        try JSONSerialization.data(withJSONObject: json).write(to: root.appendingPathComponent("OperatorWorkspaceV1/setup.json"))
        let restored = OperatorWorkspace(directory: root)
        XCTAssertEqual(restored.primaryDestination, .events)
        XCTAssertEqual(restored.path, [.manageEvent, .serverEvent("saved-event")])
        XCTAssertFalse(restored.hasPendingSetup)
        json["path"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode([OperatorWorkspaceRoute.sales, .eventReport("historical")]))
        try JSONSerialization.data(withJSONObject: json).write(to: root.appendingPathComponent("OperatorWorkspaceV1/setup.json"))
        let reports = OperatorWorkspace(directory: root)
        XCTAssertEqual(reports.primaryDestination, .reports)
        XCTAssertEqual(reports.path, [.eventReport("historical")])
        reports.saveReportSelection(tab: "Sales", runID: "past")
        reports.showCurrentReport()
        XCTAssertTrue(reports.path.isEmpty)
        XCTAssertNil(reports.snapshot.reportRunID)
        XCTAssertEqual(reports.snapshot.reportTab, "Overview")
        let routes: [OperatorWorkspaceRoute] = [.payments, .charging, .eventSetup, .boothCheck, .receiptDesign, .stickers, .samplePrints,
            .equipment, .advanced, .printer, .recovery, .camera, .gallery, .waitingGalleries, .recentSessions, .storage, .printHistory,
            .sessionSetup, .branding, .sales, .eventReport("event"), .eventMaintenance("event"), .savedDrafts,
            .newEvent, .savedEvent("design"), .eventHistory, .eventLibrary, .regularBooth, .monitoring]
        XCTAssertEqual(try JSONDecoder().decode([OperatorWorkspaceRoute].self, from: JSONEncoder().encode(routes)), routes)
    }

    func testSectionRestorationKeepsDraftsAndDoesNotPublishOrActivate() throws {
        let workspace = OperatorWorkspace(directory: root)
        let draft = SavedEventDesign.new(name: "Uncommitted", venue: "Private fixture")
        workspace.saveDesignDraft(draft, id: draft.id)
        workspace.select(.events); workspace.path = [.sessionSetup]
        workspace.saveSetupStage(2)
        workspace.select(.system); workspace.path = [.printer, .recovery]
        workspace.select(.reports); workspace.path = [.eventReport("read-only")]
        workspace.saveReportSelection(tab: "Sessions", runID: "historical-run")
        workspace.select(.events)
        XCTAssertEqual(workspace.path, [.sessionSetup])
        let restored = OperatorWorkspace(directory: root)
        XCTAssertEqual(restored.primaryDestination, .events)
        XCTAssertEqual(restored.snapshot.setupStage, 2)
        XCTAssertEqual(restored.snapshot.reportTab, "Sessions")
        XCTAssertEqual(restored.snapshot.reportRunID, "historical-run")
        XCTAssertEqual(restored.designDraft(id: draft.id), draft)
        restored.select(.system)
        XCTAssertEqual(restored.path, [.printer, .recovery])
        restored.finish(keepingDrafts: true)
        XCTAssertEqual(OperatorWorkspace(directory: root).designDraft(id: draft.id), draft)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("EventRunsV1/runs.json").path))
    }

    func testSavedPrepaidEventsRestoreCopyLimitsFormatsAndUnsavedDraftsWithoutActivation() async throws {
        let workspace = OperatorWorkspace(directory: root)
        let acceptance = SessionAcceptanceStore(directory: root)
        let library = EventDesignLibraryStore(directory: root, legacyProfile: { .pocketPixelsDefault }, legacyName: { "" },
            operationAuthorized: { true }, operationBlockingReason: { nil })
        let runs = EventRunStore(directory: root.appendingPathComponent("runs"), authorized: { true }, blockingReason: { nil })
        let first = try library.create(name: "First event", venue: "")
        let second = try library.create(name: "Second event", venue: "")
        let applied = CommercialEventRun.legacy
        let beforeAdmission = acceptance.state
        let setup = SessionSetupCoordinator(workspace: workspace, acceptance: acceptance, library: library, eventRuns: runs,
            creations: CommercialEventCreationStore(directory: root), authorized: { true }, blockingReason: { nil },
            loadLocal: { applied }, saveLocal: { _ in XCTFail("Saving or selecting a reusable event must not publish the active booth") },
            source: { .localPrepaid }, saveSource: { _ in XCTFail("Selecting a saved event must not change the payment source") })
        await setup.setEventMode(true)
        await setup.chooseDesign(first.id)
        setup.prepaid.activePolicy.maxCopies = 4
        setup.prepaid.activePolicy.defaultCopies = 2
        setup.prepaid.activePolicy.supportedFormatRawValues = ["duo"]
        await setup.saveOnly()
        XCTAssertEqual(library.design(id: first.id)?.prepaidPolicy?.defaultCopies, 2)
        await setup.chooseDesign(second.id)
        setup.prepaid.activePolicy.defaultCopies = 1
        setup.prepaid.activePolicy.maxCopies = 1
        setup.prepaid.activePolicy.supportedFormatRawValues = ["solo"]
        await setup.saveOnly()
        await setup.chooseDesign(first.id)
        XCTAssertEqual(setup.prepaid.activePolicy.maxCopies, 4)
        XCTAssertEqual(setup.prepaid.activePolicy.defaultCopies, 2)
        XCTAssertEqual(setup.prepaid.activePolicy.supportedFormatRawValues, ["duo"])
        setup.prepaid.activePolicy.maxCopies = 3
        await setup.chooseDesign(second.id)
        await setup.chooseDesign(first.id)
        XCTAssertEqual(setup.prepaid.activePolicy.maxCopies, 3, "Unsaved per-event copy settings survive event switching")
        XCTAssertEqual(library.design(id: first.id)?.prepaidPolicy?.maxCopies, 4, "Staged edits cannot overwrite the saved event")
        XCTAssertEqual(OperatorWorkspace(directory: root).designDraft(id: first.id)?.prepaidPolicy?.maxCopies, 3)
        XCTAssertEqual(acceptance.state, beforeAdmission)
        XCTAssertTrue(runs.runs.isEmpty)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(first)) as? [String: Any])
        legacy.removeValue(forKey: "prepaidPolicy")
        XCTAssertNil(try JSONDecoder().decode(SavedEventDesign.self, from: JSONSerialization.data(withJSONObject: legacy)).prepaidPolicy)
    }

    func testTruthfulEmptyEquipmentStateAndContextualPause() {
        let status = OperatorStatusSummary(report: EventReadinessReport(checks: [], generatedAt: Date()), hasUnresolvedPrint: false,
            printerRequiresRecovery: false, pendingUploadCount: 0, galleryStorageError: false)
        XCTAssertFalse(status.allSystemsReady)
        for component in [status.camera, status.printer, status.gallery, status.internet] { XCTAssertEqual(component.label, "Not checked") }
        for state in [EventOperatorStatus.regular, .accepting, .unconfirmed("offline")] {
            XCTAssertTrue(OperatorHomeActionPolicy(status: state).showsPause)
        }
        for state in [EventOperatorStatus.noEvent, .draft, .ready, .pausedOnBooth, .serverPaused, .needsReview("review"),
            .recoveryRequired("uncertain print"), .completed, .archived, .starting, .ending] {
            XCTAssertFalse(OperatorHomeActionPolicy(status: state).showsPause)
        }
        XCTAssertNotEqual(EventOperatorStatus.pausedOnBooth.title, EventOperatorStatus.serverPaused.title)
    }

    func testRunMetricsChartsAndSessionFiltersUseExactDeduplicatedEvidence() {
        let start = Date(timeIntervalSince1970: 1_792_100_000)
        var a = EventRunSession(sessionID: "one", runID: "selected", createdAt: start, format: "solo")
        a.completedAt = start; a.printOutcomes = ["batch/1": "delivered", "batch/2": "uncertain"]
        a.galleryPreparedAt = start
        var b = EventRunSession(sessionID: "two", runID: "selected", createdAt: start.addingTimeInterval(3_600), format: "duo")
        b.completedAt = b.createdAt; b.galleryPreparedAt = start; b.galleryVerifiedAt = start
        b.printOutcomes = ["batchB/1": "delivered"]
        var other = a; other = EventRunSession(sessionID: "other", runID: "another", createdAt: start, format: "solo", completedAt: start)
        let insights = OperatorRunInsights(runID: "selected", sessions: [a, a, b, other])
        XCTAssertEqual(insights.sessions.count, 2)
        XCTAssertEqual(insights.statistics.completed, 2)
        XCTAssertEqual(insights.statistics.delivered, 2)
        XCTAssertEqual(insights.statistics.uncertain, 1)
        XCTAssertEqual(insights.statistics.galleriesVerified, 1)
        XCTAssertEqual(insights.statistics.galleriesAwaitingVerification, 1)
        XCTAssertEqual(insights.hours.map(\.count).reduce(0, +), 2)
        XCTAssertEqual(insights.statistics.completedByFormat, ["solo": 1, "duo": 1])
        XCTAssertEqual(OperatorSessionFilter.apply(insights.sessions, query: "ONE", format: "solo", status: "waiting").map(\.sessionID), ["one"])
        XCTAssertEqual(OperatorSessionFilter.apply(insights.sessions, query: "", format: "all", status: "review").map(\.sessionID), ["one"])
        XCTAssertTrue(OperatorSessionFilter.apply(insights.sessions, query: "missing", format: "all", status: "all").isEmpty)
        XCTAssertEqual(OperatorRunInsights(runID: "empty", sessions: [a, b]).statistics.completed, 0)
    }

    func testPortraitLandscapeAndNarrowWorkspaceRules() {
        XCTAssertFalse(OperatorWorkspaceLayout.usesSidebar(width: 834, height: 1_194))
        XCTAssertTrue(OperatorWorkspaceLayout.usesSidebar(width: 1_194, height: 834))
        XCTAssertFalse(OperatorWorkspaceLayout.usesSidebar(width: 700, height: 834))
        XCTAssertEqual(OperatorSetupStage.allCases.map(\.title), ["Event Details", "Payment & Prints", "Receipt & Branding", "Review & Start"])
    }

    func testRenderedWorkspaceAndMajorScreensInBothOrientations() async throws {
        let workspace = OperatorWorkspace(directory: root)
        let runs = EventRunStore(directory: root.appendingPathComponent("runs"), authorized: { true }, blockingReason: { nil })
        let acceptance = SessionAcceptanceStore(directory: root)
        let library = EventDesignLibraryStore(directory: root, legacyProfile: { .pocketPixelsDefault }, legacyName: { "" },
            operationAuthorized: { true }, operationBlockingReason: { nil })
        let run = try runs.startNewRun(context: EventRunContext(designID: nil, commercialEventID: nil, serverBinding: nil, name: "Studio Preview Event"))
        for index in 0..<6 {
            let id = "SYNTHETIC-\(index)"
            try runs.beginSession(id: id, runID: run.id, format: index.isMultiple(of: 2) ? "solo" : "duo")
            runs.updateSession(id: id) {
                $0.completedAt = Date().addingTimeInterval(Double(index) * -3_600)
                $0.printOutcomes["batch/1"] = index == 5 ? "uncertain" : "delivered"
                $0.galleryPreparedAt = Date()
                if index < 4 { $0.galleryVerifiedAt = Date() }
            }
        }
        let lifecycle = EventLifecycleCoordinator(runs: runs, acceptance: acceptance, authorized: { true },
            blockingReason: { nil }, recoveryReason: { nil }, source: { .localPrepaid },
            appliedContext: { run.context }, hasUnsavedSetup: { false })
        let setup = SessionSetupCoordinator(workspace: workspace, acceptance: acceptance, library: library, eventRuns: runs,
            creations: CommercialEventCreationStore(directory: root), authorized: { true }, blockingReason: { nil }, source: { .localPrepaid })
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        for size in [CGSize(width: 834, height: 1_194), CGSize(width: 1_194, height: 834)] {
            for section in OperatorPrimaryDestination.allCases {
                workspace.select(section); workspace.path = []
                try await render(AnyView(OperatorWorkspaceView(workspace: workspace, lifecycle: lifecycle, loadsRemote: false)),
                    name: section.rawValue, size: size, scene: scene)
            }
            for stage in OperatorSetupStage.allCases {
                workspace.saveSetupStage(stage.rawValue)
                try await render(AnyView(NavigationStack { SessionSetupView(coordinator: setup) }),
                    name: "setup-\(stage.rawValue + 1)", size: size, scene: scene)
            }
            for tab in [EventRunReportingView.Tab.overview, .activity, .sales] {
                try await render(AnyView(NavigationStack { EventRunReportingView(store: runs, library: library,
                    archiveDirectory: root.appendingPathComponent("archives"), loadsRemote: false, initialTab: tab) }),
                    name: "reports-\(tab.rawValue.lowercased())", size: size, scene: scene)
            }
            try await render(AnyView(NavigationStack { OperatorRecoveryView() }), name: "printer-recovery", size: size, scene: scene)
            let everyday: [(String, AnyView)] = [
                ("regular-defaults", AnyView(RegularBoothSettingsView())),
                ("printer-setup", AnyView(OperatorPrinterSetupView())),
                ("branding-defaults", AnyView(OperatorBrandingView())),
                ("recent-sessions", AnyView(RecentSessionsView())),
                ("retained-sessions", AnyView(RetainedRecoverySessionsView()))
            ]
            for (name, view) in everyday {
                try await render(AnyView(NavigationStack { view }), name: name, size: size, scene: scene)
            }
        }
        workspace.select(.home); workspace.path = []
        try await render(AnyView(OperatorWorkspaceView(workspace: workspace, lifecycle: lifecycle, loadsRemote: false)
            .environment(\.dynamicTypeSize, .accessibility3)), name: "home-accessibility", size: CGSize(width: 700, height: 1_024), scene: scene)
        try await render(AnyView(NavigationStack { RegularBoothSettingsView() }.environment(\.dynamicTypeSize, .accessibility3)),
            name: "regular-accessibility", size: CGSize(width: 700, height: 1_024), scene: scene)
        try await render(AnyView(NavigationStack { OperatorPrinterSetupView() }.environment(\.dynamicTypeSize, .accessibility3)),
            name: "printer-accessibility", size: CGSize(width: 700, height: 1_024), scene: scene)
        workspace.saveSetupStage(3)
        try await render(AnyView(NavigationStack { SessionSetupView(coordinator: setup) }.environment(\.dynamicTypeSize, .accessibility3)),
            name: "setup-accessibility", size: CGSize(width: 700, height: 1_024), scene: scene)
        // Rendering and navigation never changes the run or opens the admission barrier.
        XCTAssertEqual(runs.current?.id, run.id)
        XCTAssertEqual(runs.current?.status, .active)
        let archived = try runs.createHistoricalRun(name: "Earlier Studio Event", designID: nil,
            startedAt: Date().addingTimeInterval(-86_400), endedAt: Date().addingTimeInterval(-82_800))
        try runs.transition(id: archived.id, to: .archived)
        workspace.saveReportSelection(tab: "Overview", runID: archived.id)
        try await render(AnyView(NavigationStack { EventRunReportingView(store: runs, library: library,
            archiveDirectory: root.appendingPathComponent("archives"), loadsRemote: false, workspace: workspace) }),
            name: "reports-archived-scope", size: CGSize(width: 834, height: 1_194), scene: scene)
        XCTAssertEqual(workspace.snapshot.reportRunID, archived.id)
        XCTAssertEqual(runs.current?.id, run.id, "Restoring historical scope cannot change the accepting run")
    }

    private func render(_ view: AnyView, name: String, size: CGSize, scene: UIWindowScene) async throws {
        let host = UIHostingController(rootView: view)
        let window = UIWindow(windowScene: scene); window.frame = CGRect(origin: .zero, size: size)
        window.overrideUserInterfaceStyle = .light
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        try await Task.sleep(for: .milliseconds(800))
        host.view.frame = window.bounds; host.view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(size: size).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        let data = try XCTUnwrap(image.pngData())
        XCTAssertGreaterThan(data.count, 15_000, "\(name) rendered blank")
        let label = "dashboard-v2-\(name)-\(size.width > size.height ? "landscape" : "portrait")"
        let attachment = XCTAttachment(image: image); attachment.name = label; attachment.lifetime = .keepAlways; add(attachment)
        try data.write(to: URL(fileURLWithPath: "/tmp/\(label).png"))
    }
}
