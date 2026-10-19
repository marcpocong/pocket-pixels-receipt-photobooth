import CoreGraphics
import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import PocketPixelsBooth

// MARK: - Fixtures

/// Deterministic fake online provider. Never touches the network.
final class FakeOnlineStickerProvider: OnlineStickerProvider, @unchecked Sendable {
    let providerName = "FAKE"
    let attributionText = "Powered by FAKE"
    private let lock = NSLock()
    private var _calls: [String] = []
    private var _cancellations = 0
    let downloadDelay: Duration
    let media: Data

    init(downloadDelay: Duration = .zero, media: Data = StickerFixtures.pngData(width: 120, height: 80, opaqueFraction: 1)) {
        self.downloadDelay = downloadDelay
        self.media = media
    }

    var calls: [String] { lock.withLock { _calls } }
    var cancellations: Int { lock.withLock { _cancellations } }

    private func record(_ call: String) { lock.withLock { _calls.append(call) } }

    func trending(kind: OnlineStickerKind, offset: Int, limit: Int) async throws -> OnlineStickerPage {
        record("trending:\(kind.rawValue):\(offset)")
        return OnlineStickerPage(results: [Self.result(id: "t1")], nextOffset: nil)
    }

    func search(query: String, kind: OnlineStickerKind, offset: Int, limit: Int) async throws -> OnlineStickerPage {
        record("search:\(query)")
        return OnlineStickerPage(results: [Self.result(id: "s1")], nextOffset: nil)
    }

    func downloadMedia(_ url: URL) async throws -> Data {
        record("download:\(url.lastPathComponent)")
        do {
            try await Task.sleep(for: downloadDelay)
        } catch {
            lock.withLock { _cancellations += 1 }
            throw error
        }
        return media
    }

    static func result(id: String) -> OnlineStickerResult {
        OnlineStickerResult(
            id: id,
            title: "Fake \(id)",
            previewURL: URL(string: "https://media1.giphy.com/media/\(id)/preview.gif")!,
            mediaURL: URL(string: "https://media1.giphy.com/media/\(id)/full.gif")!,
            kind: .stickers,
            creatorDisplayName: nil,
            aspectRatio: 1.5
        )
    }
}

enum StickerFixtures {
    static let date = Date(timeIntervalSince1970: 1_788_692_040)

    static func photos(for format: BoothFormat, seed: Int = 1) -> [UIImage] {
        (0..<format.photoCount).map { index in
            let landscape = format == .passport && index == PhotoPassReceiptLayout.heroPhotoIndex
            let size = landscape ? CGSize(width: 800, height: 600) : CGSize(width: 600, height: 800)
            let rendererFormat = UIGraphicsImageRendererFormat()
            rendererFormat.scale = 1
            rendererFormat.opaque = true
            return UIGraphicsImageRenderer(size: size, format: rendererFormat).image { context in
                UIColor(white: 0.55 + CGFloat((seed + index) % 4) * 0.08, alpha: 1).setFill()
                context.fill(CGRect(origin: .zero, size: size))
                UIColor(white: 0.25, alpha: 1).setFill()
                context.cgContext.fillEllipse(in: CGRect(x: size.width * 0.3, y: size.height * 0.2, width: size.width * 0.4, height: size.height * 0.4))
            }
        }
    }

    /// PNG whose left `opaqueFraction` is solid black and the rest fully transparent.
    static func pngData(width: Int, height: Int, opaqueFraction: CGFloat) -> Data {
        let rendererFormat = UIGraphicsImageRendererFormat()
        rendererFormat.scale = 1
        rendererFormat.opaque = false
        let image = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: rendererFormat).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(x: 0, y: 0, width: CGFloat(width) * opaqueFraction, height: CGFloat(height)))
        }
        return image.pngData()!
    }

    static func solidImage(width: Int = 200, height: Int = 200, opaqueFraction: CGFloat = 1) -> CGImage {
        let data = pngData(width: width, height: height, opaqueFraction: opaqueFraction)
        return try! StickerPrintPreparation.prepare(try! StickerImageDecoder.decodeFrame(data))
    }

    /// Animated GIF whose frame i is a solid grey of value `levels[i]`.
    static func gifData(levels: [UInt8], size: Int = 64) -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, levels.count, nil)!
        for level in levels {
            let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(red: CGFloat(level) / 255, green: CGFloat(level) / 255, blue: CGFloat(level) / 255, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: size, height: size))
            CGImageDestinationAddImage(destination, context.makeImage()!, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]] as CFDictionary)
        }
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    static func placement(target: StickerTarget, x: Double = 0.5, y: Double = 0.5, scale: Double = 0.5, rotation: Double = 0, aspect: Double = 1, z: Int = 0) -> StickerPlacement {
        StickerPlacement(id: UUID(), assetID: "test.solid", assetName: "Solid", provenance: .builtIn, frameIndex: 0, target: target, centerX: x, centerY: y, scale: scale, rotation: rotation, zOrder: z, aspectRatio: aspect)
    }

    static func compose(_ format: BoothFormat, stickers: [FrozenStickerDecoration] = [], includeQR: Bool = true, passport: PassportSessionData? = nil) throws -> ComposedReceipt {
        var options = ReceiptPrintOptions.default
        options.includesPrintedGalleryQR = includeQR
        return try ReceiptComposer.compose(
            photos: photos(for: format),
            sessionIdentifier: "PP-20260907-161400",
            date: date,
            galleryURL: URL(string: "https://example.com/g/\(String(repeating: "a", count: 32))"),
            format: format,
            passport: format == .passport ? (passport ?? .photoPassDebugFixture) : nil,
            printOptions: options,
            stickers: stickers
        )
    }

    struct Bitmap {
        let width: Int
        let height: Int
        let bytes: [UInt8]

        init(pngData: Data) {
            let image = UIImage(data: pngData)!.cgImage!
            width = image.width
            height = image.height
            var buffer = [UInt8](repeating: 0, count: width * height * 4)
            let context = CGContext(data: &buffer, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            bytes = buffer
        }

        func pixel(_ x: Int, _ y: Int) -> UInt8 { bytes[(y * width + x) * 4] }

        /// Points (top-left origin) where two bitmaps differ.
        func differences(from other: Bitmap) -> [CGPoint] {
            precondition(width == other.width && height == other.height)
            var points: [CGPoint] = []
            for y in 0..<height {
                for x in 0..<width {
                    let index = (y * width + x) * 4
                    if bytes[index] != other.bytes[index] || bytes[index + 1] != other.bytes[index + 1] || bytes[index + 2] != other.bytes[index + 2] {
                        points.append(CGPoint(x: x, y: y))
                    }
                }
            }
            return points
        }
    }
}

// MARK: - Settings and operator controls

