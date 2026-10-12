//
//  StickerStudioSession.swift
//  PocketPixelsBooth
//
//  One guest's sticker draft: placements, selection, undo/redo, artwork and optional online
//  browsing. Owned by BoothSessionViewModel for exactly one customer session generation and
//  discarded with it. Nothing here uploads, archives, prints or writes to disk.
//

import CoreGraphics
import Foundation
import Observation
import UIKit

@MainActor
@Observable
final class StickerStudioSession {
    struct OnlineState: Equatable {
        var kind: OnlineStickerKind = .stickers
        var results: [OnlineStickerResult] = []
        var isLoading = false
        var message: String?
        var nextOffset: Int?
    }

    let configuration: StickerStudioSessionConfiguration
    let catalog: StickerGuestCatalog
    /// The customer session this draft belongs to. Async work checks it before mutating.
    let generation: Int
    @ObservationIgnored private let catalogStore: StickerCatalogStore?
    @ObservationIgnored private let provider: OnlineStickerProvider?

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
    private(set) var isOnlineAvailable: Bool
    private(set) var online = OnlineState()
    private(set) var canUndo = false
    private(set) var canRedo = false

    /// Print-prepared still artwork per placement — exactly what the receipt will draw.
    private(set) var artwork: [UUID: CGImage] = [:]
    /// Source bytes for animated online stickers so another still frame can be chosen offline.
    @ObservationIgnored private var animatedSources: [UUID: Data] = [:]
    @ObservationIgnored private var undoStack: [[StickerPlacement]] = []
    @ObservationIgnored private var redoStack: [[StickerPlacement]] = []
    @ObservationIgnored private var onlineTask: Task<Void, Never>?
    @ObservationIgnored private var onlineDownloadTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var thumbnailTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private let downloadLimiter = AsyncLimiter(limit: StickerImageLimits.maximumConcurrentDownloads)
    @ObservationIgnored private var onlineResultsByID: [String: OnlineStickerResult] = [:]
    @ObservationIgnored private var isClosed = false

    static let undoDepth = 30

    init(
        configuration: StickerStudioSessionConfiguration,
        catalog: StickerGuestCatalog,
        generation: Int,
        catalogStore: StickerCatalogStore?,
        provider: OnlineStickerProvider?
    ) {
        self.configuration = configuration
        self.catalog = catalog
        self.generation = generation
        self.catalogStore = catalogStore
        self.provider = configuration.onlineReady ? provider : nil
        self.isOnlineAvailable = configuration.onlineReady && provider != nil
        self.selectedCategory = catalog.categories.first ?? (configuration.onlineReady && provider != nil ? .online : nil)
    }

    var limit: Int { configuration.settings.guestStickerLimit }
    var minimumPrintedDots: Int { configuration.settings.minimumPrintedStickerDots }
    var isAtLimit: Bool { placements.count + pendingInsertions >= limit }
    var hasContent: Bool { !catalog.assets.isEmpty || isOnlineAvailable }
    var attributionText: String? { provider?.attributionText }

    /// Tabs in order; Trending only appears when online use is licensed and configured.
    var categories: [StickerCategory] {
        catalog.categories + (isOnlineAvailable ? [.online] : [])
    }

