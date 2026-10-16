import Foundation
import Security
import CryptoKit

nonisolated struct PaymentsConfiguration: Sendable, Equatable {
    let baseURL: URL
    let environment: String

    private static let baseURLKey = "pocketPixels.payments.baseURL"
    private static let environmentKey = "pocketPixels.payments.environment"

    /// Operator-paired configuration first, then a reviewed bundle setting. HTTPS only.
    static var bundled: PaymentsConfiguration? {
        current()
    }

    static func current(defaults: UserDefaults = .standard, bundle: Bundle = .main) -> PaymentsConfiguration? {
        let raw = defaults.string(forKey: baseURLKey) ?? (bundle.object(forInfoDictionaryKey: "PAYMENTS_API_BASE_URL") as? String)
        guard let raw, let url = validatedURL(raw) else { return nil }
        let environment = defaults.string(forKey: environmentKey)
            ?? (bundle.object(forInfoDictionaryKey: "PAYMENTS_ENVIRONMENT") as? String)
            ?? "test"
        return PaymentsConfiguration(baseURL: url, environment: environment == "live" ? "live" : "test")
    }

    static func validatedURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return nil }
        return url
    }

    static func savePaired(baseURL: URL, environment: String, defaults: UserDefaults = .standard) {
        defaults.set(baseURL.absoluteString, forKey: baseURLKey)
        defaults.set(environment, forKey: environmentKey)
    }

    static func clearPaired(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: baseURLKey)
        defaults.removeObject(forKey: environmentKey)
    }

    /// Joins an API path (which may carry a query string) onto the base URL.
    func url(for path: String) -> URL? {
        var base = baseURL.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        return URL(string: "\(base)/\(path)")
    }
}

nonisolated protocol PaymentCredentialProviding: Sendable {
    func load() throws -> String?
}

nonisolated struct PaymentDeviceCredentialStore: PaymentCredentialProviding {
    private let service = "com.pocketpixels.payments"
    private let account = "device-token"

    func save(_ token: String) throws {
        let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count >= 32, value.count <= 512, let data = value.data(using: .utf8) else {
            throw PaymentsAPIError.configuration("The device credential is invalid.")
        }
        var attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            attributes.merge(query) { _, new in new }
            guard SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess else {
                throw PaymentsAPIError.configuration("Could not securely save the payment device credential.")
            }
        } else if status != errSecSuccess {
            throw PaymentsAPIError.configuration("Could not securely save the payment device credential.")
        }
    }

    func load() throws -> String? {
        var item = query
        item[kSecReturnData as String] = true
        item[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(item as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,
              let data = result as? Data,
              let token = String(data: data, encoding: .utf8) else {
            throw PaymentsAPIError.configuration("Could not read the payment device credential.")
        }
        return token
    }

    func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw PaymentsAPIError.configuration("Could not revoke the local payment credential.")
        }
    }

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

nonisolated struct PaymentOperatorCredentialStore: PaymentCredentialProviding {
    private let configuration: PaymentsConfiguration
    private let testFallback: any PaymentCredentialProviding
    private let permit: OperatorAccessPermit

    init(configuration: PaymentsConfiguration,
         testFallback: any PaymentCredentialProviding = PaymentDeviceCredentialStore(),
         permit: OperatorAccessPermit = .shared) {
        self.configuration = configuration
        self.testFallback = testFallback
        self.permit = permit
    }

    private var query: [String: Any] {
        let binding = "\(configuration.environment):\(configuration.baseURL.absoluteString)"
        let account = SHA256.hash(data: Data(binding.utf8)).map { String(format: "%02x", $0) }.joined()
        return [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "com.pocketpixels.payments.operator", kSecAttrAccount as String: account]
    }

    func save(_ token: String) throws {
        guard permit.isAuthorized else { throw PaymentsAPIError.unauthorized }
        guard (32...512).contains(token.count) else { throw PaymentsAPIError.configuration("Invalid operator credential.") }
        var attributes: [String: Any] = [kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            attributes.merge(query) { _, new in new }
            guard SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess else {
                throw PaymentsAPIError.configuration("Could not securely save the operator credential.")
            }
        } else if status != errSecSuccess {
            throw PaymentsAPIError.configuration("Could not securely save the operator credential.")
        }
    }

    func load() throws -> String? {
        guard permit.isAuthorized else { throw PaymentsAPIError.unauthorized }
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound {
            // Existing combined TEST pairing remains compatible. LIVE never falls back to booth.
            return configuration.environment == "test" ? try testFallback.load() : nil
        }
        guard status == errSecSuccess, let data = result as? Data,
              let token = String(data: data, encoding: .utf8) else { throw PaymentsAPIError.unauthorized }
        return token
    }
}