@MainActor
final class StickerStudioSettingsTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        suiteName = "StickerStudioTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testMasterToggleDefaultsOffForNewAndPreMigrationInstalls() throws {
        XCTAssertFalse(StickerStudioSettingsStore.load(defaults: defaults).isEnabled, "Fresh installs start OFF")
        XCTAssertFalse(StickerStudioSettings.default.isEnabled)
        defaults.set(Data("{}".utf8), forKey: StickerStudioSettingsStore.storageKey)
        XCTAssertFalse(StickerStudioSettingsStore.load(defaults: defaults).isEnabled, "An empty legacy record stays OFF")
        defaults.set(Data(#"{"schemaVersion":0,"futureField":true}"#.utf8), forKey: StickerStudioSettingsStore.storageKey)
        let migrated = StickerStudioSettingsStore.load(defaults: defaults)
        XCTAssertFalse(migrated.isEnabled)
        XCTAssertEqual(migrated.schemaVersion, StickerStudioSettings.currentSchemaVersion)
        XCTAssertEqual(migrated.guestStickerLimit, 6)
        // Schema 2: emoji lead; the original artwork is kept but becomes an opt-in legacy source.
        XCTAssertTrue(migrated.emojiCollectionEnabled)
        XCTAssertFalse(migrated.builtInStickersEnabled)
        XCTAssertTrue(migrated.operatorCollectionEnabled)
        XCTAssertFalse(migrated.onlineDiscoveryEnabled)
    }

    func testOnAndOffPersistAcrossRelaunchAndCorruptDataResetsSafely() {
        var settings = StickerStudioSettings()
        settings.isEnabled = true
        settings.guestStickerLimit = 3
        StickerStudioSettingsStore.save(settings, defaults: defaults)
        // A "relaunch" is a fresh read from the same persistent domain.
        let relaunched = UserDefaults(suiteName: suiteName)!
        XCTAssertTrue(StickerStudioSettingsStore.load(defaults: relaunched).isEnabled)
        XCTAssertEqual(StickerStudioSettingsStore.load(defaults: relaunched).guestStickerLimit, 3)

        settings.isEnabled = false
        StickerStudioSettingsStore.save(settings, defaults: defaults)
        XCTAssertFalse(StickerStudioSettingsStore.load(defaults: relaunched).isEnabled)

        defaults.set(Data("not json".utf8), forKey: StickerStudioSettingsStore.storageKey)
        XCTAssertEqual(StickerStudioSettingsStore.load(defaults: defaults), .default, "Corrupt settings fall back to the safe OFF default")
        defaults.set(Data(#"{"isEnabled":"yes","guestStickerLimit":"many"}"#.utf8), forKey: StickerStudioSettingsStore.storageKey)
        XCTAssertFalse(StickerStudioSettingsStore.load(defaults: defaults).isEnabled, "Mistyped fields decode to their safe defaults")
    }

    func testSavingPostsChangeNotification() {
        let expectation = expectation(forNotification: StickerStudioSettingsStore.didChangeNotification, object: nil)
        StickerStudioSettingsStore.save(StickerStudioSettings(), defaults: defaults)
        wait(for: [expectation], timeout: 1)
    }

    func testNormalizationClampsLimitsAndDropsUnacknowledgedOnline() {
        var settings = StickerStudioSettings()
        settings.guestStickerLimit = 99
        settings.minimumPrintedStickerDots = 1
        settings.onlineDiscoveryEnabled = true
        let normalized = settings.normalized()
        XCTAssertEqual(normalized.guestStickerLimit, 10)
        XCTAssertEqual(normalized.minimumPrintedStickerDots, StickerStudioSettings.minimumPrintedDotsRange.lowerBound)
        XCTAssertFalse(normalized.onlineDiscoveryEnabled, "Online can never be ON without a rights acknowledgement")
        settings.guestStickerLimit = 0
        XCTAssertEqual(settings.normalized().guestStickerLimit, 1)
        settings.onlineRightsAcknowledgement = OnlineStickerRightsAcknowledgement(acknowledgedAt: Date(), statementVersion: 0)
        XCTAssertNil(settings.normalized().onlineRightsAcknowledgement, "A stale acknowledgement statement must be re-confirmed")
    }

    func testOnlineRequiresMasterKeyToggleAndRightsTogether() throws {
        let withKey = InMemoryOnlineStickerCredentialStore(key: "abcdefghijklmnopqrstuvwxyz012345")
        let noKey = InMemoryOnlineStickerCredentialStore()
        var settings = StickerStudioSettings()
        settings.isEnabled = true
        XCTAssertFalse(StickerStudioSessionConfiguration.current(settings: settings, credentials: withKey).onlineReady, "A key alone never enables online")

        settings.onlineDiscoveryEnabled = true
        XCTAssertFalse(StickerStudioSessionConfiguration.current(settings: settings, credentials: withKey).onlineReady, "Toggle plus key without rights stays off")

        settings.onlineRightsAcknowledgement = OnlineStickerRightsAcknowledgement(acknowledgedAt: Date())
        XCTAssertFalse(StickerStudioSessionConfiguration.current(settings: settings, credentials: noKey).onlineReady, "Rights without a key stay off")
        XCTAssertEqual(settings.onlineAvailability(hasCredential: false), .missingCredentials)
        XCTAssertFalse(StickerStudioSessionConfiguration.current(settings: settings, credentials: withKey).onlineReady, "Legacy credentials cannot enable online discovery in the static studio")

        settings.isEnabled = false
        XCTAssertEqual(StickerStudioSessionConfiguration.current(settings: settings, credentials: withKey), .disabled, "Master OFF disables everything")
        XCTAssertEqual(OnlineStickerAvailability.disabled.operatorDescription, "Online catalog unavailable — use built-in or approved stickers")
    }

    func testAPIKeyIsNeverStoredInSettingsOrShownInFull() throws {
        let key = "SECRETkey0123456789abcdef"
        let store = InMemoryOnlineStickerCredentialStore()
        XCTAssertThrowsError(try store.saveAPIKey("bad key!"))
        try store.saveAPIKey(key)
        XCTAssertEqual(store.redactedDescription(), "Saved key ending in cdef")
        XCTAssertFalse(store.redactedDescription().contains("SECRET"))
        var settings = StickerStudioSettings()
        settings.onlineDiscoveryEnabled = true
        settings.onlineRightsAcknowledgement = OnlineStickerRightsAcknowledgement(acknowledgedAt: Date())
        let json = String(data: try JSONEncoder().encode(settings), encoding: .utf8)!
        XCTAssertFalse(json.contains(key), "The key lives only in the keychain")
        let request = GiphyStickerProvider.makeRequest(endpoint: "trending", kind: .stickers, query: nil, offset: 0, limit: 10, apiKey: key)
        XCTAssertFalse(String(describing: OnlineStickerError.badResponse(500).localizedDescription).contains(key))
        XCTAssertEqual(request.url?.scheme, "https")
    }
}

// MARK: - Catalog, imports and assets

final class StickerCatalogTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("StickerCatalogTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    func testBuiltInLibraryIsOriginalLegibleAndOffline() throws {
        let assets = BundledStickerFactory.assets
        XCTAssertGreaterThanOrEqual(assets.count, 18)
        XCTAssertEqual(Set(assets.map(\.id)).count, assets.count, "IDs are unique")
        for category in [StickerCategory.classic, .cute, .hearts, .doodles, .reactions] {
            XCTAssertFalse(assets.filter { $0.category == category }.isEmpty, "\(category) has built-in stickers")
        }
        for name in ["LOL", "OMG", "WOW", "Side Eye", "MOOD", "POV"] {
            XCTAssertTrue(assets.contains { $0.name == name }, "\(name) reaction is included")
        }
        for asset in assets {
            XCTAssertEqual(asset.provenance, .builtIn)
            let image = try XCTUnwrap(BundledStickerFactory.image(for: asset.id), asset.id)
            let prepared = try StickerPrintPreparation.prepare(image)
            let data = try XCTUnwrap(UIImage(cgImage: prepared).pngData())
            let bitmap = StickerFixtures.Bitmap(pngData: data)
            var ink = 0, clear = 0
            for index in stride(from: 0, to: bitmap.bytes.count, by: 4) {
                if bitmap.bytes[index + 3] == 0 { clear += 1 } else if bitmap.bytes[index] < 64 { ink += 1 }
            }
            let total = bitmap.width * bitmap.height
            XCTAssertGreaterThan(Double(ink) / Double(total), 0.03, "\(asset.id) has solid printable ink")
            XCTAssertGreaterThan(Double(clear) / Double(total), 0.05, "\(asset.id) has a transparent background")
            XCTAssertTrue(BundledStickerFactory.image(for: asset.id) === image, "Artwork is cached and identical")
        }
    }

    func testImportSurvivesRestartAndMissingOrCorruptFilesAreSkipped() throws {
        let store = try StickerCatalogStore(directoryURL: root)
        let record = try store.importData(StickerFixtures.pngData(width: 300, height: 200, opaqueFraction: 0.5), name: "  Party Hat ", category: .reactions)
        XCTAssertEqual(record.name, "Party Hat")
        XCTAssertEqual(record.category, .reactions)
        XCTAssertTrue(record.isEnabled)

        let relaunched = try StickerCatalogStore(directoryURL: root)
        XCTAssertEqual(relaunched.records().map(\.id), [record.id], "Imports survive a relaunch")
        XCTAssertNotNil(relaunched.image(for: record, frameIndex: 0, maximumPixelDimension: 256))
        XCTAssertEqual(relaunched.storageBytes(), record.byteCount)

        try FileManager.default.removeItem(at: relaunched.fileURL(for: record))
        XCTAssertTrue(relaunched.records().isEmpty, "A deleted file is skipped, never shown to guests")

        let second = try relaunched.importData(StickerFixtures.pngData(width: 100, height: 100, opaqueFraction: 1), name: "B", category: .cute)
        try Data("garbage".utf8).write(to: relaunched.fileURL(for: second))
        XCTAssertNil(relaunched.image(for: second, frameIndex: 0, maximumPixelDimension: 256), "A corrupted file decodes to nil, not a crash")
        let catalog = StickerGuestCatalog.make(settings: enabledSettings(), store: relaunched)
        let asset = try XCTUnwrap(catalog.asset(id: second.assetID))
        XCTAssertNil(catalog.image(for: asset, frameIndex: 0, maximumPixelDimension: 128, store: relaunched))

        try Data("{broken".utf8).write(to: root.appendingPathComponent("manifest.json"))
        XCTAssertTrue(try StickerCatalogStore(directoryURL: root).records().isEmpty, "A corrupt manifest reads as an empty library")
    }

    func testEventCollectionEnableDisableReorderAndDelete() throws {
        let store = try StickerCatalogStore(directoryURL: root)
        let first = try store.importData(StickerFixtures.pngData(width: 100, height: 100, opaqueFraction: 1), name: "One", category: .cute)
        let second = try store.importData(StickerFixtures.pngData(width: 100, height: 100, opaqueFraction: 1), name: "Two", category: .reactions)
        try store.update(first.id) { $0.isInEventCollection = true }
        var catalog = StickerGuestCatalog.make(settings: enabledSettings(), store: try StickerCatalogStore(directoryURL: root))
        XCTAssertEqual(catalog.asset(id: first.assetID)?.category, .event)
        XCTAssertTrue(catalog.categories.contains(.event))

        try store.update(second.id) { $0.isEnabled = false }
        catalog = StickerGuestCatalog.make(settings: enabledSettings(), store: store)
        XCTAssertNil(catalog.asset(id: second.assetID), "Disabled stickers never reach guests")

        try store.move(fromOffsets: IndexSet(integer: 1), toOffset: 0)
        XCTAssertEqual(store.records().map(\.id), [second.id, first.id])

        try store.delete(first.id)
        XCTAssertEqual(store.records().map(\.id), [second.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL(for: first).path))
    }

    func testGuestCatalogRespectsSourcesAndHidesEmptyCategories() throws {
        var settings = enabledSettings()
        settings.isEnabled = false
        XCTAssertTrue(StickerGuestCatalog.make(settings: settings, store: nil).assets.isEmpty, "Master OFF loads nothing")

        settings.isEnabled = true
        let builtIns = StickerGuestCatalog.make(settings: settings, store: nil)
        XCTAssertFalse(builtIns.categories.contains(.event), "No empty Event tab")
        XCTAssertFalse(builtIns.categories.contains(.online), "Trending never comes from the local catalog")
        XCTAssertFalse(builtIns.search("lol").isEmpty, "Offline search by name")
        XCTAssertFalse(builtIns.search("love").isEmpty, "Offline search by tag")

        settings.hiddenCategories = [.reactions]
        XCTAssertFalse(StickerGuestCatalog.make(settings: settings, store: nil).categories.contains(.reactions))

        settings.builtInStickersEnabled = false
        XCTAssertTrue(StickerGuestCatalog.make(settings: settings, store: nil).assets.isEmpty)
    }

    func testDecoderLimitsAreEnforced() throws {
        XCTAssertEqual(StickerImageLimits.maximumImportBytes, 5 * 1024 * 1024)
        XCTAssertEqual(StickerImageLimits.maximumDecodedPixelDimension, 2048)
        XCTAssertEqual(StickerImageLimits.maximumConcurrentDownloads, 3)
        XCTAssertLessThanOrEqual(StickerImageLimits.thumbnailPixelDimension, 384)

        XCTAssertThrowsError(try StickerImageDecoder.inspect(Data())) { XCTAssertEqual($0 as? StickerImageError, .empty) }
        XCTAssertThrowsError(try StickerImageDecoder.inspect(Data(count: StickerImageLimits.maximumImportBytes + 1))) { XCTAssertEqual($0 as? StickerImageError, .tooLarge) }
        XCTAssertThrowsError(try StickerImageDecoder.inspect(Data("hello, not an image".utf8)))
        let tiff = UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10)).image { _ in }.jpegData(compressionQuality: 1)!
        XCTAssertNoThrow(try StickerImageDecoder.inspect(tiff), "JPEG is accepted")
        let wide = StickerFixtures.pngData(width: 9_000, height: 4, opaqueFraction: 1)
        XCTAssertThrowsError(try StickerImageDecoder.inspect(wide)) { XCTAssertEqual($0 as? StickerImageError, .dimensionsTooLarge) }

        let large = StickerFixtures.pngData(width: 3_000, height: 1_000, opaqueFraction: 1)
        let decoded = try StickerImageDecoder.decodeFrame(large, maximumPixelDimension: 10_000)
        XCTAssertLessThanOrEqual(max(decoded.width, decoded.height), StickerImageLimits.maximumDecodedPixelDimension, "Decoding is bounded even if a caller asks for more")
        let printSize = try StickerImageDecoder.decodeFrame(large)
        XCTAssertEqual(max(printSize.width, printSize.height), StickerImageLimits.printPixelDimension)
    }

    func testGIFPrintsADeterministicRepresentativeStillFrame() throws {
        let gif = StickerFixtures.gifData(levels: [10, 60, 120, 180, 240])
        let info = try StickerImageDecoder.inspect(gif)
        XCTAssertTrue(info.isAnimated)
        XCTAssertEqual(info.frameCount, 5)
        let asset = StickerAsset(id: "x", name: "x", tags: [], category: .reactions, provenance: .operatorImport, isAnimated: true, frameCount: 5)
        XCTAssertEqual(asset.representativeFrameIndex, 2)
        let first = try StickerImageDecoder.decodeFrame(gif, frameIndex: asset.representativeFrameIndex)
        let again = try StickerImageDecoder.decodeFrame(gif, frameIndex: asset.representativeFrameIndex)
        let firstBitmap = StickerFixtures.Bitmap(pngData: UIImage(cgImage: first).pngData()!)
        let againBitmap = StickerFixtures.Bitmap(pngData: UIImage(cgImage: again).pngData()!)
        XCTAssertEqual(firstBitmap.bytes, againBitmap.bytes, "Same frame, same pixels, every time")
        // GIF palettes and colour management shift absolute values, so check ordering: the
        // printed still is exactly frame 2, strictly between its neighbours, never a blend.
        let levels = try (0..<5).map { index in
            Int(StickerFixtures.Bitmap(pngData: UIImage(cgImage: try StickerImageDecoder.decodeFrame(gif, frameIndex: index)).pngData()!).pixel(10, 10))
        }
        XCTAssertEqual(levels, levels.sorted(), "Frames decode in order")
        XCTAssertEqual(Set(levels).count, 5, "Each frame is distinct")
        XCTAssertEqual(Int(firstBitmap.pixel(10, 10)), levels[2])
        let flat = Set(stride(from: 0, to: firstBitmap.bytes.count, by: 4).map { firstBitmap.bytes[$0] })
        XCTAssertEqual(flat.count, 1, "A still frame is one clean image, with no animation artifacts")
        XCTAssertThrowsError(try StickerImageDecoder.decodeFrame(gif, frameIndex: 9)) { XCTAssertEqual($0 as? StickerImageError, .frameOutOfRange) }
    }

    func testPrintPreparationSnapsAlphaAndFlagsLowContrast() throws {
        let rendererFormat = UIGraphicsImageRendererFormat()
        rendererFormat.scale = 1
        rendererFormat.opaque = false
        let soft = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 40), format: rendererFormat).image { context in
            UIColor(white: 0, alpha: 0.3).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 20, height: 40))
            UIColor(white: 0, alpha: 0.9).setFill()
            context.fill(CGRect(x: 20, y: 0, width: 20, height: 40))
        }.cgImage!
        let prepared = StickerFixtures.Bitmap(pngData: UIImage(cgImage: try StickerPrintPreparation.prepare(soft)).pngData()!)
        XCTAssertEqual(prepared.bytes[(10 * 40 + 5) * 4 + 3], 0, "Faint alpha becomes fully clear")
        XCTAssertEqual(prepared.bytes[(10 * 40 + 30) * 4 + 3], 255, "Strong alpha becomes fully opaque")

        let flatGrey = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 40), format: rendererFormat).image { context in
            UIColor(white: 0.5, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
        }.cgImage!
        XCTAssertLessThan(StickerPrintPreparation.contrastSpread(of: flatGrey), StickerPrintPreparation.lowContrastThreshold)
        let store = try StickerCatalogStore(directoryURL: root)
        let record = try store.importData(UIImage(cgImage: flatGrey).pngData()!, name: "Grey", category: .cute)
        XCTAssertEqual(record.printWarning, StickerPrintPreparation.lowContrastWarning)
    }

    private func enabledSettings() -> StickerStudioSettings {
        var settings = StickerStudioSettings()
        settings.isEnabled = true
        // These tests exercise the original artwork, now an operator opt-in legacy collection.
        settings.builtInStickersEnabled = true
        return settings
    }
}

