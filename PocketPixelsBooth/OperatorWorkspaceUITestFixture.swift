#if DEBUG && targetEnvironment(simulator)
import SwiftUI
import UIKit

/// Available only in debug simulators through an explicit UI-test launch argument. Production
/// ContentView is never constructed, so camera, payments, upload workers and printers do not run.
struct OperatorWorkspaceUITestFixture: View {
    @State private var fixture: Fixture?
    @State private var failure = ""
    @State private var screen = "Sessions"
    var body: some View {
        Group {
            if let fixture {
                VStack(spacing: 0) {
                    Picker("Synthetic validation screen", selection: $screen) {
                        ForEach(["Sessions", "Events", "Checkouts", "Health"], id: \.self) { Text($0) }
                    }.pickerStyle(.segmented).padding()
                    NavigationStack {
                        switch screen {
                        case "Events": OperatorEventsView(workspace: fixture.workspace, runs: fixture.runs, library: fixture.library)
                        case "Checkouts": List { CheckoutRecoverySection(recovery: fixture.recovery, showsArchived: true) }.navigationTitle("Checkout Recovery")
                        case "Health": ProductionHealthSheet(lifecycle: fixture.lifecycle, isPresented: .constant(true), loadsRemote: false, reportOverride: fixture.health)
                        default: RecentSessionsView(viewModel: fixture.sessions)
                        }
                    }
                }
            } else if !failure.isEmpty { Text(failure) }
            else { ProgressView("Preparing synthetic records…") }
        }.task {
            guard fixture == nil else { return }
            do { fixture = try await Fixture() } catch { failure = "Synthetic fixture could not be prepared." }
        }
    }

    @MainActor private struct Fixture {
        let sessions: RecentSessionsViewModel
        let workspace: OperatorWorkspace
        let runs: EventRunStore
        let library: EventDesignLibraryStore
        let recovery: PaymentRecoveryCoordinator
        let lifecycle: EventLifecycleCoordinator
        let health: ProductionHealthReport
        init() async throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("V41UITest-" + UUID().uuidString)
            let store = try RecentSessionArchiveStore(directoryURL: root.appendingPathComponent("archive"))
            let proofs = try GalleryVerificationStore(directory: root.appendingPathComponent("proof"))
            for index in 0..<2 {
                let format = UIGraphicsImageRendererFormat(); format.scale = 1
                let photo = UIGraphicsImageRenderer(size: CGSize(width: 900, height: 1200), format: format).image { context in
                    UIColor.systemTeal.setFill(); context.fill(CGRect(x: 0, y: 0, width: 900, height: 1200))
                    "SYNTHETIC PHOTO \(index + 1)".draw(at: CGPoint(x: 70, y: 500), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 52), .foregroundColor: UIColor.white])
                }
                let token = String(repeating: index == 0 ? "a" : "b", count: 64)
                let url = URL(string: "https://synthetic.example.test/?g=\(token)")!
                let id = "PP-20261025-12000\(index)-" + UUID().uuidString.lowercased()
                FixtureGalleryProtocol.sessionIDs[token] = id
                let date = Date().addingTimeInterval(Double(-index * 60))
                let session = CommittedGallerySession(sessionIdentifier: id, createdAt: date, galleryToken: token, galleryURL: url, photos: [photo], format: .solo, eventProfile: nil)
                let receipt = try ReceiptComposer.compose(photos: [photo], sessionIdentifier: id, date: date, galleryURL: url, format: .solo)
                guard let image = UIImage(data: receipt.imagePNGData), let encoded = photo.jpegData(compressionQuality: 0.95) else { throw MediaExportError.unavailable }
                let raster = try ThermalImageRasterizer.rasterize(image, purpose: .completeReceipt)
                try store.save(.init(committedSession: session, composedReceipt: receipt, receiptPreviewPNGData: receipt.imagePNGData,
                    thermalPreviewPNGData: raster.previewPNGData, rasterizedImage: raster, photoThumbnailData: [try SessionArchiveCommitter.thumbnailData(from: photo)]))
                if index == 0 {
                    try store.attachOriginalPhotos(archiveID: token, sessionID: id, photos: [encoded])
                    try proofs.record(sessionID: id, token: token, url: url, source: "synthetic-ui-fixture")
                }
            }
            let paymentsRoot = root.appendingPathComponent("payments")
            let checkpoints = try CheckoutCheckpointStore(directory: paymentsRoot), outbox = try PrintOutcomeOutbox(directory: paymentsRoot)
            let recoveryStore = try AppRecoveryStore(directoryURL: root.appendingPathComponent("recovery"))
            let pending = try GalleryPendingUploadStore(directoryURL: root.appendingPathComponent("queue"))
            let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [FixtureGalleryProtocol.self]
            sessions = RecentSessionsViewModel(store: store, verificationStore: proofs, recheckSession: URLSession(configuration: config), photosWriter: FixturePhotosWriter(),
                managementAuthorized: { true }, mediaDeletionInspector: { try SessionMediaOperations.sessionDeletionDecision($0, checkpoints: checkpoints, outbox: outbox, recoveryStore: recoveryStore, pendingStore: pending) })
            sessions.refresh()
            for index in 0..<3 {
                let id = "synthetic-checkout-\(index)"
                try checkpoints.begin(.init(id: id, environment: "test", eventID: "synthetic-event", policyRevisionID: "synthetic-policy", unitPriceCentavos: 5000,
                    copies: 1, format: "solo", method: "QRPH", phase: .awaitingProvider, createdAt: Date(), updatedAt: Date()))
                if index > 0 { _ = checkpoints.park(id: id, reason: "guest left") }
                if index == 2 { checkpoints.update(id: id) { $0.hiddenAt = Date() } }
            }
            let reader = FixtureRecoveryReader()
            recovery = PaymentRecoveryCoordinator(checkpointStore: { checkpoints }, reader: { reader }, outboxClient: { nil }, managementAuthorized: { true }, inspectManagementDependencies: { _ in .init() })
            await recovery.refresh()
            runs = EventRunStore(directory: root.appendingPathComponent("runs"), authorized: { true }, blockingReason: { nil })
            workspace = OperatorWorkspace(directory: root.appendingPathComponent("workspace"))
            library = EventDesignLibraryStore(directory: root.appendingPathComponent("designs"), legacyProfile: { .pocketPixelsDefault }, legacyName: { "" }, operationAuthorized: { true }, operationBlockingReason: { nil })
            _ = try library.create(name: "Unused Test Setup", venue: "")
            let used = try library.create(name: "Garden Celebration", venue: "Synthetic venue")
            _ = try runs.createHistoricalRun(name: "Garden Celebration", designID: used.id, startedAt: Date().addingTimeInterval(-3600), endedAt: Date())
            lifecycle = EventLifecycleCoordinator(runs: runs, authorized: { true }, blockingReason: { nil }, recoveryReason: { nil }, source: { .localPrepaid })
            health = ProductionHealthReport(.init(admissionOpen: true, eventStatus: .regular, runID: nil, runStatus: nil, paid: false,
                commercialEventID: nil, commercial: .notNeeded, lastEventCheck: nil, paymentsConfigured: false, environment: nil,
                printerRequiresRecovery: false, unresolvedPrint: false, printerLastReported: "Not checked", printAccountingConflicts: 0, printAccountingPending: 0,
                checkoutsNeedingAttention: recovery.activeInterruptionCount, checkoutIntegrityFault: false, lastRecoveryCheck: Date(),
                pendingGalleries: 0, galleryStorageProblem: false, storageErrors: [], pendingCreation: false, parkedFinancialFollowUps: recovery.parkedFollowUpCount))
        }
    }
}

