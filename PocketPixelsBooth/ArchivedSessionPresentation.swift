//
//  ArchivedSessionPresentation.swift
//  PocketPixelsBooth
//
//  Read-only presentation models for Recent Sessions: the original gallery link and its QR, a
//  truthful delivery status, and a concise print summary. Nothing here mints a token, starts an
//  upload, rewrites an archive or logs a gallery URL or token.
//

import Foundation
import UIKit

/// Where an archived session's customer gallery stands, from on-device evidence only.
nonisolated enum ArchivedGalleryStatus: Equatable, Sendable {
    /// The public gallery page was fetched and confirmed complete for this session.
    case verified
    case uploading
    case unavailable
    /// Saved on this iPad and queued; the QR may not open the photos yet.
    case waiting(String)
    /// Queued, but the last attempt could not confirm delivery: an operator should retry.
    case needsAttention(String)
    /// Not queued and no verification was recorded (for example an older session or a cleared
    /// history). The link may work, but this iPad cannot vouch for it.
    case unknown
    /// The archived link is not a valid gallery URL for this session. No QR is shown.
    case invalidLink

    var title: String {
        switch self {
        case .uploading: "Uploading"
        case .unavailable: "Gallery Unavailable"
        case .verified: "Gallery Ready"
        case .waiting: "Waiting for Upload"
        case .needsAttention: "Needs Attention"
        case .unknown: "Not Yet Verified"
        case .invalidLink: "Invalid Gallery Link"
        }
    }

    var detail: String {
        switch self {
        case .uploading: "Upload or public completion verification is in progress."
        case .unavailable: "An authoritative check confirmed this original gallery is unavailable."
        case .verified:
            "The customer gallery was verified online. Scanning opens these photos."
        case .waiting(let detail):
            "\(detail). This is the original QR, but the photos may not be ready yet."
        case .needsAttention(let detail):
            "\(detail). Photos are saved on this iPad; retry from Manage Gallery Upload."
        case .unknown:
            "This iPad has no delivery confirmation for this session. The QR is the original link, but it may not be ready."
        case .invalidLink:
            "This archive's gallery link is missing or damaged, so no QR is shown. Never substitute another code."
        }
    }

    var systemImage: String {
        switch self {
        case .uploading: "arrow.triangle.2.circlepath"
        case .unavailable: "icloud.slash"
        case .verified: "checkmark.seal.fill"
        case .waiting: "arrow.up.circle"
        case .needsAttention: "exclamationmark.triangle.fill"
        case .unknown: "questionmark.circle"
        case .invalidLink: "link.badge.plus"
        }
    }

    /// Short card label.
    var shortTitle: String {
        switch self {
        case .uploading: "Uploading"
        case .unavailable: "Gallery Unavailable"
        case .verified: "Gallery Ready"
        case .waiting: "Gallery waiting"
        case .needsAttention: "Gallery needs attention"
        case .unknown: "Not Yet Verified"
        case .invalidLink: "Invalid Gallery Link"
        }
    }

    var isAttention: Bool {
        switch self {
        case .needsAttention, .invalidLink: true
        default: false
        }
    }

    static func resolve(
        linkIsValid: Bool,
        pendingItem: GalleryPendingUploadSummary?,
        verifiedAt: Date?
    ) -> ArchivedGalleryStatus {
        guard linkIsValid else { return .invalidLink }
        if let pendingItem {
            switch pendingItem.deliveryState {
            case .posted: return .uploading
            case .notStarted:
                return .waiting(pendingItem.deliveryState.operatorTitle)
            case .deliveryUnknown:
                return .needsAttention(pendingItem.deliveryState.operatorTitle)
            }
        }
        return verifiedAt != nil ? .verified : .unknown
    }
}

/// The archived session's own gallery link, validated but never rebuilt.
nonisolated struct ArchivedGalleryLink: Equatable, Sendable {
    /// The frozen `archive.galleryURL`, or nil when it is not a valid link for this session.
    let url: URL?

    /// Valid only when the frozen URL is an HTTPS `<front door>?g=<token>` link carrying this
    /// archive's own token. Any historical front door is accepted; nothing is migrated.
    init(galleryURL: URL, galleryToken: String) {
        let valid = GalleryTokenGenerator.isValidGalleryToken(galleryToken)
            && GalleryURLBuilder.customerGalleryBaseURL(ofGalleryURL: galleryURL, galleryToken: galleryToken) != nil
        url = valid ? galleryURL : nil
    }

    var isValid: Bool { url != nil }

    /// Scannable QR with its white quiet zone, encoding exactly the archived URL.
    func makeQRImage(pixelSize: Int = GalleryQRCodeGenerator.pixelSize) -> UIImage? {
        guard let url else { return nil }
        return try? GalleryQRCodeGenerator.makeQRCodeImage(for: url, pixelSize: pixelSize)
    }
}

/// One-line print outcome for a session card, from the retained print audit.
nonisolated enum ArchivedPrintSummary: Equatable, Sendable {
    case printed(copies: Int)
    case needsInspection
    case notPrinted
    case notRecorded

    static func resolve(records: [PrintAuditRecord]) -> ArchivedPrintSummary {
        guard !records.isEmpty else { return .notRecorded }
        if records.contains(where: { $0.terminalResult == .recoveryRequiredAfterBytes }) { return .needsInspection }
        let completed = records.filter { $0.terminalResult == .completed && $0.source != .archivedReprint }
        if !completed.isEmpty { return .printed(copies: completed.count) }
        return records.contains(where: { $0.terminalResult == .completed }) ? .printed(copies: 0) : .notPrinted
    }

    var title: String {
        switch self {
        case .printed(let copies): copies > 1 ? "Printed · \(copies) copies" : "Printed"
        case .needsInspection: "Print status unknown"
        case .notPrinted: "Not printed"
        case .notRecorded: "Print not recorded"
        }
    }

    var systemImage: String {
        switch self {
        case .printed: "printer.fill"
        case .needsInspection: "exclamationmark.triangle.fill"
        case .notPrinted: "xmark.circle"
        case .notRecorded: "printer"
        }
    }

    var isAttention: Bool { self == .needsInspection }
}