// MARK: - Geometry

final class StickerGeometryTests: XCTestCase {
    private let region = StickerTargetRegion(
        target: .photo(index: 0),
        rect: CGRect(x: 36, y: 140, width: 504, height: 672),
        clipRect: CGRect(x: 40, y: 144, width: 496, height: 664),
        label: "Photo 1"
    )

    func testSingleTransformMapsPrintAndDisplayAtEveryIPadScale() throws {
        let placement = StickerFixtures.placement(target: .photo(index: 0), x: 0.25, y: 0.75, scale: 0.5, rotation: 0.4, aspect: 2)
        let frame = try StickerGeometry.resolve(placement, in: region)
        XCTAssertEqual(frame.center.x, 40 + 0.25 * 496, accuracy: 0.001)
        XCTAssertEqual(frame.center.y, 144 + 0.75 * 664, accuracy: 0.001)
        XCTAssertEqual(frame.size.width, 0.5 * 496, accuracy: 0.001, "Long edge is scale × the region's short edge")
        XCTAssertEqual(frame.size.height, frame.size.width / 2, accuracy: 0.001)

        // 11-inch and 13-inch landscape canvases and a portrait canvas.
        for displayScale in [CGFloat(0.62), 0.81, 1.0, 1.37] {
            let display = frame.display(scale: displayScale)
            XCTAssertEqual(display.center.x, frame.center.x * displayScale, accuracy: 0.001)
            XCTAssertEqual(display.size.height, frame.size.height * displayScale, accuracy: 0.001)
            XCTAssertEqual(display.rotation, frame.rotation)
            XCTAssertEqual(display.clipRect.minY, region.clipRect.minY * displayScale, accuracy: 0.001)

            // Dragging 31 points on screen moves the printed sticker 31 / scale dots.
            let moved = StickerGeometry.applying(translation: CGSize(width: 31, height: -12), magnification: 1, rotationDelta: 0, to: placement, in: region, displayScale: displayScale, minimumPrintedDots: 72)
            let movedFrame = try StickerGeometry.resolve(moved, in: region)
            XCTAssertEqual(movedFrame.center.x - frame.center.x, 31 / displayScale, accuracy: 0.01)
            XCTAssertEqual(movedFrame.center.y - frame.center.y, -12 / displayScale, accuracy: 0.01)
        }
    }

