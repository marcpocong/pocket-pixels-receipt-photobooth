//
//  CoBrandedReceiptHeader.swift
//  PocketPixelsBooth
//
//  Geometry for the Co-Branded receipt header: the Made to Keep wordmark, a subtle × and the
//  event logo, side by side across the 576-dot paper. Pure values shared by ReceiptComposer and
//  the operator previews so what the operator sees is exactly what prints.
//

import CoreGraphics
import Foundation

nonisolated enum CoBrandedHeaderGeometry {
    /// Identities align with the photographs' white side margins.
    static let sideInset: CGFloat = 36
    /// The × is a vector cross, centred on the paper.
    static let separatorSize: CGFloat = 18
    static let separatorLineWidth: CGFloat = 2
    /// Clear space between the × and each identity.
    static let separatorClearance: CGFloat = 20
    /// Logo box at full size. Wide logos are width-limited, square logos height-limited.
    static let maximumLogoHeight: CGFloat = 104
    static let wordmarkMaximumSize: CGFloat = 46
    static let wordmarkMinimumSize: CGFloat = 30
    /// `studios` keeps the masthead's proportions but never drops below a thermal-safe size.
    static let studiosMinimumSize: CGFloat = 10.5
    static let mastheadWordmarkSize: CGFloat = 55
    static let mastheadStudiosSize: CGFloat = 14
    static let mastheadStudiosTracking: CGFloat = 8.5

    /// Width available to each identity on its side of the ×.
    static func slotWidth(receiptWidth: CGFloat = CGFloat(BoothConfiguration.receiptWidth)) -> CGFloat {
        floor(receiptWidth / 2 - sideInset - separatorSize / 2 - separatorClearance)
    }

    /// Inner edges of the two slots (closest to the ×).
    static func innerEdges(receiptWidth: CGFloat = CGFloat(BoothConfiguration.receiptWidth)) -> (left: CGFloat, right: CGFloat) {
        let center = receiptWidth / 2
        let offset = separatorSize / 2 + separatorClearance
        return (center - offset, center + offset)
    }

    /// Aspect-preserving logo box. Fit never crops; Fill crops to the banner ratio inside the box.
    static func logoFrameSize(sourceSize: CGSize, configuration: ReceiptHeaderConfiguration, receiptWidth: CGFloat = CGFloat(BoothConfiguration.receiptWidth)) -> CGSize {
        let config = configuration.normalized()
        let scale = CGFloat(min(config.scale, ReceiptHeaderConfiguration.maximumEditorScale))
        let maximumWidth = max(1, floor(slotWidth(receiptWidth: receiptWidth) * scale))
        let maximumHeight = max(1, floor(maximumLogoHeight * scale))
        guard sourceSize.width.isFinite, sourceSize.height.isFinite, sourceSize.width > 0, sourceSize.height > 0 else {
            return CGSize(width: maximumWidth, height: min(maximumHeight, 32))
        }
        if config.layoutMode == .fill {
            return CGSize(width: maximumWidth, height: max(1, min(maximumHeight, floor(maximumWidth * CGFloat(config.effectiveFillHeightRatio)))))
        }
        let factor = min(maximumWidth / sourceSize.width, maximumHeight / sourceSize.height)
        return CGSize(width: max(1, floor(sourceSize.width * factor)), height: max(1, floor(sourceSize.height * factor)))
    }

    /// Left x of an element of `width` inside its slot. Position -1 sits beside the ×, 0 centres
    /// in the slot and 1 reaches the outer margin. Both sides mirror the same position.
    static func slotX(width: CGFloat, leftSide: Bool, position: Double, receiptWidth: CGFloat = CGFloat(BoothConfiguration.receiptWidth)) -> CGFloat {
        let slot = slotWidth(receiptWidth: receiptWidth)
        let slack = max(0, slot - width)
        let travel = slack * CGFloat(min(1, max(-1, position)) + 1) / 2
        let edges = innerEdges(receiptWidth: receiptWidth)
        return leftSide ? floor(edges.left - width - travel) : floor(edges.right + travel)
    }

    /// Top inset above the lockup and gap below it. At default spacing they equal the standard
    /// masthead's, so photographs only move by the difference in header height.
    static func verticalSpacing(configuration: ReceiptHeaderConfiguration, mastheadTopInset: Int, mastheadPhotoGap: Int) -> (top: Int, bottom: Int) {
        let config = configuration.normalized()
        let defaults = ReceiptHeaderConfiguration.default
        let top = mastheadTopInset + Int((config.topSpacing - defaults.topSpacing).rounded())
        let bottom = mastheadPhotoGap + Int((config.bottomSpacing - defaults.bottomSpacing).rounded())
        return (max(8, top), max(20, bottom))
    }
}

