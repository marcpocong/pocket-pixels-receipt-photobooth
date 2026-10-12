import CryptoKit
import ImageIO
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import PocketPixelsBooth

@MainActor final class StaticStickerCollectionTests: XCTestCase {
    private func settings() -> StickerStudioSettings {
        var settings = StickerStudioSettings()
        settings.isEnabled = true
        return settings
    }

    func testAll150StickersAreDistinctStaticTransparentAndBounded() throws {
        let assets = BundledStickerFactory.assets
        XCTAssertEqual(assets.count, 150)
        XCTAssertEqual(Set(assets.map(\.id)).count, 150)
        var fingerprints = Set<String>()
        for asset in assets {
            XCTAssertFalse(asset.isAnimated)
            XCTAssertEqual(asset.frameCount, 1)
            XCTAssertEqual(asset.provenance, .builtIn)
            let master = try XCTUnwrap(BundledStickerFactory.image(for: asset.id))
            let png = try XCTUnwrap(UIImage(cgImage: master).pngData())
            fingerprints.insert(SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined())
            let thumbnail = try XCTUnwrap(BundledStickerFactory.image(for: asset.id, maximumPixelDimension: 192))
            XCTAssertLessThanOrEqual(max(thumbnail.width, thumbnail.height), 192)
            XCTAssertTrue(thumbnail === BundledStickerFactory.image(for: asset.id, maximumPixelDimension: 192))
            let bitmap = StickerFixtures.Bitmap(pngData: try XCTUnwrap(UIImage(cgImage: thumbnail).pngData()))
            var ink = 0, transparent = 0
            for index in stride(from: 0, to: bitmap.bytes.count, by: 4) {
                if bitmap.bytes[index + 3] == 0 { transparent += 1 }
                else if bitmap.bytes[index] < 64 { ink += 1 }
            }
            let area = bitmap.width * bitmap.height
            XCTAssertGreaterThan(Double(ink) / Double(area), 0.025, "\(asset.name) needs enough thermal ink")
            XCTAssertLessThan(Double(ink) / Double(area), 0.65, "\(asset.name) must not become a black blob")
            XCTAssertGreaterThan(Double(transparent) / Double(area), 0.05, "\(asset.name) needs transparent surroundings")
        }
        XCTAssertEqual(fingerprints.count, 150, "Distinct names must correspond to distinct artwork")
    }

    func testCategoryBrowsingAndSearchStayEntirelyLocal() throws {
        let catalog = StickerGuestCatalog.make(settings: settings(), store: nil)
        XCTAssertEqual(catalog.assets.count, 150)
        XCTAssertEqual(catalog.categories.count, 11)
        XCTAssertFalse(catalog.categories.contains(.online))
        for category in catalog.categories { XCTAssertFalse(catalog.assets(in: category).isEmpty) }
        for query in ["cat", "birthday", "coffee", "memory", "camera", "heart", "travel", "slay"] {
            XCTAssertFalse(catalog.search(query).isEmpty, "Offline search should find \(query)")
        }
        var filtered = settings()
        filtered.hiddenCategories = [.retro, .birthday]
        let hidden = StickerGuestCatalog.make(settings: filtered, store: nil)
        XCTAssertFalse(hidden.categories.contains(.retro))
        XCTAssertFalse(hidden.assets.contains { $0.category == .birthday })
        filtered.builtInStickersEnabled = false
        XCTAssertTrue(StickerGuestCatalog.make(settings: filtered, store: nil).assets.isEmpty)
    }

