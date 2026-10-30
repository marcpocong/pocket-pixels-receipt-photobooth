import XCTest
import UIKit
import ImageIO
import UniformTypeIdentifiers
@testable import PocketPixelsBooth

/// Local only: URLProtocol intercepts every request. Timed delays model an origin, not Drive SLA.
@MainActor final class GalleryPipelineBenchmarkTests: XCTestCase {
    func testSyntheticConsecutiveGuestMatrix() async throws {
        var rows: [[String: Any]] = []
        for count in [1, 3, 6] {
            let photos = (0..<count).map { Self.photo(seed: UInt32($0 + 1)) }
            let format: BoothFormat = count == 1 ? .solo : count == 3 ? .strip : .gridSix
            let date = Date(timeIntervalSince1970: 1_793_318_400)
            let receipt = try ReceiptComposer.compose(photos: photos, sessionIdentifier: "PP-20261030-120000", date: date, format: format)
            let receiptImage = try XCTUnwrap(UIImage(data: receipt.imagePNGData))
            for guests in [1, 5, 20] {
                let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: root) }
                let store = try GalleryPendingUploadStore(directoryURL: root)
                let proof = try GalleryVerificationStore(directory: root.appendingPathComponent("proof"))
                let configuration = URLSessionConfiguration.ephemeral
                configuration.protocolClasses = [PipelineBenchmarkProtocol.self]
                PipelineBenchmarkProtocol.reset()
                let service = GoogleDriveGalleryUploadService(
                    configurationProvider: { try GoogleDriveGalleryConfiguration.validate(rawValue: "https://script.google.com/macros/s/SYNTHETIC/exec") },
                    customerGalleryConfigurationProvider: { try CustomerGalleryConfiguration.validate(rawValue: "https://benchmark.example.test/") },
                    urlSession: URLSession(configuration: configuration), pendingStore: store, verificationStore: proof,
                    scheduler: GalleryUploadScheduler(), onPublicGalleryVerified: { _ in })
                var preparation: [Double] = [], persistence: [Double] = [], tokens: [String] = []
                // Real image preparation and atomic queue persistence; reuse identical deterministic inputs.
                for guest in 0..<guests {
                    let token = String(format: "%064x", guest + 1)
                    tokens.append(token)
                    let start = ProcessInfo.processInfo.systemUptime
                    let payload = try GoogleDriveGalleryUploadService.preparePayload(photos: photos, composedReceipt: receiptImage,
                        sessionID: "PP-20261030-120000", createdAt: date, galleryToken: token,
                        customerGalleryBaseURL: URL(string: "https://benchmark.example.test/")!,
                        receiptVariants: GalleryReceiptVariants(originalFooterStyle: .decorativeBarcodeOnly, defaultStyle: .shareFriendly))
                    preparation.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
                    let disk = ProcessInfo.processInfo.systemUptime
                    try store.save(payload)
                    persistence.append((ProcessInfo.processInfo.systemUptime - disk) * 1000)
                }
                let start = ProcessInfo.processInfo.systemUptime
                let tasks = tokens.map { token in Task { () throws -> Double in
                    PipelineBenchmarkProtocol.enqueue(token)
                    _ = try await service.uploadPendingGallery(galleryToken: token, deviceToken: "synthetic-only-placeholder-token")
                    return (ProcessInfo.processInfo.systemUptime - start) * 1000
                } }
                var completion: [Double] = []
                for task in tasks { completion.append(try await task.value) }
                XCTAssertTrue(try store.summaries().isEmpty)
                XCTAssertEqual(PipelineBenchmarkProtocol.postCount, guests)
                let row: [String: Any] = ["photos": count, "guests": guests, "preparationMs": Self.stats(preparation),
                    "persistenceMs": Self.stats(persistence), "completionMs": Self.stats(completion),
                    "queueToPOSTMs": Self.stats(PipelineBenchmarkProtocol.queueWaits),
                    "requestBytes": PipelineBenchmarkProtocol.bytes, "totalMs": completion.max() ?? 0]
                rows.append(row)
                print("GALLERY_BENCHMARK \(String(data: try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]), encoding: .utf8)!)")
            }
        }
        let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("DerivedData/gallery-benchmark-latest.json")
        try JSONSerialization.data(withJSONObject: ["environment": "iOS simulator, Debug, synthetic POST 20ms / verification 80ms; all guests queued together after preparation", "rows": rows], options: [.prettyPrinted, .sortedKeys]).write(to: output, options: .atomic)
    }

    func testJPEGEncoderCandidateBenchmark() throws {
        let photo = Self.photo(seed: 1).normalizedForGalleryUpload()
        var ui: [Double] = [], io: [Double] = []
        var equal = true
        for _ in 0..<10 {
            let start = ProcessInfo.processInfo.systemUptime
            let original = try XCTUnwrap(photo.jpegData(compressionQuality: 0.78))
            ui.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
            let next = ProcessInfo.processInfo.systemUptime
            let data = NSMutableData()
            let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, try XCTUnwrap(photo.cgImage), [kCGImageDestinationLossyCompressionQuality: 0.78] as CFDictionary)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            io.append((ProcessInfo.processInfo.systemUptime - next) * 1000)
            equal = equal && original == data as Data
        }
        print("GALLERY_JPEG_CANDIDATE UIKit=\(Self.stats(ui)) ImageIO=\(Self.stats(io)) byteIdentical=\(equal)")
    }

    static func stats(_ values: [Double]) -> [String: Double] {
        let sorted = values.sorted()
        func percentile(_ p: Double) -> Double { sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, max(0, Int(ceil(Double(sorted.count) * p)) - 1))] }
        return ["p50": percentile(0.5), "p95": percentile(0.95), "max": sorted.last ?? 0]
    }

    static func photo(seed: UInt32) -> UIImage {
        let width = 1600, height = 1200
        var state = seed
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for i in stride(from: 0, to: bytes.count, by: 4) {
            state = 1664525 &* state &+ 1013904223
            let level = UInt8(truncatingIfNeeded: state >> 24)
            bytes[i] = level; bytes[i + 1] = level; bytes[i + 2] = level
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return UIImage(cgImage: CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!)
    }
}

