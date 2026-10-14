//
//  ReceiptDesignSystem.swift
//  PocketPixelsBooth
//
//  Shared vocabulary for the Made to Keep editorial receipt: branding modes, the resolved
//  branding for one receipt, editorial captions and the physical print options. Studio identity,
//  event identity, the printed QR and the guest's digital gallery are deliberately independent.
//

import Foundation

/// Operator-selected receipt hierarchy. Persisted inside `ReceiptHeaderConfiguration`; raw
/// values are stable.
nonisolated enum ReceiptBrandingMode: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Made to Keep masthead at the top; event artwork prints as a compact bottom signature.
    case studioFirst
    /// Event artwork replaces the Made to Keep masthead at the top.
    case eventFirst
    /// Made to Keep wordmark × event logo side by side in the top header.
    case coBranded

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .studioFirst: "Studio-First"
        case .eventFirst: "Event-First"
        case .coBranded: "Co-Branded"
        }
    }

    var summary: String {
        switch self {
        case .studioFirst: "Made to Keep stays at the top. Event artwork prints as a small signature near the bottom."
        case .eventFirst: "Event artwork replaces the Made to Keep masthead at the top of the receipt. The Made to Keep monogram stays in the footer."
        case .coBranded: "Made to Keep × your event logo, side by side at the top of the receipt."
        }
    }

    /// Layouts offered behind the operator's Advanced disclosure; Co-Branded is the primary choice.
    static let advancedLayouts: [ReceiptBrandingMode] = [.studioFirst, .eventFirst]
}

/// Where branding actually lands on one receipt after artwork availability is considered.
nonisolated enum ReceiptBrandingPlacement: String, Sendable, Equatable {
    /// A profile saved before branding modes: header and event details print at the top, as before.
    case legacyHeader
    case studioFirst
    case eventFirst
    /// Made to Keep wordmark × event logo share the top header.
    case coBranded
}

nonisolated enum ReceiptBrandingWarning: String, Sendable, Equatable, CaseIterable {
    case eventFirstMissingArtwork
    case eventFirstArtworkHidden
    case coBrandedMissingArtwork

    var message: String {
        switch self {
        case .eventFirstMissingArtwork:
            "Event-First needs event artwork. Until artwork is added, new receipts print the Made to Keep masthead instead."
        case .eventFirstArtworkHidden:
            "Event-First is selected but event artwork is turned off. New receipts print the Made to Keep masthead instead."
        case .coBrandedMissingArtwork:
            "Co-Branded needs a usable event logo. Until one is added, new receipts print the standard Made to Keep header."
        }
    }
}

/// The branding decisions for one receipt. Pure value: derived from the frozen session profile
/// and whether its artwork file could be loaded, never from live operator settings.
nonisolated struct ReceiptBrandingResolution: Sendable, Equatable {
    let placement: ReceiptBrandingPlacement
    /// Made to Keep wordmark at the top of standard formats (centred, or beside the logo when Co-Branded).
    let showsStudioMasthead: Bool
    /// Event artwork at the top: replacing the masthead (Event-First, legacy custom header) or
    /// beside it (Co-Branded).
    let showsTopArtwork: Bool
    /// Event artwork prints as a compact signature below the footer.
    let showsArtworkSignature: Bool
    /// Understated Made to Keep credit below the footer.
    let showsStudioCredit: Bool
    /// Event details print in the compact secondary area instead of below the header.
    let showsEventDetailsBelowFooter: Bool
    let warnings: [ReceiptBrandingWarning]

    static let standard = ReceiptBrandingResolution(
        placement: .studioFirst,
        showsStudioMasthead: true,
        showsTopArtwork: false,
        showsArtworkSignature: false,
        showsStudioCredit: false,
        showsEventDetailsBelowFooter: true,
        warnings: []
    )

    /// - Parameters:
    ///   - header: the frozen event header configuration, or nil for a standard receipt.
    ///   - artworkAvailable: whether the configured artwork file loaded for this receipt.
    static func resolve(header: ReceiptHeaderConfiguration?, artworkAvailable: Bool) -> ReceiptBrandingResolution {
        guard let header = header?.normalized() else { return .standard }
        let wantsArtwork = header.mode == .customEventHeader
        let artworkReady = wantsArtwork && artworkAvailable

        switch header.brandingMode {
        case nil:
            // Legacy rendering: exactly the header the profile was saved with. A missing custom
            // asset already fell back to the Made to Keep masthead before branding modes existed.
            return ReceiptBrandingResolution(
                placement: .legacyHeader,
                showsStudioMasthead: header.mode == .pocketPixelsDefault || (wantsArtwork && !artworkReady),
                showsTopArtwork: artworkReady,
                showsArtworkSignature: false,
                showsStudioCredit: false,
                showsEventDetailsBelowFooter: false,
                warnings: []
            )
        case .studioFirst:
            return ReceiptBrandingResolution(
                placement: .studioFirst,
                showsStudioMasthead: true,
                showsTopArtwork: false,
                showsArtworkSignature: artworkReady,
                showsStudioCredit: false,
                showsEventDetailsBelowFooter: true,
                warnings: []
            )
        case .coBranded:
            guard artworkReady else {
                // Never reserve blank logo space: the standard masthead prints instead.
                return ReceiptBrandingResolution(
                    placement: .studioFirst,
                    showsStudioMasthead: true,
                    showsTopArtwork: false,
                    showsArtworkSignature: false,
                    showsStudioCredit: false,
                    showsEventDetailsBelowFooter: true,
                    warnings: [.coBrandedMissingArtwork]
                )
            }
            return ReceiptBrandingResolution(
                placement: .coBranded,
                showsStudioMasthead: true,
                showsTopArtwork: true,
                showsArtworkSignature: false,
                showsStudioCredit: false,
                showsEventDetailsBelowFooter: true,
                warnings: []
            )
        case .eventFirst:
            guard artworkReady else {
                // Never print an unexplained blank header: fall back to the studio masthead and
                // tell the operator why.
                return ReceiptBrandingResolution(
                    placement: .studioFirst,
                    showsStudioMasthead: true,
                    showsTopArtwork: false,
                    showsArtworkSignature: false,
                    showsStudioCredit: false,
                    showsEventDetailsBelowFooter: true,
                    warnings: [wantsArtwork ? .eventFirstMissingArtwork : .eventFirstArtworkHidden]
                )
            }
            return ReceiptBrandingResolution(
                placement: .eventFirst,
                showsStudioMasthead: false,
                showsTopArtwork: true,
                showsArtworkSignature: false,
                showsStudioCredit: header.effectiveShowsStudioCredit,
                showsEventDetailsBelowFooter: true,
                warnings: []
            )
        }
    }
}

