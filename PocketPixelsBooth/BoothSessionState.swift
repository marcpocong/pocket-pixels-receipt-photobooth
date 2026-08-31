//
//  BoothSessionState.swift
//  PocketPixelsBooth
//
//  Created by marc on 8/30/26.
//

import Foundation

enum BoothSessionState: Equatable {
    case welcome
    case choosingFormat
    case preparingCamera
    case cameraReady
    case countdown(photoIndex: Int, value: Int)
    case capturing(photoIndex: Int)
    case betweenPhotos(nextPhotoIndex: Int)
    case review
    case retaking(photoIndex: Int)
    case composingReceipt
    case receiptPreview
    case connectingToPrinter
    case printing
    case thankYou
    case recoveryRequired(String)
    case error(String)

    var isActiveSession: Bool {
        switch self {
        case .welcome, .choosingFormat, .thankYou:
            false
        case .preparingCamera, .cameraReady, .countdown, .capturing, .betweenPhotos, .review, .retaking, .composingReceipt, .receiptPreview, .connectingToPrinter, .printing, .recoveryRequired, .error:
            true
        }
    }

    var allowsCancellation: Bool {
        switch self {
        case .welcome, .choosingFormat, .thankYou:
            false
        case .preparingCamera, .cameraReady, .countdown, .capturing, .betweenPhotos, .review, .retaking, .composingReceipt, .receiptPreview, .connectingToPrinter, .printing, .recoveryRequired, .error:
            true
        }
    }

    var title: String {
        switch self {
        case .welcome:
            "Welcome"
        case .choosingFormat:
            "Choose Format"
        case .preparingCamera:
            "Preparing Camera"
        case .cameraReady:
            "Camera Ready"
        case .countdown(let index, _):
            "Photo \(index + 1)"
        case .capturing(let index):
            "Capturing Photo \(index + 1)"
        case .betweenPhotos(let nextIndex):
            "Next: Photo \(nextIndex + 1)"
        case .review:
            "Review"
        case .retaking(let index):
            "Retaking Photo \(index + 1)"
        case .composingReceipt:
            "Building Receipt"
        case .receiptPreview:
            "Receipt Preview"
        case .connectingToPrinter:
            "Connecting to Printer"
        case .printing:
            "Printing Receipt"
        case .thankYou:
            "Thank You"
        case .recoveryRequired:
            "Printer Restart Required"
        case .error:
            "Error"
        }
    }
}
