import XCTest
import UIKit
@testable import PocketPixelsBooth

@MainActor final class GallerySchedulerV2Tests: XCTestCase {
    private func result(_ token: String) -> GalleryUploadResult {
        GalleryUploadResult(galleryToken: token, galleryURL: URL(string: "https://example.test/?g=\(token)")!, status: .existingComplete)
    }

    func testFreshArrivalTakesNextSafeSlotAndRecoveryCannotStarve() async throws {
        let scheduler = GalleryUploadScheduler()
        var order: [String] = []
        var finish: CheckedContinuation<Void, Never>?
        let started = expectation(description: "in flight")
        let first = Task {
            try await scheduler.perform(token: "old-active", priority: .recovery) {
                order.append("old-active"); started.fulfill()
                await withCheckedContinuation { finish = $0 }
                return self.result("old-active")
            }
        }
        await fulfillment(of: [started])
        let old = Task { try await scheduler.perform(token: "old-waiting", priority: .recovery) { order.append("old-waiting"); return self.result("old-waiting") } }
        let guests = (1...5).map { index in Task {
            let token = "guest-\(index)"
            return try await scheduler.perform(token: token) { order.append(token); return self.result(token) }
        } }
        // Let every request enqueue while the first operation still owns the transmission.
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(order, ["old-active"], "No preemption of an uncertain in-flight request")
        finish?.resume()
        _ = try await first.value; _ = try await old.value
        for guest in guests { _ = try await guest.value }
        XCTAssertTrue(order[1].hasPrefix("guest"))
        XCTAssertLessThanOrEqual(try XCTUnwrap(order.firstIndex(of: "old-waiting")), 3)
    }

    func testSequentialRecoveryGetsFairSlotAmongImmediatelyCompletedFreshJobs() async throws {
        let scheduler = GalleryUploadScheduler()
        var order: [String] = [], finish: CheckedContinuation<Void, Never>?
        let started = expectation(description: "old gallery active")
        let recovery = Task {
            for index in 0..<2 {
                let token = "old-\(index)"
                _ = try await scheduler.perform(token: token, priority: .recovery) {
                    order.append(token)
                    if index == 0 {
                        started.fulfill()
                        await withCheckedContinuation { finish = $0 }
                    }
                    return self.result(token)
                }
            }
        }
        await fulfillment(of: [started])
        let guests = (0..<20).map { index in Task {
            let token = "fresh-\(index)"
            return try await scheduler.perform(token: token) { order.append(token); return self.result(token) }
        } }
        for _ in 0..<30 { await Task.yield() }
        finish?.resume()
        _ = try await recovery.value
        for guest in guests { _ = try await guest.value }
        XCTAssertLessThanOrEqual(try XCTUnwrap(order.firstIndex(of: "old-1")), 3,
            "Sequential durable recovery participates before all immediate cached jobs drain")
    }

    func testReconnectSignalsCoalesceWithoutCompetingRecoveryPasses() async {
        let scheduler = GalleryUploadScheduler()
        var calls = 0, active = 0, peak = 0
        var finish: CheckedContinuation<Void, Never>?
        let started = expectation(description: "single recovery owner")
        let repeated = expectation(description: "coalesced follow-up")
        scheduler.configureRecovery {
            calls += 1; active += 1; peak = max(peak, active)
            if calls == 1 { started.fulfill(); await withCheckedContinuation { finish = $0 } }
            else { repeated.fulfill() }
            active -= 1
            return nil
        }
        scheduler.connectionChanged(available: false)
        scheduler.requestRecovery()
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(calls, 0, "Offline signals retain work without polling")
        scheduler.connectionChanged(available: true)
        await fulfillment(of: [started])
        for _ in 0..<20 { scheduler.connectionChanged(available: false); scheduler.connectionChanged(available: true); scheduler.requestRecovery() }
        XCTAssertEqual(calls, 1)
        finish?.resume()
        await fulfillment(of: [repeated])
        XCTAssertEqual(peak, 1); XCTAssertEqual(calls, 2)
    }

