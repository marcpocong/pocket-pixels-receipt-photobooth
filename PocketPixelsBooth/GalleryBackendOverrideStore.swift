import Foundation

/// Optional, non-secret endpoint overrides for event operations. Device credentials remain in Keychain.
nonisolated struct GalleryBackendOverrideStore: Sendable {
    nonisolated private enum Key {
        static let uploadURL = "PocketPixels.galleryUploadURLOverride"
        static let customerURL = "PocketPixels.customerGalleryURLOverride"
    }

    nonisolated(unsafe) private let defaults: UserDefaults

    nonisolated init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    nonisolated func uploadURLOverride() -> String? {
        normalizedValue(forKey: Key.uploadURL)
    }

    nonisolated func customerURLOverride() -> String? {
        normalizedValue(forKey: Key.customerURL)
    }

    nonisolated func save(uploadURL: String, customerURL: String) throws {
        let upload = uploadURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let customer = customerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !upload.isEmpty {
            _ = try GoogleDriveGalleryConfiguration.validate(rawValue: upload)
        }
        if !customer.isEmpty {
            _ = try CustomerGalleryConfiguration.validate(rawValue: customer)
        }
        setOptional(upload, forKey: Key.uploadURL)
        setOptional(customer, forKey: Key.customerURL)
    }

    nonisolated func reset() {
        defaults.removeObject(forKey: Key.uploadURL)
        defaults.removeObject(forKey: Key.customerURL)
    }

    nonisolated private func normalizedValue(forKey key: String) -> String? {
        guard let value = defaults.string(forKey: key)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    nonisolated private func setOptional(_ value: String, forKey key: String) {
        if value.isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(value, forKey: key)
        }
    }
}
