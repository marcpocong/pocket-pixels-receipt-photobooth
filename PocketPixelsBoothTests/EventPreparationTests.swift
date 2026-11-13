import SwiftUI
import XCTest
@testable import PocketPixelsBooth

@MainActor final class EventPreparationTests: XCTestCase {
    private var root: URL!
    private var workspace: OperatorWorkspace!
    private var library: EventDesignLibraryStore!
    private var runs: EventRunStore!
    private let binding = "test:https://payments.example.test"

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("prepare-event-\(UUID())")
        workspace = OperatorWorkspace(directory: root)
        library = EventDesignLibraryStore(directory: root, legacyProfile: { .pocketPixelsDefault }, legacyName: { "" }, operationAuthorized: { true }, operationBlockingReason: { nil })
        runs = EventRunStore(directory: root, authorized: { true }, blockingReason: { nil })
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    private func presentation(_ id: String, error: String? = nil, historyUnreadable: Bool = false) -> EventPreparationPresentation {
        .init(designID: id, library: library.library, libraryError: error,
              workspace: workspace.snapshot, workspaceError: workspace.persistenceError, binding: binding,
              operationalRun: runs.operational, historyUnreadable: historyUnreadable)
    }

    func testDuplicateNamesUseStableDesignIdentityAndDoNotCreateOccurrences() throws {
        let first = try library.create(name: "Celebration", venue: "First venue")
        let second = try library.create(name: "Celebration", venue: "Second venue")
        let model = presentation(second.id)
        XCTAssertEqual(model.saved?.id, second.id)
        XCTAssertEqual(model.saved?.venue, "Second venue")
        XCTAssertEqual(model.setupRoute, .savedEvent(second.id))
        XCTAssertNotEqual(model.saved?.id, first.id)
        XCTAssertNil(runs.currentRunID)
        XCTAssertNil(library.library.appliedEventID)
    }

    func testSavedAndExplicitStagedContentHaveDistinctProvenance() throws {
        var saved = try library.create(name: "Saved celebration", venue: "Saved venue")
        saved.prepaidPolicy = .legacyPrepaid
        saved.prepaidPolicy?.defaultCopies = 2
        saved.profile.stickerStudioEnabled = false
        try library.save(saved)
        var draft = saved
        draft.name = "Unsaved celebration"; draft.venue = "Draft venue"
        draft.prepaidPolicy?.maxCopies = 4; draft.guestScreensEnabled = true
        workspace.saveDesignDraft(draft, id: saved.id)
        let model = presentation(saved.id)
        XCTAssertTrue(model.hasDraft)
        XCTAssertEqual(model.design(for: .saved), library.design(id: saved.id))
        XCTAssertEqual(model.design(for: .staged)?.name, draft.name)
        XCTAssertEqual(model.design(for: .saved)?.guestScreensEnabled, false)
        XCTAssertEqual(model.design(for: .staged)?.guestScreensEnabled, true)
        XCTAssertEqual(model.policyRows(for: .saved).first { $0.0 == "Included / maximum copies" }?.1, "2 / 10")
        XCTAssertEqual(model.policyRows(for: .staged).first { $0.0 == "Included / maximum copies" }?.1, "2 / 4")
        XCTAssertEqual(model.previewLabel(for: .saved), "Saved design preview")
        XCTAssertEqual(model.previewLabel(for: .staged), "Staged draft preview")
        XCTAssertEqual(EventPreparationPresentation.Source.saved.rawValue, "Saved design")
        XCTAssertEqual(EventPreparationPresentation.Source.staged.rawValue, "Staged draft")
    }

    func testAnotherActiveEventIsUntouchedAndSameActiveEventUsesLiveEditing() throws {
        let first = try library.create(name: "Active event", venue: "")
        let second = try library.create(name: "Tomorrow", venue: "")
        try library.recordApplied(eventModeEnabled: true, eventID: first.id)
        let run = try runs.startNewRun(context: .init(designID: first.id, commercialEventID: nil, serverBinding: nil, name: first.name))
        let next = presentation(second.id)
        XCTAssertTrue(next.application.contains(first.name))
        XCTAssertFalse(next.editsLiveEvent); XCTAssertFalse(next.isApplied)
        XCTAssertEqual(next.setupRoute, .savedEvent(second.id))
        XCTAssertEqual(presentation(first.id).setupRoute, .liveEvent)
        XCTAssertTrue(presentation(first.id).isApplied)
        XCTAssertEqual(runs.currentRunID, run.id)
        XCTAssertEqual(library.library.appliedEventID, first.id)
        XCTAssertFalse(presentation(first.id, historyUnreadable: true).editsLiveEvent)
        XCTAssertEqual(presentation(first.id, historyUnreadable: true).application, "Current event status unavailable")
    }

