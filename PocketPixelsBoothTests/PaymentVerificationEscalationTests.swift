import XCTest
import SwiftUI
@testable import PocketPixelsBooth

/// P2: an uncertain guest gets useful guidance; no timer ever decides a payment outcome.
@MainActor final class PaymentVerificationEscalationTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_760_000_000)

    func testReconciliationEscalatesByTimeWithoutChangingTheCheckout() {
        var clock = PaymentVerificationClock()
        clock.begin(key: "PP-1#0", now: t0)
        XCTAssertEqual(clock.stage(now: t0.addingTimeInterval(10), qrExpiresAt: nil), .checking)
        XCTAssertEqual(clock.stage(now: t0.addingTimeInterval(45), qrExpiresAt: nil), .delayed)
        XCTAssertEqual(clock.stage(now: t0.addingTimeInterval(179), qrExpiresAt: nil), .delayed)
        XCTAssertEqual(clock.stage(now: t0.addingTimeInterval(180), qrExpiresAt: nil), .attendantRequired)
    }

    func testAnUnexpiredQRIsNeverReportedAsSlow() {
        var clock = PaymentVerificationClock()
        clock.begin(key: "PP-1#0", now: t0)
        let expiry = t0.addingTimeInterval(300)
        XCTAssertEqual(clock.stage(now: t0.addingTimeInterval(250), qrExpiresAt: expiry), .checking, "The guest may still be paying")
        XCTAssertEqual(clock.stage(now: expiry.addingTimeInterval(44), qrExpiresAt: expiry), .checking)
        XCTAssertEqual(clock.stage(now: expiry.addingTimeInterval(45), qrExpiresAt: expiry), .delayed, "Expired but unconfirmed: may have been paid")
        XCTAssertEqual(clock.stage(now: expiry.addingTimeInterval(180), qrExpiresAt: expiry), .attendantRequired)
    }

    func testOfflineFailuresEscalateAndRecoveryOnlineResetsTheFailureCount() {
        var clock = PaymentVerificationClock()
        clock.begin(key: "PP-1#0", now: t0)
        for _ in 0..<3 { clock.recordFailure() }
        XCTAssertEqual(clock.stage(now: t0.addingTimeInterval(5), qrExpiresAt: nil), .delayed)
        clock.recordResponse(reviewHeld: false)   // back online
        XCTAssertEqual(clock.stage(now: t0.addingTimeInterval(6), qrExpiresAt: nil), .checking)
        for _ in 0..<15 { clock.recordFailure() }
        XCTAssertEqual(clock.stage(now: t0.addingTimeInterval(30), qrExpiresAt: nil), .attendantRequired)
    }

    func testServerReviewHoldNeedsTheAttendantImmediately() {
        var clock = PaymentVerificationClock()
        clock.begin(key: "PP-1#0", now: t0)
        clock.recordResponse(reviewHeld: true)
        XCTAssertEqual(clock.stage(now: t0, qrExpiresAt: nil), .attendantRequired)
    }

    func testForegroundRestartKeepsTheClockAndANewCheckoutRestartsIt() {
        var clock = PaymentVerificationClock()
        clock.begin(key: "PP-1#0", now: t0)
        clock.begin(key: "PP-1#0", now: t0.addingTimeInterval(100))   // app returned to foreground; polling restarted
        XCTAssertEqual(clock.startedAt, t0, "Backgrounding never resets the guest's wait or starts a different checkout")
        XCTAssertEqual(clock.stage(now: t0.addingTimeInterval(100), qrExpiresAt: nil), .delayed)
        clock.begin(key: "PP-1#1", now: t0.addingTimeInterval(200))   // deliberate new checkout after a confirmed unpaid QR
        XCTAssertEqual(clock.stage(now: t0.addingTimeInterval(201), qrExpiresAt: nil), .checking)
        clock.begin(key: "PP-2#0", now: t0.addingTimeInterval(300))   // next guest
        XCTAssertEqual(clock.consecutiveFailures, 0)
    }

    func testStagesNeverOfferPaymentAndAlwaysSayDoNotPayAgainWhenUncertain() {
        for stage in [PaymentVerificationStage.delayed, .attendantRequired] {
            XCTAssertTrue(stage.guidance.contains("Do not pay again") || stage.guidance.contains("do not pay again"), stage.title)
            XCTAssertFalse(stage.guidance.localizedCaseInsensitiveContains("cash"), "Never suggests a cash fallback")
        }
    }

    func testEscalatedQRScreenRendersInPortraitAndLandscape() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        for stage in [PaymentVerificationStage.delayed, .attendantRequired] {
            for size in [CGSize(width: 834, height: 1194), CGSize(width: 1194, height: 834)] {
                let view = QRPhPaymentContent(totalCentavos: 15000, copies: 3, image: nil, hasImagePayload: true, expiresAt: t0, verificationStage: stage)
                let host = UIHostingController(rootView: view)
                let window = UIWindow(windowScene: scene); window.frame = CGRect(origin: .zero, size: size)
                window.rootViewController = host; window.makeKeyAndVisible()
                try await Task.sleep(for: .milliseconds(200))
                host.view.layoutIfNeeded()
                let image = UIGraphicsImageRenderer(size: size).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
                XCTAssertGreaterThan(image.pngData()?.count ?? 0, 15_000, "\(stage) \(size) rendered blank")
                window.isHidden = true
            }
        }
    }
}
