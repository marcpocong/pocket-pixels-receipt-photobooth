import AVFoundation
import Combine
import Foundation
import Security
import SwiftUI

nonisolated struct BoothTelemetry: Codable, Equatable, Sendable {
    var mode: String
    var network: String
    var payment: String
    var printer: String
    var storage: String
    var incidents: [String]
    var eventReference: String?
    var reportedAt: String? = nil
    var eventState: String? = nil
    var activityAt: String? = nil
    var uploads: GalleryQueueTelemetry? = nil

    var telemetryVersion: Int? = nil
    var printerObservation: PrinterMonitoringObservation? = nil
    var camera: CameraMonitoringState? = nil
    var guest: GuestMonitoringState? = nil

    func compatible(version: Int) -> Self {
        var value = self
        if version < 3 { if value.eventState == "unknown" { value.eventState = nil }; value.telemetryVersion = nil; value.printerObservation = nil; value.camera = nil; value.guest = nil }
        return version < 2 ? value.legacy() : value
    }

    func legacy() -> Self {
        var value = self
        value.telemetryVersion = nil; value.printerObservation = nil; value.camera = nil; value.guest = nil
        value.reportedAt = nil; value.eventState = nil; value.activityAt = nil; value.uploads = nil
        return value
    }
}

/// Transport/readiness are observations, never a claim of physical paper output.
nonisolated struct PrinterMonitoringObservation: Codable, Equatable, Sendable {
    enum Connection: String, Codable, Sendable { case connected, disconnected, connecting, unknown }
    enum Readiness: String, Codable, Sendable {
        case ready, busy, diagnosticRequired = "diagnostic_required", recoveryRequired = "recovery_required", unavailable, unknown
    }
    enum Evidence: String, Codable, Sendable { case clear, unresolved, unknown }
    enum Transport: String, Codable, Sendable { case bluetooth, wifi, auto, unknown }
    var transport: Transport
    var connection: Connection
    var readiness: Readiness
    var evidence: Evidence

    static func resolve(mode: PrinterConnectionMode, bluetoothConnected: Bool, bluetoothConnecting: Bool,
                        diagnostic: Bool, wifiConnection: Connection, busy: Bool, recovery: Bool,
                        unresolved: Bool, evidenceReadable: Bool) -> Self {
        let usesBluetooth = mode == .bluetooth || (mode == .auto && bluetoothConnected)
        let connection: Connection = usesBluetooth ? (bluetoothConnected ? .connected : (bluetoothConnecting ? .connecting : .disconnected))
            : (wifiConnection == .unknown && mode == .auto && bluetoothConnecting ? .connecting : wifiConnection)
        let readiness: Readiness = recovery ? .recoveryRequired : (busy ? .busy :
            (connection == .connected ? (usesBluetooth && diagnostic ? .diagnosticRequired : .ready) :
                (connection == .disconnected ? .unavailable : .unknown)))
        return Self(transport: usesBluetooth ? .bluetooth : (mode == .wifi || wifiConnection != .unknown ? .wifi : .auto),
                    connection: connection, readiness: readiness,
                    evidence: unresolved ? .unresolved : (evidenceReadable && !busy ? .clear : .unknown))
    }

    var legacyPrinter: String {
        if evidence == .unresolved { return "uncertain" }
        switch readiness {
        case .recoveryRequired: return "recovery"
        case .ready, .busy: return "ready"
        default: return "unavailable"
        }
    }
}

nonisolated enum EventMonitoringState: String, Codable, Sendable {
    case active, idle, paused, recovery, unknown
    static func resolve(readable: Bool, hasRun: Bool, paused: Bool, recovering: Bool) -> Self {
        if recovering { return .recovery }
        guard readable else { return .unknown }
        guard hasRun else { return .idle }
        return paused ? .paused : .active
    }
}

nonisolated enum CameraMonitoringState: String, Codable, Sendable {
    case ready, initializing, unavailable, permissionDenied = "permission_denied", interrupted, recoveryRequired = "recovery_required", unknown
    static func resolve(permissionDenied: Bool, running: Bool, unavailable: Bool, initializing: Bool, interrupted: Bool, recoveryRequired: Bool = false) -> Self {
        if recoveryRequired { return .recoveryRequired }
        if permissionDenied { return .permissionDenied }
        if interrupted { return .interrupted }
        if running { return .ready }
        if unavailable { return .unavailable }
        return initializing ? .initializing : .unknown
    }
}

