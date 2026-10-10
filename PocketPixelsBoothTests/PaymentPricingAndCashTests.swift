import Foundation
import Testing
@testable import PocketPixelsBooth

@Suite("Payment pricing and policy")
struct PaymentPricingTests {
    @Test(arguments: [(1, 5_000), (2, 10_000), (3, 15_000), (10, 50_000)])
    func exactIntegerCentavoTotals(copies: Int, expected: Int) {
        let policy = paidPolicy(maxCopies: 10)
        #expect(policy.totalCentavos(for: copies) == expected)
    }

    @Test func rejectsInvalidCopiesAndInvalidPaidPolicies() {
        let policy = paidPolicy(maxCopies: 3)
        #expect(policy.totalCentavos(for: 0) == nil)
        #expect(policy.totalCentavos(for: 4) == nil)

        var noMethod = policy
        noMethod.cashEnabled = false
        noMethod.qrPhEnabled = false
        #expect(noMethod.validationMessage != nil)

        var zeroPrice = policy
        zeroPrice.unitPriceCentavos = 0
        #expect(zeroPrice.validationMessage != nil)
    }

    @Test func legacyMigrationDefaultsToPrepaidAndDoesNotCharge() {
        let legacy = CommercialEventRun.legacy
        #expect(legacy.activePolicy.commercialMode == .privatePrepaid)
        #expect(legacy.activePolicy.unitPriceCentavos == 0)
        #expect(legacy.lifecycle == .active)
    }

    @Test func paidEntitlementLocksQuantityAndReceiptIdentity() {
        let entitlement = CheckoutEntitlement(
            id: "entitlement",
            orderID: "order",
            eventID: "event",
            policyRevisionID: "revision",
            sessionID: "session",
            selectedFormatRawValue: BoothFormat.solo.rawValue,
            purchasedCopies: 3,
            unitPriceCentavos: 5_000,
            totalCentavos: 15_000,
            authorizationSource: .verifiedQRPh,
            authorizedAt: Date(),
            receiptFingerprint: String(repeating: "a", count: 64)
        )
        #expect(entitlement.permitsPrint(copyIndex: 1, receiptFingerprint: String(repeating: "a", count: 64)))
        #expect(entitlement.permitsPrint(copyIndex: 3, receiptFingerprint: String(repeating: "a", count: 64)))
        #expect(!entitlement.permitsPrint(copyIndex: 4, receiptFingerprint: String(repeating: "a", count: 64)))
        #expect(!entitlement.permitsPrint(copyIndex: 1, receiptFingerprint: String(repeating: "b", count: 64)))
    }

    private func paidPolicy(maxCopies: Int) -> PaymentPolicySnapshot {
        PaymentPolicySnapshot(
            revisionID: "revision",
            revision: 1,
            commercialMode: .payPerPrint,
            unitPriceCentavos: 5_000,
            maxCopies: maxCopies,
            defaultCopies: 1,
            cashEnabled: true,
            qrPhEnabled: true,
            prepaidGuestCopyChoice: false,
            supportedFormatRawValues: [BoothFormat.solo.rawValue],
            offlineValidUntil: Date().addingTimeInterval(3_600)
        )
    }
}

@Suite("Offline cash recovery")
struct CashOfflineRecoveryTests {
    @Test func declarationSurvivesRestartAndDuplicateSessionIsRejected() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cash-ledger-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let event = CommercialEventRun(
            id: "offline-event",
            name: "Offline Event",
            venue: "",
            lifecycle: .active,
            activePolicy: PaymentPolicySnapshot(
            revisionID: "revision-1",
            revision: 1,
            commercialMode: .payPerPrint,
            unitPriceCentavos: 5_000,
            maxCopies: 10,
            defaultCopies: 1,
            cashEnabled: true,
            qrPhEnabled: true,
            prepaidGuestCopyChoice: false,
            supportedFormatRawValues: [BoothFormat.solo.rawValue],
                offlineValidUntil: Date().addingTimeInterval(3_600)
            ),
            startsAt: nil,
            endsAt: nil,
            updatedAt: Date()
        )

        let first = try OfflineCashLedger(directory: root)
        let (record, entitlement) = try await first.declare(event: event, sessionID: "session-1", format: .solo, copies: 3)
        #expect(record.syncState == .pending)
        #expect(record.totalCentavos == 15_000)
        #expect(entitlement.authorizationSource == .localUnsyncedCashDeclared)

        let restarted = try OfflineCashLedger(directory: root)
        #expect(await restarted.pendingRecords().map(\.id) == [record.id])
        #expect(await restarted.unsyncedTotalCentavos() == 15_000)

        await #expect(throws: OfflineCashLedger.LedgerError.self) {
            _ = try await restarted.declare(event: event, sessionID: "session-1", format: .solo, copies: 3)
        }

        try await restarted.applySync(localID: record.id, serverOrderID: "server-order", conflict: nil)
        #expect(await restarted.pendingRecords().isEmpty)
    }

    @Test func staleOfflinePolicyIsRejected() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cash-ledger-stale-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = try OfflineCashLedger(directory: root)
        var event = CommercialEventRun.legacy
        event.activePolicy = PaymentPolicySnapshot(
            revisionID: "stale",
            revision: 1,
            commercialMode: .payPerPrint,
            unitPriceCentavos: 5_000,
            maxCopies: 1,
            defaultCopies: 1,
            cashEnabled: true,
            qrPhEnabled: false,
            prepaidGuestCopyChoice: false,
            supportedFormatRawValues: [BoothFormat.solo.rawValue],
            offlineValidUntil: Date().addingTimeInterval(-1)
        )
        await #expect(throws: OfflineCashLedger.LedgerError.self) {
            _ = try await ledger.declare(event: event, sessionID: "session", format: .solo, copies: 1)
        }
    }
}
