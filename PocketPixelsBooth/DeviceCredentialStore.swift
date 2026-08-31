//
//  DeviceCredentialStore.swift
//  PocketPixelsBooth
//
//  Created by marc on 8/30/26.
//

import Foundation
import Security

struct DeviceCredentialStore {
    private let service = "com.pocketpixels.gallery-upload"
    private let account = "device-upload-token"

    func saveDeviceToken(_ token: String) throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 24 else {
            throw GalleryUploadError.invalidDeviceToken
        }

        guard let data = trimmed.data(using: .utf8) else {
            throw GalleryUploadError.invalidDeviceToken
        }

        try deleteDeviceToken(ignoringMissing: true)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw GalleryUploadError.configuration("Keychain save failed with status \(status).")
        }
    }

    func loadDeviceToken() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        if status == errSecItemNotFound {
            return nil
        }

        guard status == errSecSuccess, let data = item as? Data, let token = String(data: data, encoding: .utf8) else {
            throw GalleryUploadError.configuration("Keychain read failed with status \(status).")
        }

        return token
    }

    func hasDeviceToken() -> Bool {
        (try? loadDeviceToken()) != nil
    }

    func deleteDeviceToken() throws {
        try deleteDeviceToken(ignoringMissing: false)
    }

    func redactedTokenDescription() -> String {
        guard let token = try? loadDeviceToken(), !token.isEmpty else {
            return "No token saved"
        }

        let suffix = token.suffix(4)
        return "Saved token ending in \(suffix)"
    }

    private func deleteDeviceToken(ignoringMissing: Bool) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let status = SecItemDelete(query as CFDictionary)
        if status == errSecSuccess || (ignoringMissing && status == errSecItemNotFound) || status == errSecItemNotFound {
            return
        }

        throw GalleryUploadError.configuration("Keychain delete failed with status \(status).")
    }
}