nonisolated struct PaymentPairingCredential: PaymentCredentialProviding {
    let token: String
    func load() throws -> String? { token }
}

nonisolated enum PaymentsAPIError: Error, LocalizedError, Sendable, Equatable {
    case configuration(String)
    case unauthorized
    /// The server answered with a definitive error code (for example `payment_method_locked`).
    case rejected(code: String, message: String, status: Int, details: Data)
    /// The server answered 5xx without a structured code, or could not be reached for a read.
    case unavailable
    /// A write may or may not have been processed (timeout or connection loss after sending).
    case outcomeUnknown
    case invalidResponse

    var code: String? {
        if case .rejected(let code, _, _, _) = self { return code }
        return nil
    }

    var isOutcomeUnknown: Bool {
        if case .outcomeUnknown = self { return true }
        return code == "qr_status_unknown"
    }

    var errorDescription: String? {
        switch self {
        case .configuration(let message): message
        case .rejected(_, let message, _, _): message
        case .unauthorized: "This iPad is not authorized for payments."
        case .unavailable: "The payments service is unavailable."
        case .outcomeUnknown: "The connection was interrupted. The payment status is being checked."
        case .invalidResponse: "The payments service returned an invalid response."
        }
    }

    func decodeDetails<Value: Decodable>(_ type: Value.Type) -> Value? {
        guard case .rejected(_, _, _, let details) = self else { return nil }
        return try? PaymentsAPIClient.makeDecoder().decode(Value.self, from: details)
    }
}

