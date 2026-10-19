//
//  GoogleGalleryNetworkSupport.swift
//  PocketPixelsBooth
//

import Foundation
import Network

nonisolated enum GalleryBackendConnectivityState: Equatable, Sendable {
    case noNetworkPath
    case wifiNoUsableInternet(host: String?, code: Int?)
    case reachable
    case timeout(host: String?, code: Int)
    case tlsFailure(host: String?, code: Int)
    case invalidBackendURL(String)
    case backendDiagnostic(String)

    var title: String {
        switch self {
        case .noNetworkPath:
            "No network path"
        case .wifiNoUsableInternet:
            "Wi-Fi connected, no usable internet"
        case .reachable:
            "Google backend reachable"
        case .timeout:
            "Backend timeout"
        case .tlsFailure:
            "TLS failure"
        case .invalidBackendURL:
            "Invalid backend URL"
        case .backendDiagnostic:
            "Backend diagnostic"
        }
    }

    var diagnosticDescription: String {
        switch self {
        case .noNetworkPath:
            "No network path is available."
        case .wifiNoUsableInternet(let host, let code):
            "Connected to Wi-Fi, but Google is not reachable. Host: \(host ?? "unknown")\(Self.codeSuffix(code))."
        case .reachable:
            "The configured Google Apps Script backend is reachable."
        case .timeout(let host, let code):
            "Backend request timed out. Host: \(host ?? "unknown"), URLError code: \(code)."
        case .tlsFailure(let host, let code):
            "TLS validation failed. Host: \(host ?? "unknown"), URLError code: \(code)."
        case .invalidBackendURL(let message):
            message
        case .backendDiagnostic(let message):
            message
        }
    }

    var isReachable: Bool {
        switch self {
        case .reachable, .backendDiagnostic:
            true
        case .noNetworkPath, .wifiNoUsableInternet, .timeout, .tlsFailure, .invalidBackendURL:
            false
        }
    }

    private static func codeSuffix(_ code: Int?) -> String {
        guard let code else {
            return "."
        }

        return ", URLError code: \(code)."
    }
}

nonisolated enum GalleryDeliveryState: Codable, Equatable, Sendable {
    case notStarted
    case posted
    case deliveryUnknown
}

nonisolated struct GalleryPreparedUploadMetrics: Codable, Equatable, Sendable {
    let files: [GalleryPreparedUploadFileMetric]
    let totalDecodedBytes: Int
    let estimatedBase64JSONBytes: Int
    let originalDecodedBytes: Int?
    let timing: GalleryUploadTimingMetrics?

    nonisolated init(
        files: [GalleryPreparedUploadFileMetric],
        totalDecodedBytes: Int,
        estimatedBase64JSONBytes: Int,
        originalDecodedBytes: Int? = nil,
        timing: GalleryUploadTimingMetrics? = nil
    ) {
        self.files = files
        self.totalDecodedBytes = totalDecodedBytes
        self.estimatedBase64JSONBytes = estimatedBase64JSONBytes
        self.originalDecodedBytes = originalDecodedBytes
        self.timing = timing
    }

    nonisolated static let maxFileDecodedBytes = GalleryPreparedUploadBudget.maximumFileDecodedBytes
    nonisolated static let maxTotalDecodedBytes = GalleryPreparedUploadBudget.maximumPreparedDecodedBytes
    nonisolated static let maxEstimatedBase64JSONBytes = GalleryPreparedUploadBudget.maximumRequestBytes
}

