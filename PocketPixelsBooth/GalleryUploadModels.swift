//
//  GalleryUploadModels.swift
//  PocketPixelsBooth
//
//  Created by marc on 8/30/26.
//

import Foundation

struct GalleryUploadImage: Codable, Sendable {
    let filename: String
    let mimeType: String
    let base64Data: String
}

struct GalleryUploadRequest: Codable, Sendable {
    let schemaVersion: Int
    let deviceToken: String
    let galleryToken: String
    let sessionID: String
    let createdAt: String
    let photos: [GalleryUploadImage]
    let receipt: GalleryUploadImage?
    let colorReceipt: GalleryUploadImage?
    let thermalReceipt: GalleryUploadImage?
    let gif: GalleryUploadImage?
    let shareColorReceipt: GalleryUploadImage?
    let receiptVariants: GalleryReceiptVariants?

    nonisolated init(schemaVersion: Int, deviceToken: String, galleryToken: String, sessionID: String, createdAt: String,
         photos: [GalleryUploadImage], receipt: GalleryUploadImage? = nil,
         colorReceipt: GalleryUploadImage? = nil, thermalReceipt: GalleryUploadImage? = nil,
         gif: GalleryUploadImage? = nil, shareColorReceipt: GalleryUploadImage? = nil,
         receiptVariants: GalleryReceiptVariants? = nil) {
        self.schemaVersion = schemaVersion; self.deviceToken = deviceToken; self.galleryToken = galleryToken
        self.sessionID = sessionID; self.createdAt = createdAt; self.photos = photos; self.receipt = receipt
        self.colorReceipt = colorReceipt; self.thermalReceipt = thermalReceipt; self.gif = gif
        self.shareColorReceipt = shareColorReceipt; self.receiptVariants = receiptVariants
    }
}

struct GalleryUploadResponse: Codable, Sendable {
    let ok: Bool
    let schemaVersion: Int?
    let galleryToken: String?
    let galleryURL: URL?
    let fileCount: Int?
    let errorCode: String?
    let error: String?
    let status: String?
    let field: String?
    let stage: String?
    let detail: String?
}

struct GalleryBackendDiagnosticResponse: Codable, Sendable {
    let ok: Bool
    let schemaVersion: Int?
    let backendVersion: String?
    let galleryTokenPattern: String?
    let sessionIDTimeZone: String?
    let canonicalURLPolicy: Bool?
    let accountScopedPathAllowed: Bool?
    let status: String?
}

struct GalleryUploadResult: Sendable {
    let galleryToken: String
    let galleryURL: URL
    let status: GalleryUploadResultStatus
}

enum GalleryUploadResultStatus: String, Codable, Equatable, Sendable {
    case created
    case existingComplete
    case completedIncomplete
    case unknown

    init(serverStatus: String?) {
        self = GalleryUploadResultStatus(rawValue: serverStatus ?? "") ?? .unknown
    }

    var displayTitle: String {
        switch self {
        case .created:
            "Created new gallery"
        case .existingComplete:
            "Existing completed gallery returned"
        case .completedIncomplete:
            "Completed pending gallery"
        case .unknown:
            "Upload successful"
        }
    }
}

@MainActor
enum GalleryUploadDateFormatter {
    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func string(from date: Date) -> String {
        formatter.string(from: date)
    }

    static func date(from string: String) -> Date? {
        formatter.date(from: string)
    }

    static func isValidWireString(_ value: String) -> Bool {
        guard !value.isEmpty,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.contains("."),
              let parsedDate = date(from: value) else {
            return false
        }

        return string(from: parsedDate) == value
    }
}

enum GalleryUploadPhase: Equatable {
    case idle
    case checkingInternet
    case preparing
    case uploading
    case success(URL)
    case pendingNoInternet
    case deliveryUnknown
    case unauthorized
    case serverRejected(String)
    case retryAvailable
    case failed(String)

    var isWorking: Bool {
        switch self {
        case .checkingInternet, .preparing, .uploading:
            true
        case .idle, .success, .pendingNoInternet, .deliveryUnknown, .unauthorized, .serverRejected, .retryAvailable, .failed:
            false
        }
    }

    var title: String {
        switch self {
        case .idle:
            "Ready"
        case .checkingInternet:
            "Checking internet"
        case .preparing:
            "Preparing"
        case .uploading:
            "Uploading"
        case .success:
            "Upload successful"
        case .pendingNoInternet:
            "Pending: no internet"
        case .deliveryUnknown:
            "Delivery unknown"
        case .unauthorized:
            "Unauthorized"
        case .serverRejected:
            "Server rejected upload"
        case .retryAvailable:
            "Retry available"
        case .failed:
            "Failed"
        }
    }
}

enum GalleryUploadError: Error, LocalizedError, Equatable {
    case configuration(String)
    case missingDeviceToken
    case invalidDeviceToken
    case invalidPhotoCount
    case missingReceipt
    case invalidSessionID
    case invalidDate
    case invalidGalleryToken
    case invalidGalleryURL
    case imageEncoding(String)
    case uploadAlreadyActive
    case cancelled
    case network(String)
    case timeout
    case backendUnreachable(GalleryBackendConnectivityState)
    case pendingNoInternet
    case deliveryUnknown
    case unauthorized
    case conflictManualInspection(String)
    case stalePendingUpload
    case requestTooLarge(String)
    case qrGeneration(String)
    case httpStatus(Int)
    case server(String)
    case decoding(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .configuration(let message):
            message
        case .missingDeviceToken:
            "Enter and save the device upload token before uploading."
        case .invalidDeviceToken:
            "The saved device token is invalid."
        case .invalidPhotoCount:
            "A gallery upload requires 1 to 6 photos."
        case .missingReceipt:
            "Create the composed color receipt before uploading."
        case .invalidSessionID:
            "The booth session ID is invalid."
        case .invalidDate:
            "The gallery creation date is invalid."
        case .invalidGalleryToken:
            "The gallery token is invalid."
        case .invalidGalleryURL:
            "The gallery URL is invalid."
        case .imageEncoding(let message):
            "Image encoding failed. \(message)"
        case .uploadAlreadyActive:
            "A gallery upload is already active."
        case .cancelled:
            "Gallery upload was cancelled."
        case .network(let message):
            "Network upload failed. \(message)"
        case .timeout:
            "Gallery upload timed out."
        case .backendUnreachable(let state):
            state.diagnosticDescription
        case .pendingNoInternet:
            "This Wi-Fi does not have usable internet. Printing can still work, but the gallery upload is pending."
        case .deliveryUnknown:
            "The server may have received this upload. Check Google Drive before retrying."
        case .unauthorized:
            "Gallery authentication failed. Re-enter the device upload token in Gallery Setup."
        case .conflictManualInspection(let message):
            message
        case .stalePendingUpload:
            "A pending upload from an older app version exists. It will not be uploaded automatically. Build a new test gallery to create a Phase 6C request."
        case .requestTooLarge(let message):
            "Gallery upload is too large. \(message)"
        case .qrGeneration(let message):
            "QR code could not be generated. \(message)"
        case .httpStatus(let status):
            "Gallery upload failed with HTTP status \(status)."
        case .server(let message):
            message
        case .decoding(let message):
            "Gallery response could not be decoded. \(message)"
        case .invalidResponse:
            "Gallery upload response was incomplete."
        }
    }
}