actor PaymentsAPIClient {
    private struct OrderEnvelope: Decodable { let order: PaymentOrder }

    private struct CreateOrderBody: Encodable {
        let eventId: String
        let format: String
        let copies: Int
        let checkoutSessionId: String
        let expectedPolicyRevisionId: String
        let expectedUnitPriceCentavos: Int
        let supersedesOrderId: String?
        let idempotencyKey: String
    }

    private struct ClaimBody: Encodable {
        let sessionId: String
        let idempotencyKey: String
        let recovery: Bool?
    }

    private let configuration: PaymentsConfiguration
    private let credentials: any PaymentCredentialProviding
    private let operatorCredentials: any PaymentCredentialProviding
    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        configuration: PaymentsConfiguration,
        credentialStore: any PaymentCredentialProviding = PaymentDeviceCredentialStore(),
        operatorCredentialStore: (any PaymentCredentialProviding)? = nil,
        session: URLSession = .shared
    ) {
        self.configuration = configuration
        self.credentials = credentialStore
        self.operatorCredentials = operatorCredentialStore ?? PaymentOperatorCredentialStore(configuration: configuration, testFallback: credentialStore)
        self.session = session
        encoder = PaymentsJSON.encoder()
        decoder = Self.makeDecoder()
    }

    nonisolated static func makeDecoder() -> JSONDecoder {
        let decoder = PaymentsJSON.decoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    nonisolated var environment: String { configuration.environment }

    // MARK: Booth

    func device() async throws -> DeviceInfoResponse {
        try await send("v1/device", method: "GET", body: Optional<EmptyBody>.none)
    }

    func activeEvent() async throws -> ActiveEventResponse {
        try await send("v1/events/active", method: "GET", body: Optional<EmptyBody>.none)
    }

    func createOrder(
        event: ServerEventPolicy,
        format: BoothFormat,
        copies: Int,
        checkoutSessionID: String,
        supersedesOrderID: String?,
        idempotencyKey: String
    ) async throws -> PaymentOrder {
        let body = CreateOrderBody(
            eventId: event.id,
            format: format.paymentRawValue(in: event.supportedFormats) ?? format.rawValue,
            copies: copies,
            checkoutSessionId: checkoutSessionID,
            expectedPolicyRevisionId: event.policyRevisionId,
            expectedUnitPriceCentavos: event.unitPriceCentavos,
            supersedesOrderId: supersedesOrderID,
            idempotencyKey: idempotencyKey
        )
        let response: OrderEnvelope = try await send("v1/orders", method: "POST", body: body, idempotencyKey: idempotencyKey)
        return response.order
    }

    func createQR(orderID: String) async throws -> PaymentAttempt {
        struct Response: Decodable { let attempt: PaymentAttempt }
        let response: Response = try await send("v1/orders/\(orderID)/qrph", method: "POST", body: EmptyBody())
        return response.attempt
    }

    func declareCash(orderID: String) async throws -> PaymentStatusResponse {
        try await send("v1/orders/\(orderID)/cash-declaration", method: "POST", body: EmptyBody())
    }

    /// Attendant-confirmed cash. Sent with the operator credential, which the iPad releases
    /// only after local operator authentication; the server records it as operator-confirmed,
    /// never provider-verified. Idempotent: a replay returns the same entitlement.
    func confirmCash(orderID: String, expectedTotalCentavos: Int) async throws -> PaymentStatusResponse {
        struct Body: Encodable { let expectedTotalCentavos: Int }
        return try await send("v1/admin/orders/\(orderID)/cash-confirmation", method: "POST", body: Body(expectedTotalCentavos: expectedTotalCentavos))
    }

    func status(orderID: String) async throws -> PaymentStatusResponse {
        try await send("v1/orders/\(orderID)/status", method: "GET", body: Optional<EmptyBody>.none)
    }

    func claim(entitlementID: String, sessionID: String, idempotencyKey: String, recovery: Bool = false) async throws -> CheckoutEntitlement {
        struct Response: Decodable { let entitlement: CheckoutEntitlement }
        let body = ClaimBody(sessionId: sessionID, idempotencyKey: idempotencyKey, recovery: recovery ? true : nil)
        let response: Response = try await send("v1/entitlements/\(entitlementID)/claim", method: "POST", body: body, idempotencyKey: idempotencyKey)
        return response.entitlement
    }

    /// Device-scoped, read-only view of every order this iPad created for one checkout session.
    func checkoutRecovery(checkoutSessionID: String) async throws -> CheckoutRecoveryResponse {
        try await send("v1/checkouts/\(checkoutSessionID)", method: "GET", body: Optional<EmptyBody>.none)
    }

    func complete(entitlementID: String, sessionID: String) async throws {
        struct Body: Encodable { let sessionId: String }
        let _: IgnoredResponse = try await send("v1/entitlements/\(entitlementID)/complete", method: "POST", body: Body(sessionId: sessionID))
    }

    func recordPrint(_ record: PrintProgressRecord) async throws {
        let _: IgnoredResponse = try await send("v1/prints/\(record.batchID)/progress", method: "POST", body: record, idempotencyKey: record.idempotencyKey)
    }

    func syncOfflineCash(records: [OfflineCashRecord]) async throws -> [OfflineSyncResult] {
        struct Record: Encodable {
            let localId: String; let localSequence: Int; let snapshotId: String?; let eventId: String; let policyRevisionId: String
            let sessionId: String; let format: String; let copies: Int; let unitPriceCentavos: Int; let totalCentavos: Int; let declaredAt: Date
        }
        struct Body: Encodable { let records: [Record] }
        struct Response: Decodable { let results: [OfflineSyncResult] }
        let body = Body(records: records.map {
            Record(localId: $0.id, localSequence: $0.localSequence, snapshotId: $0.snapshotID, eventId: $0.eventID, policyRevisionId: $0.policyRevisionID,
                   sessionId: $0.sessionID, format: $0.format, copies: $0.copies, unitPriceCentavos: $0.unitPriceCentavos, totalCentavos: $0.totalCentavos, declaredAt: $0.declaredAt)
        })
        let response: Response = try await send("v1/sync/offline-cash", method: "POST", body: body)
        return response.results
    }

    // MARK: Operator

    func listEvents() async throws -> [OperatorEventSummary] {
        var events: [OperatorEventSummary] = []
        var cursor: String?
        var seen = Set<String>()
        repeat {
            try Task.checkCancellation()
            let suffix = cursor.map { "&cursor=" + ($0.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "") } ?? ""
            let response: OperatorEventListResponse = try await send("v1/admin/events?limit=100" + suffix, method: "GET", body: Optional<EmptyBody>.none)
            events.append(contentsOf: response.events)
            cursor = response.nextCursor
            if let cursor, !seen.insert(cursor).inserted || seen.count > 1000 {
                throw PaymentsAPIError.configuration("Event history pagination did not complete. Refresh before using this list.")
            }
        } while cursor != nil
        return events.reduce(into: [OperatorEventSummary]()) { result, event in
            if !result.contains(where: { $0.id == event.id }) { result.append(event) }
        }
    }

    func createEvent(name: String, venue: String) async throws -> OperatorCreatedEvent {
        try await send("v1/admin/events", method: "POST", body: OperatorCreateEventBody(name: name, venue: venue))
    }

    func eventDetail(id: String) async throws -> OperatorEventDetail {
        try await send("v1/admin/events/\(id)", method: "GET", body: Optional<EmptyBody>.none)
    }

    func saveDraft(eventID: String, expectedVersion: Int, name: String, venue: String, policy: ServerPolicyDraft.RequestBody) async throws -> OperatorEventUpdate {
        struct Body: Encodable { let name: String; let venue: String; let policy: ServerPolicyDraft.RequestBody }
        return try await send("v1/admin/events/\(eventID)", method: "PATCH", body: Body(name: name, venue: venue, policy: policy), ifMatch: expectedVersion)
    }

    func transitionEvent(id: String, action: String, expectedVersion: Int, policyRevisionID: String? = nil, acknowledgedUnitPriceCentavos: Int? = nil) async throws -> OperatorEventTransition {
        try await send("v1/admin/events/\(id)/\(action)", method: "POST",
                       body: OperatorTransitionBody(policyRevisionId: policyRevisionID, acknowledgedUnitPriceCentavos: acknowledgedUnitPriceCentavos), ifMatch: expectedVersion)
    }

    func eventSummary(id: String, pendingLocalCount: Int = 0) async throws -> OperatorSalesSummary {
        try await send("v1/admin/events/\(id)/summary?pendingLocalCount=\(max(0, pendingLocalCount))", method: "GET", body: Optional<EmptyBody>.none)
    }

    func eventOrders(id: String, filter: String, cursor: String?) async throws -> OperatorOrderPage {
        var path = "v1/admin/events/\(id)/orders?limit=50&filter=\(filter)"
        if let cursor, let encoded = cursor.addingPercentEncoding(withAllowedCharacters: .alphanumerics) { path += "&cursor=\(encoded)" }
        return try await send(path, method: "GET", body: Optional<EmptyBody>.none)
    }

    func offlineConflicts(eventID: String) async throws -> [OperatorOfflineConflict] {
        struct Response: Decodable { let conflicts: [OperatorOfflineConflict] }
        let response: Response = try await send("v1/admin/events/\(eventID)/offline-conflicts", method: "GET", body: Optional<EmptyBody>.none)
        return response.conflicts
    }

    func diagnostics() async throws -> OperatorDiagnostics {
        try await send("v1/admin/diagnostics", method: "GET", body: Optional<EmptyBody>.none)
    }

    func recordCashCount(eventID: String, countedCentavos: Int, reason: String, pendingLocalCount: Int) async throws -> OperatorCashCount {
        try await send("v1/admin/events/\(eventID)/cash-counts", method: "POST",
                       body: OperatorCashCountBody(countedCentavos: countedCentavos, reason: reason, pendingLocalCount: pendingLocalCount))
    }

    /// Returns one CSV page and whether the export is complete.
    func exportCSV(eventID: String, cursor: String? = nil) async throws -> (data: Data, complete: Bool, nextCursor: String?) {
        var path = "v1/admin/events/\(eventID)/export.csv"
        if let cursor, let encoded = cursor.addingPercentEncoding(withAllowedCharacters: .alphanumerics) { path += "?cursor=\(encoded)" }
        let (data, http) = try await perform(path, method: "GET", bodyData: nil, idempotencyKey: nil, ifMatch: nil)
        guard (200..<300).contains(http.statusCode) else { throw mapError(status: http.statusCode, data: data) }
        return (data, http.value(forHTTPHeaderField: "x-export-complete") == "true", http.value(forHTTPHeaderField: "x-export-next-cursor"))
    }

    /// Completes every page or throws; never offers a truncated file as a complete export.
    func completeEventCSV(eventID: String) async throws -> Data {
        var combined = Data()
        var cursor: String?
        var seen = Set<String>()
        var pages = 0
        repeat {
            try Task.checkCancellation()
            let page = try await exportCSV(eventID: eventID, cursor: cursor)
            guard let text = String(data: page.data, encoding: .utf8), let newline = text.range(of: "\r\n") else { throw PaymentsAPIError.invalidResponse }
            combined.append(pages == 0 ? page.data : Data(text[newline.upperBound...].utf8))
            pages += 1
            if page.complete { return combined }
            guard let next = page.nextCursor, !next.isEmpty, seen.insert(next).inserted, pages < 1000 else {
                throw PaymentsAPIError.configuration("The export could not be completed. No partial CSV was prepared.")
            }
            cursor = next
        } while true
    }

    func allEventOrders(id: String, requireCheckoutIdentity: Bool = false) async throws -> [OperatorOrderRow] {
        var rows: [OperatorOrderRow] = []
        var cursor: String?
        var seen = Set<String>()
        repeat {
            try Task.checkCancellation()
            let page = try await eventOrders(id: id, filter: "all", cursor: cursor)
            if requireCheckoutIdentity, page.checkoutSessionIdentityIncluded != true {
                throw PaymentsAPIError.configuration("Exact run payment totals need the approved Payments Worker reporting update. Commercial-event totals remain available; no missing links are treated as unpaid.")
            }
            rows.append(contentsOf: page.orders)
            cursor = page.nextCursor
            if let cursor, !seen.insert(cursor).inserted || seen.count > 1000 { throw PaymentsAPIError.invalidResponse }
        } while cursor != nil
        return rows
    }

    // MARK: Transport

    private func send<Response: Decodable, Body: Encodable>(
        _ path: String,
        method: String,
        body: Body?,
        idempotencyKey: String? = nil,
        ifMatch: Int? = nil
    ) async throws -> Response {
        let bodyData = try body.map { try encoder.encode($0) }
        let (data, http) = try await perform(path, method: method, bodyData: bodyData, idempotencyKey: idempotencyKey, ifMatch: ifMatch)
        guard (200..<300).contains(http.statusCode) else { throw mapError(status: http.statusCode, data: data) }
        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw PaymentsAPIError.invalidResponse
        }
    }

    private func perform(_ path: String, method: String, bodyData: Data?, idempotencyKey: String?, ifMatch: Int?) async throws -> (Data, HTTPURLResponse) {
        let selectedCredentials = path.hasPrefix("v1/admin/") ? operatorCredentials : credentials
        guard let token = try selectedCredentials.load() else {
            throw PaymentsAPIError.configuration(path.hasPrefix("v1/admin/") ? "Separate operator pairing is required for LIVE administration." : "Payment device pairing is required.")
        }
        guard let url = configuration.url(for: path) else {
            throw PaymentsAPIError.configuration("The payments URL is invalid.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        if let idempotencyKey { request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key") }
        if let ifMatch { request.setValue(String(ifMatch), forHTTPHeaderField: "If-Match") }
        request.httpBody = bodyData
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw PaymentsAPIError.invalidResponse }
            return (data, http)
        } catch let error as PaymentsAPIError {
            throw error
        } catch {
            // For reads this is simply "unreachable"; for writes the server may have committed.
            throw method == "GET" ? PaymentsAPIError.unavailable : PaymentsAPIError.outcomeUnknown
        }
    }

    private func mapError(status: Int, data: Data) -> PaymentsAPIError {
        let body = try? decoder.decode(APIErrorBody.self, from: data)
        if status == 401 { return .unauthorized }
        if let code = body?.error {
            return .rejected(code: code, message: body?.message ?? "The request was rejected.", status: status, details: data)
        }
        if status == 403 { return .unauthorized }
        return status >= 500 ? .unavailable : .rejected(code: "rejected", message: "The request was rejected.", status: status, details: data)
    }
}