private final class PipelineBenchmarkProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var enqueued: [String: Double] = [:]
    nonisolated(unsafe) static var queueWaits: [Double] = []
    nonisolated(unsafe) static var bytes = 0
    nonisolated(unsafe) static var postCount = 0
    static func reset() { lock.lock(); defer { lock.unlock() }; enqueued = [:]; queueWaits = []; bytes = 0; postCount = 0 }
    static func enqueue(_ token: String) { lock.lock(); defer { lock.unlock() }; enqueued[token] = ProcessInfo.processInfo.systemUptime }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    private var pending: DispatchWorkItem?
    override func startLoading() {
        let post = request.httpMethod == "POST"
        var body = request.httpBody ?? Data()
        if post, body.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 65536)
            while stream.hasBytesAvailable { let size = stream.read(&buffer, maxLength: buffer.count); if size <= 0 { break }; body.append(contentsOf: buffer.prefix(size)) }
        }
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let token = json?["galleryToken"] as? String ?? URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "g" }!.value!
        if post {
            Self.lock.lock()
            Self.bytes += body.count; Self.postCount += 1
            Self.queueWaits.append((ProcessInfo.processInfo.systemUptime - (Self.enqueued[token] ?? 0)) * 1000)
            Self.lock.unlock()
        }
        let response: [String: Any] = post
            ? ["ok": true, "schemaVersion": 4, "galleryToken": token, "galleryURL": "https://benchmark.example.test/?g=\(token)", "fileCount": (json?["photos"] as? [Any])!.count + 2, "status": "created"]
            : [:]
        let data = post ? try! JSONSerialization.data(withJSONObject: response) : Data("<main data-pocket-pixels-gallery-status=\"complete\"></main>".utf8)
        let work = DispatchWorkItem { [self] in
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (post ? 0.02 : 0.08), execute: work)
    }
    override func stopLoading() { pending?.cancel() }
}