extension ReceiptHeaderConfiguration {
    /// The polished starting point for a newly added event logo: Co-Branded, whole logo, full
    /// size, beside the ×. Reset returns here.
    nonisolated static let coBrandedRecommended: ReceiptHeaderConfiguration = {
        var value = ReceiptHeaderConfiguration.default
        value.mode = .customEventHeader
        value.brandingMode = .coBranded
        value.horizontalPosition = -1
        return value
    }()
}

/// Additive event design settings. The reference scale freezes the old header midline when
/// independent editing begins, so resizing one identity cannot move the other vertically.
nonisolated struct CoBrandedHeaderAdjustments: Codable, Equatable, Sendable {
    var referenceLogoScale: Double
    var referenceLayoutMode: ReceiptHeaderLayoutMode
    var referenceFillHeightRatio: Double
    var studioScale: Double = 1
    var studioPosition: Double
    var studioY: Double = 0
    var eventPosition: Double
    var eventY: Double = 0
    var compositionScale: Double = 1
    var studioOffsetX: Double = 0
    var eventOffsetX: Double = 0
    var separatorY: Double = 0
    /// Opt-in geometry. Nil keeps both generations of saved headers unchanged.
    var placement: CoBrandedHeaderPlacement?

    init(configuration: ReceiptHeaderConfiguration) {
        referenceLogoScale = configuration.scale
        referenceLayoutMode = configuration.layoutMode
        referenceFillHeightRatio = configuration.effectiveFillHeightRatio
        studioPosition = configuration.effectiveHorizontalPosition
        eventPosition = configuration.effectiveHorizontalPosition
    }

    func normalized() -> Self {
        var v = self
        func bound(_ value: Double, _ range: ClosedRange<Double>, fallback: Double = 0) -> Double {
            min(range.upperBound, max(range.lowerBound, value.isFinite ? value : fallback))
        }
        v.referenceFillHeightRatio = bound(referenceFillHeightRatio, ReceiptHeaderConfiguration.fillHeightRatioRange, fallback: ReceiptHeaderConfiguration.defaultFillHeightRatio)
        v.referenceLogoScale = bound(referenceLogoScale, 0.5...1.35, fallback: 1)
        v.studioScale = bound(studioScale, 0.5...1, fallback: 1)
        v.studioPosition = bound(studioPosition, -1...1)
        v.eventPosition = bound(eventPosition, -1...1)
        v.studioY = bound(studioY, -48...48)
        v.eventY = bound(eventY, -48...48)
        v.compositionScale = bound(compositionScale, 0.5...1, fallback: 1)
        v.studioOffsetX = bound(studioOffsetX, -48...48)
        v.eventOffsetX = bound(eventOffsetX, -48...48)
        v.separatorY = bound(separatorY, -48...48)
        v.placement = placement?.normalized()
        return v
    }
}

extension ReceiptHeaderConfiguration {
    nonisolated mutating func editCoBranded(_ edit: (inout CoBrandedHeaderAdjustments) -> Void) {
        var value = coBrandedAdjustments ?? CoBrandedHeaderAdjustments(configuration: normalized())
        edit(&value)
        coBrandedAdjustments = value.normalized()
    }

    nonisolated mutating func resetStudioIdentity() {
        if coBrandedAdjustments?.placement != nil {
            self = ReceiptComposer.resetHeaderElement(self, target: .studio)
            return
        }
        editCoBranded { $0.studioScale = 1; $0.studioPosition = -1; $0.studioY = 0; $0.studioOffsetX = 0 }
    }