nonisolated enum GuestMonitoringState: String, Codable, Sendable {
    case idle, guestInProgress = "guest_in_progress", captureWaiting = "capture_waiting", printing
    case recoveryRequired = "recovery_required", unknown
    static func resolve(_ state: BoothSessionState) -> Self {
        switch state {
        case .welcome, .choosingFormat, .thankYou: return .idle
        case .preparingCamera, .cameraReady, .countdown, .capturing, .betweenPhotos, .retaking: return .captureWaiting
        case .connectingToPrinter, .printing: return .printing
        case .recoveryRequired, .error: return .recoveryRequired
        default: return .guestInProgress
        }
    }
}

nonisolated struct GalleryQueueTelemetry: Codable, Equatable, Sendable {
    var pending: Int
    var uploading: Int
    var verifying: Int
    var attention: Int
    var oldestAt: String?
    var activityAt: String?

    init(summaries: [GalleryPendingUploadSummary], activeToken: String?, verifying: Bool, lastActivityAt: Date?) {
        pending = min(100000, summaries.count)
        uploading = activeToken != nil && !verifying ? 1 : 0
        self.verifying = activeToken != nil && verifying ? 1 : 0
        attention = min(100000, summaries.filter(\.needsAttention).count)
        oldestAt = summaries.first?.createdAt
        activityAt = lastActivityAt.map { ISO8601DateFormatter().string(from: $0) }
    }
}

/// Independent observational service: it has no ability to authorize payment, print, change
/// event settings or resolve recovery. No free-form logs, photos, QR payloads or money are sent.
@MainActor final class BoothMonitoring: ObservableObject {
    static let shared = BoothMonitoring()
    @Published private(set) var lastResult = "Monitoring has not been configured."
    @Published private(set) var lastHeartbeat: Date?
    private var task: Task<Void, Never>?
    private var sending = false
    private var supportedVersion: Int?
    private let credentialService = "com.pocketpixels.booth-monitoring"
    var endpoint: String { UserDefaults.standard.string(forKey: "pocketPixels.monitoring.endpoint") ?? "" }

