import Foundation
import Security

nonisolated struct PaymentsConfiguration: Sendable {
    let baseURL: URL
    let environment: String

    static var bundled: PaymentsConfiguration? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "PAYMENTS_API_BASE_URL") as? String,
              let url = URL(string: raw),
              url.scheme == "https" else {
            return nil
        }
        let environment = (Bundle.main.object(forInfoDictionaryKey: "PAYMENTS_ENVIRONMENT") as? String) ?? "test"
        return PaymentsConfiguration(baseURL: url, environment: environment)
    }
}

nonisolated struct PaymentDeviceCredentialStore: Sendable {
    private let service = "com.pocketpixels.payments"
    private let account = "device-token"

    func save(_ token: String) throws {
        let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count >= 32, let data = value.data(using: .utf8) else {
            throw PaymentsAPIError.configuration("The device credential is invalid.")
        }
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        item[kSecValueData as String] = data
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
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

nonisolated enum PaymentsAPIError: Error, LocalizedError, Sendable {
    case configuration(String)
    case unauthorized
    case rejected(String)
    case unavailable
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .configuration(let message), .rejected(let message): message
        case .unauthorized: "This iPad is not authorized for payments."
        case .unavailable: "The payments service is unavailable. QR Ph cannot start."
        case .invalidResponse: "The payments service returned an invalid response."
        }
    }
}

actor PaymentsAPIClient {
    private struct APIEnvelope<Value: Decodable>: Decodable {
        let order: Value
    }

    private struct CreateOrderBody: Encodable {
        let eventId: String
        let format: String
        let copies: Int
        let idempotencyKey: String
    }

    private struct ClaimBody: Encodable {
        let sessionId: String
        let idempotencyKey: String
    }

    private let configuration: PaymentsConfiguration
    private let credentialStore: PaymentDeviceCredentialStore
    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        configuration: PaymentsConfiguration,
        credentialStore: PaymentDeviceCredentialStore = PaymentDeviceCredentialStore(),
        session: URLSession = .shared
    ) {
        self.configuration = configuration
        self.credentialStore = credentialStore
        self.session = session
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.keyDecodingStrategy = .convertFromSnakeCase
    }

    func createOrder(eventID: String, format: BoothFormat, copies: Int, idempotencyKey: String) async throws -> PaymentOrder {
        let body = CreateOrderBody(eventId: eventID, format: format.rawValue, copies: copies, idempotencyKey: idempotencyKey)
        let response: APIEnvelope<PaymentOrder> = try await send("v1/orders", method: "POST", body: body, idempotencyKey: idempotencyKey)
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

    func status(orderID: String) async throws -> PaymentStatusResponse {
        try await send("v1/orders/\(orderID)/status", method: "GET", body: Optional<EmptyBody>.none)
    }

    func claim(entitlementID: String, sessionID: String, idempotencyKey: String) async throws -> CheckoutEntitlement {
        struct Response: Decodable { let entitlement: CheckoutEntitlement }
        let body = ClaimBody(sessionId: sessionID, idempotencyKey: idempotencyKey)
        let response: Response = try await send("v1/entitlements/\(entitlementID)/claim", method: "POST", body: body, idempotencyKey: idempotencyKey)
        return response.entitlement
    }

    func listEvents() async throws -> [OperatorEventSummary] {
        let response: OperatorEventListResponse = try await send("v1/admin/events?limit=100", method: "GET", body: Optional<EmptyBody>.none)
        return response.events
    }

    func createEvent(name: String, venue: String) async throws -> OperatorCreatedEvent {
        try await send("v1/admin/events", method: "POST", body: OperatorCreateEventBody(name: name, venue: venue))
    }

    func transitionEvent(id: String, action: String, policyRevisionID: String? = nil) async throws -> OperatorEventTransition {
        try await send("v1/admin/events/\(id)/\(action)", method: "POST", body: OperatorTransitionBody(policyRevisionId: policyRevisionID))
    }

    func eventSummary(id: String) async throws -> OperatorSalesSummary {
        try await send("v1/admin/events/\(id)/summary", method: "GET", body: Optional<EmptyBody>.none)
    }

    func recordCashCount(eventID: String, countedCentavos: Int, reason: String) async throws -> OperatorCashCount {
        try await send("v1/admin/events/\(eventID)/cash-counts", method: "POST", body: OperatorCashCountBody(countedCentavos: countedCentavos, reason: reason))
    }

    func exportCSV(eventID: String) async throws -> Data {
        try await sendData("v1/admin/events/\(eventID)/export.csv")
    }

    private func send<Response: Decodable, Body: Encodable>(
        _ path: String,
        method: String,
        body: Body?,
        idempotencyKey: String? = nil
    ) async throws -> Response {
        guard let token = try credentialStore.load() else {
            throw PaymentsAPIError.configuration("Payment device pairing is required.")
        }
        let url = configuration.baseURL.appending(path: path)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 20
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        if let idempotencyKey {
            request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        }
        if let body {
            request.httpBody = try encoder.encode(body)
        }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw PaymentsAPIError.invalidResponse }
            switch http.statusCode {
            case 200..<300:
                return try decoder.decode(Response.self, from: data)
            case 401, 403:
                throw PaymentsAPIError.unauthorized
            case 400..<500:
                let message = (try? decoder.decode(APIErrorBody.self, from: data).message) ?? "The request was rejected."
                throw PaymentsAPIError.rejected(message)
            default:
                throw PaymentsAPIError.unavailable
            }
        } catch let error as PaymentsAPIError {
            throw error
        } catch {
            throw PaymentsAPIError.unavailable
        }
    }

    private func sendData(_ path: String) async throws -> Data {
        guard let token = try credentialStore.load() else { throw PaymentsAPIError.configuration("Payment device pairing is required.") }
        var request = URLRequest(url: configuration.baseURL.appending(path: path))
        request.timeoutInterval = 20
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw PaymentsAPIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw http.statusCode == 401 || http.statusCode == 403 ? PaymentsAPIError.unauthorized : PaymentsAPIError.unavailable }
        return data
    }
}

