import SwiftUI
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import PocketPixelsBooth

/// Native Unicode emoji stickers: grapheme validation, system-font rendering, thermal
/// legibility, editor behaviour, settings migration and legacy compatibility.
@MainActor
final class EmojiStickerTests: XCTestCase {
    /// Representative sequences, including the hard cases called out for print fidelity.
    static let representative: [(String, String)] = [
        ("😀", "ordinary"),
        ("❤️", "variation selector"),
        ("👍🏽", "skin tone"),
        ("🇵🇭", "flag"),
        ("👨‍👩‍👧‍👦", "ZWJ family"),
        ("🧑🏻‍🤝‍🧑🏿", "ZWJ with two skin tones"),
        ("🏳️‍🌈", "ZWJ flag with selector"),
        ("🏴󠁧󠁢󠁳󠁣󠁴󠁿", "tag subdivision flag"),
        ("#️⃣", "keycap"),
        ("🤍", "white heart (light ink)"),
        ("⭐", "yellow star"),
        ("😂", "face with tears of joy")
    ]

    // MARK: Validation

    func testValidatorAcceptsEveryRepresentativeSequenceAsOneGrapheme() throws {
        for (glyph, kind) in Self.representative {
            XCTAssertEqual(glyph.count, 1, "\(kind) is one extended grapheme cluster")
            let result = EmojiGlyphValidator.validate(glyph)
            XCTAssertEqual(try result.get(), glyph, "\(kind) must validate unchanged")
        }
        // Whitespace from the keyboard is trimmed.
        XCTAssertEqual(try EmojiGlyphValidator.validate("  🎉\n").get(), "🎉")
    }

    func testValidatorNormalizesTextDefaultPictographToEmojiPresentation() throws {
        // U+2764 alone is text-default; the sticker uses the emoji form, never a text glyph.
        XCTAssertEqual(try EmojiGlyphValidator.validate("\u{2764}").get(), "\u{2764}\u{FE0F}")
    }

    func testValidatorRejectsTextEmptyModifiersAndLongPastes() {
        XCTAssertEqual(EmojiGlyphValidator.validate(""), .failure(.empty))
        XCTAssertEqual(EmojiGlyphValidator.validate("   "), .failure(.empty))
        XCTAssertEqual(EmojiGlyphValidator.validate("a"), .failure(.notEmoji))
        XCTAssertEqual(EmojiGlyphValidator.validate("7"), .failure(.notEmoji), "Digits are emoji only as keycaps")
        XCTAssertEqual(EmojiGlyphValidator.validate("#"), .failure(.notEmoji))
        XCTAssertEqual(EmojiGlyphValidator.validate("é"), .failure(.notEmoji))
        XCTAssertEqual(EmojiGlyphValidator.validate("hi"), .failure(.multipleCharacters))
        XCTAssertEqual(EmojiGlyphValidator.validate("😀😀"), .failure(.multipleCharacters))
        XCTAssertEqual(EmojiGlyphValidator.validate("😀a"), .failure(.multipleCharacters))
        XCTAssertEqual(EmojiGlyphValidator.validate("🏽"), .failure(.standaloneComponent), "Bare skin-tone modifier")
        XCTAssertEqual(EmojiGlyphValidator.validate("🇵"), .failure(.standaloneComponent), "Lone regional indicator")
        XCTAssertEqual(EmojiGlyphValidator.validate("\u{200D}"), .failure(.notEmoji))
        XCTAssertEqual(EmojiGlyphValidator.validate("\u{FE0F}"), .failure(.notEmoji))
        XCTAssertEqual(EmojiGlyphValidator.validate(String(repeating: "x", count: 500)), .failure(.tooLong))
        XCTAssertEqual(EmojiGlyphValidator.validate(String(repeating: "😀", count: 80)), .failure(.tooLong))
    }

    func testValidatorRejectsSequencesTheSystemFontCannotDrawAsOneEmoji() {
        // A made-up ZWJ chain is one grapheme but draws as several glyphs.
        let invented = "🐱\u{200D}🍕\u{200D}🚀"
        XCTAssertEqual(invented.count, 1)
        XCTAssertEqual(EmojiGlyphValidator.validate(invented), .failure(.unsupportedOnDevice))
        XCTAssertFalse(EmojiGlyphValidator.isSingleSystemEmojiGlyph("ab"))
        XCTAssertTrue(EmojiGlyphValidator.isSingleSystemEmojiGlyph("👨‍👩‍👧‍👦"))
    }

