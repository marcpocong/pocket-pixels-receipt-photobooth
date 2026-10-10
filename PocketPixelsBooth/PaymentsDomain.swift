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
    /// Server lifecycle (`AUTHORIZED`, `IN_SESSION`, `CONSUMED`, `REVIEW_REQUIRED`); nil for local entitlements.
    var serverState: String? = nil

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
        case serverState = "state"
    }

    var permitsCapture: Bool {
        purchasedCopies >= 1 && serverState != "REVIEW_REQUIRED" && serverState != "CONSUMED"
    }

    /// Server entitlements must be claimed by this session before the camera starts.
    var requiresServerClaim: Bool {
        orderID != nil && serverState == "AUTHORIZED"
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
    var paymentMethod: String? = nil
    var checkoutSessionID: String? = nil
    var supersedesOrderID: String? = nil
    var supersededByOrderID: String? = nil

    enum CodingKeys: String, CodingKey {
        case id
        case eventID = "eventId"
        case policyRevisionID = "policyRevisionId"
        case format, copies, unitPriceCentavos, totalCentavos, currency, state, expiresAt, paymentMethod
        case checkoutSessionID = "checkoutSessionId"
        case supersedesOrderID = "supersedesOrderId"
        case supersededByOrderID = "supersededByOrderId"
    }
}

/// Server decision on whether a deliberate new checkout may replace an order.
nonisolated struct NewCheckoutDecision: Codable, Equatable, Sendable {
    let allowed: Bool
    let reason: String
}

nonisolated struct PaymentAttempt: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let method: String?
    let state: String
    let qrImageDataURL: String?
    let testURL: URL?
    let expiresAt: Date?
    /// `PROVIDER_VERIFIED`, `NOT_VERIFIED`, or `UNVERIFIED_SELF_REPORTED` for guest cash.
    var verification: String? = nil

    /// No payment can still arrive for this attempt's own QR code.
    var isConclusivelyUnpaid: Bool {
        ["CREATE_FAILED_NO_QR", "PAYMENT_FAILED", "QR_EXPIRED_CONFIRMED"].contains(state)
    }
}

nonisolated struct PaymentStatusResponse: Codable, Sendable {
    let order: PaymentOrder
    let attempt: PaymentAttempt?
    let entitlement: CheckoutEntitlement?
    var newCheckout: NewCheckoutDecision? = nil
    let serverTime: Date
}

nonisolated enum PHPPriceFormatter {
    static func string(centavos: Int) -> String {
        let value = Decimal(centavos) / 100
        return value.formatted(.currency(code: "PHP").locale(Locale(identifier: "en_PH")))
    }
}

/// Operators type Philippine pesos; storage and the API stay in integer centavos. Parsing is done
/// on the digit string, never through floating point, so "50.10" is exactly 5010 centavos.
nonisolated enum PesoAmount {
    static let maximumCentavos = 10_000_000

    static func centavos(fromPesoText text: String) -> Int? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("₱") { value.removeFirst() }
        if value.uppercased().hasPrefix("PHP") { value = String(value.dropFirst(3)) }
        value = value.trimmingCharacters(in: .whitespaces)
        let grouped = value.split(separator: ".", omittingEmptySubsequences: false)
        guard grouped.count <= 2, let wholeRaw = grouped.first else { return nil }
        let whole = String(wholeRaw)
        // Thousands separators are accepted only in canonical groups of three ("1,500").
        if whole.contains(",") {
            let parts = whole.split(separator: ",", omittingEmptySubsequences: false)
            guard let first = parts.first, (1...3).contains(first.count),
                  parts.dropFirst().allSatisfy({ $0.count == 3 }) else { return nil }
        }
        let digits = whole.replacingOccurrences(of: ",", with: "")
        guard !digits.isEmpty, digits.count <= 6, digits.allSatisfy(\.isASCIIDigit) else { return nil }
        let fraction = grouped.count == 2 ? String(grouped[1]) : ""
        guard fraction.count <= 2, fraction.allSatisfy(\.isASCIIDigit), grouped.count == 1 || !fraction.isEmpty else { return nil }
        guard let pesos = Int(digits), let cents = Int(fraction.padding(toLength: 2, withPad: "0", startingAt: 0)) else { return nil }
        let total = pesos * 100 + cents
        return total <= maximumCentavos ? total : nil
    }

    static func editingText(centavos: Int) -> String {
        let sign = centavos < 0 ? "-" : ""
        let magnitude = abs(centavos)
        return "\(sign)\(magnitude / 100).\(String(format: "%02d", magnitude % 100))"
    }
}

nonisolated private extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}