private struct FixturePhotosWriter: PhotosLibraryWriting {
    func requestAddAccess() async -> Bool { false }
    func save(files: [URL]) async throws { throw MediaExportError.permission }
}
private struct FixtureRecoveryReader: CheckoutRecoveryReading {
    let environment = "test"
    func checkoutRecovery(checkoutSessionID: String) async throws -> CheckoutRecoveryResponse {
        // No attempt can be considered terminal; these rows can only be archived.
        let json = """
        {"checkoutSessionId":"\(checkoutSessionID)","orders":[{"order":{"id":"synthetic-order","eventId":"synthetic-event","policyRevisionId":"synthetic-policy","format":"solo","copies":1,"unitPriceCentavos":5000,"totalCentavos":5000,"currency":"PHP","state":"PAYMENT_PENDING","paymentMethod":"QRPH"},"attempt":{"id":"synthetic-attempt","method":"QRPH","state":"UNKNOWN_RECONCILIATION"},"entitlement":null,"printOutcomes":[]}],"openOrderId":"synthetic-order","serverTime":"2026-10-25T04:00:00Z"}
        """
        return try PaymentsAPIClient.makeDecoder().decode(CheckoutRecoveryResponse.self, from: Data(json.utf8))
    }
}
private final class FixtureGalleryProtocol: URLProtocol {
    nonisolated(unsafe) static var sessionIDs: [String: String] = [:]
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard ProcessInfo.processInfo.arguments.contains("--gallery-ready-response"),
              let url = request.url, let token = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "g" })?.value,
              let id = Self.sessionIDs[token] else { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return }
        let body = "{\"statusVersion\":1,\"ok\":true,\"status\":\"complete\",\"galleryToken\":\"\(token)\",\"sessionID\":\"\(id)\",\"schemaVersion\":2,\"fileCount\":4}"
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
#endif