    func testNewGIFImportsAreRejectedWhileLegacyFilesAndSettingsSurvive() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try StickerCatalogStore(directoryURL: directory)
        let png = try store.importData(StickerFixtures.pngData(width: 100, height: 100, opaqueFraction: 0.5), name: "Static", category: .cute)
        let gif = StickerFixtures.gifData(levels: [20, 160])
        XCTAssertThrowsError(try store.importData(gif, name: "New animation", category: .cute))
        var oldJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(png)) as? [String: Any])
        oldJSON["id"] = UUID().uuidString
        oldJSON["name"] = "Legacy animation"
        oldJSON["fileName"] = "legacy-preserved.gif"
        oldJSON["typeIdentifier"] = UTType.gif.identifier
        oldJSON["frameCount"] = 2
        oldJSON["byteCount"] = gif.count
        let old = try JSONDecoder().decode(CustomStickerRecord.self, from: JSONSerialization.data(withJSONObject: oldJSON))
        try gif.write(to: store.fileURL(for: old))
        var manifest = store.loadManifest()
        manifest.records.append(old)
        try store.saveManifest(manifest)
        var legacySettings = settings()
        legacySettings.onlineDiscoveryEnabled = true
        legacySettings.onlineRightsAcknowledgement = .init(acknowledgedAt: Date())
        let configuration = StickerStudioSessionConfiguration.current(settings: legacySettings, credentials: InMemoryOnlineStickerCredentialStore(key: "syntheticfixture0123456789"))
        XCTAssertFalse(configuration.onlineReady)
        XCTAssertTrue(configuration.settings.onlineDiscoveryEnabled, "Stored legacy preference is preserved, but inert")
        let catalog = StickerGuestCatalog.make(settings: configuration.settings, store: store)
        XCTAssertNotNil(catalog.asset(id: png.assetID))
        XCTAssertNil(catalog.asset(id: old.assetID))
        XCTAssertEqual(store.records().count, 2)
        XCTAssertEqual(try Data(contentsOf: store.fileURL(for: old)), gif)
        XCTAssertFalse(old.isStaticGuestEligible)
    }

    func testContactSheetsAndExactThermalArtwork() throws {
        let catalog = StickerGuestCatalog.make(settings: settings(), store: nil)
        for category in catalog.categories {
            let assets = catalog.assets(in: category)
            let columns = 4, cell = 144
            let rows = (assets.count + columns - 1) / columns
            let size = CGSize(width: 576, height: rows * cell + 55)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            let sheet = UIGraphicsImageRenderer(size: size, format: format).image { context in
                UIColor.white.setFill(); context.fill(CGRect(origin: .zero, size: size))
                ("\(category.displayName) · \(assets.count) original stickers" as NSString).draw(at: CGPoint(x: 12, y: 12), withAttributes: [.font: UIFont.systemFont(ofSize: 18, weight: .semibold), .foregroundColor: UIColor.black])
                for (index, asset) in assets.enumerated() {
                    let x = CGFloat(index % columns * cell), y = CGFloat(index / columns * cell + 50)
                    if let cgImage = BundledStickerFactory.image(for: asset.id, maximumPixelDimension: 192) {
                        let image = UIImage(cgImage: cgImage)
                        let scale = min(118 / image.size.width, 105 / image.size.height)
                        let drawSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
                        image.draw(in: CGRect(x: x + (144 - drawSize.width) / 2, y: y + (110 - drawSize.height) / 2, width: drawSize.width, height: drawSize.height))
                    }
                    (asset.name as NSString).draw(in: CGRect(x: x + 5, y: y + 114, width: 134, height: 28), withAttributes: [.font: UIFont.systemFont(ofSize: 10, weight: .medium), .foregroundColor: UIColor.black])
                }
            }
            let raster = try ThermalImageRasterizer.rasterize(sheet, purpose: .completeReceipt)
            XCTAssertEqual(raster.width, 576)
            let attachment = XCTAttachment(data: raster.previewPNGData, uniformTypeIdentifier: UTType.png.identifier)
            attachment.name = "collection-\(category.rawValue)-thermal"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    func testRepresentativeStickersAcrossEveryReceiptFormatAndMultipleCopies() throws {
        for format in BoothFormat.allCases {
            let receipt = try StickerFixtures.compose(format)
            let layout = try XCTUnwrap(receipt.stickerLayout)
            let region = try XCTUnwrap(layout.regions.first)
            let ids = ["builtin.twin-lens", "builtin.cat", "builtin.love-letter", "builtin.made-to-keep", "builtin.birthday-tiara"]
            let id = ids[BoothFormat.allCases.firstIndex(of: format)! % ids.count]
            let asset = try XCTUnwrap(BundledStickerFactory.assets.first { $0.id == id })
            var placement = StickerFixtures.placement(target: region.target, x: 0.45, y: 0.52, scale: 0.4, rotation: 0.22, aspect: Double(asset.aspectRatio))
            placement.assetID = asset.id
            placement.assetName = asset.name
            placement = StickerGeometry.clamped(placement, in: region, minimumPrintedDots: 72)
            let artwork = try StickerPrintPreparation.prepare(try XCTUnwrap(BundledStickerFactory.image(for: id, maximumPixelDimension: 768)))
            let frozen = FrozenStickerDecoration(placement: placement, printImage: artwork)
            let first = try StickerFixtures.compose(format, stickers: [frozen])
            let second = try StickerFixtures.compose(format, stickers: [frozen])
            XCTAssertEqual(first.imagePNGData, second.imagePNGData)
            let raster = try ThermalImageRasterizer.rasterize(try XCTUnwrap(UIImage(data: first.imagePNGData)), purpose: .completeReceipt)
            let again = try ThermalImageRasterizer.rasterize(try XCTUnwrap(UIImage(data: second.imagePNGData)), purpose: .completeReceipt)
            XCTAssertEqual(raster.rasterData, again.rasterData)
            let attachment = XCTAttachment(data: raster.previewPNGData, uniformTypeIdentifier: UTType.png.identifier)
            attachment.name = "decorated-\(format.rawValue)-thermal"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    func testRenderStaticStudioInPortraitAndLandscape() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        for size in [CGSize(width: 834, height: 1194), CGSize(width: 1194, height: 834)] {
            let settings = settings()
            let session = StickerStudioSession(configuration: .init(settings: settings, onlineReady: false), catalog: StickerGuestCatalog.make(settings: settings, store: nil), generation: 1, catalogStore: nil)
            let receipt = try StickerFixtures.compose(.grid)
            let layout = try XCTUnwrap(receipt.stickerLayout)
            session.setCanvas(image: ReceiptComposer.makePhotoSectionPreviewImage(from: try XCTUnwrap(UIImage(data: receipt.imagePNGData)), previewContentHeight: layout.editorVisibleHeight), layout: layout)
            let view = StickerStudioView(session: session, onDone: {}, onSkip: {}, onBack: {}, onCancel: {}, onActivity: {}).background(MadeToKeepPaperBackground())
            let controller = UIHostingController(rootView: view)
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(origin: .zero, size: size)
            window.rootViewController = controller
            window.makeKeyAndVisible()
            try await Task.sleep(for: .milliseconds(400))
            controller.view.frame = window.bounds; controller.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(size: size).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
            XCTAssertGreaterThan(image.pngData()?.count ?? 0, 30_000)
            let attachment = XCTAttachment(image: image)
            attachment.name = size.width < size.height ? "static-studio-portrait" : "static-studio-landscape"
            attachment.lifetime = .keepAlways
            add(attachment)
            window.isHidden = true
            session.close()
        }
    }
    func testOperatorControlsAndPreviewWithoutEnablingLiveStudio() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let size = CGSize(width: 834, height: 1194)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        let controls = UIHostingController(rootView: NavigationStack { StickerStudioOperatorView() })
        window.rootViewController = controls
        window.makeKeyAndVisible()
        try await Task.sleep(for: .milliseconds(350))
        controls.view.frame = window.bounds; controls.view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(size: size).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        let attachment = XCTAttachment(image: image)
        attachment.name = "static-operator-controls"
        attachment.lifetime = .keepAlways
        add(attachment)
        // Preview deliberately overrides the master switch only in its own sample draft.
        let before = StickerStudioSettingsStore.load()
        let preview = UIHostingController(rootView: NavigationStack { StickerStudioPreviewView(settings: .default) })
        window.rootViewController = preview
        try await Task.sleep(for: .milliseconds(700))
        preview.view.frame = window.bounds; preview.view.layoutIfNeeded()
        let sample = UIGraphicsImageRenderer(size: size).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        let sampleAttachment = XCTAttachment(image: sample)
        sampleAttachment.name = "offline-preview-with-master-off"
        sampleAttachment.lifetime = .keepAlways
        add(sampleAttachment)
        XCTAssertEqual(StickerStudioSettingsStore.load(), before, "Preview cannot turn live guest editing on")
        XCTAssertGreaterThan(sample.pngData()?.count ?? 0, 30_000)
        window.isHidden = true
    }

}