/// Shared JSON coding for the Payments Worker. The Worker emits ISO-8601 timestamps with
/// milliseconds (`2026-10-10T08:00:00.000Z`). Foundation's `.iso8601` strategy does not accept
/// fractional seconds on every OS version in the deployment range, so parsing is explicit.
nonisolated enum PaymentsJSON {
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { container in
            let raw = try container.singleValueContainer().decode(String.self)
            guard let date = parseDate(raw) else {
                throw DecodingError.dataCorrupted(.init(codingPath: container.codingPath, debugDescription: "Invalid ISO-8601 date: \(raw)"))
            }
            return date
        }
        return decoder
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, container in
            var single = container.singleValueContainer()
            try single.encode(string(from: date))
        }
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static func parseDate(_ raw: String) -> Date? {
        if let date = try? Date(raw, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) { return date }
        return try? Date(raw, strategy: Date.ISO8601FormatStyle())
    }

    static func string(from date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }
}

/// Where the booth's charging policy comes from. Local mode never charges guests and needs no
/// Payments Worker; server mode takes price, methods and lifecycle only from the server.
nonisolated enum CommercialPolicySource: String, Codable, CaseIterable, Sendable {
    case localPrepaid = "LOCAL_PREPAID"
    case serverManaged = "SERVER_MANAGED"

    var displayName: String {
        switch self {
        case .localPrepaid: "Private / Prepaid (this iPad)"
        case .serverManaged: "Paid events (server-managed)"
        }
    }

    private static let key = "pocketPixels.commercialPolicySource"

    static func load(defaults: UserDefaults = .standard) -> CommercialPolicySource {
        defaults.string(forKey: key).flatMap(CommercialPolicySource.init(rawValue:)) ?? .localPrepaid
    }

    static func save(_ value: CommercialPolicySource, defaults: UserDefaults = .standard) {
        defaults.set(value.rawValue, forKey: key)
    }
}

/// Server event policy as published by `GET /v1/events/active` (camelCase `publicPolicy`).
nonisolated struct ServerEventPolicy: Codable, Equatable, Sendable {
    let id: String
    let name: String
    let venue: String?
    let lifecycle: CommercialEventLifecycle
    let policyRevisionId: String
    let revision: Int
    let commercialMode: CommercialEventMode
    let unitPriceCentavos: Int
    let maxCopies: Int
    let defaultCopies: Int
    let cashEnabled: Bool
    let qrphEnabled: Bool
    let prepaidGuestCopyChoice: Bool
    let supportedFormats: [String]
    let offlineValidUntil: Date?

    var eventRun: CommercialEventRun {
        CommercialEventRun(
            id: id,
            name: name,
            venue: venue ?? "",
            lifecycle: lifecycle,
            activePolicy: PaymentPolicySnapshot(
                revisionID: policyRevisionId,
                revision: revision,
                commercialMode: commercialMode,
                unitPriceCentavos: unitPriceCentavos,
                maxCopies: maxCopies,
                defaultCopies: defaultCopies,
                cashEnabled: cashEnabled,
                qrPhEnabled: qrphEnabled,
                prepaidGuestCopyChoice: prepaidGuestCopyChoice,
                supportedFormatRawValues: supportedFormats,
                offlineValidUntil: offlineValidUntil
            ),
            startsAt: nil,
            endsAt: nil,
            updatedAt: Date()
        )
    }
}

/// How the policy for the current guest session was established.
nonisolated enum PolicyAuthority: Equatable, Sendable {
    case localPrepaid
    case serverConfirmed(fetchedAt: Date)
    case signedOffline(snapshotID: String, expiresAt: Date)

    var isOfflineCashOnly: Bool {
        if case .signedOffline = self { return true }
        return false
    }
}

/// Pure decision rules for the guest checkout, kept separate from the view model so the
/// QR/cash exclusivity rules can be unit tested.
nonisolated struct CheckoutGuard: Equatable, Sendable {
    /// A server order exists (or may exist) for this session.
    var serverCheckoutStarted = false
    /// A QR attempt was started for the current order and is not conclusively unpaid.
    var qrAttemptUnresolved = false
    /// The server said a deliberate new checkout may replace the current order.
    var newCheckoutAllowed = false

    func canChooseCash(authority: PolicyAuthority, cashEnabled: Bool) -> Bool {
        guard cashEnabled, !qrAttemptUnresolved else { return false }
        // Offline cash is never a fallback once a server checkout for this session started.
        if authority.isOfflineCashOnly { return !serverCheckoutStarted }
        return true
    }

    func canChooseQR(authority: PolicyAuthority, qrEnabled: Bool, online: Bool) -> Bool {
        guard case .serverConfirmed = authority else { return false }
        return qrEnabled && online && !qrAttemptUnresolved
    }

    func canStartNewCheckout() -> Bool {
        newCheckoutAllowed
    }
}
