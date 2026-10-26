import XCTest
@testable import PocketPixelsBooth

@MainActor
final class PrepaidCopyAuthorizationTests: XCTestCase {
    func testRegularAndEventGuestsCanSelectEveryAllowedCopyCount() throws {
        for regular in [true, false] {
            let fixture = try Fixture(regular: regular)
            defer { fixture.cleanup() }
            let model = fixture.model
            let original = try XCTUnwrap(model.checkoutEntitlement)
            for count in 2...10 {
                XCTAssertTrue(model.canIncreasePrintCopies)
                model.increasePrintCopies()
                XCTAssertEqual(model.selectedPrintCopies, count)
                XCTAssertEqual(model.checkoutEntitlement?.purchasedCopies, count)
                XCTAssertEqual(model.checkoutEntitlement?.id, original.id)
                XCTAssertEqual(model.checkoutEntitlement?.sessionID, original.sessionID)
                XCTAssertEqual(model.checkoutEntitlement?.eventID, original.eventID)
                XCTAssertEqual(model.checkoutEntitlement?.policyRevisionID, original.policyRevisionID)
                XCTAssertEqual(model.checkoutEntitlement?.authorizedAt, original.authorizedAt)
                XCTAssertEqual(model.checkoutEntitlement?.totalCentavos, 0)
            }
            XCTAssertFalse(model.canIncreasePrintCopies)
            model.increasePrintCopies()
            XCTAssertEqual(model.selectedPrintCopies, 10)
            // Exercise the real print authorization gate without opening any transport.
            model.printReceipt(host: "", port: nil)
            XCTAssertEqual(model.printerState, .failure("Enter a valid TCP port from 1 to 65535."))
            XCTAssertFalse(model.isPrintBatchActive)
            for count in stride(from: 9, through: 1, by: -1) {
                model.decreasePrintCopies()
                XCTAssertEqual(model.selectedPrintCopies, count)
                XCTAssertEqual(model.checkoutEntitlement?.purchasedCopies, count)
            }
            XCTAssertFalse(model.canDecreasePrintCopies)
        }
    }

    func testFrozenRegularAndEventLimitsCannotBeExpandedByAQuantityBinding() throws {
        for regular in [true, false] {
            let fixture = try Fixture(regular: regular, maximum: 3)
            defer { fixture.cleanup() }
            for _ in 0..<10 { fixture.model.increasePrintCopies() }
            XCTAssertEqual(fixture.model.selectedPrintCopies, 3)
            XCTAssertEqual(fixture.model.checkoutEntitlement?.purchasedCopies, 3)
            fixture.model.selectedPrintCopies = 4
            fixture.model.printReceipt(host: "", port: nil)
            XCTAssertEqual(fixture.model.printerState, .failure("This print quantity is not authorized for the session."))
            XCTAssertEqual(fixture.model.checkoutEntitlement?.purchasedCopies, 3)
        }
    }

    func testDirectPrepaidQuantityBindingUsesTheSameFrozenAuthorizationBeforePrint() throws {
        for regular in [true, false] {
            let fixture = try Fixture(regular: regular)
            defer { fixture.cleanup() }
            fixture.model.selectedPrintCopies = 8
            fixture.model.printReceipt(host: "", port: nil)
            XCTAssertEqual(fixture.model.checkoutEntitlement?.purchasedCopies, 8)
            XCTAssertEqual(fixture.model.printerState, .failure("Enter a valid TCP port from 1 to 65535."))
        }
    }

    func testOperatorFixedPrepaidQuantitiesCannotBeChanged() throws {
        for regular in [true, false] {
            let fixture = try Fixture(regular: regular, maximum: 10, defaultCopies: 3, choice: false)
            defer { fixture.cleanup() }
            fixture.model.increasePrintCopies()
            fixture.model.decreasePrintCopies()
            XCTAssertFalse(fixture.model.canIncreasePrintCopies)
            XCTAssertFalse(fixture.model.canDecreasePrintCopies)
            XCTAssertEqual(fixture.model.selectedPrintCopies, 3)
            fixture.model.printReceipt(host: "", port: nil)
            XCTAssertEqual(fixture.model.printerState, .failure("Enter a valid TCP port from 1 to 65535."))
            fixture.model.selectedPrintCopies = 4
            fixture.model.printReceipt(host: "", port: nil)
            XCTAssertEqual(fixture.model.checkoutEntitlement?.purchasedCopies, 3)
            XCTAssertEqual(fixture.model.printerState, .failure("This print quantity is not authorized for the session."))
        }
    }

    func testPaidQRPhCashAndOfflineCashRemainFixedAtPurchasedQuantity() throws {
        for source in [CheckoutAuthorizationSource.verifiedQRPh, .unverifiedCashDeclared, .localUnsyncedCashDeclared] {
            let fixture = try Fixture(regular: false, defaultCopies: 2, source: source)
            defer { fixture.cleanup() }
            let original = fixture.model.checkoutEntitlement
            XCTAssertFalse(fixture.model.canIncreasePrintCopies)
            XCTAssertFalse(fixture.model.canDecreasePrintCopies)
            for quantity in [1, 3, 10] {
                fixture.model.selectedPrintCopies = quantity
                fixture.model.printReceipt(host: "", port: nil)
                XCTAssertEqual(fixture.model.printerState, .failure("This print quantity is not authorized for the session."))
                XCTAssertEqual(fixture.model.checkoutEntitlement, original)
            }
            fixture.model.selectedPrintCopies = 2
            fixture.model.printReceipt(host: "", port: nil)
            XCTAssertEqual(fixture.model.printerState, .failure("Enter a valid TCP port from 1 to 65535."))
        }
    }

