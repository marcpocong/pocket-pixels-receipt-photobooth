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
        case .pocketPixelsDefault: MadeToKeepBrand.shortName
        case .customEventHeader: "Event Artwork"
        case .none: "None"
        }
    }
}

nonisolated enum ReceiptHeaderAlignment: String, Codable, CaseIterable, Identifiable, Sendable {
    case left, center, right
    var id: String { rawValue }
    var displayName: String { rawValue.capitalized }

    /// Position on the -1 (left) … 1 (right) scale used by `horizontalPosition`.
    var horizontalPosition: Double {
        switch self {
        case .left: -1
        case .center: 0
        case .right: 1
        }
    }
}

nonisolated enum ReceiptHeaderLayoutMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case fit, fill
    var id: String { rawValue }
    var displayName: String { rawValue.capitalized }
}

/// Codable, device-independent settings only. Artwork bytes live in EventHeaderAssetStore.
///
/// Persisted keys and raw values are stable. Fields added after the first release are optional
/// so profiles saved by older builds decode unchanged and render exactly as before.
nonisolated struct ReceiptHeaderConfiguration: Codable, Equatable, Sendable {
    static let minimumScale = 0.5
    static let maximumScale = 1.35
    /// Frame width is capped at the printable width, so sizes above 1 never widen the artwork.
    /// The editor offers 0.5 … 1.0; larger legacy values still clamp safely.
    static let maximumEditorScale = 1.0
    static let maximumSpacing = 48.0
    static let maximumZoom = 3.0
    static let defaultFillHeightRatio = 1.0 / 3.0
    static let fillHeightRatioRange = 0.2...1.0

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
    /// Fine horizontal placement of the frame (-1 left … 1 right). Nil follows `alignment`,
    /// which is how every profile saved before the artwork editor existed behaves.
    var horizontalPosition: Double?
    /// Banner height as a fraction of frame width in Fill mode. Nil keeps the original 1:3 banner.
    var fillHeightRatio: Double?
    /// Studio-First or Event-First receipt hierarchy. Nil is a profile saved before branding
    /// modes existed: it keeps the legacy top-header rendering until the operator picks a mode.
    var brandingMode: ReceiptBrandingMode?
    /// Event-First only: prints an understated Made to Keep credit near the footer.
    var showsStudioCredit: Bool?
    /// Nil preserves the original shared layout byte-for-byte until an adjustment is made.
    var coBrandedAdjustments: CoBrandedHeaderAdjustments?

    init(
        mode: ReceiptHeaderMode,
        assetIdentifier: String?,
        scale: Double,
        topSpacing: Double,
        bottomSpacing: Double,
        alignment: ReceiptHeaderAlignment,
        layoutMode: ReceiptHeaderLayoutMode,
        cropPositionX: Double,
        cropPositionY: Double,
        cropZoom: Double,
        horizontalPosition: Double? = nil,
        fillHeightRatio: Double? = nil,
        brandingMode: ReceiptBrandingMode? = nil,
        showsStudioCredit: Bool? = nil
    ) {
        self.mode = mode
        self.assetIdentifier = assetIdentifier
        self.scale = scale
        self.topSpacing = topSpacing
        self.bottomSpacing = bottomSpacing
        self.alignment = alignment
        self.layoutMode = layoutMode
        self.cropPositionX = cropPositionX
        self.cropPositionY = cropPositionY
        self.cropZoom = cropZoom
        self.horizontalPosition = horizontalPosition
        self.fillHeightRatio = fillHeightRatio
        self.brandingMode = brandingMode
        self.showsStudioCredit = showsStudioCredit
    }

    var effectiveHorizontalPosition: Double {
        (horizontalPosition ?? alignment.horizontalPosition).clamped(to: -1...1)
    }

    var effectiveFillHeightRatio: Double {
        (fillHeightRatio ?? Self.defaultFillHeightRatio).clamped(to: Self.fillHeightRatioRange)
    }

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

    /// Starting point for new event configurations: Made to Keep masthead at the top, with any
    /// event artwork printed as a compact signature near the bottom.
    static let studioFirst: ReceiptHeaderConfiguration = {
        var value = ReceiptHeaderConfiguration.default
        value.brandingMode = .studioFirst
        return value
    }()

    var effectiveShowsStudioCredit: Bool {
        brandingMode == .eventFirst && showsStudioCredit == true
    }

    func normalized() -> ReceiptHeaderConfiguration {
        var value = self
        value.scale = scale.clamped(to: Self.minimumScale...Self.maximumScale)
        value.topSpacing = topSpacing.clamped(to: 0...Self.maximumSpacing)
        value.bottomSpacing = bottomSpacing.clamped(to: 0...Self.maximumSpacing)
        value.cropPositionX = cropPositionX.clamped(to: -1...1)
        value.cropPositionY = cropPositionY.clamped(to: -1...1)
        value.cropZoom = cropZoom.clamped(to: 1...Self.maximumZoom)
        value.horizontalPosition = horizontalPosition.map { $0.isFinite ? $0.clamped(to: -1...1) : 0 }
        value.fillHeightRatio = fillHeightRatio.map {
            $0.isFinite ? $0.clamped(to: Self.fillHeightRatioRange) : Self.defaultFillHeightRatio
        }
        value.coBrandedAdjustments = coBrandedAdjustments?.normalized()
        if value.assetIdentifier?.isEmpty == true { value.assetIdentifier = nil }
        return value
    }

    /// Snaps to a named alignment and drops any fine horizontal offset.
    mutating func align(_ alignment: ReceiptHeaderAlignment) {
        self.alignment = alignment
        horizontalPosition = nil
    }

    mutating func resetAdjustments() {
        let assetIdentifier = assetIdentifier
        let mode = mode
        let brandingMode = brandingMode
        let showsStudioCredit = showsStudioCredit
        self = .default
        self.assetIdentifier = assetIdentifier
        self.mode = mode
        self.brandingMode = brandingMode
        self.showsStudioCredit = showsStudioCredit
    }
}

private extension Double {
    nonisolated func clamped(to range: ClosedRange<Double>) -> Double {
        min(range.upperBound, max(range.lowerBound, isFinite ? self : range.lowerBound))
    }
}
