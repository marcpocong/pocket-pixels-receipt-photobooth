//
//  EmojiSticker.swift
//  PocketPixelsBooth
//
//  Native Unicode emoji stickers. A sticker is exactly one validated extended grapheme cluster,
//  drawn by Apple's own text stack (Core Text + the system Apple Color Emoji font). Nothing here
//  uses private API or bundles emoji artwork: the glyph is rendered on this iPad at insert time.
//
//  - `EmojiGlyphValidator`  One grapheme, emoji-only scalars, supported by the system font.
//  - `EmojiStickerRenderer` Colour artwork for the editor and the matching thermal print artwork.
//

import CoreGraphics
import CoreText
import Foundation
import UIKit

nonisolated enum EmojiValidationError: Error, LocalizedError, Equatable, Sendable {
    case empty
    case tooLong
    case multipleCharacters
    case notEmoji
    case standaloneComponent
    case unsupportedOnDevice
    case renderFailed

    var errorDescription: String? {
        switch self {
        case .empty: "Choose an emoji."
        case .tooLong: "That's too much text. Choose a single emoji."
        case .multipleCharacters: "Choose just one emoji at a time."
        case .notEmoji: "Only emoji can be used as stickers."
        case .standaloneComponent: "That piece can't be used on its own. Choose a complete emoji."
        case .unsupportedOnDevice: "This emoji isn't available on this iPad. Try another one."
        case .renderFailed: "That emoji couldn't be prepared for printing. Try another one."
        }
    }
}

nonisolated enum EmojiGlyphValidator {
    /// Raw keyboard or paste input beyond this many UTF-16 units is rejected before any parsing.
    static let maximumInputUTF16Length = 128
    /// The longest RGI sequences (couples with two skin tones, subdivision flags) use 10 scalars.
    static let maximumScalarCount = 16
    static let emojiFontName = "AppleColorEmoji"

    /// Returns the normalized emoji (a bare text-default pictograph gains U+FE0F) or why it was refused.
    static func validate(_ input: String) -> Result<String, EmojiValidationError> {
        guard input.utf16.count <= maximumInputUTF16Length else { return .failure(.tooLong) }
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.empty) }
        guard trimmed.count == 1, let character = trimmed.first else { return .failure(.multipleCharacters) }
        let scalars = Array(character.unicodeScalars)
        guard scalars.count <= maximumScalarCount else { return .failure(.tooLong) }

        var normalized = String(character)
        if scalars.count == 1 {
            let scalar = scalars[0]
            if scalar.properties.isEmojiModifier || isRegionalIndicator(scalar) {
                return .failure(.standaloneComponent)
            }
            // ASCII digits, '#' and '*' are "emoji" only as keycaps.
            guard scalar.properties.isEmoji, scalar.value > 0x7F, !isJoinerOrSelector(scalar) else {
                return .failure(.notEmoji)
            }
            if !scalar.properties.isEmojiPresentation {
                normalized.unicodeScalars.append(Self.emojiPresentationSelector)
            }
        } else {
            guard let first = scalars.first,
                  !first.properties.isEmojiModifier, !isJoinerOrSelector(first) else {
                return .failure(.standaloneComponent)
            }
            let allowed = scalars.allSatisfy { scalar in
                scalar.properties.isEmoji || scalar.properties.isEmojiModifier || isJoinerOrSelector(scalar)
                    || isRegionalIndicator(scalar) || isTag(scalar) || scalar.value == 0x20E3
            }
            guard allowed else { return .failure(.notEmoji) }
            let regionalIndicators = scalars.filter(isRegionalIndicator)
            if !regionalIndicators.isEmpty {
                // A flag is exactly two regional indicators and nothing else.
                guard regionalIndicators.count == 2, scalars.count == 2 else { return .failure(.notEmoji) }
            }
            let hasEmojiForm = scalars.contains { $0.properties.isEmojiPresentation || $0.value == 0xFE0F || $0.value == 0x20E3 }
            guard hasEmojiForm else { return .failure(.notEmoji) }
            if first.value <= 0x7F, !scalars.contains(where: { $0.value == 0x20E3 }) {
                return .failure(.notEmoji)
            }
        }

        guard isSingleSystemEmojiGlyph(normalized) else { return .failure(.unsupportedOnDevice) }
        return .success(normalized)
    }

    static func isValid(_ input: String) -> Bool {
        if case .success = validate(input) { return true }
        return false
    }

    /// True when the system emoji font draws this text as exactly one visible glyph. Unknown ZWJ
    /// or skin-tone combinations fall apart into several glyphs, and missing ones use another font.
    static func isSingleSystemEmojiGlyph(_ text: String) -> Bool {
        let font = CTFontCreateWithName(emojiFontName as CFString, 64, nil)
        guard (CTFontCopyPostScriptName(font) as String) == emojiFontName else { return false }
        let attributed = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
        let line = CTLineCreateWithAttributedString(attributed)
        guard let runs = CTLineGetGlyphRuns(line) as? [CTRun] else { return false }
        var visibleGlyphs = 0
        for run in runs {
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            let attributes = CTRunGetAttributes(run) as NSDictionary
            guard let value = attributes[kCTFontAttributeName as String] else { return false }
            let runFont = value as! CTFont
            guard (CTFontCopyPostScriptName(runFont) as String) == emojiFontName else { return false }
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var advances = [CGSize](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
            CTRunGetAdvances(run, CFRange(location: 0, length: count), &advances)
            for (glyph, advance) in zip(glyphs, advances) {
                if glyph == 0 { return false }
                if advance.width > 0.5 { visibleGlyphs += 1 }
            }
        }
        return visibleGlyphs == 1
    }

    static let emojiPresentationSelector = Unicode.Scalar(0xFE0F)!

    private static func isRegionalIndicator(_ scalar: Unicode.Scalar) -> Bool {
        (0x1F1E6...0x1F1FF).contains(scalar.value)
    }

    private static func isJoinerOrSelector(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value == 0x200D || scalar.value == 0xFE0F || scalar.value == 0xFE0E
    }

    private static func isTag(_ scalar: Unicode.Scalar) -> Bool {
        (0xE0020...0xE007F).contains(scalar.value)
    }
}

