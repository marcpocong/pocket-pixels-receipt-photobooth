import SwiftUI

struct CommercialEventSetupView: View {
    @State private var savedRun = CommercialEventRunStore.load()
    @State private var draft = CommercialEventRunStore.loadDraft()
    @State private var statusMessage = "Commercial settings loaded."
    @State private var showingEndConfirmation = false

    var body: some View {
        Form {
            Section("Commercial Mode") {
                LabeledContent("Status", value: savedRun.lifecycle.rawValue)
                Picker("Guest charging", selection: $draft.activePolicy.commercialMode) {
                    ForEach(CommercialEventMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                Text("Commercial mode is independent from Branding Mode and receipt design.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Event") {
                TextField("Event name", text: $draft.name)
                TextField("Venue", text: $draft.venue)
            }

            if draft.activePolicy.commercialMode == .payPerPrint {
                Section("Price and Payment") {
                    TextField(
                        "Price per complete copy (centavos)",
                        value: $draft.activePolicy.unitPriceCentavos,
                        format: .number
                    )
                    .keyboardType(.numberPad)
                    Stepper(
                        "Maximum copies: \(draft.activePolicy.maxCopies)",
                        value: $draft.activePolicy.maxCopies,
                        in: PaymentPolicySnapshot.copyRange
                    )
                    Stepper(
                        "Default copies: \(draft.activePolicy.defaultCopies)",
                        value: $draft.activePolicy.defaultCopies,
                        in: 1...draft.activePolicy.maxCopies
                    )
                    Toggle("QR Ph", isOn: $draft.activePolicy.qrPhEnabled)
                    Toggle("Cash — guest self-reported", isOn: $draft.activePolicy.cashEnabled)
                    if let message = draft.activePolicy.validationMessage {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            } else {
                Section("Private / Prepaid Copies") {
                    Stepper(
                        "Default copies: \(draft.activePolicy.defaultCopies)",
                        value: $draft.activePolicy.defaultCopies,
                        in: 1...draft.activePolicy.maxCopies
                    )
                    Stepper(
                        "Maximum copies: \(draft.activePolicy.maxCopies)",
                        value: $draft.activePolicy.maxCopies,
                        in: PaymentPolicySnapshot.copyRange
                    )
                    Toggle("Guests may choose copies", isOn: $draft.activePolicy.prepaidGuestCopyChoice)
                }
            }

            Section("Formats") {
                ForEach(BoothFormat.allCases, id: \.self) { format in
                    Toggle(
                        format.displayName,
                        isOn: Binding(
                            get: { draft.activePolicy.supports(format) },
                            set: { enabled in setFormat(format, enabled: enabled) }
                        )
                    )
                }
            }

            Section("Offline Cash") {
                DatePicker(
                    "Cached policy valid until",
                    selection: Binding(
                        get: { draft.activePolicy.offlineValidUntil ?? Date().addingTimeInterval(12 * 60 * 60) },
                        set: { draft.activePolicy.offlineValidUntil = $0 }
                    )
                )
                Text("Offline cash works only on a previously provisioned device while this cached policy remains valid. QR Ph always requires internet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Publish") {
                Button("Save Draft") { saveDraft() }
                Button("Activate") { transition(to: .active) }
                    .disabled(draft.activePolicy.validationMessage != nil)
                if savedRun.lifecycle == .active {
                    Button("Pause New Sessions") { transition(to: .paused) }
                } else if savedRun.lifecycle == .paused {
                    Button("Resume") { transition(to: .active) }
                }
                if savedRun.lifecycle == .active || savedRun.lifecycle == .paused {
                    Button("End Event", role: .destructive) { showingEndConfirmation = true }
                }
                Text(statusMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Commercial Event")
        .confirmationDialog("End this event?", isPresented: $showingEndConfirmation) {
            Button("End Event", role: .destructive) { transition(to: .ended) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("No new sessions can start. Existing paid entitlements remain recoverable.")
        }
    }

    private func setFormat(_ format: BoothFormat, enabled: Bool) {
        var values = draft.activePolicy.supportedFormatRawValues
        if enabled {
            if !values.contains(format.rawValue) { values.append(format.rawValue) }
        } else {
            values.removeAll { $0 == format.rawValue }
        }
        draft.activePolicy = replacingPolicy(supportedFormats: values)
    }

    private func saveDraft() {
        draft.lifecycle = .draft
        draft.updatedAt = Date()
        do {
            try CommercialEventRunStore.saveDraft(draft)
            statusMessage = "Draft saved. Guests remain on the last explicitly active configuration."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func transition(to lifecycle: CommercialEventLifecycle) {
        guard lifecycle != .active || draft.activePolicy.validationMessage == nil else {
            statusMessage = draft.activePolicy.validationMessage ?? "Configuration is invalid."
            return
        }
        draft.lifecycle = lifecycle
        draft.updatedAt = Date()
        do {
            try CommercialEventRunStore.publish(draft)
            savedRun = draft
            statusMessage = "Event is now \(lifecycle.rawValue)."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func replacingPolicy(supportedFormats: [String]) -> PaymentPolicySnapshot {
        PaymentPolicySnapshot(
            revisionID: draft.activePolicy.revisionID,
            revision: draft.activePolicy.revision,
            commercialMode: draft.activePolicy.commercialMode,
            unitPriceCentavos: draft.activePolicy.unitPriceCentavos,
            maxCopies: draft.activePolicy.maxCopies,
            defaultCopies: min(draft.activePolicy.defaultCopies, draft.activePolicy.maxCopies),
            cashEnabled: draft.activePolicy.cashEnabled,
            qrPhEnabled: draft.activePolicy.qrPhEnabled,
            prepaidGuestCopyChoice: draft.activePolicy.prepaidGuestCopyChoice,
            supportedFormatRawValues: supportedFormats,
            offlineValidUntil: draft.activePolicy.offlineValidUntil
        )
    }
}