    func testServerBindingsAreLibraryOwnedAndEnvironmentScoped() throws {
        var saved = try library.create(name: "Paid event", venue: "")
        saved.serverEvents = [binding: "test-event", "live:https://payments.example.test": "live-event"]
        try library.save(saved)
        var draft = saved; draft.serverEvents = [binding: "stale-event"]
        workspace.saveDesignDraft(draft, id: saved.id)
        var paid = ServerPolicyDraft(); paid.priceText = "50"; paid.cashEnabled = true
        workspace.saveServerDraft(.init(eventID: "test-event", serverBinding: binding, baseVersion: 3, name: saved.name, venue: "", policy: paid))
        workspace.saveServerDraft(.init(eventID: "live-event", serverBinding: "live:https://payments.example.test", baseVersion: 8, name: "Live draft", venue: "", policy: ServerPolicyDraft()))
        let model = presentation(saved.id)
        XCTAssertEqual(model.serverEventID, "test-event")
        XCTAssertEqual(model.design(for: .staged)?.serverEvents, saved.serverEvents)
        XCTAssertEqual(model.serverDraft?.baseVersion, 3)
        XCTAssertTrue(model.policyRows(for: .staged).contains { $0.0 == "Staged paid policy" && $0.1 == GuestPaymentChoice.qrAndCash.title })
        XCTAssertFalse(model.policyRows(for: .saved).contains { $0.0 == "Staged paid policy" })
        workspace.saveDesignDraft(nil, id: saved.id)
        XCTAssertEqual(presentation(saved.id).previewLabel(for: .staged), "Saved design preview", "Payment-only drafts do not invent a staged receipt")
        XCTAssertEqual(workspace.snapshot.serverDrafts.count, 2)
    }

    func testMissingArchivedRemovedAndUnreadableDesignsNeverUseDefaults() throws {
        var saved = try library.create(name: "Archive me", venue: "")
        try library.archiveDesign(id: saved.id)
        XCTAssertNotNil(presentation(saved.id).saved?.archivedAt)
        XCTAssertNil(presentation(saved.id).unavailable)
        XCTAssertEqual(presentation(saved.id).setupRoute, .savedEvent(saved.id), "Archived designs retain their existing editing pathway; setup owns start validation")
        saved = try XCTUnwrap(library.design(id: saved.id))
        saved.removedAt = Date()
        // Construct a persisted tombstone exactly as a relaunch would read it.
        var records = library.library; records.events = [saved]
        let removed = EventPreparationPresentation(designID: saved.id, library: records, libraryError: nil, workspace: workspace.snapshot,
            workspaceError: nil, binding: binding, operationalRun: nil, historyUnreadable: false)
        XCTAssertNotNil(removed.unavailable)
        XCTAssertNil(presentation("missing-id").saved)
        XCTAssertNotNil(presentation("missing-id").unavailable)
        XCTAssertEqual(presentation(saved.id, error: "File unreadable").unavailable, "File unreadable")
    }

    func testWriteFailureKeepsReadableDesignAvailableForEditingAndRetry() throws {
        var rejectsWrites = false
        let store = EventDesignLibraryStore(directory: root.appendingPathComponent("write-failure"), write: { data, url in
            if rejectsWrites { throw CocoaError(.fileWriteOutOfSpace) }
            try DurableFileWriter.write(data, to: url)
        }, legacyProfile: { .pocketPixelsDefault }, legacyName: { "" })
        let saved = try store.create(name: "Retry this save", venue: "")
        rejectsWrites = true
        var edited = saved; edited.venue = "Staged venue"
        XCTAssertThrowsError(try store.save(edited))
        XCTAssertNotNil(store.storageError)
        XCTAssertFalse(store.libraryUnreadable)
        let model = EventPreparationPresentation(designID: saved.id, library: store.library,
            libraryError: store.libraryUnreadable ? store.storageError : nil, workspace: workspace.snapshot,
            workspaceError: nil, binding: binding, operationalRun: nil, historyUnreadable: false)
        XCTAssertNil(model.unavailable)
        XCTAssertEqual(model.saved?.id, saved.id)
        XCTAssertEqual(model.setupRoute, .savedEvent(saved.id))
    }

