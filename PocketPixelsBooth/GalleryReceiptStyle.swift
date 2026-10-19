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
    static func save(_ style: GalleryReceiptStyle, defaults: UserDefaults = .standard) {
        defaults.set(style.rawValue, forKey: key)
    }
}

nonisolated struct GalleryReceiptVariants: Codable, Equatable, Sendable {
    let originalFooterStyle: ReceiptFooterStyle
    let defaultStyle: GalleryReceiptStyle
    var hasAlternative: Bool { originalFooterStyle != .decorativeBarcodeOnly }
}