    func testDragPinchAndTwistAreClampedTogether() throws {
        let placement = StickerFixtures.placement(target: .photo(index: 0))
        let flung = StickerGeometry.applying(translation: CGSize(width: 50_000, height: -50_000), magnification: 40, rotationDelta: 7 * .pi, to: placement, in: region, displayScale: 0.8, minimumPrintedDots: 72)
        XCTAssertEqual(flung.centerX, 1)
        XCTAssertEqual(flung.centerY, 0)
        XCTAssertEqual(flung.scale, StickerPlacement.maximumScale)
        XCTAssertEqual(flung.rotation, .pi, accuracy: 1e-9)
        XCTAssertNoThrow(try StickerGeometry.resolve(flung, in: region))

        let shrunk = StickerGeometry.applying(translation: .zero, magnification: 0.0001, rotationDelta: 0, to: placement, in: region, displayScale: 0.8, minimumPrintedDots: 72)
        let shrunkFrame = try StickerGeometry.resolve(shrunk, in: region)
        XCTAssertGreaterThanOrEqual(max(shrunkFrame.size.width, shrunkFrame.size.height), 72 - 0.001, "Never smaller than the printable minimum")
        XCTAssertNil(StickerGeometry.legibilityWarning(for: shrunkFrame, minimumPrintedDots: 72))

        let unchanged = StickerGeometry.applying(translation: CGSize(width: CGFloat.nan, height: 0), magnification: .infinity, rotationDelta: .nan, to: placement, in: region, displayScale: .nan, minimumPrintedDots: 72)
        XCTAssertEqual(unchanged, placement, "Non-finite gesture input is ignored")
    }

    func testMalformedPlacementsFailSafely() {
        let bad: [StickerPlacement] = [
            StickerFixtures.placement(target: .photo(index: 0), x: .nan),
            StickerFixtures.placement(target: .photo(index: 0), y: .infinity),
            StickerFixtures.placement(target: .photo(index: 0), scale: 50),
            StickerFixtures.placement(target: .photo(index: 0), scale: -1),
            StickerFixtures.placement(target: .photo(index: 0), aspect: 0),
            StickerFixtures.placement(target: .photo(index: 0), x: 3),
            StickerFixtures.placement(target: .photo(index: 9))
        ]
        for placement in bad {
            XCTAssertThrowsError(try StickerGeometry.resolve(placement, in: region))
        }
        let negative = StickerTargetRegion(target: .photo(index: 0), rect: CGRect(x: 10, y: 10, width: -5, height: 20), clipRect: CGRect(x: 10, y: 10, width: -5, height: 20), label: "")
        XCTAssertThrowsError(try StickerGeometry.resolve(StickerFixtures.placement(target: .photo(index: 0)), in: negative))
        let offCanvas = StickerTargetRegion(target: .photo(index: 0), rect: CGRect(x: 500, y: 0, width: 200, height: 200), clipRect: CGRect(x: 504, y: 4, width: 192, height: 192), label: "")
        XCTAssertThrowsError(try StickerGeometry.resolve(StickerFixtures.placement(target: .photo(index: 0)), in: offCanvas), "Wider than the 576-dot paper")

        let repaired = StickerGeometry.clamped(StickerFixtures.placement(target: .photo(index: 0), x: .nan, scale: .infinity, rotation: .nan, aspect: .nan), in: region, minimumPrintedDots: 72)
        XCTAssertNoThrow(try StickerGeometry.resolve(repaired, in: region))
    }

    func testRotationNormalizationAndLegibilityWarning() throws {
        XCTAssertEqual(StickerGeometry.normalizedRotation(3 * .pi), .pi, accuracy: 1e-9)
        XCTAssertEqual(StickerGeometry.normalizedRotation(-3 * .pi / 2), .pi / 2, accuracy: 1e-9)
        let edge = StickerFixtures.placement(target: .photo(index: 0), x: 1, y: 1, scale: 0.6)
        let frame = try StickerGeometry.resolve(edge, in: region)
        XCTAssertNotNil(StickerGeometry.legibilityWarning(for: frame, minimumPrintedDots: 72), "A sticker mostly off the photo is flagged")
    }
}

// MARK: - Rendering, thermal and privacy

final class StickerRenderingTests: XCTestCase {
    func testNoStickersIsByteForByteIdenticalToBaselineForEveryFormat() throws {
        for format in BoothFormat.allCases {
            let baseline = try StickerFixtures.compose(format)
            let empty = try StickerFixtures.compose(format, stickers: [])
            XCTAssertEqual(baseline.imagePNGData, empty.imagePNGData, "\(format) receipt unchanged when no stickers are placed")
            XCTAssertEqual(baseline.height, empty.height)
            XCTAssertTrue(empty.drawnStickerPlacementIDs.isEmpty)
            let baseRaster = try ThermalImageRasterizer.rasterize(UIImage(data: baseline.imagePNGData)!, purpose: .completeReceipt)
            let emptyRaster = try ThermalImageRasterizer.rasterize(UIImage(data: empty.imagePNGData)!, purpose: .completeReceipt)
            XCTAssertEqual(baseRaster.rasterData, emptyRaster.rasterData, "\(format) raster unchanged")
        }
    }

    func testRegionsComeFromTheExactLayoutPlanForEveryFormat() throws {
        for format in BoothFormat.allCases {
            let receipt = try StickerFixtures.compose(format)
            let layout = try XCTUnwrap(receipt.stickerLayout)
            let plan = try ReceiptComposer.makeLayoutPlan(format: format, passport: format == .passport ? .photoPassDebugFixture : nil, date: StickerFixtures.date)
            XCTAssertEqual(layout.canvasWidth, BoothConfiguration.receiptWidth)
            XCTAssertEqual(layout.canvasHeight, receipt.height)
            let photoRegions = layout.regions.filter { if case .photo = $0.target { return true } else { return false } }
            XCTAssertEqual(photoRegions.count, format.photoCount, "\(format) offers every photo")
            for frame in plan.photoFrames {
                let region = try XCTUnwrap(layout.region(for: .photo(index: frame.photoIndex)))
                XCTAssertEqual(region.rect, frame.rect, "\(format) photo \(frame.photoIndex) geometry is the printed opening")
                XCTAssertEqual(region.clipRect, frame.rect.insetBy(dx: StickerGeometry.safeMarginDots, dy: StickerGeometry.safeMarginDots))
            }
            XCTAssertEqual(layout.regions.count, photoRegions.count, "Current layouts have no blank band wide enough, so only photos are offered")
            let protected = ReceiptComposer.stickerProtectedRects(for: plan)
            for region in layout.regions {
                for rect in protected where format != .passport {
                    XCTAssertFalse(region.clipRect.intersects(rect), "\(format) region never overlaps branding, text or the QR")
                }
            }
        }
    }

