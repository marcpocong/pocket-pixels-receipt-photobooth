//
//  CustomerExperienceSupport.swift
//  PocketPixelsBooth
//

import SwiftUI

nonisolated enum CustomerScreenTheme: String, Codable, CaseIterable, Identifiable, Sendable {
    case classic
    case warmCelebration
    case minimalLight
    case evening
    case editorial

    nonisolated var id: String { rawValue }

    nonisolated var displayName: String {
        switch self {
        case .classic: "Made to Keep Classic"
        case .warmCelebration: "Warm Celebration"
        case .minimalLight: "Minimal Light"
        case .evening: "Evening"
        case .editorial: "Editorial"
        }
    }

    nonisolated var summary: String {
        switch self {
        case .classic: "Ivory printed paper with the Made to Keep burgundy accent."
        case .warmCelebration: "Soft peach and cream for weddings and celebrations."
        case .minimalLight: "Clean ivory surfaces with restrained contrast."
        case .evening: "Dusty plum and candlelit blush with strong maroon contrast."
        case .editorial: "Neutral paper and bold ink-inspired accents."
        }
    }
}

extension CustomerScreenTheme {
    var backgroundColors: [Color] {
        switch self {
        case .classic:
            [MadeToKeepTheme.ColorPalette.paper, MadeToKeepTheme.ColorPalette.brandBlush.opacity(0.34), MadeToKeepTheme.ColorPalette.paperWarm.opacity(0.72)]
        case .warmCelebration:
            [Color(red: 1.00, green: 0.97, blue: 0.92), Color(red: 0.99, green: 0.84, blue: 0.74), Color(red: 0.96, green: 0.90, blue: 0.83)]
        case .minimalLight:
            [Color(red: 0.99, green: 0.99, blue: 0.98), Color(red: 0.95, green: 0.94, blue: 0.92), Color.white]
        case .evening:
            [Color(red: 0.97, green: 0.92, blue: 0.93), Color(red: 0.86, green: 0.74, blue: 0.78), Color(red: 0.95, green: 0.88, blue: 0.90)]
        case .editorial:
            [Color(red: 0.95, green: 0.94, blue: 0.90), Color(red: 0.86, green: 0.84, blue: 0.78), Color(red: 0.98, green: 0.97, blue: 0.94)]
        }
    }

    var customerTextColor: Color {
        MadeToKeepTheme.ColorPalette.brandMaroon
    }

    var customerSecondaryTextColor: Color {
        MadeToKeepTheme.ColorPalette.secondaryText
    }

    var previewSurfaceColor: Color {
        MadeToKeepTheme.ColorPalette.acrylic.opacity(0.82)
    }
}

nonisolated enum CustomerIdleResetPolicy {
    static let inactivityDuration: TimeInterval = 5 * 60
    static let warningDuration: Int = 30
    static let thankYouInactivityDuration: TimeInterval = 60
    static let thankYouWarningDuration: Int = 15

    static func warningDuration(for state: BoothSessionState) -> Int {
        state == .thankYou ? thankYouWarningDuration : warningDuration
    }

    static func isEligible(
        state: BoothSessionState,
        printerWorking: Bool,
        printBatchActive: Bool,
        recoveryLocked: Bool,
        unresolvedPrint: Bool
    ) -> Bool {
        guard !printerWorking, !printBatchActive, !recoveryLocked, !unresolvedPrint else {
            return false
        }

        switch state {
        case .choosingFormat, .choosingCopies, .choosingPayment, .cashAttestation, .cameraReady, .review,
             .passportDetails, .passportSignature, .passportPreview, .stickerStudio, .receiptPreview, .thankYou:
            return true
        case .welcome, .awaitingQRPayment, .paymentReconciliation, .preparingCamera, .countdown, .capturing, .betweenPhotos, .retaking,
             .preparingStickers, .composingReceipt, .connectingToPrinter, .printing, .recoveryRequired, .error:
            return false
        }
    }

    static func initialDelay(for state: BoothSessionState) -> TimeInterval {
        if case .thankYou = state {
            return thankYouInactivityDuration
        }
        return inactivityDuration
    }
}

nonisolated enum CustomerErrorKind: Equatable, Sendable {
    case camera
    case printer
    case photoPreparation
    case general

    var title: String {
        switch self {
        case .camera: "Camera needs attention"
        case .printer: "Printer needs attention"
        case .photoPreparation: "We couldn't prepare your photos"
        case .general: "Something needs attention"
        }
    }

    var guidance: String { "Please ask the booth operator for help." }

    static func classify(state: BoothSessionState) -> CustomerErrorKind {
        switch state {
        case .recoveryRequired, .connectingToPrinter, .printing:
            .printer
        case .preparingCamera, .cameraReady, .countdown, .capturing, .betweenPhotos, .retaking:
            .camera
        case .composingReceipt, .preparingStickers:
            .photoPreparation
        default:
            .general
        }
    }

    static func classify(technicalMessage: String) -> CustomerErrorKind {
        let value = technicalMessage.lowercased()
        if value.contains("camera") || value.contains("capture") || value.contains("permission") {
            return .camera
        }
        if value.contains("printer") || value.contains("bluetooth") || value.contains("ble") || value.contains("print") {
            return .printer
        }
        if value.contains("receipt") || value.contains("photo") || value.contains("image") {
            return .photoPreparation
        }
        return .general
    }
}

nonisolated enum CustomerExperiencePreviewPolicy {
    static let createsGallery = false
    static let createsArchive = false
    static let sendsPrint = false
    static let changesEventCounters = false
}

/// Which rendering the pre-print receipt preview shows. The keepsake view is the composed receipt;
/// "Black & White" is a smooth grayscale digital preview (`MonochromeReceiptRenderer`). Guests never
/// see the 1-bit printer raster: that stays in operator diagnostics only.
enum ReceiptPreviewMode: String, CaseIterable, Sendable {
    case keepsake
    case blackAndWhite
    /// The guest's photos played in order, like the gallery GIF. Multi-photo formats only.
    case motion

    static let printNote = "Printed in black and white on thermal paper. Final print texture may vary."
    /// Reserved vertical space for the toggle and note on the receipt screen.
    static let pickerHeightEstimate: CGFloat = 62

    var title: String {
        switch self {
        case .keepsake: "Keepsake"
        case .blackAndWhite: "Black & White"
        case .motion: "In Motion"
        }
    }

    /// Modes offered for a session. Solo has nothing to animate.
    static func available(motion: Bool) -> [ReceiptPreviewMode] {
        motion ? allCases : allCases.filter { $0 != .motion }
    }

    /// Black & White shows only the smooth monochrome preview. While it is still rendering this
    /// returns nil (a loading state), never the keepsake or the printer raster.
    func image(keepsake: UIImage?, monochrome: UIImage?) -> UIImage? {
        switch self {
        case .keepsake: keepsake
        case .blackAndWhite: monochrome
        case .motion: keepsake
        }
    }
}
