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
    private func printer(_ mode: PrinterConnectionMode = .bluetooth, connected: Bool = true, connecting: Bool = false,
                         diagnostic: Bool = false, wifi: PrinterMonitoringObservation.Connection = .unknown,
                         busy: Bool = false, recovery: Bool = false, unresolved: Bool = false,
                         readable: Bool = true) -> PrinterMonitoringObservation {
        .resolve(mode: mode, bluetoothConnected: connected, bluetoothConnecting: connecting, diagnostic: diagnostic,
                 wifiConnection: wifi, busy: busy, recovery: recovery, unresolved: unresolved, evidenceReadable: readable)
    }

    func testConnectionAndReadinessNeverVerifyPhysicalOutput() {
        let ready = printer()
        XCTAssertEqual(ready.connection, .connected); XCTAssertEqual(ready.readiness, .ready)
        XCTAssertEqual(ready.evidence, .clear, "Only no outstanding review is established, not physical delivery")
        XCTAssertEqual(printer(connected: false).connection, .disconnected)
        XCTAssertEqual(printer(connected: false).readiness, .unavailable)
        XCTAssertEqual(printer(connected: false, connecting: true).connection, .connecting)
        XCTAssertEqual(printer(diagnostic: true).readiness, .diagnosticRequired)
    }

    func testNormalBusyCheckpointIsUnknownAndExplicitReviewStillSurfaces() {
        XCTAssertEqual(printer(busy: true).readiness, .busy)
        XCTAssertEqual(printer(busy: true).evidence, .unknown)
        XCTAssertEqual(printer(busy: true, recovery: true, unresolved: true).readiness, .recoveryRequired)
        XCTAssertEqual(printer(busy: true, unresolved: true).evidence, .unresolved)
    }

    func testReconnectionCannotResolvePhysicalEvidenceAndUnreadableIsUnknown() {
        for connected in [false, true] {
            XCTAssertEqual(printer(connected: connected, unresolved: true).evidence, .unresolved)
        }
        XCTAssertEqual(printer(readable: false).evidence, .unknown)
        XCTAssertEqual(printer(unresolved: true, readable: false).evidence, .unresolved)
        XCTAssertEqual(printer().evidence, .clear)
    }

    func testSelectedTransportIgnoresUnusedRadioAndOldWiFiChecks() {
        XCTAssertEqual(printer(.wifi, connected: false, diagnostic: true, wifi: .connected).readiness, .ready)
        XCTAssertEqual(printer(.bluetooth, wifi: .disconnected).readiness, .ready)
        XCTAssertEqual(printer(.wifi, wifi: .unknown).readiness, .unknown)
        XCTAssertEqual(printer(.wifi, wifi: .disconnected).readiness, .unavailable)
        XCTAssertEqual(printer(.auto, diagnostic: true, wifi: .connected).readiness, .diagnosticRequired)
        XCTAssertEqual(printer(.auto, connected: false, wifi: .connected).transport, .wifi)
    }

    func testV3NegotiationDoesNotSendNewFieldsToV2OrLegacy() throws {
        var telemetry = BoothTelemetry(mode: "event", network: "online", payment: "ready", printer: "ready", storage: "ready", incidents: [])
        telemetry.telemetryVersion = 3; telemetry.printerObservation = printer(); telemetry.camera = .unknown
        telemetry.guest = .guestInProgress; telemetry.reportedAt = ISO8601DateFormatter().string(from: Date())
        telemetry.eventState = "idle"
        for version in [1, 2, 3] {
            let data = try JSONEncoder().encode(telemetry.compatible(version: version))
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(object["telemetryVersion"] as? Int, version == 3 ? 3 : nil)
            XCTAssertEqual(object["reportedAt"] != nil, version >= 2)
            XCTAssertEqual(object["printerObservation"] != nil, version == 3)
            XCTAssertLessThan(data.count, 2048)
        }
    }

    func testCameraObservationsArePassiveAndUninitializedIsUnknown() {
        func camera(running: Bool = false, initializing: Bool = false, denied: Bool = false,
                    unavailable: Bool = false, interrupted: Bool = false) -> CameraMonitoringState {
            .resolve(permissionDenied: denied, running: running, unavailable: unavailable,
                     initializing: initializing, interrupted: interrupted)
        }
        XCTAssertEqual(camera(), .unknown)
        XCTAssertEqual(camera(running: true), .ready)
        XCTAssertEqual(camera(initializing: true), .initializing)
        XCTAssertEqual(camera(denied: true), .permissionDenied)
        XCTAssertEqual(camera(unavailable: true), .unavailable)
        XCTAssertEqual(camera(interrupted: true), .interrupted)
        XCTAssertEqual(CameraMonitoringState.resolve(permissionDenied: false, running: false, unavailable: false, initializing: false, interrupted: false, recoveryRequired: true), .recoveryRequired)
    }

    func testGuestObservationsNeverTreatLegitimateWaitingAsStalled() {
        XCTAssertEqual(GuestMonitoringState.resolve(.welcome), .idle)
        for state: BoothSessionState in [.review, .awaitingQRPayment, .cashAttestation, .stickerStudio, .passportSignature] {
            XCTAssertEqual(GuestMonitoringState.resolve(state), .guestInProgress)
        }
        XCTAssertEqual(GuestMonitoringState.resolve(.capturing(photoIndex: 1)), .captureWaiting)
        XCTAssertEqual(GuestMonitoringState.resolve(.printing), .printing)
        XCTAssertEqual(GuestMonitoringState.resolve(.recoveryRequired("private details")), .recoveryRequired)
    }

    func testMonitoringDoesNotMutateMountedGuestOrExposeItsPrivateFields() throws {
        let previous = ActiveGuestInteraction.model
        defer { ActiveGuestInteraction.model = previous }
        let model = BoothSessionViewModel()
        ActiveGuestInteraction.model = model
        model.state = .review; model.sessionIdentifier = "PP-PRIVATE-GUEST"
        model.galleryToken = String(repeating: "private", count: 10)
        let first = BoothMonitoring.shared.snapshot()
        let second = BoothMonitoring.shared.snapshot()
        XCTAssertEqual(model.state, .review); XCTAssertEqual(model.sessionIdentifier, "PP-PRIVATE-GUEST")
        XCTAssertEqual(first.guest, .guestInProgress); XCTAssertEqual(second.guest, .guestInProgress)
        let text = String(decoding: try JSONEncoder().encode(first), as: UTF8.self)
        XCTAssertFalse(text.contains("PP-PRIVATE-GUEST")); XCTAssertFalse(text.contains("privateprivate"))
    }

    func testUnreadableEventContextIsUnknownAndDowngradesSafely() throws {
        XCTAssertEqual(EventMonitoringState.resolve(readable: false, hasRun: false, paused: false, recovering: false), .unknown)
        XCTAssertEqual(EventMonitoringState.resolve(readable: false, hasRun: true, paused: false, recovering: false), .unknown)
        XCTAssertEqual(EventMonitoringState.resolve(readable: true, hasRun: false, paused: false, recovering: false), .idle)
        XCTAssertEqual(EventMonitoringState.resolve(readable: true, hasRun: true, paused: false, recovering: false), .active)
        XCTAssertEqual(EventMonitoringState.resolve(readable: true, hasRun: true, paused: true, recovering: false), .paused)
        XCTAssertEqual(EventMonitoringState.resolve(readable: false, hasRun: false, paused: false, recovering: true), .recovery)
        var telemetry = BoothTelemetry(mode: "event", network: "unknown", payment: "ready", printer: "unavailable", storage: "error", incidents: ["storage"])
        telemetry.eventState = "unknown"; telemetry.telemetryVersion = 3
        for version in [1, 2, 3] {
            XCTAssertEqual(telemetry.compatible(version: version).eventState, version == 3 ? "unknown" : nil)
        }
    }

}