    func testStickerInkStaysInsideItsRegionAndNeverTouchesProtectedElements() throws {
        let ink = StickerFixtures.solidImage()
        for format in BoothFormat.allCases {
            let baseline = try StickerFixtures.compose(format)
            let layout = try XCTUnwrap(baseline.stickerLayout)
            // A large rotated sticker in every photo's corner tries hard to escape.
            let decorations = layout.regions.map { region in
                FrozenStickerDecoration(placement: StickerFixtures.placement(target: region.target, x: 1, y: 1, scale: 1, rotation: .pi / 4), printImage: ink)
            }
            let decorated = try StickerFixtures.compose(format, stickers: decorations)
            XCTAssertEqual(decorated.height, baseline.height, "\(format) receipt height never grows for stickers")
            XCTAssertEqual(decorated.width, 576)
            XCTAssertEqual(decorated.drawnStickerPlacementIDs.count, decorations.count)
            let changed = StickerFixtures.Bitmap(pngData: decorated.imagePNGData).differences(from: StickerFixtures.Bitmap(pngData: baseline.imagePNGData))
            XCTAssertFalse(changed.isEmpty, "\(format) stickers are in the actual printed bitmap")
            let allowed = layout.regions.map(\.clipRect)
            let escaped = changed.filter { point in !allowed.contains { $0.insetBy(dx: -1, dy: -1).contains(point) } }
            XCTAssertTrue(escaped.isEmpty, "\(format): \(escaped.count) sticker pixels escaped the approved regions, e.g. \(escaped.prefix(3))")

            let plan = try ReceiptComposer.makeLayoutPlan(format: format, passport: format == .passport ? .photoPassDebugFixture : nil, date: StickerFixtures.date)
            let qr = try XCTUnwrap(plan.qrRect).insetBy(dx: -StickerGeometry.qrQuietZoneDots, dy: -StickerGeometry.qrQuietZoneDots)
            XCTAssertFalse(changed.contains { qr.contains($0) }, "\(format) QR and quiet zone are untouched")
            if let photoPass = plan.photoPassLayout {
                for text in photoPass.allTexts {
                    XCTAssertFalse(changed.contains { text.rect.contains($0) }, "Photo Pass \(text.role) text is never covered")
                }
                XCTAssertFalse(changed.contains { photoPass.template.signatureBoxRect.contains($0) }, "The signature box is never covered")
            }
            for rect in plan.mastheadFrames + plan.captionFrames + plan.footerFrames + [plan.sessionIdentifierFrame] {
                XCTAssertFalse(changed.contains { rect.contains($0) }, "\(format) branding and required text stay clean")
            }
        }
    }

    func testAlphaCompositesOverThePhoto() throws {
        let halfInk = StickerFixtures.solidImage(width: 200, height: 200, opaqueFraction: 0.5)
        let baseline = try StickerFixtures.compose(.solo)
        let region = try XCTUnwrap(baseline.stickerLayout?.region(for: .photo(index: 0)))
        let placement = StickerFixtures.placement(target: .photo(index: 0), scale: 0.5)
        let decorated = try StickerFixtures.compose(.solo, stickers: [FrozenStickerDecoration(placement: placement, printImage: halfInk)])
        let frame = try StickerGeometry.resolve(placement, in: region)
        let before = StickerFixtures.Bitmap(pngData: baseline.imagePNGData)
        let after = StickerFixtures.Bitmap(pngData: decorated.imagePNGData)
        let leftInside = (Int(frame.center.x - frame.size.width * 0.3), Int(frame.center.y))
        let rightInside = (Int(frame.center.x + frame.size.width * 0.3), Int(frame.center.y))
        XCTAssertEqual(after.pixel(leftInside.0, leftInside.1), 0, "Opaque sticker ink covers the photo")
        XCTAssertEqual(after.pixel(rightInside.0, rightInside.1), before.pixel(rightInside.0, rightInside.1), "Transparent sticker pixels show the photo underneath")
    }

    func testThermalPreviewPrintRasterAndCopiesMatchForOneCommittedSession() throws {
        let decorations = [
            FrozenStickerDecoration(placement: StickerFixtures.placement(target: .photo(index: 0), x: 0.3, y: 0.3, scale: 0.4, rotation: 0.3), printImage: try XCTUnwrap(BundledStickerFactory.image(for: "builtin.heart")).prepared()),
            FrozenStickerDecoration(placement: StickerFixtures.placement(target: .photo(index: 2), x: 0.7, y: 0.6, scale: 0.6, rotation: -0.5, aspect: 1.6, z: 1), printImage: try XCTUnwrap(BundledStickerFactory.image(for: "builtin.lol")).prepared())
        ]
        let first = try StickerFixtures.compose(.strip, stickers: decorations)
        let rebuilt = try StickerFixtures.compose(.strip, stickers: decorations)
        XCTAssertEqual(first.imagePNGData, rebuilt.imagePNGData, "Rebuilds of a committed session are identical")
        let raster = try ThermalImageRasterizer.rasterize(UIImage(data: first.imagePNGData)!, purpose: .completeReceipt)
        let rasterAgain = try ThermalImageRasterizer.rasterize(UIImage(data: rebuilt.imagePNGData)!, purpose: .completeReceipt)
        XCTAssertEqual(raster.rasterData, rasterAgain.rasterData, "Every copy sends the same raster")
        XCTAssertEqual(raster.previewPNGData, rasterAgain.previewPNGData, "The 1-bit preview is the printed raster")
        XCTAssertEqual(raster.rasterData.shortSHA256Fingerprint, rasterAgain.rasterData.shortSHA256Fingerprint)
        XCTAssertEqual(raster.width, 576)
        XCTAssertLessThanOrEqual(raster.height, BoothConfiguration.receiptMaximumHeight)
        XCTAssertNoThrow(try ThermalImageRasterizer.validateRasterCommand(raster.rasterCommand, imageWidth: raster.width, imageHeight: raster.height, bytesPerRow: raster.widthBytes, rasterDataCount: raster.rasterData.count))

        // Reference output for black & white thermal sticker placement.
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/StickerStudio/StickerReferences", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try raster.previewPNGData.write(to: directory.appendingPathComponent("strip_stickers_thermal_1bit.png"))
        try first.imagePNGData.write(to: directory.appendingPathComponent("strip_stickers_keepsake.png"))
        let attachment = XCTAttachment(data: raster.previewPNGData, uniformTypeIdentifier: UTType.png.identifier)
        attachment.name = "strip_stickers_thermal_1bit.png"
        attachment.lifetime = .keepAlways
        add(attachment)
        print("[StickerStudioReference] \(directory.path)")
    }

