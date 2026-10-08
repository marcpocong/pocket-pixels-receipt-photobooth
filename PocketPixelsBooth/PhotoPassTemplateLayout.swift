//
//  PhotoPassTemplateLayout.swift
//  PocketPixelsBooth
//
//  Deterministic geometry for the Photo Pass design (PassportDesignVersion.photoPassV2): two
//  stacked landscape cards with a rounded star border. Every coordinate of the template lives
//  here, derived from `Metrics`, in 576-dot receipt space. The composer, the validation, the
//  iPad preview, the gallery copy and the printer all use this one layout.
//
//  The template is split into a static layer (cards, star borders, wordmarks, field labels,
//  rules, accents) and a dynamic layer (photos, field values, signature). Field values are
//  fitted into fixed value rectangles, so customer text can never move or overlap the artwork.
//

import UIKit

// MARK: - Design selection

/// Resolved content for whichever Passport design a session stores. The composer picks the
/// matching layout and renderer from this, so legacy and Photo Pass code never mix.
nonisolated enum PassportDesignContent: Equatable, Sendable {
    case legacy(PassportReceiptContent)
    case photoPass(PhotoPassContent)

    nonisolated var legacyContent: PassportReceiptContent? {
        if case .legacy(let content) = self { return content }
        return nil
    }

    nonisolated var photoPassContent: PhotoPassContent? {
        if case .photoPass(let content) = self { return content }
        return nil
    }
}

// MARK: - Resolved content

/// Frozen, display-ready values for one Photo Pass receipt.
nonisolated struct PhotoPassContent: Equatable, Sendable {
    let name: String
    let date: String
    let event: String
    let location: String
    let notes: String
    let signature: PassportSignature

    /// Name and notes come from the customer. Date, event and location come from the event
    /// profile frozen with the session, so the customer never re-enters them:
    /// - Date: the configured event date when Event Mode shows one, otherwise the session date.
    /// - Event: the event name when Event Mode is active, otherwise blank.
    /// - Location: the event location when Event Mode is active, otherwise blank.
    nonisolated static func resolve(
        passport: PassportSessionData,
        eventProfile: EventProfile?,
        referenceDate: Date
    ) -> PhotoPassContent {
        let data = passport.normalized(referenceDate: referenceDate)
        let event = eventProfile?.activeReceiptSnapshot
        let date = event.flatMap { $0.includeEventDate ? $0.eventDate : nil } ?? referenceDate
        return PhotoPassContent(
            name: PassportText.printed(data.name),
            date: PassportText.photoPassDate(date),
            event: PassportText.printed(event?.eventName ?? ""),
            location: PassportText.printed(event?.location ?? ""),
            notes: PassportText.printed(data.notes),
            signature: data.signature
        )
    }
}

extension PassportText {
    /// "OCT 7, 2026" in the receipt time zone.
    nonisolated static func photoPassDate(_ date: Date) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard let month = components.month, let day = components.day, let year = components.year else { return "" }
        return "\(monthAbbreviations[max(0, min(11, month - 1))]) \(day), \(year)"
    }
}

// MARK: - Template geometry

