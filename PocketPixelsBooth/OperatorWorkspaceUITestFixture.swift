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
                        case "Events": OperatorEventsView(workspace: fixture.workspace, runs: fixture.runs, library: fixture.library, lifecycle: fixture.lifecycle, sessionArchives: { fixture.archiveStore }, creationPending: { _ in false })
                        case "Checkouts": List { CheckoutRecoverySection(recovery: fixture.recovery, showsArchived: true) }.navigationTitle("Checkout Recovery")
                        case "Health": ProductionHealthSheet(lifecycle: fixture.lifecycle, isPresented: .constant(true), loadsRemote: false, reportOverride: fixture.health)
                        default: RecentSessionsView(viewModel: fixture.sessions)
                        }
                    }
                }
            } else if !failure.isEmpty { Text(failure) }
            else { ProgressView("Preparing synthetic records…") }
        }.environment(\.dynamicTypeSize, ProcessInfo.processInfo.arguments.contains("--fixture-accessibility") ? .accessibility2 : .large)
        .task {
            guard fixture == nil else { return }
            do { fixture = try await Fixture() } catch { failure = "Synthetic fixture could not be prepared." }
        }
    }

    @MainActor private struct Fixture {
        let archiveStore: RecentSessionArchiveStore
        let sessions: RecentSessionsViewModel
        let workspace: OperatorWorkspace
        let runs: EventRunStore
        let library: EventDesignLibraryStore
        let recovery: PaymentRecoveryCoordinator
        let lifecycle: EventLifecycleCoordinator
        let health: ProductionHealthReport
        init() async throws {
            let args = ProcessInfo.processInfo.arguments
            let fixtureID = args.firstIndex(of: "--fixture-id").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } ?? UUID().uuidString
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("V41UITest-" + fixtureID.filter { $0.isLetter || $0.isNumber || $0 == "-" })
            let seedMarker = root.appendingPathComponent("seeded")
            let seeded = FileManager.default.fileExists(atPath: seedMarker.path)
            let activeGuest = args.contains("--fixture-active-guest")
            let store = try RecentSessionArchiveStore(directoryURL: root.appendingPathComponent("archive"))
            archiveStore = store
            let proofs = try GalleryVerificationStore(directory: root.appendingPathComponent("proof"))
            for index in 0..<(seeded || args.contains("--fixture-empty") ? 0 : args.contains("--fixture-many-sessions") ? 8 : 2) {
                let format = UIGraphicsImageRendererFormat(); format.scale = 1
                let photo = UIGraphicsImageRenderer(size: CGSize(width: 900, height: 1200), format: format).image { context in
                    let colors: [UIColor] = [.init(red: 0.36, green: 0.58, blue: 0.54, alpha: 1), .init(red: 0.74, green: 0.47, blue: 0.40, alpha: 1), .init(red: 0.48, green: 0.47, blue: 0.64, alpha: 1), .init(red: 0.70, green: 0.57, blue: 0.36, alpha: 1)]
                    colors[index % colors.count].setFill(); context.fill(CGRect(x: 0, y: 0, width: 900, height: 1200))
                    UIColor.white.withAlphaComponent(0.12).setFill()
                    for stripe in 0..<6 { context.fill(CGRect(x: stripe * 180 - 100, y: 0, width: 60, height: 1200)) }
                    UIColor(red: 0.23, green: 0.29, blue: 0.32, alpha: 1).setFill()
                    UIBezierPath(ovalIn: CGRect(x: 170, y: 640, width: 560, height: 620)).fill()
                    UIColor(red: 0.95, green: 0.78, blue: 0.62, alpha: 1).setFill()
                    UIBezierPath(ovalIn: CGRect(x: 300, y: 320, width: 300, height: 380)).fill()
                    UIColor(red: 0.20, green: 0.18, blue: 0.19, alpha: 1).setFill()
                    UIBezierPath(ovalIn: CGRect(x: 280, y: 270, width: 340, height: 160)).fill()
                    "SYNTHETIC SAMPLE \(index + 1)".draw(at: CGPoint(x: 60, y: 1080), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 42), .foregroundColor: UIColor.white])
                }
                let token = index < 2 ? String(repeating: index == 0 ? "a" : "b", count: 64) : String(format: "%064x", index)
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
            for summary in try store.summaries() {
                FixtureGalleryProtocol.sessionIDs[summary.archiveID] = summary.sessionIdentifier
            }
            for index in 0..<(seeded ? 0 : 3) {
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
            var rejectsDesignWrites = false
            library = EventDesignLibraryStore(directory: root.appendingPathComponent("designs"), write: { data, url in
                if rejectsDesignWrites && args.contains("--fixture-storage-failure") { throw CocoaError(.fileWriteOutOfSpace) }
                try DurableFileWriter.write(data, to: url)
            }, legacyProfile: { .pocketPixelsDefault }, legacyName: { "" }, operationAuthorized: { true }, operationBlockingReason: { activeGuest ? "Finish the active guest first." : nil })
            if !seeded {
                var unused = try library.create(name: "Unused Test Setup", venue: "")
                unused.createdAt = Date().addingTimeInterval(-7200); try library.save(unused)
                let used = try library.create(name: "Garden Celebration", venue: "Synthetic venue")
                _ = try runs.createHistoricalRun(name: "Garden Celebration", designID: used.id, startedAt: Date().addingTimeInterval(-3600), endedAt: Date())
                if args.contains("--fixture-applied") || activeGuest {
                    try library.recordApplied(eventModeEnabled: true, eventID: used.id)
                    if activeGuest { _ = try runs.startNewRun(context: .init(designID: used.id, commercialEventID: nil, serverBinding: nil, name: used.displayName)) }
                }
                try Data("synthetic fixture only".utf8).write(to: seedMarker)
            }
            rejectsDesignWrites = true
            let acceptance = SessionAcceptanceStore(directory: root)
            let fixtureLibrary = library
            lifecycle = EventLifecycleCoordinator(runs: runs, acceptance: acceptance, authorized: { true },
                blockingReason: { activeGuest ? "Finish the active guest first." : nil }, recoveryReason: { nil },
                endBlockingReason: { activeGuest ? "Finish the active guest first." : nil }, retainFollowUps: {}, source: { .localPrepaid },
                appliedContext: { .init(designID: fixtureLibrary.library.appliedEventID, commercialEventID: nil, serverBinding: nil, name: "Synthetic") },
                applyRegularConfiguration: { try fixtureLibrary.recordApplied(eventModeEnabled: false, eventID: nil) })
            health = ProductionHealthReport(.init(admissionOpen: true, eventStatus: .regular, runID: nil, runStatus: nil, paid: false,
                commercialEventID: nil, commercial: .notNeeded, lastEventCheck: nil, paymentsConfigured: false, environment: nil,
                printerRequiresRecovery: false, unresolvedPrint: false, printerLastReported: "Not checked", printAccountingConflicts: 0, printAccountingPending: 0,
                checkoutsNeedingAttention: recovery.activeInterruptionCount, checkoutIntegrityFault: false, lastRecoveryCheck: Date(),
                pendingGalleries: 0, galleryStorageProblem: false, storageErrors: [], pendingCreation: false, parkedFinancialFollowUps: recovery.financialFollowUpCount))
        }
    }
}

