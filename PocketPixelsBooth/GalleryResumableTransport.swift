import CryptoKit
import Foundation

nonisolated struct GalleryTransferJournal: Codable, Sendable {
    struct Asset: Codable, Sendable {
        let filename: String
        let sha256: String
        let bytes: Int
        var uploadURL: URL?
        var confirmedBytes = 0
        var stored = false
    }
    var version = 1
    let endpoint: URL
    var stage = "Saved locally"
    var assets: [String: Asset] = [:]
}

@MainActor final class GalleryResumableTransport {
    nonisolated struct Descriptor: Codable, Sendable {
        let filename: String
        let mimeType: String
        let bytes: Int
        let sha256: String
        init(_ image: GalleryStoredUploadImage) {
            filename = image.filename; mimeType = image.mimeType; bytes = image.data.count
            sha256 = SHA256.hash(data: image.data).map { String(format: "%02x", $0) }.joined()
        }
    }
    nonisolated struct Command: Encodable, Sendable {
        var transport = "drive-resumable-v1"
        var action = "initialize"
        let deviceToken: String
        let schemaVersion: Int
        let galleryToken: String
        let sessionID: String
        let createdAt: String
        let photos: [Descriptor]
        let receipt: Descriptor?
        let colorReceipt: Descriptor?
        let thermalReceipt: Descriptor?
        let gif: Descriptor?
        let shareColorReceipt: Descriptor?
        let receiptVariants: GalleryReceiptVariants?
        var expiredAsset: String?
        init(_ payload: GalleryPreparedUploadPayload, deviceToken: String) {
            self.deviceToken = deviceToken; schemaVersion = payload.schemaVersion; galleryToken = payload.galleryToken
            sessionID = payload.sessionID; createdAt = payload.createdAt
            photos = payload.photos.map(Descriptor.init)
            receipt = payload.schemaVersion == 1 ? Descriptor(payload.colorReceipt) : nil
            colorReceipt = payload.schemaVersion == 1 ? nil : Descriptor(payload.colorReceipt)
            thermalReceipt = payload.thermalReceipt.map(Descriptor.init); gif = payload.gif.map(Descriptor.init)
            shareColorReceipt = payload.shareColorReceipt.map(Descriptor.init); receiptVariants = payload.receiptVariants
        }
        var descriptors: [Descriptor] { photos + [receipt, colorReceipt, thermalReceipt, gif, shareColorReceipt].compactMap { $0 } }
    }
    nonisolated struct Reply: Decodable, Sendable {
        struct Asset: Decodable, Sendable {
            let filename: String; let bytes: Int; let sha256: String; let stored: Bool; let uploadURL: URL?
        }
        let ok: Bool
        let transport: String?
        let galleryToken: String?
        let status: String?
        let errorCode: String?
        let assets: [Asset]?
    }
    private let session: URLSession
    private let controlSession: URLSession
    private let store: GalleryPendingUploadStore
    private let scheduler: GalleryUploadScheduler
    private static var capabilities: [URL: (supported: Bool, expires: Date)] = [:]

    init(session: URLSession, store: GalleryPendingUploadStore, scheduler: GalleryUploadScheduler) {
        self.session = session; self.store = store; self.scheduler = scheduler
        let control = session.configuration
        control.waitsForConnectivity = false
        control.timeoutIntervalForRequest = 60
        control.timeoutIntervalForResource = 120
        self.controlSession = URLSession(configuration: control, delegate: GoogleGalleryURLSessionDelegate(), delegateQueue: nil)
    }

