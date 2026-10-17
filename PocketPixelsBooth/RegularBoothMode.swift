import Foundation

/// Operational mode is separate from commercial policy, reusable artwork and historical runs.
nonisolated enum BoothOperatingMode: String, Codable, Sendable { case regular, event }

nonisolated struct RegularBoothSettings: Codable, Equatable, Sendable {
    var formats = BoothFormat.allCases.map(\.rawValue)
    var defaultCopies = 1
    var maxCopies = 10
    var guestCopyChoice = true

    var policy: PaymentPolicySnapshot {
        var value = PaymentPolicySnapshot.legacyPrepaid
        value.revisionID = "regular-booth-v1"
        value.supportedFormatRawValues = formats
        value.defaultCopies = defaultCopies; value.maxCopies = maxCopies
        value.prepaidGuestCopyChoice = guestCopyChoice
        return value
    }
    var configuration: CommercialEventRun {
        // A presentation adapter for the existing capture/copy pipeline, never a persisted event.
        .init(id: "", name: "Regular Booth", venue: "", lifecycle: .active, activePolicy: policy, updatedAt: Date())
    }
    static func load(defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: "pocketPixels.regularBooth.defaults.v1"),
              let settings = try? JSONDecoder().decode(Self.self, from: data), settings.policy.validationMessage == nil,
              settings.formats.allSatisfy({ BoothFormat(rawValue: $0) != nil }) else { return Self() }
        return settings
    }
    static func save(_ value: Self, defaults: UserDefaults = .standard) throws {
        guard value.policy.validationMessage == nil, value.formats.allSatisfy({ BoothFormat(rawValue: $0) != nil }) else { throw SetupFailure("Choose valid Regular Booth formats and copies.") }
        defaults.set(try JSONEncoder().encode(value), forKey: "pocketPixels.regularBooth.defaults.v1")
    }
}

@MainActor enum RegularBoothMode {
    static var isEnabled: Bool {
        isEnabled(acceptance: .shared, runs: .shared)
    }
    static func isEnabled(acceptance: SessionAcceptanceStore, runs: EventRunStore) -> Bool {
        acceptance.storageError == nil && !runs.historyUnreadable && runs.pendingTransition == nil
            && acceptance.state.boothMode == .regular && acceptance.state.mode == .localPrepaid
            && acceptance.state.eventID == nil && acceptance.state.startingEventID == nil && runs.current == nil
    }

    /// Fresh/legacy unbound prepaid installs can migrate locally. Any paid binding, pause,
    /// applied event, history pointer or recovery obligation requires an explicit operator action.
    static func bootstrapIfSafe(acceptance: SessionAcceptanceStore = .shared, runs: EventRunStore = .shared,
                                source: CommercialPolicySource = CommercialPolicySource.load(),
                                local: CommercialEventRun = CommercialEventRunStore.load(),
                                library: EventDesignLibraryStore = .shared,
                                recoveryReason: @MainActor () -> String? = { SessionSetupSafety.blockingReason }) throws {
        guard acceptance.state.boothMode == nil, acceptance.storageError == nil, !runs.historyUnreadable,
              !acceptance.state.blocked, acceptance.state.eventID == nil, acceptance.state.serverBinding == nil, acceptance.state.startingEventID == nil,
              source == .localPrepaid, local.lifecycle == .active, local.activePolicy.commercialMode == .privatePrepaid,
              local.activePolicy.validationMessage == nil, runs.current == nil, runs.pendingTransition == nil,
              library.storageError == nil, library.library.appliedEventID == nil,
              !library.library.appliedEventModeEnabled, recoveryReason() == nil else { return }
        try acceptance.save(.init(mode: .localPrepaid, boothMode: .regular))
    }
}
