import Combine
import Foundation
import OSLog

/// One process-wide owner of delivery work. Requests join by durable gallery identity.
/// Two fresh guests may pass recovery work; the next slot belongs to the oldest recovery.
/// An acquired operation is never cancelled/preempted by a retry or a path transition.
@MainActor
final class GalleryUploadScheduler: ObservableObject {
    static let shared = GalleryUploadScheduler()
    enum Priority { case guest, recovery }
    enum Lane { case transmission, publicRead }
    enum Phase: String { case uploading, verifying }
    @Published private(set) var phase: Phase = .uploading
    @Published private(set) var activeToken: String?
    @Published private(set) var activity = "Galleries are saved on iPad until verified online."
    @Published private(set) var lastActivityAt: Date?
    private struct Job {
        let token: String
        var priority: Priority
        let lane: Lane
        let operation: @MainActor () async throws -> GalleryUploadResult
        var waiters: [CheckedContinuation<GalleryUploadResult, Error>]
        let enqueuedAt: TimeInterval
    }
    private var jobs: [Job] = []
    private var activeWaiters: [String: [CheckedContinuation<GalleryUploadResult, Error>]] = [:]
    private var owners: [String: Task<Void, Never>] = [:]
    private var verifyingTokens: Set<String> = []
    private var verificationCapacity: (token: String, continuation: CheckedContinuation<Void, Never>)?
    // Bound public reads and retained payload memory. One additional POST can run concurrently.
    private let maximumVerifications = 2
    private var freshSlots = 0
    private var recoveryTask: Task<Void, Never>?
    private var recoveryWake: Task<Void, Never>?
    private var recoveryRequested = false
    private var recovery: (@MainActor () async -> Date?)?
    private var connectionAvailable = true
    private var pathSignature: String?
    private(set) var connectivityGeneration = 0
    private var lastReachabilityWake = Date.distantPast

    func perform(token: String, priority: Priority = .guest, lane: Lane = .transmission,
                 operation: @escaping @MainActor () async throws -> GalleryUploadResult) async throws -> GalleryUploadResult {
        try await withCheckedThrowingContinuation { continuation in
            if activeWaiters[token] != nil { activeWaiters[token]!.append(continuation); return }
            if let index = jobs.firstIndex(where: { $0.token == token }) {
                jobs[index].waiters.append(continuation)
                if priority == .guest { jobs[index].priority = .guest }
            } else {
                jobs.append(Job(token: token, priority: priority, lane: lane, operation: operation, waiters: [continuation], enqueuedAt: ProcessInfo.processInfo.systemUptime))
            }
            startWorker()
        }
    }

    func report(_ message: String, phase: Phase? = nil) {
        if let phase { self.phase = phase }
        activity = message
        lastActivityAt = Date()
    }

    /// Release only the transmission lane; the token lease and all joined callers remain owned.
    /// Call only when the operation will perform no further POST (accepted or read-only work).
    func beginVerification(token: String) async {
        if verifyingTokens.contains(token) { return }
        guard activeToken == token else { return }
        if verifyingTokens.count >= maximumVerifications {
            await withCheckedContinuation { verificationCapacity = (token, $0) }
        }
        verifyingTokens.insert(token)
        activeToken = nil
        startWorker()
    }

    private func startWorker() {
        // Public reconciliation does not wait behind a slow POST. Admission happens
        // before starting its closure, so it cannot occupy the transmission lane.
        while verifyingTokens.count < maximumVerifications,
              let index = jobs.firstIndex(where: { $0.lane == .publicRead }) {
            let job = jobs.remove(at: index)
            verifyingTokens.insert(job.token)
            launch(job)
        }
        guard activeToken == nil, !jobs.isEmpty else { return }
        let recoveryIndex = jobs.firstIndex { $0.priority == .recovery && $0.lane == .transmission }
        let freshIndex = jobs.firstIndex { $0.priority == .guest && $0.lane == .transmission }
        guard recoveryIndex != nil || freshIndex != nil else { return }
        let index = freshSlots >= 2 ? (recoveryIndex ?? freshIndex!) : (freshIndex ?? recoveryIndex!)
        let job = jobs.remove(at: index)
        freshSlots = job.priority == .guest ? min(2, freshSlots + 1) : 0
        activeToken = job.token
        launch(job)
    }

