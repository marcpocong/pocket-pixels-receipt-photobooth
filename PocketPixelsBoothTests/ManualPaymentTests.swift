import XCTest
@testable import PocketPixelsBooth

@MainActor final class ManualPaymentTests: XCTestCase {
    private func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("manual-payment-tests-\(UUID())") }
    private func receiver(_ store: ManualPaymentStore) throws {
        let permit = OperatorAccessPermit.shared, wasAuthorized = permit.isAuthorized
        permit.authorize(); defer { if !wasAuthorized { permit.revoke() } }
        var receiver = ManualReceivingAccount();receiver.provider="Synthetic";receiver.recipient="Example recipient";receiver.identifier="TEST-ONLY"
        receiver.enabled=true;receiver.permittedUseConfirmed=true;try store.saveReceiver(receiver)
    }
    private func begin(_ store: ManualPaymentStore, mode: ManualPaymentMode = .digital, policy: PaymentReceiptPolicy = .optional,
                       session: String = UUID().uuidString, event: String = "", copies: Int = 3) throws -> ManualCheckoutRecord {
        var p = ManualPaymentPolicy();p.mode=mode;p.receiptPolicy=policy
        return try store.begin(sessionID: session,eventID:event,eventName:event.isEmpty ? "Regular Booth":"Synthetic event",runID:nil,format:"solo",copies:copies,policy:p,method:mode == .cash ? "CASH":"MANUAL_DIGITAL",profile:nil)
    }
    func testAllReceiptPoliciesAuthorizeExactlyOnceAndRequiredWaitsForPrivateProof() throws {
        for policy in PaymentReceiptPolicy.allCases {
            let root=root();defer { try? FileManager.default.removeItem(at:root) }
            let store=ManualPaymentStore(directory:root);try receiver(store)
            let record=try begin(store,policy:policy);try store.acknowledge(record.id)
            if policy == .required {
                XCTAssertThrowsError(try store.authorize(record.id))
                let server=UUID().uuidString.lowercased()
                try store.applyRemote(.init(id:server,localCheckoutId:record.id,sessionId:record.sessionID,snapshotHash:record.snapshotHash,copies:3,totalCentavos:7500,acknowledgedAt:Date(),receipt:.init(checkoutId:server,snapshotHash:record.snapshotHash,receiptId:UUID().uuidString,storedAt:Date()),checkoutURL:nil),to:record.id)
            }
            let entitlement=try store.authorize(record.id), replay=try store.authorize(record.id)
            XCTAssertEqual(entitlement,replay);XCTAssertEqual(entitlement.purchasedCopies,3)
            XCTAssertEqual(entitlement.authorizationSource,.manualDigitalAcknowledged)
            XCTAssertFalse(entitlement.requiresServerClaim)
            XCTAssertFalse(entitlement.permitsPrint(copyIndex:4,receiptFingerprint:"unchanged"))
            let restarted=ManualPaymentStore(directory:root);XCTAssertEqual(restarted.record(record.id)?.entitlement,entitlement)
        }
    }
    func testUnchangedCheckoutStatusDoesNotRewriteTheDurableJournal() throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        var writes = 0
        let store = ManualPaymentStore(directory: directory) { data, url in
            writes += 1
            try DurableFileWriter.write(data, to: url)
        }
        try receiver(store)
        let record = try begin(store)
        let status = ManualCheckoutStatus(id: UUID().uuidString, localCheckoutId: record.id,
            sessionId: record.sessionID, snapshotHash: record.snapshotHash, copies: record.copies,
            totalCentavos: record.totalCentavos, acknowledgedAt: nil, receipt: nil, checkoutURL: nil)
        try store.setBinding(record.id, "test:fixture")
        try store.applyRemote(status, to: record.id)
        let afterFirstStatus = writes
        try store.setBinding(record.id, "test:fixture")
        try store.applyRemote(status, to: record.id)
        XCTAssertEqual(writes, afterFirstStatus)
        XCTAssertEqual(store.record(record.id)?.serverID, status.id)
    }

    func testReceiverModePriceQuantityAndSessionAreFrozenAcrossConfigurationChanges() throws {
        let root=root();defer { try? FileManager.default.removeItem(at:root) };let store=ManualPaymentStore(directory:root);try receiver(store)
        let record=try begin(store,session:"original",event:"stable-event");let oldReceiver=record.receiver
        try receiver(store);XCTAssertNotEqual(store.receiver?.id,oldReceiver?.id)
        XCTAssertEqual(store.record(record.id)?.receiver,oldReceiver)
        XCTAssertThrowsError(try begin(store,session:"original",event:"stable-event",copies:4))
        XCTAssertThrowsError(try store.applyRemote(.init(id:UUID().uuidString,localCheckoutId:record.id,sessionId:"another-guest",snapshotHash:record.snapshotHash,copies:3,totalCentavos:7500,acknowledgedAt:Date(),receipt:nil,checkoutURL:nil),to:record.id))
        XCTAssertNil(store.record(record.id)?.acknowledgedAt)
    }
    func testOfflineCashNeedsNoReceiverNetworkOrOperatorAuthenticationAndSurvivesRestart() throws {
        let root=root();defer { try? FileManager.default.removeItem(at:root) };let store=ManualPaymentStore(directory:root)
        let permit=OperatorAccessPermit.shared,wasAuthorized=permit.isAuthorized;permit.revoke();defer { if wasAuthorized { permit.authorize() } }
        let record=try begin(store,mode:.cash);try store.acknowledge(record.id)
        let entitlement=try store.authorize(record.id)
        XCTAssertEqual(entitlement.authorizationSource,.manualCashAcknowledged)
        XCTAssertFalse(permit.isAuthorized)
        XCTAssertEqual(ManualPaymentStore(directory:root).record(record.id)?.entitlement,entitlement)
    }
    func testClosedLateMobileEvidenceNeverAuthorizesAnotherGuestOrClosedOriginal() throws {
        let root=root();defer { try? FileManager.default.removeItem(at:root) };let store=ManualPaymentStore(directory:root);try receiver(store)
        let old=try begin(store);try store.close(old.id)
        let next=try begin(store,session:"next-guest",event:"different-event")
        try store.applyRemote(.init(id:UUID().uuidString,localCheckoutId:old.id,sessionId:old.sessionID,snapshotHash:old.snapshotHash,copies:3,totalCentavos:7500,acknowledgedAt:Date(),receipt:nil,checkoutURL:nil),to:old.id)
        XCTAssertThrowsError(try store.authorize(old.id));XCTAssertNil(store.record(next.id)?.acknowledgedAt);XCTAssertNil(store.record(next.id)?.entitlement)
        XCTAssertNotNil(ManualPaymentStore(directory:root).record(old.id)?.closedAt)
    }
    func testFailedAuthorizationWriteDoesNotCreatePhantomPermissionAndCorruptOriginalIsRetained() throws {
        let root=root();defer { try? FileManager.default.removeItem(at:root) }
        final class Disk { var fails=false }
        let disk=Disk();let store=ManualPaymentStore(directory:root,writer:{ data,url in if disk.fails { throw SetupFailure("Synthetic disk full") };try DurableFileWriter.write(data,to:url) })
        let record=try begin(store,mode:.cash);try store.acknowledge(record.id);disk.fails=true
        XCTAssertThrowsError(try store.authorize(record.id));XCTAssertNil(store.record(record.id)?.entitlement)
        XCTAssertNil(ManualPaymentStore(directory:root).record(record.id)?.entitlement)
        let file=root.appendingPathComponent("ManualPaymentsV1/records.json");let corrupt=Data("{invalid".utf8);try corrupt.write(to:file)
        let damaged=ManualPaymentStore(directory:root);XCTAssertNotNil(damaged.storageError);XCTAssertThrowsError(try begin(damaged,mode:.cash))
        XCTAssertEqual(try Data(contentsOf:file),corrupt)
    }
    func testManualUncertainCopyAcknowledgmentRelaunchAndNextGuestEventKeepsDuplicateProtection() throws {
        let root=root();defer { try? FileManager.default.removeItem(at:root) }
        let store=ManualPaymentStore(directory:root);let old=try begin(store,mode:.cash);try store.acknowledge(old.id);_ = try store.authorize(old.id)
        let outbox=try PrintOutcomeOutbox(directory:root.appendingPathComponent("outbox"))
        try outbox.beginCopy(batchID:"original-batch",sessionID:old.sessionID,entitlementID:nil,receiptFingerprint:"original",copyIndex:1,copyCount:3,transport:"tcp")
        XCTAssertTrue(outbox.finishCopy(batchID:"original-batch",copyIndex:1,state:.uncertain))
        try outbox.acknowledgeInspection(entryIDs:outbox.inspectionEntryIDs);try store.close(old.id)
        let relaunched=ManualPaymentStore(directory:root),journal=try PrintOutcomeOutbox(directory:root.appendingPathComponent("outbox"))
        let checkpoints=try CheckoutCheckpointStore(directory:root.appendingPathComponent("checkpoints"))
        XCTAssertNil(SessionSetupSafety.recoveryReason(needsReceiptCheck:false,hasPendingSession:false,checkpoints:checkpoints,outbox:journal))
        let regular=try begin(relaunched,mode:.cash,session:"regular-next"),event=try begin(relaunched,mode:.cash,session:"event-next",event:"event-two")
        for r in [regular,event] { try relaunched.acknowledge(r.id);XCTAssertNotNil(try relaunched.authorize(r.id)) }
        XCTAssertEqual(journal.copiesThatMayHavePrinted(sessionID:old.sessionID).first?.localState,.uncertain)
        XCTAssertThrowsError(try journal.beginCopy(batchID:"original-batch",sessionID:old.sessionID,entitlementID:nil,receiptFingerprint:"original",copyIndex:1,copyCount:3,transport:"tcp"))
        XCTAssertEqual(relaunched.record(old.id)?.entitlement?.purchasedCopies,3)
    }
    func testExistingPayloadsDecodeAndFinancialViewsDoNotDoubleCount() throws {
        let legacy=PaymentPolicySnapshot.legacyPrepaid
        let encoded=try PaymentsJSON.encoder().encode(legacy)
        XCTAssertNil(try PaymentsJSON.decoder().decode(PaymentPolicySnapshot.self,from:encoded).manualPayment)
        let root=root();defer { try? FileManager.default.removeItem(at:root) };let store=ManualPaymentStore(directory:root)
        let record=try begin(store,mode:.cash);try store.acknowledge(record.id)
        let was=OperatorAccessPermit.shared.isAuthorized;OperatorAccessPermit.shared.authorize();defer { if !was { OperatorAccessPermit.shared.revoke() } }
        try store.review(record.id,outcome:.fundsConfirmed,confirmedCentavos:7000,note:"Synthetic independent cash count")
        XCTAssertEqual(store.totals.acknowledged,7500);XCTAssertEqual(store.totals.verified,7000)
        let csv=try ManualPaymentCSV.export(store.records);defer { try? FileManager.default.removeItem(at:csv) }
        let text=try String(contentsOf:csv,encoding:.utf8);XCTAssertTrue(text.contains("7500"));XCTAssertTrue(text.contains("7000"));XCTAssertFalse(text.contains("14500"))
    }
    func testFourModesAndCopyAuthorizationThroughRealGuestFlow() throws {
        for regular in [true,false] {
            for mode in ManualPaymentMode.allCases {
                let root=root();defer { try? FileManager.default.removeItem(at:root) };let store=ManualPaymentStore(directory:root);try receiver(store)
                var environment=BoothSessionEnvironment.customer;environment.archiveDirectory=root.appendingPathComponent("archive");environment.recoveryDirectory=root.appendingPathComponent("recovery");environment.detachedCheckoutDirectory=root.appendingPathComponent("detached");environment.deliversGallery=false;environment.recordsCustomerSessionMetrics=false
                let model=BoothSessionViewModel(environment:environment,eventRunStore:nil,checkpointStore:nil,manualPaymentStore:store)
                var policy=ManualPaymentPolicy();policy.mode=mode;model.configureManualCheckoutForTesting(policy,regular:regular);model.selectBoothFormat(.solo)
                if mode == .none { XCTAssertEqual(model.checkoutEntitlement?.authorizationSource,.privatePrepaid);continue }
                model.adjustCheckoutCopies(by:2);model.confirmCopySelection()
                if mode == .cashAndDigital { model.chooseCash() }
                if mode.acceptsCash { model.declareCashPaidByGuest() } else { model.acknowledgeManualPayment() }
                XCTAssertEqual(model.checkoutEntitlement?.purchasedCopies,3)
                XCTAssertEqual(model.checkoutEntitlement?.authorizationSource,mode.acceptsCash ? .manualCashAcknowledged:.manualDigitalAcknowledged)
                XCTAssertFalse(model.canIncreasePrintCopies)
                XCTAssertEqual(store.records.count,1)
            }
        }
    }
    func testExpiredLocalClaimNeedsExplicitOriginalRecoveryAndPrintIntentPermanentlyPreventsFreshCopies() throws {
        let root=root();defer{try? FileManager.default.removeItem(at:root)};let store=ManualPaymentStore(directory:root)
        var policy=ManualPaymentPolicy();policy.mode = .cash
        let original=try store.begin(sessionID:"expired-original",eventID:"",eventName:"Regular Booth",runID:nil,format:"solo",copies:2,policy:policy,method:"CASH",profile:nil,now:Date().addingTimeInterval(-1801))
        XCTAssertThrowsError(try store.acknowledge(original.id));XCTAssertNil(store.record(original.id)?.acknowledgedAt)
        let permit=OperatorAccessPermit.shared,was=permit.isAuthorized;permit.authorize();defer{if !was{permit.revoke()}}
        try store.acceptOriginalClaimForRecovery(original.id,note:"Synthetic original guest recovery")
        XCTAssertNotNil(store.record(original.id)?.entitlement)
        try store.recordPrintIntent(sessionID:original.sessionID)
        let restarted=ManualPaymentStore(directory:root)
        XCTAssertNotNil(restarted.record(original.id)?.printingBeganAt)
        XCTAssertThrowsError(try restarted.reopenForRecovery(original.id),"Even a pruned report journal cannot make used authority fresh")
    }
    func testLegacyQRNeedsExplicitReplacementWhileCashFreeAndOldEntitlementsKeepTheirMeanings() async throws {
        let booth=Booth();defer{booth.cleanup()};let setup=booth.setup()
        await setup.choosePayment(.qrOnly);await setup.createEvent(name:"Legacy migration",venue:"");setup.policy.priceText="50"
        XCTAssertTrue(setup.validation?.contains("retired")==true)
        let refused=await setup.startAccepting();XCTAssertFalse(refused);XCTAssertEqual(booth.server.mutations("activate"),0)
        await setup.choosePayment(.cashOnly);XCTAssertFalse(setup.policy.qrPhEnabled);XCTAssertTrue(setup.policy.cashEnabled)
        let started=await setup.startAccepting();XCTAssertTrue(started,setup.message)
        let historic=CheckoutEntitlement(id:"old-provider",orderID:"old-order",eventID:"legacy-event",policyRevisionID:"legacy-revision",sessionID:"original",selectedFormatRawValue:"solo",purchasedCopies:2,unitPriceCentavos:2500,totalCentavos:5000,authorizationSource:.verifiedQRPh,authorizedAt:Date(),receiptFingerprint:nil)
        let decoded=try PaymentsJSON.decoder().decode(CheckoutEntitlement.self,from:PaymentsJSON.encoder().encode(historic));XCTAssertEqual(decoded.authorizationSource,.verifiedQRPh);XCTAssertEqual(decoded.purchasedCopies,2)
    }

}
