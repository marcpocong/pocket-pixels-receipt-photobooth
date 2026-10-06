//
//  GoogleDriveGalleryConfiguration.swift
//  PocketPixelsBooth
//
//  Created by marc on 8/30/26.
//

import Foundation

struct GoogleDriveGalleryConfiguration: Sendable {
    let webAppURL: URL

    nonisolated static let infoPlistKey = "GOOGLE_GALLERY_WEB_APP_URL"
    nonisolated static let placeholder = "YOUR_GOOGLE_APPS_SCRIPT_WEB_APP_URL"

    nonisolated static func load() throws -> GoogleDriveGalleryConfiguration {
        if let override = GalleryBackendOverrideStore().uploadURLOverride() {
            return try validate(rawValue: override)
        }
        guard let rawValue = Bundle.main.object(forInfoDictionaryKey: infoPlistKey) as? String else {
            throw GalleryUploadError.configuration("GOOGLE_GALLERY_WEB_APP_URL is missing from Info.plist.")
        }

        return try validate(rawValue: rawValue)
    }

    nonisolated static func validate(rawValue: String) throws -> GoogleDriveGalleryConfiguration {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != placeholder else {
            throw GalleryUploadError.configuration("Google gallery web-app URL is still using the placeholder.")
        }

        guard let rawURL = URL(string: trimmed) else {
            throw GalleryUploadError.configuration("Google gallery web-app URL is malformed.")
        }

        let url = try GalleryURLBuilder.canonicalWebAppURL(rawURL)

        guard let scheme = url.scheme?.lowercased(), let host = url.host()?.lowercased(), !host.isEmpty else {
            throw GalleryUploadError.configuration("Google gallery web-app URL is malformed.")
        }

        guard scheme == "https" else {
            throw GalleryUploadError.configuration("Google gallery uploads require an HTTPS web-app URL.")
        }

        guard host == "script.google.com" else {
            throw GalleryUploadError.configuration("Google gallery web-app URL must use script.google.com.")
        }

        guard url.path.hasPrefix("/macros/s/"), url.path.hasSuffix("/exec") else {
            throw GalleryUploadError.configuration("Use the deployed Google Apps Script Web App URL ending in /exec.")
        }

        guard !url.path.contains("/dev") else {
            throw GalleryUploadError.configuration("Use the deployed Google Apps Script /exec URL, not the /dev URL.")
        }

        guard !url.path.contains("/library/") else {
            throw GalleryUploadError.configuration("Google gallery web-app URL must not contain /library/.")
        }

        return GoogleDriveGalleryConfiguration(webAppURL: url)
    }

    nonisolated static func statusMessage() -> String {
        do {
            _ = try load()
            return "Configured"
        } catch {
            return error.localizedDescription
        }
    }
}

struct CustomerGalleryConfiguration: Sendable {
    let baseURL: URL

    nonisolated static let infoPlistKey = "POCKET_PIXELS_CUSTOMER_GALLERY_BASE_URL"
    nonisolated static let placeholder = "https://pocket-pixels-gallery.pocketpixels-ceb.workers.dev/"

    nonisolated static func load() throws -> CustomerGalleryConfiguration {
        if let override = GalleryBackendOverrideStore().customerURLOverride() {
            return try validate(rawValue: override)
        }
        guard let rawValue = Bundle.main.object(forInfoDictionaryKey: infoPlistKey) as? String else {
            throw GalleryUploadError.configuration("POCKET_PIXELS_CUSTOMER_GALLERY_BASE_URL is missing from Info.plist.")
        }

        return try validate(rawValue: rawValue)
    }

    nonisolated static func validate(rawValue: String) throws -> CustomerGalleryConfiguration {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw GalleryUploadError.configuration("Customer gallery base URL is missing.")
        }

        guard let rawURL = URL(string: trimmed) else {
            throw GalleryUploadError.configuration("Customer gallery base URL is malformed.")
        }

        let url = try GalleryURLBuilder.canonicalCustomerGalleryBaseURL(rawURL)
        guard url.scheme?.lowercased() == "https", let host = url.host()?.lowercased(), !host.isEmpty else {
            throw GalleryUploadError.configuration("Customer gallery base URL must be HTTPS.")
        }

        guard host != "script.google.com" else {
            throw GalleryUploadError.configuration("Customer gallery base URL must not use script.google.com.")
        }

        return CustomerGalleryConfiguration(baseURL: url)
    }

    nonisolated static func statusMessage() -> String {
        do {
            _ = try load()
            return "Configured"
        } catch {
            return error.localizedDescription
        }
    }
}
