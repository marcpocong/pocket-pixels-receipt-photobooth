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