nonisolated struct PhotoPassTemplateLayout: Equatable, Sendable {
    /// Template proportions in printer dots (8 dots/mm), measured from the Photo Pass reference
    /// artwork (876 px wide cards) and scaled to the 552-dot receipt card (≈ 0.63). Positions
    /// marked "card-relative" are offsets from the card's top-left corner.
    nonisolated enum Metrics {
        static let cardX = 12
        static let cardWidth = BoothConfiguration.receiptWidth - 24
        static let upperCardHeight = 460
        static let lowerCardHeight = 540
        static let cardGap = 6
        static let cornerRadius: CGFloat = 25
        /// Refined outer border that remains a dependable three-dot thermal rule.
        static let outerBorderWidth: CGFloat = 3
        /// Border stars sit on a rectangle this far inside the card edge, one on every corner.
        static let borderStarInset: CGFloat = 23
        static let borderStarRadius: CGFloat = 5.5
        static let borderStarSpacing: CGFloat = 22.7
        /// Everything except border stars stays inside the card inset by this much.
        static let contentInset: CGFloat = 32
        /// Frames, grid and ornament rules stay at two dots for dependable 1-bit output.
        static let lineWidth: CGFloat = 2
        /// White knockout around large accent stars, which opens the frame line like the reference.
        static let accentStarHalo: CGFloat = 3

        // Upper card (card-relative).
        /// Exactly 4:3, the hero shape PassportPhotoProcessor and the thermal pipeline crop to.
        static let heroPhoto = CGRect(x: 88, y: 68, width: 432, height: 324)
        /// Vertical script wordmark, reading bottom to top, left of the hero photo.
        static let heroWordmark = CGRect(x: 36, y: 40, width: 40, height: 380)
        static let heroTopStar = (center: CGPoint(x: 500, y: 78), radius: CGFloat(18))
        static let heroBottomStar = (center: CGPoint(x: 100, y: 384), radius: CGFloat(15))

        // Lower card (card-relative).
        /// Exactly 3:4, the portrait shape.
        static let portraitPhoto = CGRect(x: 36, y: 52, width: 240, height: 320)
        static let portraitStar = (center: CGPoint(x: 266, y: 362), radius: CGFloat(13))
        static let portraitWordmark = CGRect(x: 36, y: 388, width: 240, height: 44)
        static let ornamentY: CGFloat = 466
        static let ornamentRules = [(minX: CGFloat(44), maxX: CGFloat(122)), (minX: CGFloat(190), maxX: CGFloat(268))]
        static let ornamentStar = (center: CGPoint(x: 156, y: 466), radius: CGFloat(7))

        /// Field grid: event and location use their own full-width rows for readability.
        static let grid = CGRect(x: 286, y: 52, width: 220, height: 436)
        static let gridRowHeights: [CGFloat] = [62, 62, 72, 72, 96, 72]
        /// Labels sit at each cell's top-left; values use the space below.
        static let labelInset = CGSize(width: 7, height: 5)
        static let labelHeight: CGFloat = 15
        static let valueInset: CGFloat = 7
    }

    nonisolated enum FieldKind: String, CaseIterable, Sendable {
        case name
        case date
        case event
        case location
        case notes
        case signature

        /// Static label printed by the template.
        var label: String { "\(rawValue):" }
    }

    nonisolated struct Field: Equatable, Sendable {
        let kind: FieldKind
        /// Grid cell outlined by the template.
        let cellRect: CGRect
        let labelRect: CGRect
        /// Area reserved for the customer or event value.
        let valueRect: CGRect
    }

    nonisolated struct Star: Equatable, Sendable {
        let center: CGPoint
        let radius: CGFloat

        nonisolated var bounds: CGRect {
            CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        }
    }

    let upperCardRect: CGRect
    let lowerCardRect: CGRect
    let heroPhotoRect: CGRect
    let portraitPhotoRect: CGRect
    /// Large vertical script wordmark to the left of the hero photo.
    let heroBrandingRect: CGRect
    /// Small script wordmark under the portrait.
    let portraitBrandingRect: CGRect
    /// Line–star–line ornament under the small wordmark.
    let ornamentRules: [CGRect]
    let gridRect: CGRect
    let fields: [Field]
    /// 4:1 signature drawing area inside the signature value rectangle.
    let signatureRect: CGRect
    /// Large decorative stars over the photo frame corners plus the ornament star.
    let accentStars: [Star]
    let bottom: Int

    nonisolated var cards: [CGRect] { [upperCardRect, lowerCardRect] }

    nonisolated func field(_ kind: FieldKind) -> Field {
        // `make` creates every kind exactly once, in declaration order.
        fields[FieldKind.allCases.firstIndex(of: kind) ?? 0]
    }

    nonisolated var nameRect: CGRect { field(.name).valueRect }
    nonisolated var dateRect: CGRect { field(.date).valueRect }
    nonisolated var eventRect: CGRect { field(.event).valueRect }
    nonisolated var locationRect: CGRect { field(.location).valueRect }
    nonisolated var notesRect: CGRect { field(.notes).valueRect }
    nonisolated var signatureBoxRect: CGRect { field(.signature).valueRect }

    /// Area inside the star border that holds every non-border element.
    nonisolated var contentRects: [CGRect] {
        cards.map { $0.insetBy(dx: Metrics.contentInset, dy: Metrics.contentInset) }
    }

    nonisolated static func make(top: Int) -> PhotoPassTemplateLayout {
        let upperCard = CGRect(x: Metrics.cardX, y: top, width: Metrics.cardWidth, height: Metrics.upperCardHeight)
        let lowerCard = CGRect(x: Metrics.cardX, y: Int(upperCard.maxY) + Metrics.cardGap, width: Metrics.cardWidth, height: Metrics.lowerCardHeight)

        func place(_ rect: CGRect, in card: CGRect) -> CGRect {
            rect.offsetBy(dx: card.minX, dy: card.minY)
        }
        func place(_ star: (center: CGPoint, radius: CGFloat), in card: CGRect) -> Star {
            Star(center: CGPoint(x: card.minX + star.center.x, y: card.minY + star.center.y), radius: star.radius)
        }

        let grid = place(Metrics.grid, in: lowerCard)
        var rows: [CGRect] = []
        var rowY = grid.minY
        for height in Metrics.gridRowHeights {
            rows.append(CGRect(x: grid.minX, y: rowY, width: grid.width, height: height))
            rowY += height
        }
        let cells: [(FieldKind, CGRect)] = [
            (.name, rows[0]),
            (.date, rows[1]),
            (.event, rows[2]),
            (.location, rows[3]),
            (.notes, rows[4]),
            (.signature, rows[5])
        ]
        let labelFont = PassportFontSpec(style: .monoBold, size: 12).font
        let fields = cells.map { kind, cell -> Field in
            let label = CGRect(
                x: cell.minX + Metrics.labelInset.width,
                y: cell.minY + Metrics.labelInset.height,
                width: PassportReceiptLayout.measuredWidth(kind.label, font: labelFont, tracking: 0.2) + 2,
                height: Metrics.labelHeight
            )
            let inner = cell.insetBy(dx: Metrics.valueInset, dy: 4)
            let value: CGRect
            if kind == .signature {
                // The signature uses the space beside its label, which gives a wider 4:1 area.
                let x = label.maxX + 6
                value = CGRect(x: x, y: inner.minY, width: inner.maxX - x, height: inner.height)
            } else {
                let y = label.maxY + 1
                value = CGRect(x: inner.minX, y: y, width: inner.width, height: inner.maxY - y)
            }
            return Field(kind: kind, cellRect: cell, labelRect: label, valueRect: value)
        }
        let signatureBox = fields.last?.valueRect ?? .zero
        let signatureRect = PassportSignature.fittedRect(in: signatureBox, alignment: 0)

        let ornamentRules = Metrics.ornamentRules.map { rule in
            CGRect(
                x: lowerCard.minX + rule.minX,
                y: lowerCard.minY + Metrics.ornamentY - Metrics.lineWidth / 2,
                width: rule.maxX - rule.minX,
                height: Metrics.lineWidth
            )
        }

        return PhotoPassTemplateLayout(
            upperCardRect: upperCard,
            lowerCardRect: lowerCard,
            heroPhotoRect: place(Metrics.heroPhoto, in: upperCard),
            portraitPhotoRect: place(Metrics.portraitPhoto, in: lowerCard),
            heroBrandingRect: place(Metrics.heroWordmark, in: upperCard),
            portraitBrandingRect: place(Metrics.portraitWordmark, in: lowerCard),
            ornamentRules: ornamentRules,
            gridRect: grid,
            fields: fields,
            signatureRect: signatureRect,
            accentStars: [
                place(Metrics.heroTopStar, in: upperCard),
                place(Metrics.heroBottomStar, in: upperCard),
                place(Metrics.portraitStar, in: lowerCard),
                place(Metrics.ornamentStar, in: lowerCard)
            ],
            bottom: Int(lowerCard.maxY)
        )
    }

    /// Star centres on a rectangle inside the card edge: one star per corner and evenly spaced
    /// stars along each side, matching the reference's single star row.
    nonisolated static func borderStarCenters(for card: CGRect) -> [CGPoint] {
        let path = card.insetBy(dx: Metrics.borderStarInset, dy: Metrics.borderStarInset)
        guard path.width > 0, path.height > 0 else { return [] }
        let columns = max(1, Int((path.width / Metrics.borderStarSpacing).rounded()))
        let rows = max(1, Int((path.height / Metrics.borderStarSpacing).rounded()))
        func snap(_ point: CGPoint) -> CGPoint {
            CGPoint(x: (point.x * 2).rounded() / 2, y: (point.y * 2).rounded() / 2)
        }
        var centers: [CGPoint] = []
        for index in 0...columns {
            let x = path.minX + path.width * CGFloat(index) / CGFloat(columns)
            centers.append(snap(CGPoint(x: x, y: path.minY)))
            centers.append(snap(CGPoint(x: x, y: path.maxY)))
        }
        for index in 1..<rows {
            let y = path.minY + path.height * CGFloat(index) / CGFloat(rows)
            centers.append(snap(CGPoint(x: path.minX, y: y)))
            centers.append(snap(CGPoint(x: path.maxX, y: y)))
        }
        return centers
    }
}

