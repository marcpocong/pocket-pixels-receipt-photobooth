//
//  ReceiptHeaderConfiguration.swift
//  PocketPixelsBooth
//

import Foundation

nonisolated enum ReceiptHeaderMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case pocketPixelsDefault
    case customEventHeader
    case none

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .pocketPixelsDefault: "Pocket Pixels"
        case .customEventHeader: "Event Image"
        case .none: "None"
        }
    }
}

nonisolated enum ReceiptHeaderAlignment: String, Codable, CaseIterable, Identifiable, Sendable {
    case left, center, right
    var id: String { rawValue }
    var displayName: String { rawValue.capitalized }
}

nonisolated enum ReceiptHeaderLayoutMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case fit, fill
    var id: String { rawValue }
    var displayName: String { rawValue.capitalized }
}

/// Codable, device-independent settings only. Image bytes live in EventHeaderAssetStore.
nonisolated struct ReceiptHeaderConfiguration: Codable, Equatable, Sendable {
    static let minimumScale = 0.5
    static let maximumScale = 1.35
    static let maximumSpacing = 48.0
    static let maximumZoom = 3.0

    var mode: ReceiptHeaderMode
    var assetIdentifier: String?
    var scale: Double
    var topSpacing: Double
    var bottomSpacing: Double
    var alignment: ReceiptHeaderAlignment
    var layoutMode: ReceiptHeaderLayoutMode
    var cropPositionX: Double
    var cropPositionY: Double
    var cropZoom: Double

    static let `default` = ReceiptHeaderConfiguration(
        mode: .pocketPixelsDefault,
        assetIdentifier: nil,
        scale: 1,
        topSpacing: 8,
        bottomSpacing: 12,
        alignment: .center,
        layoutMode: .fit,
        cropPositionX: 0,
        cropPositionY: 0,
        cropZoom: 1
    )

    func normalized() -> ReceiptHeaderConfiguration {
        var value = self
        value.scale = scale.clamped(to: Self.minimumScale...Self.maximumScale)
        value.topSpacing = topSpacing.clamped(to: 0...Self.maximumSpacing)
        value.bottomSpacing = bottomSpacing.clamped(to: 0...Self.maximumSpacing)
        value.cropPositionX = cropPositionX.clamped(to: -1...1)
        value.cropPositionY = cropPositionY.clamped(to: -1...1)
        value.cropZoom = cropZoom.clamped(to: 1...Self.maximumZoom)
        if value.assetIdentifier?.isEmpty == true { value.assetIdentifier = nil }
        return value
    }

    mutating func resetAdjustments() {
        let assetIdentifier = assetIdentifier
        let mode = mode
        self = .default
        self.assetIdentifier = assetIdentifier
        self.mode = mode
    }
}

private extension Double {
    nonisolated func clamped(to range: ClosedRange<Double>) -> Double {
        min(range.upperBound, max(range.lowerBound, isFinite ? self : range.lowerBound))
    }
}
