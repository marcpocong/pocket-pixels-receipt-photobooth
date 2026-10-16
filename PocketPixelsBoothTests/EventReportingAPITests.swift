import XCTest
@testable import PocketPixelsBooth

private final class ReportStubProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, Data, [String: String]))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (code, data, headers) = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { }
}
private struct ReportCredential: PaymentCredentialProviding { func load() throws -> String? { String(repeating: "f", count: 40) } }

@MainActor final class EventReportingAPITests: XCTestCase {
    private func client() -> PaymentsAPIClient {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ReportStubProtocol.self]
        return PaymentsAPIClient(configuration: PaymentsConfiguration(baseURL: URL(string: "https://synthetic.example.test")!, environment: "test"),
                                 credentialStore: ReportCredential(), operatorCredentialStore: ReportCredential(), session: URLSession(configuration: config))
    }
    override func tearDown() { ReportStubProtocol.handler = nil }
    nonisolated private func event(_ id: String) -> String {
        #"{"id":"\#(id)","name":"Synthetic","venue":"","lifecycle":"ARCHIVED","version":1,"updated_at":"2026-10-16T00:00:00.000Z"}"#
    }
    func testEventListLoadsAllPagesIncludingArchivedHistory() async throws {
        var page = 0
        ReportStubProtocol.handler = { request in
            page += 1
            if page == 1 { return (200, Data(#"{"events":[\#(self.event("first"))],"nextCursor":"page-two"}"#.utf8), [:]) }
            XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "cursor" }?.value, "page-two")
            return (200, Data(#"{"events":[\#(self.event("last"))],"nextCursor":null}"#.utf8), [:])
        }
        let events = try await client().listEvents()
        XCTAssertEqual(events.map(\.id), ["first", "last"]); XCTAssertEqual(page, 2)
    }
    func testRepeatedPaginationCursorFailsInsteadOfSilentTruncation() async {
        ReportStubProtocol.handler = { _ in (200, Data(#"{"events":[],"nextCursor":"repeated"}"#.utf8), [:]) }
        do { _ = try await client().listEvents(); XCTFail("Incomplete history must fail") } catch { }
    }
    func testCSVLoadsEveryPageAndIncludesHeaderOnlyOnce() async throws {
        var page = 0
        ReportStubProtocol.handler = { _ in
            page += 1
            return (200, Data("order_id,amount\r\n\(page),5000\r\n".utf8), page == 1
                    ? ["x-export-complete": "false", "x-export-next-cursor": "next"] : ["x-export-complete": "true"])
        }
        let csv = String(decoding: try await client().completeEventCSV(eventID: "synthetic"), as: UTF8.self)
        XCTAssertEqual(csv, "order_id,amount\r\n1,5000\r\n2,5000\r\n")
        XCTAssertEqual(page, 2)
    }
    func testIncompleteCSVWithoutNextCursorIsNotOfferedAsComplete() async {
        ReportStubProtocol.handler = { _ in (200, Data("id\r\npartial\r\n".utf8), ["x-export-complete": "false"]) }
        do { _ = try await client().completeEventCSV(eventID: "synthetic"); XCTFail("Partial export must fail") } catch { }
    }
    func testFailedSummaryAndWrongCredentialThrowInsteadOfBecomingZero() async {
        for status in [401, 503] {
            ReportStubProtocol.handler = { _ in (status, Data(#"{"error":"unavailable","message":"synthetic refusal"}"#.utf8), [:]) }
            do { _ = try await client().eventSummary(id: "synthetic"); XCTFail("Unavailable financial totals must not become zero") } catch { }
        }
    }
    func testDeliveredPrintCountIsDecodedWithoutEquatingItToSensorConfirmation() throws {
        let json = #"{"purchased":3,"confirmed":0,"delivered":2,"uncertain":1,"failed":0,"notStarted":0}"#
        let utilization = try PaymentsAPIClient.makeDecoder().decode(OperatorPrintUtilization.self, from: Data(json.utf8))
        XCTAssertEqual(utilization.delivered, 2); XCTAssertEqual(utilization.confirmed, 0)
        let legacy = try PaymentsAPIClient.makeDecoder().decode(OperatorPrintUtilization.self, from: Data(#"{"purchased":1,"confirmed":1,"uncertain":0,"failed":0}"#.utf8))
        XCTAssertNil(legacy.delivered)
    }
    func testRunOrderQueryCompletesAllPagesIncludingExactSessionIDs() async throws {
        var page = 0
        ReportStubProtocol.handler = { _ in
            page += 1
            let row = #"{"id":"order-\#(page)","created_at":"2026-10-16T00:00:00.000Z","booth_format":"solo","copies":1,"total_centavos":5000,"state":"COMPLETE","category":"QRPH_VERIFIED_TEST","confirmed_prints":0,"uncertain_prints":0,"session_id":"exact-session"}"#
            let next = page == 1 ? "\"next\"" : "null"
            return (200, Data("{\"orders\":[\(row)],\"nextCursor\":\(next)}".utf8), [:])
        }
        let rows = try await client().allEventOrders(id: "synthetic")
        XCTAssertEqual(rows.map(\.id), ["order-1", "order-2"])
        XCTAssertTrue(rows.allSatisfy { $0.sessionId == "exact-session" })
    }

    func testExactRunPaymentsRequireExplicitBackendCapabilityInsteadOfReturningMisleadingZero() async throws {
        ReportStubProtocol.handler = { _ in (200, Data(#"{"orders":[],"nextCursor":null}"#.utf8), [:]) }
        do { _ = try await client().allEventOrders(id: "synthetic", requireCheckoutIdentity: true); XCTFail("Old report shape must not look like zero run revenue") } catch { }
        ReportStubProtocol.handler = { _ in (200, Data(#"{"orders":[],"nextCursor":null,"checkoutSessionIdentityIncluded":true}"#.utf8), [:]) }
        let rows = try await client().allEventOrders(id: "synthetic", requireCheckoutIdentity: true)
        XCTAssertTrue(rows.isEmpty, "An authoritative complete empty report is distinct from unsupported reporting")
    }

}
