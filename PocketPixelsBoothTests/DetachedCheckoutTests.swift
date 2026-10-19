import XCTest
@testable import PocketPixelsBooth

@MainActor final class DetachedCheckoutTests: XCTestCase {
    private func checkpoint(_ id: String, phase: CheckoutPhase = .awaitingProvider) -> CheckoutCheckpoint {
        .init(id:id,environment:"test",deviceID:"device",accountID:"account",eventID:"original-event",policyRevisionID:"original-policy",
              unitPriceCentavos:5000,copies:1,format:"solo",method:"QRPH",orderID:"original-order",entitlementID:nil,offlineRecordID:nil,
              phase:phase,lastServerState:"UNKNOWN_RECONCILIATION",createdAt:Date(),updatedAt:Date(),resolution:nil,resolvedAt:nil)
    }
    private func snapshot(_ id: String, stage: AppRecoveryStage = .formatSelected) -> AppRecoverySnapshot {
        .init(schemaVersion:1,sessionIdentifier:id,createdAt:Date(),format:.solo,eventProfile:nil,galleryToken:String(repeating:"a",count:64),
              galleryURL:URL(string:"https://example.test/original-gallery"),photoJPEGData:[],receiptPreviewPNGData:nil,thermalPreviewPNGData:nil,
              rasterFingerprint:nil,stage:stage,updatedAt:Date(),galleryReceiptStyle:.asPrinted)
    }
    func testDurableHandoffReleasesKioskAndPreservesOriginalOwnership() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        var env=BoothSessionEnvironment.customer;env.recordsCustomerSessionMetrics=false;env.deliversGallery=false
        env.recoveryDirectory=root.appendingPathComponent("recovery");env.detachedCheckoutDirectory=root.appendingPathComponent("detached")
        let checkpoints=try CheckoutCheckpointStore(directory:root)
        let model=BoothSessionViewModel(environment:env,eventRunStore:nil,checkpointStore:checkpoints)
        model.configurePaidCheckoutForTesting(qrPhEnabled:true,cashEnabled:false)
        let original=try XCTUnwrap(model.sessionIdentifier)
        try checkpoints.begin(checkpoint(original))
        let recovery=try AppRecoveryStore(directoryURL:env.recoveryDirectory)
        try recovery.saveCritical(snapshot(original))
        model.beginPaymentReconciliationForTesting()
        XCTAssertTrue(model.canDetachUnresolvedCheckout)
        model.detachUnresolvedCheckout()
        let reference=try XCTUnwrap(model.detachedRecoveryReference)
        XCTAssertNotNil(UUID(uuidString:reference))
        XCTAssertNil(model.checkoutEntitlement)
        XCTAssertNil(model.paymentPollTaskForTesting)
        XCTAssertFalse(try XCTUnwrap(checkpoints.checkpoint(id:original)).isResolved,"Unknown payment was not declared failed")
        let record=try XCTUnwrap(DetachedCheckoutStore(directory:env.detachedCheckoutDirectory).load(sessionID:original))
        XCTAssertEqual(record.checkpoint.orderID,"original-order")
        XCTAssertEqual(record.snapshot.galleryReceiptStyle,.asPrinted)
        XCTAssertEqual(record.snapshot.galleryURL,snapshot(original).galleryURL)
        XCTAssertEqual(record.reference,reference)
        model.finishDetachedCheckout()
        XCTAssertEqual(model.state,.welcome)
        model.configurePaidCheckoutForTesting(qrPhEnabled:true,cashEnabled:false)
        XCTAssertNotEqual(model.sessionIdentifier,original)
        XCTAssertNil(model.checkoutEntitlement)
        XCTAssertEqual(try CheckoutCheckpointStore(directory:root).checkpoint(id:original)?.recoveryReference,reference)
    }
    func testCrashAfterHandoffCommitClearsOnlyMatchingPreCameraSnapshot() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let checkpoints=try CheckoutCheckpointStore(directory:root), recovery=try AppRecoveryStore(directoryURL:root.appendingPathComponent("recovery"))
        let store=DetachedCheckoutStore(directory:root.appendingPathComponent("detached"))
        var check=checkpoint("original");check.detachedAt=Date();check.recoveryReference="reference"
        try checkpoints.begin(check);try recovery.saveCritical(snapshot("original"))
        try store.save(.init(checkpoint:check,snapshot:snapshot("original"),reference:"reference",detachedAt:Date()))
        try DetachedCheckoutHandoff.recover(checkpoints:checkpoints,recovery:recovery,detached:store)
        XCTAssertNil(recovery.load())
        try recovery.saveCritical(snapshot("next-guest"))
        try DetachedCheckoutHandoff.recover(checkpoints:checkpoints,recovery:recovery,detached:store)
        XCTAssertEqual(recovery.load()?.sessionIdentifier,"next-guest")
    }
    func testCaptureAndPrintingCannotBeDetachedAndWriteFailureDoesNotLoseOriginal() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        var store=DetachedCheckoutStore(directory:root)
        for phase in [CheckoutPhase.entitled,.claimed,.printing,.completed] {
            XCTAssertThrowsError(try store.save(.init(checkpoint:checkpoint("original",phase:phase),snapshot:snapshot("original"),reference:"reference",detachedAt:Date())))
        }
        store.writer={_,_ in throw CocoaError(.fileWriteOutOfSpace)}
        XCTAssertThrowsError(try store.save(.init(checkpoint:checkpoint("original"),snapshot:snapshot("original"),reference:"reference",detachedAt:Date())))
        XCTAssertNil(try store.load(sessionID:"original"))
    }
    func testDeletionRequiresUnusedLocalRunAndCompleteReadableEvidence() throws {
        let booth=Booth();defer {booth.cleanup()}
        let historical=try booth.runs.createHistoricalRun(name:"Empty",designID:nil,startedAt:Date(),endedAt:Date())
        XCTAssertNotNil(booth.runs.unusedRunDeletionReason(id:historical.id,archives:[],inspectionComplete:false))
        XCTAssertThrowsError(try booth.runs.deleteUnusedRun(id:historical.id,archives:[],inspectionComplete:false))
        try booth.runs.deleteUnusedRun(id:historical.id,archives:[],inspectionComplete:true)
        try booth.runs.deleteUnusedRun(id:historical.id,archives:[],inspectionComplete:true)
        XCTAssertTrue(booth.runs.runs.isEmpty)
        let used=try booth.runs.createHistoricalRun(name:"Used",designID:nil,startedAt:Date(),endedAt:Date())
        try booth.runs.beginSession(id:"guest",runID:used.id,format:"solo")
        XCTAssertThrowsError(try booth.runs.deleteUnusedRun(id:used.id,archives:[],inspectionComplete:true))
        XCTAssertEqual(booth.runs.runs.count,1)
    }
}
