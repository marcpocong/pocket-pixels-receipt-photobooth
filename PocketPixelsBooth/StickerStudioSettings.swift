//
//  StickerStudioSettings.swift
//  PocketPixelsBooth
//
//  Operator-controlled, runtime-persisted settings for the optional guest Sticker Studio step.
//  The master switch defaults OFF so existing installations keep the exact production flow
//  until an operator deliberately enables it. A session freezes these settings when it starts;
//  edits made in the operator UI apply to the next guest.
//

import Foundation
import Security

nonisolated enum StickerCategory: String, Codable, CaseIterable, Sendable, Identifiable {
    case classic
    case cute
    case hearts
    case doodles
    case reactions
    case birthday, celebration, retro, travel, everyday, madeToKeep
    case event
    case online

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .classic: "Classic"
        case .cute: "Cute"
        case .hearts: "Hearts"
        case .doodles: "Doodles"
        case .reactions: "Reactions"
        case .birthday: "Birthday"
        case .celebration: "Celebrate"
        case .retro: "Retro"
        case .travel: "Adventure"
        case .everyday: "Everyday"
        case .madeToKeep: "Made to Keep"
        case .event: "Event"
        case .online: "Trending"
        }
    }

    /// Operator-facing name; "Reactions/Memes" makes the imported-meme destination explicit.
    var operatorDisplayName: String {
        switch self {
        case .reactions: "Reactions / Memes"
        case .online: "Online / Trending"
        default: displayName
        }
    }

    /// Categories an operator can assign to an imported sticker.
    static let assignableToImports: [StickerCategory] = allCases.filter { $0 != .online }
}

/// The operator's explicit confirmation that their content licence covers printing third-party
/// online media on paid physical keepsakes. Never inferred from an API key being present.
nonisolated struct OnlineStickerRightsAcknowledgement: Codable, Equatable, Sendable {
    static let currentStatementVersion = 1
    static let statement = "I confirm our GIPHY agreement (or other written licence) permits printing third-party GIFs and stickers on paid physical photo receipts, and we will display GIPHY attribution."

    var acknowledgedAt: Date
    var statementVersion: Int = currentStatementVersion
    var provider: String = GiphyStickerProvider.providerIdentifier

    var isCurrent: Bool { statementVersion == Self.currentStatementVersion }
}

