//
//  BoothFormat.swift
//  PocketPixelsBooth
//

import Foundation

enum BoothFormat: String, Codable, CaseIterable, Identifiable, Sendable {
    case solo
    case duo
    case grid
    case strip
    case gridSix
    case passport

    nonisolated var id: String { rawValue }

    nonisolated var displayName: String {
        switch self {
        case .solo:
            "Solo"
        case .duo:
            "Duo"
        case .grid:
            "Grid"
        case .gridSix:
            "Grid 6"
        case .strip:
            "Strip"
        case .passport:
            // Customer-facing name only; the stored raw value stays "passport".
            "Photo Pass"
        }
    }

    nonisolated var shortDescription: String {
        switch self {
        case .solo:
            "One large portrait"
        case .duo:
            "Two stacked portraits"
        case .grid:
            "Classic four-photo grid"
        case .gridSix:
            "Six-photo grid"
        case .strip:
            "Three-photo classic strip"
        case .passport:
            "Two-photo event keepsake"
        }
    }

    nonisolated var photoCount: Int {
        switch self {
        case .solo:
            1
        case .duo:
            2
        case .grid:
            4
        case .gridSix:
            6
        case .strip:
            3
        case .passport:
            2
        }
    }

    nonisolated var photoCountLabel: String {
        photoCount == 1 ? "1 photo" : "\(photoCount) photos"
    }

    /// Photo Pass (stored as Passport) adds keepsake details, a signature and a dedicated preview after photo review.
    nonisolated var usesPassportFlow: Bool {
        self == .passport
    }

    nonisolated var reviewSummary: String {
        "\(displayName.uppercased()) · \(photoCountLabel.uppercased())"
    }
}
