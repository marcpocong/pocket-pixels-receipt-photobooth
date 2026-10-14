import SwiftUI

/// Legacy restored routes use the unified staged workflow.
struct CommercialEventSetupView: View {
    var body: some View { SessionSetupView() }
}

/// What a guest session would use right now, as reported by the server and the stored offline grant.
struct ServerBoothStatus: Equatable {
    var paired: Bool
    var environment: String
    var deviceID: String?
    var event: ServerEventPolicy?
    var inactiveDescription: String?
    var offlineStatus: String
    var offlineExpiresAt: Date?
    var error: String?

    @MainActor static func load() async -> ServerBoothStatus {
        guard let configuration = PaymentsConfiguration.current() else {
            return ServerBoothStatus(paired: false, environment: "NOT CONFIGURED", offlineStatus: "Unavailable", error: "Pair this iPad under Manage Server Events & Sales.")
        }
        var status = ServerBoothStatus(paired: true, environment: configuration.environment.uppercased(), offlineStatus: "Unavailable")
        let verifier = OfflinePolicyVerifier.bundled(environment: configuration.environment)
        do {
            let response = try await PaymentsAPIClient(configuration: configuration).activeEvent()
            try? OfflineGrantStore.recordServerContact(device: response.device, environment: configuration.environment, serverTime: response.serverTime, grant: response.offlinePolicy)
            status.deviceID = response.device.id
            status.event = response.event
            status.inactiveDescription = response.inactiveEvent.map { "\($0.name) — \($0.lifecycle)" }
            status.offlineStatus = response.offlinePolicyStatus.map(Self.describe) ?? "Unavailable"
        } catch {
            status.error = "Server unreachable or refused: \(error.localizedDescription)"
        }
        if let record = OfflineGrantStore.load(), let grant = record.grant {
            do {
                let payload = try verifier.verify(grant, deviceID: record.deviceID, accountID: record.accountID, now: Date(), trustedClockFloor: record.trustedClockFloor)
                status.offlineStatus = "Valid signed policy (revision \(payload.revision))"
                status.offlineExpiresAt = payload.expiresAt
            } catch {
                status.offlineStatus = error.localizedDescription
            }
        } else if verifier.trustedKeys.isEmpty {
            status.offlineStatus = OfflinePolicyError.noTrustedKeys.localizedDescription
        }
        return status
    }

    private static func describe(_ code: String) -> String {
        switch code {
        case "issued": "Signed policy issued"
        case "offline_cash_not_enabled": "Offline cash not enabled for this event"
        case "offline_signing_not_configured": "Server signing key not configured"
        case "offline_window_elapsed": "Offline window has ended"
        case "no_active_event": "No active event"
        default: code
        }
    }
}

struct ServerBoothStatusRows: View {
    let status: ServerBoothStatus

    var body: some View {
        LabeledContent("Environment", value: status.environment)
        LabeledContent("Paired device", value: status.deviceID ?? (status.paired ? "Unknown" : "Not paired"))
        if let event = status.event {
            LabeledContent("Active event", value: event.name)
            LabeledContent("Event ID", value: event.id)
            LabeledContent("Policy revision", value: "\(event.revision)")
            LabeledContent("Charging", value: event.commercialMode == .payPerPrint ? "\(PHPPriceFormatter.string(centavos: event.unitPriceCentavos)) per copy" : "Private / Prepaid")
            LabeledContent("Methods", value: [event.qrphEnabled ? "QR Ph" : nil, event.cashEnabled ? "Cash (attendant confirmed)" : nil].compactMap { $0 }.joined(separator: ", "))
        } else {
            LabeledContent("Active event", value: status.inactiveDescription ?? "None — guests cannot start paid sessions")
        }
        LabeledContent("Offline cash", value: status.offlineStatus)
        if let expires = status.offlineExpiresAt {
            LabeledContent("Offline valid until") { Text(expires, style: .time) }
        }
        if let error = status.error {
            Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
        }
    }
}