nonisolated struct StickerStudioSettings: Codable, Equatable, Sendable {
    /// 2: native Unicode emoji became the primary guest collection and the original artwork
    /// became an optional legacy source.
    static let currentSchemaVersion = 2
    static let guestStickerLimitRange = 1...10
    static let defaultGuestStickerLimit = 6
    /// Printed edge length bounds for one sticker, in printer dots (8 dots per mm).
    static let minimumPrintedDotsRange = 48...160
    static let defaultMinimumPrintedDots = 72

    var schemaVersion = currentSchemaVersion
    /// Master switch. OFF means the guest never sees, loads or fetches anything sticker related.
    var isEnabled = false
    /// Native Unicode emoji drawn by the system font: the primary guest collection.
    var emojiCollectionEnabled = true
    /// The original Made to Keep artwork. Retired from the default palette; operators may opt in.
    var builtInStickersEnabled = false
    var operatorCollectionEnabled = true
    /// Requested by the operator; only effective with a stored API key AND a rights acknowledgement.
    var onlineDiscoveryEnabled = false
    var onlineRightsAcknowledgement: OnlineStickerRightsAcknowledgement?
    /// Categories the operator hid from guests. Empty categories are hidden automatically.
    var hiddenCategories: Set<StickerCategory> = []
    var guestStickerLimit = defaultGuestStickerLimit
    var minimumPrintedStickerDots = defaultMinimumPrintedDots

    static let `default` = StickerStudioSettings()

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let storedSchema = (try? container.decode(Int.self, forKey: .schemaVersion)) ?? 1
        schemaVersion = Self.currentSchemaVersion
        isEnabled = (try? container.decode(Bool.self, forKey: .isEnabled)) ?? false
        if storedSchema < 2 {
            // Schema 1 had no emoji collection and showed the original artwork by default.
            // Emoji now lead; the artwork stays installed as an optional legacy source.
            emojiCollectionEnabled = true
            builtInStickersEnabled = false
        } else {
            emojiCollectionEnabled = (try? container.decode(Bool.self, forKey: .emojiCollectionEnabled)) ?? true
            builtInStickersEnabled = (try? container.decode(Bool.self, forKey: .builtInStickersEnabled)) ?? false
        }
        operatorCollectionEnabled = (try? container.decode(Bool.self, forKey: .operatorCollectionEnabled)) ?? true
        onlineDiscoveryEnabled = (try? container.decode(Bool.self, forKey: .onlineDiscoveryEnabled)) ?? false
        onlineRightsAcknowledgement = try? container.decodeIfPresent(OnlineStickerRightsAcknowledgement.self, forKey: .onlineRightsAcknowledgement)
        // Unknown category names from a newer build are dropped instead of failing the whole decode.
        let hiddenNames = (try? container.decode([String].self, forKey: .hiddenCategories)) ?? []
        hiddenCategories = Set(hiddenNames.compactMap(StickerCategory.init(rawValue:)))
        guestStickerLimit = (try? container.decode(Int.self, forKey: .guestStickerLimit)) ?? Self.defaultGuestStickerLimit
        minimumPrintedStickerDots = (try? container.decode(Int.self, forKey: .minimumPrintedStickerDots)) ?? Self.defaultMinimumPrintedDots
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(emojiCollectionEnabled, forKey: .emojiCollectionEnabled)
        try container.encode(builtInStickersEnabled, forKey: .builtInStickersEnabled)
        try container.encode(operatorCollectionEnabled, forKey: .operatorCollectionEnabled)
        try container.encode(onlineDiscoveryEnabled, forKey: .onlineDiscoveryEnabled)
        try container.encodeIfPresent(onlineRightsAcknowledgement, forKey: .onlineRightsAcknowledgement)
        try container.encode(hiddenCategories.map(\.rawValue).sorted(), forKey: .hiddenCategories)
        try container.encode(guestStickerLimit, forKey: .guestStickerLimit)
        try container.encode(minimumPrintedStickerDots, forKey: .minimumPrintedStickerDots)
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, isEnabled, emojiCollectionEnabled, builtInStickersEnabled, operatorCollectionEnabled
        case onlineDiscoveryEnabled, onlineRightsAcknowledgement, hiddenCategories
        case guestStickerLimit, minimumPrintedStickerDots
    }

    /// Clamps every bound and drops an online request that has no current rights acknowledgement.
    func normalized() -> StickerStudioSettings {
        var copy = self
        copy.schemaVersion = Self.currentSchemaVersion
        copy.guestStickerLimit = min(max(guestStickerLimit, Self.guestStickerLimitRange.lowerBound), Self.guestStickerLimitRange.upperBound)
        copy.minimumPrintedStickerDots = min(max(minimumPrintedStickerDots, Self.minimumPrintedDotsRange.lowerBound), Self.minimumPrintedDotsRange.upperBound)
        if copy.onlineRightsAcknowledgement?.isCurrent != true {
            copy.onlineRightsAcknowledgement = nil
            copy.onlineDiscoveryEnabled = false
        }
        copy.hiddenCategories.remove(.online)
        return copy
    }

    /// Whether any source could supply stickers. Online alone is only a source when ready.
    func hasAnyLocalSource() -> Bool {
        emojiCollectionEnabled || builtInStickersEnabled || operatorCollectionEnabled
    }

    func onlineAvailability(hasCredential: Bool) -> OnlineStickerAvailability {
        guard onlineDiscoveryEnabled else { return .disabled }
        guard hasCredential else { return .missingCredentials }
        guard onlineRightsAcknowledgement?.isCurrent == true else { return .rightsNotAcknowledged }
        return .ready
    }
}

nonisolated enum OnlineStickerAvailability: Equatable, Sendable {
    case disabled
    case missingCredentials
    case rightsNotAcknowledged
    case ready

    var isReady: Bool { self == .ready }

    static let unavailableMessage = "Online catalog unavailable — use built-in or approved stickers"

    var operatorDescription: String {
        switch self {
        case .disabled: Self.unavailableMessage
        case .missingCredentials: "Online catalog unavailable — add a GIPHY API key first."
        case .rightsNotAcknowledged: "Online catalog unavailable — confirm commercial print rights first."
        case .ready: "Online catalog ready. Results are safe-search (rating G) and print as a still frame."
        }
    }
}

