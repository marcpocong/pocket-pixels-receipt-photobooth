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

    nonisolated static let maxFileDecodedBytes = 6 * 1024 * 1024
    nonisolated static let maxTotalDecodedBytes = 20 * 1024 * 1024
    nonisolated static let maxEstimatedBase64JSONBytes = 28 * 1024 * 1024
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
    let receipt: GalleryStoredUploadImage
    let metrics: GalleryPreparedUploadMetrics
    let deliveryState: GalleryDeliveryState
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
