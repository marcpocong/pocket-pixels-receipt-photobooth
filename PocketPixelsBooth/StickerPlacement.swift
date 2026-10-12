//
//  StickerPlacement.swift
//  PocketPixelsBooth
//
//  The print-space sticker model. Every placement is stored normalized to a target region that
//  ReceiptComposer measured on the real receipt (576 printer dots wide). The editor, its touch
//  gestures and the final receipt raster all resolve a placement through the single
//  `StickerGeometry.resolve` transform, so what the guest arranges is exactly what prints.
//

import CoreGraphics
import Foundation
import UIKit

/// Where a sticker may live. Photos are always eligible; receipt regions only exist when the
/// measured layout has a blank area big enough to clear every protected element.
nonisolated enum StickerTarget: Codable, Hashable, Sendable {
    case photo(index: Int)
    case receiptRegion(id: String)
}

/// A measured, approved drawing area in printer dots.
nonisolated struct StickerTargetRegion: Equatable, Sendable {
    let target: StickerTarget
    /// The visible element (photo opening or blank band).
    let rect: CGRect
    /// `rect` minus the safe margin. Sticker ink is clipped to this rectangle.
    let clipRect: CGRect
    let label: String
}

/// Immutable geometry for one composed receipt: the canvas size and its approved regions.
nonisolated struct StickerLayoutSnapshot: Equatable, Sendable {
    let canvasWidth: Int
    let canvasHeight: Int
    let regions: [StickerTargetRegion]

    func region(for target: StickerTarget) -> StickerTargetRegion? {
        regions.first { $0.target == target }
    }

    /// The editor shows the top of the receipt down to the last region (plus a little paper).
    var editorVisibleHeight: Int {
        let bottom = regions.map { Int(ceil($0.rect.maxY)) }.max() ?? canvasHeight
        return min(canvasHeight, bottom + 24)
    }
}

nonisolated struct StickerPlacement: Codable, Equatable, Hashable, Sendable, Identifiable {
    let id: UUID
    var assetID: String
    var assetName: String
    var provenance: StickerProvenance
    /// Still frame that prints for an animated source; 0 for still images.
    var frameIndex: Int
    var target: StickerTarget
    /// Center, normalized to the target's clip rectangle (0...1).
    var centerX: Double
    var centerY: Double
    /// Longest sticker edge as a fraction of the clip rectangle's shorter edge.
    var scale: Double
    /// Radians, clockwise on paper. Normalized to -π...π.
    var rotation: Double
    var zOrder: Int
    /// width / height of the artwork.
    var aspectRatio: Double

    static let defaultScale = 0.42
    static let maximumScale = 1.0
}

// MARK: - Geometry

nonisolated enum StickerPlacementError: Error, Equatable, LocalizedError {
    case nonFiniteValue
    case invalidTarget
    case invalidAspectRatio
    case invalidScale
    case invalidRegion

    var errorDescription: String? {
        switch self {
        case .nonFiniteValue: "The sticker position is not a valid number."
        case .invalidTarget: "That sticker is not on an available photo."
        case .invalidAspectRatio: "The sticker artwork has an unusable shape."
        case .invalidScale: "The sticker size is out of range."
        case .invalidRegion: "The sticker area is not usable."
        }
    }
}

/// The resolved transform of one sticker, in printer dots.
nonisolated struct StickerResolvedFrame: Equatable, Sendable {
    let center: CGPoint
    let size: CGSize
    let rotation: CGFloat
    let clipRect: CGRect

    /// Axis-aligned bounds of the rotated artwork (before clipping).
    var rotatedBounds: CGRect {
        let cosine = abs(cos(rotation)), sine = abs(sin(rotation))
        let width = size.width * cosine + size.height * sine
        let height = size.width * sine + size.height * cosine
        return CGRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height)
    }

    /// Visible ink area: the rotated bounds clipped to the approved region.
    var visibleBounds: CGRect { rotatedBounds.intersection(clipRect) }

    /// Maps this print-space frame into an editor whose canvas shows the receipt at `displayScale`
    /// points per printer dot.
    func display(scale displayScale: CGFloat) -> StickerResolvedFrame {
        StickerResolvedFrame(
            center: CGPoint(x: center.x * displayScale, y: center.y * displayScale),
            size: CGSize(width: size.width * displayScale, height: size.height * displayScale),
            rotation: rotation,
            clipRect: CGRect(
                x: clipRect.minX * displayScale,
                y: clipRect.minY * displayScale,
                width: clipRect.width * displayScale,
                height: clipRect.height * displayScale
            )
        )
    }
}

