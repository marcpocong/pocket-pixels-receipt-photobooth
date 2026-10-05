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
        case .classic: "Pocket Pixels Classic"
        case .warmCelebration: "Warm Celebration"
        case .minimalLight: "Minimal Light"
        case .evening: "Evening"
        case .editorial: "Editorial"
        }
    }

    nonisolated var summary: String {
        switch self {
        case .classic: "Blush and warm paper with the Pocket Pixels maroon accent."
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
            [PocketPixelsTheme.ColorPalette.paper, PocketPixelsTheme.ColorPalette.brandBlush.opacity(0.34), PocketPixelsTheme.ColorPalette.paperWarm.opacity(0.72)]
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
        PocketPixelsTheme.ColorPalette.brandMaroon
    }

    var customerSecondaryTextColor: Color {
        PocketPixelsTheme.ColorPalette.secondaryText
    }

    var previewSurfaceColor: Color {
        PocketPixelsTheme.ColorPalette.acrylic.opacity(0.82)
    }
}

nonisolated enum CustomerIdleResetPolicy {
    static let inactivityDuration: TimeInterval = 5 * 60
    static let warningDuration: Int = 30
    static let thankYouInactivityDuration: TimeInterval = 2 * 60

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
        case .choosingFormat, .cameraReady, .review, .passportDetails, .passportSignature, .passportPreview, .receiptPreview, .thankYou:
            return true
        case .welcome, .preparingCamera, .countdown, .capturing, .betweenPhotos, .retaking,
             .composingReceipt, .connectingToPrinter, .printing, .recoveryRequired, .error:
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
        case .composingReceipt:
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
