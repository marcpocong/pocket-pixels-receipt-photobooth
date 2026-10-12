//
//  EventOperationalState.swift
//  PocketPixelsBooth
//

import Combine
import AVFoundation
import Foundation
import Network
import SwiftUI
import UIKit

struct EventReadinessCheck: Identifiable, Sendable {
    enum Severity: String, Sendable {
        case critical
        case important
        case optional
    }

    enum Status: String, Sendable {
        case pass
        case fail
        case warning
    }

    var id: String { "\(severity.rawValue)-\(title)" }
    let severity: Severity
    let title: String
    let status: Status
    let detail: String
}

struct EventReadinessReport: Sendable {
    let checks: [EventReadinessCheck]
    let generatedAt: Date

    enum Readiness: String { case ready, attention, notReady }

    var readiness: Readiness {
        guard !checks.isEmpty else { return .notReady }
        if checks.contains(where: { $0.severity == .critical && $0.status != .pass }) { return .notReady }
        return checks.contains(where: { $0.status != .pass }) ? .attention : .ready
    }

    var isReadyForEvent: Bool { readiness != .notReady }
    var title: String {
        switch readiness {
        case .ready: "READY FOR EVENT"
        case .attention: "READY WITH ATTENTION"
        case .notReady: "NOT READY"
        }
    }
    var reasons: [EventReadinessCheck] { checks.filter { $0.status != .pass } }

}

@MainActor
final class EventOperationalState: ObservableObject {
    static let shared = EventOperationalState()

    @Published private(set) var pendingUploads: [GalleryPendingUploadSummary] = []
    @Published private(set) var networkPathStatus = "Unknown"
    @Published private(set) var isUploadWorkerRunning = false
    @Published private(set) var lastUploadWorkerMessage = "Upload worker has not run."
    @Published private(set) var recoverableSession: AppRecoverySnapshot?
    @Published private(set) var sessionsCompletedThisLaunch = 0
    @Published private(set) var cameraRestartCountThisLaunch = 0
    @Published private(set) var uploadFailuresThisLaunch = 0
    @Published private(set) var appStartedAt = Date()
    @Published private(set) var readinessReport = EventReadinessReport(checks: [], generatedAt: Date())