nonisolated enum StickerGeometry {
    /// Dots kept clear inside every photo edge.
    static let safeMarginDots: CGFloat = 4
    /// Smallest blank band that may become an approved receipt region.
    static let minimumReceiptRegionDots: CGFloat = 96
    /// Clearance between an approved band and any protected element.
    static let protectedClearanceDots: CGFloat = 12
    /// The printed QR keeps at least this much white around it.
    static let qrQuietZoneDots: CGFloat = 16

    static func validateRegion(_ region: StickerTargetRegion, canvasWidth: Int = BoothConfiguration.receiptWidth) throws {
        let rect = region.clipRect
        guard [rect.origin.x, rect.origin.y, rect.size.width, rect.size.height].allSatisfy(\.isFinite) else { throw StickerPlacementError.invalidRegion }
        // Raw sizes: CGRect accessors silently standardize negative widths and heights.
        guard rect.size.width > 0, rect.size.height > 0, region.rect.size.width > 0, region.rect.size.height > 0,
              rect.minX >= 0, rect.minY >= 0, rect.maxX <= CGFloat(canvasWidth),
              region.rect.contains(rect) else {
            throw StickerPlacementError.invalidRegion
        }
    }

    /// Resolves a placement against its region. Rejects malformed input instead of guessing.
    static func resolve(_ placement: StickerPlacement, in region: StickerTargetRegion) throws -> StickerResolvedFrame {
        try validateRegion(region)
        guard placement.target == region.target else { throw StickerPlacementError.invalidTarget }
        guard [placement.centerX, placement.centerY, placement.scale, placement.rotation, placement.aspectRatio].allSatisfy(\.isFinite) else {
            throw StickerPlacementError.nonFiniteValue
        }
        guard placement.aspectRatio >= 0.1, placement.aspectRatio <= 10 else { throw StickerPlacementError.invalidAspectRatio }
        guard placement.scale > 0, placement.scale <= StickerPlacement.maximumScale + 1e-9 else { throw StickerPlacementError.invalidScale }
        guard (0...1).contains(placement.centerX), (0...1).contains(placement.centerY) else { throw StickerPlacementError.invalidTarget }

        let clip = region.clipRect
        let longSide = CGFloat(placement.scale) * min(clip.width, clip.height)
        let ratio = CGFloat(placement.aspectRatio)
        let size = ratio >= 1
            ? CGSize(width: longSide, height: longSide / ratio)
            : CGSize(width: longSide * ratio, height: longSide)
        let center = CGPoint(x: clip.minX + CGFloat(placement.centerX) * clip.width, y: clip.minY + CGFloat(placement.centerY) * clip.height)
        return StickerResolvedFrame(center: center, size: size, rotation: CGFloat(placement.rotation), clipRect: clip)
    }

    /// Smallest allowed `scale` in a region so the sticker's long edge prints at least
    /// `minimumPrintedDots`.
    static func minimumScale(in region: StickerTargetRegion, minimumPrintedDots: Int) -> Double {
        let shortSide = Double(min(region.clipRect.width, region.clipRect.height))
        guard shortSide > 0 else { return StickerPlacement.maximumScale }
        return min(StickerPlacement.maximumScale, Double(minimumPrintedDots) / shortSide)
    }

    /// Brings any placement back inside its limits: center inside the region, scale between
    /// the printable minimum and the region size, rotation in -π...π. Non-finite values reset.
    static func clamped(_ placement: StickerPlacement, in region: StickerTargetRegion, minimumPrintedDots: Int) -> StickerPlacement {
        var copy = placement
        copy.centerX = placement.centerX.isFinite ? min(max(placement.centerX, 0), 1) : 0.5
        copy.centerY = placement.centerY.isFinite ? min(max(placement.centerY, 0), 1) : 0.5
        let minimum = minimumScale(in: region, minimumPrintedDots: minimumPrintedDots)
        let scale = placement.scale.isFinite ? placement.scale : StickerPlacement.defaultScale
        copy.scale = min(max(scale, minimum), StickerPlacement.maximumScale)
        copy.rotation = normalizedRotation(placement.rotation.isFinite ? placement.rotation : 0)
        if !(placement.aspectRatio.isFinite && placement.aspectRatio >= 0.1 && placement.aspectRatio <= 10) {
            copy.aspectRatio = 1
        }
        return copy
    }

    static func normalizedRotation(_ radians: Double) -> Double {
        guard radians.isFinite else { return 0 }
        var value = radians.truncatingRemainder(dividingBy: 2 * .pi)
        if value > .pi { value -= 2 * .pi }
        if value <= -.pi { value += 2 * .pi }
        return value
    }

    /// Applies a live gesture (in editor points) to a placement. `displayScale` is points per
    /// printer dot. The result is clamped, so dragging can never leave the region.
    static func applying(
        translation: CGSize,
        magnification: CGFloat,
        rotationDelta: Double,
        to placement: StickerPlacement,
        in region: StickerTargetRegion,
        displayScale: CGFloat,
        minimumPrintedDots: Int
    ) -> StickerPlacement {
        guard displayScale.isFinite, displayScale > 0 else { return placement }
        var copy = placement
        let clip = region.clipRect
        if clip.width > 0, clip.height > 0 {
            copy.centerX += Double(translation.width / displayScale / clip.width)
            copy.centerY += Double(translation.height / displayScale / clip.height)
        }
        if magnification.isFinite, magnification > 0 {
            copy.scale *= Double(magnification)
        }
        if rotationDelta.isFinite {
            copy.rotation += rotationDelta
        }
        return clamped(copy, in: region, minimumPrintedDots: minimumPrintedDots)
    }

    /// Whether the sticker is likely too small or mostly clipped to read on paper.
    static func legibilityWarning(for frame: StickerResolvedFrame, minimumPrintedDots: Int) -> String? {
        let longest = max(frame.size.width, frame.size.height)
        if longest < CGFloat(minimumPrintedDots) - 0.5 {
            return "Too small to print clearly"
        }
        let visible = frame.visibleBounds
        let full = frame.rotatedBounds
        if full.width > 0, full.height > 0, !visible.isNull,
           (visible.width * visible.height) / (full.width * full.height) < 0.45 {
            return "Mostly off the photo — it will be cut off"
        }
        return nil
    }

    // MARK: Region discovery

    /// Approved regions for a measured receipt: every photo opening, plus any blank band beside
    /// or above the photographs that clears all protected elements by `protectedClearanceDots`
    /// and is at least `minimumReceiptRegionDots` in both directions. The current editorial
    /// layouts leave 24-dot side gutters and a 34-dot header gap, so in practice only photos
    /// qualify — by measurement, not by assumption.
    static func regions(
        photoFrames: [ReceiptPhotoFrame],
        protectedRects: [CGRect],
        canvasWidth: Int,
        canvasHeight: Int
    ) -> [StickerTargetRegion] {
        var regions: [StickerTargetRegion] = photoFrames
            .sorted { $0.photoIndex < $1.photoIndex }
            .compactMap { frame in
                let clip = frame.rect.insetBy(dx: safeMarginDots, dy: safeMarginDots)
                guard clip.width > 0, clip.height > 0 else { return nil }
                return StickerTargetRegion(target: .photo(index: frame.photoIndex), rect: frame.rect, clipRect: clip, label: "Photo \(frame.photoIndex + 1)")
            }

        let photoUnion = photoFrames.map(\.rect).reduce(CGRect.null) { $0.union($1) }
        guard !photoUnion.isNull else { return regions }
        let margin = CGFloat(BoothConfiguration.receiptHorizontalMargin)
        let candidates: [(String, String, CGRect)] = [
            ("left-gutter", "Left margin", CGRect(x: margin, y: photoUnion.minY, width: photoUnion.minX - margin, height: photoUnion.height)),
            ("right-gutter", "Right margin", CGRect(x: photoUnion.maxX, y: photoUnion.minY, width: CGFloat(canvasWidth) - margin - photoUnion.maxX, height: photoUnion.height))
        ]
        let obstacles = protectedRects + photoFrames.map(\.rect)
        for (id, label, candidate) in candidates {
            let clip = candidate.insetBy(dx: protectedClearanceDots, dy: protectedClearanceDots)
            guard clip.width >= minimumReceiptRegionDots, clip.height >= minimumReceiptRegionDots,
                  obstacles.allSatisfy({ !$0.insetBy(dx: -protectedClearanceDots, dy: -protectedClearanceDots).intersects(clip) }),
                  clip.maxY <= CGFloat(canvasHeight) else { continue }
            regions.append(StickerTargetRegion(target: .receiptRegion(id: id), rect: candidate, clipRect: clip, label: label))
        }
        return regions
    }
}

