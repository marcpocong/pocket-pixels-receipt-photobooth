import Foundation

/// Digital gallery preference, independent of physical receipt print options.
nonisolated enum GalleryReceiptStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case shareFriendly, asPrinted
    var id: String { rawValue }
    var title: String {
        switch self {
        case .shareFriendly: "Share-Friendly"
        case .asPrinted: "Same as Physical Print"
        }
    }
    static func resolve(device: Self, profile: EventProfile) -> Self {
        profile.galleryReceiptStyleOverride ?? device
    }
}

nonisolated enum GalleryReceiptSettingsStore {
    static let key = "madeToKeep.customerGallery.defaultReceiptStyle"
    static func load(defaults: UserDefaults = .standard) -> GalleryReceiptStyle {
        defaults.string(forKey: key).flatMap(GalleryReceiptStyle.init(rawValue:)) ?? .shareFriendly
    }
    static func loadIssue(defaults: UserDefaults = .standard) -> String? {
        guard let raw = defaults.string(forKey: key), GalleryReceiptStyle(rawValue: raw) == nil else { return nil }
        return "The saved digital receipt style is not recognized. Review the replacement below; the original is retained when you save."
    }
    static func save(_ style: GalleryReceiptStyle, defaults: UserDefaults = .standard) {
        if loadIssue(defaults: defaults) != nil, let original = defaults.string(forKey: key) {
            defaults.set(original, forKey: key + ".preserved." + UUID().uuidString)
        }
        defaults.set(style.rawValue, forKey: key)
    }
}

nonisolated struct GalleryReceiptVariants: Codable, Equatable, Sendable {
    let originalFooterStyle: ReceiptFooterStyle
    let defaultStyle: GalleryReceiptStyle
    var hasAlternative: Bool { originalFooterStyle != .decorativeBarcodeOnly }
}
