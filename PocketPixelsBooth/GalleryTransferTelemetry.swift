import Combine
import Foundation
import OSLog

/// Aggregate numeric transport evidence only. No gallery identity or URL is published.
@MainActor final class GalleryTransferTelemetry: ObservableObject {
    static let shared = GalleryTransferTelemetry()
    nonisolated struct Sample: Sendable {
        var sent: Int64 = 0
        var expected: Int64 = 0
        var phase = "Connecting"
        var began = ProcessInfo.processInfo.systemUptime
        var lastProgress = ProcessInfo.processInfo.systemUptime
        var waitingSeconds: Double = 0
        var hasBodyProgress = false
    }
    @Published private(set) var activeTransfers = 0
    @Published private(set) var bytesSent: Int64 = 0
    @Published private(set) var bytesPerSecond: Double = 0
    @Published private(set) var recentBytesPerSecond: Double = 0
    var constrainedPath = false
    private var lastRateAt: Date?
    private var hasRecentRate: Bool { lastRateAt.map { Date().timeIntervalSince($0) < 60 } == true }
    var recommendedAssetConcurrency: Int { !constrainedPath && hasRecentRate && recentBytesPerSecond >= 256 * 1024 ? 2 : 1 }
    var prefersSingleRequest: Bool {
        !constrainedPath && hasRecentRate && recentBytesPerSecond >= 256 * 1024
    }
    @Published private(set) var phase = "Waiting for saved galleries"
    @Published private(set) var lastProgressAt: Date?
    @Published private(set) var completedGalleries = 0
    private var samples: [UUID: Sample] = [:]
    private var completedBytes: Int64 = 0

    func recordCompletedGallery() { completedGalleries += 1 }
    func resetPathEstimate() { recentBytesPerSecond = 0; lastRateAt = nil }

    func update(_ id: UUID, sample: Sample, finished: Bool = false, succeeded: Bool = true) {
        if finished {
            samples[id] = nil; completedBytes += sample.sent
            if sample.sent >= 64 * 1024 {
                // Include acknowledgment latency. Bytes handed to a kernel/TLS
                // buffer are not proof of actual available upstream bandwidth.
                let rate = Double(sample.sent) / max(0.01, ProcessInfo.processInfo.systemUptime-sample.began-sample.waitingSeconds)
                lastRateAt = Date()
                recentBytesPerSecond = recentBytesPerSecond == 0 || rate < recentBytesPerSecond
                    ? rate : recentBytesPerSecond * 0.5 + rate * 0.5
            }
            if !succeeded { resetPathEstimate() }
        }
        else { samples[id] = sample }
        activeTransfers = samples.count
        bytesSent = completedBytes + samples.values.reduce(0) { $0 + $1.sent }
        bytesPerSecond = samples.values.reduce(0) { $0 + Double($1.sent) / max(0.1, ProcessInfo.processInfo.systemUptime - $1.began - $1.waitingSeconds) }
        phase = samples.values.first?.phase ?? "No active byte transfer"
        if sample.sent > 0 { lastProgressAt = Date() }
    }
}

