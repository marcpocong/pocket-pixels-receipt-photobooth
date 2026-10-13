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
    private struct EditSnapshot {
        let placements: [StickerPlacement]
        let artwork: [UUID: CGImage]
    }
    private var snapshot: EditSnapshot {
        EditSnapshot(placements: placements, artwork: artwork.filter { id, _ in placements.contains { $0.id == id } })
    }
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
        provider: OnlineStickerProvider? = nil
    ) {
        self.configuration = configuration
        self.catalog = catalog
        self.generation = generation
        self.catalogStore = catalogStore
        self.selectedCategory = catalog.categories.first
    }

    var limit: Int { configuration.settings.guestStickerLimit }
    var minimumPrintedDots: Int { configuration.settings.minimumPrintedStickerDots }
    var isAtLimit: Bool { placements.count + pendingInsertions >= limit }
    var hasContent: Bool { !catalog.assets.isEmpty }

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

    private func insert(assetID: String, name: String, provenance: StickerProvenance, frameIndex: Int, aspectRatio: Double, image: CGImage) {
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
        if selectedPlacementID == id { selectedPlacementID = nil }
    }

    func resetAll() {
        guard !placements.isEmpty else { return }
        recordUndo()
        placements.removeAll()
        artwork.removeAll()
        selectedPlacementID = nil
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(snapshot)
        placements = previous.placements
        artwork = previous.artwork
        if !placements.contains(where: { $0.id == selectedPlacementID }) { selectedPlacementID = nil }
        updateHistoryFlags()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(snapshot)
        placements = next.placements
        artwork = next.artwork
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
        return StickerGeometry.legibilityWarning(for: frame, minimumPrintedDots: minimumPrintedDots)
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
        undoStack.removeAll()
        redoStack.removeAll()
        thumbnails.removeAll()
        selectedPlacementID = nil
        canvasImage = nil
        pendingInsertions = 0
    }

    var isClosedForTesting: Bool { isClosed }
}