    @Published private(set) var isPreflightRunning = false
    @Published private(set) var cameraCheckPassed = false
    @Published private(set) var cameraCheckMessage = "Run preflight to check camera initialization."
    @Published private(set) var auditRecords: [PrintAuditRecord] = []
    @Published private(set) var archiveCount = 0
    @Published private(set) var availableBytes: Int64 = 0
    @Published private(set) var queueError: String?
    @Published private(set) var recoveryConfirmation = 0
    @Published var customerSessionActive = false
    /// A hardware qualification print may have started without a confirmed outcome. The printer's
    /// physical state is unknown, so customers are blocked exactly like an unresolved customer print.
    @Published private(set) var qualificationPrintNeedsInspection = false
    private let preflightCamera = CameraService()
    private var preflightGeneration = 0
    private var acknowledgedPrintIdentity: String?

    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "com.pocketpixels.event-network-monitor")
    private let uploadService = GoogleDriveGalleryUploadService()
    private let credentialStore = DeviceCredentialStore()
    private let recoveryStore = try? AppRecoveryStore()
    private var retryTask: Task<Void, Never>?
    private var didStart = false

    private init() {}

    var uptimeText: String {
        Self.durationText(Date().timeIntervalSince(appStartedAt))
    }

    var pendingUploadCount: Int {
        pendingUploads.count
    }

    func start() {
        guard !didStart else {
            refresh()
            return
        }

        didStart = true
        recoverableSession = recoveryStore?.load()
        refresh()
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                self?.networkPathStatus = Self.networkStatusText(path.status)
                self?.refresh()
                if path.status == .satisfied {
                    self?.retryPendingUploads(reason: "Network path is available.")
                }
            }
        }
        monitor.start(queue: monitorQueue)
    }

    func handleScenePhaseActive() {
        start()
        refresh()
        retryPendingUploads(reason: "App became active.")
    }

    func refresh() {
        do {
            pendingUploads = try GalleryPendingUploadStore().summaries()
            queueError = nil
        } catch {
            queueError = "Pending gallery storage needs operator inspection. Data has been retained."
        }
        recoverableSession = recoveryStore?.load()
        auditRecords = (try? PrintAuditStore().load()) ?? []
        archiveCount = (try? RecentSessionArchiveStore().summaries().count) ?? 0
        qualificationPrintNeedsInspection = (try? HardwareQualificationStore())?.unresolvedPrintRun != nil
        availableBytes = Self.freeDiskSpaceBytes()
        readinessReport = makeReadinessReport()
    }

    func recordSessionCompleted() {
        sessionsCompletedThisLaunch += 1
    }

    func recordCameraRestart() {
        cameraRestartCountThisLaunch += 1
    }

    func retryPendingUploads(reason: String) {
        guard retryTask == nil, networkPathStatus == "Online" else {
            return
        }

        pendingUploads = uploadService.pendingUploadSummaries()
        guard !pendingUploads.isEmpty else {
            lastUploadWorkerMessage = "No pending uploads."
            return
        }

        guard let deviceToken = try? credentialStore.loadDeviceToken() else {
            lastUploadWorkerMessage = "Pending uploads are waiting for the saved device token."
            return
        }

        isUploadWorkerRunning = true
        lastUploadWorkerMessage = reason
        retryTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.isUploadWorkerRunning = false
                self.retryTask = nil
                self.refresh()
            }

            do {
                let results = try await uploadService.retryPendingQueue(deviceToken: deviceToken, maxAttemptsPerGallery: 2)
                lastUploadWorkerMessage = results.isEmpty
                    ? "No pending uploads."
                    : "Uploaded \(results.count) pending \(results.count == 1 ? "gallery" : "galleries")."
            } catch {
                uploadFailuresThisLaunch += 1
                lastUploadWorkerMessage = "Upload paused. Photos remain saved locally. Check connection and gallery settings."
            }
        }
    }

    var hasUnresolvedPrint: Bool {
        if qualificationPrintNeedsInspection { return true }
        guard let snapshot = recoverableSession, snapshot.stage == .printStatusUnknown else { return false }
        return OperatorPrintPolicy.requiresAcknowledgement(stage: snapshot.stage, snapshotIdentity: recoveryIdentity(snapshot), acknowledgedIdentity: acknowledgedPrintIdentity)
    }

    private func recoveryIdentity(_ snapshot: AppRecoverySnapshot) -> String {
        "\(snapshot.sessionIdentifier)|\(snapshot.updatedAt.timeIntervalSince1970)"
    }

    func confirmPhysicalPrinterRecovery() {
        let printer = PrinterCoordinator.shared
        guard !printer.isWorking, printer.requiresRecovery || hasUnresolvedPrint else { return }
        printer.confirmPrinterRestarted()
        if qualificationPrintNeedsInspection, let store = try? HardwareQualificationStore(), let run = store.unresolvedPrintRun {
            try? store.acknowledgeUncertainPrint(runID: run.runID, note: "Confirmed through Printer Recovery.")
        }
        if let snapshot = recoverableSession, snapshot.stage == .printStatusUnknown {
            acknowledgedPrintIdentity = recoveryIdentity(snapshot)
        }
        recoveryConfirmation += 1
        refresh()
    }

    func invalidateCameraCheck(message: String = "Run preflight after returning to the app.") {
        preflightGeneration += 1
        isPreflightRunning = false
        cameraCheckPassed = false
        cameraCheckMessage = message
        preflightCamera.stopSession()
        refresh()
    }

    func runEventPreflight() {
        guard !isPreflightRunning, !customerSessionActive, !PrinterCoordinator.shared.isWorking else { return }
        isPreflightRunning = true
        cameraCheckPassed = false
        cameraCheckMessage = "Checking camera initialization…"
        refresh()
        let generation = preflightGeneration
        if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
            Task { [weak self] in
                guard let self else { return }
                _ = await self.preflightCamera.requestAccess()
                guard generation == self.preflightGeneration else { return }
                self.finishCameraPreflight(generation: generation)
            }
            return
        }
        finishCameraPreflight(generation: generation)
    }

    private func finishCameraPreflight(generation: Int) {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            cameraCheckMessage = "Camera permission required. Enable Camera in iPad Settings."
            isPreflightRunning = false
            refresh()
            return
        }
        preflightCamera.configureAndStart { [weak self] result in
            guard let self else { return }
            guard generation == self.preflightGeneration else { return }
            self.preflightCamera.stopSession()
            switch result {
            case .success:
                self.cameraCheckPassed = true
                self.cameraCheckMessage = "Camera initialized. Verify live preview before guests arrive."
            case .failure:
                self.cameraCheckPassed = false
                self.cameraCheckMessage = "Camera unavailable. Check on the physical iPad."
            }
            self.isPreflightRunning = false
            self.refresh()
        }
    }

    private func makeReadinessReport() -> EventReadinessReport {
        var checks: [EventReadinessCheck] = []
        let cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
        let printerCoordinator = PrinterCoordinator.shared
        let freeDiskSpace = Self.freeDiskSpaceBytes()
        let eventProfile = EventProfileStore.load()

        checks.append(EventReadinessCheck(severity: .critical, title: "Camera Initialization",
            status: cameraCheckPassed ? .pass : .fail, detail: cameraCheckMessage))
        checks.append(EventReadinessCheck(severity: .critical, title: "Pending Gallery Storage",
            status: queueError == nil ? .pass : .fail, detail: queueError ?? "Accessible"))
        checks.append(EventReadinessCheck(
            severity: .critical,
            title: "Camera Authorization",
            status: cameraStatus == .authorized ? .pass : .fail,
            detail: Self.cameraAuthorizationText(cameraStatus)
        ))
        checks.append(EventReadinessCheck(
            severity: .critical,
            title: "Printer",
            status: printerCoordinator.preferredMode != .wifi && PrinterBluetoothService.shared.canPrintRaster ? .pass : .fail,
            detail: printerCoordinator.preferredMode == .wifi ? "Wi-Fi readiness is not verified by this preflight." : (PrinterBluetoothService.shared.canPrintRaster ? printerCoordinator.bluetoothSummary : "Connect printer and complete any required operator text-test check in Recovery.")
        ))
        checks.append(EventReadinessCheck(
            severity: .critical,
            title: "Print Queue",
            status: printerCoordinator.isWorking ? .fail : .pass,
            detail: printerCoordinator.isWorking ? "Busy" : "Idle"
        ))
        checks.append(EventReadinessCheck(
            severity: .critical,
            title: "Printer Recovery",
            status: printerCoordinator.requiresRecovery ? .fail : .pass,
            detail: printerCoordinator.requiresRecovery ? "Recovery Required" : "Clear"
        ))
        checks.append(EventReadinessCheck(
            severity: .critical,
            title: "Unsafe Print State",
            status: hasUnresolvedPrint ? .fail : .pass,
            detail: hasUnresolvedPrint ? "Receipt may already have printed. Operator recovery required." : "Clear / acknowledged"
        ))
        checks.append(storageCheck(title: "Archive Storage", severity: .critical) {
            let store = try RecentSessionArchiveStore()
            try OperatorStorageProbe.verify(directory: URL(fileURLWithPath: store.storagePath))
            if try store.summaries().contains(where: { $0.rasterFingerprint == "CORRUPT" }) {
                throw CocoaError(.fileReadCorruptFile)
            }
        })
        checks.append(storageCheck(title: "Recovery Storage", severity: .critical) {
            let store = try AppRecoveryStore()
            let file = URL(fileURLWithPath: store.storagePath)
            try OperatorStorageProbe.verify(directory: file.deletingLastPathComponent())
            if FileManager.default.fileExists(atPath: file.path), store.load() == nil {
                throw CocoaError(.fileReadCorruptFile)
            }
        })
        checks.append(EventReadinessCheck(
            severity: .important,
            title: "Internet",
            status: networkPathStatus == "Online" ? .pass : .warning,
            detail: networkPathStatus
        ))
        checks.append(EventReadinessCheck(
            severity: .important,
            title: "Pending Uploads",
            status: pendingUploadCount == 0 ? .pass : .warning,
            detail: "\(pendingUploadCount)"
        ))
        checks.append(EventReadinessCheck(
            severity: .important,
            title: "Gallery Credentials",
            status: credentialStore.hasDeviceToken() ? .pass : .warning,
            detail: credentialStore.hasDeviceToken() ? "Saved" : "Missing"
        ))
        checks.append(EventReadinessCheck(
            severity: StorageHealth(bytes: freeDiskSpace) == .critical ? .critical : .important,
            title: "Free Disk Space",
            status: StorageHealth(bytes: freeDiskSpace).checkStatus,
            detail: "\(StorageHealth(bytes: freeDiskSpace).rawValue) — \(Self.freeDiskSpaceText(bytes: freeDiskSpace))"
        ))
        checks.append(EventReadinessCheck(
            severity: .optional,
            title: "Event Profile",
            status: eventProfile.isEnabled && eventProfile.activeReceiptSnapshot == nil ? .warning : .pass,
            detail: eventProfile.activeReceiptSnapshot?.eventName ?? MadeToKeepBrand.defaultEventName
        ))
        checks.append(EventReadinessCheck(
            severity: .optional,
            title: "Printer Mode",
            status: .pass,
            detail: "\(printerCoordinator.preferredMode.displayName) · Bluetooth transfer: \(printerCoordinator.receiptBluetoothTransferMode.operatorSummary)"
        ))
        checks.append(EventReadinessCheck(
            severity: .optional,
            title: "App Uptime",
            status: .pass,
            detail: uptimeText
        ))

        return EventReadinessReport(checks: checks, generatedAt: Date())
    }

    private func storageCheck(
        title: String,
        severity: EventReadinessCheck.Severity,
        operation: () throws -> Void
    ) -> EventReadinessCheck {
        do {
            try operation()
            return EventReadinessCheck(severity: severity, title: title, status: .pass, detail: "Accessible")
        } catch {
            return EventReadinessCheck(severity: severity, title: title, status: .fail, detail: error.localizedDescription)
        }
    }

    private static func networkStatusText(_ status: NWPath.Status) -> String {
        switch status {
        case .satisfied:
            "Online"
        case .unsatisfied:
            "Offline"
        case .requiresConnection:
            "Requires Connection"
        @unknown default:
            "Unknown"
        }
    }

    private static func durationText(_ duration: TimeInterval) -> String {
        let seconds = max(0, Int(duration))
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }

    private static func cameraAuthorizationText(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .authorized:
            "Authorized"
        case .notDetermined:
            "Not Determined"
        case .denied:
            "Denied"
        case .restricted:
            "Restricted"
        @unknown default:
            "Unknown"
        }
    }

    private static func freeDiskSpaceBytes() -> Int64 {
        let values = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }

    private static func freeDiskSpaceText(bytes: Int64) -> String {
        let megabytes = bytes / 1_000_000
        return megabytes > 0 ? "\(megabytes) MB" : "Unknown"
    }
}