    // MARK: Rendering and print fidelity

    func testRendererProducesBoundedMatchingDisplayAndPrintArtwork() throws {
        for (glyph, kind) in Self.representative {
            let artwork = try EmojiStickerRenderer.makeArtwork(for: glyph)
            XCTAssertEqual(artwork.display.width, artwork.print.width, kind)
            XCTAssertEqual(artwork.display.height, artwork.print.height, kind)
            XCTAssertLessThanOrEqual(max(artwork.display.width, artwork.display.height), EmojiStickerRenderer.pixelDimension, kind)
            XCTAssertGreaterThan(min(artwork.display.width, artwork.display.height), 200, kind)

            let display = PixelStats(artwork.display)
            if kind != "white heart (light ink)" {
                XCTAssertGreaterThan(display.colorfulFraction, 0.05, "\(kind) editor art is the colour system glyph")
            }
            XCTAssertTrue(display.edgesAreTransparent, "\(kind) has a transparent margin, so no glyph edge is clipped")

            let print = PixelStats(artwork.print)
            XCTAssertEqual(print.colorfulFraction, 0, "\(kind) print art is grayscale")
            XCTAssertTrue(print.alphaIsBinary, "\(kind) print alpha is snapped by StickerPrintPreparation")
            XCTAssertGreaterThan(print.visibleFraction, 0.2, "\(kind) has a real silhouette")
            XCTAssertGreaterThan(print.darkFraction, 0.06, "\(kind) has enough dark ink to print")
            XCTAssertTrue(print.edgesAreTransparent, kind)
        }
    }

    func testRendererIsDeterministic() throws {
        let first = try EmojiStickerRenderer.makeArtwork(for: "👨‍👩‍👧‍👦")
        let second = try EmojiStickerRenderer.makeArtwork(for: "👨‍👩‍👧‍👦")
        XCTAssertEqual(UIImage(cgImage: first.print).pngData(), UIImage(cgImage: second.print).pngData())
    }

    func testToneCurveDarkensBrightColoursButKeepsHighlightsWhite() {
        XCTAssertEqual(EmojiStickerRenderer.toneMapped(255), 255, accuracy: 0.5)
        XCTAssertEqual(EmojiStickerRenderer.toneMapped(0), 0, accuracy: 0.5)
        // Emoji yellow (#FFCC4D) has luminance ≈ 209: it must print well below paper white.
        XCTAssertLessThan(EmojiStickerRenderer.toneMapped(209), 200)
        XCTAssertLessThan(EmojiStickerRenderer.toneMapped(128), 100, "Mid-tones darken for the dither")
        var previous = -1.0
        for value in stride(from: 0.0, through: 255, by: 5) {
            let mapped = EmojiStickerRenderer.toneMapped(value)
            XCTAssertGreaterThanOrEqual(mapped, previous, "Tone curve is monotonic")
            previous = mapped
        }
    }