    func testQuantityCannotBeReauthorizedAfterACopyHasStartedOrCompleted() throws {
        for completed in [0, 1] {
            let fixture = try Fixture(regular: true)
            defer { fixture.cleanup() }
            let entitlement = try XCTUnwrap(fixture.model.checkoutEntitlement)
            fixture.model.configureReceiptAuthorizationForTesting(run: fixture.run, entitlement: entitlement, currentCopy: 1, completedCopies: completed)
            XCTAssertFalse(fixture.model.canIncreasePrintCopies)
            fixture.model.selectedPrintCopies = 2
            fixture.model.printReceipt(host: "", port: nil)
            XCTAssertEqual(fixture.model.checkoutEntitlement, entitlement)
            XCTAssertEqual(fixture.model.printerState, .failure("This print quantity is not authorized for the session."))
        }
    }

    func testWrongSessionFormatEventAndPolicyCannotAcquireMoreCopies() throws {
        for mismatch in 0..<4 {
            let fixture = try Fixture(regular: false)
            defer { fixture.cleanup() }
            let original = try XCTUnwrap(fixture.model.checkoutEntitlement)
            switch mismatch {
            case 0: fixture.model.sessionIdentifier = "another-guest"
            case 1: fixture.model.selectedBoothFormat = .duo
            default:
                var run = fixture.run
                if mismatch == 2 { run = .init(id: "another-event", name: run.name, venue: run.venue, lifecycle: run.lifecycle, activePolicy: run.activePolicy, updatedAt: run.updatedAt) }
                else { run.activePolicy.revisionID = "another-policy" }
                fixture.model.configureReceiptAuthorizationForTesting(run: run, entitlement: original)
            }
            XCTAssertFalse(fixture.model.canIncreasePrintCopies)
            fixture.model.selectedPrintCopies = 2
            fixture.model.printReceipt(host: "", port: nil)
            XCTAssertEqual(fixture.model.checkoutEntitlement, original)
            XCTAssertEqual(fixture.model.printerState, .failure("This print quantity is not authorized for the session."))
        }
    }

    func testNextGuestDoesNotInheritThePreviousCopyAllowance() throws {
        let fixture = try Fixture(regular: true)
        defer { fixture.cleanup() }
        for _ in 1..<10 { fixture.model.increasePrintCopies() }
        XCTAssertEqual(fixture.model.checkoutEntitlement?.purchasedCopies, 10)
        fixture.model.resetAfterDone()
        XCTAssertNil(fixture.model.checkoutEntitlement)
        XCTAssertEqual(fixture.model.selectedPrintCopies, 1)
        XCTAssertFalse(fixture.model.canIncreasePrintCopies)
    }

    private final class Fixture {
        let root: URL
        let model: BoothSessionViewModel
        let run: CommercialEventRun

        init(regular: Bool, maximum: Int = 10, defaultCopies: Int = 1, choice: Bool = true,
             source: CheckoutAuthorizationSource = .privatePrepaid) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("copy-authorization-\(UUID())")
            var settings = RegularBoothSettings()
            settings.maxCopies = maximum
            settings.defaultCopies = defaultCopies
            settings.guestCopyChoice = choice
            var policy = settings.policy
            if source != .privatePrepaid {
                policy.commercialMode = .payPerPrint
                policy.unitPriceCentavos = 2500
                policy.cashEnabled = true
                policy.qrPhEnabled = true
            }
            run = .init(id: regular ? "" : "prepaid-event", name: regular ? "Regular Booth" : "Event",
                        venue: "", lifecycle: .active, activePolicy: policy, updatedAt: Date())
            var environment = BoothSessionEnvironment.customer
            environment.archiveDirectory = root.appendingPathComponent("archive")
            environment.recoveryDirectory = root.appendingPathComponent("recovery")
            environment.detachedCheckoutDirectory = root.appendingPathComponent("detached")
            environment.deliversGallery = false
            environment.recordsCustomerSessionMetrics = false
            model = BoothSessionViewModel(environment: environment, eventRunStore: nil, checkpointStore: nil)
            let entitlement = CheckoutEntitlement(
                id: "local-or-paid-authorization", orderID: source == .privatePrepaid || source == .localUnsyncedCashDeclared ? nil : "paid-order",
                eventID: run.id, policyRevisionID: policy.revisionID, sessionID: "test-guest-\(UUID())",
                selectedFormatRawValue: BoothFormat.solo.rawValue, purchasedCopies: defaultCopies,
                unitPriceCentavos: policy.unitPriceCentavos, totalCentavos: policy.unitPriceCentavos * defaultCopies,
                authorizationSource: source, authorizedAt: Date(), receiptFingerprint: nil,
                serverState: source == .privatePrepaid || source == .localUnsyncedCashDeclared ? nil : "IN_SESSION"
            )
            model.configureReceiptAuthorizationForTesting(run: run, entitlement: entitlement)
        }

        func cleanup() { model.cancelActiveTaskForTesting(); try? FileManager.default.removeItem(at: root) }
    }
}
