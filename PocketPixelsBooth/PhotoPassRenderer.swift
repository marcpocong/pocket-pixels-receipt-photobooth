//
//  PhotoPassRenderer.swift
//  PocketPixelsBooth
//
//  Draws a PhotoPassReceiptLayout. The static template (cards, star borders, wordmarks, labels,
//  frames, grid, accents) is recreated in Core Graphics from the Photo Pass reference instead of
//  shipping the screen artwork as a bitmap, so every star and rule lands on whole printer dots.
//  Artwork is solid black on white with antialiasing off and strokes of 2 dots or more, so it
//  reaches the VOZY G80 as clean 1-bit shapes instead of dithered grey edges. Only the photos
//  carry continuous tone.
//

import UIKit

nonisolated enum PhotoPassRenderer {
    nonisolated static func draw(
        content: PhotoPassContent,
        layout: PhotoPassReceiptLayout,
        portraitPhoto: UIImage,
        heroPhoto: UIImage,
        context: CGContext
    ) {
        context.saveGState()
        defer { context.restoreGState() }

        // Dynamic photos go down first so the static frames and corner stars sit on top of them.
        drawPhoto(heroPhoto, in: layout.template.heroPhotoRect, context: context)
        drawPhoto(portraitPhoto, in: layout.template.portraitPhotoRect, context: context)

        drawStaticTemplate(layout, context: context)
        drawDynamicText(layout, signature: content.signature, context: context)
    }

    // MARK: Static layer

    nonisolated static func drawStaticTemplate(_ layout: PhotoPassReceiptLayout, context: CGContext) {
        let template = layout.template
        let metrics = PhotoPassTemplateLayout.Metrics.self
        context.saveGState()
        defer { context.restoreGState() }
        context.setShouldAntialias(false)
        UIColor.black.setStroke()
        UIColor.black.setFill()

        for card in template.cards {
            let outer = UIBezierPath(
                roundedRect: card.insetBy(dx: metrics.outerBorderWidth / 2, dy: metrics.outerBorderWidth / 2),
                cornerRadius: metrics.cornerRadius - metrics.outerBorderWidth / 2
            )
            outer.lineWidth = metrics.outerBorderWidth
            outer.stroke()
            for center in PhotoPassTemplateLayout.borderStarCenters(for: card) {
                fillStar(center: center, radius: metrics.borderStarRadius, context: context)
            }
        }

        // Thin frames around both photo openings and the field grid. Cell dividers are drawn once
        // on the shared edge so inner lines match the outer frame instead of doubling up.
        let line = metrics.lineWidth
        context.setLineWidth(line)
        for rect in [template.heroPhotoRect, template.portraitPhotoRect, template.gridRect] {
            context.stroke(rect.insetBy(dx: line / 2, dy: line / 2))
        }
        for cell in template.fields.map(\.cellRect) {
            if cell.minY > template.gridRect.minY {
                context.fill(CGRect(x: cell.minX, y: cell.minY - line / 2, width: cell.width, height: line))
            }
            if cell.minX > template.gridRect.minX {
                context.fill(CGRect(x: cell.minX - line / 2, y: cell.minY, width: line, height: cell.height))
            }
        }
        for rule in template.ornamentRules {
            context.fill(rule)
        }

        for block in layout.labelTexts {
            drawText(block)
        }
        for wordmark in layout.wordmarks {
            drawWordmark(wordmark, context: context)
        }

        // Accent stars are knocked out of whatever is underneath, opening the frame lines.
        for star in template.accentStars {
            context.addPath(starPath(center: star.center, radius: star.radius))
            context.setStrokeColor(UIColor.white.cgColor)
            context.setLineWidth(metrics.accentStarHalo * 2)
            context.setLineJoin(.round)
            context.strokePath()
            fillStar(center: star.center, radius: star.radius, context: context)
        }
    }

    // MARK: Dynamic layer

    nonisolated static func drawDynamicText(_ layout: PhotoPassReceiptLayout, signature: PassportSignature, context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }
        context.setShouldAntialias(false)

        for block in layout.valueTexts {
            drawText(block)
        }

        guard !signature.isEmpty else { return }
        // Aliased like the rest of the artwork: antialiased edges dither into speckles at 1-bit.
        context.clip(to: layout.template.signatureBoxRect)
        context.addPath(signature.path(in: layout.template.signatureRect))
        context.setStrokeColor(UIColor.black.cgColor)
        context.setLineWidth(3)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.strokePath()
    }

    // MARK: Primitives

    nonisolated private static func drawPhoto(_ image: UIImage, in rect: CGRect, context: CGContext) {
        context.saveGState()
        context.interpolationQuality = .high
        context.clip(to: rect)
        image.draw(in: rect)
        context.restoreGState()
    }

    nonisolated static func starPath(center: CGPoint, radius: CGFloat) -> CGPath {
        let path = CGMutablePath()
        for index in 0..<10 {
            let angle = -CGFloat.pi / 2 + CGFloat(index) * CGFloat.pi / 5
            // A slightly full inner radius keeps the small border stars solid at 1-bit.
            let length = index.isMultiple(of: 2) ? radius : radius * 0.46
            let point = CGPoint(x: center.x + cos(angle) * length, y: center.y + sin(angle) * length)
            if index == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        path.closeSubpath()
        return path
    }

    nonisolated private static func fillStar(center: CGPoint, radius: CGFloat, context: CGContext) {
        context.addPath(starPath(center: center, radius: radius))
        context.setFillColor(UIColor.black.cgColor)
        context.fillPath()
    }

    /// Ink added on each side by the wordmark's thickening stroke (stroke width is a percentage
    /// of the point size and straddles the glyph outline).
    nonisolated static func wordmarkStrokeOutset(for size: CGFloat) -> CGFloat {
        size * wordmarkStrokePercent / 100 / 2
    }

    nonisolated private static let wordmarkStrokePercent: CGFloat = 2.5

    /// Script wordmark, thickened with a fill-and-stroke so its hairlines survive 1-bit printing,
    /// with the glyph ink centred in its box.
    nonisolated private static func drawWordmark(_ wordmark: PhotoPassWordmark, context: CGContext) {
        let font = wordmark.font.font
        let text = NSAttributedString(string: wordmark.text, attributes: [
            .font: font,
            .foregroundColor: UIColor.black,
            .strokeColor: UIColor.black,
            .strokeWidth: -wordmarkStrokePercent
        ])
        let length = wordmark.isVertical ? wordmark.rect.height : wordmark.rect.width
        let thickness = wordmark.isVertical ? wordmark.rect.width : wordmark.rect.height
        let ink = wordmark.inkBounds
        // Ink bounds are y-up from the baseline; the local drawing space is y-down.
        let baseline = (thickness + ink.height) / 2 + ink.minY
        let condense = PhotoPassWordmark.condense
        let originX = (length / condense - ink.width) / 2 - ink.minX

        context.saveGState()
        context.clip(to: wordmark.rect.insetBy(dx: -1, dy: -1))
        if wordmark.isVertical {
            // Baseline runs bottom to top; letter tops face the card's left edge.
            context.translateBy(x: wordmark.rect.minX, y: wordmark.rect.maxY)
            context.rotate(by: -.pi / 2)
        } else {
            context.translateBy(x: wordmark.rect.minX, y: wordmark.rect.minY)
        }
        context.scaleBy(x: condense, y: 1)
        text.draw(at: CGPoint(x: originX, y: baseline - font.ascender))
        context.restoreGState()
    }

    nonisolated private static func drawText(_ block: PassportTextBlock) {
        guard !block.text.isEmpty else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = block.alignment
        paragraph.lineBreakMode = block.maximumLines == 1 ? .byTruncatingTail : (block.wrapsByCharacter ? .byCharWrapping : .byWordWrapping)
        NSAttributedString(string: block.text, attributes: [
            .font: block.font.font,
            .kern: block.tracking,
            .foregroundColor: UIColor.black,
            .paragraphStyle: paragraph
        ]).draw(
            with: CGRect(x: block.rect.minX, y: block.rect.minY, width: block.rect.width, height: block.rect.height + 1),
            options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine],
            context: nil
        )
    }
}