    /// Composes real receipts with complex emoji, rasterizes them with the production thermal
    /// rasterizer and checks the sticker area is inked while the QR and other photos are not
    /// touched. Rasters are attached (and optionally dumped) for visual inspection.
    func testEmojiStickersAreLegibleInTheThermalRasterAndRespectProtectedAreas() throws {
        let baseline = try StickerFixtures.compose(.grid)
        let layout = try XCTUnwrap(baseline.stickerLayout)
        let baselineRaster = try ThermalImageRasterizer.rasterize(try XCTUnwrap(UIImage(data: baseline.imagePNGData)), purpose: .completeReceipt)
        let glyphs = ["😀", "👨‍👩‍👧‍👦", "🇵🇭", "👍🏽"]
        var decorations: [FrozenStickerDecoration] = []
        for (index, glyph) in glyphs.enumerated() {
            let region = try XCTUnwrap(layout.region(for: .photo(index: index)))
            let artwork = try EmojiStickerRenderer.makeArtwork(for: glyph)
            var placement = StickerFixtures.placement(target: region.target, scale: 0.6, aspect: artwork.aspectRatio)
            placement.provenance = .systemEmoji
            placement.assetID = StickerStudioSession.emojiAssetID(for: glyph)
            decorations.append(FrozenStickerDecoration(placement: StickerGeometry.clamped(placement, in: region, minimumPrintedDots: 72), printImage: artwork.print))
        }
        let decorated = try StickerFixtures.compose(.grid, stickers: decorations)
        XCTAssertEqual(decorated.width, baseline.width)
        XCTAssertEqual(decorated.height, baseline.height, "Stickers never change receipt geometry")
        let raster = try ThermalImageRasterizer.rasterize(try XCTUnwrap(UIImage(data: decorated.imagePNGData)), purpose: .completeReceipt)
        XCTAssertEqual(raster.rasterData.count, baselineRaster.rasterData.count)

        for decoration in decorations {
            let region = try XCTUnwrap(layout.region(for: decoration.placement.target))
            let frame = try StickerGeometry.resolve(decoration.placement, in: region)
            let changed = RasterRegion.changedDots(raster, baselineRaster, in: frame.visibleBounds)
            XCTAssertGreaterThan(changed, 0.10, "\(decoration.placement.assetID) visibly changes the printed dots")
        }
        // Error-diffusion dithering spreads tiny differences, so protected areas are checked on the
        // composed receipt pixels: nothing outside the approved clip rectangles may change.
        let changedOutside = try ComposedPixels.changedPixels(
            UIImage(data: decorated.imagePNGData)!, UIImage(data: baseline.imagePNGData)!,
            outside: layout.regions.map(\.clipRect))
        XCTAssertEqual(changedOutside, 0, "Emoji ink never leaves the approved photo regions (QR, text and footer untouched)")

        let attachment = XCTAttachment(data: raster.previewPNGData, uniformTypeIdentifier: UTType.png.identifier)
        attachment.name = "emoji-grid-thermal"
        attachment.lifetime = .keepAlways
        add(attachment)
        try Self.dump(raster.previewPNGData, name: "emoji-grid-thermal.png")
        try Self.dump(decorated.imagePNGData, name: "emoji-grid-keepsake.png")
        for (glyph, kind) in Self.representative {
            let artwork = try EmojiStickerRenderer.makeArtwork(for: glyph)
            try Self.dump(UIImage(cgImage: artwork.print).pngData(), name: "emoji-print-\(kind.replacingOccurrences(of: " ", with: "-")).png")
            try Self.dump(UIImage(cgImage: artwork.display).pngData(), name: "emoji-display-\(kind.replacingOccurrences(of: " ", with: "-")).png")
        }
    }

    func testEmojiStickersOnEveryFormatKeepReceiptGeometry() throws {
        for format in BoothFormat.allCases {
            let baseline = try StickerFixtures.compose(format)
            guard let layout = baseline.stickerLayout, let region = layout.regions.first else { continue }
            let artwork = try EmojiStickerRenderer.makeArtwork(for: "🥳")
            let placement = StickerGeometry.clamped(StickerFixtures.placement(target: region.target, aspect: artwork.aspectRatio), in: region, minimumPrintedDots: 72)
            let decorated = try StickerFixtures.compose(format, stickers: [FrozenStickerDecoration(placement: placement, printImage: artwork.print)])
            XCTAssertEqual(decorated.height, baseline.height, format.rawValue)
            XCTAssertNotEqual(decorated.imagePNGData, baseline.imagePNGData, format.rawValue)
        }
    }

    // MARK: Editor behaviour

    private func makeSession(limit: Int = 6, emoji: Bool = true, legacy: Bool = false) throws -> StickerStudioSession {
        var settings = StickerStudioSettings()
        settings.isEnabled = true
        settings.emojiCollectionEnabled = emoji
        settings.builtInStickersEnabled = legacy
        settings.guestStickerLimit = limit
        let configuration = StickerStudioSessionConfiguration(settings: settings.normalized(), onlineReady: false)
        let session = StickerStudioSession(configuration: configuration, catalog: StickerGuestCatalog.make(settings: settings, store: nil), generation: 1, catalogStore: nil)
        let receipt = try StickerFixtures.compose(.grid)
        session.setCanvas(image: UIImage(data: receipt.imagePNGData)!, layout: try XCTUnwrap(receipt.stickerLayout))
        return session
    }

