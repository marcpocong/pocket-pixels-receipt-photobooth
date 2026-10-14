import XCTest
import SwiftUI
import UIKit
@testable import PocketPixelsBooth

@MainActor final class SavedDraftsTests: XCTestCase {
    private func fixture() throws -> (URL, OperatorWorkspace, EventDesignLibraryStore, SavedEventDesign) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("saved-drafts-\(UUID())")
        let workspace = OperatorWorkspace(directory: root)
        let library = EventDesignLibraryStore(directory: root, legacyProfile: { .pocketPixelsDefault }, legacyName: { "" })
        let design = SavedEventDesign.new(name: "Release Sample", venue: "")
        try library.save(design)
        return (root, workspace, library, design)
    }
    func testRealSampleIsDiscoverableWithOnlyChangedFieldsAndMetadataDoesNotCount() throws {
        let (root, workspace, library, saved) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var draft = saved
        draft.updatedAt = .distantFuture; draft.createdAt = .distantPast; draft.serverEvents["test:other"] = "remote"
        draft.name += " "
        workspace.saveDesignDraft(draft, id: saved.id)
        XCTAssertTrue(SavedDraftCatalog.entries(workspace: workspace, library: library.library).isEmpty)
        draft.profile.receiptHeader.scale = 0.75
        workspace.saveDesignDraft(draft, id: saved.id)
        let entry = try XCTUnwrap(SavedDraftCatalog.entries(workspace: workspace, library: library.library).first)
        XCTAssertEqual(entry.id, .design(saved.id)); XCTAssertEqual(entry.eventName, "Release Sample")
        XCTAssertEqual(entry.changes.count, 1); XCTAssertEqual(entry.changes[0].label, "Logo size")
        XCTAssertEqual(entry.changes[0].after, "75%")
        let restored = OperatorWorkspace(directory: root)
        XCTAssertEqual(restored.designDraft(id: saved.id), draft)
    }
    func testReturningToNormalizedSavedValuesRemovesTheAutosavedDraft() throws {
        let (root, workspace, library, saved) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let setup = SessionSetupCoordinator(draftTarget: .design(saved.id), workspace: workspace, library: library, authorized: { true })
        setup.design?.profile.receiptHeader.scale = 0.75
        XCTAssertNotNil(workspace.designDraft(id: saved.id))
        setup.design?.profile.receiptHeader.scale = saved.profile.receiptHeader.scale
        setup.design?.name = "Release Sample  "
        XCTAssertNil(workspace.designDraft(id: saved.id))
        XCTAssertFalse(setup.designDirty)
    }

    func testImplicitAndExplicitEquivalentHeaderDefaultsDoNotCreateADraft() throws {
        let (root, _, _, saved) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var draft = saved
        draft.profile.receiptHeader.horizontalPosition = saved.profile.receiptHeader.effectiveHorizontalPosition
        draft.profile.receiptHeader.fillHeightRatio = saved.profile.receiptHeader.effectiveFillHeightRatio
        draft.profile.receiptHeader.showsStudioCredit = false
        XCTAssertTrue(SavedDraftDiff.design(draft, saved).isEmpty)
    }

    func testLogoReplacementIsExplainedWithoutExposingAssetIdentifiers() throws {
        let (root, _, _, saved) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var before = saved, after = saved
        before.profile.receiptHeader.assetIdentifier = "old-image"
        after.profile.receiptHeader.assetIdentifier = "new-image"
        let change = try XCTUnwrap(SavedDraftDiff.design(after, before).first)
        XCTAssertEqual(change.label, "Logo artwork")
        XCTAssertEqual(change.before, "Saved artwork")
        XCTAssertEqual(change.after, "Different artwork selected")
    }
    func testIndividualDiscardPreservesOtherDraftsSavedDesignAndAppliedState() throws {
        let (root, workspace, library, saved) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var draft = saved; draft.profile.receiptHeader.scale = 0.75
        workspace.saveDesignDraft(draft, id: saved.id)
        workspace.saveNewEvent(name: "Another event", venue: "Garden")
        let before = library.library
        try workspace.discardDraft(.design(saved.id), authorized: { true })
        XCTAssertNil(workspace.designDraft(id: saved.id)); XCTAssertEqual(workspace.snapshot.newEventName, "Another event")
        XCTAssertEqual(library.library, before)
        let restored = OperatorWorkspace(directory: root)
        XCTAssertNil(restored.designDraft(id: saved.id)); XCTAssertEqual(restored.snapshot.newEventName, "Another event")
    }
    func testUnauthorizedAndFailedDiscardKeepTheDraft() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("discard-failure-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        var fail = false
        let workspace = OperatorWorkspace(directory: root, write: { data, url in
            if fail { throw CocoaError(.fileWriteOutOfSpace) }
            try DurableFileWriter.write(data, to: url)
        })
        workspace.saveNewEvent(name: "Keep me", venue: "")
        XCTAssertThrowsError(try workspace.discardDraft(.newEvent, authorized: { false }))
        fail = true
        XCTAssertThrowsError(try workspace.discardDraft(.newEvent, authorized: { true }))
        XCTAssertEqual(workspace.snapshot.newEventName, "Keep me")
        XCTAssertEqual(OperatorWorkspace(directory: root).snapshot.newEventName, "Keep me")
    }
    func testPaymentDiffUsesBaselineIgnoresEquivalentPesoTextAndDisabledOfflineDate() throws {
        var policy = ServerPolicyDraft(); policy.priceText = "25.00"
        let baseline = PaymentDraftBaseline(name: "Event", venue: "", policy: policy)
        policy.priceText = "25"; policy.offlineValidUntil = .distantFuture
        var draft = OperatorServerSetupDraft(eventID: "event", serverBinding: "live:fixture", baseVersion: 2, name: "Event", venue: "", policy: policy, baseline: baseline)
        XCTAssertTrue(SavedDraftDiff.payment(draft, baseline).isEmpty)
        draft.policy.priceText = "30"
        let change = try XCTUnwrap(SavedDraftDiff.payment(draft, baseline).first)
        XCTAssertEqual(change.label, "Price per copy"); XCTAssertEqual(change.before, "₱25.00"); XCTAssertEqual(change.after, "₱30.00")
        let decoded = try JSONDecoder().decode(OperatorServerSetupDraft.self, from: JSONEncoder().encode(draft))
        XCTAssertEqual(decoded.baseline, baseline)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(draft)) as? [String: Any]); legacy.removeValue(forKey: "baseline")
        XCTAssertNil(try JSONDecoder().decode(OperatorServerSetupDraft.self, from: JSONSerialization.data(withJSONObject: legacy)).baseline)
    }
    func testUnknownBaselineAndOtherConnectionStayVisibleAndCannotBePruned() throws {
        let (root, workspace, library, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var policy = ServerPolicyDraft(); policy.priceText = "1.00"
        workspace.saveServerDraft(.init(eventID: "pilot", serverBinding: "other-server", baseVersion: 1, name: "Other pilot", venue: "", policy: policy))
        let entry = try XCTUnwrap(SavedDraftCatalog.entries(workspace: workspace, library: library.library).first)
        XCTAssertEqual(entry.id, .payment(binding: "other-server", eventID: "pilot"))
        XCTAssertTrue(entry.notice?.contains("different payments connection") == true)
        XCTAssertTrue(entry.changes.allSatisfy { $0.before == nil })
        XCTAssertTrue(workspace.storedDraftIDs.contains(entry.id))
    }
    func testEquivalentDraftPruningKeepsGenuineDesignEdits() throws {
        let (root, workspace, library, saved) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var draft = saved; draft.profile.receiptHeader.scale = 0.75
        workspace.saveDesignDraft(draft, id: saved.id)
        workspace.saveBrandingDraft(EventProfileStore.load())
        let wasAuthorized = OperatorAccessPermit.shared.isAuthorized
        OperatorAccessPermit.shared.authorize()
        defer { if !wasAuthorized { OperatorAccessPermit.shared.revoke() } }
        try SavedDraftCatalog.removeEquivalentDrafts(workspace: workspace, library: library.library)
        XCTAssertNil(workspace.snapshot.brandingDraft)
        XCTAssertNotNil(workspace.designDraft(id: saved.id))
    }

    func testEquivalentLookingSelectionForAnotherPaymentConnectionIsRetained() throws {
        let (root, workspace, library, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        workspace.saveSessionSetup(.init(mode: .serverManaged, eventID: nil, serverBinding: "another-server", eventModeEnabled: false))
        let entries = SavedDraftCatalog.entries(workspace: workspace, library: library.library,
                                               acceptance: .init(), source: .serverManaged)
        let entry = try XCTUnwrap(entries.first { $0.id == .sessionSelection })
        XCTAssertTrue(entry.notice?.contains("different payments connection") == true)
    }

    func testTypedReviewRoutesSurviveRestart() throws {
        let routes: [OperatorWorkspaceRoute] = [.savedDrafts, .draftReview(.design("sample")), .draftReview(.payment(binding: "live:server", eventID: "pilot")), .draftReview(.newEvent)]
        XCTAssertEqual(try JSONDecoder().decode([OperatorWorkspaceRoute].self, from: JSONEncoder().encode(routes)), routes)
    }
    func testTargetedDesignReviewDoesNotChangeAnotherDraftOrSessionSelectionAndSaveDoesNotApply() throws {
        let (root, workspace, library, saved) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var draft = saved; draft.profile.receiptHeader.scale = 0.75
        draft.serverEvents["binding"] = "old-event"
        draft.createdAt = .distantPast
        workspace.saveDesignDraft(draft, id: saved.id)
        try library.link(designID: saved.id, binding: "binding", serverEventID: "current-event")
        let selection = OperatorSessionSetupDraft(mode: .serverManaged, eventID: "paid", serverBinding: workspace.serverBinding, eventModeEnabled: false)
        workspace.saveSessionSetup(selection)
        let before = library.library
        let setup = SessionSetupCoordinator(draftTarget: .design(saved.id), workspace: workspace, library: library, authorized: { true })
        XCTAssertEqual(setup.design?.id, saved.id); XCTAssertEqual(setup.design?.profile.receiptHeader.scale, 0.75)
        setup.design?.profile.receiptHeader.scale = 0.80
        XCTAssertEqual(workspace.snapshot.sessionSetup, selection)
        setup.saveDesign()
        XCTAssertNil(workspace.designDraft(id: saved.id))
        XCTAssertEqual(library.design(id: saved.id)?.profile.receiptHeader.scale, 0.80)
        XCTAssertEqual(library.design(id: saved.id)?.serverEvents["binding"], "current-event")
        XCTAssertEqual(library.design(id: saved.id)?.createdAt, saved.createdAt)
        XCTAssertEqual(library.library.appliedEventID, before.appliedEventID)
        XCTAssertEqual(library.library.appliedEventModeEnabled, before.appliedEventModeEnabled)
        XCTAssertEqual(workspace.snapshot.sessionSetup, selection)
    }
    func testRenderDraftListAndSampleReviewInBothOrientations() async throws {
        let (root, workspace, library, saved) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var draft = saved; draft.personalizeReceipt = true; draft.profile.receiptHeader.scale = 0.75; draft.profile.receiptHeader.topSpacing = 12
        workspace.saveDesignDraft(draft, id: saved.id)
        workspace.saveNewEvent(name: "October event", venue: "Cebu")
        let empty = OperatorWorkspace(directory: root.appendingPathComponent("empty"))
        try await render("draft_list_empty", NavigationStack { SavedDraftsView(workspace: empty, library: library, loadsRemote: false) }, width: 834, height: 1194)
        for (name, width, height) in [("portrait", CGFloat(834), CGFloat(1194)), ("landscape", CGFloat(1194), CGFloat(834))] {
            try await render("draft_list_\(name)", NavigationStack { SavedDraftsView(workspace: workspace, library: library, loadsRemote: false) }, width: width, height: height)
            try await render("draft_review_\(name)", NavigationStack { SavedDraftReviewView(draftID: .design(saved.id), workspace: workspace, library: library, loadsRemote: false) }, width: width, height: height)
        }
    }
    private func render<V: View>(_ name: String, _ view: V, width: CGFloat, height: CGFloat) async throws {
        let host = UIHostingController(rootView: view)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene); window.frame = CGRect(x: 0, y: 0, width: width, height: height)
        window.overrideUserInterfaceStyle = .light; window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        try await Task.sleep(for: .milliseconds(3000))
        host.view.frame = window.bounds; host.view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(size: window.bounds.size).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        let attachment = XCTAttachment(data: try XCTUnwrap(image.pngData()), uniformTypeIdentifier: "public.png")
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