    func testPhotoPassGalleryRedactionKeepsStickersAndOriginalPhotos() throws {
        let photos = StickerFixtures.photos(for: .passport)
        let base = try StickerFixtures.compose(.passport)
        let region = try XCTUnwrap(base.stickerLayout?.region(for: .photo(index: PhotoPassReceiptLayout.heroPhotoIndex)))
        let decoration = FrozenStickerDecoration(placement: StickerFixtures.placement(target: region.target, x: 0.2, y: 0.3, scale: 0.4), printImage: StickerFixtures.solidImage())
        var options = ReceiptPrintOptions.default
        options.includesPrintedGalleryQR = true
        var passport = PassportSessionData.photoPassDebugFixture
        passport.name = "Private Guest Name"
        let session = CommittedGallerySession(
            sessionIdentifier: "PP-20260907-161400",
            createdAt: StickerFixtures.date,
            galleryToken: String(repeating: "a", count: 32),
            galleryURL: URL(string: "https://example.com/g/\(String(repeating: "a", count: 32))")!,
            photos: photos,
            format: .passport,
            eventProfile: nil,
            passport: passport.committed(at: StickerFixtures.date),
            printOptions: options,
            stickers: [decoration]
        )
        let printed = try ReceiptComposer.compose(photos: session.photos, sessionIdentifier: session.sessionIdentifier, date: session.createdAt, galleryURL: session.galleryURL, format: .passport, passport: session.passport, printOptions: options, stickers: session.stickers)
        let printedImage = try XCTUnwrap(UIImage(data: printed.imagePNGData))
        let gallery = try BoothSessionViewModel.galleryReceiptImage(for: session, printedReceiptImage: printedImage, photoQualityProfile: .customerPrintDefault)
        let printedBitmap = StickerFixtures.Bitmap(pngData: printed.imagePNGData)
        let galleryBitmap = StickerFixtures.Bitmap(pngData: try XCTUnwrap(gallery.pngData()))
        XCTAssertFalse(galleryBitmap.differences(from: printedBitmap).isEmpty, "Gallery copy is redacted")
        let frame = try StickerGeometry.resolve(decoration.placement, in: region)
        XCTAssertEqual(galleryBitmap.pixel(Int(frame.center.x), Int(frame.center.y)), 0, "The gallery receipt keeps the sticker")
        let plan = try ReceiptComposer.makeLayoutPlan(format: .passport, passport: passport.redactedForGallery(), date: StickerFixtures.date)
        let nameField = try XCTUnwrap(plan.photoPassLayout?.template.fields.first { $0.kind == .name })
        let redactedBase = StickerFixtures.Bitmap(pngData: try ReceiptComposer.compose(photos: photos, sessionIdentifier: session.sessionIdentifier, date: session.createdAt, galleryURL: session.galleryURL, format: .passport, passport: passport.redactedForGallery(), printOptions: options).imagePNGData)
        XCTAssertFalse(galleryBitmap.differences(from: redactedBase).contains { nameField.valueRect.contains($0) }, "The redacted name field is identical with or without stickers")
        XCTAssertTrue(zip(session.photos, photos).allSatisfy { $0 === $1 }, "Original gallery photos are never modified")
    }
}

private extension CGImage {
    func prepared() throws -> CGImage { try StickerPrintPreparation.prepare(self) }
}

// MARK: - Guest editor model

@MainActor
final class StickerStudioSessionTests: XCTestCase {
    private func makeSession(limit: Int = 6, online: OnlineStickerProvider? = nil) throws -> StickerStudioSession {
        var settings = StickerStudioSettings()
        settings.isEnabled = true
        settings.builtInStickersEnabled = true
        settings.guestStickerLimit = limit
        let configuration = StickerStudioSessionConfiguration(settings: settings.normalized(), onlineReady: online != nil)
        let session = StickerStudioSession(configuration: configuration, catalog: StickerGuestCatalog.make(settings: settings, store: nil), generation: 1, catalogStore: nil, provider: online)
        let receipt = try StickerFixtures.compose(.grid)
        session.setCanvas(image: UIImage(data: receipt.imagePNGData)!, layout: try XCTUnwrap(receipt.stickerLayout))
        return session
    }

    private func waitFor(_ condition: @escaping @MainActor () -> Bool, timeout: TimeInterval = 5) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func testAddMoveUndoRedoDeleteResetAndLimit() async throws {
        let session = try makeSession(limit: 2)
        let heart = try XCTUnwrap(session.catalog.asset(id: "builtin.heart"))
        session.add(heart)
        await waitFor { session.placements.count == 1 }
        let first = try XCTUnwrap(session.placements.first)
        XCTAssertEqual(first.target, .photo(index: 0), "The first sticker lands on the first photo")
        XCTAssertEqual(session.selectedPlacementID, first.id, "A new sticker stays selected")
        XCTAssertNotNil(session.artwork[first.id])

        session.commitGesture(first.id, translation: CGSize(width: 40, height: 0), magnification: 1.2, rotation: 0.3, displayScale: 1)
        XCTAssertNotEqual(session.placements.first, first)
        session.undo()
        XCTAssertEqual(session.placements.first, first)
        session.redo()
        XCTAssertNotEqual(session.placements.first, first)

        session.add(heart)
        await waitFor { session.placements.count == 2 }
        XCTAssertTrue(session.isAtLimit)
        session.add(heart)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(session.placements.count, 2, "The operator limit is enforced")
        XCTAssertNotNil(session.notice)

        session.deleteSelected()
        XCTAssertEqual(session.placements.count, 1)
        session.resetAll()
        XCTAssertTrue(session.placements.isEmpty)
        session.undo()
        XCTAssertEqual(session.placements.count, 1, "Reset can be undone")
        XCTAssertEqual(session.freeze().count, 1)
    }

    func testHitTestingFindsTinyAndRotatedStickers() async throws {
        let session = try makeSession()
        session.add(try XCTUnwrap(session.catalog.asset(id: "builtin.star")))
        await waitFor { session.placements.count == 1 }
        let placement = try XCTUnwrap(session.placements.first)
        let frame = try StickerGeometry.resolve(placement, in: try XCTUnwrap(session.layout?.region(for: placement.target)))
        let scale: CGFloat = 0.7
        XCTAssertEqual(session.placement(at: CGPoint(x: frame.center.x * scale, y: frame.center.y * scale), displayScale: scale)?.id, placement.id)
        XCTAssertNil(session.placement(at: CGPoint(x: 2, y: 2), displayScale: scale), "Empty paper deselects")
    }

    func testLegacyOnlineConfigurationCannotTriggerGuestNetworkRequests() async throws {
        let provider = FakeOnlineStickerProvider()
        let session = try makeSession(online: provider)
        XCTAssertFalse(session.categories.contains(.online))
        XCTAssertTrue(provider.calls.isEmpty)
        session.add(try XCTUnwrap(session.catalog.asset(id: "builtin.star")))
        await waitFor { session.placements.count == 1 }
        XCTAssertEqual(session.placements.count, 1)
        session.close()
        XCTAssertTrue(provider.calls.isEmpty)
    }

    func testRepeatedSyntheticEditSessionsDoNotLeakState() async throws {
        // 300 guest drafts with random edits, freezes and closes; 12 of them composed for real.
        var generator = SystemRandomNumberGenerator()
        let assets = BundledStickerFactory.assets
        for iteration in 0..<300 {
            let session = try makeSession(limit: Int.random(in: 1...10, using: &generator))
            for _ in 0..<Int.random(in: 0...4, using: &generator) {
                session.add(assets.randomElement(using: &generator)!)
            }
            await waitFor { session.pendingInsertions == 0 }
            for placement in session.placements {
                session.commitGesture(placement.id, translation: CGSize(width: .random(in: -400...400, using: &generator), height: .random(in: -400...400, using: &generator)), magnification: .random(in: 0.1...5, using: &generator), rotation: .random(in: -7...7, using: &generator), displayScale: .random(in: 0.5...1.4, using: &generator))
            }
            XCTAssertLessThanOrEqual(session.placements.count, session.limit)
            let frozen = session.freeze()
            XCTAssertEqual(frozen.count, session.placements.count)
            if iteration % 25 == 0 {
                let receipt = try StickerFixtures.compose(.grid, stickers: frozen)
                XCTAssertEqual(receipt.drawnStickerPlacementIDs.count, frozen.count)
            }
            session.close()
            XCTAssertTrue(session.placements.isEmpty)
            XCTAssertTrue(session.artwork.isEmpty, "Closing releases sticker artwork")
        }
    }
}

final class FailingOnlineStickerProvider: OnlineStickerProvider, @unchecked Sendable {
    let providerName = "FAIL"
    let attributionText = "Powered by FAIL"
    func trending(kind: OnlineStickerKind, offset: Int, limit: Int) async throws -> OnlineStickerPage { throw OnlineStickerError.badResponse(503) }
    func search(query: String, kind: OnlineStickerKind, offset: Int, limit: Int) async throws -> OnlineStickerPage { throw OnlineStickerError.badResponse(503) }
    func downloadMedia(_ url: URL) async throws -> Data { throw OnlineStickerError.badResponse(503) }
}

// MARK: - Online provider

final class OnlineStickerProviderTests: XCTestCase {
    func testURLPolicyRejectsUnsafeAddresses() {
        let policy = GiphyStickerProvider.urlPolicy
        XCTAssertTrue(policy.isAllowed(URL(string: "https://media1.giphy.com/media/x/200w.gif")))
        XCTAssertTrue(policy.isAllowed(URL(string: "https://api.giphy.com/v1/stickers/trending")))
        for unsafe in [
            "http://media1.giphy.com/a.gif", "ftp://giphy.com/a.gif", "file:///etc/passwd", "javascript:alert(1)",
            "https://localhost/a.gif", "https://127.0.0.1/a.gif", "https://[::1]/a.gif", "https://user:pass@giphy.com/a.gif",
            "https://giphy.com:8443/a.gif", "https://giphy.com.evil.example/a.gif", "https://evilgiphy.com/a.gif"
        ] {
            XCTAssertFalse(policy.isAllowed(URL(string: unsafe)), unsafe)
        }
    }