    private func waitForInsertions(_ session: StickerStudioSession, timeout: TimeInterval = 10) async {
        let deadline = Date().addingTimeInterval(timeout)
        while session.pendingInsertions > 0, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    func testAddingEmojiUsesExistingGeometryUndoRedoAndFreeze() async throws {
        let session = try makeSession()
        XCTAssertTrue(session.hasEmoji)
        XCTAssertFalse(session.hasArtwork, "Original artwork is no longer in the default guest palette")
        XCTAssertEqual(session.activePaletteSource, .emoji)
        XCTAssertNil(session.addEmoji("👨‍👩‍👧‍👦"))
        await waitForInsertions(session)
        let placement = try XCTUnwrap(session.placements.first)
        XCTAssertEqual(placement.provenance, .systemEmoji)
        XCTAssertEqual(placement.assetID, "emoji.1f468-200d-1f469-200d-1f467-200d-1f466")
        XCTAssertEqual(placement.assetName, "Family: man, woman, girl, boy")
        XCTAssertNotNil(session.displayArtwork[placement.id], "Editor shows the colour glyph")
        XCTAssertNotNil(session.artwork[placement.id], "Print artwork is frozen separately")
        XCTAssertFalse(session.displayArtwork[placement.id] === session.artwork[placement.id])
        XCTAssertEqual(session.recentEmoji, ["👨‍👩‍👧‍👦"])

        // Gestures go through the same StickerGeometry commit.
        session.commitGesture(placement.id, translation: CGSize(width: 30, height: 10), magnification: 1.3, rotation: 0.4, displayScale: 1)
        let moved = try XCTUnwrap(session.placements.first)
        XCTAssertNotEqual(moved, placement)
        session.undo()
        XCTAssertEqual(session.placements.first, placement)
        session.redo()
        XCTAssertEqual(session.placements.first, moved)

        session.delete(moved.id)
        XCTAssertTrue(session.placements.isEmpty)
        XCTAssertTrue(session.displayArtwork.isEmpty)
        session.undo()
        XCTAssertEqual(session.placements.first, moved)
        XCTAssertNotNil(session.displayArtwork[moved.id], "Undo restores the colour editor art too")

        let frozen = session.freeze()
        XCTAssertEqual(frozen.count, 1)
        XCTAssertTrue(frozen[0].printImage === session.artwork[moved.id], "Receipts draw the print artwork, never the colour glyph")
    }

    func testEmojiRespectsStickerLimitAndRejectsInvalidInput() async throws {
        let session = try makeSession(limit: 2)
        XCTAssertEqual(session.addEmoji("hello"), .multipleCharacters)
        XCTAssertNotNil(session.notice)
        XCTAssertEqual(session.addEmoji("🏽"), .standaloneComponent)
        XCTAssertTrue(session.placements.isEmpty)
        session.addEmoji("😀")
        session.addEmoji("🇵🇭")
        await waitForInsertions(session)
        XCTAssertEqual(session.placements.count, 2)
        XCTAssertTrue(session.isAtLimit)
        session.addEmoji("⭐")
        await waitForInsertions(session)
        XCTAssertEqual(session.placements.count, 2)
        XCTAssertEqual(session.notice, "You've used all 2 stickers. Delete one to add another.")
    }

    func testRecentEmojiAreScopedToOneSessionAndClosingReleasesEverything() async throws {
        let first = try makeSession()
        first.addEmoji("🥳")
        await waitForInsertions(first)
        first.addEmoji("👍🏽")
        await waitForInsertions(first)
        XCTAssertEqual(first.recentEmoji, ["👍🏽", "🥳"])
        XCTAssertEqual(first.emojiSections.first?.title, "Recent")
        first.close()
        XCTAssertTrue(first.recentEmoji.isEmpty)
        XCTAssertTrue(first.displayArtwork.isEmpty)
        XCTAssertTrue(first.artwork.isEmpty)
        // A late render for a closed session is dropped.
        let closing = try makeSession()
        closing.addEmoji("🎉")
        closing.close()
        await waitForInsertions(closing)
        XCTAssertTrue(closing.placements.isEmpty)

        let next = try makeSession()
        XCTAssertTrue(next.recentEmoji.isEmpty, "The next guest never sees the previous guest's emoji")
        XCTAssertEqual(next.emojiSections.first?.title, "Popular")
        XCTAssertEqual(next.visibleEmoji.first?.glyph, EmojiCatalog.popularGlyphs.first)
    }

    func testLegacyArtworkAndEmojiCanBeOfferedTogetherOrSeparately() throws {
        let both = try makeSession(emoji: true, legacy: true)
        XCTAssertTrue(both.offersSourceChoice)
        both.paletteSource = .artwork
        XCTAssertEqual(both.activePaletteSource, .artwork)
        XCTAssertFalse(both.visibleAssets.isEmpty, "Original artwork still works when an operator enables it")

        let legacyOnly = try makeSession(emoji: false, legacy: true)
        XCTAssertFalse(legacyOnly.hasEmoji)
        XCTAssertEqual(legacyOnly.activePaletteSource, .artwork)
        XCTAssertNil(legacyOnly.emojiCatalog)

        let none = try makeSession(emoji: false, legacy: false)
        XCTAssertFalse(none.hasContent, "Nothing to offer: the view model skips the editor")
    }

    // MARK: Catalog

    func testBundledCatalogCoversUnicodeGroupsSkinTonesAndSearch() throws {
        let catalog = EmojiCatalog.shared
        XCTAssertEqual(catalog.groups.map(\.key), ["smileys", "people", "animals", "food", "travel", "activities", "objects", "symbols", "flags"])
        XCTAssertGreaterThan(catalog.allEntries.count, 1_800)
        XCTAssertGreaterThan(catalog.totalSelectableCount, 3_400)
        XCTAssertEqual(Set(catalog.allEntries.map(\.glyph)).count, catalog.allEntries.count, "No duplicate glyphs")
        for entry in catalog.allEntries.prefix(400) + catalog.allEntries.suffix(300) {
            XCTAssertEqual(entry.glyph.count, 1, entry.name)
        }
        let thumbs = try XCTUnwrap(catalog.entry(for: "👍"))
        XCTAssertEqual(thumbs.skinToneVariants.count, 5)
        XCTAssertEqual(catalog.entry(for: "👍🏽")?.glyph, "👍", "A skin-tone form resolves to its base")
        XCTAssertTrue(catalog.search("heart").contains { $0.glyph == "❤️" })
        XCTAssertTrue(catalog.search("love").contains { $0.glyph == "❤️" }, "Everyday synonyms")
        XCTAssertTrue(catalog.search("philippines").contains { $0.glyph == "🇵🇭" })
        XCTAssertTrue(catalog.search("cats").contains { $0.glyph == "🐈" }, "Plurals")
        XCTAssertFalse(catalog.search("cat").contains { $0.name == "vacation" })
        XCTAssertEqual(catalog.search("🎉").first?.glyph, "🎉", "A typed emoji finds itself")
        XCTAssertTrue(catalog.search("zzzzqq").isEmpty)
        XCTAssertTrue(catalog.popularEntries.count >= 20)
        XCTAssertNotNil(catalog.entry(for: "👨‍👩‍👧‍👦"))
    }

    func testCatalogFiltersEntriesTheSystemFontCannotDraw() throws {
        let data = Data(#"{"unicodeVersion":"99.0","groups":[{"key":"smileys","name":"Smileys & Emotion","emoji":[{"g":"😀","n":"grinning face","s":"face-smiling","e":"1.0"},{"g":"🫩","n":"future face","s":"face-new","e":"16.0","v":["🫩"]}]}]}"#.utf8)
        let catalog = try XCTUnwrap(EmojiCatalog.decode(data, supportCheck: { _ in false }))
        XCTAssertEqual(catalog.allEntries.map(\.glyph), ["😀"], "Old emoji are kept; unsupported new ones are hidden")
        XCTAssertEqual(catalog.unsupportedCount, 2)
    }

    // MARK: Settings

    func testSettingsMigrationMakesEmojiPrimaryAndKeepsArtworkAsOptionalLegacySource() throws {
        let suite = "EmojiStickerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertTrue(StickerStudioSettings.default.emojiCollectionEnabled)
        XCTAssertFalse(StickerStudioSettings.default.builtInStickersEnabled)
        XCTAssertFalse(StickerStudioSettings.default.isEnabled, "Master switch behaviour is unchanged")

        // A schema-1 install (built-in artwork on, master on, operator imports on).
        defaults.set(Data(#"{"schemaVersion":1,"isEnabled":true,"builtInStickersEnabled":true,"operatorCollectionEnabled":true,"guestStickerLimit":4}"#.utf8), forKey: StickerStudioSettingsStore.storageKey)
        let migrated = StickerStudioSettingsStore.load(defaults: defaults)
        XCTAssertEqual(migrated.schemaVersion, 2)
        XCTAssertTrue(migrated.isEnabled)
        XCTAssertTrue(migrated.emojiCollectionEnabled)
        XCTAssertFalse(migrated.builtInStickersEnabled)
        XCTAssertTrue(migrated.operatorCollectionEnabled, "Imported stickers stay available")
        XCTAssertEqual(migrated.guestStickerLimit, 4)

        // An operator who re-enables the artwork and disables emoji keeps that choice.
        var chosen = migrated
        chosen.builtInStickersEnabled = true
        chosen.emojiCollectionEnabled = false
        StickerStudioSettingsStore.save(chosen, defaults: defaults)
        let reloaded = StickerStudioSettingsStore.load(defaults: defaults)
        XCTAssertTrue(reloaded.builtInStickersEnabled)
        XCTAssertFalse(reloaded.emojiCollectionEnabled)
        XCTAssertTrue(reloaded.hasAnyLocalSource())

        var nothing = StickerStudioSettings()
        nothing.isEnabled = true
        nothing.emojiCollectionEnabled = false
        nothing.builtInStickersEnabled = false
        nothing.operatorCollectionEnabled = false
        XCTAssertFalse(StickerStudioSessionConfiguration(settings: nothing, onlineReady: false).isGuestStepEnabled)
    }

    // MARK: Screenshots

    func testRenderEmojiStudioInPortraitAndLandscape() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        for size in [CGSize(width: 834, height: 1194), CGSize(width: 1194, height: 834)] {
            let session = try makeSession()
            let receipt = try StickerFixtures.compose(.grid)
            let layout = try XCTUnwrap(receipt.stickerLayout)
            session.setCanvas(image: ReceiptComposer.makePhotoSectionPreviewImage(from: try XCTUnwrap(UIImage(data: receipt.imagePNGData)), previewContentHeight: layout.editorVisibleHeight), layout: layout)
            session.addEmoji("🥳")
            session.addEmoji("🇵🇭")
            await waitForInsertions(session)
            let view = StickerStudioView(session: session, onDone: {}, onSkip: {}, onBack: {}, onCancel: {}, onActivity: {}).background(MadeToKeepPaperBackground())
            let image = try await ScreenshotHarness.render(view, size: size, scene: scene)
            let name = size.width < size.height ? "emoji-studio-portrait" : "emoji-studio-landscape"
            add(ScreenshotHarness.attachment(image, name: name))
            try Self.dump(image.pngData(), name: name + ".png")
            session.close()
        }
    }

    // MARK: Helpers

    /// Writes inspection images when `UI_DUMP_DIR` is set (pass `TEST_RUNNER_UI_DUMP_DIR` to xcodebuild).
    static func dump(_ data: Data?, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["UI_DUMP_DIR"], let data else { return }
        let url = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try data.write(to: url.appendingPathComponent(name))
    }
}

/// Pixel statistics for an RGBA image.
struct PixelStats {
    var visibleFraction = 0.0
    var darkFraction = 0.0
    var colorfulFraction = 0.0
    var alphaIsBinary = true
    var edgesAreTransparent = true

    init(_ image: CGImage) {
        let width = image.width, height = image.height
        guard let context = EmojiStickerRenderer.rgbaContext(width: width, height: height) else { return }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return }
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        var visible = 0, dark = 0, colorful = 0
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let alpha = pixels[offset + 3]
                if alpha != 0 && alpha != 255 { alphaIsBinary = false }
                if (x == 0 || y == 0 || x == width - 1 || y == height - 1), alpha > 8 { edgesAreTransparent = false }
                guard alpha >= 128 else { continue }
                visible += 1
                let r = Int(pixels[offset]), g = Int(pixels[offset + 1]), b = Int(pixels[offset + 2])
                if max(r, g, b) - min(r, g, b) > 24 { colorful += 1 }
                if (r * 299 + g * 587 + b * 114) / 1000 < 150 * Int(alpha) / 255 { dark += 1 }
            }
        }
        let area = Double(width * height)
        visibleFraction = Double(visible) / area
        darkFraction = visible > 0 ? Double(dark) / Double(visible) : 0
        colorfulFraction = visible > 0 ? Double(colorful) / Double(visible) : 0
    }
}

