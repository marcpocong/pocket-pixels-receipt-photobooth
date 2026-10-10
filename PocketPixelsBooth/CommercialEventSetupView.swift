import SwiftUI

/// Chooses where the booth's charging policy comes from.
///
/// - Private / Prepaid (this iPad): the legacy path. Guests are never charged and the Payments
///   Worker is not needed. Only copy limits and formats are edited here.
/// - Paid events (server-managed): price, payment methods, formats, copies and lifecycle come
///   only from the server's active policy revision. Nothing on this screen can change them.
struct CommercialEventSetupView: View {
    @State private var source = CommercialPolicySource.load()
    @State private var savedRun: CommercialEventRun
    @State private var draft: CommercialEventRun
    @State private var statusMessage = ""
    @State private var serverStatus: ServerBoothStatus?
    @State private var isCheckingServer = false

    init() {
        // Load once: the legacy default is time-stamped, so two loads would never compare equal.
        let run = CommercialEventRunStore.load()
        _savedRun = State(initialValue: run)
        _draft = State(initialValue: run)
    }

    var body: some View {
        Form {
            Section {
                Picker("Charging source", selection: $source) {
                    ForEach(CommercialPolicySource.allCases, id: \.self) { value in
                        Text(value.displayName).tag(value)
                    }
                }
                .onChange(of: source) { _, newValue in
                    CommercialPolicySource.save(newValue)
                    statusMessage = newValue == .serverManaged
                        ? "New guest sessions will use the server's active event."
                        : "New guest sessions are Private / Prepaid and are never charged."
                    if newValue == .serverManaged { Task { await checkServer() } }
                }
                Text("Charging is independent from Branding Mode and receipt design. Changing it never affects galleries or event designs.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Guest Charging")
            }

            if source == .localPrepaid {
                localPrepaidSections
            } else {
                serverSections
            }

            if !statusMessage.isEmpty {
                Section {
                    Text(statusMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Booth Charging Mode")
        .task {
            if source == .serverManaged { await checkServer() }
        }
    }

    // MARK: Local prepaid

    @ViewBuilder private var localPrepaidSections: some View {
        Section("Private / Prepaid Copies") {
            LabeledContent("Status", value: savedRun.lifecycle == .active ? "Accepting sessions" : savedRun.lifecycle.rawValue.capitalized)
            Stepper("Maximum copies: \(draft.activePolicy.maxCopies)", value: maxCopiesBinding, in: PaymentPolicySnapshot.copyRange)
            Stepper("Default copies: \(draft.activePolicy.defaultCopies)", value: $draft.activePolicy.defaultCopies, in: 1...draft.activePolicy.maxCopies)
            Toggle("Guests may choose copies", isOn: $draft.activePolicy.prepaidGuestCopyChoice)
        }

        Section("Formats") {
            ForEach(BoothFormat.allCases, id: \.self) { format in
                Toggle(format.displayName, isOn: Binding(
                    get: { draft.activePolicy.supports(format) },
                    set: { setFormat(format, enabled: $0) }
                ))
            }
        }

        Section {
            Button("Save Prepaid Settings") { saveLocal(lifecycle: .active) }
                .disabled(draft.activePolicy.validationMessage != nil || draft == savedRun)
            if savedRun.lifecycle == .active {
                Button("Pause New Sessions") { saveLocal(lifecycle: .paused) }
            } else {
                Button("Resume Sessions") { saveLocal(lifecycle: .active) }
            }
            if let message = draft.activePolicy.validationMessage {
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            } else if draft != savedRun {
                Label("Unsaved changes", systemImage: "pencil.circle").foregroundStyle(.orange)
            }
        } footer: {
            Text("Paid pricing is never set on this iPad. Use Paid events (server-managed) to charge guests.")
        }
    }

    private var maxCopiesBinding: Binding<Int> {
        Binding(
            get: { draft.activePolicy.maxCopies },
            set: { value in
                draft.activePolicy.maxCopies = value
                draft.activePolicy.defaultCopies = min(draft.activePolicy.defaultCopies, value)
            }
        )
    }

    private func setFormat(_ format: BoothFormat, enabled: Bool) {
        var values = draft.activePolicy.supportedFormatRawValues
        if enabled {
            if !values.contains(format.rawValue) { values.append(format.rawValue) }
        } else {
            values.removeAll { $0 == format.rawValue }
        }
        draft.activePolicy.supportedFormatRawValues = values
    }

    private func saveLocal(lifecycle: CommercialEventLifecycle) {
        var run = draft
        // A legacy local paid configuration can never be republished; force prepaid.
        run.activePolicy.commercialMode = .privatePrepaid
        run.activePolicy.unitPriceCentavos = 0
        run.activePolicy.cashEnabled = false
        run.activePolicy.qrPhEnabled = false
        run.activePolicy.offlineValidUntil = nil
        run.lifecycle = lifecycle
        run.updatedAt = Date()
        do {
            try CommercialEventRunStore.publish(run)
            savedRun = run
            draft = run
            statusMessage = lifecycle == .active ? "Saved on this iPad. New sessions use these prepaid settings." : "New sessions are paused on this iPad."
        } catch {
            statusMessage = "Not saved: \(error.localizedDescription)"
        }
    }

    // MARK: Server-managed

    @ViewBuilder private var serverSections: some View {
        Section("Server Event (read-only here)") {
            if isCheckingServer {
                ProgressView("Checking the payments server…")
            } else if let serverStatus {
                ServerBoothStatusRows(status: serverStatus)
            } else {
                Text("Not checked yet.").foregroundStyle(.secondary)
            }
            Button("Check Again") { Task { await checkServer() } }
                .disabled(isCheckingServer)
            NavigationLink("Manage Server Events & Sales") { PaymentsOperatorView() }
        }
    }

    private func checkServer() async {
        isCheckingServer = true
        serverStatus = await ServerBoothStatus.load()
        isCheckingServer = false
    }
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
            LabeledContent("Methods", value: [event.qrphEnabled ? "QR Ph" : nil, event.cashEnabled ? "Cash (self-reported)" : nil].compactMap { $0 }.joined(separator: ", "))
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