// MARK: - Fitted receipt layout

/// A script wordmark that is part of the static template.
nonisolated struct PhotoPassWordmark: Equatable, Sendable {
    let text: String
    let font: PassportFontSpec
    /// Bounding box in receipt coordinates (already rotated for vertical wordmarks).
    let rect: CGRect
    /// Vertical wordmarks read bottom to top, with the letter tops facing left.
    let isVertical: Bool
    /// Glyph ink bounds relative to the text origin on the baseline (y up), used to centre the
    /// actual letters rather than the font's generous script line box.
    let inkBounds: CGRect
    let isTruncated: Bool

    /// Horizontal squeeze applied along the reading direction. Snell Roundhand is wider than the
    /// reference lettering; condensing it gives the reference's taller script proportions.
    nonisolated static let condense: CGFloat = 0.8

    nonisolated static func inkBounds(of text: String, font: UIFont) -> CGRect {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
        return CTLineGetImageBounds(line, nil)
    }
}

/// The template plus the dynamic text fitted into its fixed value rectangles.
nonisolated struct PhotoPassReceiptLayout: Equatable, Sendable {
    /// Photo index 1 (hero) fills the upper card; photo index 0 (portrait) the lower card.
    nonisolated static let portraitPhotoIndex = PassportReceiptLayout.portraitPhotoIndex
    nonisolated static let heroPhotoIndex = PassportReceiptLayout.heroPhotoIndex
    nonisolated static let wordmarkText = "Photo Pass"

    let template: PhotoPassTemplateLayout
    let wordmarks: [PhotoPassWordmark]
    /// Static field labels.
    let labelTexts: [PassportTextBlock]
    /// Dynamic values, one per filled text field. Empty values produce no block.
    let valueTexts: [PassportTextBlock]

    nonisolated var photoFrames: [ReceiptPhotoFrame] {
        [
            ReceiptPhotoFrame(photoIndex: Self.portraitPhotoIndex, rect: template.portraitPhotoRect),
            ReceiptPhotoFrame(photoIndex: Self.heroPhotoIndex, rect: template.heroPhotoRect)
        ]
    }

    nonisolated var bottom: Int { template.bottom }

    nonisolated var allTexts: [PassportTextBlock] { labelTexts + valueTexts }

    nonisolated var truncatedRoles: [PassportTextBlock.Role] {
        allTexts.filter(\.isTruncated).map(\.role) + wordmarks.filter(\.isTruncated).map { _ in .brand }
    }

    nonisolated func valueBlock(_ kind: PhotoPassTemplateLayout.FieldKind) -> PassportTextBlock? {
        valueTexts.first { $0.role == Self.valueRole(kind) }
    }

    nonisolated static func valueRole(_ kind: PhotoPassTemplateLayout.FieldKind) -> PassportTextBlock.Role {
        .fieldValue(kind.rawValue.uppercased())
    }

    nonisolated static func make(content: PhotoPassContent, top: Int) -> PhotoPassReceiptLayout {
        let template = PhotoPassTemplateLayout.make(top: top)
        let wordmarks = [
            fitWordmark(in: template.heroBrandingRect, vertical: true, sizes: Array(stride(from: CGFloat(96), through: 36, by: -1))),
            fitWordmark(in: template.portraitBrandingRect, vertical: false, sizes: Array(stride(from: CGFloat(48), through: 22, by: -1)))
        ]
        let labels = template.fields.map { field in
            PassportReceiptLayout.singleLineBlock(
                role: .fieldLabel(field.kind.rawValue),
                text: field.kind.label,
                origin: field.labelRect.origin,
                width: Int(ceil(field.labelRect.width)),
                style: .monoBold,
                sizes: [12, 11],
                tracking: 0.2
            )
        }

        var values: [PassportTextBlock] = []
        func appendValue(_ kind: PhotoPassTemplateLayout.FieldKind, _ text: String, style: PassportFontSpec.Style, singleSizes: [CGFloat], wrappedSizes: [CGFloat], maximumLines: Int) {
            guard !text.isEmpty else { return }
            values.append(fitValue(
                role: valueRole(kind),
                text: text,
                in: template.field(kind).valueRect,
                style: style,
                singleSizes: singleSizes,
                wrappedSizes: wrappedSizes,
                maximumLines: maximumLines
            ))
        }
        // Name is the most prominent value; date, event and location are compact; notes smallest.
        appendValue(.name, content.name, style: .serifBold, singleSizes: [18, 17, 16, 15, 14, 13, 12, 11], wrappedSizes: [10, 9], maximumLines: 2)
        appendValue(.date, content.date, style: .sansBold, singleSizes: [14, 13, 12, 11], wrappedSizes: [], maximumLines: 1)
        appendValue(.event, content.event, style: .sansBold, singleSizes: [13, 12], wrappedSizes: [12, 11, 10, 9], maximumLines: 3)
        appendValue(.location, content.location, style: .sansBold, singleSizes: [13, 12], wrappedSizes: [12, 11, 10, 9], maximumLines: 3)
        appendValue(.notes, content.notes, style: .sansSemibold, singleSizes: [12], wrappedSizes: [12, 11, 10, 9], maximumLines: 3)

        return PhotoPassReceiptLayout(template: template, wordmarks: wordmarks, labelTexts: labels, valueTexts: values)
    }

    // MARK: Fitting

    /// Largest script size whose glyph ink (plus the thickening stroke) fits the box: length
    /// along the reading direction, letter height across it.
    nonisolated private static func fitWordmark(in rect: CGRect, vertical: Bool, sizes: [CGFloat]) -> PhotoPassWordmark {
        let length = vertical ? rect.height : rect.width
        let thickness = vertical ? rect.width : rect.height
        for size in sizes {
            let spec = PassportFontSpec(style: .script, size: size)
            let ink = PhotoPassWordmark.inkBounds(of: wordmarkText, font: spec.font)
            let stroke = PhotoPassRenderer.wordmarkStrokeOutset(for: spec.size)
            if (ink.width + stroke * 2) * PhotoPassWordmark.condense <= length - 4, ink.height + stroke * 2 <= thickness - 2 {
                return PhotoPassWordmark(text: wordmarkText, font: spec, rect: rect, isVertical: vertical, inkBounds: ink, isTruncated: false)
            }
        }
        let spec = PassportFontSpec(style: .script, size: sizes.last ?? 22)
        return PhotoPassWordmark(text: wordmarkText, font: spec, rect: rect, isVertical: vertical, inkBounds: PhotoPassWordmark.inkBounds(of: wordmarkText, font: spec.font), isTruncated: true)
    }

    /// Tries one line at the preferred sizes, then wraps to `maximumLines` at smaller sizes. A
    /// size is only accepted when every line also fits the value rectangle's height.
    nonisolated private static func fitValue(
        role: PassportTextBlock.Role,
        text: String,
        in rect: CGRect,
        style: PassportFontSpec.Style,
        singleSizes: [CGFloat],
        wrappedSizes: [CGFloat],
        maximumLines: Int
    ) -> PassportTextBlock {
        let width = Int(rect.width)
        for size in singleSizes where ceil(PassportFontSpec(style: style, size: size).font.lineHeight) <= rect.height {
            let block = PassportReceiptLayout.singleLineBlock(role: role, text: text, origin: .zero, width: width, style: style, sizes: [size], tracking: 0.3)
            if !block.isTruncated {
                return centered(block, in: rect)
            }
        }
        var fallback: PassportTextBlock?
        for (index, size) in wrappedSizes.enumerated() {
            let lineHeight = ceil(PassportFontSpec(style: style, size: size).font.lineHeight)
            let lines = min(maximumLines, Int(rect.height / lineHeight))
            guard lines >= 1 else { continue }
            let block = PassportReceiptLayout.wrappedBlock(
                role: role,
                text: text,
                origin: .zero,
                width: width,
                style: style,
                sizes: [size],
                tracking: 0.2,
                maximumLines: lines,
                alignment: .left,
                allowsCharacterWrap: index == wrappedSizes.count - 1
            )
            if !block.isTruncated {
                return centered(block, in: rect)
            }
            fallback = block
        }
        // Nothing fits: keep the smallest attempt, clipped to the rect and tail-truncated.
        let last = fallback ?? PassportReceiptLayout.singleLineBlock(role: role, text: text, origin: .zero, width: width, style: style, sizes: [singleSizes.last ?? 12], tracking: 0.3)
        return centered(last, in: rect, forceTruncated: true)
    }

    /// Places a measured block inside `rect`, vertically centred under the label.
    nonisolated private static func centered(_ block: PassportTextBlock, in rect: CGRect, forceTruncated: Bool = false) -> PassportTextBlock {
        let lineHeight = max(1, ceil(block.font.font.lineHeight))
        let lines = max(1, min(block.maximumLines, Int(rect.height / lineHeight)))
        let height = min(rect.height, lineHeight * CGFloat(lines))
        return PassportTextBlock(
            role: block.role,
            text: block.text,
            rect: CGRect(x: rect.minX, y: rect.minY + floor((rect.height - height) / 2), width: rect.width, height: height),
            font: block.font,
            tracking: block.tracking,
            alignment: .left,
            maximumLines: lines,
            isTruncated: block.isTruncated || forceTruncated,
            wrapsByCharacter: block.wrapsByCharacter
        )
    }
}
