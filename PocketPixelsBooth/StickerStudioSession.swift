//
//  StickerStudioSession.swift
//  PocketPixelsBooth
//
//  One guest's static sticker draft: placements, selection, undo/redo and artwork.
//  Owned by BoothSessionViewModel for exactly one customer session generation and
//  discarded with it. Nothing here uploads, archives, prints or writes to disk.
//

import CoreGraphics
import Foundation
import Observation
import UIKit

@MainActor
@Observable
final class StickerStudioSession {
    let configuration: StickerStudioSessionConfiguration
    let catalog: StickerGuestCatalog
    /// The customer session this draft belongs to. Async work checks it before mutating.
    let generation: Int
    @ObservationIgnored private let catalogStore: StickerCatalogStore?

    private(set) var layout: StickerLayoutSnapshot?
    /// The real composed receipt (without stickers), cropped to the decorated area.
    private(set) var canvasImage: UIImage?
    private(set) var placements: [StickerPlacement] = []
    var selectedPlacementID: UUID?
    var selectedCategory: StickerCategory?
    var searchQuery = ""
    private(set) var notice: String?
    private(set) var thumbnails: [String: UIImage] = [:]
    private(set) var failedThumbnails: Set<String> = []
    private(set) var pendingInsertions = 0
    private(set) var canUndo = false
    private(set) var canRedo = false

    /// Print-prepared still artwork per placement — exactly what the receipt will draw.
    private(set) var artwork: [UUID: CGImage] = [:]
    /// Editor-only colour artwork (native emoji). Same pixel size and framing as `artwork`, so
    /// geometry is identical; it is never frozen, printed or uploaded.
    private(set) var displayArtwork: [UUID: CGImage] = [:]
    /// Per-placement print notes, e.g. a very light emoji.
    private(set) var printWarnings: [UUID: String] = [:]
    /// Emoji this guest used, most recent first. Lives and dies with this session only.
    private(set) var recentEmoji: [String] = []
    /// Which collection the palette shows.
    var paletteSource: StickerPaletteSource = .emoji
    /// Selected emoji group key, or `EmojiPaletteSection.recentKey`.
    var selectedEmojiGroupKey: String = EmojiPaletteSection.recentKey
    private struct EditSnapshot {
        let placements: [StickerPlacement]
        let artwork: [UUID: CGImage]
        let displayArtwork: [UUID: CGImage]
        let printWarnings: [UUID: String]
    }
    private var snapshot: EditSnapshot {
        let live = Set(placements.map(\.id))
        return EditSnapshot(
            placements: placements,
            artwork: artwork.filter { live.contains($0.key) },
            displayArtwork: displayArtwork.filter { live.contains($0.key) },
            printWarnings: printWarnings.filter { live.contains($0.key) }
        )
    }
    @ObservationIgnored private let emojiEnabled: Bool
    @ObservationIgnored private let emojiCatalogOverride: EmojiCatalog?
    @ObservationIgnored private var undoStack: [EditSnapshot] = []
    @ObservationIgnored private var redoStack: [EditSnapshot] = []
    @ObservationIgnored private var thumbnailTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var isClosed = false

    static let undoDepth = 30

    /// The legacy provider argument is ignored; this model cannot start a network request.
    init(
        configuration: StickerStudioSessionConfiguration,
        catalog: StickerGuestCatalog,
        generation: Int,
        catalogStore: StickerCatalogStore?,
        provider: OnlineStickerProvider? = nil,
        emojiCatalog: EmojiCatalog? = nil
    ) {
        self.configuration = configuration
        self.catalog = catalog
        self.generation = generation
        self.catalogStore = catalogStore
        self.selectedCategory = catalog.categories.first
        self.emojiEnabled = configuration.settings.emojiCollectionEnabled
        self.emojiCatalogOverride = emojiCatalog
        self.paletteSource = configuration.settings.emojiCollectionEnabled ? .emoji : .artwork
    }

    var limit: Int { configuration.settings.guestStickerLimit }
    var minimumPrintedDots: Int { configuration.settings.minimumPrintedStickerDots }
    var isAtLimit: Bool { placements.count + pendingInsertions >= limit }
    var hasContent: Bool { hasEmoji || !catalog.assets.isEmpty }