/// What one guest session is allowed to do, frozen when the session starts.
nonisolated struct StickerStudioSessionConfiguration: Equatable, Sendable {
    let settings: StickerStudioSettings
    let onlineReady: Bool

    static let disabled = StickerStudioSessionConfiguration(settings: .default, onlineReady: false)

    var isGuestStepEnabled: Bool {
        settings.isEnabled && settings.hasAnyLocalSource()
    }

    @MainActor
    static func current(
        settings: StickerStudioSettings = StickerStudioSettingsStore.load(),
        credentials: OnlineStickerCredentialStoring = KeychainOnlineStickerCredentialStore()
    ) -> StickerStudioSessionConfiguration {
        let normalized = settings.normalized()
        guard normalized.isEnabled else { return .disabled }
        // Legacy online preferences and credentials remain stored, but the static studio
        // never reads a credential, constructs a provider, or enables an online guest source.
        return StickerStudioSessionConfiguration(settings: normalized, onlineReady: false)
    }
}

/// Versioned, normalized settings in UserDefaults (a few hundred bytes — never image data).
enum StickerStudioSettingsStore {
    nonisolated static let storageKey = "madeToKeep.stickerStudio.settings.v1"
    static let didChangeNotification = Notification.Name("madeToKeep.stickerStudio.didChange")

    /// Missing or corrupt data falls back to the safe default (master switch OFF).
    nonisolated static func load(defaults: UserDefaults = .standard) -> StickerStudioSettings {
        guard let data = defaults.data(forKey: storageKey),
              let settings = try? JSONDecoder().decode(StickerStudioSettings.self, from: data) else {
            return .default
        }
        return settings.normalized()
    }

    static func save(_ settings: StickerStudioSettings, defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(settings.normalized()) else { return }
        defaults.set(data, forKey: storageKey)
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }
}

// MARK: - Online credentials

nonisolated protocol OnlineStickerCredentialStoring: Sendable {
    func loadAPIKey() -> String?
    func saveAPIKey(_ key: String) throws
    func deleteAPIKey()
}

nonisolated extension OnlineStickerCredentialStoring {
    func hasAPIKey() -> Bool { loadAPIKey()?.isEmpty == false }

    /// Never reveals the key; at most its last four characters.
    func redactedDescription() -> String {
        guard let key = loadAPIKey(), !key.isEmpty else { return "No API key saved" }
        return "Saved key ending in \(key.suffix(4))"
    }
}

nonisolated enum OnlineStickerCredentialError: Error, LocalizedError {
    case invalidKey
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidKey: "Enter the API key exactly as issued (letters and numbers only)."
        case .keychain(let status): "The key could not be saved (status \(status))."
        }
    }
}

/// The provider key lives in the device keychain, never in source, UserDefaults or logs.
nonisolated struct KeychainOnlineStickerCredentialStore: OnlineStickerCredentialStoring {
    private let service = "com.madetokeep.sticker-studio"
    private let account = "giphy-api-key"

    static func isPlausibleKey(_ key: String) -> Bool {
        (16...128).contains(key.count) && key.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    func loadAPIKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8) else { return nil }
        return key
    }

    func saveAPIKey(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isPlausibleKey(trimmed), let data = trimmed.data(using: .utf8) else {
            throw OnlineStickerCredentialError.invalidKey
        }
        deleteAPIKey()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw OnlineStickerCredentialError.keychain(status) }
    }

    func deleteAPIKey() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// Test double and preview store; holds the key only in memory.
nonisolated final class InMemoryOnlineStickerCredentialStore: OnlineStickerCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var key: String?

    init(key: String? = nil) { self.key = key }

    func loadAPIKey() -> String? { lock.withLock { key } }

    func saveAPIKey(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard KeychainOnlineStickerCredentialStore.isPlausibleKey(trimmed) else {
            throw OnlineStickerCredentialError.invalidKey
        }
        lock.withLock { self.key = trimmed }
    }

    func deleteAPIKey() { lock.withLock { key = nil } }
}
