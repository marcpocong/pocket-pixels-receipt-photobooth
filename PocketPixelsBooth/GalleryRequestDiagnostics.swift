//
//  GalleryRequestDiagnostics.swift
//  PocketPixelsBooth
//

#if DEBUG
import Foundation

struct GalleryRequestDiagnostics: CustomStringConvertible, Equatable, Sendable {
    let schemaVersion: Int
    let hasDeviceToken: Bool
    let galleryTokenCharacterCount: Int
    let galleryTokenMatchesLowercaseHex: Bool
    let sessionID: String
    let createdAt: String
    let photoCount: Int
    let photoFilenames: [String]
    let photoMimeTypes: [String]
    let photoBase64CharacterCounts: [Int]
    let receiptFilename: String
    let receiptMimeType: String
    let receiptBase64CharacterCount: Int
    let jsonBodyByteCount: Int

    var description: String {
        "GalleryRequestDiagnostics(schemaVersion: \(schemaVersion), hasDeviceToken: \(hasDeviceToken), galleryTokenCharacterCount: \(galleryTokenCharacterCount), galleryTokenMatchesLowercaseHex: \(galleryTokenMatchesLowercaseHex), sessionID: \(sessionID), createdAt: \(createdAt), photoCount: \(photoCount), photoFilenames: \(photoFilenames), photoMimeTypes: \(photoMimeTypes), photoBase64CharacterCounts: \(photoBase64CharacterCounts), receiptFilename: \(receiptFilename), receiptMimeType: \(receiptMimeType), receiptBase64CharacterCount: \(receiptBase64CharacterCount), jsonBodyByteCount: \(jsonBodyByteCount))"
    }
}
#endif
