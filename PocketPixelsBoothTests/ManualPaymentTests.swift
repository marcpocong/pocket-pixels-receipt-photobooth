import XCTest
import SwiftUI
import CoreImage
@testable import PocketPixelsBooth

@MainActor final class ManualPaymentTests: XCTestCase {
    private func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("manual-payment-tests-\(UUID())") }
    private func receiver(_ store: ManualPaymentStore, withQR: Bool = false) throws {
        let permit = OperatorAccessPermit.shared, wasAuthorized = permit.isAuthorized
        permit.authorize(); defer { if !wasAuthorized { permit.revoke() } }
        var receiver = ManualReceivingAccount();receiver.provider="Synthetic";receiver.recipient="Example recipient";receiver.identifier="TEST-ONLY"
        if withQR {
            let source = try GalleryQRCodeGenerator.makeQRCodeImage(for: Self.syntheticPaymentURL)
            receiver.qrJPEG = source.jpegData(compressionQuality: 0.88)
        }
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
            if policy == .optional {
                XCTAssertThrowsError(try store.authorize(record.id))
                XCTAssertEqual(ManualPaymentStore(directory: root).record(record.id)?.optionalReceiptChoice, .pending)
                try store.chooseOptionalReceipt(.skipped, for: record.id)
            }
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
                var policy=ManualPaymentPolicy();policy.mode=mode;policy.receiptPolicy = .acknowledgmentOnly;model.configureManualCheckoutForTesting(policy,regular:regular);model.selectBoothFormat(.solo)
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
    private static let syntheticPaymentURL = URL(string: "https://payment.example.test/synthetic-receiver")!

    private func model(in directory: URL, store: ManualPaymentStore, client: PaymentsAPIClient? = nil) -> BoothSessionViewModel {
        var environment = BoothSessionEnvironment.customer
        environment.recoveryDirectory = directory.appendingPathComponent("recovery")
        environment.archiveDirectory = directory.appendingPathComponent("archive")
        environment.detachedCheckoutDirectory = directory.appendingPathComponent("detached")
        environment.eventProfileSource = { .pocketPixelsDefault }
        environment.deliversGallery = false
        environment.recordsCustomerSessionMetrics = false
        return BoothSessionViewModel(environment: environment, paymentsClient: client, eventRunStore: nil,
                                     checkpointStore: nil, manualPaymentStore: store)
    }

    private func chooseDigital(_ model: BoothSessionViewModel, policy: PaymentReceiptPolicy, mode: ManualPaymentMode = .digital) {
        model.configureManualCheckoutForTesting(.init(mode: mode, unitPriceCentavos: 2500, receiptPolicy: policy))
        model.selectBoothFormat(.solo)
        model.adjustCheckoutCopies(by: 2)
        model.confirmCopySelection()
        if mode == .cashAndDigital { model.chooseQRPh() }
    }

    private func waitFor(_ condition: @MainActor () -> Bool) async throws {
        let timeout = ContinuousClock.now.advanced(by: .seconds(10))
        while !condition() && ContinuousClock.now < timeout { try await Task.sleep(for: .milliseconds(35)) }
        XCTAssertTrue(condition(), "Checkout did not reach the expected state")
    }

    func testAcknowledgmentOnlyOpensCameraOfflineAndOptionalStartsReceiptWithoutEntitlement() async throws {
        for policy in [PaymentReceiptPolicy.acknowledgmentOnly, .optional] {
            let directory = root()
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = ManualPaymentStore(directory: directory)
            try receiver(store)
            let model = model(in: directory, store: store)
            chooseDigital(model, policy: policy)
            let original = try XCTUnwrap(model.manualCheckout)
            XCTAssertEqual(model.manualCheckoutStep, .pay)
            model.acknowledgeManualPayment()
            model.acknowledgeManualPayment()
            XCTAssertNotNil(store.record(original.id)?.acknowledgedAt)
            if policy == .optional {
                XCTAssertEqual(model.manualCheckoutStep, .receipt)
                XCTAssertNil(model.checkoutEntitlement)
                try await waitFor { model.paymentNotice?.contains("temporarily unavailable") == true }
                model.skipOptionalManualReceipt()
                XCTAssertEqual(store.record(original.id)?.optionalReceiptChoice, .skipped)
            }
            XCTAssertEqual(model.checkoutEntitlement?.sessionID, original.sessionID)
            XCTAssertEqual(model.checkoutEntitlement?.purchasedCopies, 3)
            if case .error(let reason) = model.state {
                XCTAssertEqual(reason, CameraServiceError.permissionDenied.localizedDescription)
            } else {
                XCTAssertTrue([.preparingCamera, .cameraReady].contains(model.state))
            }
            XCTAssertEqual(store.records.count, 1)
        }
    }

    func testRequiredNeverShowsPaymentBeforeOriginalReadinessAndReceiptPollOpensOriginalCamera() async throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ManualPaymentStore(directory: directory)
        try receiver(store)
        let service = ManualCheckoutFixtureService()
        let model = model(in: directory, store: store, client: service.client())
        chooseDigital(model, policy: .required)
        XCTAssertEqual(model.manualCheckoutStep, .preparing)
        model.acknowledgeManualPayment()
        XCTAssertNil(model.manualCheckout?.acknowledgedAt)
        try await waitFor { model.canSwitchManualCheckoutToCash || model.paymentNotice != nil }
        let original = try XCTUnwrap(model.manualCheckout)
        XCTAssertNotNil(original.serverID)
        XCTAssertEqual(model.manualCheckoutStep, .preparing)
        XCTAssertNil(model.checkoutEntitlement)
        service.setReady()
        await model.refreshManualPayment()
        XCTAssertEqual(model.manualCheckoutStep, .pay)
        XCTAssertEqual(model.manualCheckout?.id, original.id)
        model.acknowledgeManualPayment()
        model.skipOptionalManualReceipt()
        XCTAssertEqual(model.manualCheckoutStep, .receipt)
        XCTAssertNil(model.checkoutEntitlement)
        service.setStored()
        try await waitFor { model.checkoutEntitlement != nil }
        XCTAssertEqual(model.checkoutEntitlement?.sessionID, original.sessionID)
        XCTAssertEqual(model.checkoutEntitlement?.purchasedCopies, original.copies)
        XCTAssertNotNil(store.record(original.id)?.receipt)
    }

    func testRequiredPreflightCashAlternativeKeepsFrozenQuoteAndClosesUnshownDigitalCheckout() async throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ManualPaymentStore(directory: directory)
        try receiver(store)
        let model = model(in: directory, store: store)
        chooseDigital(model, policy: .required, mode: .cashAndDigital)
        try await waitFor { model.canSwitchManualCheckoutToCash }
        let original = try XCTUnwrap(model.manualCheckout)
        model.switchManualCheckoutToCash()
        XCTAssertEqual(model.state, .cashAttestation)
        model.declareCashPaidByGuest()
        XCTAssertNotNil(store.record(original.id)?.closedAt)
        XCTAssertNil(store.record(original.id)?.acknowledgedAt)
        XCTAssertNotEqual(model.checkoutEntitlement?.sessionID, original.sessionID)
        XCTAssertEqual(model.checkoutEntitlement?.totalCentavos, original.totalCentavos)
        XCTAssertEqual(model.checkoutEntitlement?.purchasedCopies, original.copies)
    }

    func testAcknowledgedOptionalChoiceSurvivesRelaunchAndLateEvidenceStaysWithClosedGuest() async throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ManualPaymentStore(directory: directory)
        try receiver(store)
        let first = model(in: directory, store: store)
        chooseDigital(first, policy: .optional)
        first.acknowledgeManualPayment()
        let original = try XCTUnwrap(first.manualCheckout)
        first.cancelActiveTaskForTesting()

        let relaunched = ManualPaymentStore(directory: directory)
        XCTAssertEqual(relaunched.record(original.id)?.optionalReceiptChoice, .pending)
        XCTAssertNotNil(relaunched.record(original.id)?.acknowledgedAt)
        XCTAssertNil(relaunched.record(original.id)?.entitlement)
        let permit = OperatorAccessPermit.shared, wasAuthorized = permit.isAuthorized
        permit.authorize()
        defer { if !wasAuthorized { permit.revoke() } }
        try relaunched.reopenForRecovery(original.id)
        relaunched.armedResumeID = original.id
        let recovered = model(in: directory, store: relaunched)
        recovered.startSession()
        XCTAssertEqual(recovered.manualCheckoutStep, .receipt)
        XCTAssertEqual(recovered.manualCheckout?.id, original.id)
        XCTAssertNil(recovered.checkoutEntitlement)
        recovered.cancelSession()
        XCTAssertEqual(recovered.state, .welcome)

        let server = UUID().uuidString.lowercased()
        let proof = ManualReceiptProof(checkoutId: server, snapshotHash: original.snapshotHash, receiptId: UUID().uuidString, storedAt: Date())
        try relaunched.applyRemote(.init(id: server, localCheckoutId: original.id, sessionId: original.sessionID,
            snapshotHash: original.snapshotHash, copies: original.copies, totalCentavos: original.totalCentavos,
            acknowledgedAt: nil, receipt: proof, checkoutURL: nil), to: original.id)
        let next = model(in: directory, store: relaunched)
        next.configureManualCheckoutForTesting(.init(mode: .digital, receiptPolicy: .acknowledgmentOnly), regular: false)
        next.selectBoothFormat(.solo)
        next.confirmCopySelection()
        next.acknowledgeManualPayment()
        XCTAssertEqual(next.checkoutEntitlement?.eventID, "test-event")
        XCTAssertNotEqual(next.checkoutEntitlement?.sessionID, original.sessionID)
        XCTAssertEqual(relaunched.record(original.id)?.receipt, proof)
        XCTAssertNil(relaunched.record(original.id)?.entitlement)
    }

    func testGuestCheckoutRendersSeparateReadableQRsAndOriginalFlow() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let oldKey = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true; oldKey?.makeKey() }
        let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("DerivedData/payment-fixtures")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        func capture(_ name: String) async throws -> [String] {
            try await Task.sleep(for: .milliseconds(450))
            window.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            try XCTUnwrap(image.pngData()).write(to: output.appendingPathComponent(name + ".png"))
            guard name.hasPrefix("ipad-") else { return [] }
            let detector = try XCTUnwrap(CIDetector(ofType: CIDetectorTypeQRCode, context: CIContext(options: [.useSoftwareRenderer: true]),
                                                   options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
            return detector.features(in: CIImage(cgImage: try XCTUnwrap(image.cgImage)))
                .compactMap { ($0 as? CIQRCodeFeature)?.messageString }
        }
        for policy in PaymentReceiptPolicy.allCases {
            let directory = root()
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = ManualPaymentStore(directory: directory)
            try receiver(store, withQR: true)
            let service = ManualCheckoutFixtureService()
            if policy != .required { service.setReady() }
            let model = model(in: directory, store: store, client: service.client())
            window.rootViewController = UIHostingController(rootView: BoothSessionView(viewModel: model))
            window.makeKeyAndVisible()
            if policy == .acknowledgmentOnly {
                _ = try await capture("reference-start")
                model.configureManualCheckoutForTesting(.init(mode: .cashAndDigital, receiptPolicy: policy))
                _ = try await capture("reference-format")
                model.selectBoothFormat(.solo)
                _ = try await capture("reference-copies")
                model.adjustCheckoutCopies(by: 2)
                model.confirmCopySelection()
                _ = try await capture("reference-payment-method")
                model.chooseQRPh()
            } else {
                chooseDigital(model, policy: policy, mode: policy == .required ? .cashAndDigital : .digital)
            }
            if policy == .required {
                try await waitFor { model.canSwitchManualCheckoutToCash }
                let errorCodes = try await capture("ipad-required-unavailable")
                XCTAssertTrue(errorCodes.isEmpty)
                service.setReady()
                await model.refreshManualPayment()
            }
            let paymentCodes = try await capture("ipad-" + policy.rawValue.lowercased() + "-pay")
            XCTAssertEqual(paymentCodes, [Self.syntheticPaymentURL.absoluteString])
            model.acknowledgeManualPayment()
            if policy == .acknowledgmentOnly {
                _ = try await capture("reference-camera")
                model.completeSessionForReportingTest()
                _ = try await capture("reference-completion")
            } else {
                try await waitFor { model.manualCheckout?.receiptSubmissionURL != nil && !model.manualCheckoutIsRefreshing }
                let receiptCodes = try await capture("ipad-" + policy.rawValue.lowercased() + "-receipt")
                XCTAssertEqual(receiptCodes, [try XCTUnwrap(model.manualCheckout?.receiptSubmissionURL?.absoluteString)])
                if policy == .optional {
                    service.setStored()
                    try await waitFor { model.checkoutEntitlement != nil }
                    XCTAssertEqual(store.record(try XCTUnwrap(model.manualCheckout?.id))?.optionalReceiptChoice, .uploaded)
                }
            }
            model.cancelActiveTaskForTesting()
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

/// In-process responses for the real native transport. The Worker tests verify storage signatures.
private nonisolated final class ManualCheckoutFixtureService: @unchecked Sendable {
    private let lock = NSLock()
    private var ready = false
    private var stored = false
    private var status: [String: Any] = [:]
    private let serverID = "11111111-1111-4111-8111-111111111111"

    func setReady() { lock.withLock { ready = true } }
    func setStored() { lock.withLock { stored = true } }

    @MainActor func client() -> PaymentsAPIClient {
        ManualCheckoutFixtureProtocol.service = self
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ManualCheckoutFixtureProtocol.self]
        return PaymentsAPIClient(configuration: .init(baseURL: URL(string: "https://receipts.example.test")!, environment: "test"),
            credentialStore: ManualFixtureCredential(), session: URLSession(configuration: configuration))
    }

    func response(_ request: URLRequest) throws -> (Int, Data) {
        try lock.withLock {
            let date = ISO8601DateFormatter()
            if request.httpMethod == "POST" {
                var bytes = request.httpBody ?? Data()
                if let stream = request.httpBodyStream, bytes.isEmpty {
                    stream.open()
                    defer { stream.close() }
                    var buffer = [UInt8](repeating: 0, count: 4096)
                    while stream.hasBytesAvailable {
                        let count = stream.read(&buffer, maxLength: buffer.count)
                        if count <= 0 { break }
                        bytes.append(contentsOf: buffer.prefix(count))
                    }
                }
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
                let copies = try XCTUnwrap(body["copies"] as? Int)
                let unitPrice = try XCTUnwrap(body["unitPriceCentavos"] as? Int)
                status = [
                    "id": serverID, "localCheckoutId": try XCTUnwrap(body["localCheckoutId"]),
                    "sessionId": try XCTUnwrap(body["sessionId"]), "snapshotHash": try XCTUnwrap(body["snapshotHash"]),
                    "copies": copies, "totalCentavos": copies * unitPrice,
                    "expiresAt": date.string(from: Date().addingTimeInterval(1790)),
                    "receiptExpiresAt": date.string(from: Date().addingTimeInterval(86400)),
                    "checkoutURL": "https://receipts.example.test/checkout#c=" + serverID + "." + String(repeating: "a", count: 64)
                ]
            }
            var response = status
            if request.url?.lastPathComponent == "receipt-readiness" {
                response["receiptSubmissionReady"] = ready
            }
            if stored {
                response["receipt"] = ["checkoutId": serverID, "snapshotHash": try XCTUnwrap(status["snapshotHash"]),
                    "receiptId": "22222222-2222-4222-8222-222222222222", "storedAt": date.string(from: Date())]
            }
            return (200, try JSONSerialization.data(withJSONObject: response))
        }
    }
}

private nonisolated struct ManualFixtureCredential: PaymentCredentialProviding {
    func load() throws -> String? { String(repeating: "t", count: 40) }
}

private nonisolated final class ManualCheckoutFixtureProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var service: ManualCheckoutFixtureService?
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "receipts.example.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, bytes) = try XCTUnwrap(Self.service).response(request)
            let response = try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"]))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: bytes)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { }
}