/// Mirrors the bounded Apps Script upload and customer-page render limits. New v2 payloads
/// reserve headroom so every package accepted by the app can also be embedded by the QR page.
nonisolated enum GalleryPreparedUploadBudget {
    static let maximumAssetCount = 9 // Six photos, two receipts and one GIF.
    static let maximumFileDecodedBytes = 6 * 1024 * 1024
    static let backendGalleryDecodedBytes = 6 * 1024 * 1024
    static let decodedSafetyMarginBytes = 512 * 1024
    static let maximumPreparedDecodedBytes = backendGalleryDecodedBytes - decodedSafetyMarginBytes
    static let maximumGalleryBase64Characters = 9 * 1024 * 1024
    static let maximumRequestBytes = 9 * 1024 * 1024
    static let minimumGIFByteBudget = 64 * 1024

    static func estimatedBase64JSONBytes(for images: [GalleryStoredUploadImage]) -> Int {
        images.reduce(4096) { partial, image in
            partial + ((image.data.count + 2) / 3 * 4) + image.filename.utf8.count + image.mimeType.utf8.count + 128
        }
    }

    static func maximumGIFBytes(afterPreparing images: [GalleryStoredUploadImage]) throws -> Int {
        let available = maximumPreparedDecodedBytes - images.reduce(0) { $0 + $1.data.count }
        guard available >= minimumGIFByteBudget else {
            throw GalleryUploadError.requestTooLarge("Prepared photos and receipts leave no safe room for the required GIF.")
        }
        return min(available, maximumFileDecodedBytes)
    }

    static func validate(images: [GalleryStoredUploadImage], requiresGIF: Bool) throws {
        guard !images.isEmpty, images.count <= maximumAssetCount else {
            throw GalleryUploadError.requestTooLarge("Gallery asset count exceeds the server limit.")
        }
        guard images.allSatisfy({ $0.data.count <= maximumFileDecodedBytes }) else {
            throw GalleryUploadError.requestTooLarge("A gallery asset exceeds the 6 MB file limit.")
        }
        if requiresGIF {
            guard let gif = images.first(where: { $0.filename == "session.gif" }),
                  gif.mimeType == "image/gif",
                  gif.data.count >= 6 else {
                throw GalleryUploadError.requestTooLarge("A complete schema-v2 gallery requires session.gif.")
            }
        }
        let decoded = images.reduce(0) { $0 + $1.data.count }
        guard decoded <= maximumPreparedDecodedBytes else {
            throw GalleryUploadError.requestTooLarge("Decoded gallery assets exceed the safe 5.5 MB render budget.")
        }
        let estimated = estimatedBase64JSONBytes(for: images)
        guard estimated <= maximumRequestBytes, estimated <= maximumGalleryBase64Characters else {
            throw GalleryUploadError.requestTooLarge("Estimated Base64 gallery data exceeds the 9 MB server limit.")
        }
    }
}

nonisolated struct GalleryPreparedUploadFileMetric: Codable, Equatable, Sendable, Identifiable {
    var id: String { filename }
    let filename: String
    let decodedBytes: Int
}

