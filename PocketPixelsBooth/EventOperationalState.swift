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
    @Published private(set) var recoveryActionMessage = ""
    @Published private(set) var recoveryStorageError: String?
    @Published var customerSessionActive = false
    /// A hardware qualification print may have started without a confirmed outcome. The printer's
    /// physical state is unknown, so customers are blocked exactly like an unresolved customer print.
    @Published private(set) var qualificationPrintNeedsInspection = false
    private let preflightCamera = CameraService()
    private var preflightGeneration = 0
    // An explicit owner-directed venue override applies only to the exact old checkpoint.
    // A new session/checkpoint always has a different identity and still blocks for recovery.
    private var acknowledgedPrintIdentity: String? = UserDefaults.standard.string(forKey: "pocketPixels.venueOwnerAcknowledgedPrintIdentity")

    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "com.pocketpixels.event-network-monitor")
    private let uploadService = GoogleDriveGalleryUploadService()
    private let credentialStore = DeviceCredentialStore()
    private let recoveryStore = try? AppRecoveryStore()
    private var retryTask: Task<Void, Never>?
    private var retryRequested = false
    private var didStart = false
    private var printerStatusSubscription: AnyCancellable?
    private var selectedPrinterSubscription: AnyCancellable?

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
        // @Published emits before mutation; deliver on the next main run-loop turn so
        // readiness reads the updated connection and discovered write characteristic.
        printerStatusSubscription = PrinterBluetoothService.shared.$jobState
            .receive(on: RunLoop.main)
            // Chunk progress can publish hundreds of times; only a readiness change
            // should rerun storage/camera checks on the main actor.
            .map { _ in PrinterBluetoothService.shared.readinessMessage }
            .removeDuplicates()
            .sink { [weak self] _ in
                guard let self else { return }
                self.readinessReport = self.makeReadinessReport()
            }
        selectedPrinterSubscription = PrinterCoordinator.shared.objectWillChange
            .receive(on: RunLoop.main)
            .map { PrinterCoordinator.shared.operatorState }
            .removeDuplicates()
            .sink { [weak self] _ in
                guard let self else { return }
                self.readinessReport = self.makeReadinessReport()
            }
        recoverableSession = recoveryStore?.load()
