//
//  GiphyStickerProvider.swift
//  PocketPixelsBooth
//
//  GIPHY adapter built on the documented public endpoints:
//    GET https://api.giphy.com/v1/{gifs|stickers}/trending
//    GET https://api.giphy.com/v1/{gifs|stickers}/search
//  (https://developers.giphy.com/docs/api/). Every request uses rating=g. The API key is supplied
//  at runtime by the operator (keychain) and is never logged. GIPHY attribution must be shown
//  wherever results appear.
//
//  Licensing: GIPHY's API terms do not by themselves grant rights to reproduce third-party
//  content on paid physical prints. The app only enables this provider for guests after the
//  operator explicitly confirms their agreement covers that use.
//

import Foundation

nonisolated struct GiphyStickerProvider: OnlineStickerProvider {
    static let providerIdentifier = "GIPHY"
    static let attribution = "Powered by GIPHY"
    static let apiHost = "api.giphy.com"
    /// Documented API and media hosts (media0–4.giphy.com, i.giphy.com).
    static let urlPolicy = OnlineMediaURLPolicy(allowedHostSuffixes: ["giphy.com"])
    static let maximumPageSize = 24
    static let maximumResponseBytes = 1_500_000

    let providerName = GiphyStickerProvider.providerIdentifier
    let attributionText = Self.attribution
    private let apiKey: String
    private let session: URLSession

    init(apiKey: String, session: URLSession = OnlineMediaFetcher.makeSession()) {
        self.apiKey = apiKey
        self.session = session
    }

    func trending(kind: OnlineStickerKind, offset: Int, limit: Int) async throws -> OnlineStickerPage {
        try await page(Self.makeRequest(endpoint: "trending", kind: kind, query: nil, offset: offset, limit: limit, apiKey: apiKey))
    }

    func search(query: String, kind: OnlineStickerKind, offset: Int, limit: Int) async throws -> OnlineStickerPage {
        let trimmed = String(query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(50))
        guard !trimmed.isEmpty else { return try await trending(kind: kind, offset: offset, limit: limit) }
        return try await page(Self.makeRequest(endpoint: "search", kind: kind, query: trimmed, offset: offset, limit: limit, apiKey: apiKey))
    }

    func downloadMedia(_ url: URL) async throws -> Data {
        try await OnlineMediaFetcher.fetch(URLRequest(url: url), policy: Self.urlPolicy, maximumBytes: StickerImageLimits.maximumRemoteBytes, session: session)
    }

    private func page(_ request: URLRequest) async throws -> OnlineStickerPage {
        let data = try await OnlineMediaFetcher.fetch(request, policy: Self.urlPolicy, maximumBytes: Self.maximumResponseBytes, session: session)
        return try Self.parse(data)
    }

    static func makeRequest(endpoint: String, kind: OnlineStickerKind, query: String?, offset: Int, limit: Int, apiKey: String) -> URLRequest {
        var components = URLComponents()
        components.scheme = "https"
        components.host = apiHost
        components.path = "/v1/\(kind.rawValue)/\(endpoint)"
        var items = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "limit", value: String(min(max(limit, 1), maximumPageSize))),
            URLQueryItem(name: "offset", value: String(min(max(offset, 0), 4_999))),
            URLQueryItem(name: "rating", value: "g"),
            URLQueryItem(name: "bundle", value: "messaging_non_clips")
        ]
        if let query { items.append(URLQueryItem(name: "q", value: query)) }
        components.queryItems = items
        var request = URLRequest(url: components.url ?? URL(string: "https://api.giphy.com")!)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    // MARK: Parsing

    private struct Response: Decodable {
        let data: [Item]
        let pagination: Pagination?
    }

    private struct Pagination: Decodable {
        let total_count: Int?
        let count: Int?
        let offset: Int?
    }

    private struct Item: Decodable {
        let id: String
        let type: String?
        let title: String?
        let user: User?
        let images: Images
    }

    private struct User: Decodable {
        let display_name: String?
    }

    private struct Images: Decodable {
        let fixed_width_small: Rendition?
        let fixed_width: Rendition?
        let downsized: Rendition?
    }

    private struct Rendition: Decodable {
        let url: String?
        let width: String?
        let height: String?
        let size: String?
    }

    /// Converts a documented GIPHY response into results, dropping any item whose media URLs
    /// fail the host policy or whose rendition exceeds the download cap.
    static func parse(_ data: Data) throws -> OnlineStickerPage {
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
            throw OnlineStickerError.decodeFailed
        }
        let results: [OnlineStickerResult] = response.data.compactMap { item in
            let preview = item.images.fixed_width_small ?? item.images.fixed_width
            let media = item.images.fixed_width ?? item.images.downsized
            guard let previewURL = preview?.url.flatMap(URL.init(string:)),
                  let mediaURL = media?.url.flatMap(URL.init(string:)),
                  urlPolicy.isAllowed(previewURL), urlPolicy.isAllowed(mediaURL) else { return nil }
            if let size = media?.size.flatMap(Int.init), size > StickerImageLimits.maximumRemoteBytes { return nil }
            let width = media?.width.flatMap(Double.init) ?? 1
            let height = media?.height.flatMap(Double.init) ?? 1
            let creator = item.user?.display_name?.trimmingCharacters(in: .whitespacesAndNewlines)
            return OnlineStickerResult(
                id: item.id,
                title: item.title?.isEmpty == false ? item.title! : "GIPHY item",
                previewURL: previewURL,
                mediaURL: mediaURL,
                kind: item.type == "sticker" ? .stickers : .gifs,
                creatorDisplayName: creator?.isEmpty == false ? creator : nil,
                aspectRatio: height > 0 ? max(0.1, min(10, width / height)) : 1
            )
        }
        var nextOffset: Int?
        if let pagination = response.pagination, let count = pagination.count, let offset = pagination.offset, count > 0 {
            let next = offset + count
            if let total = pagination.total_count, next >= total { nextOffset = nil } else { nextOffset = next }
        }
        return OnlineStickerPage(results: results, nextOffset: nextOffset)
    }
}