    func configure(endpoint: String, token: String) throws {
        guard let url = URL(string: endpoint), url.scheme == "https", url.host?.hasSuffix(".workers.dev") == true,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              token.count >= 32, token.count <= 256 else { throw SetupFailure("Use the HTTPS monitoring Worker URL and its device-only credential.") }
        let key: [String: Any] = [kSecClass as String:kSecClassGenericPassword, kSecAttrService as String:credentialService, kSecAttrAccount as String:"device-heartbeat"]
        let value: [String: Any] = [kSecValueData as String:Data(token.utf8), kSecAttrAccessible as String:kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(key as CFDictionary,value as CFDictionary)
        if status == errSecItemNotFound { status = SecItemAdd(key.merging(value) { _,new in new } as CFDictionary,nil) }
        guard status == errSecSuccess else { throw SetupFailure("Monitoring credential could not be saved in Keychain.") }
        UserDefaults.standard.set(url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn:"/")),forKey:"pocketPixels.monitoring.endpoint")
        supportedVersion = nil
        lastResult = "Configured. A heartbeat will verify the connection."
    }
    private func token() -> String? {
        let query: [String: Any] = [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:credentialService,kSecAttrAccount as String:"device-heartbeat",kSecReturnData as String:true,kSecMatchLimit as String:kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary,&result)==errSecSuccess,let data=result as? Data else { return nil }
        return String(data:data,encoding:.utf8)
    }
    func start() {
        // Xcode/devicectl provisioning is consumed once into this app's existing Keychain.
        let env = ProcessInfo.processInfo.environment
        if let endpoint=env["MTK_MONITOR_ENDPOINT"], let token=env["MTK_MONITOR_DEVICE_TOKEN"] {
            do { try configure(endpoint:endpoint,token:token) } catch { lastResult=error.localizedDescription }
        }
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.sendHeartbeat()
                try? await Task.sleep(for:.seconds(300))
            }
        }
    }
    func sendHeartbeat() async {
        guard !sending, let token=token(), let base=URL(string:endpoint), !endpoint.isEmpty else { return }
        sending=true; defer { sending=false }
        var request=URLRequest(url:base.appendingPathComponent("v1/heartbeat"),timeoutInterval:10)
        request.httpMethod="POST";request.setValue("Bearer "+token,forHTTPHeaderField:"Authorization")
        request.setValue("application/json",forHTTPHeaderField:"Content-Type")
        do {
            if supportedVersion == nil {
                // Old deployed Workers allowlist the legacy schema. Negotiate before adding fields.
                let healthRequest = URLRequest(url: base.appendingPathComponent("health"), timeoutInterval: 8)
                if let (data, response) = try? await URLSession.shared.data(for: healthRequest),
                   (response as? HTTPURLResponse)?.statusCode == 200,
                   let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    supportedVersion = min(3, max(1, body["telemetryVersion"] as? Int ?? 1))
                }
            }
            let telemetry = snapshot()
            request.httpBody=try JSONEncoder().encode(telemetry.compatible(version: supportedVersion ?? 1))
            var (_,response)=try await URLSession.shared.data(for:request)
            if (response as? HTTPURLResponse)?.statusCode == 422, (supportedVersion ?? 1) > 1 {
                // Code rollback to a legacy Worker cannot silently stop heartbeat enrollment.
                supportedVersion = 1
                request.httpBody = try JSONEncoder().encode(telemetry.legacy())
                (_,response) = try await URLSession.shared.data(for: request)
            }
            guard let response=response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            if response.statusCode==429 { lastResult="Heartbeat cooldown; monitoring remains configured.";return }
            guard response.statusCode==200 else { throw URLError(.badServerResponse) }
            lastHeartbeat=Date();lastResult="Heartbeat received by monitoring Worker."
        } catch { lastResult="Monitoring connection unavailable. The server will detect a stale heartbeat; booth/payment permissions are unchanged." }
    }
    func snapshot() -> BoothTelemetry {
        let operations=EventOperationalState.shared, runs=EventRunStore.shared, acceptance=SessionAcceptanceStore.shared
        let recovery=PaymentRecoveryCoordinator.shared
        let printer=PrinterCoordinator.shared
        var incidents: [String]=[]
        var payment="ready"
        for item in recovery.items {
            switch item.classification {
            case .needsReview, .inconsistent: incidents.append("review");payment="review"
            case .paymentPending where item.checkpoint.lastServerState == "UNKNOWN_RECONCILIATION" && Date().timeIntervalSince(item.checkpoint.createdAt)>180: incidents.append("verification")
            case .paidUnclaimed(verified:true), .claimedNotPrinted(verified:true):
                if !operations.customerSessionActive { incidents.append("paid_blocked") }
            default: break
            }
        }
        // Old uncertain outcomes remain evidence, not a new incident on every heartbeat.
        // The pre-send checkpoint deliberately says printStatusUnknown while a normal send is
        // running. It is not itself an operator-review incident. Durable inspection stays visible.
        let explicitReview = operations.qualificationPrintNeedsInspection
            || PrintOutcomeOutbox.shared?.inspectionEntryIDs.isEmpty == false
            || !recovery.receiptCheckIDs.isEmpty || (!printer.isWorking && operations.hasUnresolvedPrint)
        let bluetooth = PrinterBluetoothService.shared
        let evidenceReadable = operations.recoveryStorageError == nil && PrintOutcomeOutbox.shared != nil
            && PrintOutcomeOutbox.shared?.integrityFault == nil && PrintOutcomeOutbox.shared?.persistenceFailure == nil
            && CheckoutCheckpointStore.shared != nil && CheckoutCheckpointStore.shared?.integrityFault == nil
        let observation = PrinterMonitoringObservation.resolve(mode: printer.preferredMode,
            bluetoothConnected: bluetooth.isConnectedAndReady, bluetoothConnecting: bluetooth.jobState.isWorking && !bluetooth.isTransmitting,
            diagnostic: bluetooth.needsDiagnosticTextTest, wifiConnection: printer.monitoringWiFiConnection,
            busy: printer.isWorking, recovery: printer.requiresRecovery, unresolved: explicitReview,
            evidenceReadable: evidenceReadable)
        if observation.evidence == .unresolved || printer.requiresRecovery { incidents.append("uncertain_print") }
        // Legacy servers still receive their supported vocabulary; no duplicate recovery cause.
        if observation.readiness == .unavailable || observation.readiness == .diagnosticRequired { incidents.append("printer") }
        let storage = !evidenceReadable || acceptance.storageError != nil || runs.storageError != nil || operations.queueError != nil
            || CheckoutCheckpointStore.shared?.integrityFault != nil || PrintOutcomeOutbox.shared?.integrityFault != nil
            || CheckoutCheckpointStore.shared == nil || PrintOutcomeOutbox.shared == nil
        if storage { incidents.append("storage") }
        let paused=acceptance.state.blocked || runs.pendingTransition != nil
        if paused { incidents.append("paused") }
        if CommercialPolicySource.load() == .serverManaged, operations.networkPathStatus != "Online" { payment="unavailable" }
        var value = BoothTelemetry(mode:runs.pendingTransition != nil ? "recovery" : (paused ? "paused" : (RegularBoothMode.isEnabled ? "regular" : "event")),
            network:operations.networkPathStatus=="Online" ? "online" : (operations.networkPathStatus=="Offline" ? "offline" : "unknown"),
            payment:payment,printer:observation.legacyPrinter,storage:storage ? "error" : "ready",
            incidents:Array(Set(incidents)).sorted(),eventReference:runs.operational?.id)
        value.telemetryVersion = 3
        value.printerObservation = observation
        let guestModel = ActiveGuestInteraction.model
        value.guest = guestModel.map { GuestMonitoringState.resolve($0.state) } ?? (operations.customerSessionActive ? .guestInProgress : .unknown)
        let permission = AVCaptureDevice.authorizationStatus(for: .video)
        value.camera = CameraMonitoringState.resolve(permissionDenied: permission == .denied || permission == .restricted,
            running: guestModel?.isCameraRunning == true, unavailable: guestModel?.isCameraUnavailable == true,
            initializing: guestModel?.state == .preparingCamera, interrupted: guestModel?.monitoringCameraInterrupted == true,
            recoveryRequired: guestModel?.monitoringCameraRecoveryRequired == true)
        let scheduler = GalleryUploadScheduler.shared
        value.reportedAt = ISO8601DateFormatter().string(from: Date())
        value.eventState = EventMonitoringState.resolve(readable: runs.storageError == nil && acceptance.storageError == nil,
            hasRun: runs.operational != nil, paused: paused || runs.operational?.status == .paused, recovering: runs.pendingTransition != nil).rawValue
        value.activityAt = operations.lastGuestActivityAt.map { ISO8601DateFormatter().string(from: $0) }
        // Re-read metadata only; no photographs are loaded for monitoring.
        do {
            let queue = try GalleryPendingUploadStore().summaries()
            value.uploads = GalleryQueueTelemetry(summaries: queue, activeToken: scheduler.activeToken,
                verifying: scheduler.phase == .verifying, lastActivityAt: scheduler.lastActivityAt)
        } catch {
            value.storage = "error"
            value.incidents = Array(Set(value.incidents + ["storage"])).sorted()
        }
        return value
    }
}

