//
//  PassportReceiptLayout.swift
//  PocketPixelsBooth
//
//  Deterministic geometry for the two stacked landscape Passport cards. The layout is pure:
//  it measures frozen strings and returns frames in 576-dot receipt coordinates, so tests,
//  previews and the production renderer all agree on exactly the same receipt.
//

import UIKit

// MARK: - Resolved content

/// Frozen, display-ready strings for one Passport receipt.
nonisolated struct PassportReceiptContent: Equatable, Sendable {
    nonisolated enum TitleMode: Equatable, Sendable {
        case pocketPixels
        case eventText
        case headerGraphic
    }

    nonisolated struct Field: Equatable, Sendable {
        let label: String
        let value: String
    }

    let theme: PassportTheme
    let titleMode: TitleMode
    let eyebrow: String
    let title: String
    let label: String
    let subtitle: String
    let metadata: String
    let message: String
    let stampLines: [String]
    let name: Field
    let birthday: Field
    let age: Field?
    let nationality: Field
    let profession: Field
    let birthplace: Field?
    let brandLines: [String]
    let keepsakeLines: [String]
    let signatureLabel: String
    let signature: PassportSignature

    nonisolated static func resolve(
        passport: PassportSessionData,
        eventProfile: EventProfile?,
        headerGraphicAvailable: Bool,
        referenceDate: Date
    ) -> PassportReceiptContent {
        let data = passport.normalized(referenceDate: referenceDate)
        let configuration = data.configuration
        let event = eventProfile?.activeReceiptSnapshot
        let eventBlock = event?.receiptBlockContent
        let namedEvent = event.flatMap { $0.eventName.isEmpty ? nil : $0 }

        let titleMode: TitleMode
        switch configuration.titleSource {
        case .pocketPixels:
            titleMode = .pocketPixels
        case .eventText:
            titleMode = namedEvent == nil ? .pocketPixels : .eventText
        case .eventHeaderGraphic:
            titleMode = headerGraphicAvailable ? .headerGraphic : (namedEvent == nil ? .pocketPixels : .eventText)
        case .automatic:
            if headerGraphicAvailable {
                titleMode = .headerGraphic
            } else if eventBlock != nil, namedEvent != nil {
                titleMode = .eventText
            } else {
                titleMode = .pocketPixels
            }
        }

        let eventLabel = configuration.eventLabel.isEmpty ? PassportConfiguration.defaultEventLabel : configuration.eventLabel
        let title: String
        let label: String
        let subtitle: String
        switch titleMode {
        case .pocketPixels:
            title = configuration.title
            label = ""
            subtitle = configuration.subtitle.isEmpty ? MadeToKeepBrand.tagline.uppercased() : configuration.subtitle
        case .eventText:
            title = namedEvent?.eventName ?? configuration.title
            label = eventLabel
            subtitle = configuration.subtitle.isEmpty ? (namedEvent?.subtitle ?? "") : configuration.subtitle
        case .headerGraphic:
            title = ""
            label = eventLabel
            subtitle = configuration.subtitle
        }

        let metadata = titleMode == .pocketPixels ? "" : (eventBlock?.metadata ?? "")
        let age = data.displayAge(referenceDate: referenceDate)
        let stampLines: [String]
        switch configuration.theme {
        case .classic:
            stampLines = ["MEMORY", "PASS"]
        case .event:
            let dateLine = event.flatMap { $0.includeEventDate ? PassportText.stampDate($0.eventDate) : nil }
            stampLines = ["EVENT PASS", dateLine ?? "KEEPSAKE"]
        case .stars, .minimal:
            stampLines = []
        }

        return PassportReceiptContent(
            theme: configuration.theme,
            titleMode: titleMode,
            eyebrow: titleMode == .pocketPixels ? "MADE TO KEEP STUDIOS" : "A KEEPSAKE FROM",
            title: PassportText.printed(title),
            label: PassportText.printed(label),
            subtitle: PassportText.printed(subtitle),
            metadata: PassportText.printed(metadata),
            message: PassportText.printed(eventBlock?.message ?? ""),
            stampLines: stampLines,
            name: Field(label: "NAME", value: PassportText.printed(data.name)),
            birthday: Field(label: "BIRTHDAY", value: data.birthday?.displayText ?? ""),
            age: age.map { Field(label: "AGE", value: "\($0)") },
            nationality: Field(label: "NATIONALITY", value: PassportText.printed(data.nationality)),
            profession: Field(label: "PROFESSION", value: PassportText.printed(data.profession)),
            birthplace: data.birthplace.isEmpty ? nil : Field(label: "BIRTHPLACE", value: PassportText.printed(data.birthplace)),
            brandLines: ["POCKET", "PASSPORT"],
            keepsakeLines: ["KEEPSAKE ·", "NO EXPIRY"],
            signatureLabel: "SIGNATURE",
            signature: data.signature
        )
    }
}

