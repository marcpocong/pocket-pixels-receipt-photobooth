//
//  OnlineStickerProvider.swift
//  PocketPixelsBooth
//
//  Optional online sticker discovery. Everything here is inert unless the operator has saved
//  an API key AND confirmed that their licence covers printing third-party media on paid
//  receipts (see StickerStudioSessionConfiguration). Results are never cached to disk or
//  indexed; selected media is downloaded once into memory for the current guest only.
//

import Foundation

nonisolated enum OnlineStickerKind: String, CaseIterable, Sendable {
    case stickers
    case gifs

    var displayName: String {
        switch self {
        case .stickers: "Stickers"
        case .gifs: "GIFs"
        }
    }
}

nonisolated struct OnlineStickerResult: Identifiable, Equatable, Sendable {
    /// Provider content ID.
    let id: String
    let title: String
    /// Small animated rendition for the browsing grid.
    let previewURL: URL
    /// Larger rendition decoded once, at a bounded size, for the printed still frame.
    let mediaURL: URL
    let kind: OnlineStickerKind
    let creatorDisplayName: String?
    /// width / height
    let aspectRatio: Double
}

nonisolated struct OnlineStickerPage: Equatable, Sendable {
    let results: [OnlineStickerResult]
    /// Offset for the next page; nil when exhausted.
    let nextOffset: Int?
}

nonisolated enum OnlineStickerError: Error, LocalizedError, Equatable {
    case unavailable
    case disallowedURL
    case badResponse(Int)
    case tooLarge
    case decodeFailed
    case rateLimited

    var errorDescription: String? {
        switch self {
        case .unavailable: OnlineStickerAvailability.unavailableMessage
        case .disallowedURL: "That media address is not allowed."
        case .badResponse(let status): "The online catalog returned an error (\(status))."
        case .tooLarge: "That item is too large to use."
        case .decodeFailed: "The online catalog response could not be read."
        case .rateLimited: "The online catalog is busy. Try again in a moment."
        }
    }
}

nonisolated protocol OnlineStickerProvider: Sendable {
    var providerName: String { get }
    /// Required on-screen attribution wherever results are shown.
    var attributionText: String { get }
    func trending(kind: OnlineStickerKind, offset: Int, limit: Int) async throws -> OnlineStickerPage
    func search(query: String, kind: OnlineStickerKind, offset: Int, limit: Int) async throws -> OnlineStickerPage
    /// Downloads media bytes with URL policy, redirect and size limits enforced.
    func downloadMedia(_ url: URL) async throws -> Data
}

// MARK: - URL policy

/// Remote media may only come from HTTPS hosts the provider documents. No other schemes,
/// localhost, IP literals, credentials in URLs, non-standard ports or foreign redirects.
nonisolated struct OnlineMediaURLPolicy: Sendable {
    let allowedHostSuffixes: [String]
    var maximumRedirects = 3

    func isAllowed(_ url: URL?) -> Bool {
        guard let url,
              url.scheme?.lowercased() == "https",
              url.user == nil, url.password == nil,
              url.port == nil || url.port == 443,
              let host = url.host?.lowercased(), !host.isEmpty else { return false }
        if host == "localhost" || host.hasSuffix(".local") || host.hasSuffix(".localhost") { return false }
        // Reject IPv4 / IPv6 literals.
        if host.contains(":") || host.split(separator: ".").allSatisfy({ Int($0) != nil }) { return false }
        return allowedHostSuffixes.contains { host == $0 || host.hasSuffix("." + $0) }
    }
}

/// Enforces the URL policy and a hop limit on every redirect.
nonisolated final class OnlineMediaRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let policy: OnlineMediaURLPolicy
    private let lock = NSLock()
    private var redirects = 0

    init(policy: OnlineMediaURLPolicy) { self.policy = policy }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        let count = lock.withLock { () -> Int in redirects += 1; return redirects }
        guard count <= policy.maximumRedirects, policy.isAllowed(request.url) else {
            task.cancel()
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

nonisolated enum OnlineMediaFetcher {
    /// Ephemeral session: no disk cache, no cookies, short timeouts.
    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.httpMaximumConnectionsPerHost = StickerImageLimits.maximumConcurrentDownloads
        return URLSession(configuration: configuration)
    }

    static func fetch(_ request: URLRequest, policy: OnlineMediaURLPolicy, maximumBytes: Int, session: URLSession) async throws -> Data {
        guard policy.isAllowed(request.url) else { throw OnlineStickerError.disallowedURL }
        let delegate = OnlineMediaRedirectGuard(policy: policy)
        let (bytes, response) = try await session.bytes(for: request, delegate: delegate)
        guard let http = response as? HTTPURLResponse else { throw OnlineStickerError.decodeFailed }
        guard policy.isAllowed(http.url) else { throw OnlineStickerError.disallowedURL }
        if http.statusCode == 429 { throw OnlineStickerError.rateLimited }
        guard (200..<300).contains(http.statusCode) else { throw OnlineStickerError.badResponse(http.statusCode) }
        if http.expectedContentLength > Int64(maximumBytes) { throw OnlineStickerError.tooLarge }
        var data = Data()
        data.reserveCapacity(min(maximumBytes, max(0, Int(http.expectedContentLength))))
        for try await byte in bytes {
            data.append(byte)
            if data.count > maximumBytes { throw OnlineStickerError.tooLarge }
        }
        return data
    }
}