    nonisolated mutating func resetEventIdentity() {
        if coBrandedAdjustments?.placement != nil {
            self = ReceiptComposer.resetHeaderElement(self, target: .event)
            return
        }
        editCoBranded { $0.eventPosition = -1; $0.eventY = 0; $0.eventOffsetX = 0 }
        scale = 1; layoutMode = .fit; cropZoom = 1; cropPositionX = 0; cropPositionY = 0
    }

    nonisolated mutating func resetEntireCoBrandedHeader() {
        let identifier = assetIdentifier
        self = .coBrandedRecommended
        assetIdentifier = identifier
    }
}

/// Centers are printer dots before whole-header scaling/translation. Keeping separate anchors
/// prevents an identity resize from moving its neighbor. The reference scale preserves older edits.
nonisolated struct CoBrandedHeaderPlacement: Codable, Equatable, Sendable {
    var studioX: Double
    var studioY: Double
    var eventX: Double
    var eventY: Double
    var separatorX: Double
    var separatorY: Double
    var separatorScale: Double = 1
    var referenceScale: Double = 1
    var wholeX: Double = 0
    var wholeY: Double = 0
    var referenceTopSpacing: Double = 8
    var pivotY: Double

    func normalized() -> Self {
        var v = self
        func safe(_ n: Double, _ fallback: Double, _ range: ClosedRange<Double>) -> Double {
            min(range.upperBound, max(range.lowerBound, n.isFinite ? n : fallback))
        }
        v.studioX = safe(studioX, 140, 0...576); v.eventX = safe(eventX, 420, 0...576)
        v.studioY = safe(studioY, 70, 0...240); v.eventY = safe(eventY, 70, 0...240)
        v.separatorX = safe(separatorX, 288, 100...476); v.separatorY = safe(separatorY, 70, 0...240)
        v.separatorScale = safe(separatorScale, 1, 0.5...2)
        v.referenceScale = safe(referenceScale, 1, 0.5...1)
        v.wholeX = safe(wholeX, 0, -576...576); v.wholeY = safe(wholeY, 0, -240...240)
        v.referenceTopSpacing = safe(referenceTopSpacing, 8, 0...48)
        v.pivotY = safe(pivotY, 70, 0...240)
        return v
    }
}

nonisolated enum CoBrandedHeaderTarget: String, CaseIterable {
    case whole = "Whole Header", studio = "Made to Keep", separator = "× Separator", event = "Event Logo"
}

extension ReceiptComposer {
    nonisolated static func headerEditingPlan(_ configuration: ReceiptHeaderConfiguration) -> ReceiptLayoutPlan? {
        var profile = EventProfile.pocketPixelsDefault
        profile.isEnabled = true; profile.showEventTextBlock = false; profile.receiptHeader = configuration
        return try? makeLayoutPlan(format: .solo, eventProfile: profile)
    }

    /// Available movement is measured from the final printed frames, including whole scale.
    nonisolated static func headerTravel(_ configuration: ReceiptHeaderConfiguration, target: CoBrandedHeaderTarget,
        vertical: Bool = false) -> ClosedRange<Double> {
        let configuration = prepareCoBrandedEditing(configuration)
        guard let plan = headerEditingPlan(configuration), let logo = plan.customHeaderFrame,
              let cross = plan.coBrandSeparatorFrame, let a = configuration.coBrandedAdjustments,
              let p = a.placement else { return 0...0 }
        let studio = plan.mastheadFrames.reduce(CGRect.null) { $0.union($1) }
        let bounds = studio.union(logo).union(cross)
        let rect: CGRect = switch target {
        case .whole: bounds
        case .studio: studio
        case .separator: cross
        case .event: logo
        }
        let scale = CGFloat(a.compositionScale)
        let spacingY = max(8, configuration.topSpacing) - max(8, p.referenceTopSpacing)
        let localY = p.pivotY + (rect.midY - p.wholeY - spacingY - p.pivotY) / scale
        if vertical {
            let upper = target == .whole ? 240 - p.wholeY : (240 - localY) * scale
            return Double(min(0, CGFloat(plan.headerStartY + 8) - rect.minY))...Double(max(0, upper))
        }
        let gap = 8 * scale
        let lower: CGFloat, upper: CGFloat
        switch target {
        case .whole: lower = 36 - bounds.minX; upper = 540 - bounds.maxX
        case .studio: lower = 36 - studio.minX; upper = cross.minX - gap - studio.maxX
        case .separator: lower = studio.maxX + gap - cross.minX; upper = logo.minX - gap - cross.maxX
        case .event: lower = cross.maxX + gap - logo.minX; upper = 540 - logo.maxX
        }
        let localX = 288 + (rect.midX - p.wholeX - 288) / scale
        let allowed: ClosedRange<Double> = switch target {
        case .whole: -576...576
        case .separator: 100...476
        default: 0...576
        }
        let current = target == .whole ? p.wholeX : localX
        let multiplier = target == .whole ? 1 : scale
        return Double(min(0, max(lower, (allowed.lowerBound - current) * multiplier)))...Double(max(0, min(upper, (allowed.upperBound - current) * multiplier)))
    }

