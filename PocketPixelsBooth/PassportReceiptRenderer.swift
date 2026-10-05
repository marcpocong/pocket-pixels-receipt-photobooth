//
//  PassportReceiptRenderer.swift
//  PocketPixelsBooth
//
//  Draws a frozen PassportReceiptLayout into the receipt context. Everything is pure black on
//  white with 2–3 dot strokes: no hairlines, no grey fills and no large dark areas, so the
//  cards survive 1-bit thermal rasterization on the VOZY G80.
//

import UIKit

nonisolated enum PassportReceiptRenderer {
    nonisolated static func draw(
        content: PassportReceiptContent,
        layout: PassportReceiptLayout,
        portraitPhoto: UIImage,
        heroPhoto: UIImage,
        headerGraphic: UIImage?,
        context: CGContext
    ) {
        context.saveGState()
        defer { context.restoreGState() }

        for card in [layout.upperCard, layout.lowerCard] {
            drawCardFrame(card, theme: layout.theme, context: context)
        }

        drawPhoto(heroPhoto, in: layout.heroPhotoRect, context: context)
        drawPhoto(portraitPhoto, in: layout.portraitPhotoRect, context: context)

        if let headerGraphic, let rect = layout.headerGraphicRect {
            context.saveGState()
            context.clip(to: rect)
            context.interpolationQuality = .high
            UIColor.white.setFill()
            context.fill(rect)
            headerGraphic.draw(in: rect)
            context.restoreGState()
        }

        if let stampRect = layout.stampRect {
            drawStamp(in: stampRect, theme: layout.theme, context: context)
        }
        if let starBandRect = layout.starBandRect {
            drawStarBand(in: starBandRect, context: context)
        }

        UIColor.black.setFill()
        for underline in layout.underlines {
            context.fill(underline)
        }

        for block in layout.allTexts {
            drawText(block)
        }

        if !content.signature.isEmpty {
            context.saveGState()
            context.addPath(content.signature.path(in: layout.signatureRect))
            context.setStrokeColor(UIColor.black.cgColor)
            context.setLineWidth(3)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.strokePath()
            context.restoreGState()
        }
    }

    // MARK: Card frames

    nonisolated private static func drawCardFrame(_ card: CGRect, theme: PassportTheme, context: CGContext) {
        let border = PassportReceiptLayout.borderWidth
        let outer = UIBezierPath(
            roundedRect: card.insetBy(dx: border / 2, dy: border / 2),
            cornerRadius: PassportReceiptLayout.cardCornerRadius
        )
        outer.lineWidth = border
        UIColor.black.setStroke()
        outer.stroke()

        switch theme {
        case .classic:
            let inner = UIBezierPath(roundedRect: card.insetBy(dx: 8, dy: 8), cornerRadius: PassportReceiptLayout.cardCornerRadius - 7)
            inner.lineWidth = 2
            inner.stroke()
        case .stars:
            // Three stars set into the top and bottom borders, knocked out of the line.
            for y in [card.minY + border / 2, card.maxY - border / 2] {
                for (offset, radius) in [(-22.0, 5.0), (0.0, 7.5), (22.0, 5.0)] as [(CGFloat, CGFloat)] {
                    fillStar(center: CGPoint(x: card.midX + offset, y: y), radius: radius, context: context, knockout: true)
                }
            }
        case .minimal:
            break
        case .event:
            let inner = UIBezierPath(roundedRect: card.insetBy(dx: 8, dy: 8), cornerRadius: PassportReceiptLayout.cardCornerRadius - 7)
            inner.lineWidth = 2
            inner.setLineDash([8, 6], count: 2, phase: 0)
            inner.stroke()
            // Ticket notches on both sides of each card.
            for x in [card.minX, card.maxX] {
                let center = CGPoint(x: x, y: card.midY)
                let notch = CGRect(x: center.x - 11, y: center.y - 11, width: 22, height: 22)
                UIColor.white.setFill()
                context.fillEllipse(in: notch)
                let arc = UIBezierPath(ovalIn: notch.insetBy(dx: border / 2, dy: border / 2))
                arc.lineWidth = border
                context.saveGState()
                context.clip(to: card)
                arc.stroke()
                context.restoreGState()
            }
        }
    }

    nonisolated private static func drawPhoto(_ image: UIImage, in rect: CGRect, context: CGContext) {
        context.saveGState()
        context.interpolationQuality = .high
        image.draw(in: rect)
        context.restoreGState()
        UIColor.black.setStroke()
        context.setLineWidth(PassportReceiptLayout.photoBorderWidth)
        context.stroke(rect.insetBy(dx: PassportReceiptLayout.photoBorderWidth / 2, dy: PassportReceiptLayout.photoBorderWidth / 2))
    }

    // MARK: Motifs

    nonisolated private static func drawStamp(in rect: CGRect, theme: PassportTheme, context: CGContext) {
        UIColor.black.setStroke()
        switch theme {
        case .classic:
            let outer = UIBezierPath(ovalIn: rect.insetBy(dx: 1.5, dy: 1.5))
            outer.lineWidth = 3
            outer.stroke()
            let inner = UIBezierPath(ovalIn: rect.insetBy(dx: 7, dy: 7))
            inner.lineWidth = 2
            inner.setLineDash([4, 4], count: 2, phase: 0)
            inner.stroke()
            fillStar(center: CGPoint(x: rect.midX, y: rect.minY + 1.5), radius: 5.5, context: context, knockout: true)
            fillStar(center: CGPoint(x: rect.midX, y: rect.maxY - 1.5), radius: 5.5, context: context, knockout: true)
        case .event:
            let box = UIBezierPath(roundedRect: rect.insetBy(dx: 1.5, dy: 1.5), cornerRadius: 6)
            box.lineWidth = 3
            box.stroke()
            let inner = UIBezierPath(roundedRect: rect.insetBy(dx: 6, dy: 6), cornerRadius: 3)
            inner.lineWidth = 2
            inner.stroke()
        case .stars, .minimal:
            break
        }
    }

    nonisolated private static func drawStarBand(in rect: CGRect, context: CGContext) {
        let count = 5
        let radius = min(rect.height / 2, 7)
        let spacing = (rect.width - radius * 2) / CGFloat(count - 1)
        for index in 0..<count {
            let size = index.isMultiple(of: 2) ? radius : radius * 0.7
            fillStar(center: CGPoint(x: rect.minX + radius + spacing * CGFloat(index), y: rect.midY), radius: size, context: context)
        }
    }

    nonisolated private static func fillStar(center: CGPoint, radius: CGFloat, context: CGContext, knockout: Bool = false) {
        let path = CGMutablePath()
        for index in 0..<10 {
            let angle = -CGFloat.pi / 2 + CGFloat(index) * CGFloat.pi / 5
            let length = index.isMultiple(of: 2) ? radius : radius * 0.45
            let point = CGPoint(x: center.x + cos(angle) * length, y: center.y + sin(angle) * length)
            if index == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        path.closeSubpath()
        if knockout {
            UIColor.white.setFill()
            context.fillEllipse(in: CGRect(x: center.x - radius - 2, y: center.y - radius - 2, width: (radius + 2) * 2, height: (radius + 2) * 2))
        }
        context.addPath(path)
        context.setFillColor(UIColor.black.cgColor)
        context.fillPath()
    }

    // MARK: Text

    nonisolated private static func drawText(_ block: PassportTextBlock) {
        guard !block.text.isEmpty else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = block.alignment
        paragraph.lineBreakMode = block.maximumLines == 1 ? .byTruncatingTail : (block.wrapsByCharacter ? .byCharWrapping : .byWordWrapping)
        let attributed = NSAttributedString(string: block.text, attributes: [
            .font: block.font.font,
            .kern: block.tracking,
            .foregroundColor: UIColor.black,
            .paragraphStyle: paragraph
        ])
        attributed.draw(
            with: CGRect(x: block.rect.minX, y: block.rect.minY, width: block.rect.width, height: block.rect.height + 1),
            options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine],
            context: nil
        )
    }
}
