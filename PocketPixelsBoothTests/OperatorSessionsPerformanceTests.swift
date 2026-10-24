import XCTest
import Darwin
import SwiftUI
@testable import PocketPixelsBooth

/// All archives are synthetic and isolated under a fresh temporary directory.
@MainActor final class OperatorSessionsPerformanceTests: XCTestCase {
    func testArchiveBrowserScaling() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("v4-benchmark-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try RecentSessionArchiveStore(directoryURL: root)
        let token = String(repeating: "a", count: 64)
        let url = try GalleryURLBuilder.makeGalleryURL(customerGalleryBaseURL: URL(string: "https://photos.madetokeep.studio")!, galleryToken: token)
        let photos = StickerFixtures.photos(for: .grid)
        let session = CommittedGallerySession(sessionIdentifier: "benchmark-original", createdAt: Date(), galleryToken: token, galleryURL: url, photos: photos, format: .grid, eventProfile: nil)
        let receipt = try ReceiptComposer.compose(photos: photos, sessionIdentifier: session.sessionIdentifier, date: session.createdAt, galleryURL: url, format: .grid)
        let raster = try ThermalImageRasterizer.rasterize(XCTUnwrap(UIImage(data: receipt.imagePNGData)), purpose: .completeReceipt)
        try store.save(.init(committedSession: session, composedReceipt: receipt, receiptPreviewPNGData: receipt.imagePNGData, thermalPreviewPNGData: raster.previewPNGData, rasterizedImage: raster, photoThumbnailData: photos.compactMap { $0.preparingThumbnail(of: CGSize(width: 240, height: 320))?.jpegData(compressionQuality: 0.8) }))
        let original = root.appendingPathComponent(token)
        var results: [[String: Any]] = []
        var previous = 1
        for count in [50, 250, 500, 1000] {
            for i in previous..<count {
                let id = String(format: "%064x", i)
                let target = root.appendingPathComponent(id)
                try FileManager.default.copyItem(at: original, to: target)
                let metadataURL = target.appendingPathComponent("metadata.json")
                var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: metadataURL)) as? [String: Any])
                json["archiveID"] = id; json["sessionIdentifier"] = "benchmark-\(i)"
                try JSONSerialization.data(withJSONObject: json).write(to: metadataURL)
            }
            previous = count
            let model = RecentSessionsViewModel(store: store)
            let start = CFAbsoluteTimeGetCurrent()
            model.refresh()
            let deadline = Date().addingTimeInterval(90)
            while !model.hasLoaded && Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
            let loadMS = (CFAbsoluteTimeGetCurrent() - start) * 1000
            XCTAssertEqual(model.summaries.count, count)
            let firstStart = CFAbsoluteTimeGetCurrent()
            let first = try XCTUnwrap(model.summaries.first)
            let image = await model.thumbnail(for: first)
            XCTAssertNotNil(image)
            let firstMS = (CFAbsoluteTimeGetCurrent() - firstStart) * 1000
            for summary in model.summaries.prefix(140) { _ = await model.thumbnail(for: summary) }
            let cached = await model.thumbnails.statistics()
            XCTAssertLessThanOrEqual(cached.count, 96)
            XCTAssertLessThanOrEqual(cached.bytes, 12 * 1024 * 1024)
            _ = await model.thumbnail(for: model.summaries[139 < count ? 139 : count - 1])
            let hit = await model.thumbnails.statistics()
            XCTAssertGreaterThan(hit.hits, cached.hits)
            let filterStart = CFAbsoluteTimeGetCurrent()
            for i in 0..<30 { model.searchText = "benchmark-\(i)"; _ = model.groupedSummaries }
            let filterMS = (CFAbsoluteTimeGetCurrent() - filterStart) * 1000 / 30
            let row: [String: Any] = ["sessions": count, "loadMilliseconds": loadMS, "filterMilliseconds": filterMS, "firstThumbnailMillisecondsAfterMetadata": firstMS,
                "cacheEntries": cached.count, "cacheDecodedBytes": cached.bytes, "processFootprintBytesAfterCacheWarmup": processFootprint()]
            results.append(row)
            if count == 1000 {
                model.searchText = ""
                try await renderEvidence(model: model, store: store, originalID: token)
            }
            print("V4_BENCHMARK \(row)")
        }
        let data = try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: "/tmp/pp-v4-benchmark.json"))
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json"); attachment.name = "archive-scaling"; attachment.lifetime = .keepAlways; add(attachment)
    }
    private func processFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    private func capture<V: View>(_ view: V, name: String, size: CGSize) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let image = try await ScreenshotHarness.render(view, size: size, scene: scene)
        add(ScreenshotHarness.attachment(image, name: name))
        try image.pngData()?.write(to: URL(fileURLWithPath: "/tmp/v4-" + name + ".png"))
    }

    private func renderEvidence(model: RecentSessionsViewModel, store: RecentSessionArchiveStore, originalID: String) async throws {
        let portrait = CGSize(width: 834, height: 1194)
        try await capture(NavigationStack { RecentSessionsView(viewModel: model) }, name: "sessions-list-portrait", size: portrait)
        model.usesPhotoGrid = true
        try await capture(NavigationStack { RecentSessionsView(viewModel: model) }, name: "sessions-grid-portrait", size: portrait)
        model.usesPhotoGrid = false
        model.selectedArchiveID = originalID
        try await capture(NavigationStack { RecentSessionsView(viewModel: model) }, name: "session-detail-portrait", size: portrait)
        try await captureOriginalGallery(model: model, originalID: originalID)
        try await capture(NavigationStack { RecentSessionsView(viewModel: model) }, name: "sessions-split-landscape", size: CGSize(width: 1194, height: 834))
        model.selectedArchiveID = nil
        let preserved = try model.loadArchive(originalID)
        let cacheBefore = await model.thumbnails.statistics()
        model.markReprinted(originalID, copies: 1)
        XCTAssertEqual(model.summaries.first { $0.archiveID == originalID }?.reprintCount, 1)
        XCTAssertEqual(try model.loadArchive(originalID).rasterizedImage.rasterCommand, preserved.rasterizedImage.rasterCommand)
        XCTAssertEqual(try model.loadArchive(originalID).galleryURL, preserved.galleryURL)
        let cacheAfter = await model.thumbnails.statistics()
        XCTAssertEqual(cacheAfter.bytes, cacheBefore.bytes, "One metadata update must not evict or rebuild the browser images")
        try await capture(NavigationStack { RecentSessionsView(viewModel: model) }.environment(\.dynamicTypeSize, .accessibility3), name: "sessions-accessibility", size: CGSize(width: 700, height: 1024))
        let loading = RecentSessionsViewModel(store: store, summaryLoader: { Thread.sleep(forTimeInterval: 2); return [] })
        try await capture(NavigationStack { RecentSessionsView(viewModel: loading) }, name: "sessions-loading", size: portrait)
        let emptyStore = try RecentSessionArchiveStore(directoryURL: URL(fileURLWithPath: store.storagePath).appendingPathComponent("empty"))
        let empty = RecentSessionsViewModel(store: emptyStore)
        try await capture(NavigationStack { RecentSessionsView(viewModel: empty) }, name: "sessions-empty", size: portrait)
        let bad = RecentSessionsViewModel(store: store, summaryLoader: { throw CocoaError(.fileReadCorruptFile) })
        try await capture(NavigationStack { RecentSessionsView(viewModel: bad) }, name: "sessions-storage-error", size: portrait)
        try await measureScrolling(model: model)
    }

    private func captureOriginalGallery(model: RecentSessionsViewModel, originalID: String) async throws {
        let summary = try XCTUnwrap(model.summaries.first { $0.archiveID == originalID })
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene); window.frame = CGRect(x: 0, y: 0, width: 834, height: 1194)
        let host = UIHostingController(rootView: NavigationStack { ArchivedSessionDetailView(summary: summary, rootViewModel: model) })
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        try await Task.sleep(for: .milliseconds(700)); host.view.layoutIfNeeded()
        func find(_ view: UIView) -> UIScrollView? {
            if let scroll = view as? UIScrollView, scroll.contentSize.height > scroll.bounds.height { return scroll }
            return view.subviews.lazy.compactMap(find).first
        }
        let scroll = try XCTUnwrap(find(host.view))
        scroll.setContentOffset(CGPoint(x: 0, y: min(1450, max(0, scroll.contentSize.height - scroll.bounds.height))), animated: false)
        try await Task.sleep(for: .milliseconds(150))
        let image = UIGraphicsImageRenderer(size: window.bounds.size).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        add(ScreenshotHarness.attachment(image, name: "original-gallery-portrait"))
        try image.pngData()?.write(to: URL(fileURLWithPath: "/tmp/v4-original-gallery-portrait.png"))
    }

    private func measureScrolling(model: RecentSessionsViewModel) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene); window.frame = CGRect(x: 0, y: 0, width: 834, height: 1194)
        let host = UIHostingController(rootView: RecentSessionsView(viewModel: model))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        try await Task.sleep(for: .milliseconds(300))
        host.view.layoutIfNeeded()
        func findScroll(_ view: UIView) -> UIScrollView? {
            if let scroll = view as? UIScrollView, scroll.contentSize.height > scroll.bounds.height { return scroll }
            return view.subviews.lazy.compactMap(findScroll).first
        }
        let scroll = try XCTUnwrap(findScroll(host.view))
        XCTAssertLessThanOrEqual(scroll.contentSize.width, scroll.bounds.width + 1)
        let probe = SessionScrollProbe(scroll: scroll)
        probe.start()
        try await Task.sleep(for: .seconds(4))
        probe.stop()
        XCTAssertGreaterThan(scroll.contentOffset.y, 500, "The real scroll view must move during the callback sample")
        let sorted = probe.intervals.sorted()
        XCTAssertGreaterThan(sorted.count, 30)
        let result: [String: Any] = ["samples": sorted.count, "durationSeconds": 4, "maximumCallbackGapMS": (sorted.last ?? 0) * 1000,
            "p95CallbackGapMS": sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))] * 1000,
            "callbackGapsOver34MS": sorted.filter { $0 > 0.034 }.count,
            "note": "Simulator CADisplayLink callbacks during programmatic scroll; not physical-device FPS or Instruments hitch measurement"]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: "/tmp/pp-v4-scroll.json"))
        let before = CFAbsoluteTimeGetCurrent()
        model.selectedArchiveID = model.summaries.first?.archiveID
        try await Task.sleep(for: .milliseconds(100))
        let selected = model.selectedArchiveID
        window.frame.size = CGSize(width: 1194, height: 834); host.view.frame = window.bounds; host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(model.selectedArchiveID, selected)
        window.frame.size = CGSize(width: 834, height: 1194); host.view.frame = window.bounds; host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(model.selectedArchiveID, selected)
        model.selectedArchiveID = nil
        XCTAssertEqual(model.searchText, "")
        XCTAssertEqual(model.summaries.count, 1000)
        XCTAssertFalse(model.usesPhotoGrid)
        print("V4_RETURN_AND_ROTATE_MS \((CFAbsoluteTimeGetCurrent() - before) * 1000)")
    }

}

@MainActor private final class SessionScrollProbe: NSObject {
    weak var scroll: UIScrollView?
    private var link: CADisplayLink?
    private var last: CFTimeInterval?
    var intervals: [CFTimeInterval] = []
    init(scroll: UIScrollView) { self.scroll = scroll }
    func start() { let link = CADisplayLink(target: self, selector: #selector(tick)); self.link = link; link.add(to: .main, forMode: .common) }
    func stop() { link?.invalidate(); link = nil }
    @objc private func tick() {
        let now = CACurrentMediaTime()
        if let last { intervals.append(now - last) }; last = now
        guard let scroll else { return }
        let maximum = max(0, scroll.contentSize.height - scroll.bounds.height)
        scroll.setContentOffset(CGPoint(x: 0, y: min(maximum, scroll.contentOffset.y + 24)), animated: false)
    }
}
