//
//  BoothSessionEnvironment.swift
//  PocketPixelsBooth
//
//  Where a booth session's side effects go. Customer sessions use `.customer`, which is exactly
//  the production behavior. Operator hardware qualification drives the same production state
//  machine with `.hardwareQualification`, which redirects every durable side effect into an
//  isolated diagnostic namespace so a test can never touch customer archives, galleries,
//  recovery snapshots, event session counts or the saved event configuration.
//

import Foundation
import LocalAuthentication

struct BoothSessionEnvironment {
    enum Purpose: Equatable {
        case customer
        case hardwareQualification(runID: String)
    }

    var purpose: Purpose = .customer
    /// nil uses the production archive. A diagnostic directory that cannot be opened fails the
    /// archive commit (and therefore blocks printing); it never falls back to production.
    var archiveDirectory: URL?
    /// nil uses the production recovery store.
    var recoveryDirectory: URL?
    var detachedCheckoutDirectory: URL?
    /// Customer galleries are prepared and uploaded. Qualification never uploads.
    var deliversGallery = true
    /// Event session counts and other customer metrics.
    var recordsCustomerSessionMetrics = true
    var printSource: PrintJobSource = .liveCustomer
    // A receipt timestamp is readable, but never an ownership key by itself: clocks can repeat
    // across rapid handoffs, relaunches and booths. Recovery retains its original identifier.
    var makeSessionIdentifier: @MainActor (Date) -> String = { "\(ReceiptComposer.makeSessionIdentifier(date: $0))-\(UUID().uuidString.lowercased())" }
    /// The event configuration a new session freezes. Qualification supplies its own scenario
    /// profile instead of editing the operator's saved event settings.
    var eventProfileSource: @MainActor () -> EventProfile = { RegularBoothMode.isEnabled ? RegularBoothSettings.load().profile : EventProfileStore.load() }
    var regularBoothModeSource: @MainActor () -> Bool = { RegularBoothMode.isEnabled }
    var galleryReceiptStyleSource: @MainActor () -> GalleryReceiptStyle = { GalleryReceiptSettingsStore.load() }
    var receiptPrintOptionsSource: @MainActor () -> ReceiptPrintOptions = { ReceiptPrintSettingsStore.load() }
    /// Sticker Studio settings a new session freezes. Qualification never shows the editor.
    var stickerConfigurationSource: @MainActor () -> StickerStudioSessionConfiguration = { StickerStudioSessionConfiguration.current() }
    /// Operator sticker library for the guest catalog; nil means built-in stickers only.
    var stickerCatalogStoreSource: @MainActor () -> StickerCatalogStore? = { try? StickerCatalogStore() }
    /// Online provider factory, consulted only when the frozen configuration is online-ready.
    var onlineStickerProviderSource: @MainActor () -> OnlineStickerProvider? = {
        nil // Legacy injection point; the static studio never consults it.
    }

    /// Authorized-operator confirmation that cash for the shown total was received. True only
    /// after local operator authentication on this iPad; a guest tap alone can never pass it.
    var authorizeAttendantCashConfirmation: @MainActor (_ totalText: String) async -> Bool = { total in
        await AttendantCashConfirmation.authenticate(totalText: total)
    }

    static var customer: BoothSessionEnvironment { BoothSessionEnvironment() }

    var isQualification: Bool {
        if case .hardwareQualification = purpose { return true }
        return false
    }

    nonisolated static func makeArchiveStore(directory: URL?) throws -> RecentSessionArchiveStore {
        if let directory {
            return try RecentSessionArchiveStore(directoryURL: directory)
        }
        return try RecentSessionArchiveStore()
    }
}

/// Device-owner authentication (Face ID, Touch ID or the iPad passcode) for attendants
/// confirming cash. Mirrors the operator unlock; it stores nothing.
enum AttendantCashConfirmation {
    @MainActor static func authenticate(totalText: String) async -> Bool {
        let context = LAContext()
        context.touchIDAuthenticationAllowableReuseDuration = 0
        context.localizedFallbackTitle = "Use iPad Passcode"
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return false }
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication,
            localizedReason: "Attendant: confirm you received \(totalText) in cash")) ?? false
    }
}