    func supports(_ endpoint: URL) async -> Bool {
        if let known = Self.capabilities[endpoint], known.expires > Date() { return known.supported }
        var url = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        url.queryItems = [URLQueryItem(name: "diagnostic", value: "phase6c")]
        do {
            let (data, response) = try await controlSession.data(for: URLRequest(url: url.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15))
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return false }
            let body = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let supported = (body?["uploadTransports"] as? [String])?.contains("drive-resumable-v1") == true
            Self.capabilities[endpoint] = (supported, Date().addingTimeInterval(300))
            return supported
        } catch { return false }
    }

    func upload(_ payload: GalleryPreparedUploadPayload, deviceToken: String, endpoint: URL) async throws -> GalleryUploadResult {
        let command = await Task.detached(priority: .utility) { Command(payload, deviceToken: deviceToken) }.value
        var journal = try await disk { try $0.transferJournal(galleryToken: payload.galleryToken) }
            ?? GalleryTransferJournal(endpoint: endpoint)
        for descriptor in command.descriptors {
            if let saved = journal.assets[descriptor.filename] {
                guard saved.sha256 == descriptor.sha256, saved.bytes == descriptor.bytes else {
                    throw GalleryUploadError.conflictManualInspection("Saved transfer identity needs inspection. Media is retained.")
                }
            } else {
                journal.assets[descriptor.filename] = .init(filename: descriptor.filename, sha256: descriptor.sha256, bytes: descriptor.bytes)
            }
        }
        // Persist protocol choice before any backend mutation. Rollback must never
        // fall back to a full legacy POST over reserved/partially uploaded files.
        try await save(journal, token: payload.galleryToken)
        let initial = try await coordinate(command, endpoint: journal.endpoint)
        if initial.reply.status == "existingComplete" { return try completeResult(initial.data, payload: payload) }
        try apply(initial.reply, to: &journal)
        try await save(journal, token: payload.galleryToken)
        let images = payload.photos + [payload.colorReceipt] + [payload.thermalReceipt, payload.gif, payload.shareColorReceipt].compactMap { $0 }
        let pending = images.filter { journal.assets[$0.filename]?.stored != true }
        let initialAssets = journal.assets
        let transferEndpoint = journal.endpoint
        try await withThrowingTaskGroup(of: Void.self) { group in
            var next = 0, active = 0
            func submit() {
                let image = pending[next]
                let asset = initialAssets[image.filename]!
                next += 1; active += 1
                group.addTask { @MainActor [self] in
                    try await transferAsset(image, initial: asset, command: command, token: payload.galleryToken, endpoint: transferEndpoint)
                }
            }
            while next < pending.count && active < GalleryTransferTelemetry.shared.recommendedAssetConcurrency { submit() }
            while try await group.next() != nil {
                active -= 1
                while next < pending.count && active < GalleryTransferTelemetry.shared.recommendedAssetConcurrency { submit() }
            }
        }
        // Merge per-asset commits made by bounded concurrent senders. Never write
        // an earlier gallery-wide snapshot over another asset's newer offset.
        journal = try await disk { try $0.transferJournal(galleryToken: payload.galleryToken) } ?? journal
        journal.stage = "Remotely stored"; try await save(journal, token: payload.galleryToken)
        await scheduler.beginVerification(token: payload.galleryToken)
        journal.stage = "Publishing"; try await save(journal, token: payload.galleryToken)
        scheduler.report("Media is stored remotely. Publishing the gallery.", phase: .verifying)
        var finalize = command; finalize.action = "finalize"
        let final = try await coordinate(finalize, endpoint: journal.endpoint)
        return try completeResult(final.data, payload: payload)
    }

    private func transferAsset(_ image: GalleryStoredUploadImage, initial: GalleryTransferJournal.Asset,
                               command: Command, token: String, endpoint: URL) async throws {
        var asset = initial
        for renewal in 0...1 {
            do { try await transfer(image, asset: &asset, token: token); return }
            catch GalleryResumableError.expired {
                guard renewal == 0 else { throw GalleryUploadError.network("Upload session renewal is waiting. Media is retained.") }
                var refresh = command; refresh.expiredAsset = image.filename
                let result = try await coordinate(refresh, endpoint: endpoint)
                if result.reply.status == "existingComplete" { return }
                guard let remote = result.reply.assets?.first(where: { $0.filename == image.filename }),
                      remote.sha256 == asset.sha256, remote.bytes == asset.bytes,
                      remote.stored || remote.uploadURL.map(Self.validSessionURL) == true else { throw GalleryUploadError.deliveryUnknown }
                asset.uploadURL = remote.uploadURL; asset.stored = remote.stored
                asset.confirmedBytes = remote.stored ? asset.bytes : 0
                try await record(asset, token: token)
                if asset.stored { return }
            }
        }
    }

    private func transfer(_ image: GalleryStoredUploadImage, asset: inout GalleryTransferJournal.Asset,
                          token: String) async throws {
        guard let url = asset.uploadURL, Self.validSessionURL(url) else { throw GalleryUploadError.deliveryUnknown }
        var probe = URLRequest(url: url); probe.httpMethod = "PUT"; probe.timeoutInterval = 30
        probe.setValue("bytes */\(asset.bytes)", forHTTPHeaderField: "Content-Range")
        probe.setValue("0", forHTTPHeaderField: "Content-Length")
        let probeStart = ProcessInfo.processInfo.systemUptime
        let (_, response) = try await controlSession.data(for: probe)
        GalleryPerformance.record(.resumableReconciliation, since: probeStart)
        guard let http = response as? HTTPURLResponse else { throw GalleryUploadError.deliveryUnknown }
        if [200,201].contains(http.statusCode) { asset.stored = true; asset.confirmedBytes = asset.bytes }
        else if http.statusCode == 308 { asset.confirmedBytes = try Self.confirmedOffset(http.value(forHTTPHeaderField: "Range"), total: asset.bytes) }
        else { try Self.checkStatus(http); throw GalleryUploadError.deliveryUnknown }
        try await record(asset, token: token)
        while !asset.stored && asset.confirmedBytes < asset.bytes {
            let start = asset.confirmedBytes
            let end = min(asset.bytes, start + 256 * 1024)
            let chunk = image.data.subdata(in: start..<end)
            let filename = image.filename
            let file = try await disk { try $0.writeTransferChunk(chunk, galleryToken: token, assetFilename: filename) }
            var request = URLRequest(url: url); request.httpMethod = "PUT"; request.timeoutInterval = 90
            request.setValue(image.mimeType, forHTTPHeaderField: "Content-Type")
            request.setValue("bytes \(start)-\(end-1)/\(asset.bytes)", forHTTPHeaderField: "Content-Range")
            let (_, response) = try await GalleryTransferObserver.upload(session: session, request: request, file: file)
            guard let response = response as? HTTPURLResponse else { throw GalleryUploadError.deliveryUnknown }
            if [200,201].contains(response.statusCode) { asset.stored = true; asset.confirmedBytes = asset.bytes }
            else if response.statusCode == 308 {
                let confirmed = try Self.confirmedOffset(response.value(forHTTPHeaderField: "Range"), total: asset.bytes)
                guard confirmed > start, confirmed <= end else { throw GalleryUploadError.deliveryUnknown }
                asset.confirmedBytes = confirmed
            } else { try Self.checkStatus(response); throw GalleryUploadError.deliveryUnknown }
            try await record(asset, token: token)
        }
        guard asset.stored else { throw GalleryUploadError.deliveryUnknown }
    }

    private func record(_ asset: GalleryTransferJournal.Asset, token: String) async throws {
        try await disk { try $0.recordTransferAsset(asset, galleryToken: token) }
    }

    private func coordinate(_ command: Command, endpoint: URL) async throws -> (reply: Reply, data: Data) {
        let start = ProcessInfo.processInfo.systemUptime
        var succeeded = false
        defer { GalleryPerformance.record(.coordination, since: start, succeeded: succeeded) }
        var request = URLRequest(url: endpoint); request.httpMethod = "POST"; request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(command)
        let (data, response) = try await controlSession.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw GalleryUploadError.deliveryUnknown }
        if response.statusCode != 200 { try Self.checkStatus(response) }
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        guard reply.ok else {
            if ["MISSING_DEVICE_TOKEN","INVALID_DEVICE_TOKEN","SERVER_NOT_CONFIGURED"].contains(reply.errorCode ?? "") { throw GalleryUploadError.unauthorized }
            if reply.status == "manualInspectionRequired" { throw GalleryUploadError.conflictManualInspection("Gallery integrity needs inspection. Media is retained.") }
            if reply.status == "retryable" {
                if reply.errorCode == "UPLOAD_SERVICE_BUSY" { throw GalleryUploadError.rateLimited(30) }
                // Apps Script returns its logical status in JSON. A temporary
                // Drive outage is not a server-imposed cooldown: a new usable
                // path may retry it while actual busy/rate-limit gates remain.
                throw GalleryUploadError.network("Gallery coordination is temporarily unavailable. Media is retained.")
            }
            throw GalleryUploadError.configuration("Gallery transfer configuration needs inspection. Media is retained.")
        }
        guard reply.transport == "drive-resumable-v1", reply.galleryToken == command.galleryToken else { throw GalleryUploadError.deliveryUnknown }
        succeeded = true
        return (reply, data)
    }

    private func apply(_ reply: Reply, to journal: inout GalleryTransferJournal) throws {
        guard let assets = reply.assets, assets.count == journal.assets.count, Set(assets.map(\.filename)).count == assets.count else { throw GalleryUploadError.deliveryUnknown }
        for remote in assets {
            guard var asset = journal.assets[remote.filename], asset.sha256 == remote.sha256, asset.bytes == remote.bytes else { throw GalleryUploadError.deliveryUnknown }
            guard remote.stored || remote.uploadURL.map(Self.validSessionURL) == true else { throw GalleryUploadError.deliveryUnknown }
            asset.stored = remote.stored; asset.uploadURL = remote.uploadURL
            if remote.stored { asset.confirmedBytes = asset.bytes }
            journal.assets[remote.filename] = asset
        }
    }

    private func completeResult(_ data: Data, payload: GalleryPreparedUploadPayload) throws -> GalleryUploadResult {
        let response = try JSONDecoder().decode(GalleryUploadResponse.self, from: data)
        guard GoogleDriveGalleryUploadService.validateSuccessfulResponse(response, expectedGalleryToken: payload.galleryToken,
            expectedGalleryURL: payload.galleryURL, expectedPhotoCount: payload.photos.count,
            expectedGIFIncluded: payload.gif != nil, expectedShareReceiptIncluded: payload.shareColorReceipt != nil) else { throw GalleryUploadError.deliveryUnknown }
        return GalleryUploadResult(galleryToken: payload.galleryToken, galleryURL: payload.galleryURL, status: .init(serverStatus: response.status))
    }

    private func disk<T: Sendable>(_ work: @escaping @Sendable (GalleryPendingUploadStore) throws -> T) async throws -> T {
        let store = self.store
        return try await GalleryDiskIO.shared.run { try work(store) }
    }
    private func save(_ journal: GalleryTransferJournal, token: String) async throws {
        try await disk { try $0.saveTransferJournal(journal, galleryToken: token) }
    }
    nonisolated static func validSessionURL(_ url: URL) -> Bool {
        url.scheme == "https" && url.host()?.lowercased() == "www.googleapis.com" && url.path == "/upload/drive/v3/files" &&
            url.user == nil && url.password == nil && url.fragment == nil && url.port == nil &&
            URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains(where: { $0.name == "upload_id" && !($0.value ?? "").isEmpty }) == true
    }
    nonisolated static func confirmedOffset(_ range: String?, total: Int) throws -> Int {
        guard let range else { return 0 }
        guard range.hasPrefix("bytes=0-"), let last = Int(range.dropFirst(8)), last >= 0, last < total else { throw GalleryUploadError.deliveryUnknown }
        return last + 1
    }
    nonisolated private static func checkStatus(_ response: HTTPURLResponse) throws {
        switch response.statusCode {
        case 404,410: throw GalleryResumableError.expired
        case 408,409,416: throw GalleryUploadError.deliveryUnknown
        case 401,403: throw GalleryUploadError.unauthorized
        case 429,503: throw GalleryUploadError.rateLimited(GoogleDriveGalleryUploadService.retryAfter(response.value(forHTTPHeaderField: "Retry-After")))
        default: throw GalleryUploadError.httpStatus(response.statusCode)
        }
    }
}

nonisolated enum GalleryResumableError: Error { case expired }
