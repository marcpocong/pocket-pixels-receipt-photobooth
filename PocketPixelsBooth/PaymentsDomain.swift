import Foundation

nonisolated enum CommercialEventMode: String, Codable, CaseIterable, Sendable {
    case privatePrepaid = "PRIVATE_PREPAID"
    case payPerPrint = "PAY_PER_PRINT"

    var displayName: String {
        switch self {
        case .privatePrepaid: "Private / Prepaid"
        case .payPerPrint: "Pay Per Print"
        }
    }
}

nonisolated enum CommercialEventLifecycle: String, Codable, CaseIterable, Sendable {
    case draft = "DRAFT"
    case active = "ACTIVE"
    case paused = "PAUSED"
    case ended = "ENDED"
    case archived = "ARCHIVED"
}

nonisolated enum GuestPaymentMethod: String, Codable, CaseIterable, Sendable {
    case qrPh = "QRPH"
    case cash = "CASH"
}

nonisolated struct PaymentPolicySnapshot: Codable, Equatable, Sendable {
    static let copyRange = 1...10

    var revisionID: String
    var revision: Int
    var commercialMode: CommercialEventMode
    var unitPriceCentavos: Int
    var maxCopies: Int
    var defaultCopies: Int
    var cashEnabled: Bool
    var qrPhEnabled: Bool
    var prepaidGuestCopyChoice: Bool
    var supportedFormatRawValues: [String]
    var offlineValidUntil: Date?

    static var legacyPrepaid: PaymentPolicySnapshot {
        PaymentPolicySnapshot(
            revisionID: "legacy-prepaid",
            revision: 0,
            commercialMode: .privatePrepaid,
            unitPriceCentavos: 0,
            maxCopies: 10,
            defaultCopies: 1,
            cashEnabled: false,
            qrPhEnabled: false,
            prepaidGuestCopyChoice: true,
            supportedFormatRawValues: BoothFormat.allCases.map(\.rawValue),
            offlineValidUntil: nil
        )
    }

    var validationMessage: String? {
        guard Self.copyRange.contains(maxCopies),
              Self.copyRange.contains(defaultCopies),
              defaultCopies <= maxCopies,
              !supportedFormatRawValues.isEmpty else {
            return "Choose valid copy limits and at least one format."
        }
        if commercialMode == .payPerPrint {
            guard unitPriceCentavos > 0 else { return "Pay-per-print events need a positive price." }
            guard cashEnabled || qrPhEnabled else { return "Enable Cash or QR Ph." }
        } else if unitPriceCentavos != 0 {
            return "Private/prepaid events cannot charge guests."
        }
        return nil
    }

    func totalCentavos(for copies: Int) -> Int? {
        guard copies >= 1, copies <= maxCopies, unitPriceCentavos > 0,
              unitPriceCentavos <= Int.max / copies else {
            return nil
        }
        return unitPriceCentavos * copies
    }

    func supports(_ format: BoothFormat) -> Bool {
        supportedFormatRawValues.contains(format.rawValue)
    }

    func permitsOfflineCash(at date: Date) -> Bool {
        commercialMode == .payPerPrint && cashEnabled && (offlineValidUntil.map { date <= $0 } ?? false)
    }
}

nonisolated struct CommercialEventRun: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var name: String
    var venue: String
    var lifecycle: CommercialEventLifecycle
    var activePolicy: PaymentPolicySnapshot
    var startsAt: Date?
    var endsAt: Date?
    var updatedAt: Date

    static var legacy: CommercialEventRun {
        CommercialEventRun(
            id: "legacy-local-event",
            name: "Legacy Event",
            venue: "",
            lifecycle: .active,
            activePolicy: .legacyPrepaid,
            startsAt: nil,
            endsAt: nil,
            updatedAt: Date()
        )
    }

    var acceptsNewSessions: Bool {
        lifecycle == .active
    }
}

nonisolated enum CheckoutAuthorizationSource: String, Codable, Sendable {
    case privatePrepaid = "PRIVATE_PREPAID"
    case verifiedQRPh = "VERIFIED_QRPH"
    case unverifiedCashDeclared = "UNVERIFIED_CASH_DECLARED"
    case localUnsyncedCashDeclared = "LOCAL_UNSYNCED_CASH_DECLARED"
}

nonisolated struct CheckoutEntitlement: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let orderID: String?
    let eventID: String
    let policyRevisionID: String
    var sessionID: String?
    let selectedFormatRawValue: String
    let purchasedCopies: Int
    let unitPriceCentavos: Int
    let totalCentavos: Int
    let authorizationSource: CheckoutAuthorizationSource
    let authorizedAt: Date
    var receiptFingerprint: String?

    enum CodingKeys: String, CodingKey {
        case id
        case orderID = "orderId"
        case eventID = "eventId"
        case policyRevisionID = "policyRevisionId"
        case sessionID = "sessionId"
        case selectedFormatRawValue = "selectedFormat"
        case purchasedCopies
        case unitPriceCentavos
        case totalCentavos
        case authorizationSource
        case authorizedAt
        case receiptFingerprint
    }

    var permitsCapture: Bool {
        purchasedCopies >= 1
    }

    func permitsPrint(copyIndex: Int, receiptFingerprint: String) -> Bool {
        (1...purchasedCopies).contains(copyIndex)
            && (self.receiptFingerprint == nil || self.receiptFingerprint == receiptFingerprint)
    }
}

nonisolated enum PaymentOrderState: String, Codable, Sendable {
    case creating = "CREATING"
    case awaitingPayment = "AWAITING_PAYMENT"
    case confirming = "CONFIRMING"
    case paid = "PAID_VERIFIED"
    case cashDeclared = "CASH_DECLARED_UNVERIFIED"
    case failed = "PAYMENT_FAILED"
    case expired = "QR_EXPIRED_CONFIRMED"
    case unknownReconciliation = "UNKNOWN_RECONCILIATION"
}

nonisolated struct PaymentOrder: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let eventID: String
    let policyRevisionID: String
    let format: String
    let copies: Int
    let unitPriceCentavos: Int
    let totalCentavos: Int
    let currency: String
    let state: String
    let expiresAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case eventID = "eventId"
        case policyRevisionID = "policyRevisionId"
        case format, copies, unitPriceCentavos, totalCentavos, currency, state, expiresAt
    }
}

nonisolated struct PaymentAttempt: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let method: String?
    let state: String
    let qrImageDataURL: String?
    let testURL: URL?
    let expiresAt: Date?
}

nonisolated struct PaymentStatusResponse: Codable, Sendable {
    let order: PaymentOrder
    let attempt: PaymentAttempt?
    let entitlement: CheckoutEntitlement?
    let serverTime: Date
}

nonisolated enum PHPPriceFormatter {
    static func string(centavos: Int) -> String {
        let value = Decimal(centavos) / 100
        return value.formatted(.currency(code: "PHP").locale(Locale(identifier: "en_PH")))
    }
}