    func testRequestsUseDocumentedEndpointsAndSafeSearch() throws {
        let trending = GiphyStickerProvider.makeRequest(endpoint: "trending", kind: .stickers, query: nil, offset: 24, limit: 500, apiKey: "KEY0123456789abcdef")
        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(trending.url), resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.host, "api.giphy.com")
        XCTAssertEqual(components.path, "/v1/stickers/trending")
        XCTAssertEqual(components.queryItems?.first { $0.name == "rating" }?.value, "g")
        XCTAssertEqual(components.queryItems?.first { $0.name == "limit" }?.value, String(GiphyStickerProvider.maximumPageSize))
        XCTAssertEqual(components.queryItems?.first { $0.name == "offset" }?.value, "24")
        let search = GiphyStickerProvider.makeRequest(endpoint: "search", kind: .gifs, query: "happy dance", offset: 0, limit: 10, apiKey: "KEY0123456789abcdef")
        XCTAssertEqual(search.url?.path, "/v1/gifs/search")
        XCTAssertTrue(search.url?.query?.contains("q=happy%20dance") == true)
    }

    func testParsingDropsDisallowedOrOversizedMediaAndPaginates() throws {
        // Synthetic response in the documented shape; no real provider content.
        let json = """
        {"data":[
          {"id":"a1","type":"sticker","title":"Synthetic A","user":{"display_name":"Test Creator"},
           "images":{"fixed_width_small":{"url":"https://media2.giphy.com/media/a1/100w.gif","width":"100","height":"50"},
                     "fixed_width":{"url":"https://media2.giphy.com/media/a1/200w.gif","width":"200","height":"100","size":"20000"}}},
          {"id":"b2","type":"gif","title":"Bad host",
           "images":{"fixed_width_small":{"url":"http://evil.example/b.gif"},"fixed_width":{"url":"https://evil.example/b.gif"}}},
          {"id":"c3","type":"gif","title":"Too big",
           "images":{"fixed_width_small":{"url":"https://media.giphy.com/c/s.gif"},"fixed_width":{"url":"https://media.giphy.com/c/l.gif","width":"200","height":"200","size":"99000000"}}}
        ],"pagination":{"total_count":100,"count":3,"offset":0}}
        """
        let page = try GiphyStickerProvider.parse(Data(json.utf8))
        XCTAssertEqual(page.results.map(\.id), ["a1"])
        XCTAssertEqual(page.results.first?.aspectRatio, 2)
        XCTAssertEqual(page.results.first?.creatorDisplayName, "Test Creator")
        XCTAssertEqual(page.nextOffset, 3)
        XCTAssertThrowsError(try GiphyStickerProvider.parse(Data("<html>".utf8)))
    }


}

actor ConcurrencyTracker {
    private var active = 0
    private(set) var peak = 0
    func enter() { active += 1; peak = max(peak, active) }
    func leave() { active -= 1 }
}

// MARK: - Booth flow integration