nonisolated struct PrintProgressRecord: Encodable, Sendable {
    let batchID: String
    let entitlementId: String
    let sessionId: String
    let receiptFingerprint: String
    let copyIndex: Int
    let outcome: String
    let transport: String
    let idempotencyKey: String

    enum CodingKeys: String, CodingKey {
        case entitlementId, sessionId, receiptFingerprint, copyIndex, outcome, transport, idempotencyKey
    }
}

nonisolated struct DeviceInfoResponse: Decodable, Sendable {
    struct Device: Decodable, Sendable { let id: String; let accountId: String; let displayName: String?; let scopes: [String] }
    let device: Device
    let environment: String
    let serverTime: Date
}

nonisolated struct ActiveEventResponse: Decodable, Sendable {
    struct InactiveEvent: Decodable, Sendable { let id: String; let name: String; let lifecycle: String }
    let event: ServerEventPolicy?
    let inactiveEvent: InactiveEvent?
    let offlinePolicy: SignedOfflinePolicy?
    let offlinePolicyStatus: String?
    let device: PaymentDeviceIdentity
    let serverTime: Date
}

nonisolated struct OperatorEventSummary: Codable, Identifiable, Sendable, Hashable {
    let id: String
    let name: String
    let venue: String
    let lifecycle: String
    let activePolicyRevisionId: String?
    let version: Int
    let updatedAt: Date
    var activeRevision: Int? = nil
    var activeUnitPriceCentavos: Int? = nil
}
nonisolated struct OperatorEventListResponse: Codable, Sendable { let events: [OperatorEventSummary]; let nextCursor: String? }
nonisolated struct OperatorCreatedEvent: Codable, Sendable { let id: String; let lifecycle: String; var version: Int? = nil }
nonisolated struct OperatorEventTransition: Codable, Sendable { let id: String; let lifecycle: String; var activePolicyRevisionId: String? = nil; var version: Int? = nil }

