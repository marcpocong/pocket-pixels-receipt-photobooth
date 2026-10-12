import Foundation
import Testing
@testable import PocketPixelsBooth

@Suite("Operator authentication", .serialized)
@MainActor struct OperatorAuthenticationTests {
    @Test func deniedAuthenticationNeverGrantsAccessAndCanRetry() async {
        let permit = OperatorAccessPermit()
        var accepted = false
        let authentication = OperatorAuthentication(permit: permit, evaluate: { accepted })
        await authentication.unlock()
        #expect(!authentication.isUnlocked)
        #expect(!permit.isAuthorized)
        accepted = true
        await authentication.unlock()
        #expect(authentication.isUnlocked)
        #expect(permit.isAuthorized)
        authentication.lock()
        #expect(!authentication.isUnlocked)
        #expect(!permit.isAuthorized)
    }

    @Test func authenticationFailureAllowsOwnerRecovery() async {
        let permit = OperatorAccessPermit()
        var fails = true
        let authentication = OperatorAuthentication(permit: permit, evaluate: {
            if fails { throw URLError(.cancelled) }
            return true
        })
        await authentication.unlock()
        #expect(!permit.isAuthorized)
        #expect(!authentication.isAuthenticating)
        fails = false
        await authentication.unlock()
        #expect(authentication.isUnlocked)
    }

    @Test func backgroundLockRejectsLateAuthenticationResult() async {
        let permit = OperatorAccessPermit()
        var completion: CheckedContinuation<Bool, Never>?
        let authentication = OperatorAuthentication(permit: permit, evaluate: {
            await withCheckedContinuation { completion = $0 }
        })
        let attempt = Task { await authentication.unlock() }
        while completion == nil { await Task.yield() }
        authentication.lock()
        completion?.resume(returning: true)
        await attempt.value
        #expect(!authentication.isUnlocked)
        #expect(!permit.isAuthorized)
    }

    @Test func liveAdministrationCannotReuseBoothCredential() throws {
        let permit = OperatorAccessPermit()
        let configuration = PaymentsConfiguration(baseURL: URL(string: "https://\(UUID().uuidString).example.test")!, environment: "live")
        let store = PaymentOperatorCredentialStore(configuration: configuration,
            testFallback: PaymentPairingCredential(token: String(repeating: "b", count: 40)), permit: permit)
        #expect(throws: PaymentsAPIError.unauthorized) { try store.load() }
        permit.authorize()
        #expect(try store.load() == nil)
        permit.revoke()
        #expect(throws: PaymentsAPIError.unauthorized) { try store.save(String(repeating: "o", count: 40)) }
    }

    @Test func existingTestCredentialRequiresOperatorAuthentication() throws {
        let permit = OperatorAccessPermit()
        let token = String(repeating: "b", count: 40)
        let configuration = PaymentsConfiguration(baseURL: URL(string: "https://\(UUID().uuidString).example.test")!, environment: "test")
        let store = PaymentOperatorCredentialStore(configuration: configuration,
            testFallback: PaymentPairingCredential(token: token), permit: permit)
        #expect(throws: PaymentsAPIError.unauthorized) { try store.load() }
        permit.authorize()
        #expect(try store.load() == token)
    }

    @Test func apiRoutesUseSeparateBoothAndOperatorCredentials() async throws {
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [OperatorCredentialProtocol.self]
        let api = PaymentsAPIClient(configuration: PaymentsConfiguration(baseURL: URL(string: "https://payments.example.test")!, environment: "live"),
            credentialStore: PaymentPairingCredential(token: "booth-fixture"),
            operatorCredentialStore: PaymentPairingCredential(token: "operator-fixture"),
            session: URLSession(configuration: sessionConfiguration))
        _ = try await api.device()
        _ = try await api.listEvents()
    }

    @Test func explicitPasscodeUsesPasscodeAuthenticationOnly() async {
        let permit = OperatorAccessPermit()
        var biometricRequests = 0
        var passcodeRequests = 0
        let authentication = OperatorAuthentication(permit: permit, evaluate: {
            biometricRequests += 1
            return false
        }, evaluatePasscode: {
            passcodeRequests += 1
            return true
        })
        await authentication.unlock(usingPasscode: true)
        #expect(biometricRequests == 0)
        #expect(passcodeRequests == 1)
        #expect(authentication.isUnlocked)
        authentication.lock()
        #expect(!permit.isAuthorized)
    }
}

private final class OperatorCredentialProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let admin = request.url?.path.hasPrefix("/v1/admin/") == true
        let expected = admin ? "Bearer operator-fixture" : "Bearer booth-fixture"
        #expect(request.value(forHTTPHeaderField: "Authorization") == expected)
        let body = admin ? #"{"events":[],"nextCursor":null}"# :
            #"{"device":{"id":"booth","accountId":"account","displayName":"Booth","scopes":["booth"]},"environment":"live","serverTime":"2026-10-13T00:00:00.000Z"}"#
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