struct BoothMonitoringView: View {
    @ObservedObject private var monitor=BoothMonitoring.shared
    @State private var endpoint=""
    @State private var credential=""
    @State private var message=""
    var body: some View {
        Form {
            Section("Owner alerts") {
                Text("Private Telegram alerts use a separate monitoring Worker. Only bounded health codes, queue counts, timestamps and an event reference are sent. Monitoring cannot authorize payments or change booth operation.")
                TextField("Monitoring Worker URL",text:$endpoint).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("Device heartbeat credential",text:$credential).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Save Monitoring Connection") {
                    guard OperatorAccessPermit.shared.isAuthorized else { message="Unlock Operator again before configuring monitoring.";return }
                    do { try monitor.configure(endpoint:endpoint,token:credential);credential="";monitor.start();message="Saved in Keychain." }
                    catch { message=error.localizedDescription }
                }
                Button("Send Health Heartbeat") { Task { await monitor.sendHeartbeat() } }
                Text(monitor.lastResult)
                if let date=monitor.lastHeartbeat { LabeledContent("Last received",value:date.formatted()) }
                if !message.isEmpty { Text(message) }
            }
            Section("Timing") { Text("A heartbeat is sent every five minutes while the app runs in the foreground. The server checks for overdue contact after ten minutes during a last-reported active event or fifteen minutes while idle, on its next five-minute scheduled check. iPadOS may suspend background apps; keep Carlo open for booth operation.") }
        }.navigationTitle("Remote Monitoring").onAppear { endpoint=monitor.endpoint }
    }
}