/// Dot-level comparison of two rasters of identical geometry.
enum RasterRegion {
    static func dot(_ raster: ThermalRasterizedImage, x: Int, y: Int) -> Bool {
        let byte = raster.rasterData[y * raster.widthBytes + x / 8]
        return byte & (0x80 >> UInt8(x % 8)) != 0
    }

    /// Fraction of dots inside `rect` that differ between the rasters.
    static func changedDots(_ lhs: ThermalRasterizedImage, _ rhs: ThermalRasterizedImage, in rect: CGRect) -> Double {
        let bounds = rect.integral.intersection(CGRect(x: 0, y: 0, width: lhs.width, height: lhs.height))
        guard !bounds.isNull, bounds.width > 0, bounds.height > 0 else { return 0 }
        var changed = 0, total = 0
        for y in Int(bounds.minY)..<Int(bounds.maxY) {
            for x in Int(bounds.minX)..<Int(bounds.maxX) {
                total += 1
                if dot(lhs, x: x, y: y) != dot(rhs, x: x, y: y) { changed += 1 }
            }
        }
        return Double(changed) / Double(max(1, total))
    }

    /// Number of differing dots outside every allowed rectangle.
    static func changedDots(_ lhs: ThermalRasterizedImage, _ rhs: ThermalRasterizedImage, outside allowed: [CGRect]) -> Int {
        let expanded = allowed.map { $0.insetBy(dx: -1, dy: -1) }
        var changed = 0
        for y in 0..<lhs.height {
            for x in 0..<lhs.width where dot(lhs, x: x, y: y) != dot(rhs, x: x, y: y) {
                let point = CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)
                if !expanded.contains(where: { $0.contains(point) }) { changed += 1 }
            }
        }
        return changed
    }
}