#if DEBUG
        if ProcessInfo.processInfo.environment["POCKET_PIXELS_PREPARE_MIDORI"] == "1" {
            Task { @MainActor in
                let wasAuthorized = OperatorAccessPermit.shared.isAuthorized
                OperatorAccessPermit.shared.authorize()
                defer { if !wasAuthorized { OperatorAccessPermit.shared.revoke() } }
                // Explicit owner override applies only to this booth's local admission policy.
                CommercialPolicySource.save(.localPrepaid)
                let runs = EventRunStore(authorized: { true }, blockingReason: { nil })
                let setup = SessionSetupCoordinator(eventRuns: runs, authorized: { true }, blockingReason: { nil }, source: { .localPrepaid })
                setup.mode = .localPrepaid
                await setup.choosePayment(.noPayment)
                if let existing = setup.savedEvents.first(where: { $0.name == "midori" }) {
                    await setup.chooseDesign(existing.id)
                    await setup.setEventMode(true)
                } else {
                    await setup.createEvent(name: "midori", venue: "")
                }
                setup.prepaid.activePolicy = .legacyPrepaid
                setup.prepaid.activePolicy.maxCopies = 10
                setup.prepaid.activePolicy.defaultCopies = 1
                setup.prepaid.activePolicy.prepaidGuestCopyChoice = true
                setup.design?.profile.receiptDesign.footerStyleOverride = .integratedGalleryQR
                setup.startsNewOccurrence = true
                setup.mode = .localPrepaid
                setup.unattendedQR = false
                var ready = false
                do {
                    if let design = setup.design { try setup.library.save(design) }
                    var run = setup.prepaid
                    run.name = "midori"
                    run.lifecycle = .active
                    run.updatedAt = Date()
                    try CommercialEventRunStore.publish(run)
                    EventProfileStore.save(setup.effectiveProfile)
                    try setup.library.recordApplied(eventModeEnabled: true, eventID: setup.design?.id)
                    let context = setup.runContext
                    try setup.eventRuns.commitStart(context: context, expected: setup.eventRuns.occurrencePlan(for: context), allowNewOccurrence: true)
                    try SessionAcceptanceStore.shared.save(.init(mode: .localPrepaid, boothMode: .event))
                    OperatorWorkspace.shared.saveSessionSetup(nil)
                    ready = true
                } catch { print("[MidoriSetup] local configuration failed: \(error)") }
                print("[MidoriSetup] ready=\(ready) mode=\(setup.mode.rawValue) message=\(setup.message)")
                let status: [String: Any] = ["ready": ready, "message": setup.message,
                    "event": setup.design?.name ?? "", "maxCopies": setup.prepaid.activePolicy.maxCopies,
                    "priceCentavos": setup.prepaid.activePolicy.unitPriceCentavos,
                    "footer": setup.design?.profile.receiptDesign.footerStyleOverride?.rawValue ?? ""]
                if let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
                   let data = try? JSONSerialization.data(withJSONObject: status, options: .sortedKeys) {
                    try? data.write(to: root.appendingPathComponent("MidoriSetupStatus.json"), options: .atomic)
                }
            }
        }
        if let rawMode = ProcessInfo.processInfo.environment["POCKET_PIXELS_RECEIPT_TRANSFER_MODE"],
           let mode = ReceiptBluetoothTransferMode(rawValue: rawMode) {
            PrinterCoordinator.shared.preferredMode = .bluetooth
            PrinterCoordinator.shared.receiptBluetoothTransferMode = mode
            print("[VenueSetup] Bluetooth receipt transfer configured: \(mode.rawValue).")
        }
        // Local developer-device handoff only, invoked for an explicit owner instruction.
        // Preserve the unknown result and all photos; do not claim paper verification or resend.
        if let snapshot = recoverableSession, snapshot.stage == .printStatusUnknown,
           ProcessInfo.processInfo.environment["POCKET_PIXELS_OWNER_ACKNOWLEDGED_SESSION"] == snapshot.sessionIdentifier {
            let identity = recoveryIdentity(snapshot)
            acknowledgedPrintIdentity = identity
            UserDefaults.standard.set(identity, forKey: "pocketPixels.venueOwnerAcknowledgedPrintIdentity")
            PrinterCoordinator.shared.preferredMode = .bluetooth
            print("[VenueSetup] Owner acknowledged the previous unknown print; old receipt retained, never resent.")
            Task { @MainActor [weak self] in
                guard let self else { return }
                let printerReady = (try? await PrinterBluetoothService.shared.waitUntilReady()) == true
                self.runEventPreflight()
                let deadline = Date().addingTimeInterval(10)
                while self.isPreflightRunning && Date() < deadline {
                    try? await Task.sleep(for: .milliseconds(200))
                }
                let status: [String: Any] = [
                    "regularBooth": RegularBoothMode.isEnabled,
                    "printerReady": printerReady,
                    "printer": PrinterBluetoothService.shared.readinessMessage,
                    "cameraReady": self.cameraCheckPassed,
                    "unresolvedPrint": self.hasUnresolvedPrint,
                    "printerRecovery": PrinterCoordinator.shared.requiresRecovery,
                    "checkedAt": ISO8601DateFormatter().string(from: Date())
                ]
                if let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
                   let data = try? JSONSerialization.data(withJSONObject: status, options: .sortedKeys) {
                    try? data.write(to: root.appendingPathComponent("VenueSetupStatus.json"), options: .atomic)
                }
            }
        }