// MARK: - Frozen decorations and rendering

/// A placement plus its print-prepared still artwork, frozen when the guest taps Done. Reprints,
/// rebuilds and copies reuse these exact pixels; nothing is re-decoded or re-fetched.
nonisolated struct FrozenStickerDecoration: @unchecked Sendable, Equatable {
    let placement: StickerPlacement
    let printImage: CGImage

    static func == (lhs: FrozenStickerDecoration, rhs: FrozenStickerDecoration) -> Bool {
        lhs.placement == rhs.placement && lhs.printImage === rhs.printImage
    }
}

nonisolated enum StickerCompositionRenderer {
    /// Draws stickers in z-order, each clipped to its approved region. Malformed placements or
    /// placements without a measured region are skipped (never drawn outside safe space).
    /// Returns the placements that were drawn.
    @discardableResult
    static func draw(_ decorations: [FrozenStickerDecoration], regions: [StickerTargetRegion], context: CGContext) -> [UUID] {
        var drawn: [UUID] = []
        let ordered = decorations.sorted {
            ($0.placement.zOrder, $0.placement.id.uuidString) < ($1.placement.zOrder, $1.placement.id.uuidString)
        }
        for decoration in ordered {
            guard let region = regions.first(where: { $0.target == decoration.placement.target }),
                  let frame = try? StickerGeometry.resolve(decoration.placement, in: region),
                  frame.size.width >= 1, frame.size.height >= 1 else { continue }
            context.saveGState()
            context.clip(to: frame.clipRect)
            context.translateBy(x: frame.center.x, y: frame.center.y)
            context.rotate(by: frame.rotation)
            context.interpolationQuality = .high
            // UIImage drawing honours the UIKit (top-left origin) coordinate space of the receipt.
            UIImage(cgImage: decoration.printImage, scale: 1, orientation: .up)
                .draw(in: CGRect(x: -frame.size.width / 2, y: -frame.size.height / 2, width: frame.size.width, height: frame.size.height))
            context.restoreGState()
            drawn.append(decoration.placement.id)
        }
        return drawn
    }
}
