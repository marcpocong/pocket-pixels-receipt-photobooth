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
}

/// Independent observational service: it has no ability to authorize payment, print, change
/// event settings or resolve recovery. No free-form logs, photos, QR payloads or money are sent.
@MainActor final class BoothMonitoring: ObservableObject {
    static let shared = BoothMonitoring()
    @Published private(set) var lastResult = "Monitoring has not been configured."
    @Published private(set) var lastHeartbeat: Date?
    private var task: Task<Void, Never>?
    private var sending = false
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
            request.httpBody=try JSONEncoder().encode(snapshot())
            let (_,response)=try await URLSession.shared.data(for:request)
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
        let uncertain=operations.hasUnresolvedPrint || recovery.outboxSummary.uncertain>0
        if uncertain { incidents.append("uncertain_print") }
        if printer.operatorState == .unresolved || printer.operatorState == .disconnected || printer.operatorState == .awaitingTest { incidents.append("printer") }
        let storage=acceptance.storageError != nil || runs.storageError != nil || operations.queueError != nil
            || CheckoutCheckpointStore.shared?.integrityFault != nil || PrintOutcomeOutbox.shared?.integrityFault != nil
            || CheckoutCheckpointStore.shared == nil || PrintOutcomeOutbox.shared == nil
        if storage { incidents.append("storage") }
        let paused=acceptance.state.blocked || runs.pendingTransition != nil
        if paused { incidents.append("paused") }
        if CommercialPolicySource.load() == .serverManaged, operations.networkPathStatus != "Online" { payment="unavailable" }
        return BoothTelemetry(mode:runs.pendingTransition != nil ? "recovery" : (paused ? "paused" : (RegularBoothMode.isEnabled ? "regular" : "event")),
            network:operations.networkPathStatus=="Online" ? "online" : (operations.networkPathStatus=="Offline" ? "offline" : "unknown"),
            payment:payment,printer:uncertain ? "uncertain" : (printer.requiresRecovery ? "recovery" : printer.operatorState.telemetryValue),storage:storage ? "error" : "ready",
            incidents:Array(Set(incidents)).sorted(),eventReference:runs.operational?.id)
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
                Text("Private Telegram alerts use a separate monitoring Worker. Only fixed health codes and an event reference are sent. Monitoring cannot authorize payments or change booth operation.")
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
            Section("Timing") { Text("A heartbeat is sent every five minutes while the app runs in the foreground. After fifteen minutes without one, the server raises an offline incident on its next scheduled check. iPadOS may suspend background apps; keep Carlo open for booth operation.") }
        }.navigationTitle("Remote Monitoring").onAppear { endpoint=monitor.endpoint }
    }
}