    /// The Unicode emoji collection, when this session froze it ON and the data is readable.
    var emojiCatalog: EmojiCatalog? {
        guard emojiEnabled else { return nil }
        let catalog = emojiCatalogOverride ?? EmojiCatalog.shared
        return catalog.groups.isEmpty ? nil : catalog
    }

    var hasEmoji: Bool { emojiCatalog != nil }
    var hasArtwork: Bool { !catalog.assets.isEmpty }
    /// Both collections are on: the palette shows an Emoji / Stickers switch.
    var offersSourceChoice: Bool { hasEmoji && hasArtwork }

    var activePaletteSource: StickerPaletteSource {
        if !hasEmoji { return .artwork }
        if !hasArtwork { return .emoji }
        return paletteSource
    }

    /// Emoji sections in display order: Recent (or Popular before first use) then Unicode groups.
    var emojiSections: [EmojiPaletteSection] {
        guard let emojiCatalog else { return [] }
        // One stable lead tab: popular picks until this guest has used an emoji, then their recents.
        let lead: EmojiPaletteSection = recentEmoji.isEmpty
            ? .init(key: EmojiPaletteSection.recentKey, title: "Popular", systemImage: "star")
            : .init(key: EmojiPaletteSection.recentKey, title: "Recent", systemImage: "clock")
        return [lead] + emojiCatalog.groups.map { .init(key: $0.key, title: $0.displayName, systemImage: $0.systemImage) }
    }

    /// The emoji grid for the current section or search.
    var visibleEmoji: [EmojiEntry] {
        guard let emojiCatalog else { return [] }
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty { return emojiCatalog.search(query) }
        switch selectedEmojiGroupKey {
        case EmojiPaletteSection.recentKey:
            let recent = recentEmoji.compactMap { glyph in emojiCatalog.entry(for: glyph).map { RecentEmoji(entry: $0, glyph: glyph).asEntry } }
            return recent.isEmpty ? emojiCatalog.popularEntries : recent
        default:
            return emojiCatalog.group(key: selectedEmojiGroupKey)?.entries ?? []
        }
    }

    /// Non-empty offline collections in display order.
    var categories: [StickerCategory] {
        catalog.categories
    }

    func assetCount(in category: StickerCategory) -> Int { catalog.assets(in: category).count }
    func catalogSearch(_ query: String) -> [StickerAsset] { catalog.search(query) }