/// The short, tracked uppercase event caption printed in the supplementary area below the
/// receipt footer. Standard receipts print no caption, like the reference design.
nonisolated enum ReceiptEditorialCaption {
    static let maximumLines = 2
    static let maximumLineLength = 24
    /// Characters accepted while typing (two full lines plus the separator).
    static let inputLimit = maximumLines * maximumLineLength + 1

    /// Lines to print: only an operator-entered event caption. Photo Pass carries its own
    /// message, so it never prints an editorial caption.
    static func resolvedLines(for format: BoothFormat, eventCaption: String?) -> [String] {
        guard format != .passport else { return [] }
        return lines(from: eventCaption ?? "").map { $0.uppercased() }
    }

    /// Splits operator text into at most two print-safe lines. A deliberate newline is kept; a
    /// single long line is broken at the word boundary closest to its middle.
    static func lines(from text: String) -> [String] {
        let explicit = text
            .components(separatedBy: .newlines)
            .map(collapsedWhitespace)
            .filter { !$0.isEmpty }
        let lines: [String]
        if explicit.count == 1, explicit[0].count > maximumLineLength {
            lines = balancedSplit(explicit[0])
        } else {
            lines = explicit
        }
        return lines.prefix(maximumLines).map { String($0.prefix(maximumLineLength)).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    static func normalized(_ text: String) -> String {
        lines(from: text).joined(separator: "\n")
    }

    private static func collapsedWhitespace(_ value: String) -> String {
        value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private static func balancedSplit(_ line: String) -> [String] {
        let words = line.split(separator: " ").map(String.init)
        guard words.count > 1 else { return [line] }
        var best: (first: String, second: String)?
        for index in 1..<words.count {
            let first = words[..<index].joined(separator: " ")
            let second = words[index...].joined(separator: " ")
            guard let current = best else {
                best = (first, second)
                continue
            }
            if max(first.count, second.count) < max(current.first.count, current.second.count) {
                best = (first, second)
            }
        }
        return best.map { [$0.first, $0.second] } ?? [line]
    }
}

/// Physical-print options frozen with each customer session. These never affect the gallery
/// token, gallery URL or the QR shown on the iPad.
nonisolated struct ReceiptPrintOptions: Codable, Equatable, Sendable {
    /// Prints the gallery QR section on the physical receipt.
    var includesPrintedGalleryQR: Bool

    static let `default` = ReceiptPrintOptions(includesPrintedGalleryQR: true)
}

/// Device-wide physical printing preferences. Independent of Event Mode.
nonisolated enum ReceiptPrintSettingsStore {
    static let printsGalleryQRKey = "madeToKeep.receipt.printsGalleryQR"
    static let didChangeNotification = Notification.Name("madeToKeep.receipt.printSettings.didChange")

    static func load(defaults: UserDefaults = .standard) -> ReceiptPrintOptions {
        // Missing means an existing or new installation that never changed the setting: ON.
        ReceiptPrintOptions(includesPrintedGalleryQR: defaults.object(forKey: printsGalleryQRKey) as? Bool ?? true)
    }

    static func save(_ options: ReceiptPrintOptions, defaults: UserDefaults = .standard) {
        defaults.set(options.includesPrintedGalleryQR, forKey: printsGalleryQRKey)
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }
}
