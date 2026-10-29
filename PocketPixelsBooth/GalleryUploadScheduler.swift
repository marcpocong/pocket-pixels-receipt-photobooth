import Combine
import Foundation

/// One process-wide owner of delivery work. Requests join by durable gallery identity.
/// Two fresh guests may pass recovery work; the next slot belongs to the oldest recovery.
/// An acquired operation is never cancelled/preempted by a retry or a path transition.
@MainActor
final class GalleryUploadScheduler: ObservableObject {
    static let shared = GalleryUploadScheduler()
    enum Priority { case guest, recovery }
    enum Phase: String { case uploading, verifying }
    @Published private(set) var phase: Phase = .uploading
    @Published private(set) var activeToken: String?
    @Published private(set) var activity = "Galleries are saved on iPad until verified online."
    @Published private(set) var lastActivityAt: Date?
    private struct Job {
        let token: String
        var priority: Priority
        let operation: @MainActor () async throws -> GalleryUploadResult
        var waiters: [CheckedContinuation<GalleryUploadResult, Error>]
    }
    private var jobs: [Job] = []
    private var activeWaiters: [CheckedContinuation<GalleryUploadResult, Error>] = []
    private var worker: Task<Void, Never>?
    private var freshSlots = 0
    private var recoveryTask: Task<Void, Never>?
    private var recoveryWake: Task<Void, Never>?
    private var recoveryRequested = false
    private var recovery: (@MainActor () async -> Date?)?
    private var connectionAvailable = true

    func perform(token: String, priority: Priority = .guest,
                 operation: @escaping @MainActor () async throws -> GalleryUploadResult) async throws -> GalleryUploadResult {
        try await withCheckedThrowingContinuation { continuation in
            if activeToken == token { activeWaiters.append(continuation); return }
            if let index = jobs.firstIndex(where: { $0.token == token }) {
                jobs[index].waiters.append(continuation)
                if priority == .guest { jobs[index].priority = .guest }
            } else {
                jobs.append(Job(token: token, priority: priority, operation: operation, waiters: [continuation]))
            }
            startWorker()
        }
    }

    func report(_ message: String, phase: Phase? = nil) {
        if let phase { self.phase = phase }
        activity = message
        lastActivityAt = Date()
    }

    private func startWorker() {
        guard worker == nil else { return }
        worker = Task {
            while !jobs.isEmpty {
                let recoveryIndex = jobs.firstIndex { $0.priority == .recovery }
                let freshIndex = jobs.firstIndex { $0.priority == .guest }
                let index = freshSlots >= 2 ? (recoveryIndex ?? freshIndex!) : (freshIndex ?? recoveryIndex!)
                let job = jobs.remove(at: index)
                freshSlots = job.priority == .guest ? min(2, freshSlots + 1) : 0
                activeToken = job.token
                activeWaiters = job.waiters
                let result: Result<GalleryUploadResult, Error>
                do { result = .success(try await job.operation()) }
                catch { result = .failure(error) }
                let waiters = activeWaiters
                activeWaiters = []
                activeToken = nil
                for waiter in waiters { waiter.resume(with: result) }
            }
            worker = nil
            report("Delivery pass finished. Unverified galleries remain saved on iPad.")
            NotificationCenter.default.post(name: .galleryQueueChanged, object: nil)
        }
    }

    func configureRecovery(_ handler: @escaping @MainActor () async -> Date?) {
        recovery = handler
    }

    func connectionChanged(available: Bool) {
        let restored = !connectionAvailable && available
        connectionAvailable = available
        if !available { recoveryWake?.cancel(); recoveryWake = nil }
        if restored { requestRecovery() }
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
    static let galleryQueueChanged = Notification.Name("pocketPixels.galleryQueueChanged")
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