nonisolated struct GalleryPreparedUploadPayload: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let galleryToken: String
    let galleryURL: URL
    let sessionID: String
    let createdAt: String
    let photos: [GalleryStoredUploadImage]
    let colorReceipt: GalleryStoredUploadImage
    let thermalReceipt: GalleryStoredUploadImage?
    let shareColorReceipt: GalleryStoredUploadImage?
    let receiptVariants: GalleryReceiptVariants?
    let gif: GalleryStoredUploadImage?
    let metrics: GalleryPreparedUploadMetrics
    let deliveryState: GalleryDeliveryState
    var receipt: GalleryStoredUploadImage { colorReceipt }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, galleryToken, galleryURL, sessionID, createdAt, photos
        case receipt, colorReceipt, thermalReceipt, gif, metrics, deliveryState, shareColorReceipt, receiptVariants
    }

    init(schemaVersion: Int, galleryToken: String, galleryURL: URL, sessionID: String, createdAt: String,
         photos: [GalleryStoredUploadImage], colorReceipt: GalleryStoredUploadImage,
         thermalReceipt: GalleryStoredUploadImage?, gif: GalleryStoredUploadImage?,
         metrics: GalleryPreparedUploadMetrics, deliveryState: GalleryDeliveryState,
         shareColorReceipt: GalleryStoredUploadImage? = nil, receiptVariants: GalleryReceiptVariants? = nil) {
        self.schemaVersion = schemaVersion; self.galleryToken = galleryToken; self.galleryURL = galleryURL
        self.sessionID = sessionID; self.createdAt = createdAt; self.photos = photos
        self.colorReceipt = colorReceipt; self.thermalReceipt = thermalReceipt; self.gif = gif
        self.metrics = metrics; self.deliveryState = deliveryState
        self.shareColorReceipt = shareColorReceipt; self.receiptVariants = receiptVariants
    }

    init(schemaVersion: Int, galleryToken: String, galleryURL: URL, sessionID: String, createdAt: String,
         photos: [GalleryStoredUploadImage], receipt: GalleryStoredUploadImage,
         metrics: GalleryPreparedUploadMetrics, deliveryState: GalleryDeliveryState) {
        self.init(schemaVersion: schemaVersion, galleryToken: galleryToken, galleryURL: galleryURL,
                  sessionID: sessionID, createdAt: createdAt, photos: photos, colorReceipt: receipt,
                  thermalReceipt: nil, gif: nil, metrics: metrics, deliveryState: deliveryState)
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        galleryToken = try values.decode(String.self, forKey: .galleryToken)
        galleryURL = try values.decode(URL.self, forKey: .galleryURL)
        sessionID = try values.decode(String.self, forKey: .sessionID)
        createdAt = try values.decode(String.self, forKey: .createdAt)
        photos = try values.decode([GalleryStoredUploadImage].self, forKey: .photos)
        colorReceipt = try values.decodeIfPresent(GalleryStoredUploadImage.self, forKey: .colorReceipt)
            ?? values.decode(GalleryStoredUploadImage.self, forKey: .receipt)
        shareColorReceipt = try values.decodeIfPresent(GalleryStoredUploadImage.self, forKey: .shareColorReceipt)
        receiptVariants = try values.decodeIfPresent(GalleryReceiptVariants.self, forKey: .receiptVariants)
        thermalReceipt = try values.decodeIfPresent(GalleryStoredUploadImage.self, forKey: .thermalReceipt)
        gif = try values.decodeIfPresent(GalleryStoredUploadImage.self, forKey: .gif)
        metrics = try values.decode(GalleryPreparedUploadMetrics.self, forKey: .metrics)
        deliveryState = try values.decode(GalleryDeliveryState.self, forKey: .deliveryState)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(schemaVersion, forKey: .schemaVersion); try values.encode(galleryToken, forKey: .galleryToken)
        try values.encode(galleryURL, forKey: .galleryURL); try values.encode(sessionID, forKey: .sessionID)
        try values.encode(createdAt, forKey: .createdAt); try values.encode(photos, forKey: .photos)
        if schemaVersion == 1 { try values.encode(colorReceipt, forKey: .receipt) }
        else { try values.encode(colorReceipt, forKey: .colorReceipt) }
        try values.encodeIfPresent(thermalReceipt, forKey: .thermalReceipt); try values.encodeIfPresent(gif, forKey: .gif)
        try values.encodeIfPresent(shareColorReceipt, forKey: .shareColorReceipt)
        try values.encodeIfPresent(receiptVariants, forKey: .receiptVariants)
        try values.encode(metrics, forKey: .metrics); try values.encode(deliveryState, forKey: .deliveryState)
    }
}

nonisolated struct GalleryStoredUploadImage: Codable, Equatable, Sendable {
    let filename: String
    let mimeType: String
    let data: Data
}

final class GoogleGalleryURLSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url,
              url.scheme?.lowercased() == "https",
              let host = url.host()?.lowercased(),
              Self.isAllowedGoogleRedirectHost(host) else {
            completionHandler(nil)
            return
        }

        completionHandler(request)
    }

    nonisolated static func isAllowedGoogleRedirectHost(_ host: String) -> Bool {
        host == "script.google.com"
            || host == "script.googleusercontent.com"
            || host.hasSuffix(".googleusercontent.com")
    }
}

enum GalleryNetworkClassifier {
    nonisolated static func classify(urlError: URLError, fallbackHost: String?) -> GalleryBackendConnectivityState {
        let host = urlError.failureURLString.flatMap { URL(string: $0)?.host() } ?? fallbackHost
        let code = urlError.errorCode

        switch urlError.code {
        case .timedOut:
            return .timeout(host: host, code: code)
        case .secureConnectionFailed,
             .serverCertificateHasBadDate,
             .serverCertificateUntrusted,
             .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid,
             .clientCertificateRejected,
             .clientCertificateRequired,
             .cannotLoadFromNetwork:
            return .tlsFailure(host: host, code: code)
        case .notConnectedToInternet,
             .networkConnectionLost,
             .cannotFindHost,
             .cannotConnectToHost,
             .dnsLookupFailed,
             .internationalRoamingOff,
             .callIsActive,
             .dataNotAllowed:
            return .wifiNoUsableInternet(host: host, code: code)
        default:
            return .wifiNoUsableInternet(host: host, code: code)
        }
    }
}

struct GalleryBackendConnectivityTester: Sendable {
    private let configurationProvider: @Sendable () throws -> GoogleDriveGalleryConfiguration
    private let session: URLSession
    private let pathStatusProvider: @Sendable () async -> NWPath.Status

