import Foundation

/// Operational mode is separate from commercial policy, reusable artwork and historical runs.
nonisolated enum BoothOperatingMode: String, Codable, Sendable { case regular, event }

nonisolated struct RegularBoothSettings: Codable, Equatable, Sendable {
    var formats = BoothFormat.allCases.map(\.rawValue)
    var defaultCopies = 1
    var maxCopies = 10
    var guestCopyChoice = true

    /// Optional for backwards compatibility with existing copy/format defaults.
    var receiptProfile: EventProfile?
    static let storageKey = "pocketPixels.regularBooth.defaults.v1"

    var validationMessage: String? {
        if let reason = policy.validationMessage { return reason }
        if formats.contains(where: { BoothFormat(rawValue: $0) == nil }) {
            return "A saved format is no longer supported. Review available formats before saving."
        }
        return nil
    }

    static func loadIssue(defaults: UserDefaults = .standard) -> String? {
        guard let data = defaults.data(forKey: storageKey) else { return nil }
        guard let settings = try? JSONDecoder().decode(Self.self, from: data) else {
            return "Saved Regular Booth defaults could not be read. The original is retained. Review these replacement defaults and save when ready."
        }
        return settings.validationMessage
    }

    static func loadForSession(defaults: UserDefaults = .standard) throws -> Self {
        if let issue = loadIssue(defaults: defaults) { throw SetupFailure(issue) }
        return load(defaults: defaults)
    }

    var profile: EventProfile { receiptProfile ?? .pocketPixelsDefault }

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
        guard let data = defaults.data(forKey: storageKey),
              let settings = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        // Keep readable invalid values visible for operator repair; never silently reset them.
        return settings
    }
    static func save(_ value: Self, defaults: UserDefaults = .standard) throws {
        if let reason = value.validationMessage { throw SetupFailure(reason) }
        let data = try JSONEncoder().encode(value)
        if loadIssue(defaults: defaults) != nil, let original = defaults.data(forKey: storageKey) {
            // Preserve each replaced invalid original for support, including unreadable bytes.
            defaults.set(original, forKey: storageKey + ".preserved." + UUID().uuidString)
        }
        defaults.set(data, forKey: storageKey)
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
