import CoreGraphics
import UIKit

/// Original, deterministic line drawings. Each motif has its own silhouette and construction;
/// no emoji, downloaded clip art, or random variation is used to expand the collection.
nonisolated enum CuratedStickerArtwork {
    struct Motif: Sendable {
        let id: String
        let name: String
        let category: StickerCategory
        var words: String? = nil
        var treatment = 0
    }

    static let motifs: [Motif] = [
        // Classic embellishments
        .init(id: "rosette", name: "Ribbon Rosette", category: .classic),
        .init(id: "ribbon-tails", name: "Ribbon Tails", category: .classic),
        .init(id: "photo-frame", name: "Instant Photo Frame", category: .classic),
        .init(id: "film-border", name: "Film Border", category: .classic),
        .init(id: "admit-one", name: "Admit One Ticket", category: .classic),
        .init(id: "wax-seal", name: "Wax Seal", category: .classic),
        .init(id: "scallop-stamp", name: "Scalloped Stamp", category: .classic),
        .init(id: "sunburst", name: "Engraved Sunburst", category: .classic),
        // Love notes and keepsakes
        .init(id: "love-letter", name: "Love Letter", category: .hearts),
        .init(id: "heart-lock", name: "Heart Lock", category: .hearts),
        .init(id: "linked-hearts", name: "Linked Hearts", category: .hearts),
        .init(id: "heart-wings", name: "Winged Heart", category: .hearts),
        .init(id: "love-potion", name: "Love Potion", category: .hearts),
        .init(id: "rose", name: "Love Rose", category: .hearts),
        .init(id: "kiss", name: "Lipstick Kiss", category: .hearts),
        .init(id: "heart-key", name: "Key to My Heart", category: .hearts),
        .init(id: "holding-hands", name: "Holding Hands", category: .hearts),
        .init(id: "love-postage", name: "Love Postage", category: .hearts),
        // Small friendly characters
        .init(id: "cat", name: "Curious Cat", category: .cute),
        .init(id: "puppy", name: "Floppy Puppy", category: .cute),
        .init(id: "bear", name: "Little Bear", category: .cute),
        .init(id: "bunny", name: "Bunny Hop", category: .cute),
        .init(id: "frog", name: "Friendly Frog", category: .cute),
        .init(id: "duck", name: "Puddle Duck", category: .cute),
        .init(id: "fish", name: "Goldfish", category: .cute),
        .init(id: "butterfly", name: "Garden Butterfly", category: .cute),
        .init(id: "strawberry", name: "Sweet Strawberry", category: .cute),
        .init(id: "mushroom", name: "Tiny Mushroom", category: .cute),
        .init(id: "bee", name: "Busy Bee", category: .cute),
        .init(id: "snail", name: "Slow Sunday Snail", category: .cute),
        .init(id: "whale", name: "Happy Whale", category: .cute),
        .init(id: "sleepy-moon", name: "Sleepy Moon", category: .cute),
        // Hand gestures and decorative marks
        .init(id: "scribble", name: "Handmade Underline", category: .doodles),
        .init(id: "swirl-arrow", name: "Looped Arrow", category: .doodles),
        .init(id: "pointing-hand", name: "This One", category: .doodles),
        .init(id: "stitched-patch", name: "Stitched Patch", category: .doodles),
        .init(id: "paperclips", name: "Linked Paper Clips", category: .doodles),
        .init(id: "peace-hand", name: "Peace Sign", category: .doodles),
        // Twelve original type compositions
        .init(id: "xoxo", name: "XOXO", category: .reactions, words: "XOXO", treatment: 0),
        .init(id: "slay", name: "SLAY", category: .reactions, words: "SLAY", treatment: 1),
        .init(id: "oops", name: "OOPS", category: .reactions, words: "OOPS!", treatment: 2),
        .init(id: "love-this", name: "Love This", category: .reactions, words: "LOVE\nTHIS", treatment: 3),
        .init(id: "so-cute", name: "So Cute", category: .reactions, words: "SO\nCUTE", treatment: 4),
        .init(id: "best-day", name: "Best Day Ever", category: .reactions, words: "BEST DAY\nEVER", treatment: 5),
        .init(id: "cheers", name: "Cheers", category: .reactions, words: "CHEERS", treatment: 6),
        .init(id: "oh-snap", name: "Oh Snap", category: .reactions, words: "OH\nSNAP!", treatment: 7),
        .init(id: "iconic", name: "Iconic", category: .reactions, words: "ICONIC", treatment: 8),
        .init(id: "brb", name: "BRB", category: .reactions, words: "BRB", treatment: 9),
        .init(id: "all-smiles", name: "All Smiles", category: .reactions, words: "ALL\nSMILES", treatment: 10),
        .init(id: "good-vibes", name: "Good Vibes", category: .reactions, words: "GOOD\nVIBES", treatment: 11),
        // Birthdays
        .init(id: "cake", name: "Birthday Cake", category: .birthday),
        .init(id: "cupcake", name: "Frosted Cupcake", category: .birthday),
        .init(id: "candle", name: "Birthday Candle", category: .birthday),
        .init(id: "balloons", name: "Balloon Bouquet", category: .birthday),
        .init(id: "party-hat", name: "Party Hat", category: .birthday),
        .init(id: "gift", name: "Wrapped Present", category: .birthday),
        .init(id: "happy-birthday", name: "Happy Birthday", category: .birthday, words: "HAPPY\nBIRTHDAY", treatment: 4),
        .init(id: "make-a-wish", name: "Make a Wish", category: .birthday, words: "MAKE\nA WISH", treatment: 7),
        .init(id: "cake-slice", name: "Cake Slice", category: .birthday),
        .init(id: "party-flags", name: "Party Bunting", category: .birthday),
        .init(id: "birthday-tiara", name: "Birthday Tiara", category: .birthday),
        .init(id: "party-blower", name: "Party Blower", category: .birthday),
        // Celebrations
        .init(id: "clinking-glasses", name: "Toast Together", category: .celebration),
        .init(id: "celebration-bottle", name: "Celebration Bottle", category: .celebration),
        .init(id: "disco-ball", name: "Disco Ball", category: .celebration),
        .init(id: "party-popper", name: "Confetti Popper", category: .celebration),
        .init(id: "graduation-cap", name: "Graduation Cap", category: .celebration),
        .init(id: "diploma", name: "Rolled Diploma", category: .celebration),
        .init(id: "trophy", name: "Winner Trophy", category: .celebration),
        .init(id: "medal", name: "Gold Medal", category: .celebration),
        .init(id: "congrats", name: "Congratulations", category: .celebration, words: "CONGRATS", treatment: 5),
        .init(id: "hooray", name: "Hooray", category: .celebration, words: "HOORAY", treatment: 1),
        // Analogue memories
        .init(id: "twin-lens", name: "Twin Lens Camera", category: .retro),
        .init(id: "instant-camera", name: "Instant Camera", category: .retro),
        .init(id: "film-roll", name: "35 mm Film Roll", category: .retro),
        .init(id: "cassette", name: "Mixtape Cassette", category: .retro),
        .init(id: "vinyl", name: "Vinyl Record", category: .retro),
        .init(id: "compact-disc", name: "Compact Disc", category: .retro),
        .init(id: "floppy", name: "Floppy Disk", category: .retro),
        .init(id: "television", name: "Retro Television", category: .retro),
        .init(id: "telephone", name: "Rotary Telephone", category: .retro),
        .init(id: "pixel-cursor", name: "Pixel Cursor", category: .retro),
        .init(id: "game-console", name: "Pocket Game", category: .retro),
        .init(id: "radio", name: "Transistor Radio", category: .retro),
        // Days out
        .init(id: "airplane", name: "Paper Sky Airplane", category: .travel),
        .init(id: "suitcase", name: "Weekend Suitcase", category: .travel),
        .init(id: "sun", name: "Sunny Day", category: .travel),
        .init(id: "crescent", name: "Crescent Night", category: .travel),
        .init(id: "mountains", name: "Mountain Trail", category: .travel),
        .init(id: "waves", name: "Ocean Waves", category: .travel),
        .init(id: "palm", name: "Island Palm", category: .travel),
        .init(id: "globe", name: "World Explorer", category: .travel),
        .init(id: "compass", name: "North Star Compass", category: .travel),
        .init(id: "location", name: "Here We Are", category: .travel),
        .init(id: "hiking-boot", name: "Hiking Boot", category: .travel),
        .init(id: "binoculars", name: "Lookout Binoculars", category: .travel),
        .init(id: "tent", name: "Camping Tent", category: .travel),
        .init(id: "postcard", name: "Wish You Were Here", category: .travel),
        // Everyday treasures
        .init(id: "coffee", name: "Morning Coffee", category: .everyday),
        .init(id: "open-book", name: "One More Chapter", category: .everyday),
        .init(id: "headphones", name: "Headphones", category: .everyday),
        .init(id: "music-notes", name: "Our Song", category: .everyday),
        .init(id: "pizza", name: "Pizza Night", category: .everyday),
        .init(id: "croissant", name: "Bakery Croissant", category: .everyday),
        .init(id: "donut", name: "Sprinkle Donut", category: .everyday),
        .init(id: "ice-cream", name: "Ice Cream Day", category: .everyday),
        .init(id: "tote", name: "Market Tote", category: .everyday),
        .init(id: "teacup", name: "Afternoon Tea", category: .everyday),
        .init(id: "pencil", name: "Little Pencil", category: .everyday),
        .init(id: "bicycle", name: "Sunday Bicycle", category: .everyday),
        .init(id: "umbrella", name: "Rainy Day", category: .everyday),
        .init(id: "houseplant", name: "Window Plant", category: .everyday),
        // Studio keepsakes
        .init(id: "made-to-keep", name: "Made to Keep", category: .madeToKeep, words: "MADE\nTO KEEP", treatment: 10),
        .init(id: "keep-this-moment", name: "Keep This Moment", category: .madeToKeep, words: "KEEP THIS\nMOMENT", treatment: 8),
        .init(id: "forever", name: "Forever", category: .madeToKeep, words: "FOREVER", treatment: 6),
        .init(id: "little-memory", name: "A Little Memory", category: .madeToKeep, words: "A LITTLE\nMEMORY", treatment: 3),
        .init(id: "memory-stamp", name: "Memory Postmark", category: .madeToKeep),
        .init(id: "keepsake-ticket", name: "Keepsake Ticket", category: .madeToKeep),
        .init(id: "photo-album", name: "Photo Album", category: .madeToKeep),
        .init(id: "memory-jar", name: "Memory Jar", category: .madeToKeep),
        .init(id: "memory-box", name: "Memory Box", category: .madeToKeep),
        .init(id: "pressed-flower", name: "Pressed Flower", category: .madeToKeep)
    ]

    static let definitions: [BundledStickerFactory.Definition] = motifs.map { motif in
        .init(id: "builtin.\(motif.id)", name: motif.name, category: motif.category,
              tags: [motif.name.lowercased(), motif.category.displayName.lowercased(), motif.category.rawValue.lowercased(), "doodle", "keepsake"],
              aspectRatio: motif.words == nil ? 1 : 1.6) { cg, size in
            if let words = motif.words { typography(cg, size: size, words: words, treatment: motif.treatment) }
            else {
                cg.saveGState()
                cg.scaleBy(x: size.width / 512, y: size.height / 512)
                draw(motif.id, cg)
                cg.restoreGState()
            }
        }
    }

    // Canonical coordinates, heavy outlines, white internal fills and transparent surroundings.
    private static func line(_ cg: CGContext, _ points: [(CGFloat, CGFloat)], width: CGFloat = 18) {
        guard let first = points.first else { return }
        let path = CGMutablePath()
        path.move(to: CGPoint(x: first.0, y: first.1))
        for point in points.dropFirst() { path.addLine(to: CGPoint(x: point.0, y: point.1)) }
        BundledStickerFactory.strokeInk(cg, path, width: width)
    }

    private static func shape(_ cg: CGContext, _ points: [(CGFloat, CGFloat)], black: Bool = false) {
        guard let first = points.first else { return }
        let path = CGMutablePath()
        path.move(to: CGPoint(x: first.0, y: first.1))
        for point in points.dropFirst() { path.addLine(to: CGPoint(x: point.0, y: point.1)) }
        path.closeSubpath()
        BundledStickerFactory.inkShape(cg, path, fill: black ? .black : .white)
    }

    private static func oval(_ cg: CGContext, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, black: Bool = false) {
        BundledStickerFactory.inkShape(cg, CGPath(ellipseIn: CGRect(x: x, y: y, width: w, height: h), transform: nil), fill: black ? .black : .white)
    }

    private static func box(_ cg: CGContext, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, radius: CGFloat = 16) {
        BundledStickerFactory.inkShape(cg, UIBezierPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerRadius: radius).cgPath)
    }

    private static func curve(_ cg: CGContext, _ from: CGPoint, _ c1: CGPoint, _ c2: CGPoint, _ to: CGPoint, width: CGFloat = 18) {
        let path = CGMutablePath()
        path.move(to: from)
        path.addCurve(to: to, control1: c1, control2: c2)
        BundledStickerFactory.strokeInk(cg, path, width: width)
    }

    private static func heart(_ cg: CGContext, _ rect: CGRect, black: Bool = false) {
        BundledStickerFactory.inkShape(cg, BundledStickerFactory.heartPath(in: rect), fill: black ? .black : .white)
    }

    private static func star(_ cg: CGContext, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat, black: Bool = false) {
        BundledStickerFactory.inkShape(cg, BundledStickerFactory.starPath(in: CGRect(x: x, y: y, width: size, height: size), points: 5, innerRatio: 0.46), fill: black ? .black : .white)
    }

    private static func face(_ cg: CGContext, _ y: CGFloat = 245) {
        oval(cg, 180, y, 22, 28, black: true)
        oval(cg, 310, y, 22, 28, black: true)
        curve(cg, CGPoint(x: 212, y: y + 65), CGPoint(x: 242, y: y + 104), CGPoint(x: 279, y: y + 104), CGPoint(x: 305, y: y + 65), width: 14)
    }

    private static func label(_ cg: CGContext, _ words: String, _ rect: CGRect) {
        BundledStickerFactory.drawLabel(cg, words, in: rect)
    }

    private static func typography(_ cg: CGContext, size: CGSize, words: String, treatment: Int) {
        let r = CGRect(origin: .zero, size: size).insetBy(dx: 26, dy: 44)
        let path: CGPath
        switch treatment % 6 {
        case 0: path = UIBezierPath(ovalIn: r).cgPath
        case 1:
            // A wide comic burst must use both axes; a circular star would cut through
            // the fitted wordmark on these landscape type stickers.
            let burst = CGMutablePath()
            for index in 0..<20 {
                let angle = CGFloat(index) * .pi / 10 - .pi / 2
                let radius: CGFloat = index.isMultiple(of: 2) ? 1 : 0.83
                let point = CGPoint(x: r.midX + cos(angle) * r.width / 2 * radius,
                                    y: r.midY + sin(angle) * r.height / 2 * radius)
                if index == 0 { burst.move(to: point) } else { burst.addLine(to: point) }
            }
            burst.closeSubpath()
            path = burst
        case 2:
            let ticket = UIBezierPath(roundedRect: r, cornerRadius: 16)
            path = ticket.cgPath
        case 3: path = UIBezierPath(roundedRect: r.insetBy(dx: 12, dy: 0), cornerRadius: 65).cgPath
        case 4: path = UIBezierPath(roundedRect: r, cornerRadius: 24).cgPath
        default: path = UIBezierPath(roundedRect: r.insetBy(dx: 0, dy: 28), cornerRadius: 4).cgPath
        }
        BundledStickerFactory.inkShape(cg, path)
        let lines = words.components(separatedBy: "\n")
        let content = r.insetBy(dx: treatment % 6 == 1 ? 98 : 52, dy: lines.count == 1 ? 110 : 65)
        for (index, word) in lines.enumerated() {
            let height = content.height / CGFloat(lines.count)
            label(cg, word, CGRect(x: content.minX, y: content.minY + CGFloat(index) * height, width: content.width, height: height))
        }
        // A second family of ornaments differentiates each editorial treatment.
        cg.saveGState()
        cg.scaleBy(x: size.width / 512, y: size.height / 512)
        switch treatment {
        case 0: line(cg, [(95, 92), (145, 115)]); line(cg, [(370, 392), (420, 420)])
        case 1: line(cg, [(70, 30), (95, 65)]); line(cg, [(420, 450), (450, 480)])
        case 2: for y in stride(from: 140, through: 370, by: 45) { line(cg, [(62, CGFloat(y)), (62, CGFloat(y + 14))], width: 12) }
        case 3: heart(cg, CGRect(x: 220, y: 35, width: 70, height: 70))
        case 4: star(cg, 210, 22, 90); line(cg, [(150, 445), (360, 445)], width: 12)
        case 5: line(cg, [(85, 88), (430, 88)], width: 12); line(cg, [(85, 428), (430, 428)], width: 12)
        case 6: line(cg, [(80, 90), (122, 125)]); line(cg, [(430, 90), (392, 125)]); line(cg, [(80, 430), (122, 397)])
        case 7: oval(cg, 35, 400, 45, 45); oval(cg, 420, 38, 35, 35)
        case 8: for x in [95, 255, 415] { oval(cg, CGFloat(x), 425, 12, 12, black: true) }
        case 9: line(cg, [(90, 410), (380, 410)], width: 26); line(cg, [(120, 442), (330, 442)], width: 12)
        case 10: line(cg, [(60, 82), (185, 82)], width: 12); line(cg, [(327, 82), (450, 82)], width: 12); heart(cg, CGRect(x: 224, y: 31, width: 64, height: 64))
        default: star(cg, 38, 35, 75); star(cg, 403, 402, 75)
        }
        cg.restoreGState()
    }

    private static func draw(_ id: String, _ cg: CGContext) {
        switch id {
        case "rosette":
            shape(cg, [(180, 270), (145, 470), (220, 425), (264, 470), (285, 275)])
            shape(cg, [(265, 285), (305, 460), (340, 413), (405, 440), (340, 260)])
            BundledStickerFactory.inkShape(cg, BundledStickerFactory.starPath(in: CGRect(x: 95, y: 35, width: 310, height: 310), points: 12, innerRatio: 0.88))
            oval(cg, 155, 95, 190, 190); star(cg, 196, 135, 110)
        case "ribbon-tails":
            shape(cg, [(105, 185), (85, 450), (165, 406), (225, 450), (238, 200)])
            shape(cg, [(267, 200), (285, 450), (346, 406), (427, 450), (401, 180)])
            box(cg, 80, 100, 355, 135, radius: 30)
            line(cg, [(130, 148), (378, 148)], width: 12); line(cg, [(167, 240), (160, 356)], width: 14)
        case "photo-frame":
            let outer = CGRect(x: 70, y: 38, width: 372, height: 434)
            BundledStickerFactory.strokeInk(cg, UIBezierPath(rect: outer).cgPath, width: 20)
            BundledStickerFactory.strokeInk(cg, UIBezierPath(rect: CGRect(x: 100, y: 70, width: 312, height: 290)).cgPath, width: 18)
            line(cg, [(125, 417), (300, 417)], width: 14); heart(cg, CGRect(x: 342, y: 387, width: 55, height: 55))
        case "film-border":
            BundledStickerFactory.strokeInk(cg, UIBezierPath(rect: CGRect(x: 58, y: 50, width: 396, height: 410)).cgPath, width: 18)
            line(cg, [(120, 54), (120, 455)]); line(cg, [(392, 54), (392, 455)])
            for y in stride(from: 87, through: 400, by: 65) {
                box(cg, 77, CGFloat(y), 24, 30, radius: 5); box(cg, 411, CGFloat(y), 24, 30, radius: 5)
            }
        case "admit-one":
            shape(cg, [(65, 135), (450, 135), (450, 210), (417, 250), (450, 290), (450, 370), (65, 370), (65, 290), (99, 250), (65, 210)])
            for y in stride(from: 170, through: 335, by: 45) { line(cg, [(145, CGFloat(y)), (145, CGFloat(y + 18))], width: 12) }
            label(cg, "ADMIT", CGRect(x: 180, y: 175, width: 225, height: 95)); label(cg, "ONE", CGRect(x: 205, y: 277, width: 175, height: 65))
        case "wax-seal":
            BundledStickerFactory.inkShape(cg, BundledStickerFactory.starPath(in: CGRect(x: 45, y: 45, width: 420, height: 420), points: 16, innerRatio: 0.94))
            oval(cg, 115, 115, 282, 282); heart(cg, CGRect(x: 175, y: 178, width: 163, height: 152))
        case "scallop-stamp":
            box(cg, 78, 75, 350, 360, radius: 35)
            for x in [110, 185, 260, 335] { oval(cg, CGFloat(x), 54, 38, 38); oval(cg, CGFloat(x), 415, 38, 38) }
            for y in [125, 200, 275, 350] { oval(cg, 56, CGFloat(y), 38, 38); oval(cg, 411, CGFloat(y), 38, 38) }
            box(cg, 132, 129, 240, 250); star(cg, 179, 180, 145)
        case "sunburst":
            oval(cg, 170, 170, 172, 172)
            for i in 0..<16 {
                let a = CGFloat(i) * .pi / 8
                line(cg, [(256 + cos(a) * 116, 256 + sin(a) * 116), (256 + cos(a) * 216, 256 + sin(a) * 216)], width: i % 2 == 0 ? 22 : 14)
            }
        case "love-letter":
            box(cg, 45, 160, 425, 270, radius: 12)
            line(cg, [(50, 170), (255, 330), (465, 170)])
            line(cg, [(52, 424), (185, 298)]); line(cg, [(465, 424), (330, 298)])
            heart(cg, CGRect(x: 185, y: 60, width: 145, height: 140))
        case "heart-lock":
            curve(cg, CGPoint(x: 160, y: 222), CGPoint(x: 140, y: 40), CGPoint(x: 372, y: 40), CGPoint(x: 352, y: 222), width: 30)
            heart(cg, CGRect(x: 80, y: 177, width: 350, height: 290))
            oval(cg, 236, 280, 40, 45, black: true); shape(cg, [(249, 315), (237, 368), (277, 368), (264, 315)], black: true)
        case "linked-hearts":
            heart(cg, CGRect(x: 42, y: 112, width: 285, height: 285)); heart(cg, CGRect(x: 194, y: 122, width: 275, height: 275))
            curve(cg, CGPoint(x: 145, y: 260), CGPoint(x: 238, y: 185), CGPoint(x: 280, y: 335), CGPoint(x: 373, y: 265), width: 22)
        case "heart-wings":
            shape(cg, [(230, 227), (73, 90), (46, 154), (155, 277), (51, 235), (77, 318), (223, 350)])
            shape(cg, [(282, 227), (439, 90), (466, 154), (357, 277), (461, 235), (435, 318), (289, 350)])
            heart(cg, CGRect(x: 165, y: 175, width: 185, height: 235))
        case "love-potion":
            box(cg, 198, 45, 116, 50, radius: 8); box(cg, 211, 92, 90, 95, radius: 6)
            oval(cg, 107, 165, 298, 305); line(cg, [(121, 336), (390, 336)])
            heart(cg, CGRect(x: 187, y: 243, width: 139, height: 138)); oval(cg, 156, 208, 25, 45)
        case "rose":
            line(cg, [(250, 250), (230, 465)], width: 22)
            oval(cg, 128, 62, 228, 215); oval(cg, 166, 87, 173, 146); oval(cg, 203, 107, 99, 88)
            shape(cg, [(239, 361), (136, 276), (111, 330), (190, 391)])
            shape(cg, [(240, 398), (363, 326), (367, 383), (279, 431)])
        case "kiss":
            shape(cg, [(40, 250), (162, 154), (251, 196), (346, 154), (472, 250), (350, 368), (159, 367)])
            curve(cg, CGPoint(x: 45, y: 250), CGPoint(x: 150, y: 310), CGPoint(x: 364, y: 311), CGPoint(x: 466, y: 250), width: 24)
            curve(cg, CGPoint(x: 130, y: 222), CGPoint(x: 170, y: 176), CGPoint(x: 202, y: 224), CGPoint(x: 235, y: 232), width: 14)
        case "heart-key":
            heart(cg, CGRect(x: 148, y: 45, width: 218, height: 195))
            oval(cg, 232, 110, 48, 48); line(cg, [(256, 239), (256, 449)], width: 30)
            line(cg, [(258, 384), (339, 384), (339, 425)], width: 24)
        case "holding-hands":
            shape(cg, [(39, 303), (128, 183), (212, 203), (260, 254), (224, 297), (181, 261), (143, 344), (77, 397)])
            shape(cg, [(473, 306), (388, 180), (305, 201), (234, 265), (279, 308), (322, 265), (370, 349), (434, 398)])
            line(cg, [(162, 290), (204, 323), (237, 304)], width: 16); heart(cg, CGRect(x: 212, y: 55, width: 89, height: 84))
        case "love-postage":
            box(cg, 95, 40, 322, 423, radius: 8)
            for y in stride(from: 80, through: 415, by: 56) { oval(cg, 77, CGFloat(y), 32, 32); oval(cg, 401, CGFloat(y), 32, 32) }
            heart(cg, CGRect(x: 163, y: 130, width: 185, height: 190)); label(cg, "LOVE", CGRect(x: 154, y: 350, width: 206, height: 63))
        case "cat":
            shape(cg, [(110, 225), (99, 66), (218, 157), (315, 157), (418, 66), (408, 232)])
            oval(cg, 102, 144, 309, 292); face(cg)
            shape(cg, [(239, 295), (270, 295), (255, 317)], black: true)
            for y in [289, 332] { line(cg, [(53, CGFloat(y)), (149, CGFloat(y + 9))], width: 14); line(cg, [(361, CGFloat(y + 9)), (458, CGFloat(y))], width: 14) }
        case "puppy":
            oval(cg, 58, 110, 128, 301); oval(cg, 329, 110, 128, 301)
            oval(cg, 138, 127, 244, 284); oval(cg, 207, 279, 104, 90)
            oval(cg, 184, 217, 24, 30, black: true); oval(cg, 308, 217, 24, 30, black: true)
            oval(cg, 241, 286, 35, 24, black: true); curve(cg, CGPoint(x: 223, y: 334), CGPoint(x: 235, y: 366), CGPoint(x: 287, y: 366), CGPoint(x: 297, y: 334), width: 14)
        case "bear":
            oval(cg, 88, 74, 117, 121); oval(cg, 307, 74, 117, 121)
            oval(cg, 95, 127, 322, 304); oval(cg, 186, 266, 141, 103)
            oval(cg, 178, 233, 22, 28, black: true); oval(cg, 312, 233, 22, 28, black: true)
            oval(cg, 236, 279, 40, 31, black: true); line(cg, [(255, 309), (255, 340), (233, 355)], width: 14)
        case "bunny":
            oval(cg, 125, 34, 90, 253); oval(cg, 296, 34, 90, 253)
            oval(cg, 94, 219, 328, 238); face(cg, 290); oval(cg, 235, 326, 40, 25)
            line(cg, [(168, 83), (170, 179)], width: 14); line(cg, [(341, 83), (339, 179)], width: 14)
        case "frog":
            oval(cg, 76, 98, 139, 153); oval(cg, 297, 98, 139, 153)
            oval(cg, 54, 167, 405, 270); oval(cg, 126, 137, 37, 42, black: true); oval(cg, 347, 137, 37, 42, black: true)
            curve(cg, CGPoint(x: 123, y: 285), CGPoint(x: 159, y: 380), CGPoint(x: 363, y: 380), CGPoint(x: 393, y: 285), width: 20)
        case "duck":
            oval(cg, 93, 222, 329, 208); oval(cg, 265, 97, 164, 182)
            shape(cg, [(412, 177), (486, 202), (412, 227)])
            oval(cg, 346, 150, 25, 28, black: true); curve(cg, CGPoint(x: 143, y: 311), CGPoint(x: 155, y: 392), CGPoint(x: 278, y: 383), CGPoint(x: 299, y: 305), width: 18)
            line(cg, [(90, 455), (425, 455)], width: 14)
        case "fish":
            shape(cg, [(326, 247), (464, 134), (461, 365)])
            oval(cg, 46, 133, 326, 241); oval(cg, 126, 208, 24, 28, black: true)
            curve(cg, CGPoint(x: 218, y: 169), CGPoint(x: 182, y: 215), CGPoint(x: 182, y: 296), CGPoint(x: 218, y: 338), width: 18)
            shape(cg, [(253, 227), (302, 258), (250, 301)]); oval(cg, 72, 60, 33, 33)
        case "butterfly":
            oval(cg, 43, 67, 204, 233); oval(cg, 265, 67, 204, 233)
            oval(cg, 93, 267, 149, 170); oval(cg, 270, 267, 149, 170)
            box(cg, 232, 176, 49, 233, radius: 25); line(cg, [(249, 179), (195, 108)]); line(cg, [(264, 179), (317, 108)])
            oval(cg, 99, 125, 77, 98); oval(cg, 338, 125, 77, 98)
        case "strawberry":
            shape(cg, [(73, 199), (172, 124), (341, 124), (438, 199), (402, 337), (255, 461), (110, 337)])
            shape(cg, [(130, 146), (181, 69), (240, 121), (257, 42), (282, 121), (335, 67), (385, 149), (260, 193)])
            for p in [(170, 241), (268, 242), (359, 244), (210, 316), (312, 319), (258, 390)] { oval(cg, CGFloat(p.0), CGFloat(p.1), 15, 23, black: true) }
        case "mushroom":
            box(cg, 209, 219, 103, 249, radius: 35)
            let p = UIBezierPath(); p.move(to: CGPoint(x: 44, y: 262)); p.addCurve(to: CGPoint(x: 468, y: 262), controlPoint1: CGPoint(x: 49, y: -10), controlPoint2: CGPoint(x: 463, y: -10)); p.close()
            BundledStickerFactory.inkShape(cg, p.cgPath)
            oval(cg, 99, 157, 64, 60); oval(cg, 219, 106, 75, 74); oval(cg, 348, 178, 58, 50)
            line(cg, [(239, 343), (237, 413)], width: 14)
        case "bee":
            oval(cg, 124, 58, 113, 173); oval(cg, 278, 58, 113, 173)
            oval(cg, 92, 199, 316, 211); line(cg, [(208, 210), (208, 398)], width: 25); line(cg, [(283, 209), (283, 400)], width: 25)
            oval(cg, 353, 260, 22, 25, black: true); shape(cg, [(94, 275), (37, 302), (94, 327)])
            line(cg, [(372, 219), (414, 157)], width: 14)
        case "snail":
            curve(cg, CGPoint(x: 47, y: 421), CGPoint(x: 148, y: 346), CGPoint(x: 290, y: 414), CGPoint(x: 407, y: 365), width: 35)
            oval(cg, 86, 148, 258, 249); oval(cg, 140, 201, 149, 145); oval(cg, 190, 248, 48, 47)
            box(cg, 360, 226, 91, 177, radius: 44); line(cg, [(382, 233), (367, 153)]); line(cg, [(424, 229), (451, 154)])
            oval(cg, 352, 125, 32, 37); oval(cg, 438, 126, 32, 37)
        case "whale":
            oval(cg, 49, 200, 332, 236); shape(cg, [(340, 305), (435, 235), (478, 172), (480, 300), (428, 360), (350, 380)])
            oval(cg, 121, 283, 24, 30, black: true); curve(cg, CGPoint(x: 80, y: 353), CGPoint(x: 112, y: 395), CGPoint(x: 164, y: 395), CGPoint(x: 185, y: 354), width: 16)
            line(cg, [(250, 181), (248, 97), (215, 72)]); line(cg, [(250, 123), (286, 72)])
        case "sleepy-moon", "crescent":
            let p = UIBezierPath(); p.move(to: CGPoint(x: 335, y: 45)); p.addCurve(to: CGPoint(x: 391, y: 430), controlPoint1: CGPoint(x: 42, y: 10), controlPoint2: CGPoint(x: 31, y: 475)); p.addCurve(to: CGPoint(x: 335, y: 45), controlPoint1: CGPoint(x: 187, y: 401), controlPoint2: CGPoint(x: 189, y: 140)); p.close()
            BundledStickerFactory.inkShape(cg, p.cgPath)
            if id == "sleepy-moon" {
                curve(cg, CGPoint(x: 113, y: 258), CGPoint(x: 137, y: 284), CGPoint(x: 163, y: 284), CGPoint(x: 183, y: 256), width: 14)
                label(cg, "Z", CGRect(x: 345, y: 165, width: 74, height: 90)); label(cg, "z", CGRect(x: 403, y: 100, width: 46, height: 62))
            } else { star(cg, 343, 141, 112); star(cg, 323, 300, 62) }
        case "scribble":
            curve(cg, CGPoint(x: 47, y: 246), CGPoint(x: 159, y: 160), CGPoint(x: 337, y: 328), CGPoint(x: 463, y: 214), width: 25)
            curve(cg, CGPoint(x: 58, y: 321), CGPoint(x: 181, y: 207), CGPoint(x: 328, y: 389), CGPoint(x: 449, y: 286), width: 21)
            line(cg, [(100, 383), (383, 371)], width: 14)
        case "swirl-arrow":
            curve(cg, CGPoint(x: 54, y: 386), CGPoint(x: 105, y: 164), CGPoint(x: 376, y: 157), CGPoint(x: 304, y: 341), width: 23)
            curve(cg, CGPoint(x: 304, y: 341), CGPoint(x: 181, y: 460), CGPoint(x: 159, y: 54), CGPoint(x: 455, y: 109), width: 23)
            line(cg, [(388, 62), (462, 108), (402, 162)], width: 24)
        case "pointing-hand":
            shape(cg, [(52, 299), (224, 210), (420, 210), (470, 242), (443, 275), (291, 275), (379, 311), (357, 356), (280, 351), (308, 389), (269, 420), (191, 396), (113, 370)])
            line(cg, [(78, 289), (135, 372)]); line(cg, [(248, 320), (280, 352)], width: 14)
        case "stitched-patch":
            shape(cg, [(80, 130), (417, 71), (469, 382), (125, 445)])
            for i in 0..<7 { let x = CGFloat(125 + i * 40); line(cg, [(x, 121), (x + 8, 146)], width: 13); line(cg, [(x + 35, 389), (x + 40, 411)], width: 13) }
            star(cg, 191, 185, 159)
        case "paperclips":
            cg.saveGState(); cg.translateBy(x: 254, y: 250); cg.rotate(by: -.pi / 5)
            for x: CGFloat in [-145, 4] {
                BundledStickerFactory.strokeInk(cg, UIBezierPath(roundedRect: CGRect(x: x, y: -164, width: 133, height: 320), cornerRadius: 60).cgPath, width: 20)
                BundledStickerFactory.strokeInk(cg, UIBezierPath(roundedRect: CGRect(x: x + 38, y: -127, width: 59, height: 220), cornerRadius: 29).cgPath, width: 16)
            }; cg.restoreGState()
        case "peace-hand":
            shape(cg, [(145, 431), (108, 282), (115, 245), (171, 256), (137, 94), (158, 52), (191, 63), (227, 240), (273, 62), (309, 45), (337, 73), (305, 272), (369, 285), (393, 351), (347, 440)])
            line(cg, [(171, 258), (247, 320), (307, 298)], width: 16); line(cg, [(240, 327), (202, 384)], width: 16)
        case "cake":
            box(cg, 77, 250, 359, 192); box(cg, 77, 230, 359, 67, radius: 24)
            for x in [151, 250, 347] { box(cg, CGFloat(x), 137, 20, 99, radius: 5); oval(cg, CGFloat(x - 3), 87, 27, 43) }
            line(cg, [(57, 447), (457, 447)], width: 25); line(cg, [(87, 364), (426, 364)], width: 14)
        case "cupcake":
            shape(cg, [(118, 286), (393, 286), (349, 451), (160, 451)])
            for x in [183, 249, 316] { line(cg, [(CGFloat(x), 317), (CGFloat(x), 419)], width: 14) }
            oval(cg, 87, 223, 336, 100); oval(cg, 127, 155, 258, 103); oval(cg, 176, 102, 163, 95); oval(cg, 224, 58, 60, 60)
        case "candle":
            box(cg, 169, 200, 172, 262, radius: 11)
            for y in [247, 317, 386] { line(cg, [(178, CGFloat(y)), (331, CGFloat(y + 42))], width: 18) }
            line(cg, [(255, 191), (255, 139)], width: 16)
            let p = UIBezierPath(); p.move(to: CGPoint(x: 255, y: 40)); p.addCurve(to: CGPoint(x: 255, y: 153), controlPoint1: CGPoint(x: 152, y: 150), controlPoint2: CGPoint(x: 196, y: 168)); p.addCurve(to: CGPoint(x: 255, y: 40), controlPoint1: CGPoint(x: 354, y: 169), controlPoint2: CGPoint(x: 317, y: 99)); p.close(); BundledStickerFactory.inkShape(cg, p.cgPath)
        case "balloons":
            curve(cg, CGPoint(x: 134, y: 241), CGPoint(x: 106, y: 334), CGPoint(x: 266, y: 348), CGPoint(x: 256, y: 467))
            curve(cg, CGPoint(x: 369, y: 241), CGPoint(x: 401, y: 326), CGPoint(x: 235, y: 357), CGPoint(x: 256, y: 467))
            line(cg, [(251, 220), (256, 467)], width: 14)
            oval(cg, 47, 93, 164, 180); oval(cg, 297, 93, 164, 180); oval(cg, 172, 40, 165, 183)
            for x in [125, 251, 378] { shape(cg, [(CGFloat(x - 12), 254), (CGFloat(x + 14), 254), (CGFloat(x), 278)]) }
        case "party-hat":
            shape(cg, [(59, 430), (253, 84), (453, 430)])
            line(cg, [(123, 318), (376, 318)], width: 21); line(cg, [(170, 230), (321, 230)], width: 20)
            oval(cg, 216, 43, 75, 75); box(cg, 52, 422, 407, 42, radius: 20)
        case "gift":
            box(cg, 78, 214, 355, 246); box(cg, 53, 175, 405, 84)
            box(cg, 229, 179, 55, 280, radius: 3)
            oval(cg, 109, 79, 145, 110); oval(cg, 255, 79, 145, 110)
            line(cg, [(143, 117), (255, 180), (370, 117)], width: 16)
        case "cake-slice":
            shape(cg, [(72, 219), (316, 96), (443, 254), (443, 429), (72, 396)])
            line(cg, [(78, 225), (439, 263)]); line(cg, [(83, 313), (435, 351)], width: 18)
            oval(cg, 279, 79, 61, 67); curve(cg, CGPoint(x: 311, y: 83), CGPoint(x: 322, y: 57), CGPoint(x: 357, y: 41), CGPoint(x: 370, y: 44), width: 14)
        case "party-flags":
            curve(cg, CGPoint(x: 32, y: 98), CGPoint(x: 116, y: 216), CGPoint(x: 394, y: 213), CGPoint(x: 480, y: 98), width: 20)
            shape(cg, [(58, 129), (141, 170), (106, 295)]); shape(cg, [(178, 184), (262, 194), (227, 323)]); shape(cg, [(306, 191), (389, 160), (378, 307)])
            star(cg, 73, 342, 85); star(cg, 351, 357, 69)
        case "birthday-tiara":
            curve(cg, CGPoint(x: 58, y: 399), CGPoint(x: 104, y: 326), CGPoint(x: 408, y: 326), CGPoint(x: 454, y: 399), width: 28)
            for i in 0..<3 { let x = CGFloat(89 + i * 122); curve(cg, CGPoint(x: x, y: 344), CGPoint(x: x - 20, y: 81), CGPoint(x: x + 121, y: 83), CGPoint(x: x + 92, y: 344), width: 20) }
            heart(cg, CGRect(x: 207, y: 72, width: 99, height: 115)); line(cg, [(83, 426), (429, 426)], width: 18)
        case "party-blower":
            shape(cg, [(53, 330), (88, 271), (296, 368), (266, 422)])
            curve(cg, CGPoint(x: 282, y: 399), CGPoint(x: 468, y: 402), CGPoint(x: 463, y: 167), CGPoint(x: 342, y: 200), width: 32)
            curve(cg, CGPoint(x: 342, y: 200), CGPoint(x: 257, y: 237), CGPoint(x: 372, y: 309), CGPoint(x: 394, y: 232), width: 24)
            line(cg, [(160, 83), (205, 151)]); line(cg, [(279, 65), (280, 132)]); line(cg, [(397, 84), (357, 140)])
        case "clinking-glasses":
            shape(cg, [(87, 96), (247, 157), (173, 300), (79, 263)])
            shape(cg, [(425, 96), (265, 157), (339, 300), (433, 263)])
            line(cg, [(127, 293), (91, 430), (48, 414), (144, 449)])
            line(cg, [(385, 293), (421, 430), (464, 414), (368, 449)])
            line(cg, [(246, 57), (257, 97)], width: 14); line(cg, [(204, 75), (217, 111)], width: 14)
        case "celebration-bottle":
            box(cg, 219, 120, 77, 146, radius: 8); box(cg, 145, 244, 226, 221, radius: 57)
            box(cg, 200, 134, 116, 30, radius: 5); box(cg, 173, 327, 170, 88, radius: 9)
            star(cg, 222, 342, 63); shape(cg, [(224, 80), (220, 32), (298, 32), (290, 80)])
            line(cg, [(147, 86), (105, 55)]); line(cg, [(374, 96), (423, 45)])
        case "disco-ball":
            line(cg, [(256, 31), (256, 86)], width: 18); oval(cg, 79, 88, 354, 355)
            for x in [173, 254, 335] { curve(cg, CGPoint(x: CGFloat(x), y: 115), CGPoint(x: CGFloat(x - 18), y: 205), CGPoint(x: CGFloat(x - 18), y: 336), CGPoint(x: CGFloat(x), y: 414), width: 12) }
            for y in [171, 253, 336] { line(cg, [(100, CGFloat(y)), (412, CGFloat(y))], width: 12) }
            star(cg, 31, 56, 70); star(cg, 410, 387, 65)
        case "party-popper":
            shape(cg, [(72, 451), (116, 218), (300, 381)])
            line(cg, [(98, 364), (191, 410)]); line(cg, [(116, 292), (244, 397)])
            curve(cg, CGPoint(x: 219, y: 267), CGPoint(x: 211, y: 129), CGPoint(x: 348, y: 166), CGPoint(x: 335, y: 58))
            curve(cg, CGPoint(x: 285, y: 301), CGPoint(x: 402, y: 321), CGPoint(x: 353, y: 208), CGPoint(x: 463, y: 211))
            star(cg, 83, 81, 80); star(cg, 362, 83, 82); oval(cg, 408, 341, 36, 36)
        case "graduation-cap":
            shape(cg, [(51, 188), (253, 85), (462, 188), (255, 292)])
            curve(cg, CGPoint(x: 135, y: 244), CGPoint(x: 124, y: 409), CGPoint(x: 382, y: 409), CGPoint(x: 380, y: 245))
            line(cg, [(253, 191), (438, 243), (438, 412)]); line(cg, [(417, 414), (458, 414), (443, 450)], width: 22)
        case "diploma":
            shape(cg, [(75, 171), (401, 111), (455, 335), (138, 407)])
            oval(cg, 72, 164, 64, 225); oval(cg, 397, 107, 65, 232)
            shape(cg, [(244, 150), (278, 144), (319, 364), (286, 373)])
            shape(cg, [(282, 275), (352, 408), (303, 390), (281, 453), (246, 285)])
        case "trophy":
            oval(cg, 48, 121, 140, 166); oval(cg, 324, 121, 140, 166)
            shape(cg, [(132, 81), (380, 81), (361, 274), (306, 336), (205, 336), (151, 274)])
            box(cg, 235, 328, 42, 85, radius: 5); box(cg, 157, 410, 197, 54, radius: 8); star(cg, 209, 157, 97)
        case "medal":
            shape(cg, [(146, 48), (223, 48), (292, 238), (204, 254)])
            shape(cg, [(292, 48), (369, 48), (306, 254), (220, 238)])
            oval(cg, 126, 217, 260, 260); oval(cg, 173, 264, 167, 167); star(cg, 205, 295, 106)
        case "twin-lens":
            box(cg, 134, 63, 249, 406, radius: 30); box(cg, 160, 40, 197, 63, radius: 5)
            oval(cg, 190, 119, 138, 138); oval(cg, 183, 278, 152, 152); oval(cg, 222, 317, 74, 74)
            box(cg, 352, 144, 62, 45, radius: 12)
        case "instant-camera":
            box(cg, 72, 91, 366, 284, radius: 44); box(cg, 111, 313, 288, 67, radius: 10)
            oval(cg, 196, 139, 163, 159); oval(cg, 241, 184, 72, 70); box(cg, 103, 127, 70, 44, radius: 10)
            shape(cg, [(142, 365), (369, 365), (404, 471), (113, 471)])
            box(cg, 154, 392, 204, 45, radius: 0)
        case "film-roll":
            box(cg, 58, 81, 177, 352, radius: 25); oval(cg, 59, 55, 175, 60)
            shape(cg, [(234, 169), (456, 169), (456, 410), (234, 410)])
            box(cg, 270, 212, 135, 150, radius: 0)
            for x in [263, 323, 383, 429] { box(cg, CGFloat(x), 178, 19, 23, radius: 3); box(cg, CGFloat(x), 378, 19, 23, radius: 3) }
            label(cg, "35", CGRect(x: 86, y: 215, width: 110, height: 92))
        case "cassette":
            box(cg, 41, 118, 430, 292, radius: 24); box(cg, 74, 155, 364, 160, radius: 12)
            oval(cg, 103, 197, 77, 78); oval(cg, 331, 197, 77, 78); line(cg, [(186, 228), (322, 228)], width: 13)
            shape(cg, [(125, 406), (163, 334), (349, 334), (385, 406)])
            for x in [66, 427] { oval(cg, CGFloat(x), 371, 13, 13, black: true) }
        case "vinyl":
            oval(cg, 48, 48, 416, 416); oval(cg, 99, 99, 315, 315); oval(cg, 160, 160, 193, 193); oval(cg, 233, 233, 46, 46)
            line(cg, [(122, 160), (157, 125)], width: 14); line(cg, [(337, 389), (385, 341)], width: 14)
        case "compact-disc":
            oval(cg, 47, 47, 420, 420); oval(cg, 199, 199, 114, 114); oval(cg, 237, 237, 38, 38)
            line(cg, [(87, 151), (191, 219)], width: 16); line(cg, [(124, 92), (218, 194)], width: 16)
            line(cg, [(318, 294), (425, 363)], width: 18); line(cg, [(293, 319), (362, 425)], width: 18)
        case "floppy":
            shape(cg, [(80, 55), (381, 55), (441, 110), (441, 456), (80, 456)])
            box(cg, 142, 56, 204, 133, radius: 4); box(cg, 268, 72, 44, 91, radius: 2)
            box(cg, 130, 269, 260, 186, radius: 7); line(cg, [(165, 319), (350, 319)], width: 14); line(cg, [(165, 364), (314, 364)], width: 14)
        case "television":
            line(cg, [(178, 44), (254, 119), (337, 43)])
            box(cg, 52, 129, 410, 290, radius: 33); box(cg, 78, 159, 274, 220, radius: 30)
            oval(cg, 381, 178, 42, 43); oval(cg, 382, 260, 42, 43)
            line(cg, [(129, 422), (97, 467)]); line(cg, [(383, 422), (415, 467)])
        case "telephone":
            shape(cg, [(72, 275), (138, 198), (374, 198), (439, 275), (462, 432), (49, 432)])
            oval(cg, 182, 259, 149, 144); oval(cg, 228, 304, 57, 57)
            curve(cg, CGPoint(x: 80, y: 149), CGPoint(x: 133, y: 38), CGPoint(x: 378, y: 38), CGPoint(x: 432, y: 149), width: 42)
            box(cg, 54, 122, 95, 86, radius: 27); box(cg, 363, 122, 95, 86, radius: 27)
        case "pixel-cursor":
            shape(cg, [(113, 45), (113, 393), (196, 307), (257, 461), (330, 430), (267, 283), (397, 283), (397, 242), (349, 242), (349, 193), (299, 193), (299, 145), (251, 145), (251, 96), (203, 96), (203, 45)])
        case "game-console":
            box(cg, 112, 40, 288, 432, radius: 32); box(cg, 149, 87, 213, 173, radius: 12)
            shape(cg, [(160, 314), (190, 314), (190, 284), (222, 284), (222, 314), (250, 314), (250, 346), (222, 346), (222, 377), (190, 377), (190, 346), (160, 346)])
            oval(cg, 296, 319, 31, 31); oval(cg, 340, 286, 31, 31); line(cg, [(280, 417), (352, 417)], width: 12)
        case "radio":
            line(cg, [(349, 118), (437, 41)], width: 14); box(cg, 50, 124, 413, 292, radius: 35)
            oval(cg, 78, 181, 203, 201); oval(cg, 115, 217, 128, 128)
            box(cg, 303, 164, 123, 59, radius: 6); oval(cg, 327, 285, 69, 70)
            line(cg, [(146, 124), (146, 91), (342, 91), (342, 124)], width: 18)
        case "airplane":
            shape(cg, [(58, 280), (238, 214), (315, 48), (356, 59), (315, 190), (451, 146), (474, 173), (305, 282), (222, 434), (179, 446), (211, 304), (89, 328)])
            curve(cg, CGPoint(x: 53, y: 448), CGPoint(x: 130, y: 395), CGPoint(x: 76, y: 366), CGPoint(x: 148, y: 357), width: 14)
        case "suitcase":
            box(cg, 62, 158, 388, 286, radius: 40); box(cg, 197, 97, 118, 58, radius: 18)
            line(cg, [(143, 166), (143, 435)], width: 19); line(cg, [(369, 166), (369, 435)], width: 19)
            star(cg, 194, 237, 118); line(cg, [(129, 446), (129, 470)], width: 22); line(cg, [(385, 446), (385, 470)], width: 22)
        case "sun":
            oval(cg, 139, 139, 234, 234); face(cg, 214)
            for i in 0..<12 { let a = CGFloat(i) * .pi / 6; line(cg, [(256 + cos(a) * 152, 256 + sin(a) * 152), (256 + cos(a) * 218, 256 + sin(a) * 218)], width: 19) }
        case "mountains":
            shape(cg, [(33, 412), (201, 101), (355, 412)]); shape(cg, [(211, 412), (348, 173), (478, 412)])
            line(cg, [(143, 209), (180, 225), (202, 188), (226, 229), (258, 209)], width: 15)
            line(cg, [(309, 242), (349, 265), (381, 239)], width: 15); line(cg, [(45, 454), (467, 454)])
        case "waves":
            for y in [193, 286, 379] {
                let h = CGFloat(y)
                curve(cg, CGPoint(x: 42, y: h), CGPoint(x: 97, y: h - 110), CGPoint(x: 151, y: h + 98), CGPoint(x: 206, y: h), width: 22)
                curve(cg, CGPoint(x: 206, y: h), CGPoint(x: 271, y: h - 110), CGPoint(x: 339, y: h + 98), CGPoint(x: 465, y: h - 33), width: 22)
            }
        case "palm":
            shape(cg, [(223, 448), (255, 173), (285, 175), (307, 448)])
            for end in [CGPoint(x: 45, y: 178), CGPoint(x: 81, y: 294), CGPoint(x: 148, y: 81), CGPoint(x: 384, y: 78), CGPoint(x: 462, y: 197), CGPoint(x: 418, y: 307)] {
                curve(cg, CGPoint(x: 268, y: 173), CGPoint(x: 233, y: end.y - 65), CGPoint(x: end.x, y: end.y - 78), end, width: 25)
            }
            line(cg, [(73, 461), (428, 461)], width: 18)
        case "globe":
            oval(cg, 59, 60, 388, 388); oval(cg, 156, 62, 193, 384)
            line(cg, [(65, 254), (442, 254)], width: 16)
            curve(cg, CGPoint(x: 97, y: 151), CGPoint(x: 212, y: 179), CGPoint(x: 304, y: 179), CGPoint(x: 417, y: 151), width: 16)
            curve(cg, CGPoint(x: 97, y: 357), CGPoint(x: 212, y: 329), CGPoint(x: 304, y: 329), CGPoint(x: 417, y: 357), width: 16)
        case "compass":
            oval(cg, 60, 67, 391, 391); oval(cg, 105, 112, 301, 301)
            shape(cg, [(330, 173), (281, 283), (173, 337), (227, 227)]); line(cg, [(230, 228), (279, 281)], width: 15)
            label(cg, "N", CGRect(x: 229, y: 13, width: 55, height: 59))
        case "location":
            let p = UIBezierPath(); p.move(to: CGPoint(x: 255, y: 471)); p.addCurve(to: CGPoint(x: 255, y: 40), controlPoint1: CGPoint(x: -42, y: 166), controlPoint2: CGPoint(x: 123, y: 29)); p.addCurve(to: CGPoint(x: 255, y: 471), controlPoint1: CGPoint(x: 387, y: 29), controlPoint2: CGPoint(x: 551, y: 166)); p.close(); BundledStickerFactory.inkShape(cg, p.cgPath)
            oval(cg, 195, 116, 121, 125); line(cg, [(144, 474), (366, 474)], width: 15)
        case "hiking-boot":
            shape(cg, [(104, 66), (275, 66), (285, 278), (423, 331), (457, 396), (449, 452), (66, 452), (69, 343), (104, 301)])
            line(cg, [(83, 413), (448, 413)], width: 21)
            for y in [161, 207, 252] { line(cg, [(188, CGFloat(y)), (266, CGFloat(y + 16))], width: 14) }
            line(cg, [(98, 130), (153, 130), (146, 284)], width: 14)
        case "binoculars":
            shape(cg, [(103, 81), (184, 81), (233, 394), (60, 394)]); shape(cg, [(327, 81), (409, 81), (451, 394), (278, 394)])
            box(cg, 194, 181, 124, 135, radius: 17); oval(cg, 51, 325, 190, 151); oval(cg, 271, 325, 190, 151)
            oval(cg, 93, 359, 106, 82); oval(cg, 313, 359, 106, 82)
        case "tent":
            shape(cg, [(41, 420), (260, 82), (469, 420)])
            shape(cg, [(103, 418), (259, 154), (410, 418)]); line(cg, [(260, 159), (260, 418)])
            line(cg, [(35, 451), (477, 451)], width: 20); star(cg, 373, 64, 70)
        case "postcard":
            box(cg, 42, 118, 428, 293, radius: 13); line(cg, [(252, 145), (252, 382)], width: 14)
            box(cg, 378, 150, 57, 67, radius: 2)
            for y in [269, 316, 365] { line(cg, [(285, CGFloat(y)), (423, CGFloat(y))], width: 14) }
            shape(cg, [(78, 360), (148, 232), (216, 360)]); oval(cg, 77, 174, 52, 52)
        case "coffee":
            box(cg, 123, 76, 268, 62, radius: 16); shape(cg, [(145, 139), (369, 139), (337, 455), (177, 455)])
            shape(cg, [(155, 239), (359, 239), (348, 346), (167, 346)]); heart(cg, CGRect(x: 210, y: 251, width: 93, height: 80))
        case "open-book":
            shape(cg, [(49, 111), (199, 94), (256, 128), (314, 94), (463, 111), (463, 426), (309, 401), (256, 437), (201, 401), (49, 426)])
            line(cg, [(256, 135), (256, 419)], width: 20)
            for y in [180, 248, 316] { line(cg, [(93, CGFloat(y)), (210, CGFloat(y - 8))], width: 14); line(cg, [(302, CGFloat(y - 8)), (419, CGFloat(y))], width: 14) }
        case "headphones":
            curve(cg, CGPoint(x: 89, y: 332), CGPoint(x: 44, y: 4), CGPoint(x: 467, y: 4), CGPoint(x: 423, y: 332), width: 34)
            box(cg, 64, 258, 109, 203, radius: 43); box(cg, 339, 258, 109, 203, radius: 43)
            line(cg, [(143, 289), (143, 421)], width: 14); line(cg, [(369, 289), (369, 421)], width: 14)
        case "music-notes":
            oval(cg, 67, 346, 117, 92, black: true); oval(cg, 301, 276, 117, 92, black: true)
            line(cg, [(176, 388), (176, 112), (407, 45), (407, 314)], width: 24)
            line(cg, [(183, 163), (400, 99)], width: 24)
        case "pizza":
            shape(cg, [(67, 105), (444, 153), (229, 456)])
            curve(cg, CGPoint(x: 72, y: 105), CGPoint(x: 199, y: 44), CGPoint(x: 354, y: 80), CGPoint(x: 440, y: 154), width: 36)
            oval(cg, 158, 179, 58, 59); oval(cg, 282, 205, 52, 53); oval(cg, 213, 311, 48, 48)
        case "croissant":
            shape(cg, [(42, 355), (102, 202), (163, 158), (259, 116), (360, 157), (420, 211), (470, 358), (371, 321), (317, 301), (202, 301), (134, 326)])
            curve(cg, CGPoint(x: 147, y: 177), CGPoint(x: 178, y: 204), CGPoint(x: 163, y: 276), CGPoint(x: 143, y: 321), width: 16)
            curve(cg, CGPoint(x: 249, y: 124), CGPoint(x: 279, y: 182), CGPoint(x: 266, y: 241), CGPoint(x: 255, y: 291), width: 16)
            curve(cg, CGPoint(x: 360, y: 166), CGPoint(x: 339, y: 229), CGPoint(x: 359, y: 270), CGPoint(x: 377, y: 315), width: 16)
        case "donut":
            oval(cg, 48, 70, 416, 373); oval(cg, 186, 190, 143, 124)
            for p in [(117, 156), (242, 116), (345, 164), (380, 284), (301, 359), (140, 322)] { line(cg, [(CGFloat(p.0), CGFloat(p.1)), (CGFloat(p.0 + 21), CGFloat(p.1 + 21))], width: 16) }
        case "ice-cream":
            shape(cg, [(158, 251), (357, 251), (255, 475)])
            line(cg, [(185, 310), (297, 382)], width: 13); line(cg, [(327, 311), (217, 382)], width: 13)
            oval(cg, 143, 63, 224, 224); box(cg, 125, 236, 261, 68, radius: 30)
        case "tote":
            curve(cg, CGPoint(x: 161, y: 189), CGPoint(x: 144, y: 26), CGPoint(x: 370, y: 26), CGPoint(x: 351, y: 189), width: 22)
            shape(cg, [(104, 169), (408, 169), (436, 464), (75, 464)])
            star(cg, 186, 242, 142); line(cg, [(129, 190), (119, 429)], width: 14)
        case "teacup":
            oval(cg, 352, 217, 112, 147); box(cg, 77, 204, 307, 198, radius: 60)
            oval(cg, 49, 397, 392, 53); line(cg, [(95, 254), (367, 254)], width: 14)
            for x: CGFloat in [170, 246, 322] { curve(cg, CGPoint(x: x, y: 166), CGPoint(x: x - 38, y: 117), CGPoint(x: x + 39, y: 85), CGPoint(x: x, y: 47), width: 14) }
        case "pencil":
            shape(cg, [(98, 379), (353, 48), (412, 92), (160, 425), (59, 473)])
            line(cg, [(99, 379), (160, 425)]); line(cg, [(118, 389), (379, 72)], width: 14)
            shape(cg, [(59, 473), (78, 432), (97, 450)], black: true); line(cg, [(328, 82), (387, 126)], width: 18)
        case "bicycle":
            oval(cg, 37, 279, 169, 169); oval(cg, 306, 279, 169, 169)
            line(cg, [(121, 364), (211, 208), (259, 364), (121, 364), (340, 209), (390, 364), (259, 364)], width: 18)
            line(cg, [(190, 188), (252, 188)], width: 23); line(cg, [(340, 209), (327, 151), (384, 151)], width: 18)
            oval(cg, 244, 350, 27, 28)
        case "umbrella":
            let p = UIBezierPath(); p.move(to: CGPoint(x: 41, y: 269)); p.addCurve(to: CGPoint(x: 471, y: 269), controlPoint1: CGPoint(x: 51, y: 13), controlPoint2: CGPoint(x: 461, y: 13)); p.close(); BundledStickerFactory.inkShape(cg, p.cgPath)
            curve(cg, CGPoint(x: 256, y: 67), CGPoint(x: 168, y: 125), CGPoint(x: 164, y: 215), CGPoint(x: 156, y: 267), width: 14)
            curve(cg, CGPoint(x: 256, y: 67), CGPoint(x: 344, y: 125), CGPoint(x: 348, y: 215), CGPoint(x: 356, y: 267), width: 14)
            line(cg, [(256, 270), (256, 421)], width: 22); curve(cg, CGPoint(x: 256, y: 421), CGPoint(x: 256, y: 486), CGPoint(x: 352, y: 482), CGPoint(x: 352, y: 415), width: 22)
        case "houseplant":
            line(cg, [(254, 370), (254, 67)], width: 22)
            oval(cg, 109, 99, 152, 87); oval(cg, 260, 185, 153, 91); oval(cg, 117, 254, 139, 79)
            shape(cg, [(144, 363), (372, 363), (335, 461), (181, 461)])
            line(cg, [(154, 390), (359, 390)], width: 14)
        case "memory-stamp":
            oval(cg, 51, 51, 410, 410); oval(cg, 94, 94, 325, 325)
            label(cg, "KEEP", CGRect(x: 137, y: 132, width: 238, height: 94)); label(cg, "2024", CGRect(x: 170, y: 287, width: 172, height: 80))
            heart(cg, CGRect(x: 217, y: 229, width: 78, height: 72))
        case "keepsake-ticket":
            box(cg, 56, 104, 400, 307, radius: 25)
            line(cg, [(151, 119), (151, 392)], width: 14); heart(cg, CGRect(x: 78, y: 220, width: 59, height: 71))
            label(cg, "KEEP", CGRect(x: 186, y: 157, width: 227, height: 107)); label(cg, "THIS", CGRect(x: 203, y: 285, width: 194, height: 72))
        case "photo-album":
            box(cg, 81, 42, 354, 429, radius: 15); line(cg, [(139, 57), (139, 459)], width: 19)
            box(cg, 188, 115, 191, 237, radius: 5); shape(cg, [(211, 312), (252, 223), (305, 312), (339, 267), (356, 312)])
            oval(cg, 307, 156, 29, 29); line(cg, [(207, 406), (357, 406)], width: 14)
        case "memory-jar":
            box(cg, 141, 51, 231, 64, radius: 16); box(cg, 109, 113, 295, 354, radius: 48)
            heart(cg, CGRect(x: 141, y: 261, width: 103, height: 110)); star(cg, 251, 158, 101)
            box(cg, 236, 335, 120, 70, radius: 8); line(cg, [(260, 360), (331, 360)], width: 12)
        case "memory-box":
            shape(cg, [(76, 177), (271, 89), (440, 172), (440, 392), (244, 463), (76, 384)])
            line(cg, [(81, 183), (245, 254), (434, 179)]); line(cg, [(245, 255), (245, 450)])
            heart(cg, CGRect(x: 125, y: 261, width: 83, height: 102)); box(cg, 285, 294, 104, 50, radius: 8)
        case "pressed-flower":
            line(cg, [(253, 211), (253, 460)], width: 20)
            for i in 0..<5 { let a = CGFloat(i) * .pi * 2 / 5; oval(cg, 212 + cos(a) * 82, 141 + sin(a) * 80, 81, 83) }
            oval(cg, 226, 155, 58, 58); shape(cg, [(250, 355), (142, 290), (159, 362), (251, 393)])
            shape(cg, [(263, 331), (369, 273), (358, 345), (262, 366)])
        default:
            assertionFailure("Missing curated artwork: \(id)")
        }
    }
}