nonisolated struct OperatorPolicyRevision: Codable, Equatable, Sendable {
    let id: String
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
    let createdAt: Date
    let activatedAt: Date?
}

nonisolated struct OperatorEventDetail: Codable, Sendable {
    struct Event: Codable, Sendable {
        let id: String; let name: String; let venue: String; let lifecycle: CommercialEventLifecycle; let version: Int
        let updatedAt: Date; let activePolicyRevisionId: String?
    }
    let event: Event
    let activePolicy: OperatorPolicyRevision?
    let latestRevision: OperatorPolicyRevision?
    let hasUnpublishedRevision: Bool
    let outstandingEntitlements: Int
    let serverTime: Date
}

nonisolated struct OperatorEventUpdate: Codable, Sendable { let eventId: String; let version: Int; let draftRevision: OperatorPolicyRevision? }
nonisolated struct OperatorVersionConflict: Decodable, Sendable { let currentVersion: Int? }
nonisolated struct OperatorPrintUtilization: Codable, Sendable { let purchased: Int; let confirmed: Int; let uncertain: Int; let failed: Int; var notStarted: Int? = nil; var delivered: Int? = nil }
nonisolated struct OperatorCashReconciliation: Codable, Sendable { let countedCentavos: Int; let provisional: Bool; let createdAt: Date; let varianceCentavos: Int }
nonisolated struct OperatorSalesSummary: Codable, Sendable {
    let eventId: String; let currency: String; let verifiedQRPhLiveCentavos: Int; let verifiedQRPhTestCentavos: Int
    let cashSelfReportedCentavos: Int; let qrSessions: Int; let cashSessions: Int
    let physicalCashCount: OperatorCashReconciliation?; let printUtilization: OperatorPrintUtilization; let settlementStatus: String
    var cashSelfReportedOnlineCentavos: Int? = nil
    var cashSelfReportedOfflineSyncedCentavos: Int? = nil
    /// Attendant-confirmed cash (operator authenticated). Nil from services that predate it.
    var cashOperatorConfirmedCentavos: Int? = nil
    var unresolvedQRCount: Int? = nil
    var lateQRPaidReviewCentavos: Int? = nil
    var reviewOrderCount: Int? = nil
    var offlineConflictCount: Int? = nil
}
nonisolated struct OperatorOrderRow: Codable, Identifiable, Sendable {
    let id: String; let createdAt: Date; let boothFormat: String; let copies: Int; let totalCentavos: Int; let state: String
    let method: String?; let paymentState: String?; let category: String; let entitlementState: String?
    let confirmedPrints: Int; let uncertainPrints: Int; let lastReconcileError: String?
    var sessionId: String? = nil
    var checkoutSessionId: String? = nil
    var supersededByOrderId: String? = nil
}
nonisolated struct OperatorOrderPage: Codable, Sendable {
    let orders: [OperatorOrderRow]; let nextCursor: String?
    var checkoutSessionIdentityIncluded: Bool? = nil
}
nonisolated struct OperatorOfflineConflict: Codable, Identifiable, Sendable {
    let localEventId: String; let localSequence: Int?; let deviceId: String; let sessionId: String?; let copies: Int?
    let unitPriceCentavos: Int?; let declaredAt: Date?; let reason: String; let receivedAt: Date
    var id: String { "\(deviceId)-\(localEventId)" }
}
nonisolated struct OperatorDiagnostics: Codable, Sendable {
    let environment: String; let liveEnabled: Bool; let offlineSigningConfigured: Bool; let unresolvedIntentCount: Int
    let oldestUnresolvedAt: Date?; let reviewOrderCount: Int; let offlineConflictCount: Int
}
nonisolated struct OperatorCashCount: Codable, Sendable { let id: String; let countedCentavos: Int; let provisional: Bool; let createdAt: Date }
nonisolated private struct OperatorCreateEventBody: Codable, Sendable { let name: String; let venue: String }
nonisolated private struct OperatorTransitionBody: Codable, Sendable { let policyRevisionId: String?; let acknowledgedUnitPriceCentavos: Int? }
nonisolated private struct OperatorCashCountBody: Codable, Sendable { let countedCentavos: Int; let reason: String; let pendingLocalCount: Int }