    var visibleAssets: [StickerAsset] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty, selectedCategory != .online { return catalog.search(query) }
        guard let selectedCategory, selectedCategory != .online else { return [] }
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
        guard !isClosed, layout != nil else { return }
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
            pendingInsertions -= 1
            guard !isClosed else { return }
            guard let image else {
                notice = "That sticker couldn't be loaded. Try another one."
                return
            }
            insert(assetID: asset.id, name: asset.name, provenance: asset.provenance, frameIndex: frame, aspectRatio: Double(asset.aspectRatio), image: image)
        }
    }

    private func insert(assetID: String, name: String, provenance: StickerProvenance, frameIndex: Int, aspectRatio: Double, image: CGImage, animatedSource: Data? = nil) {
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
        if let animatedSource { animatedSources[placement.id] = animatedSource }
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
        if selectedPlacementID == id { selectedPlacementID = nil }
    }

    func resetAll() {
        guard !placements.isEmpty else { return }
        recordUndo()
        placements.removeAll()
        selectedPlacementID = nil
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(placements)
        placements = previous
        if !placements.contains(where: { $0.id == selectedPlacementID }) { selectedPlacementID = nil }
        updateHistoryFlags()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(placements)
        placements = next
        if !placements.contains(where: { $0.id == selectedPlacementID }) { selectedPlacementID = nil }
        updateHistoryFlags()
    }

    private func recordUndo() {
        undoStack.append(placements)
        if undoStack.count > Self.undoDepth { undoStack.removeFirst(undoStack.count - Self.undoDepth) }
        redoStack.removeAll()
        updateHistoryFlags()
    }

    private func updateHistoryFlags() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    func clearNotice() { notice = nil }

    /// Animated stickers: frame count of the selected sticker's source, if it has several.
    func frameCount(for id: UUID) -> Int {
        guard let placement = placements.first(where: { $0.id == id }) else { return 1 }
        if let asset = catalog.asset(id: placement.assetID) { return asset.frameCount }
        if let data = animatedSources[id], let info = try? StickerImageDecoder.inspect(data, maximumBytes: StickerImageLimits.maximumRemoteBytes) {
            return info.frameCount
        }
        return 1
    }

    /// Steps the printed still frame of an animated sticker (deterministic, no network).
    func chooseNextFrame(for id: UUID) {
        guard let index = placements.firstIndex(where: { $0.id == id }) else { return }
        let count = frameCount(for: id)
        guard count > 1 else { return }
        let next = (placements[index].frameIndex + 1) % count
        let placement = placements[index]
        let source: Data?
        if let data = animatedSources[id] {
            source = data
        } else if let record = catalog.customRecords[placement.assetID] {
            source = catalogStore?.data(for: record)
        } else {
            source = nil
        }
        guard let source else { return }
        Task {
            let image = await Task.detached(priority: .userInitiated) { () -> CGImage? in
                guard let frame = try? StickerImageDecoder.decodeFrame(source, frameIndex: next, maximumPixelDimension: StickerImageLimits.printPixelDimension, maximumBytes: StickerImageLimits.maximumRemoteBytes) else { return nil }
                return try? StickerPrintPreparation.prepare(frame)
            }.value
            guard !isClosed, let image, let current = placements.firstIndex(where: { $0.id == id }) else { return }
            recordUndo()
            artwork[id] = image
            placements[current].frameIndex = next
        }
    }

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

    // MARK: Online

    func setOnlineKind(_ kind: OnlineStickerKind) {
        guard online.kind != kind else { return }
        online.kind = kind
        refreshOnline(debounce: false)
    }

    /// Debounced trending / search request. Previous requests are cancelled.
    func refreshOnline(debounce: Bool = true, appending: Bool = false) {
        guard isOnlineAvailable, let provider, !isClosed else { return }
        onlineTask?.cancel()
        let query = searchQuery
        let kind = online.kind
        let offset = appending ? (online.nextOffset ?? 0) : 0
        if appending, online.nextOffset == nil { return }
        online.isLoading = true
        online.message = nil
        onlineTask = Task {
            if debounce { try? await Task.sleep(for: .milliseconds(400)) }
            guard !Task.isCancelled, !isClosed, isOnlineAvailable else { return }
            do {
                let page = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? try await provider.trending(kind: kind, offset: offset, limit: GiphyStickerProvider.maximumPageSize)
                    : try await provider.search(query: query, kind: kind, offset: offset, limit: GiphyStickerProvider.maximumPageSize)
                guard !Task.isCancelled, !isClosed, isOnlineAvailable else { return }
                online.results = appending ? online.results + page.results : page.results
                online.nextOffset = page.nextOffset
                for result in page.results { onlineResultsByID[result.id] = result }
                online.isLoading = false
                online.message = online.results.isEmpty ? "Nothing found. Try another word." : nil
            } catch {
                guard !Task.isCancelled, !isClosed else { return }
                online.isLoading = false
                online.message = "Online stickers are unavailable right now. The other tabs still work."
            }
        }
    }

    func requestOnlineThumbnail(for result: OnlineStickerResult) {
        let key = "online.\(result.id)"
        guard isOnlineAvailable, let provider, !isClosed, thumbnails[key] == nil, !failedThumbnails.contains(key), thumbnailTasks[key] == nil else { return }
        let limiter = downloadLimiter
        thumbnailTasks[key] = Task {
            let image: UIImage? = await limiter.run {
                guard !Task.isCancelled, let data = try? await provider.downloadMedia(result.previewURL) else { return nil }
                return await Task.detached(priority: .utility) { () -> UIImage? in
                    guard let info = try? StickerImageDecoder.inspect(data, maximumBytes: StickerImageLimits.maximumRemoteBytes),
                          let frame = try? StickerImageDecoder.decodeFrame(data, frameIndex: info.frameCount > 1 ? info.frameCount / 2 : 0, maximumPixelDimension: StickerImageLimits.thumbnailPixelDimension, maximumBytes: StickerImageLimits.maximumRemoteBytes) else { return nil }
                    return UIImage(cgImage: frame)
                }.value
            }
            thumbnailTasks[key] = nil
            guard !isClosed, isOnlineAvailable else { return }
            if let image { thumbnails[key] = image } else { failedThumbnails.insert(key) }
        }
    }

    /// Downloads the selected item once, into memory, and places its representative still frame.
    func addOnline(_ result: OnlineStickerResult) {
        guard isOnlineAvailable, let provider, !isClosed, layout != nil else { return }
        guard !isAtLimit else {
            notice = "You've used all \(limit) stickers. Delete one to add another."
            return
        }
        let token = UUID()
        let limiter = downloadLimiter
        pendingInsertions += 1
        onlineDownloadTasks[token] = Task {
            let decoded: (CGImage, Int, Data?)? = await limiter.run {
                guard !Task.isCancelled, let data = try? await provider.downloadMedia(result.mediaURL) else { return nil }
                return await Task.detached(priority: .userInitiated) { () -> (CGImage, Int, Data?)? in
                    guard let info = try? StickerImageDecoder.inspect(data, maximumBytes: StickerImageLimits.maximumRemoteBytes) else { return nil }
                    let frameIndex = info.frameCount > 1 ? info.frameCount / 2 : 0
                    guard let frame = try? StickerImageDecoder.decodeFrame(data, frameIndex: frameIndex, maximumPixelDimension: StickerImageLimits.printPixelDimension, maximumBytes: StickerImageLimits.maximumRemoteBytes),
                          let prepared = try? StickerPrintPreparation.prepare(frame) else { return nil }
                    return (prepared, frameIndex, info.isAnimated ? data : nil)
                }.value
            }
            onlineDownloadTasks[token] = nil
            pendingInsertions = max(0, pendingInsertions - 1)
            // Never let a late download land after online use was switched off or the guest left.
            guard !Task.isCancelled, !isClosed, isOnlineAvailable else { return }
            guard let decoded else {
                notice = "That online sticker couldn't be loaded. Try another one."
                return
            }
            insert(
                assetID: "giphy.\(result.id)",
                name: result.title,
                provenance: StickerProvenance(
                    source: .online,
                    provider: provider.providerName,
                    providerContentID: result.id,
                    creatorAttribution: result.creatorDisplayName,
                    rightsBasis: "Operator-confirmed commercial print licence"
                ),
                frameIndex: decoded.1,
                aspectRatio: result.aspectRatio,
                image: decoded.0,
                animatedSource: decoded.2
            )
        }
    }

    /// Operator switched online use off mid-session: stop every request now, hide the tab and
    /// remove online stickers from this unfinalized draft.
    func disableOnline() {
        guard isOnlineAvailable else { return }
        isOnlineAvailable = false
        cancelOnlineWork()
        online = OnlineState()
        let removed = placements.filter { $0.provenance.source == .online }
        if !removed.isEmpty {
            placements.removeAll { $0.provenance.source == .online }
            for placement in removed {
                artwork[placement.id] = nil
                animatedSources[placement.id] = nil
            }
            undoStack.removeAll()
            redoStack.removeAll()
            updateHistoryFlags()
            notice = "Online stickers are no longer available."
        }
        if selectedCategory == .online { selectedCategory = catalog.categories.first }
        if !placements.contains(where: { $0.id == selectedPlacementID }) { selectedPlacementID = nil }
    }

    private func cancelOnlineWork() {
        onlineTask?.cancel()
        onlineTask = nil
        onlineDownloadTasks.values.forEach { $0.cancel() }
        onlineDownloadTasks.removeAll()
        for (key, task) in thumbnailTasks where key.hasPrefix("online.") {
            task.cancel()
            thumbnailTasks[key] = nil
        }
        thumbnails = thumbnails.filter { !$0.key.hasPrefix("online.") }
        onlineResultsByID.removeAll()
    }

    /// Ends this draft for good: cancels all work and releases artwork and source bytes.
    func close() {
        isClosed = true
        cancelOnlineWork()
        thumbnailTasks.values.forEach { $0.cancel() }
        thumbnailTasks.removeAll()
        placements.removeAll()
        artwork.removeAll()
        animatedSources.removeAll()
        undoStack.removeAll()
        redoStack.removeAll()
        thumbnails.removeAll()
        selectedPlacementID = nil
        canvasImage = nil
    }

    var isClosedForTesting: Bool { isClosed }
    var activeOnlineTaskCount: Int { onlineDownloadTasks.count + (onlineTask == nil ? 0 : 1) }
}

/// Caps concurrent downloads; extra requests wait their turn.
actor AsyncLimiter {
    private let limit: Int
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.limit = max(1, limit) }

    func run<T: Sendable>(_ operation: @Sendable () async -> T) async -> T {
        await acquire()
        let result = await operation()
        release()
        return result
    }

    private func acquire() async {
        if active < limit {
            active += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            active -= 1
        } else {
            waiters.removeFirst().resume()
        }
    }

    var activeCount: Int { active }
}