    nonisolated init(
        configurationProvider: @escaping @Sendable () throws -> GoogleDriveGalleryConfiguration = { try GoogleDriveGalleryConfiguration.load() },
        session: URLSession = GalleryBackendConnectivityTester.makeSession(),
        pathStatusProvider: @escaping @Sendable () async -> NWPath.Status = { await GalleryBackendConnectivityTester.currentPathStatus() }
    ) {
        self.configurationProvider = configurationProvider
        self.session = session
        self.pathStatusProvider = pathStatusProvider
    }

    func testBackendReachability() async -> GalleryBackendConnectivityState {
        let configuration: GoogleDriveGalleryConfiguration
        do {
            configuration = try configurationProvider()
        } catch {
            return .invalidBackendURL(error.localizedDescription)
        }

        let pathStatus = await pathStatusProvider()
        guard pathStatus == .satisfied else {
            return .noNetworkPath
        }

        var request = URLRequest(url: configuration.webAppURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("text/html,application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
                return .wifiNoUsableInternet(host: configuration.webAppURL.host(), code: nil)
            }

            let body = String(data: data.prefix(16 * 1024), encoding: .utf8) ?? ""
            if body.localizedCaseInsensitiveContains("Gallery unavailable") {
                return .reachable
            }

            return .wifiNoUsableInternet(host: configuration.webAppURL.host(), code: nil)
        } catch let error as URLError {
            return GalleryNetworkClassifier.classify(urlError: error, fallbackHost: configuration.webAppURL.host())
        } catch {
            return .wifiNoUsableInternet(host: configuration.webAppURL.host(), code: nil)
        }
    }

    func testBackendDiagnostic() async -> GalleryBackendConnectivityState {
        let configuration: GoogleDriveGalleryConfiguration
        do {
            configuration = try configurationProvider()
        } catch {
            return .invalidBackendURL(error.localizedDescription)
        }

        guard let diagnosticURL = diagnosticURL(for: configuration.webAppURL) else {
            return .invalidBackendURL("Could not build backend diagnostic URL.")
        }

        var request = URLRequest(url: diagnosticURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
                return .wifiNoUsableInternet(host: configuration.webAppURL.host(), code: nil)
            }

            let diagnostic = try JSONDecoder().decode(GalleryBackendDiagnosticResponse.self, from: data)
            guard diagnostic.ok, diagnostic.status == "diagnostic", let backendVersion = diagnostic.backendVersion else {
                return .backendDiagnostic("Backend reachable, but the Phase 6C diagnostic marker is missing. Redeploy the existing Apps Script deployment as a new version.")
            }

            return .backendDiagnostic("Backend version: \(backendVersion). Gallery token pattern: \(diagnostic.galleryTokenPattern ?? "unknown").")
        } catch let error as URLError {
            return GalleryNetworkClassifier.classify(urlError: error, fallbackHost: configuration.webAppURL.host())
        } catch {
            return .backendDiagnostic("Backend reachable, but the Phase 6C diagnostic response could not be decoded. Redeploy the existing Apps Script deployment as a new version.")
        }
    }

    nonisolated private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 15
        return URLSession(configuration: configuration, delegate: GoogleGalleryURLSessionDelegate(), delegateQueue: nil)
    }

    private func diagnosticURL(for webAppURL: URL) -> URL? {
        var components = URLComponents(url: webAppURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "diagnostic", value: "phase6c")]
        return components?.url
    }

    private static func currentPathStatus() async -> NWPath.Status {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            let queue = DispatchQueue(label: "PocketPixels.backend-path-monitor")
            let completion = PathStatusCompletion(continuation: continuation, monitor: monitor)

            monitor.pathUpdateHandler = { path in
                completion.resume(path.status)
            }

            monitor.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 0.8) {
                completion.resume(monitor.currentPath.status)
            }
        }
    }
}

private final class PathStatusCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private let continuation: CheckedContinuation<NWPath.Status, Never>
    private let monitor: NWPathMonitor
    nonisolated(unsafe) private var didResume = false

    nonisolated init(continuation: CheckedContinuation<NWPath.Status, Never>, monitor: NWPathMonitor) {
        self.continuation = continuation
        self.monitor = monitor
    }

    nonisolated func resume(_ status: NWPath.Status) {
        lock.lock()
        defer { lock.unlock() }

        guard !didResume else {
            return
        }

        didResume = true
        continuation.resume(returning: status)
        monitor.cancel()
    }
}
