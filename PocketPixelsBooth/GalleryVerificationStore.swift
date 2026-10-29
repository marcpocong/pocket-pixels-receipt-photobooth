import CryptoKit
import Foundation

/// Independent of event reporting: one protected evidence file per frozen session + URL.
/// Neither a token nor a public link is stored in this index.
nonisolated struct GalleryVerificationStore: Sendable {
    struct Evidence: Codable, Equatable, Sendable {
        let version: Int
        let identity: String
        let verifiedAt: Date
        let source: String
    }
    static let changed = Notification.Name("GalleryVerificationEvidenceChanged")
    private static let lock = NSLock()
    let directory: URL
    private let writer: @Sendable (Data, URL) throws -> Void

    init(directory: URL? = nil, writer: (@Sendable (Data, URL) throws -> Void)? = nil) throws {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GalleryVerificationV1", isDirectory: true)
        self.writer = writer ?? { data, url in
            try DurableFileWriter.write(data, to: url)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        }
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var root = self.directory
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try root.setResourceValues(values)
    }

    static func identity(sessionID: String, token: String, url: URL) -> String {
        SHA256.hash(data: Data("1\n\(sessionID)\n\(token)\n\(url.absoluteString)".utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func evidence(sessionID: String, token: String, url: URL) throws -> Evidence? {
        Self.lock.lock(); defer { Self.lock.unlock() }
        let key = Self.identity(sessionID: sessionID, token: token, url: url)
        let path = directory.appendingPathComponent(key + ".json")
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        let evidence = try JSONDecoder().decode(Evidence.self, from: Data(contentsOf: path))
        guard evidence.version == 1, evidence.identity == key else { throw GalleryUploadError.deliveryUnknown }
        return evidence
    }

    func record(sessionID: String, token: String, url: URL, source: String, now: Date = Date()) throws {
        guard ArchivedGalleryLink(galleryURL: url, galleryToken: token).isValid else { throw GalleryUploadError.invalidGalleryURL }
        Self.lock.lock()
        do {
            let key = Self.identity(sessionID: sessionID, token: token, url: url)
            let path = directory.appendingPathComponent(key + ".json")
            if FileManager.default.fileExists(atPath: path.path) {
                let old = try JSONDecoder().decode(Evidence.self, from: Data(contentsOf: path))
                guard old.version == 1, old.identity == key else { throw GalleryUploadError.deliveryUnknown }
            } else {
                try writer(JSONEncoder().encode(Evidence(version: 1, identity: key, verifiedAt: now, source: source)), path)
            }
            Self.lock.unlock()
        } catch { Self.lock.unlock(); throw error }
        NotificationCenter.default.post(name: Self.changed, object: nil, userInfo: ["identity": Self.identity(sessionID: sessionID, token: token, url: url)])
    }
}

nonisolated struct GalleryVerificationTarget: Sendable {
    let sessionID: String
    let token: String
    let url: URL
    let photoCount: Int
    var schemaVersion: Int? = nil
    var fileCount: Int? = nil

    init(sessionID: String, token: String, url: URL, photoCount: Int, schemaVersion: Int? = nil, fileCount: Int? = nil) {
        self.sessionID = sessionID; self.token = token; self.url = url; self.photoCount = photoCount
        self.schemaVersion = schemaVersion; self.fileCount = fileCount
    }

    init(_ payload: GalleryPreparedUploadPayload) {
        self.init(sessionID: payload.sessionID, token: payload.galleryToken, url: payload.galleryURL,
            photoCount: payload.photos.count, schemaVersion: payload.schemaVersion,
            fileCount: payload.photos.count + 2 + [payload.thermalReceipt, payload.gif, payload.shareColorReceipt].compactMap { $0 }.count)
    }
}

nonisolated enum GalleryPublicVerificationError: Error { case unavailable, rateLimited(TimeInterval) }

nonisolated enum GalleryPublicVerifier {
    struct Readiness: Decodable {
        let statusVersion: Int
        let ok: Bool
        let status: String
        let galleryToken: String?
        let sessionID: String?
        let schemaVersion: Int?
        let fileCount: Int?
    }
    private static func supportedFileCount(_ count: Int, photoCount: Int, schema: Int) -> Bool {
        guard (1...6).contains(photoCount) else { return false }
        // Receipt + manifest are mandatory; schemas 2/3 also require thermal. GIF and
        // schema 3/4 share receipts are optional, and are checked exactly by the backend.
        switch schema {
        case 1: return count == photoCount + 2
        case 2: return (photoCount + 3...photoCount + 4).contains(count)
        case 3: return (photoCount + 3...photoCount + 5).contains(count)
        case 4: return (photoCount + 2...photoCount + 4).contains(count)
        default: return false
        }
    }

    /// GET only. Legacy HTML is accepted only with the existing backend completion marker.
    /// A missing page or an offline check remains unknown, never confirmed unavailable.
    static func verify(_ target: GalleryVerificationTarget, session: URLSession) async throws -> String {
        guard ArchivedGalleryLink(galleryURL: target.url, galleryToken: target.token).isValid else { throw GalleryUploadError.invalidGalleryURL }
        var components = URLComponents(url: target.url, resolvingAgainstBaseURL: false)
        let items = components?.queryItems ?? []
        components?.queryItems = items.filter { $0.name != "galleryStatus" } + [URLQueryItem(name: "galleryStatus", value: "1")]
        guard let url = components?.url else { throw GalleryUploadError.invalidGalleryURL }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("application/json,text/html;q=0.9", forHTTPHeaderField: "Accept")
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { try Task.checkCancellation(); throw error }
        try Task.checkCancellation()
        if let http = response as? HTTPURLResponse, http.statusCode == 429 {
            throw GalleryPublicVerificationError.rateLimited(GoogleDriveGalleryUploadService.retryAfter(http.value(forHTTPHeaderField: "Retry-After")))
        }
        if let finalURL = response.url, let items = URLComponents(url: finalURL, resolvingAgainstBaseURL: false)?.queryItems,
           items.contains(where: { $0.name == "g" && $0.value != target.token }) { throw GalleryUploadError.deliveryUnknown }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw GalleryUploadError.deliveryUnknown }
        if let status = try? JSONDecoder().decode(Readiness.self, from: data) {
            if status.statusVersion == 1, !status.ok, status.status == "unavailable" { throw GalleryPublicVerificationError.unavailable }
            guard status.statusVersion == 1, status.ok, status.status == "complete",
                  status.galleryToken == target.token, status.sessionID == target.sessionID,
                  let schema = status.schemaVersion, (1...4).contains(schema),
                  let files = status.fileCount,
                  supportedFileCount(files, photoCount: target.photoCount, schema: schema),
                  target.schemaVersion == nil || target.schemaVersion == schema,
                  target.fileCount == nil || target.fileCount == files else { throw GalleryUploadError.deliveryUnknown }
            return "public-readiness-v1"
        }
        guard let html = String(data: data, encoding: .utf8), html.contains("data-pocket-pixels-gallery-status=\"complete\"") else { throw GalleryUploadError.deliveryUnknown }
        return "legacy-complete-page"
    }
}