    private func launch(_ job: Job) {
        activeWaiters[job.token] = job.waiters
        GalleryPerformance.record(.queueWaiting, since: job.enqueuedAt)
        owners[job.token] = Task {
            let result: Result<GalleryUploadResult, Error>
            do { result = .success(try await job.operation()) }
            catch { result = .failure(error) }
            let waiters = activeWaiters.removeValue(forKey: job.token) ?? []
            owners[job.token] = nil
            if activeToken == job.token { activeToken = nil }
            if verifyingTokens.remove(job.token) != nil, let capacity = verificationCapacity {
                verificationCapacity = nil
                // Reserve before resuming: a queued public read cannot steal this
                // slot and push the verifier count above its memory/network bound.
                verifyingTokens.insert(capacity.token)
                capacity.continuation.resume()
            }
            for waiter in waiters { waiter.resume(with: result) }
            // Sequential recovery can submit its next oldest durable item before fresh jobs drain.
            await Task.yield()
            startWorker()
            if activeWaiters.isEmpty && jobs.isEmpty {
                report("Delivery pass finished. Unverified galleries remain saved on iPad.")
                NotificationCenter.default.post(name: .galleryQueueChanged, object: nil)
            }
        }
    }

    func configureRecovery(_ handler: @escaping @MainActor () async -> Date?) {
        recovery = handler
    }

    func connectionChanged(available: Bool, signature: String? = nil) {
        let restored = !connectionAvailable && available
        let changed = available && signature != nil && signature != pathSignature
        if restored || changed { connectivityGeneration += 1 }
        pathSignature = signature
        connectionAvailable = available
        if !available { recoveryWake?.cancel(); recoveryWake = nil }
        if restored || changed { requestRecovery() }
    }

    func backendReachabilityConfirmed(at now: Date = Date()) -> Bool {
        guard now.timeIntervalSince(lastReachabilityWake) >= 30 else { return false }
        lastReachabilityWake = now
        connectivityGeneration += 1
        return true
    }

    /// A single cancellable deadline, not a polling loop. Signals coalesce while recovery runs.
    func requestRecovery() {
        recoveryWake?.cancel(); recoveryWake = nil
        guard connectionAvailable, let recovery else { return }
        guard recoveryTask == nil else { recoveryRequested = true; return }
        recoveryTask = Task {
            var next: Date?
            repeat {
                recoveryRequested = false
                next = await recovery()
            } while recoveryRequested && connectionAvailable
            recoveryTask = nil
            guard connectionAvailable, let next else { return }
            recoveryWake = Task {
                do { try await Task.sleep(for: .seconds(max(1, next.timeIntervalSinceNow))) }
                catch { return }
                requestRecovery()
            }
        }
    }
}

extension Notification.Name {
    nonisolated static let galleryQueueChanged = Notification.Name("pocketPixels.galleryQueueChanged")
    nonisolated static let galleryTransferProgressChanged = Notification.Name("pocketPixels.galleryTransferProgressChanged")
}

nonisolated enum GalleryRetryCategory: String, Codable, Sendable {
    case offline, backendUnavailable, timeout, ambiguous, server, rateLimited, authentication, configuration, verification, inspection
    var needsAttention: Bool { [.authentication, .configuration, .inspection].contains(self) }

    static func classify(_ error: Error, state: GalleryDeliveryState) -> Self {
        if case GalleryPublicVerificationError.rateLimited = error { return .rateLimited }
        if let galleryError = error as? GalleryUploadError, case .configuration = galleryError { return .configuration }
        if state == .posted { return .verification }
        guard let error = error as? GalleryUploadError else {
            if let url = error as? URLError {
                if url.code == .notConnectedToInternet { return .offline }
                return url.code == .timedOut ? .timeout : .backendUnavailable
            }
            return .configuration
        }
        switch error {
        case .pendingNoInternet: return .offline
        case .network, .backendUnreachable: return .backendUnavailable
        case .timeout: return .timeout
        case .deliveryUnknown, .invalidResponse, .decoding: return .ambiguous
        case .rateLimited: return .rateLimited
        case .unauthorized, .missingDeviceToken, .invalidDeviceToken: return .authentication
        case .conflictManualInspection, .stalePendingUpload: return .inspection
        case .httpStatus(let code): return code >= 500 || code == 408 ? .server : .inspection
        case .server: return .inspection
        default: return .configuration
        }
    }

    func nextAttempt(at now: Date, attempts: Int, retryAfter: TimeInterval? = nil, jitter: Double = Double.random(in: 0.85...1.15)) -> Date? {
        guard !needsAttention else { return nil }
        let backoff = min(900, 5 * pow(2, Double(min(8, max(0, attempts - 1)))))
        return now.addingTimeInterval(max(retryAfter ?? 0, min(900, backoff * jitter)))
    }
}
