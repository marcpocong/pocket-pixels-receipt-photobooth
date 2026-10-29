import XCTest
import UIKit
@testable import PocketPixelsBooth

@MainActor final class BoothMonitoringTelemetryTests: XCTestCase {
    func testQueueMetricsAreAggregatedAndNeverTreatAcceptedPOSTAsAvailability() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try GalleryPendingUploadStore(directoryURL: directory)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20)).image { _ in }
        let tokens = ["a", "b", "c"].map { String(repeating: $0, count: 64) }
        for (index, token) in tokens.enumerated() {
            let payload = try GoogleDriveGalleryUploadService.preparePayload(photos: [image], composedReceipt: image,
                sessionID: "PP-PRIVATE-\(index)", createdAt: Date().addingTimeInterval(Double(index)-100),
                galleryToken: token, customerGalleryBaseURL: URL(string: "https://private-gallery.example.test")!)
            try store.save(payload)
        }
        try store.updateDeliveryState(.posted, galleryToken: tokens[0])
        try store.recordFailure(galleryToken: tokens[1], error: GalleryUploadError.unauthorized)
        let metric = GalleryQueueTelemetry(summaries: try store.summaries(), activeToken: tokens[0], verifying: true, lastActivityAt: Date())
        XCTAssertEqual(metric.pending, 3, "Accepted POST is still pending public verification")
        XCTAssertEqual(metric.uploading, 0); XCTAssertEqual(metric.verifying, 1); XCTAssertEqual(metric.attention, 1)
        let text = String(decoding: try JSONEncoder().encode(metric), as: UTF8.self)
        for secret in tokens + ["PP-PRIVATE", "private-gallery", "galleryToken", "photos", "deviceToken"] { XCTAssertFalse(text.contains(secret)) }
        XCTAssertNotNil(metric.oldestAt); XCTAssertNotNil(metric.activityAt)
        XCTAssertEqual(try store.summaries().count, 3, "Monitoring cannot clear or deliver a gallery")
    }

    func testLegacySchemaCanBeUsedAgainstPreviousMonitoringWorker() throws {
        var value = BoothTelemetry(mode: "event", network: "offline", payment: "ready", printer: "uncertain", storage: "ready", incidents: ["uncertain_print"], eventReference: "evt-synthetic")
        value.reportedAt = ISO8601DateFormatter().string(from: Date()); value.eventState = "active"
        value.uploads = GalleryQueueTelemetry(summaries: [], activeToken: nil, verifying: false, lastActivityAt: nil)
        let legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value.legacy())) as? [String: Any])
        XCTAssertEqual(Set(legacy.keys), Set(["mode", "network", "payment", "printer", "storage", "incidents", "eventReference"]))
        XCTAssertEqual(legacy["printer"] as? String, "uncertain")
        XCTAssertLessThan(try JSONEncoder().encode(value).count, 2048)
    }

    func testNoQueueActivityRemainsUnknownInsteadOfInventingATime() {
        let metric = GalleryQueueTelemetry(summaries: [], activeToken: nil, verifying: false, lastActivityAt: nil)
        XCTAssertEqual(metric.pending, 0); XCTAssertEqual(metric.verifying, 0); XCTAssertEqual(metric.uploading, 0)
        XCTAssertNil(metric.activityAt); XCTAssertNil(metric.oldestAt)
    }
}