    nonisolated static func moveHeaderElement(_ configuration: ReceiptHeaderConfiguration, target: CoBrandedHeaderTarget,
        horizontal: Double = 0, vertical: Double = 0) -> ReceiptHeaderConfiguration {
        var config = prepareCoBrandedEditing(configuration)
        guard var a = config.coBrandedAdjustments, var p = a.placement else { return configuration }
        let x = headerTravel(config, target: target)
        let y = headerTravel(config, target: target, vertical: true)
        let dx = min(x.upperBound, max(x.lowerBound, horizontal.isFinite ? horizontal : 0))
        let dy = min(y.upperBound, max(y.lowerBound, vertical.isFinite ? vertical : 0))
        let scale = a.compositionScale
        guard let plan = headerEditingPlan(config), let logo = plan.customHeaderFrame,
              let cross = plan.coBrandSeparatorFrame, let wordmark = plan.mastheadFrames.first else { return configuration }
        let studio = plan.mastheadFrames.reduce(CGRect.null) { $0.union($1) }
        let spacingY = max(8, config.topSpacing) - max(8, p.referenceTopSpacing)
        func localX(_ x: Double) -> Double { 288 + (x + dx - p.wholeX - 288) / scale }
        func localY(_ y: Double) -> Double { p.pivotY + (y + dy - p.wholeY - spacingY - p.pivotY) / scale }
        // Use resolved centers, not an old request that may have been clamped by a resize.
        switch target {
        case .whole: p.wholeX += dx; p.wholeY += dy
        case .studio:
            p.studioX = localX(wordmark.midX - a.studioScale * p.referenceScale * scale / 2)
            p.studioY = localY(studio.midY)
        case .separator: p.separatorX = localX(cross.midX); p.separatorY = localY(cross.midY)
        case .event: p.eventX = localX(logo.midX); p.eventY = localY(logo.midY)
        }
        a.placement = p.normalized(); config.coBrandedAdjustments = a
        return config
    }
}

extension ReceiptComposer {
    nonisolated static func headerMaximumScale(_ configuration: ReceiptHeaderConfiguration, target: CoBrandedHeaderTarget,
        current: Double, maximum: Double) -> Double {
        let configuration = prepareCoBrandedEditing(configuration)
        guard let plan = headerEditingPlan(configuration), let logo = plan.customHeaderFrame,
              let cross = plan.coBrandSeparatorFrame else { return maximum }
        let studio = plan.mastheadFrames.reduce(CGRect.null) { $0.union($1) }
        let gap = 8 * CGFloat(configuration.coBrandedAdjustments?.compositionScale ?? 1)
        var factor: CGFloat = 1
        switch target {
        case .studio: factor = (cross.minX - gap - 36) / studio.width
        case .event: factor = (540 - cross.maxX - gap) / logo.width
        case .separator:
            factor = max(0, min(cross.midX - studio.maxX - gap, logo.minX - gap - cross.midX) * 2 / cross.width)
        case .whole:
            let bounds = studio.union(logo).union(cross)
            let p = configuration.coBrandedAdjustments?.placement
            let spacingY = max(8, configuration.topSpacing) - max(8, p?.referenceTopSpacing ?? configuration.topSpacing)
            let pivot = CGPoint(x: 288 + (p?.wholeX ?? 0), y: (p?.pivotY ?? cross.midY) + (p?.wholeY ?? 0) + spacingY)
            let limits: [(CGFloat, CGFloat)] = [(pivot.x - 36, pivot.x - bounds.minX),
                (540 - pivot.x, bounds.maxX - pivot.x), (pivot.y - CGFloat(plan.headerStartY + 8), pivot.y - bounds.minY)]
            factor = limits.filter { $0.1 > 0 }.map { $0.0 / $0.1 }.min() ?? 1
        }
        return max(0.5, min(maximum, current * Double(factor)))
    }