nonisolated struct OperatorEventSummary: Codable, Identifiable, Sendable {
    let id: String
    let name: String
    let venue: String
    let lifecycle: String
    let activePolicyRevisionId: String?
    let version: Int
    let updatedAt: Date
}
nonisolated struct OperatorEventListResponse: Codable, Sendable { let events: [OperatorEventSummary]; let nextCursor: String? }
nonisolated struct OperatorCreatedEvent: Codable, Sendable { let id: String; let lifecycle: String }
nonisolated struct OperatorEventTransition: Codable, Sendable { let id: String; let lifecycle: String }
nonisolated struct OperatorPrintUtilization: Codable, Sendable { let purchased: Int; let confirmed: Int; let uncertain: Int; let failed: Int }
nonisolated struct OperatorCashReconciliation: Codable, Sendable { let countedCentavos: Int; let provisional: Bool; let createdAt: Date; let varianceCentavos: Int }
nonisolated struct OperatorSalesSummary: Codable, Sendable {
    let eventId: String; let currency: String; let verifiedQRPhLiveCentavos: Int; let verifiedQRPhTestCentavos: Int
    let cashSelfReportedCentavos: Int; let qrSessions: Int; let cashSessions: Int
    let physicalCashCount: OperatorCashReconciliation?; let printUtilization: OperatorPrintUtilization; let settlementStatus: String
}
nonisolated struct OperatorCashCount: Codable, Sendable { let id: String; let countedCentavos: Int; let provisional: Bool; let createdAt: Date }
nonisolated private struct OperatorCreateEventBody: Codable, Sendable { let name: String; let venue: String }
nonisolated private struct OperatorTransitionBody: Codable, Sendable { let policyRevisionId: String? }
nonisolated private struct OperatorCashCountBody: Codable, Sendable { let countedCentavos: Int; let reason: String }

nonisolated private struct EmptyBody: Codable, Sendable {}
nonisolated private struct APIErrorBody: Decodable, Sendable {
    let message: String?
}
