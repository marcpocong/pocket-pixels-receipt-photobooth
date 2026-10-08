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

/// The customer-facing gallery front door used to build QR links for NEW sessions.
///
/// Precedence: operator override → `MADE_TO_KEEP_CUSTOMER_GALLERY_BASE_URL` →
/// legacy `POCKET_PIXELS_CUSTOMER_GALLERY_BASE_URL` → configuration error. Sessions that already
/// have a gallery URL (recovery snapshots, archives, queued uploads) keep that frozen URL; this
/// configuration is only consulted when a new gallery token is minted.
struct CustomerGalleryConfiguration: Sendable {
    enum Source: Sendable, Equatable {
        case operatorOverride
        case madeToKeepInfoPlist
        case legacyInfoPlist

        var displayName: String {
            switch self {
            case .operatorOverride: "Operator override"
            case .madeToKeepInfoPlist: "Made to Keep default"
            case .legacyInfoPlist: "Legacy front-door default"
            }
        }
    }

    let baseURL: URL

    /// Preferred Made to Keep Studios front-door key. Expanded from the build setting of the same
    /// name; blank or unexpanded values are treated as absent so the legacy key is used instead.
    nonisolated static let infoPlistKey = "MADE_TO_KEEP_CUSTOMER_GALLERY_BASE_URL"
    /// Legacy Pocket Pixels key. Still read so older configurations keep working.
    nonisolated static let legacyInfoPlistKey = "POCKET_PIXELS_CUSTOMER_GALLERY_BASE_URL"
    /// Legacy Pocket Pixels Worker front door. Already printed on receipts; must stay valid.
    nonisolated static let legacyBaseURLString = "https://pocket-pixels-gallery.pocketpixels-ceb.workers.dev/"
    nonisolated static let placeholder = legacyBaseURLString

    nonisolated static func load() throws -> CustomerGalleryConfiguration {
        try resolve(
            operatorOverride: GalleryBackendOverrideStore().customerURLOverride(),
            infoPlistValue: { Bundle.main.object(forInfoDictionaryKey: $0) }
        ).configuration
    }

    nonisolated static func resolve(
        operatorOverride: String?,
        infoPlistValue: (String) -> Any?
    ) throws -> (configuration: CustomerGalleryConfiguration, source: Source) {
        if let override = configuredValue(operatorOverride) {
            return (try validate(rawValue: override), .operatorOverride)
        }
        if let preferred = configuredValue(infoPlistValue(infoPlistKey) as? String) {
            return (try validate(rawValue: preferred), .madeToKeepInfoPlist)
        }
        if let legacy = configuredValue(infoPlistValue(legacyInfoPlistKey) as? String) {
            return (try validate(rawValue: legacy), .legacyInfoPlist)
        }
        throw GalleryUploadError.configuration("\(infoPlistKey) (or legacy \(legacyInfoPlistKey)) is missing from Info.plist.")
    }

    nonisolated private static func configuredValue(_ rawValue: String?) -> String? {
        guard let trimmed = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              !trimmed.hasPrefix("$(") else {
            return nil
        }
        return trimmed
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

    /// Operator-facing summary of the front door new sessions will use, e.g. "host (source)".
    nonisolated static func activeFrontDoorDescription() -> String {
        do {
            let resolved = try resolve(
                operatorOverride: GalleryBackendOverrideStore().customerURLOverride(),
                infoPlistValue: { Bundle.main.object(forInfoDictionaryKey: $0) }
            )
            return "\(resolved.configuration.baseURL.host() ?? resolved.configuration.baseURL.absoluteString) (\(resolved.source.displayName))"
        } catch {
            return error.localizedDescription
        }
    }
}