#endif
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
        do {
            guard let recoveryStore else { throw AppRecoveryStoreError.unavailable }
            recoverableSession = try recoveryStore.loadChecked()
            acknowledgedPrintIdentity = recoveryStore.acknowledgedIdentity ?? UserDefaults.standard.string(forKey: OperatorRecoveryAcknowledgement.key)
            recoveryStorageError = nil
        } catch { recoveryStorageError = "Saved guest recovery could not be read. The original file is retained. \(error.localizedDescription)" }
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
        guard networkPathStatus == "Online" else { return }
        guard retryTask == nil else {
            // Retry All during the recovery backoff wakes the existing worker, never starts a rival.
            retryRequested = true
            lastUploadWorkerMessage = "Retry requested; continuing recovery."
            return
        }
        retryRequested = false

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

            repeat {
                do {
                    let results = try await uploadService.retryPendingQueue(deviceToken: deviceToken, maxAttemptsPerGallery: 1)
                    lastUploadWorkerMessage = "Ready: \(results.count). Waiting: \(uploadService.pendingUploadSummaries().count)."
                } catch let failure as GalleryPendingQueueFailure {
                    uploadFailuresThisLaunch += failure.failedCount
                    lastUploadWorkerMessage = "Ready: \(failure.successfulResults.count). Needs attention / waiting: \(failure.failedCount). Photos retained."
                } catch {
                    lastUploadWorkerMessage = "Another upload is active or retry is unavailable. Photos retained; retrying shortly."
                }
                refresh()
                guard !pendingUploads.isEmpty, networkPathStatus == "Online" else { return }
                // Reconnection can arrive while another upload owns the worker. Keep one recovery
                // task alive so a busy trigger or delayed public verification is not lost.
                isUploadWorkerRunning = false
                for _ in 0..<30 {
                    if retryRequested {
                        retryRequested = false
                        break
                    }
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                }
                guard networkPathStatus == "Online" else { return }
                isUploadWorkerRunning = true
            } while !Task.isCancelled

        }
    }

    var hasUnresolvedPrint: Bool {
        if qualificationPrintNeedsInspection || PrintOutcomeOutbox.shared?.inspectionEntryIDs.isEmpty == false || !PaymentRecoveryCoordinator.shared.receiptCheckIDs.isEmpty { return true }
        // A launch/final-outcome write failure can retain an in-flight intent after the
        // transport stopped. Keep every print UI behind recovery until it is durably normalized.
        if PrintOutcomeOutbox.shared?.hasUnfinishedPhysicalSend == true && !PrinterCoordinator.shared.isWorking { return true }
        guard let snapshot = recoverableSession, snapshot.stage == .printStatusUnknown else { return false }
        return OperatorPrintPolicy.requiresAcknowledgement(stage: snapshot.stage, snapshotIdentity: recoveryIdentity(snapshot), acknowledgedIdentity: acknowledgedPrintIdentity)
    }

    private func recoveryIdentity(_ snapshot: AppRecoverySnapshot) -> String {
        OperatorRecoveryAcknowledgement.identity(snapshot)
    }

    var physicalRecoveryIdentity: String {
        // Keep the same ordered identity components. Explicit types also bound the
        // constraint solver on the Xcode 16.4 production runner.
        let sessionIdentity: String = recoverableSession.map(recoveryIdentity) ?? "no-snapshot"
        let inspectionIDs: [String]? = PrintOutcomeOutbox.shared?.inspectionEntryIDs.sorted()
        let inspectionIdentity: String = inspectionIDs?.joined(separator: ",") ?? "no-journal"
        let receiptIDs: [String] = PaymentRecoveryCoordinator.shared.receiptCheckIDs.sorted()
        let receiptIdentity: String = receiptIDs.joined(separator: ",")
        return [sessionIdentity, inspectionIdentity, receiptIdentity].joined(separator: "|")
    }

    @discardableResult
    func confirmPhysicalPrinterRecovery(expectedIdentity: String? = nil) -> Bool {
        let printer = PrinterCoordinator.shared
        guard OperatorAccessPermit.shared.isAuthorized, !printer.isWorking, printer.requiresRecovery || hasUnresolvedPrint else { return false }
        if let expectedIdentity, expectedIdentity != physicalRecoveryIdentity {
            recoveryActionMessage = "A different receipt now needs inspection. Review Receipt again."
            return false
        }
        do {
            guard let outbox = PrintOutcomeOutbox.shared else { throw AppRecoveryStoreError.unavailable }
            try outbox.acknowledgeInspection(entryIDs: outbox.inspectionEntryIDs)
            for id in PaymentRecoveryCoordinator.shared.receiptCheckIDs {
                guard CheckoutCheckpointStore.shared?.update(id: id, { $0.physicalReviewAt = Date() }) == true else {
                    throw SetupFailure("The original checkout receipt check could not be saved. Retry Saving Resolution.")
                }
            }
            PaymentRecoveryCoordinator.shared.refreshLocalDecisions()
        } catch {
            recoveryActionMessage = "Could not save the receipt check. Retry Saving Resolution. \(error.localizedDescription)"
            return false
        }
        if let snapshot = recoverableSession {
            guard retainAndAcknowledge(snapshot) else { return false }
        }
        printer.confirmPrinterRestarted()
        if qualificationPrintNeedsInspection, let store = try? HardwareQualificationStore(), let run = store.unresolvedPrintRun {
            do { try store.acknowledgeUncertainPrint(runID: run.runID, note: "Confirmed through Printer Recovery.") }
            catch { recoveryActionMessage = "Could not save the hardware receipt check. \(error.localizedDescription)"; return false }
        }
        recoveryActionMessage = "Receipt check recorded. Reconnect the printer and complete any requested paper test."
        recoveryConfirmation += 1
        refresh()
        return true
    }

    var hasPendingSessionRecovery: Bool {
        if recoveryStorageError != nil { return true }
        guard let snapshot = recoverableSession else { return false }
        if CheckoutCheckpointStore.shared?.checkpoint(id: snapshot.sessionIdentifier)?.isParked == true { return false }
        return recoveryIdentity(snapshot) != acknowledgedPrintIdentity
    }

    private func retainAndAcknowledge(_ snapshot: AppRecoverySnapshot) -> Bool {
        do {
            guard let recoveryStore else { throw AppRecoveryStoreError.unavailable }
            acknowledgedPrintIdentity = try OperatorRecoveryAcknowledgement.retainAndAcknowledge(snapshot, store: recoveryStore)
            return true
        } catch {
            recoveryActionMessage = "Could not keep the saved session safely: \(error.localizedDescription) Nothing was cleared."
            return false
        }
    }

    func keepInterruptedSessionForReference() { _ = closeSessionAndContinue() }

    @discardableResult
    func closeSessionAndContinue(checkoutID: String? = nil) -> Bool {
        do {
            guard OperatorAccessPermit.shared.isAuthorized else { throw SetupFailure("Unlock Operator before closing a guest session.") }
            guard !PrinterCoordinator.shared.isWorking else { throw SetupFailure("Wait for the active print transport to finish before closing.") }
            guard !hasUnresolvedPrint, !PrinterCoordinator.shared.requiresRecovery else { throw SetupFailure("Review Receipt and record the physical check first. Paper may already exist.") }
            guard let checkpoints = CheckoutCheckpointStore.shared, let outbox = PrintOutcomeOutbox.shared,
                  checkpoints.integrityFault == nil, outbox.integrityFault == nil,
                  outbox.persistenceFailure == nil, !outbox.hasUnfinishedPhysicalSend else {
                throw SetupFailure("Saved checkout or print records need review. Retry Saving Resolution before closing.")
            }
            if let model = ActiveGuestInteraction.model, model.state != .welcome,
               checkoutID == nil || model.sessionIdentifier == checkoutID {
                try model.closeSessionForOperator()
            } else {
                guard let recoveryStore else { throw AppRecoveryStoreError.unavailable }
                let snapshot = try recoveryStore.loadChecked()
                let matching = snapshot.flatMap { checkoutID == nil || $0.sessionIdentifier == checkoutID ? $0 : nil }
                if let id = checkoutID ?? matching?.sessionIdentifier, let checkpoint = checkpoints.checkpoint(id: id), !checkpoint.isResolved {
                    try CheckoutInteractionClosure.close(id: id, reason: "operator:guest_left", checkpoints: checkpoints,
                        recovery: recoveryStore, detached: DetachedCheckoutStore(), snapshot: matching)
                } else if let matching {
                    _ = try OperatorRecoveryAcknowledgement.retainAndAcknowledge(matching, store: recoveryStore)
                }
            }
            recoveryActionMessage = "Guest interaction closed. Outstanding Payments keeps the original payment and remaining entitlement; nothing was refunded, voided or printed."
            refresh()
            PaymentRecoveryCoordinator.shared.refreshLocalDecisions()
            Task { await PaymentRecoveryCoordinator.shared.refresh() }
            return true
        } catch {
            recoveryActionMessage = "Could not close this session. \(error.localizedDescription)"
            return false
        }
    }

    func recordOperatorCameraCheck(passed: Bool, message: String) {
        cameraCheckPassed = passed
        cameraCheckMessage = message
        refresh()
    }

    func invalidateCameraCheck(message: String = "Run preflight after returning to the app.") {
        PrinterCoordinator.shared.invalidateWiFiConnectionCheck()
        preflightGeneration += 1
        isPreflightRunning = false
        cameraCheckPassed = false
        cameraCheckMessage = message
        preflightCamera.stopSession()
        refresh()
    }

    func runEventPreflight() {
        guard !isPreflightRunning, !customerSessionActive, !PrinterCoordinator.shared.isWorking else { return }
        PrinterCoordinator.shared.prepare()
        if PrinterCoordinator.shared.preferredMode != .bluetooth {
            Task { [weak self] in
                _ = await PrinterCoordinator.shared.checkWiFiConnection()
                self?.refresh()
            }
        }
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
            status: printerCoordinator.operatorState.acceptsJobs ? .pass : (printerCoordinator.operatorState == .busy ? .warning : .fail),
            detail: printerCoordinator.operatorState.label
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