private struct FixturePhotosWriter: PhotosLibraryWriting {
    func requestAddAccess() async -> Bool { ProcessInfo.processInfo.arguments.contains("--fixture-photos-success") }
    func save(files: [URL]) async throws {
        guard ProcessInfo.processInfo.arguments.contains("--fixture-photos-success") else { throw MediaExportError.permission }
        // Deliberately no Photos transaction: all UI acceptance stays within synthetic storage.
    }
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

#if DEBUG && targetEnvironment(simulator)
/// Isolated authentication/header acceptance surface; never constructs guest or service flows.
struct HeaderPINRefinementFixture: View {
    @State private var configuration = ReceiptHeaderConfiguration.coBrandedRecommended
    @State private var failure = ""
    @StateObject private var authentication: OperatorAuthentication

    init() {
        let args = ProcessInfo.processInfo.arguments
        let id = args.firstIndex(of: "--fixture-id").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } ?? UUID().uuidString
        _authentication = StateObject(wrappedValue: OperatorAuthentication(permit: OperatorAccessPermit(), evaluate: { false },
            pinStore: OperatorPINStore(service: "header-pin-fixture-" + id)))
    }
    var body: some View {
        OperatorAuthenticationView(authentication: authentication) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Header Acceptance").font(.title)
                    if !failure.isEmpty { Text(failure) }
                    CoBrandedHeaderControls(configuration: $configuration)
                }.padding(24)
            }
        }
        .environment(\.dynamicTypeSize, ProcessInfo.processInfo.arguments.contains("--fixture-accessibility") ? .accessibility2 : .large)
        .task {
            guard configuration.assetIdentifier == nil else { return }
            do {
                let format = UIGraphicsImageRendererFormat(); format.scale = 1
                let logo = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 300), format: format).image { context in
                    UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 300, height: 300))
                    UIColor.black.setStroke(); context.cgContext.setLineWidth(12)
                    context.cgContext.strokeEllipse(in: CGRect(x: 12, y: 12, width: 276, height: 276))
                    NSString(string: "EVENT").draw(at: CGPoint(x: 50, y: 120), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 52)])
                }
                configuration.assetIdentifier = try EventHeaderAssetStore().importArtworkData(logo.pngData()!)
            } catch { failure = "Could not prepare synthetic artwork." }
        }
    }
}
#endif