@MainActor
final class StickerStudioFlowTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("StickerFlow-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private final class SourceCounter { var providerRequests = 0; var catalogRequests = 0 }

    private func makeModel(enabled: Bool, counter: SourceCounter? = nil, configuration: (@MainActor () -> StickerStudioSessionConfiguration)? = nil) -> BoothSessionViewModel {
        let counter = counter ?? SourceCounter()
        var environment = BoothSessionEnvironment.customer
        environment.archiveDirectory = root.appendingPathComponent("archive", isDirectory: true)
        environment.recoveryDirectory = root.appendingPathComponent("recovery", isDirectory: true)
        environment.deliversGallery = false
        environment.recordsCustomerSessionMetrics = false
        environment.printSource = .diagnostic
        environment.eventProfileSource = { EventProfile.pocketPixelsDefault }
        var settings = StickerStudioSettings()
        settings.isEnabled = enabled
        // These flows add original-artwork stickers, now an operator opt-in legacy collection.
        settings.builtInStickersEnabled = true
        environment.stickerConfigurationSource = configuration ?? { StickerStudioSessionConfiguration(settings: settings.normalized(), onlineReady: false) }
        environment.stickerCatalogStoreSource = {
            counter.catalogRequests += 1
            return nil
        }
        environment.onlineStickerProviderSource = {
            counter.providerRequests += 1
            return FakeOnlineStickerProvider()
        }
        return BoothSessionViewModel(environment: environment, captureConfirmationPause: {})
    }

    /// Drives the real state machine to Review with sample photos.
    private func reachReview(_ model: BoothSessionViewModel, format: BoothFormat) async throws {
        model.state = .welcome
        model.startSession()
        guard model.state == .choosingFormat else {
            throw XCTSkip("Booth start is blocked on this simulator (\(model.state)).")
        }
        model.selectBoothFormat(format)
        let deadline = Date().addingTimeInterval(15)
        while model.state == .preparingCamera, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        model.isCameraUnavailable = true
        model.state = .cameraReady
        for index in 0..<format.photoCount {
            await model.addSamplePhotoAndConfirm(ReliabilityFixtures.syntheticPhoto(session: 7, photo: index, format: format))
        }
        XCTAssertEqual(model.state, .review)
    }

    private func waitForState(_ model: BoothSessionViewModel, _ predicate: @escaping (BoothSessionState) -> Bool, timeout: TimeInterval = 30) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate(model.state), Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func reachPhotoPassPreview(_ model: BoothSessionViewModel) async throws {
        try await reachReview(model, format: .passport)
        model.continueFromReview()
        XCTAssertEqual(model.state, .passportDetails)
        model.passportDraft.name = "Flow Guest"
        model.continueFromPassportDetails()
        model.updatePassportSignature(.debugFixture)
        model.continueFromPassportSignature()
        XCTAssertEqual(model.state, .passportPreview)
    }

    private func archiveCount() -> Int {
        (try? RecentSessionArchiveStore(directoryURL: root.appendingPathComponent("archive", isDirectory: true)).summaries().count) ?? 0
    }

    func testFeatureOffKeepsTheExistingFlowWithNoStickerWork() async throws {
        let counter = SourceCounter()
        let model = makeModel(enabled: false, counter: counter)
        try await reachReview(model, format: .solo)
        XCTAssertFalse(model.stickerStepEnabledForSession)
        model.continueFromReview()
        XCTAssertEqual(model.state, .composingReceipt, "OFF goes straight to composition, no sticker screen")
        XCTAssertNil(model.stickerStudio)
        try await waitForState(model) { $0 == .receiptPreview }
        XCTAssertEqual(model.state, .receiptPreview)
        XCTAssertEqual(counter.providerRequests, 0, "No online provider is created when OFF")
        XCTAssertEqual(counter.catalogRequests, 0, "No sticker library is read when OFF")
        XCTAssertEqual(model.composedReceipt?.drawnStickerPlacementIDs, [])
        XCTAssertEqual(model.receiptFinalizationCount, 1)
        model.cancelSession()
    }

    func testEveryStandardFormatVisitsStickerStudioOnceAndDoneCommitsOnce() async throws {
        for format in [BoothFormat.solo, .duo, .grid, .strip, .gridSix] {
            let model = makeModel(enabled: true)
            try await reachReview(model, format: format)
            XCTAssertTrue(model.stickerStepEnabledForSession)
            model.continueFromReview()
            XCTAssertEqual(model.state, .preparingStickers)
            try await waitForState(model) { $0 == .stickerStudio }
            XCTAssertEqual(model.state, .stickerStudio, "\(format) shows Sticker Studio")
            let studio = try XCTUnwrap(model.stickerStudio)
            XCTAssertEqual(studio.layout?.regions.count, format.photoCount)

            // Browsing and editing has no business side effects.
            let archivesBefore = archiveCount()
            model.continueToReceipt()
            XCTAssertEqual(model.state, .stickerStudio, "Re-requesting finalization from the editor is ignored")
            XCTAssertEqual(model.receiptFinalizationCount, 0)
            XCTAssertNil(model.composedReceipt)
            XCTAssertEqual(model.uploadPhase, .idle)
            XCTAssertEqual(archiveCount(), archivesBefore, "Editing never archives")

            studio.add(try XCTUnwrap(studio.catalog.asset(id: "builtin.heart")))
            let deadline = Date().addingTimeInterval(5)
            while studio.placements.isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
            let placementID = try XCTUnwrap(studio.placements.first?.id)

            model.finishStickerStudio()
            model.finishStickerStudio()
            model.skipStickerStudio()
            XCTAssertEqual(model.receiptFinalizationCount, 1, "\(format): rapid taps commit exactly once")
            XCTAssertNil(model.stickerStudio, "The draft is released after commit")
            try await waitForState(model) { $0 == .receiptPreview }
            XCTAssertEqual(model.state, .receiptPreview)
            XCTAssertEqual(model.composedReceipt?.drawnStickerPlacementIDs, [placementID], "\(format) sticker is in the composed receipt")
            XCTAssertNotNil(model.receiptRasterizedImage)
            model.cancelSession()
        }
    }

    func testDoneWaitsForPendingArtworkAndPreservesStaticDraftOnBack() async throws {
        let model = makeModel(enabled: true)
        try await reachReview(model, format: .gridSix)
        model.continueFromReview()
        try await waitForState(model) { $0 == .stickerStudio }
        let studio = try XCTUnwrap(model.stickerStudio)
        studio.add(try XCTUnwrap(studio.catalog.asset(id: "builtin.twin-lens")))
        model.finishStickerStudio()
        XCTAssertEqual(model.receiptFinalizationCount, 0, "An unfinished decode cannot be frozen")
        let deadline = Date().addingTimeInterval(5)
        while studio.pendingInsertions > 0, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let placement = try XCTUnwrap(studio.placements.first)
        model.backFromStickerStudio()
        model.continueFromReview()
        try await waitForState(model) { $0 == .stickerStudio }
        XCTAssertEqual(model.stickerStudio?.placements.first, placement)
        model.finishStickerStudio()
        model.finishStickerStudio()
        XCTAssertEqual(model.receiptFinalizationCount, 1)
        try await waitForState(model) { $0 == .receiptPreview }
        model.cancelSession()
        XCTAssertNil(model.stickerStudio)
    }

    func testSkipCommitsTheOriginalReceipt() async throws {
        let model = makeModel(enabled: true)
        try await reachReview(model, format: .grid)
        model.continueFromReview()
        try await waitForState(model) { $0 == .stickerStudio }
        let studio = try XCTUnwrap(model.stickerStudio)
        studio.add(try XCTUnwrap(studio.catalog.asset(id: "builtin.star")))
        let deadline = Date().addingTimeInterval(5)
        while studio.placements.isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        model.skipStickerStudio()
        model.skipStickerStudio()
        XCTAssertEqual(model.receiptFinalizationCount, 1)
        try await waitForState(model) { $0 == .receiptPreview }
        XCTAssertEqual(model.composedReceipt?.drawnStickerPlacementIDs, [], "Skip removes every sticker")
        model.cancelSession()
    }

    func testBackPreservesPhotosAndDraftWithoutSideEffects() async throws {
        let model = makeModel(enabled: true)
        try await reachReview(model, format: .duo)
        let photos = model.capturedPhotos
        let identifier = model.sessionIdentifier
        model.continueFromReview()
        try await waitForState(model) { $0 == .stickerStudio }
        let studio = try XCTUnwrap(model.stickerStudio)
        studio.add(try XCTUnwrap(studio.catalog.asset(id: "builtin.wow")))
        let deadline = Date().addingTimeInterval(5)
        while studio.placements.isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }

        model.backFromStickerStudio()
        XCTAssertEqual(model.state, .review)
        XCTAssertTrue(zip(model.capturedPhotos, photos).allSatisfy { $0 === $1 })
        XCTAssertEqual(model.sessionIdentifier, identifier)
        XCTAssertEqual(model.selectedBoothFormat, .duo)
        XCTAssertEqual(model.receiptFinalizationCount, 0)
        XCTAssertEqual(archiveCount(), 0, "Back never archives")
        XCTAssertEqual(model.uploadPhase, .idle, "Back never uploads")

        model.continueFromReview()
        try await waitForState(model) { $0 == .stickerStudio }
        XCTAssertTrue(model.stickerStudio === studio, "Re-entering restores this guest's draft")
        XCTAssertEqual(model.stickerStudio?.placements.count, 1)

        model.backFromStickerStudio()
        model.retakeAll()
        XCTAssertNil(model.stickerStudio, "Replacing every photo discards stickers so none attach to new pictures")
        model.cancelSession()
    }

    func testPhotoPassVisitsStickersAfterDetailsSignatureAndPreview() async throws {
        let model = makeModel(enabled: true)
        try await reachPhotoPassPreview(model)
        let signature = model.passportDraft.signature
        model.continueToReceipt()
        try await waitForState(model) { $0 == .stickerStudio }
        XCTAssertEqual(model.state, .stickerStudio)
        XCTAssertTrue(model.canContinueToReceipt)
        let studio = try XCTUnwrap(model.stickerStudio)
        XCTAssertEqual(studio.layout?.regions.count, 2, "Portrait and hero photos are both decoratable")

        model.backFromStickerStudio()
        XCTAssertEqual(model.state, .passportPreview, "Back returns to the Photo Pass preview")
        XCTAssertEqual(model.passportDraft.name, "Flow Guest")
        XCTAssertEqual(model.passportDraft.signature, signature)

        try await waitForState(model) { _ in model.passportPreviewImage != nil }
        model.continueToReceipt()
        try await waitForState(model) { $0 == .stickerStudio }
        studio.add(try XCTUnwrap(studio.catalog.asset(id: "builtin.crown")))
        let deadline = Date().addingTimeInterval(5)
        while studio.placements.isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        model.finishStickerStudio()
        try await waitForState(model) { $0 == .receiptPreview }
        XCTAssertEqual(model.receiptFinalizationCount, 1)
        XCTAssertEqual(model.composedReceipt?.drawnStickerPlacementIDs.count, 1)
        model.cancelSession()
    }

    func testSettingsAreFrozenPerSessionAndIdleResetClearsTheDraft() async throws {
        final class Switch { var enabled = true }
        let saved = Switch()
        let model = makeModel(enabled: true, configuration: {
            var settings = StickerStudioSettings()
            settings.isEnabled = saved.enabled
            return StickerStudioSessionConfiguration(settings: settings, onlineReady: false)
        })
        try await reachReview(model, format: .solo)
        saved.enabled = false
        XCTAssertTrue(model.stickerStepEnabledForSession, "A settings change mid-session does not change this guest's flow")
        model.continueFromReview()
        try await waitForState(model) { $0 == .stickerStudio }
        XCTAssertEqual(model.state, .stickerStudio)
        XCTAssertTrue(model.isCustomerResetSafe, "An abandoned sticker screen is eligible for idle reset")
        XCTAssertTrue(model.resetAbandonedSessionIfSafe())
        XCTAssertEqual(model.state, .welcome)
        XCTAssertNil(model.stickerStudio, "Idle reset clears stickers")

        try await reachReview(model, format: .solo)
        XCTAssertFalse(model.stickerStepEnabledForSession, "The next session picks up the new setting")
        model.continueFromReview()
        XCTAssertEqual(model.state, .composingReceipt)
        model.cancelSession()
    }

    func testQualificationEnvironmentNeverOpensStickerStudio() {
        var environment = BoothSessionEnvironment.customer
        environment.purpose = .hardwareQualification(runID: "T")
        var settings = StickerStudioSettings()
        settings.isEnabled = true
        environment.stickerConfigurationSource = { StickerStudioSessionConfiguration(settings: settings, onlineReady: false) }
        let model = BoothSessionViewModel(environment: environment, captureConfirmationPause: {})
        model.freezeSessionStickerConfiguration()
        XCTAssertFalse(model.stickerStepEnabledForSession)
    }

    func testStickerStatesIntegrateWithIdleAndErrorPolicies() {
        XCTAssertTrue(CustomerIdleResetPolicy.isEligible(state: .stickerStudio, printerWorking: false, printBatchActive: false, recoveryLocked: false, unresolvedPrint: false))
        XCTAssertFalse(CustomerIdleResetPolicy.isEligible(state: .preparingStickers, printerWorking: false, printBatchActive: false, recoveryLocked: false, unresolvedPrint: false))
        XCTAssertTrue(BoothSessionState.stickerStudio.isActiveSession)
        XCTAssertTrue(BoothSessionState.stickerStudio.allowsCancellation)
        XCTAssertEqual(CustomerErrorKind.classify(state: .preparingStickers), .photoPreparation)
        XCTAssertFalse(StickerStudioView.gestureHint.isEmpty)
    }
}
