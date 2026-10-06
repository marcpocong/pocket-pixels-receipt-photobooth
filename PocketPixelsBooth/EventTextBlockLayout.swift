//
//  EventTextBlockLayout.swift
//  PocketPixelsBooth
//
//  Lays out and draws the event text block (eyebrow, title, subtitle, date/location, message)
//  below the receipt header. ReceiptComposer owns placement and validation; this type owns
//  font fitting so every role stays inside its own measured region.
//

import Foundation
import UIKit

nonisolated struct EventTextBlockFrame: Sendable, Equatable {
    let role: EventTextRole
    /// Text exactly as drawn (case transforms already applied).
    let text: String
    let rect: CGRect
    let face: EventFontSpec
    let fontSize: CGFloat
    let tracking: CGFloat
    let lineSpacing: CGFloat
    let wrapping: EventTextWrapping
    let alignment: EventTextAlignment

    var font: UIFont { face.font(size: fontSize) }
}

nonisolated enum EventTextBlockLayout {
    nonisolated static let eyebrowBottomGap = 5
    nonisolated static let titleBottomGap = 5
    nonisolated static let detailGap = 4

    /// Returns frames from `y` downward and the y just below the last line (no trailing padding).
    nonisolated static func make(
        content: EventReceiptBlockContent,
        typography: ResolvedEventTypography,
        x: Int,
        y startY: Int,
        width: Int
    ) -> (frames: [EventTextBlockFrame], bottom: Int) {
        var y = startY
        var frames: [EventTextBlockFrame] = []
        let entries: [(EventTextRole, String, Int)] = [
            (.eyebrow, content.eyebrow, eyebrowBottomGap),
            (.title, content.eventName, titleBottomGap),
            (.subtitle, content.subtitle, detailGap),
            (.metadata, content.metadata, detailGap),
            (.message, content.message, 0)
        ]
        for (index, entry) in entries.enumerated() {
            let (role, rawText, gap) = entry
            // Eyebrow and title always render; optional details are skipped when empty.
            guard role == .eyebrow || role == .title || !rawText.isEmpty else { continue }
            let style = typography.style(for: role)
            let text = style.uppercased ? rawText.uppercased() : rawText
            let fitted = fit(text, style: style, width: width)
            frames.append(EventTextBlockFrame(
                role: role,
                text: text,
                rect: CGRect(x: x, y: y, width: width, height: fitted.height),
                face: style.face,
                fontSize: fitted.size,
                tracking: style.tracking,
                lineSpacing: style.lineSpacing,
                wrapping: style.wrapping,
                alignment: typography.alignment
            ))
            y += fitted.height
            if index < entries.count - 1 { y += gap }
        }
        return (frames, y)
    }

    /// Largest candidate size that sets the text within the style's target line count. At the
    /// minimum size the text wraps further; the returned height always contains every line.
    nonisolated static func fit(_ text: String, style: EventTextRoleStyle, width: Int) -> (size: CGFloat, height: Int) {
        let candidates = style.candidateSizes
        for size in candidates {
            let font = style.face.font(size: size)
            let height = measuredHeight(text, font: font, width: width, tracking: style.tracking, lineSpacing: style.lineSpacing, wrapping: style.wrapping)
            let limit = Int(ceil(font.lineHeight * (CGFloat(max(1, style.targetLines)) + 0.35)))
            if height <= limit || size == candidates.last {
                return (size, height)
            }
        }
        let size = candidates.last ?? style.minimumSize
        let font = style.face.font(size: size)
        return (size, measuredHeight(text, font: font, width: width, tracking: style.tracking, lineSpacing: style.lineSpacing, wrapping: style.wrapping))
    }

    nonisolated static func measuredHeight(
        _ text: String,
        font: UIFont,
        width: Int,
        tracking: CGFloat,
        lineSpacing: CGFloat,
        wrapping: EventTextWrapping
    ) -> Int {
        let rect = NSString(string: text).boundingRect(
            with: CGSize(width: CGFloat(width), height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes(font: font, tracking: tracking, lineSpacing: lineSpacing, wrapping: wrapping, alignment: .center),
            context: nil
        )
        return max(Int(ceil(rect.height)), Int(ceil(font.lineHeight)))
    }

    /// True when every line of the text fits horizontally inside its frame (used by tests and
    /// the debug self-checks; drawing itself never extends past the frame width).
    nonisolated static func fitsHorizontally(_ frame: EventTextBlockFrame) -> Bool {
        let measured = NSString(string: frame.text).boundingRect(
            with: CGSize(width: frame.rect.width, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes(font: frame.font, tracking: frame.tracking, lineSpacing: frame.lineSpacing, wrapping: frame.wrapping, alignment: frame.alignment.nsTextAlignment),
            context: nil
        )
        return measured.width <= frame.rect.width + 0.5 && ceil(measured.height) <= frame.rect.height
    }

    nonisolated static func draw(_ frames: [EventTextBlockFrame]) {
        for frame in frames {
            var attributes = attributes(
                font: frame.font,
                tracking: frame.tracking,
                lineSpacing: frame.lineSpacing,
                wrapping: frame.wrapping,
                alignment: frame.alignment.nsTextAlignment
            )
            attributes[.foregroundColor] = UIColor.black
            NSString(string: frame.text).draw(
                in: CGRect(
                    x: Int(frame.rect.minX),
                    y: Int(frame.rect.minY),
                    width: Int(frame.rect.width),
                    height: Int(frame.rect.height) + 2
                ),
                withAttributes: attributes
            )
        }
    }

    nonisolated private static func attributes(
        font: UIFont,
        tracking: CGFloat,
        lineSpacing: CGFloat,
        wrapping: EventTextWrapping,
        alignment: NSTextAlignment
    ) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = wrapping.lineBreakMode
        paragraph.lineSpacing = lineSpacing
        return [
            .font: font,
            .kern: tracking,
            .paragraphStyle: paragraph
        ]
    }
}