    func testTwoRetryRequestsJoinOneOperationEvenWhenFirstCallerCancels() async throws {
        let scheduler = GalleryUploadScheduler()
        var calls = 0
        var finish: CheckedContinuation<Void, Never>?
        let started = expectation(description: "started")
        let first = Task { try await scheduler.perform(token: "same") {
            calls += 1; started.fulfill()
            await withCheckedContinuation { finish = $0 }
            return self.result("same")
        } }
        await fulfillment(of: [started])
        let second = Task { try await scheduler.perform(token: "same") { calls += 1; return self.result("same") } }
        for _ in 0..<10 { await Task.yield() }
        first.cancel(); finish?.resume()
        let firstResult = try await first.value, secondResult = try await second.value
        XCTAssertEqual(firstResult.galleryToken, "same")
        XCTAssertEqual(secondResult.galleryToken, "same")
        XCTAssertEqual(calls, 1)
    }

    func testRetryClassificationAndBoundedBackoff() {
        XCTAssertEqual(GalleryRetryCategory.classify(GalleryUploadError.pendingNoInternet, state: .notStarted), .offline)
        XCTAssertEqual(GalleryRetryCategory.classify(GalleryUploadError.backendUnreachable(.noNetworkPath), state: .notStarted), .backendUnavailable)
        XCTAssertEqual(GalleryRetryCategory.classify(GalleryUploadError.timeout, state: .deliveryUnknown), .timeout)
        XCTAssertEqual(GalleryRetryCategory.classify(GalleryUploadError.deliveryUnknown, state: .deliveryUnknown), .ambiguous)
        XCTAssertEqual(GalleryRetryCategory.classify(GalleryUploadError.httpStatus(503), state: .deliveryUnknown), .server)
        XCTAssertEqual(GalleryRetryCategory.classify(GalleryUploadError.unauthorized, state: .notStarted), .authentication)
        XCTAssertEqual(GalleryRetryCategory.classify(GalleryUploadError.deliveryUnknown, state: .posted), .verification)
        let now = Date(timeIntervalSince1970: 1000)
        XCTAssertNil(GalleryRetryCategory.authentication.nextAttempt(at: now, attempts: 1))
        XCTAssertEqual(GalleryRetryCategory.server.nextAttempt(at: now, attempts: 1000, jitter: 1)?.timeIntervalSince(now), 900)
        XCTAssertEqual(GalleryRetryCategory.rateLimited.nextAttempt(at: now, attempts: 1, retryAfter: 120, jitter: 1)?.timeIntervalSince(now), 120)
        XCTAssertEqual(GoogleDriveGalleryUploadService.retryAfter("120"), 120)
        XCTAssertEqual(GoogleDriveGalleryUploadService.retryAfter("bad"), 60)
    }

    func testRetryDeadlineAndPermanentFailuresSurviveRelaunchWithoutMediaLoss() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = try GalleryPendingUploadStore(directoryURL: directory)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).image { _ in }
        let token = String(repeating: "c", count: 64)
        let payload = try GoogleDriveGalleryUploadService.preparePayload(photos: [image], composedReceipt: image,
            sessionID: "PP-SCHEDULER", createdAt: Date(), galleryToken: token,
            customerGalleryBaseURL: URL(string: "https://scheduler.example.test")!)
        try queue.save(payload)
        try queue.recordAttempt(galleryToken: token)
        try queue.recordFailure(galleryToken: token, error: GalleryUploadError.rateLimited(120))
        let reopened = try GalleryPendingUploadStore(directoryURL: directory)
        let original = try XCTUnwrap(reopened.summary())
        try reopened.requestRetry(connectivityRestored: true)
        try reopened.requestRetry(galleryToken: token)
        XCTAssertEqual(try reopened.summary()?.nextAttemptAt, original.nextAttemptAt, "Rapid reconnects and operator retries respect Retry-After")
        try reopened.recordFailure(galleryToken: token, error: GalleryUploadError.unauthorized)
        try reopened.requestRetry(connectivityRestored: true)
        XCTAssertTrue(try XCTUnwrap(reopened.summary()).needsAttention)
        try reopened.requestRetry(galleryToken: token)
        XCTAssertFalse(try XCTUnwrap(reopened.summary()).needsAttention, "Explicit retry after configuration repair is allowed")
        let retained = try XCTUnwrap(reopened.load(galleryToken: token))
        XCTAssertEqual(retained.galleryURL, payload.galleryURL)
        XCTAssertEqual(retained.photos.map(\.data), payload.photos.map(\.data))
    }
}