    nonisolated static func resetHeaderElement(_ configuration: ReceiptHeaderConfiguration,
        target: CoBrandedHeaderTarget) -> ReceiptHeaderConfiguration {
        var config = prepareCoBrandedEditing(configuration)
        var recommended = ReceiptHeaderConfiguration.coBrandedRecommended
        recommended.assetIdentifier = config.assetIdentifier
        guard let plan = headerEditingPlan(recommended), let cross = plan.coBrandSeparatorFrame,
              let logo = plan.customHeaderFrame, let wordmark = plan.mastheadFrames.first,
              var a = config.coBrandedAdjustments, var p = a.placement else { return configuration }
        switch target {
        case .whole: a.compositionScale = 1; p.wholeX = 0; p.wholeY = 0
        case .studio:
            a.studioScale = 1
            p.studioX = wordmark.midX - 0.5
            p.studioY = plan.mastheadFrames.reduce(CGRect.null) { $0.union($1) }.midY
        case .separator:
            if let current = headerEditingPlan(config), let event = current.customHeaderFrame {
                let studioRight = current.mastheadFrames.map(\.maxX).max() ?? 36
                let scale = a.compositionScale
                let gap = 8 * scale
                let size = min(18 * scale, max(1, event.minX - studioRight - gap * 2))
                let desiredX = 288 + p.wholeX
                let centerX = min(event.minX - gap - size / 2, max(studioRight + gap + size / 2, desiredX))
                p.separatorScale = size / scale / 18
                p.separatorX = 288 + (centerX - p.wholeX - 288) / scale
            }
            p.separatorY = cross.midY
        case .event:
            config.scale = 1; config.layoutMode = .fit; config.fillHeightRatio = nil
            config.cropZoom = 1; config.cropPositionX = 0; config.cropPositionY = 0
            p.eventX = logo.midX; p.eventY = logo.midY
        }
        a.placement = p; config.coBrandedAdjustments = a.normalized()
        return config
    }
}

/// Editor availability only. Resolve the production frames to remove slider ranges that the
/// renderer would entirely consume through clamping; opening a design never writes these values.
extension ReceiptComposer {
    nonisolated static func headerSizeAvailability(_ configuration: ReceiptHeaderConfiguration,
        target: CoBrandedHeaderTarget, current: Double, maximum: Double) -> (limit: Double, canResize: Bool) {
        let prepared = prepareCoBrandedEditing(configuration)
        let upper = headerMaximumScale(prepared, target: target, current: current, maximum: maximum)
        func size(at value: Double) -> CGSize? {
            var candidate = prepared
            switch target {
            case .whole: candidate.coBrandedAdjustments?.compositionScale = value
            case .studio: candidate.coBrandedAdjustments?.studioScale = value
            case .separator: candidate.coBrandedAdjustments?.placement?.separatorScale = value
            case .event: candidate.scale = value
            }
            guard let plan = headerEditingPlan(candidate), let rect = ReceiptEditorGeometry(plan: plan).elements[target] else { return nil }
            return rect.size
        }
        guard upper > 0.501, let smallest = size(at: 0.5), let largest = size(at: upper),
              abs(largest.width - smallest.width) > 0.5 || abs(largest.height - smallest.height) > 0.5 else { return (0.5, false) }
        var low = 0.5, high = upper
        // Find the beginning of the maximum-size plateau. Below it the selected artwork
        // responds to the slider, with the engine still owning margins, aspect and collisions.
        for _ in 0..<12 {
            let middle = (low + high) / 2
            guard let measured = size(at: middle) else { return (0.5, false) }
            if abs(measured.width - largest.width) < 0.01 && abs(measured.height - largest.height) < 0.01 { high = middle }
            else { low = middle }
        }
        return (high, true)
    }
}
