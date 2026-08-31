//
//  BoothFormat.swift
//  PocketPixelsBooth
//

import Foundation

enum BoothFormat: String, CaseIterable, Identifiable, Sendable {
    case solo
    case duo
    case trio
    case grid
    case mosaic
    case strip

    nonisolated var id: String { rawValue }

    nonisolated var displayName: String {
        switch self {
        case .solo:
            "Solo"
        case .duo:
            "Duo"
        case .trio:
            "Trio"
        case .grid:
            "Grid"
        case .mosaic:
            "Mosaic"
        case .strip:
            "Strip"
        }
    }

    nonisolated var shortDescription: String {
        switch self {
        case .solo:
            "One large portrait"
        case .duo:
            "Two stacked portraits"
        case .trio:
            "Three portraits in a keepsake layout"
        case .grid:
            "Classic four-photo grid"
        case .mosaic:
            "Feature portrait with three smaller moments"
        case .strip:
            "Four-photo receipt strip"
        }
    }

    nonisolated var photoCount: Int {
        switch self {
        case .solo:
            1
        case .duo:
            2
        case .trio:
            3
        case .grid, .mosaic, .strip:
            4
        }
    }

    nonisolated var photoCountLabel: String {
        photoCount == 1 ? "1 photo" : "\(photoCount) photos"
    }

    nonisolated var reviewSummary: String {
        "\(displayName.uppercased()) · \(photoCountLabel.uppercased())"
    }
}