nonisolated private struct EmptyBody: Codable, Sendable {}
nonisolated private struct IgnoredResponse: Decodable, Sendable {}
nonisolated private struct APIErrorBody: Decodable, Sendable {
    let error: String?
    let message: String?
}

/// Operator's editable copy of a server policy. Prices are edited in pesos and sent as centavos.
nonisolated struct ServerPolicyDraft: Codable, Equatable, Sendable {
    var commercialMode: CommercialEventMode = .payPerPrint
    var priceText = ""
    var maxCopies = 3
    var defaultCopies = 1
    var qrPhEnabled = true
    var cashEnabled = false {
        didSet {
            if !cashEnabled {
                offlineCashEnabled = false
            }
        }
    }
    var prepaidGuestCopyChoice = false
    var supportedFormats: Set<String> = Set(BoothFormat.allCases.map(\.rawValue))
    var offlineCashEnabled = false
    var offlineValidUntil = Date().addingTimeInterval(12 * 60 * 60)

    struct RequestBody: Encodable, Equatable, Sendable {
        let commercialMode: String
        let unitPriceCentavos: Int
        let maxCopies: Int
        let defaultCopies: Int
        let cashEnabled: Bool
        let qrphEnabled: Bool
        let prepaidGuestCopyChoice: Bool
        let supportedFormats: [String]
        let features: [String: String]
        let offlineValidUntil: Date?
    }

    init() {}

    init(revision: OperatorPolicyRevision) {
        commercialMode = revision.commercialMode
        priceText = revision.commercialMode == .payPerPrint ? PesoAmount.editingText(centavos: revision.unitPriceCentavos) : ""
        maxCopies = revision.maxCopies
        defaultCopies = revision.defaultCopies
        qrPhEnabled = revision.qrphEnabled
        cashEnabled = revision.cashEnabled
        prepaidGuestCopyChoice = revision.prepaidGuestCopyChoice
        supportedFormats = Set(revision.supportedFormats)
        offlineCashEnabled = revision.cashEnabled && revision.offlineValidUntil != nil
        offlineValidUntil = revision.offlineValidUntil ?? Date().addingTimeInterval(12 * 60 * 60)
    }

    var unitPriceCentavos: Int? {
        commercialMode == .privatePrepaid ? 0 : PesoAmount.centavos(fromPesoText: priceText)
    }

    func supports(_ format: BoothFormat) -> Bool { format.paymentRawValue(in: Array(supportedFormats)) != nil }
    mutating func setFormat(_ format: BoothFormat, enabled: Bool) {
        if enabled {
            if !supports(format) { supportedFormats.insert(format.rawValue) }
        } else {
            supportedFormats.remove(format.rawValue)
            if format == .passport { supportedFormats.remove("photoPass") }
        }
    }

    func matchesForEditing(_ other: ServerPolicyDraft) -> Bool {
        var left = self, right = other
        if !left.offlineCashEnabled { left.offlineValidUntil = .distantPast }
        if !right.offlineCashEnabled { right.offlineValidUntil = .distantPast }
        return left == right
    }

    func validationMessage(now: Date = Date()) -> String? {
        guard PaymentPolicySnapshot.copyRange.contains(maxCopies), (1...maxCopies).contains(defaultCopies) else {
            return "Default copies must be between 1 and the maximum (up to 10)."
        }
        guard !supportedFormats.isEmpty else { return "Enable at least one format." }
        guard commercialMode == .payPerPrint else { return nil }
        guard let centavos = unitPriceCentavos, centavos > 0 else {
            return "Enter a price in pesos with at most two decimals, from ₱0.01 to ₱100,000.00."
        }
        guard qrPhEnabled || cashEnabled else { return "Enable QR Ph, Cash, or both." }
        // PayMongo's QR Ph minimum is PHP 1.00 per transaction; one copy must meet it.
        if qrPhEnabled && centavos < 100 { return "QR Ph needs a price of at least ₱1.00 per copy." }
        if offlineCashEnabled {
            guard cashEnabled else { return "Offline cash requires Cash to be enabled." }
            guard offlineValidUntil > now else { return "The offline cash limit must be in the future." }
        }
        return nil
    }

    func requestBody(now: Date = Date()) -> RequestBody? {
        guard validationMessage(now: now) == nil, let centavos = unitPriceCentavos else { return nil }
        let paid = commercialMode == .payPerPrint
        return RequestBody(
            commercialMode: commercialMode.rawValue,
            unitPriceCentavos: centavos,
            maxCopies: maxCopies,
            defaultCopies: defaultCopies,
            cashEnabled: paid && cashEnabled,
            qrphEnabled: paid && qrPhEnabled,
            prepaidGuestCopyChoice: !paid && prepaidGuestCopyChoice,
            supportedFormats: BoothFormat.allCases.flatMap { $0 == .passport ? ["passport", "photoPass"] : [$0.rawValue] }.filter(supportedFormats.contains),
            features: [:],
            offlineValidUntil: paid && cashEnabled && offlineCashEnabled ? offlineValidUntil : nil
        )
    }
}