/// Renders a SwiftUI view in a real window at an exact iPad size.
@MainActor
enum ScreenshotHarness {
    static func render<V: View>(_ view: V, size: CGSize, scene: UIWindowScene, settle: Duration = .milliseconds(600)) async throws -> UIImage {
        let controller = UIHostingController(rootView: view)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        // Start SwiftUI layout / onAppear before measuring the settle interval. A busy simulator
        // can otherwise defer first layout until after the wait and capture an entrance at zero opacity.
        controller.view.frame = window.bounds
        controller.view.layoutIfNeeded()
        await Task.yield()
        try await Task.sleep(for: settle)
        controller.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        let image = UIGraphicsImageRenderer(size: size).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        window.isHidden = true
        return image
    }

    static func attachment(_ image: UIImage, name: String) -> XCTAttachment {
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        return attachment
    }
}

/// Exact pixel comparison of two composed receipts of identical size.
enum ComposedPixels {
    static func changedPixels(_ lhs: UIImage, _ rhs: UIImage, outside allowed: [CGRect]) throws -> Int {
        let a = try XCTUnwrap(lhs.cgImage), b = try XCTUnwrap(rhs.cgImage)
        XCTAssertEqual(a.width, b.width); XCTAssertEqual(a.height, b.height)
        func bytes(_ image: CGImage) -> [UInt8] {
            let context = EmojiStickerRenderer.rgbaContext(width: image.width, height: image.height)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return Array(UnsafeBufferPointer(start: context.data!.bindMemory(to: UInt8.self, capacity: image.width * image.height * 4), count: image.width * image.height * 4))
        }
        let left = bytes(a), right = bytes(b)
        let expanded = allowed.map { $0.insetBy(dx: -1, dy: -1) }
        var changed = 0
        for y in 0..<a.height {
            for x in 0..<a.width {
                let offset = (y * a.width + x) * 4
                guard left[offset..<offset + 4] != right[offset..<offset + 4] else { continue }
                if !expanded.contains(where: { $0.contains(CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)) }) { changed += 1 }
            }
        }
        return changed
    }
}