/// The two images one emoji sticker needs. They share pixel size and framing, so the editor and
/// the printed receipt resolve the same `StickerGeometry`; only the ink differs.
nonisolated struct EmojiStickerArtwork: @unchecked Sendable {
    let glyph: String
    /// Native colour glyph on transparency, for the live editor.
    let display: CGImage
    /// Toned, outlined and print-prepared (grayscale, alpha snapped) — exactly what is printed.
    let print: CGImage
    /// Guest-facing note when the glyph is likely to print faintly; nil when it should be clear.
    let printWarning: String?

    var aspectRatio: Double { Double(display.width) / Double(max(1, display.height)) }
}

nonisolated enum EmojiStickerRenderer {
    /// Bounded master size: the largest sticker covers one 504-dot photo, so this never upsamples.
    static let pixelDimension = StickerImageLimits.printPixelDimension
    /// Transparent margin around the ink so the outline and rotation never clip glyph edges.
    static let marginFraction: CGFloat = 0.07
    /// Outline radius as a fraction of the longest artwork edge (≈2 printed dots at default size).
    static let outlineFraction: CGFloat = 0.022
    static let faintWarning = "Light colors may print faintly on thermal paper."
    /// Below this share of dark printed pixels the sticker is flagged as faint.
    static let minimumDarkCoverage = 0.06

    /// Renders and prepares one emoji. Safe to call off the main actor; never touches UIKit views.
    static func makeArtwork(for input: String, pixelDimension: Int = pixelDimension) throws -> EmojiStickerArtwork {
        let glyph: String
        switch EmojiGlyphValidator.validate(input) {
        case .success(let value): glyph = value
        case .failure(let error): throw error
        }
        let display = try renderColor(glyph, pixelDimension: pixelDimension)
        let toned = try outlinedPrintInk(from: display)
        let print: CGImage
        do {
            print = try StickerPrintPreparation.prepare(toned)
        } catch {
            throw EmojiValidationError.renderFailed
        }
        let coverage = darkCoverage(of: print)
        guard coverage.visible > 0.01 else { throw EmojiValidationError.renderFailed }
        return EmojiStickerArtwork(
            glyph: glyph,
            display: display,
            print: print,
            printWarning: coverage.dark < minimumDarkCoverage ? faintWarning : nil
        )
    }

    /// Draws the glyph large, measures its real ink, and crops it with a fixed margin so tall,
    /// wide and flag glyphs are never clipped. Output is at most `pixelDimension` on each edge.
    static func renderColor(_ glyph: String, pixelDimension: Int = pixelDimension) throws -> CGImage {
        let bound = max(32, min(pixelDimension, StickerImageLimits.maximumDecodedPixelDimension))
        let fontSize = CGFloat(bound)
        let side = Int(ceil(fontSize * 2))
        guard let master = rgbaContext(width: side, height: side) else { throw EmojiValidationError.renderFailed }
        let font = CTFontCreateWithName(EmojiGlyphValidator.emojiFontName as CFString, fontSize, nil)
        let attributed = NSAttributedString(string: glyph, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
        let line = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        master.textMatrix = .identity
        master.textPosition = CGPoint(x: (CGFloat(side) - width) / 2, y: (CGFloat(side) - (ascent - descent)) / 2)
        CTLineDraw(line, master)

        guard let inkBounds = alphaBounds(of: master), inkBounds.width > 1, inkBounds.height > 1 else {
            throw EmojiValidationError.renderFailed
        }
        let margin = ceil(max(inkBounds.width, inkBounds.height) * marginFraction)
        let crop = inkBounds.insetBy(dx: -margin, dy: -margin).integral
            .intersection(CGRect(x: 0, y: 0, width: side, height: side))
        guard let masterImage = master.makeImage() else { throw EmojiValidationError.renderFailed }
        // `alphaBounds` reports top-left origin rows, which is also CGImage cropping space.
        guard let cropped = masterImage.cropping(to: crop) else { throw EmojiValidationError.renderFailed }

        let scale = min(1, CGFloat(bound) / max(crop.width, crop.height))
        let outputWidth = max(1, Int((crop.width * scale).rounded()))
        let outputHeight = max(1, Int((crop.height * scale).rounded()))
        guard let output = rgbaContext(width: outputWidth, height: outputHeight) else { throw EmojiValidationError.renderFailed }
        output.interpolationQuality = .high
        output.draw(cropped, in: CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight))
        guard let image = output.makeImage() else { throw EmojiValidationError.renderFailed }
        return image
    }

    /// Thermal ink: a tone curve that keeps bright emoji colours from vanishing into paper white,
    /// over a solid dark outline that separates the silhouette from the photo underneath.
    static func outlinedPrintInk(from display: CGImage) throws -> CGImage {
        let width = display.width, height = display.height
        guard let context = rgbaContext(width: width, height: height) else { throw EmojiValidationError.renderFailed }
        context.draw(display, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let buffer = context.data else { throw EmojiValidationError.renderFailed }
        let pixels = buffer.bindMemory(to: UInt8.self, capacity: width * height * 4)
        let count = width * height
        var alpha = [UInt8](repeating: 0, count: count)
        for index in 0..<count { alpha[index] = pixels[index * 4 + 3] }
        let radius = max(2, Int((CGFloat(max(width, height)) * outlineFraction).rounded()))
        let outline = dilate(alpha, width: width, height: height, radius: radius)

        for index in 0..<count {
            let offset = index * 4
            let a = Double(pixels[offset + 3]) / 255
            var ink = 0.0
            if a > 0 {
                let red = Double(pixels[offset]) / a, green = Double(pixels[offset + 1]) / a, blue = Double(pixels[offset + 2]) / a
                ink = toneMapped(0.299 * red + 0.587 * green + 0.114 * blue)
            }
            // Glyph (premultiplied gray) over a black outline: black adds alpha but no colour.
            let outlineAlpha = Double(outline[index]) / 255
            let outAlpha = a + outlineAlpha * (1 - a)
            let gray = UInt8(max(0, min(255, (ink * a).rounded())))
            pixels[offset] = gray
            pixels[offset + 1] = gray
            pixels[offset + 2] = gray
            pixels[offset + 3] = UInt8(max(0, min(255, (outAlpha * 255).rounded())))
        }
        guard let image = context.makeImage() else { throw EmojiValidationError.renderFailed }
        return image
    }

    /// Luminance in, printable gray out. Mid-tones darken (yellow faces land near 60 % gray so
    /// the dither keeps them visible) while true highlights stay white for eyes and teeth.
    static func toneMapped(_ luminance: Double) -> Double {
        let normalized = max(0, min(1, luminance / 255))
        let darkened = pow(normalized, 1.6)
        let contrasted = (darkened - 0.5) * 1.12 + 0.5
        let highlight = normalized > 0.94 ? (normalized - 0.94) / 0.06 : 0
        let value = contrasted * (1 - highlight) + normalized * highlight
        return max(0, min(255, value * 255))
    }

    /// Share of visible pixels and of dark (printing) pixels in a prepared image.
    static func darkCoverage(of image: CGImage) -> (visible: Double, dark: Double) {
        guard let context = rgbaContext(width: image.width, height: image.height) else { return (0, 0) }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let buffer = context.data else { return (0, 0) }
        let pixels = buffer.bindMemory(to: UInt8.self, capacity: image.width * image.height * 4)
        let total = image.width * image.height
        var visible = 0, dark = 0
        for index in stride(from: 0, to: total, by: 2) {
            let offset = index * 4
            guard pixels[offset + 3] >= StickerPrintPreparation.alphaThreshold else { continue }
            visible += 1
            if pixels[offset] < 150 { dark += 1 }
        }
        let sampled = Double(max(1, (total + 1) / 2))
        return (Double(visible) / sampled, visible > 0 ? Double(dark) / Double(visible) : 0)
    }

    // MARK: Pixels

    static func rgbaContext(width: Int, height: Int) -> CGContext? {
        guard width > 0, height > 0, let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }

    /// Bounding box of pixels with any alpha, in top-left-origin pixel rows.
    private static func alphaBounds(of context: CGContext) -> CGRect? {
        guard let buffer = context.data else { return nil }
        let width = context.width, height = context.height, bytesPerRow = context.bytesPerRow
        let pixels = buffer.bindMemory(to: UInt8.self, capacity: bytesPerRow * height)
        var minX = width, minY = height, maxX = -1, maxY = -1
        for row in 0..<height {
            let rowStart = row * bytesPerRow
            for column in 0..<width where pixels[rowStart + column * 4 + 3] > 8 {
                minX = min(minX, column); maxX = max(maxX, column)
                minY = min(minY, row); maxY = max(maxY, row)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    /// Dilated silhouette: the glyph's alpha used as a clip mask and stamped in black around a
    /// disc of `radius` pixels. Core Graphics does the work, so this stays fast in every build.
    private static func dilate(_ mask: [UInt8], width: Int, height: Int, radius: Int) -> [UInt8] {
        guard let provider = CGDataProvider(data: Data(mask) as CFData),
              let maskImage = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            return mask
        }
        context.setFillColor(gray: 1, alpha: 1)
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        var offsets: [CGPoint] = [.zero]
        for ring in [CGFloat(radius), CGFloat(radius) * 0.5] {
            for step in 0..<16 {
                let angle = CGFloat(step) / 16 * 2 * .pi
                offsets.append(CGPoint(x: cos(angle) * ring, y: sin(angle) * ring))
            }
        }
        for offset in offsets {
            context.saveGState()
            context.clip(to: rect.offsetBy(dx: offset.x, dy: offset.y), mask: maskImage)
            context.fill(rect)
            context.restoreGState()
        }
        guard let data = context.data else { return mask }
        let bytes = data.bindMemory(to: UInt8.self, capacity: width * height)
        var result = [UInt8](repeating: 0, count: mask.count)
        for row in 0..<height {
            for column in 0..<width {
                result[row * width + column] = max(mask[row * width + column], bytes[row * context.bytesPerRow + column])
            }
        }
        return result
    }
}