/// URLSession's byte callbacks measure actual transport, not prepared payload size.
/// A stalled partial transfer can be cancelled safely: the next pass queries Drive's
/// confirmed offset first. Slow transfers that continue progressing are left alone.
nonisolated final class GalleryTransferObserver: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var sample = GalleryTransferTelemetry.Sample()
    private let id = UUID()
    private weak var task: URLSessionTask?
    private var watchdog: Task<Void, Never>?
    private var waitingSince: TimeInterval?
    private var stopped = false
    private static let logger = Logger(subsystem: "com.pocketpixels.PocketPixelsBooth", category: "GalleryTransfer")

    nonisolated func start(_ task: URLSessionTask, expected: Int64) {
        lock.lock(); self.task = task; sample.expected = expected; lock.unlock()
        publish()
        watchdog = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                self?.checkStall()
            }
        }
    }

    nonisolated private func checkStall() {
        lock.lock()
        let sent = max(sample.sent, task?.countOfBytesSent ?? 0)
        let waitingTooLong = waitingSince.map { ProcessInfo.processInfo.systemUptime-$0 > 30 } ?? false
        let shouldCancel = !stopped && ((sent < sample.expected &&
            ProcessInfo.processInfo.systemUptime - sample.lastProgress > 45) || waitingTooLong)
        let task = self.task
        lock.unlock()
        if shouldCancel { task?.cancel() }
    }

    nonisolated func finish(succeeded: Bool = true) {
        lock.lock(); stopped = true; sample.sent = max(sample.sent, task?.countOfBytesSent ?? 0); let final = sample; lock.unlock()
        watchdog?.cancel(); watchdog = nil
        let responseWait = final.hasBodyProgress && final.sent >= final.expected ? ProcessInfo.processInfo.systemUptime-final.lastProgress : 0
        Self.logger.info("transferBytes=\(final.sent) expectedBytes=\(final.expected) elapsedMs=\(Int((ProcessInfo.processInfo.systemUptime-final.began)*1000)) connectivityWaitMs=\(Int(final.waitingSeconds*1000)) awaitingResponseMs=\(Int(responseWait*1000)) noProgressMs=\(Int((ProcessInfo.processInfo.systemUptime-final.lastProgress)*1000))")
        Task { @MainActor in GalleryTransferTelemetry.shared.update(id, sample: final, finished: true, succeeded: succeeded) }
    }

    nonisolated private func publish() {
        lock.lock(); let current = sample; lock.unlock()
        Task { @MainActor in GalleryTransferTelemetry.shared.update(id, sample: current) }
    }

    nonisolated func urlSession(_ session: URLSession, taskIsWaitingForConnectivity task: URLSessionTask) {
        lock.lock(); sample.phase = "Waiting for connectivity"; waitingSince = ProcessInfo.processInfo.systemUptime; lock.unlock()
        publish()
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                               totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        lock.lock()
        if let since = waitingSince { sample.waitingSeconds += ProcessInfo.processInfo.systemUptime-since; waitingSince = nil }
        sample.sent = totalBytesSent; sample.expected = totalBytesExpectedToSend
        sample.hasBodyProgress = true
        sample.lastProgress = ProcessInfo.processInfo.systemUptime
        let rate = Double(totalBytesSent)/max(0.1,sample.lastProgress-sample.began-sample.waitingSeconds)
        sample.phase = totalBytesSent >= totalBytesExpectedToSend ? "Awaiting server response" : rate < 128 * 1024 ? "Slow but progressing" : "Transferring"
        lock.unlock(); publish()
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        let connecting = metrics.transactionMetrics.reduce(0.0) { value, item in
            value + (item.connectEndDate?.timeIntervalSince(item.connectStartDate ?? item.connectEndDate ?? Date()) ?? 0)
        }
        Self.logger.info("connectionMs=\(Int(connecting*1000)) redirectCount=\(metrics.redirectCount)")
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                               newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, url.scheme == "https", let host = url.host()?.lowercased(),
              GoogleGalleryURLSessionDelegate.isAllowedGoogleRedirectHost(host) else { completionHandler(nil); return }
        completionHandler(request)
    }

    nonisolated static func upload(session: URLSession, request: URLRequest, file: URL) async throws -> (Data, URLResponse) {
        let observer = GalleryTransferObserver()
        let size = (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return try await withCheckedThrowingContinuation { continuation in
            let task = session.uploadTask(with: request, fromFile: file) { data, response, error in
                observer.finish(succeeded: error == nil)
                if let error { continuation.resume(throwing: error) }
                else if let response { continuation.resume(returning: (data ?? Data(), response)) }
                else { continuation.resume(throwing: GalleryUploadError.deliveryUnknown) }
            }
            task.delegate = observer
            observer.start(task, expected: Int64(size))
            task.resume()
        }
    }

    nonisolated static func post(session: URLSession, request: URLRequest, expectedBytes: Int) async throws -> (Data, URLResponse) {
        let observer = GalleryTransferObserver()
        return try await withCheckedThrowingContinuation { continuation in
            let task = session.dataTask(with: request) { data, response, error in
                observer.finish(succeeded: error == nil)
                if let error { continuation.resume(throwing: error) }
                else if let response { continuation.resume(returning: (data ?? Data(), response)) }
                else { continuation.resume(throwing: GalleryUploadError.deliveryUnknown) }
            }
            task.delegate = observer
            observer.start(task, expected: Int64(expectedBytes))
            task.resume()
        }
    }
}