    func testUnreadableLibraryAndDraftFilesRemainPreserved() throws {
        let corruptRoot = root.appendingPathComponent("corrupt")
        let recordFile = corruptRoot.appendingPathComponent("EventDesignLibraryV1/library.json")
        let draftFile = corruptRoot.appendingPathComponent("OperatorWorkspaceV1/setup.json")
        let bytes = Data("unreadable original".utf8)
        for file in [recordFile, draftFile] {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: file)
        }
        let unreadableLibrary = EventDesignLibraryStore(directory: corruptRoot, legacyProfile: { .pocketPixelsDefault }, legacyName: { "Never substitute this" })
        let unreadableWorkspace = OperatorWorkspace(directory: corruptRoot)
        let model = EventPreparationPresentation(designID: "original-id", library: unreadableLibrary.library,
            libraryError: unreadableLibrary.storageError, workspace: unreadableWorkspace.snapshot,
            workspaceError: unreadableWorkspace.persistenceError, binding: binding, operationalRun: nil, historyUnreadable: false)
        XCTAssertNotNil(model.unavailable); XCTAssertNotNil(model.draftReadError)
        XCTAssertNil(model.saved); XCTAssertNil(model.design(for: .staged))
        XCTAssertEqual(try Data(contentsOf: recordFile), bytes)
        XCTAssertEqual(try Data(contentsOf: draftFile), bytes)
    }

    func testToolBackAndRelaunchPreserveAllDraftsAndEventSelection() throws {
        let saved = try library.create(name: "Prepared", venue: "")
        var draft = saved; draft.name = "Draft preserved"
        workspace.saveDesignDraft(draft, id: saved.id)
        workspace.saveNewEvent(name: "Unrelated draft", venue: "Other venue")
        workspace.saveSessionSetup(.init(mode: .serverManaged, eventID: "other-paid", serverBinding: binding, eventModeEnabled: true, designID: "other-design", requestedMethods: .cashOnly))
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let before = try encoder.encode(workspace.snapshot)
        for _ in 0..<3 { _ = presentation(saved.id) }
        XCTAssertEqual(try encoder.encode(workspace.snapshot), before)
        workspace.navigate(to: .prepareEvent(saved.id))
        for route in [OperatorWorkspaceRoute.printer, .gallery, .waitingGalleries, .boothCheck] {
            workspace.path.append(route)
            workspace.path.removeLast()
            XCTAssertEqual(workspace.path, [.prepareEvent(saved.id)])
        }
        workspace.finish(keepingDrafts: true)
        let restored = OperatorWorkspace(directory: root)
        XCTAssertEqual(restored.path, [.prepareEvent(saved.id)])
        XCTAssertEqual(restored.designDraft(id: saved.id), draft)
        XCTAssertEqual(restored.snapshot.newEventName, "Unrelated draft")
        XCTAssertEqual(restored.snapshot.sessionSetup?.eventID, "other-paid")
        XCTAssertNil(presentation(saved.id).selection)
        XCTAssertNil(library.library.appliedEventID); XCTAssertNil(runs.currentRunID)
    }

    func testRenderingHubDoesNotWriteSetupOrActivateAdmission() async throws {
        let saved = try library.create(name: "The Keepsake Celebration", venue: "Synthetic garden")
        var draft = saved; draft.profile.customerTitle = "Keep this staged"
        workspace.saveDesignDraft(draft, id: saved.id)
        let acceptance = SessionAcceptanceStore(directory: root)
        try acceptance.save(.init(blocked: true, mode: .localPrepaid))
        let paymentSourceBefore = CommercialPolicySource.load()
        let bindingBefore = workspace.serverBinding
        let files = ["OperatorWorkspaceV1/setup.json", "EventDesignLibraryV1/library.json", "SessionAcceptanceV1/state.json"]
        let before = try files.map { try Data(contentsOf: root.appendingPathComponent($0)) }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let host = UIHostingController(rootView: NavigationStack {
            OperatorPrepareEventView(designID: saved.id, workspace: workspace, library: library, runs: runs)
        })
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 834, height: 1194)
        window.rootViewController = host; window.makeKeyAndVisible()
        try await Task.sleep(for: .milliseconds(500))
        host.view.layoutIfNeeded()
        window.isHidden = true; window.rootViewController = nil
        for (index, file) in files.enumerated() {
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(file)), before[index], file)
        }
        XCTAssertTrue(acceptance.state.blocked)
        XCTAssertNil(runs.currentRunID)
        XCTAssertNil(library.library.appliedEventID)
        XCTAssertEqual(CommercialPolicySource.load(), paymentSourceBefore)
        XCTAssertEqual(workspace.serverBinding, bindingBefore)
    }
}
