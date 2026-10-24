import Foundation
import SwiftUI
import ImageIO
import UIKit

/// Disposable presentation cache. Archive bytes remain the source of truth.
actor SessionThumbnailCache {
    struct Statistics: Sendable {
        let count: Int
        let bytes: Int
        let hits: Int
        let misses: Int
    }
    private struct Entry { let image: UIImage; let cost: Int; var used: UInt64 }
    private var entries: [String: Entry] = [:]
    private var tick: UInt64 = 0
    private var bytes = 0
    private var hits = 0
    private var misses = 0
    private var generation: UInt64 = 0
    let byteLimit: Int
    let countLimit: Int

    init(byteLimit: Int = 12 * 1024 * 1024, countLimit: Int = 96) {
        self.byteLimit = max(0, byteLimit); self.countLimit = max(0, countLimit)
    }

    func image(archiveID: String, filename: String, store: RecentSessionArchiveStore) async -> UIImage? {
        guard !Task.isCancelled else { return nil }
        let key = archiveID + "/" + filename
        tick &+= 1
        if var cached = entries[key] {
            hits += 1; cached.used = tick; entries[key] = cached; return cached.image
        }
        misses += 1
        let requestedGeneration = generation
        // ImageIO downsamples without first retaining a full-resolution decoded image.
        let worker = Task.detached(priority: .utility) { () -> UIImage? in
            guard !Task.isCancelled, let data = store.thumbnailData(archiveID: archiveID, filename: filename),
                  let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                  !Task.isCancelled else { return nil }
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 256,
                kCGImageSourceShouldCacheImmediately: true]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary), !Task.isCancelled else { return nil }
            return UIImage(cgImage: cg)
        }
        let image = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
        guard !Task.isCancelled, generation == requestedGeneration, let image, let cg = image.cgImage else { return nil }
        let cost = cg.bytesPerRow * cg.height
        guard cost <= byteLimit, countLimit > 0 else { return image }
        // Another visible consumer may have finished this same immutable archive meanwhile.
        if let existing = entries.removeValue(forKey: key) { bytes -= existing.cost }
        while !entries.isEmpty && (bytes + cost > byteLimit || entries.count >= countLimit) {
            guard let oldest = entries.min(by: { $0.value.used < $1.value.used })?.key,
                  let removed = entries.removeValue(forKey: oldest) else { break }
            bytes -= removed.cost
        }
        tick &+= 1; entries[key] = Entry(image: image, cost: cost, used: tick); bytes += cost
        return image
    }
    func removeAll() { generation &+= 1; entries.removeAll(); bytes = 0 }
    func statistics() -> Statistics { Statistics(count: entries.count, bytes: bytes, hits: hits, misses: misses) }
}

/// Image completion invalidates only this visible preview, never the entire session list.
struct SessionThumbnailView: View {
    let summary: RecentSessionArchiveSummary
    let model: RecentSessionsViewModel
    @State private var image: UIImage?
    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFill() }
            else { Rectangle().fill(OperatorPalette.selected).overlay { Image(systemName: "photo").foregroundStyle(OperatorPalette.secondaryText) } }
        }
        .clipped().accessibilityHidden(true)
        .task(id: summary.archiveID) {
            let loaded = await model.thumbnail(for: summary)
            guard !Task.isCancelled else { return }
            image = loaded
        }
        .onDisappear { image = nil }
    }
}