// MARK: - Fonts

nonisolated struct PassportFontSpec: Equatable, Sendable {
    nonisolated enum Style: Equatable, Sendable {
        case serifBold
        case sansBlack
        case sansBold
        case sansSemibold
        case monoSemibold
        case monoBold
        case monoMedium
        /// Photo Pass wordmark. Snell Roundhand ships with iOS; a bold italic serif is the fallback.
        case script
    }

    let style: Style
    let size: CGFloat

    nonisolated var font: UIFont {
        switch style {
        case .serifBold:
            let base = UIFont.systemFont(ofSize: size, weight: .bold)
            return base.fontDescriptor.withDesign(.serif).map { UIFont(descriptor: $0, size: size) } ?? base
        case .script:
            if let script = UIFont(name: "SnellRoundhand-Bold", size: size) {
                return script
            }
            let base = UIFont.systemFont(ofSize: size, weight: .bold)
            let serif = base.fontDescriptor.withDesign(.serif) ?? base.fontDescriptor
            return serif.withSymbolicTraits([.traitItalic, .traitBold]).map { UIFont(descriptor: $0, size: size) } ?? base
        case .sansBlack:
            return .systemFont(ofSize: size, weight: .heavy)
        case .sansBold:
            return .systemFont(ofSize: size, weight: .bold)
        case .sansSemibold:
            return .systemFont(ofSize: size, weight: .semibold)
        case .monoSemibold:
            return .monospacedSystemFont(ofSize: size, weight: .semibold)
        case .monoBold:
            return .monospacedSystemFont(ofSize: size, weight: .bold)
        case .monoMedium:
            return .monospacedSystemFont(ofSize: size, weight: .medium)
        }
    }
}

// MARK: - Layout

nonisolated struct PassportTextBlock: Equatable, Sendable {
    nonisolated enum Role: Hashable, Sendable {
        case eyebrow
        case title
        case label
        case subtitle
        case metadata
        case message
        case stamp
        case fieldLabel(String)
        case fieldValue(String)
        case brand
        case keepsake
        case signatureLabel
    }

    let role: Role
    let text: String
    let rect: CGRect
    let font: PassportFontSpec
    let tracking: CGFloat
    let alignment: NSTextAlignment
    let maximumLines: Int
    /// True when the text could not fit at the smallest permitted size and is tail-truncated.
    let isTruncated: Bool
    /// Unbroken strings longer than the line (no spaces) wrap by character instead of by word.
    var wrapsByCharacter = false
}

