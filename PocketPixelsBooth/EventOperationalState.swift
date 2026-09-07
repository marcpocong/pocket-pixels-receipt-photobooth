//
//  EventOperationalState.swift
//  PocketPixelsBooth
//

import Combine
import Foundation
import Network
import SwiftUI
import UIKit

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
}

struct SystemHealthView: View {
    @StateObject private var operationalState = EventOperationalState.shared
    @StateObject private var printerCoordinator = PrinterCoordinator.shared
    @State private var recentSessionCount = 0
    @State private var recentSessionError: String?

    var body: some View {
        List {
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
