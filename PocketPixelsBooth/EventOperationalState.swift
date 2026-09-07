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

    var isReadyForEvent: Bool {
        checks.allSatisfy { check in
            check.severity != .critical || check.status == .pass
        }
    }

    var title: String {
        isReadyForEvent ? "READY FOR EVENT" : "NOT READY"
    }
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
        pendingUploads = uploadService.pendingUploadSummaries()
        recoverableSession = recoveryStore?.load()
        readinessReport = makeReadinessReport()
    }

    func recordSessionCompleted() {
        sessionsCompletedThisLaunch += 1
    }

    func recordCameraRestart() {
        cameraRestartCountThisLaunch += 1
    }

    func retryPendingUploads(reason: String) {
        guard retryTask == nil else {
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
                lastUploadWorkerMessage = error.localizedDescription
            }
        }
    }

    func dismissRecoverableSession() {
        recoveryStore?.clear()
        recoverableSession = nil
        readinessReport = makeReadinessReport()
    }

    func runEventPreflight() {
        refresh()
    }

    private func makeReadinessReport() -> EventReadinessReport {
        var checks: [EventReadinessCheck] = []
        let cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
        let printerCoordinator = PrinterCoordinator.shared
        let freeDiskSpace = Self.freeDiskSpaceBytes()
        let eventProfile = EventProfileStore.load()

        checks.append(EventReadinessCheck(
            severity: .critical,
            title: "Camera Authorization",
            status: cameraStatus == .authorized ? .pass : .fail,
            detail: Self.cameraAuthorizationText(cameraStatus)
        ))
        checks.append(EventReadinessCheck(
            severity: .critical,
            title: "Printer",
            status: printerCoordinator.isBluetoothReady ? .pass : .fail,
            detail: printerCoordinator.bluetoothSummary
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
            status: recoverableSession?.stage == .printStatusUnknown ? .fail : .pass,
            detail: recoverableSession?.stage == .printStatusUnknown ? "Print Status Unknown" : "None"
        ))
        checks.append(storageCheck(title: "Archive Storage", severity: .critical) {
            _ = try RecentSessionArchiveStore().summaries()
        })
        checks.append(storageCheck(title: "Recovery Storage", severity: .critical) {
            _ = try AppRecoveryStore().load()
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
            severity: .important,
            title: "Free Disk Space",
            status: freeDiskSpace > 500_000_000 ? .pass : .warning,
            detail: Self.freeDiskSpaceText(bytes: freeDiskSpace)
        ))
        checks.append(EventReadinessCheck(
            severity: .optional,
            title: "Event Profile",
            status: eventProfile.activeReceiptSnapshot != nil ? .pass : .warning,
            detail: eventProfile.activeReceiptSnapshot?.eventName ?? "Pocket Pixels default"
        ))
        checks.append(EventReadinessCheck(
            severity: .optional,
            title: "Printer Mode",
            status: .pass,
            detail: printerCoordinator.preferredMode.displayName
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

struct SystemHealthView: View {
    @StateObject private var operationalState = EventOperationalState.shared
    @StateObject private var printerCoordinator = PrinterCoordinator.shared
    @State private var recentSessionCount = 0
    @State private var recentSessionError: String?

    var body: some View {
        List {
            Section("Event Readiness") {
                HStack {
                    Text(operationalState.readinessReport.title)
                        .font(.headline)
                        .foregroundStyle(operationalState.readinessReport.isReadyForEvent ? Color.green : Color.red)
                    Spacer()
                    Text(operationalState.readinessReport.generatedAt.formatted(date: .omitted, time: .standard))
                        .foregroundStyle(.secondary)
                }

                ForEach(operationalState.readinessReport.checks) { check in
                    readinessRow(check)
                }

                Button("Run Event Preflight") {
                    operationalState.runEventPreflight()
                    loadRecentSessionCount()
                }
            }

            Section("System Status") {
                healthRow("Camera", value: "Use Camera Test for live preview status")
                healthRow("Printer", value: printerCoordinator.requiresRecovery ? "Recovery Required" : printerCoordinator.bluetoothSummary)
                healthRow("Print Queue", value: printerCoordinator.isWorking ? "Busy" : "Idle")
                healthRow("Internet", value: operationalState.networkPathStatus)
                healthRow("Pending Uploads", value: "\(operationalState.pendingUploadCount)")
                healthRow("Upload Worker", value: operationalState.isUploadWorkerRunning ? "Uploading" : operationalState.lastUploadWorkerMessage)
                healthRow("Recent Sessions", value: recentSessionError ?? "\(recentSessionCount)")
                healthRow("Sessions This Launch", value: "\(operationalState.sessionsCompletedThisLaunch)")
                healthRow("Camera Restarts", value: "\(operationalState.cameraRestartCountThisLaunch)")
                healthRow("Upload Failures", value: "\(operationalState.uploadFailuresThisLaunch)")
                healthRow("App Uptime", value: operationalState.uptimeText)
            }

            if let snapshot = operationalState.recoverableSession {
                Section("Recoverable Session") {
                    healthRow("Session", value: snapshot.sessionIdentifier)
                    healthRow("Stage", value: snapshot.stage.rawValue)
                    healthRow("Format", value: snapshot.format.displayName)
                    healthRow("Photos", value: "\(snapshot.photoJPEGData.count)")
                    if snapshot.stage == .printStatusUnknown {
                        Text("Print Status Unknown. Do not auto-reprint; use Recent Sessions or operator judgement after checking the physical receipt.")
                            .foregroundStyle(.orange)
                    }
                    Button("Dismiss Recovery Notice", role: .destructive) {
                        operationalState.dismissRecoverableSession()
                    }
                }
            }

            Section("Operator Actions") {
                Button("Retry Pending Uploads Now") {
                    operationalState.retryPendingUploads(reason: "Operator requested retry.")
                }
                .disabled(operationalState.isUploadWorkerRunning || operationalState.pendingUploads.isEmpty)

                NavigationLink("Recent Sessions") {
                    RecentSessionsView()
                }

                NavigationLink("Printer Diagnostics") {
                    PrinterTestView()
                }

                NavigationLink("Camera Test") {
                    CameraTestView()
                }

#if DEBUG
                NavigationLink("Endurance Harness") {
                    EventEnduranceHarnessView()
                }
#endif
            }

            Section("Pending Uploads") {
                if operationalState.pendingUploads.isEmpty {
                    Text("No pending uploads.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(operationalState.pendingUploads) { upload in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(upload.sessionID)
                                .font(.headline.monospacedDigit())
                            Text("\(upload.metrics.files.count - 1) photos • \(upload.deliveryState.displayName) • Retry \(upload.retryAttemptCount)")
                                .foregroundStyle(.secondary)
                            if let lastAttemptAt = upload.lastAttemptAt {
                                Text("Last attempt \(lastAttemptAt.formatted(date: .numeric, time: .standard))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if let lastSafeError = upload.lastSafeError {
                                Text(lastSafeError)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("System Health")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            operationalState.start()
            loadRecentSessionCount()
        }
        .refreshable {
            operationalState.refresh()
            loadRecentSessionCount()
        }
    }

    private func healthRow(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }

    private func readinessRow(_ check: EventReadinessCheck) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(check.title)
                Text(check.severity.rawValue.capitalized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(check.status.rawValue.uppercased())
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(color(for: check.status))
                Text(check.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
        }
    }

    private func color(for status: EventReadinessCheck.Status) -> Color {
        switch status {
        case .pass:
            .green
        case .warning:
            .orange
        case .fail:
            .red
        }
    }

    private func loadRecentSessionCount() {
        do {
            recentSessionCount = try RecentSessionArchiveStore().summaries().count
            recentSessionError = nil
        } catch {
            recentSessionError = error.localizedDescription
        }
    }
}

private extension GalleryDeliveryState {
    var displayName: String {
        switch self {
        case .notStarted:
            "Pending"
        case .posted:
            "Posted"
        case .deliveryUnknown:
            "Delivery Unknown"
        }
    }
}