nonisolated struct PassportReceiptLayout: Equatable, Sendable {
    nonisolated static let cardX = 12
    nonisolated static let cardWidth = BoothConfiguration.receiptWidth - 24
    nonisolated static let cardInset = 18
    nonisolated static let cardGap = 14
    nonisolated static let cardCornerRadius: CGFloat = 16
    nonisolated static let borderWidth: CGFloat = 3
    nonisolated static let heroPhotoSize = CGSize(width: 320, height: 240)
    nonisolated static let portraitPhotoSize = CGSize(width: 156, height: 208)
    nonisolated static let photoBorderWidth: CGFloat = 2
    nonisolated static let underlineHeight: CGFloat = 2
    nonisolated static let signatureBoxHeight = 66

    /// Photo index 1 (hero) belongs to the upper card; photo index 0 (portrait) to the lower card.
    nonisolated static let portraitPhotoIndex = 0
    nonisolated static let heroPhotoIndex = 1

    let theme: PassportTheme
    let upperCard: CGRect
    let lowerCard: CGRect
    let heroPhotoRect: CGRect
    let portraitPhotoRect: CGRect
    let titleColumn: CGRect
    let headerGraphicRect: CGRect?
    let stampRect: CGRect?
    let starBandRect: CGRect?
    let upperTexts: [PassportTextBlock]
    let lowerTexts: [PassportTextBlock]
    let underlines: [CGRect]
    let signatureBox: CGRect
    let signatureRect: CGRect
    let message: PassportTextBlock?
    let bottom: Int

    nonisolated var photoFrames: [ReceiptPhotoFrame] {
        [
            ReceiptPhotoFrame(photoIndex: Self.portraitPhotoIndex, rect: portraitPhotoRect),
            ReceiptPhotoFrame(photoIndex: Self.heroPhotoIndex, rect: heroPhotoRect)
        ]
    }

    nonisolated var allTexts: [PassportTextBlock] {
        upperTexts + lowerTexts + (message.map { [$0] } ?? [])
    }

    nonisolated var truncatedRoles: [PassportTextBlock.Role] {
        allTexts.filter(\.isTruncated).map(\.role)
    }

    nonisolated static func make(
        content: PassportReceiptContent,
        headerGraphicSourceSize: CGSize?,
        top: Int
    ) -> PassportReceiptLayout {
        let cardMaxX = cardX + cardWidth

        // Upper card: title column on the left, hero photo on the right.
        let upperCard = CGRect(x: cardX, y: top, width: cardWidth, height: cardInset * 2 + Int(heroPhotoSize.height))
        let heroPhotoRect = CGRect(
            x: CGFloat(cardMaxX - cardInset) - heroPhotoSize.width,
            y: CGFloat(top + cardInset),
            width: heroPhotoSize.width,
            height: heroPhotoSize.height
        )
        let columnX = cardX + cardInset + 4
        let titleColumn = CGRect(
            x: CGFloat(columnX),
            y: heroPhotoRect.minY + 2,
            width: heroPhotoRect.minX - 18 - CGFloat(columnX),
            height: heroPhotoRect.height - 4
        )
        let upper = makeTitleColumn(content: content, column: titleColumn, headerGraphicSourceSize: headerGraphicSourceSize)

        // Lower card: portrait photo and branding on the left, details and signature on the right.
        let lowerTop = Int(upperCard.maxY) + cardGap
        let portraitPhotoRect = CGRect(
            x: CGFloat(columnX),
            y: CGFloat(lowerTop + cardInset + 2),
            width: portraitPhotoSize.width,
            height: portraitPhotoSize.height
        )
        let fieldsX = Int(portraitPhotoRect.maxX) + 20
        let fieldsWidth = cardMaxX - cardInset - 4 - fieldsX
        var lowerTexts: [PassportTextBlock] = []
        var underlines: [CGRect] = []
        var y = lowerTop + cardInset

        func appendFieldRow(_ fields: [(PassportReceiptContent.Field, Int, Int)], valueStyle: PassportFontSpec.Style, valueSizes: [CGFloat], allowsTwoLines: Bool) {
            var rowBottom = y
            for (field, x, width) in fields {
                let label = singleLineBlock(
                    role: .fieldLabel(field.label),
                    text: field.label,
                    origin: CGPoint(x: x, y: y),
                    width: width,
                    style: .monoSemibold,
                    sizes: [11],
                    tracking: 1.2
                )
                let valueY = Int(label.rect.maxY) + 2
                var value = singleLineBlock(
                    role: .fieldValue(field.label),
                    text: field.value,
                    origin: CGPoint(x: x, y: valueY),
                    width: width,
                    style: valueStyle,
                    sizes: valueSizes,
                    tracking: 0.4
                )
                if value.isTruncated, allowsTwoLines {
                    value = wrappedBlock(
                        role: .fieldValue(field.label),
                        text: field.value,
                        origin: CGPoint(x: x, y: valueY),
                        width: width,
                        style: valueStyle,
                        sizes: valueStyle == .sansBold ? [15, 14, 13, 12] : [17, 16, 15, 14, 13],
                        tracking: 0.2,
                        maximumLines: 2,
                        alignment: .left
                    )
                }
                let underline = CGRect(x: CGFloat(x), y: value.rect.maxY + 3, width: CGFloat(width), height: underlineHeight)
                lowerTexts.append(label)
                lowerTexts.append(value)
                underlines.append(underline)
                rowBottom = max(rowBottom, Int(ceil(underline.maxY)))
            }
            y = rowBottom + 10
        }

        let valueSizes: [CGFloat] = [20, 19, 18, 17, 16, 15, 14, 13, 12]
        appendFieldRow([(content.name, fieldsX, fieldsWidth)], valueStyle: content.theme == .minimal ? .sansBlack : .serifBold, valueSizes: [24, 23, 22, 21, 20, 19, 18, 17, 16, 15], allowsTwoLines: true)
        if let age = content.age {
            let ageWidth = 76
            let birthdayWidth = fieldsWidth - ageWidth - 16
            appendFieldRow([(content.birthday, fieldsX, birthdayWidth), (age, fieldsX + birthdayWidth + 16, ageWidth)], valueStyle: .sansBold, valueSizes: valueSizes, allowsTwoLines: false)
        } else {
            appendFieldRow([(content.birthday, fieldsX, fieldsWidth)], valueStyle: .sansBold, valueSizes: valueSizes, allowsTwoLines: false)
        }
        appendFieldRow([(content.nationality, fieldsX, fieldsWidth)], valueStyle: .sansBold, valueSizes: valueSizes, allowsTwoLines: true)
        appendFieldRow([(content.profession, fieldsX, fieldsWidth)], valueStyle: .sansBold, valueSizes: valueSizes, allowsTwoLines: true)
        if let birthplace = content.birthplace {
            appendFieldRow([(birthplace, fieldsX, fieldsWidth)], valueStyle: .sansBold, valueSizes: valueSizes, allowsTwoLines: true)
        }

        let signatureLabel = singleLineBlock(
            role: .signatureLabel,
            text: content.signatureLabel,
            origin: CGPoint(x: fieldsX, y: y - 2),
            width: fieldsWidth,
            style: .monoSemibold,
            sizes: [11],
            tracking: 1.2
        )
        lowerTexts.append(signatureLabel)
        let signatureBox = CGRect(x: CGFloat(fieldsX), y: signatureLabel.rect.maxY + 2, width: CGFloat(fieldsWidth), height: CGFloat(signatureBoxHeight))
        let signatureRect = PassportSignature.fittedRect(in: signatureBox.insetBy(dx: 2, dy: 4), alignment: 0)
        underlines.append(CGRect(x: signatureBox.minX, y: signatureBox.maxY, width: signatureBox.width, height: underlineHeight))
        let rightBottom = Int(ceil(signatureBox.maxY + underlineHeight))

        // Left column below the portrait: keepsake branding.
        let brandStyle: PassportFontSpec.Style = content.theme == .minimal ? .sansBlack : .serifBold
        var leftY = Int(portraitPhotoRect.maxY) + 12
        for line in content.brandLines {
            let block = singleLineBlock(role: .brand, text: line, origin: CGPoint(x: Int(portraitPhotoRect.minX), y: leftY), width: Int(portraitPhotoRect.width), style: brandStyle, sizes: [16, 15, 14], tracking: 2.4)
            lowerTexts.append(block)
            leftY = Int(block.rect.maxY)
        }
        leftY += 5
        for line in content.keepsakeLines {
            let block = singleLineBlock(role: .keepsake, text: line, origin: CGPoint(x: Int(portraitPhotoRect.minX), y: leftY), width: Int(portraitPhotoRect.width), style: .monoSemibold, sizes: [11, 10], tracking: 1.2)
            lowerTexts.append(block)
            leftY = Int(block.rect.maxY)
        }

        let lowerHeight = max(rightBottom, leftY) - lowerTop + cardInset
        let lowerCard = CGRect(x: cardX, y: lowerTop, width: cardWidth, height: lowerHeight)

        var bottom = Int(lowerCard.maxY)
        var message: PassportTextBlock?
        if !content.message.isEmpty {
            let block = wrappedBlock(
                role: .message,
                text: content.message,
                origin: CGPoint(x: cardX + 28, y: bottom + 12),
                width: cardWidth - 56,
                style: .sansSemibold,
                sizes: [13, 12],
                tracking: 0.8,
                maximumLines: 2,
                alignment: .center
            )
            message = block
            bottom = Int(ceil(block.rect.maxY))
        }

        return PassportReceiptLayout(
            theme: content.theme,
            upperCard: upperCard,
            lowerCard: lowerCard,
            heroPhotoRect: heroPhotoRect,
            portraitPhotoRect: portraitPhotoRect,
            titleColumn: titleColumn,
            headerGraphicRect: upper.graphicRect,
            stampRect: upper.stampRect,
            starBandRect: upper.starBandRect,
            upperTexts: upper.texts,
            lowerTexts: lowerTexts,
            underlines: underlines,
            signatureBox: signatureBox,
            signatureRect: signatureRect,
            message: message,
            bottom: bottom
        )
    }

    // MARK: Title column

    private struct TitleColumnLayout {
        let texts: [PassportTextBlock]
        let graphicRect: CGRect?
        let stampRect: CGRect?
        let starBandRect: CGRect?
    }

    nonisolated private static func makeTitleColumn(
        content: PassportReceiptContent,
        column: CGRect,
        headerGraphicSourceSize: CGSize?
    ) -> TitleColumnLayout {
        let x = Int(column.minX)
        let width = Int(column.width)

        // Decorative motif reserved at the bottom of the column.
        var stampRect: CGRect?
        var starBandRect: CGRect?
        var motifTop = Int(column.maxY)
        switch content.theme {
        case .classic:
            let diameter: CGFloat = 68
            let rect = CGRect(x: column.minX + 2, y: column.maxY - diameter, width: diameter, height: diameter)
            stampRect = rect
            motifTop = Int(rect.minY) - 8
        case .event:
            let size = CGSize(width: min(column.width - 12, 148), height: 44)
            let rect = CGRect(x: column.minX + 4, y: column.maxY - size.height - 6, width: size.width, height: size.height)
            stampRect = rect
            motifTop = Int(rect.minY) - 12
        case .stars:
            let rect = CGRect(x: column.minX, y: column.maxY - 14, width: min(column.width, 116), height: 14)
            starBandRect = rect
            motifTop = Int(rect.minY) - 10
        case .minimal:
            break
        }
        let availableBottom = motifTop

        let titleStyle: PassportFontSpec.Style = content.theme == .minimal ? .sansBlack : .serifBold
        let titleSizes: [CGFloat] = [34, 31, 28, 26, 24, 22, 20, 18, 17, 16]
        let titleLines = content.titleMode == .eventText ? 4 : 3

        // Optional lines are dropped (metadata first, then subtitle) only if the title cannot
        // fit even at its smallest size.
        let optionalSets: [(subtitle: Bool, metadata: Bool)] = [(true, true), (true, false), (false, false)]
        for (index, optional) in optionalSets.enumerated() {
            let isLastAttempt = index == optionalSets.count - 1
            for (sizeIndex, size) in titleSizes.enumerated() {
                let isSmallest = sizeIndex == titleSizes.count - 1
                var texts: [PassportTextBlock] = []
                var graphicRect: CGRect?
                var y = Int(column.minY)

                let eyebrow = singleLineBlock(role: .eyebrow, text: content.eyebrow, origin: CGPoint(x: x, y: y), width: width, style: .monoSemibold, sizes: [11, 10], tracking: 1.6)
                texts.append(eyebrow)
                y = Int(eyebrow.rect.maxY) + 7

                switch content.titleMode {
                case .headerGraphic:
                    let maximumHeight = CGFloat(max(40, min(118, availableBottom - y - 60)))
                    let sourceSize = headerGraphicSourceSize ?? CGSize(width: 3, height: 1)
                    let scale = min(column.width / max(1, sourceSize.width), maximumHeight / max(1, sourceSize.height))
                    let size = CGSize(width: floor(max(1, sourceSize.width * scale)), height: floor(max(1, sourceSize.height * scale)))
                    let rect = CGRect(x: column.minX, y: CGFloat(y), width: size.width, height: size.height)
                    graphicRect = rect
                    y = Int(rect.maxY) + 8
                case .pocketPixels, .eventText:
                    let title = wrappedBlock(role: .title, text: content.title, origin: CGPoint(x: x, y: y), width: width, style: titleStyle, sizes: [size], tracking: 0.6, maximumLines: titleLines, alignment: .left, allowsCharacterWrap: isSmallest)
                    if title.isTruncated, !(isSmallest && isLastAttempt) {
                        continue
                    }
                    texts.append(title)
                    y = Int(title.rect.maxY) + 6
                }

                if !content.label.isEmpty {
                    let label = singleLineBlock(role: .label, text: content.label, origin: CGPoint(x: x, y: y), width: width, style: .sansBold, sizes: [14, 13, 12, 11], tracking: 2.0)
                    texts.append(label)
                    y = Int(label.rect.maxY) + 6
                }
                if optional.subtitle, !content.subtitle.isEmpty {
                    let subtitle = wrappedBlock(role: .subtitle, text: content.subtitle, origin: CGPoint(x: x, y: y), width: width, style: .sansSemibold, sizes: [13, 12, 11], tracking: 0.6, maximumLines: 3, alignment: .left)
                    texts.append(subtitle)
                    y = Int(subtitle.rect.maxY) + 5
                }
                if optional.metadata, !content.metadata.isEmpty {
                    let metadata = wrappedBlock(role: .metadata, text: content.metadata, origin: CGPoint(x: x, y: y), width: width, style: .monoMedium, sizes: [11, 10], tracking: 0.3, maximumLines: 2, alignment: .left)
                    texts.append(metadata)
                    y = Int(metadata.rect.maxY)
                }

                let fits = y <= availableBottom
                if fits || (isSmallest && isLastAttempt) {
                    if !content.stampLines.isEmpty, let stamp = stampRect {
                        texts.append(contentsOf: stampTexts(lines: content.stampLines, in: stamp, theme: content.theme))
                    }
                    return TitleColumnLayout(
                        texts: fits ? texts : clamp(texts, toBottom: availableBottom),
                        graphicRect: graphicRect,
                        stampRect: stampRect,
                        starBandRect: starBandRect
                    )
                }
                if content.titleMode == .headerGraphic {
                    break
                }
            }
        }

        return TitleColumnLayout(texts: [], graphicRect: nil, stampRect: stampRect, starBandRect: starBandRect)
    }

    nonisolated private static func stampTexts(lines: [String], in rect: CGRect, theme: PassportTheme) -> [PassportTextBlock] {
        let fonts: [PassportFontSpec] = theme == .classic
            ? [PassportFontSpec(style: .monoBold, size: 11), PassportFontSpec(style: .monoBold, size: 11)]
            : [PassportFontSpec(style: .sansBold, size: 13), PassportFontSpec(style: .monoSemibold, size: 11)]
        let heights = zip(lines, fonts).map { ceil($0.1.font.lineHeight) }
        var y = rect.midY - heights.reduce(0, +) / 2
        return zip(lines, fonts).enumerated().map { index, pair in
            let height = heights[index]
            let block = PassportTextBlock(
                role: .stamp,
                text: pair.0,
                rect: CGRect(x: rect.minX + 4, y: floor(y), width: rect.width - 8, height: height),
                font: pair.1,
                tracking: 1.0,
                alignment: .center,
                maximumLines: 1,
                isTruncated: measuredWidth(pair.0, font: pair.1.font, tracking: 1.0) > rect.width - 8
            )
            y += height
            return block
        }
    }

    /// Last-resort guard: drops any trailing optional text that would overflow the column.
    nonisolated private static func clamp(_ texts: [PassportTextBlock], toBottom bottom: Int) -> [PassportTextBlock] {
        texts.filter { $0.role == .eyebrow || $0.role == .title || CGFloat(bottom) >= $0.rect.maxY }
            .map { block in
                guard block.rect.maxY > CGFloat(bottom) else { return block }
                let height = max(ceil(block.font.font.lineHeight), CGFloat(bottom) - block.rect.minY)
                return PassportTextBlock(
                    role: block.role,
                    text: block.text,
                    rect: CGRect(x: block.rect.minX, y: block.rect.minY, width: block.rect.width, height: height),
                    font: block.font,
                    tracking: block.tracking,
                    alignment: block.alignment,
                    maximumLines: max(1, Int(height / ceil(block.font.font.lineHeight))),
                    isTruncated: true
                )
            }
    }

    // MARK: Measurement

    nonisolated static func singleLineBlock(
        role: PassportTextBlock.Role,
        text: String,
        origin: CGPoint,
        width: Int,
        style: PassportFontSpec.Style,
        sizes: [CGFloat],
        tracking: CGFloat
    ) -> PassportTextBlock {
        var chosen = PassportFontSpec(style: style, size: sizes.last ?? 12)
        var truncated = true
        for size in sizes {
            let spec = PassportFontSpec(style: style, size: size)
            if measuredWidth(text, font: spec.font, tracking: tracking) <= CGFloat(width) {
                chosen = spec
                truncated = false
                break
            }
        }
        return PassportTextBlock(
            role: role,
            text: text,
            rect: CGRect(x: origin.x, y: origin.y, width: CGFloat(width), height: ceil(chosen.font.lineHeight)),
            font: chosen,
            tracking: tracking,
            alignment: .left,
            maximumLines: 1,
            isTruncated: truncated
        )
    }

    nonisolated static func wrappedBlock(
        role: PassportTextBlock.Role,
        text: String,
        origin: CGPoint,
        width: Int,
        style: PassportFontSpec.Style,
        sizes: [CGFloat],
        tracking: CGFloat,
        maximumLines: Int,
        alignment: NSTextAlignment,
        lineSpacing: CGFloat = 0,
        allowsCharacterWrap: Bool = true
    ) -> PassportTextBlock {
        var chosen = PassportFontSpec(style: style, size: sizes.last ?? 12)
        var lines = maximumLines
        var truncated = true
        var wrapsByCharacter = false
        for size in sizes {
            let spec = PassportFontSpec(style: style, size: size)
            let words = text.split(separator: " ").map(String.init)
            let widestWord = words.map { measuredWidth($0, font: spec.font, tracking: tracking) }.max() ?? 0
            let count = lineCount(text, font: spec.font, width: CGFloat(width), tracking: tracking, lineSpacing: lineSpacing, lineBreakMode: .byWordWrapping)
            if widestWord <= CGFloat(width), count <= maximumLines {
                chosen = spec
                lines = max(1, count)
                truncated = false
                break
            }
        }
        if truncated, allowsCharacterWrap {
            // Word wrapping failed (usually one unbroken word); wrap by character instead.
            for size in sizes {
                let spec = PassportFontSpec(style: style, size: size)
                let count = lineCount(text, font: spec.font, width: CGFloat(width), tracking: tracking, lineSpacing: lineSpacing, lineBreakMode: .byCharWrapping)
                if count <= maximumLines {
                    chosen = spec
                    lines = max(1, count)
                    truncated = false
                    wrapsByCharacter = true
                    break
                }
            }
        }
        let lineHeight = ceil(chosen.font.lineHeight)
        let height = lineHeight * CGFloat(lines) + max(0, lineSpacing) * CGFloat(lines - 1)
        return PassportTextBlock(
            role: role,
            text: text,
            rect: CGRect(x: origin.x, y: origin.y, width: CGFloat(width), height: ceil(height)),
            font: chosen,
            tracking: tracking,
            alignment: alignment,
            maximumLines: lines,
            isTruncated: truncated,
            wrapsByCharacter: wrapsByCharacter
        )
    }

    nonisolated static func measuredWidth(_ text: String, font: UIFont, tracking: CGFloat) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        return ceil(NSAttributedString(string: text, attributes: [.font: font, .kern: tracking]).boundingRect(
            with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        ).width)
    }

    nonisolated private static func lineCount(_ text: String, font: UIFont, width: CGFloat, tracking: CGFloat, lineSpacing: CGFloat, lineBreakMode: NSLineBreakMode) -> Int {
        guard !text.isEmpty else { return 1 }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = lineBreakMode
        paragraph.lineSpacing = max(0, lineSpacing)
        let height = NSAttributedString(string: text, attributes: [.font: font, .kern: tracking, .paragraphStyle: paragraph]).boundingRect(
            with: CGSize(width: width, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        ).height
        let lineHeight = font.lineHeight + max(0, lineSpacing)
        return max(1, Int((height / lineHeight).rounded()))
    }
}

extension PassportText {
    nonisolated static func stampDate(_ date: Date) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard let month = components.month, let day = components.day, let year = components.year else { return "KEEPSAKE" }
        return "\(monthAbbreviations[max(0, min(11, month - 1))]) \(day) \(year)"
    }
}