    var visibleAssets: [StickerAsset] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty { return catalog.search(query) }
        guard let selectedCategory else { return [] }
        return catalog.assets(in: selectedCategory)
    }

    var selectedPlacement: StickerPlacement? {
        placements.first { $0.id == selectedPlacementID }
    }

    func setCanvas(image: UIImage, layout: StickerLayoutSnapshot) {
        canvasImage = image
        self.layout = layout
        // A retake can change measured geometry; re-clamp and drop placements whose target vanished.
        let valid = placements.compactMap { placement -> StickerPlacement? in
            guard let region = layout.region(for: placement.target) else { return nil }
            return StickerGeometry.clamped(placement, in: region, minimumPrintedDots: minimumPrintedDots)
        }
        if valid != placements {
            placements = valid
            artwork = artwork.filter { id, _ in valid.contains { $0.id == id } }
            displayArtwork = displayArtwork.filter { id, _ in valid.contains { $0.id == id } }
            printWarnings = printWarnings.filter { id, _ in valid.contains { $0.id == id } }
        }
    }

    // MARK: Adding

    /// The region a new sticker lands on: the selected sticker's photo, else the first photo.
    private var insertionTarget: StickerTargetRegion? {
        guard let layout else { return nil }
        if let selected = selectedPlacement, let region = layout.region(for: selected.target) { return region }
        return layout.regions.first
    }

    func add(_ asset: StickerAsset) {
        guard !isClosed, layout != nil, !asset.isAnimated, asset.provenance.source != .online else { return }
        guard !isAtLimit else {
            notice = "You've used all \(limit) stickers. Delete one to add another."
            return
        }
        let catalog = self.catalog
        let store = catalogStore
        let frame = asset.representativeFrameIndex
        pendingInsertions += 1
        Task {
            let image = await Task.detached(priority: .userInitiated) { () -> CGImage? in
                guard let source = catalog.image(for: asset, frameIndex: frame, maximumPixelDimension: StickerImageLimits.printPixelDimension, store: store) else { return nil }
                return try? StickerPrintPreparation.prepare(source)
            }.value
            pendingInsertions = max(0, pendingInsertions - 1)
            guard !isClosed else { return }
            guard let image else {
                notice = "That sticker couldn't be loaded. Try another one."
                return
            }
            insert(assetID: asset.id, name: asset.name, provenance: asset.provenance, frameIndex: frame, aspectRatio: Double(asset.aspectRatio), image: image)
        }
    }

    /// Adds one Unicode emoji (from the palette or the system keyboard). Validation is immediate;
    /// glyph rendering and print preparation run off the main actor.
    @discardableResult
    func addEmoji(_ input: String) -> EmojiValidationError? {
        guard !isClosed, layout != nil, hasEmoji else { return .renderFailed }
        guard !isAtLimit else {
            notice = "You've used all \(limit) stickers. Delete one to add another."
            return nil
        }
        let glyph: String
        switch EmojiGlyphValidator.validate(input) {
        case .success(let value): glyph = value
        case .failure(let error):
            notice = error.localizedDescription
            return error
        }
        let name = (emojiCatalog?.entry(for: glyph)?.displayName ?? "Emoji")
        pendingInsertions += 1
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<EmojiStickerArtwork, EmojiValidationError> in
                do { return .success(try EmojiStickerRenderer.makeArtwork(for: glyph)) }
                catch let error as EmojiValidationError { return .failure(error) }
                catch { return .failure(.renderFailed) }
            }.value
            pendingInsertions = max(0, pendingInsertions - 1)
            guard !isClosed else { return }
            switch result {
            case .failure(let error):
                notice = error.localizedDescription
            case .success(let artwork):
                rememberEmoji(glyph)
                insert(
                    assetID: Self.emojiAssetID(for: glyph),
                    name: name,
                    provenance: .systemEmoji,
                    frameIndex: 0,
                    aspectRatio: artwork.aspectRatio,
                    image: artwork.print,
                    displayImage: artwork.display,
                    printWarning: artwork.printWarning
                )
            }
        }
        return nil
    }

    /// Stable identifier for an emoji placement, e.g. `emoji.1f44d-1f3fd`.
    nonisolated static func emojiAssetID(for glyph: String) -> String {
        "emoji." + glyph.unicodeScalars.map { String($0.value, radix: 16) }.joined(separator: "-")
    }

    static let recentEmojiLimit = 24

    private func rememberEmoji(_ glyph: String) {
        recentEmoji.removeAll { $0 == glyph }
        recentEmoji.insert(glyph, at: 0)
        if recentEmoji.count > Self.recentEmojiLimit { recentEmoji.removeLast(recentEmoji.count - Self.recentEmojiLimit) }
    }

    private func insert(
        assetID: String,
        name: String,
        provenance: StickerProvenance,
        frameIndex: Int,
        aspectRatio: Double,
        image: CGImage,
        displayImage: CGImage? = nil,
        printWarning: String? = nil
    ) {
        guard placements.count < limit, let region = insertionTarget else {
            notice = "You've used all \(limit) stickers. Delete one to add another."
            return
        }
        // Stagger repeated inserts so stickers don't stack invisibly.
        let offset = Double(placements.filter { $0.target == region.target }.count % 4) * 0.08
        let ratio = aspectRatio.isFinite && aspectRatio > 0 ? aspectRatio : Double(image.width) / Double(max(1, image.height))
        let placement = StickerGeometry.clamped(
            StickerPlacement(
                id: UUID(),
                assetID: assetID,
                assetName: name,
                provenance: provenance,
                frameIndex: frameIndex,
                target: region.target,
                centerX: 0.5 + offset,
                centerY: 0.5 + offset,
                scale: StickerPlacement.defaultScale,
                rotation: 0,
                zOrder: (placements.map(\.zOrder).max() ?? -1) + 1,
                aspectRatio: ratio
            ),
            in: region,
            minimumPrintedDots: minimumPrintedDots
        )
        recordUndo()
        artwork[placement.id] = image
        displayArtwork[placement.id] = displayImage
        printWarnings[placement.id] = printWarning
        placements.append(placement)
        selectedPlacementID = placement.id
        notice = nil
    }

    // MARK: Editing

    func select(_ id: UUID?) {
        selectedPlacementID = id.flatMap { id in placements.contains { $0.id == id } ? id : nil }
    }

    /// Live, uncommitted transform for the gesture in progress. Same math as the commit.
    func previewPlacement(_ id: UUID, translation: CGSize, magnification: CGFloat, rotation: Double, displayScale: CGFloat) -> StickerPlacement? {
        guard let placement = placements.first(where: { $0.id == id }),
              let region = layout?.region(for: placement.target) else { return nil }
        return StickerGeometry.applying(
            translation: translation,
            magnification: magnification,
            rotationDelta: rotation,
            to: placement,
            in: region,
            displayScale: displayScale,
            minimumPrintedDots: minimumPrintedDots
        )
    }

    func commitGesture(_ id: UUID, translation: CGSize, magnification: CGFloat, rotation: Double, displayScale: CGFloat) {
        guard let updated = previewPlacement(id, translation: translation, magnification: magnification, rotation: rotation, displayScale: displayScale),
              let index = placements.firstIndex(where: { $0.id == id }),
              placements[index] != updated else { return }
        recordUndo()
        placements[index] = updated
    }

    func bringToFront(_ id: UUID) {
        guard let index = placements.firstIndex(where: { $0.id == id }) else { return }
        let top = placements.map(\.zOrder).max() ?? 0
        guard placements[index].zOrder < top || placements.filter({ $0.zOrder == top }).count > 1 else { return }
        recordUndo()
        placements[index].zOrder = top + 1
    }

    func deleteSelected() {
        guard let id = selectedPlacementID else { return }
        delete(id)
    }

    func delete(_ id: UUID) {
        guard placements.contains(where: { $0.id == id }) else { return }
        recordUndo()
        placements.removeAll { $0.id == id }
        artwork[id] = nil
        displayArtwork[id] = nil
        printWarnings[id] = nil
        if selectedPlacementID == id { selectedPlacementID = nil }
    }

    func resetAll() {
        guard !placements.isEmpty else { return }
        recordUndo()
        placements.removeAll()
        artwork.removeAll()
        displayArtwork.removeAll()
        printWarnings.removeAll()
        selectedPlacementID = nil
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(snapshot)
        placements = previous.placements
        artwork = previous.artwork
        displayArtwork = previous.displayArtwork
        printWarnings = previous.printWarnings
        if !placements.contains(where: { $0.id == selectedPlacementID }) { selectedPlacementID = nil }
        updateHistoryFlags()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(snapshot)
        placements = next.placements
        artwork = next.artwork
        displayArtwork = next.displayArtwork
        printWarnings = next.printWarnings
        if !placements.contains(where: { $0.id == selectedPlacementID }) { selectedPlacementID = nil }
        updateHistoryFlags()
    }

    private func recordUndo() {
        undoStack.append(snapshot)
        if undoStack.count > Self.undoDepth { undoStack.removeFirst(undoStack.count - Self.undoDepth) }
        redoStack.removeAll()
        updateHistoryFlags()
    }

    private func updateHistoryFlags() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    func clearNotice() { notice = nil }

    // MARK: Hit testing

    /// Topmost sticker under an editor point. Small stickers get a finger-sized hit area.
    func placement(at point: CGPoint, displayScale: CGFloat) -> StickerPlacement? {
        guard let layout, displayScale > 0 else { return nil }
        let printPoint = CGPoint(x: point.x / displayScale, y: point.y / displayScale)
        let minimumHalf = 22 / displayScale
        for placement in placements.sorted(by: { $0.zOrder > $1.zOrder }) {
            guard let region = layout.region(for: placement.target),
                  let frame = try? StickerGeometry.resolve(placement, in: region) else { continue }
            let dx = printPoint.x - frame.center.x
            let dy = printPoint.y - frame.center.y
            let cosine = cos(-frame.rotation), sine = sin(-frame.rotation)
            let localX = dx * cosine - dy * sine
            let localY = dx * sine + dy * cosine
            if abs(localX) <= max(frame.size.width / 2, minimumHalf), abs(localY) <= max(frame.size.height / 2, minimumHalf) {
                return placement
            }
        }
        return nil
    }

    func warning(for placement: StickerPlacement) -> String? {
        guard let region = layout?.region(for: placement.target),
              let frame = try? StickerGeometry.resolve(placement, in: region) else { return "This sticker can't be placed here" }
        return StickerGeometry.legibilityWarning(for: frame, minimumPrintedDots: minimumPrintedDots) ?? printWarnings[placement.id]
    }

    // MARK: Freezing

    /// Validated, immutable decorations for the receipt. Invalid or artwork-less placements are
    /// dropped rather than printed wrongly.
    func freeze() -> [FrozenStickerDecoration] {
        guard let layout else { return [] }
        return placements
            .sorted { $0.zOrder < $1.zOrder }
            .enumerated()
            .compactMap { order, placement in
                guard let image = artwork[placement.id],
                      let region = layout.region(for: placement.target),
                      (try? StickerGeometry.resolve(placement, in: region)) != nil else { return nil }
                var frozen = placement
                frozen.zOrder = order
                return FrozenStickerDecoration(placement: frozen, printImage: image)
            }
    }

    // MARK: Thumbnails

    func requestThumbnail(for asset: StickerAsset) {
        guard !isClosed, thumbnails[asset.id] == nil, !failedThumbnails.contains(asset.id), thumbnailTasks[asset.id] == nil else { return }
        let catalog = self.catalog
        let store = catalogStore
        thumbnailTasks[asset.id] = Task {
            let image = await Task.detached(priority: .utility) { () -> UIImage? in
                catalog.image(for: asset, frameIndex: asset.representativeFrameIndex, maximumPixelDimension: StickerImageLimits.thumbnailPixelDimension, store: store)
                    .map { UIImage(cgImage: $0) }
            }.value
            thumbnailTasks[asset.id] = nil
            guard !isClosed else { return }
            if let image { thumbnails[asset.id] = image } else { failedThumbnails.insert(asset.id) }
        }
    }

    /// Ends this draft for good: cancels all work and releases artwork and source bytes.
    func close() {
        isClosed = true
        thumbnailTasks.values.forEach { $0.cancel() }
        thumbnailTasks.removeAll()
        placements.removeAll()
        artwork.removeAll()
        displayArtwork.removeAll()
        printWarnings.removeAll()
        recentEmoji.removeAll()
        undoStack.removeAll()
        redoStack.removeAll()
        thumbnails.removeAll()
        selectedPlacementID = nil
        canvasImage = nil
        pendingInsertions = 0
    }

    var isClosedForTesting: Bool { isClosed }
}

/// The two guest palettes. Emoji lead; the original artwork and operator imports share "Stickers".
nonisolated enum StickerPaletteSource: String, CaseIterable, Sendable {
    case emoji
    case artwork

    var title: String {
        switch self {
        case .emoji: "Emoji"
        case .artwork: "Stickers"
        }
    }
}

nonisolated struct EmojiPaletteSection: Identifiable, Hashable, Sendable {
    static let recentKey = "recent"
    let key: String
    let title: String
    let systemImage: String
    var id: String { key }
}

/// A recently used skin-tone form shown in place of its base glyph.
private struct RecentEmoji {
    let entry: EmojiEntry
    let glyph: String

    var asEntry: EmojiEntry {
        glyph == entry.glyph ? entry : EmojiEntry(glyph: glyph, name: entry.name, subgroup: entry.subgroup, emojiVersion: entry.emojiVersion, skinToneVariants: [])
    }
}
