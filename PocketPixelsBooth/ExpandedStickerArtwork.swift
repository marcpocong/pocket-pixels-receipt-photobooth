import CoreGraphics
import UIKit

/// Fifty further original line drawings (stickers 151–200). Same construction rules as
/// `CuratedStickerArtwork`: heavy black outlines, solid black or white fills, transparent
/// surroundings and outlined system capitals for words — never emoji or third-party artwork.
/// IDs are permanent: saved placements and audits refer to them.
nonisolated enum ExpandedStickerArtwork {
    private typealias C = CuratedStickerArtwork
    private typealias F = BundledStickerFactory

    private struct Art: Sendable {
        let id: String
        let name: String
        let category: StickerCategory
        let tags: [String]
        var aspectRatio: CGFloat = 1
        /// Square artwork is drawn in 512-point canonical coordinates; wide artwork in its own size.
        let draw: @Sendable (CGContext, CGSize) -> Void
    }

    static let definitions: [BundledStickerFactory.Definition] = artwork.map { art in
        .init(id: "builtin.\(art.id)", name: art.name, category: art.category,
              tags: [art.name.lowercased(), art.category.displayName.lowercased()] + art.tags,
              aspectRatio: art.aspectRatio) { cg, size in
            cg.saveGState()
            if art.aspectRatio == 1 { cg.scaleBy(x: size.width / 512, y: size.height / 512) }
            art.draw(cg, art.aspectRatio == 1 ? CGSize(width: 512, height: 512) : size)
            cg.restoreGState()
        }
    }

    // MARK: Helpers

    private static func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

    private static func blackBox(_ cg: CGContext, _ rect: CGRect, radius: CGFloat = 8) {
        F.inkShape(cg, UIBezierPath(roundedRect: rect, cornerRadius: radius).cgPath, fill: .black)
    }

    /// Fills several overlapping shapes as one silhouette: a doubled black stroke under a white
    /// fill leaves only the outer outline, so no internal seams print.
    private static func silhouette(_ cg: CGContext, _ paths: [CGPath]) {
        cg.setStrokeColor(UIColor.black.cgColor)
        cg.setLineWidth(F.strokeWidth * 2)
        for path in paths { cg.addPath(path); cg.strokePath() }
        cg.setFillColor(UIColor.white.cgColor)
        for path in paths { cg.addPath(path); cg.fillPath() }
    }

    private static func ellipse(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGPath {
        CGPath(ellipseIn: CGRect(x: x, y: y, width: w, height: h), transform: nil)
    }

    private static func rays(_ cg: CGContext, center: CGPoint, inner: CGFloat, outer: CGFloat, count: Int, width: CGFloat, offset: CGFloat = 0) {
        for index in 0..<count {
            let angle = CGFloat(index) * 2 * .pi / CGFloat(count) + offset
            C.line(cg, [(center.x + cos(angle) * inner, center.y + sin(angle) * inner),
                        (center.x + cos(angle) * outer, center.y + sin(angle) * outer)], width: width)
        }
    }

    private static func labelLines(_ cg: CGContext, _ text: String, in rect: CGRect, inverted: Bool = false) {
        let lines = text.components(separatedBy: "\n")
        let height = rect.height / CGFloat(lines.count)
        for (index, line) in lines.enumerated() {
            F.drawLabel(cg, line, in: CGRect(x: rect.minX, y: rect.minY + CGFloat(index) * height, width: rect.width, height: height), inverted: inverted)
        }
    }

    // MARK: Artwork

    private static let artwork: [Art] = cute + hearts + doodles + reactions + birthday + celebration + retro + travel + everyday + madeToKeep

    private static let cute: [Art] = [
        Art(id: "penguin", name: "Waddle Penguin", category: .cute, tags: ["penguin", "animal", "bird", "winter"]) { cg, _ in
            C.shape(cg, [(150, 230), (88, 340), (156, 312)], black: true)
            C.shape(cg, [(362, 230), (424, 340), (356, 312)], black: true)
            C.oval(cg, 186, 420, 66, 38); C.oval(cg, 260, 420, 66, 38)
            C.oval(cg, 136, 70, 240, 380, black: true)
            C.oval(cg, 182, 190, 148, 240)
            C.oval(cg, 190, 128, 50, 54); C.oval(cg, 272, 128, 50, 54)
            C.oval(cg, 206, 144, 20, 24, black: true); C.oval(cg, 288, 144, 20, 24, black: true)
            C.shape(cg, [(232, 196), (280, 196), (256, 232)])
        },
        Art(id: "fox", name: "Little Fox", category: .cute, tags: ["fox", "animal", "woodland", "forest"]) { cg, _ in
            C.shape(cg, [(84, 70), (196, 170), (316, 170), (428, 70), (412, 270), (256, 440), (100, 270)])
            C.shape(cg, [(112, 120), (170, 176), (124, 214)], black: true)
            C.shape(cg, [(400, 120), (342, 176), (388, 214)], black: true)
            C.shape(cg, [(150, 300), (256, 250), (362, 300), (256, 440)])
            C.oval(cg, 186, 236, 24, 34, black: true); C.oval(cg, 302, 236, 24, 34, black: true)
            C.oval(cg, 234, 392, 44, 32, black: true)
        },
        Art(id: "owl", name: "Night Owl", category: .cute, tags: ["owl", "bird", "night", "wise", "animal"]) { cg, _ in
            C.line(cg, [(70, 462), (442, 462)], width: 24)
            C.shape(cg, [(140, 160), (146, 58), (220, 128)]); C.shape(cg, [(372, 160), (366, 58), (292, 128)])
            C.oval(cg, 116, 100, 280, 356)
            C.oval(cg, 152, 160, 100, 100); C.oval(cg, 260, 160, 100, 100)
            C.oval(cg, 184, 192, 38, 38, black: true); C.oval(cg, 292, 192, 38, 38, black: true)
            C.shape(cg, [(236, 268), (276, 268), (256, 304)], black: true)
            for (x, y) in [(196, 340), (276, 340), (236, 384)] as [(CGFloat, CGFloat)] {
                C.line(cg, [(x, y), (x + 20, y + 22), (x + 40, y)], width: 14)
            }
        },
        Art(id: "hedgehog", name: "Hedgehog Hug", category: .cute, tags: ["hedgehog", "animal", "spiky", "woodland"]) { cg, _ in
            let spikes = CGMutablePath()
            let center = p(290, 360)
            for index in 0...22 {
                let angle = CGFloat.pi + CGFloat(index) * .pi / 22
                let radius: CGFloat = index.isMultiple(of: 2) ? 210 : 160
                let point = p(center.x + cos(angle) * radius, center.y + sin(angle) * radius * 0.9)
                index == 0 ? spikes.move(to: point) : spikes.addLine(to: point)
            }
            spikes.closeSubpath()
            F.inkShape(cg, spikes, fill: .black)
            C.oval(cg, 186, 380, 50, 40); C.oval(cg, 330, 380, 50, 40)
            C.shape(cg, [(250, 230), (60, 330), (250, 400)])
            C.oval(cg, 44, 312, 40, 34, black: true)
            C.oval(cg, 150, 290, 22, 26, black: true)
        },
        Art(id: "chick", name: "Baby Chick", category: .cute, tags: ["chick", "bird", "egg", "spring", "baby"]) { cg, _ in
            C.line(cg, [(246, 128), (230, 84)], width: 16); C.line(cg, [(266, 128), (284, 86)], width: 16)
            C.oval(cg, 126, 120, 260, 260)
            C.oval(cg, 196, 196, 24, 30, black: true); C.oval(cg, 292, 196, 24, 30, black: true)
            C.shape(cg, [(232, 240), (280, 240), (256, 270)], black: true)
            C.shape(cg, [(104, 300), (150, 268), (192, 312), (234, 268), (278, 312), (320, 268), (362, 312), (408, 280), (392, 452), (120, 452)])
        },
        Art(id: "panda", name: "Panda Pal", category: .cute, tags: ["panda", "bear", "animal", "bamboo"]) { cg, _ in
            C.oval(cg, 80, 70, 116, 116, black: true); C.oval(cg, 316, 70, 116, 116, black: true)
            C.oval(cg, 86, 110, 340, 310)
            F.inkShape(cg, UIBezierPath(ovalIn: CGRect(x: 150, y: 200, width: 82, height: 104)).cgPath, fill: .black)
            F.inkShape(cg, UIBezierPath(ovalIn: CGRect(x: 280, y: 200, width: 82, height: 104)).cgPath, fill: .black)
            C.oval(cg, 182, 232, 28, 30); C.oval(cg, 302, 232, 28, 30)
            C.oval(cg, 232, 318, 48, 32, black: true)
            C.curve(cg, p(222, 368), p(236, 392), p(276, 392), p(290, 368), width: 12)
        },
        Art(id: "octopus", name: "Octo Wave", category: .cute, tags: ["octopus", "sea", "ocean", "animal"]) { cg, _ in
            for (index, x) in ([150, 206, 256, 306, 362] as [CGFloat]).enumerated() {
                let swing: CGFloat = index.isMultiple(of: 2) ? -40 : 40
                C.curve(cg, p(x, 250), p(x + swing, 330), p(x - swing, 400), p(x + swing * 0.6, 462), width: 30)
            }
            C.oval(cg, 126, 50, 260, 250)
            C.face(cg, 150)
            C.oval(cg, 150, 196, 36, 22); C.oval(cg, 326, 196, 36, 22)
        }
    ]

    private static let hearts: [Art] = [
        Art(id: "heart-balloon", name: "Heart Balloon", category: .hearts, tags: ["heart", "balloon", "love", "float"]) { cg, _ in
            C.curve(cg, p(256, 296), p(206, 360), p(312, 400), p(248, 470), width: 12)
            C.shape(cg, [(238, 300), (274, 300), (256, 280)], black: true)
            C.heart(cg, CGRect(x: 116, y: 36, width: 280, height: 256))
            C.curve(cg, p(170, 110), p(166, 90), p(186, 74), p(206, 72), width: 14)
        },
        Art(id: "love-bug", name: "Love Bug", category: .hearts, tags: ["ladybug", "bug", "heart", "love", "cute"]) { cg, _ in
            C.curve(cg, p(230, 110), p(220, 70), p(190, 50), p(170, 56), width: 12)
            C.curve(cg, p(282, 110), p(292, 70), p(322, 50), p(342, 56), width: 12)
            C.oval(cg, 196, 88, 120, 96, black: true)
            C.oval(cg, 112, 150, 288, 310)
            C.line(cg, [(256, 156), (256, 452)], width: 14)
            C.heart(cg, CGRect(x: 162, y: 214, width: 66, height: 60), black: true)
            C.heart(cg, CGRect(x: 284, y: 214, width: 66, height: 60), black: true)
            C.heart(cg, CGRect(x: 172, y: 330, width: 56, height: 52), black: true)
            C.heart(cg, CGRect(x: 284, y: 330, width: 56, height: 52), black: true)
        },
        Art(id: "heart-eyes", name: "Heart Eyes", category: .hearts, tags: ["heart eyes", "face", "crush", "love", "smile"]) { cg, _ in
            C.oval(cg, 50, 50, 412, 412)
            C.heart(cg, CGRect(x: 126, y: 150, width: 104, height: 96), black: true)
            C.heart(cg, CGRect(x: 282, y: 150, width: 104, height: 96), black: true)
            let mouth = CGMutablePath()
            mouth.move(to: p(160, 300))
            mouth.addCurve(to: p(352, 300), control1: p(196, 410), control2: p(316, 410))
            mouth.closeSubpath()
            F.inkShape(cg, mouth, fill: .black)
        },
        Art(id: "sticky-love-note", name: "Sticky Love Note", category: .hearts, tags: ["note", "sticky note", "heart", "love", "message"]) { cg, _ in
            C.shape(cg, [(86, 104), (420, 84), (432, 418), (98, 438)])
            C.shape(cg, [(192, 64), (322, 56), (326, 112), (196, 120)])
            C.heart(cg, CGRect(x: 170, y: 176, width: 172, height: 160))
            C.line(cg, [(150, 382), (364, 372)], width: 12)
        },
        Art(id: "heart-garland", name: "Heart Garland", category: .hearts, tags: ["garland", "hearts", "bunting", "love", "party"]) { cg, _ in
            C.curve(cg, p(30, 110), p(170, 270), p(342, 270), p(482, 110), width: 12)
            C.heart(cg, CGRect(x: 52, y: 160, width: 88, height: 84))
            C.heart(cg, CGRect(x: 152, y: 214, width: 96, height: 90), black: true)
            C.heart(cg, CGRect(x: 264, y: 214, width: 96, height: 90))
            C.heart(cg, CGRect(x: 372, y: 160, width: 88, height: 84), black: true)
        }
    ]

    private static let doodles: [Art] = [
        Art(id: "spiral", name: "Hand Spiral", category: .doodles, tags: ["spiral", "swirl", "hypnotic", "doodle"]) { cg, _ in
            var points: [(CGFloat, CGFloat)] = []
            for step in 0...260 {
                let t = CGFloat(step) / 260
                let angle = t * 3.3 * 2 * .pi
                let radius = 14 + t * 196
                points.append((256 + cos(angle) * radius, 256 + sin(angle) * radius))
            }
            C.line(cg, points, width: 22)
        },
        Art(id: "circle-it", name: "Circle It", category: .doodles, tags: ["circle", "highlight", "scribble", "doodle", "this"]) { cg, _ in
            // One hand-drawn pass and a second, looser pass that overshoots like a marker loop.
            let loop = CGMutablePath()
            loop.move(to: p(330, 120))
            loop.addCurve(to: p(56, 270), control1: p(180, 96), control2: p(56, 160))
            loop.addCurve(to: p(270, 410), control1: p(56, 370), control2: p(170, 412))
            loop.addCurve(to: p(456, 250), control1: p(380, 408), control2: p(456, 350))
            loop.addCurve(to: p(196, 108), control1: p(456, 150), control2: p(330, 92))
            loop.addCurve(to: p(110, 150), control1: p(160, 112), control2: p(130, 128))
            F.strokeInk(cg, loop, width: 20)
            C.line(cg, [(392, 112), (430, 66)], width: 16); C.line(cg, [(424, 150), (476, 128)], width: 16)
        },
        Art(id: "zigzag", name: "Zigzag", category: .doodles, tags: ["zigzag", "line", "underline", "doodle", "energy"]) { cg, _ in
            C.line(cg, [(36, 300), (106, 196), (176, 300), (246, 196), (316, 300), (386, 196), (476, 300)], width: 30)
            C.line(cg, [(96, 380), (146, 340), (196, 380), (246, 340), (296, 380), (346, 340), (416, 380)], width: 14)
        },
        Art(id: "exclamation", name: "Big Exclamation", category: .doodles, tags: ["exclamation", "wow", "alert", "doodle"]) { cg, _ in
            C.shape(cg, [(204, 46), (308, 46), (284, 326), (228, 326)], black: true)
            C.oval(cg, 214, 366, 84, 84, black: true)
            C.line(cg, [(136, 110), (176, 156)], width: 18); C.line(cg, [(376, 110), (336, 156)], width: 18)
            C.line(cg, [(108, 238), (164, 238)], width: 18); C.line(cg, [(404, 238), (348, 238)], width: 18)
        },
        Art(id: "dotted-arrow", name: "Dotted Arrow", category: .doodles, tags: ["arrow", "dotted", "path", "this way", "doodle"]) { cg, _ in
            func point(_ t: CGFloat) -> CGPoint {
                let a = p(60, 440), b = p(80, 140), c = p(330, 380), d = p(420, 110)
                let u = 1 - t
                return p(u * u * u * a.x + 3 * u * u * t * b.x + 3 * u * t * t * c.x + t * t * t * d.x,
                         u * u * u * a.y + 3 * u * u * t * b.y + 3 * u * t * t * c.y + t * t * t * d.y)
            }
            for index in 0..<9 {
                let start = CGFloat(index) / 10, end = start + 0.05
                C.line(cg, [(point(start).x, point(start).y), (point(end).x, point(end).y)], width: 20)
            }
            C.shape(cg, [(456, 64), (444, 196), (330, 120)], black: true)
        },
        Art(id: "asterisk", name: "Asterisk Bloom", category: .doodles, tags: ["asterisk", "star", "bloom", "doodle", "accent"]) { cg, _ in
            for index in 0..<4 {
                let angle = CGFloat(index) * .pi / 4
                C.line(cg, [(256 - cos(angle) * 196, 256 - sin(angle) * 196), (256 + cos(angle) * 196, 256 + sin(angle) * 196)], width: 52)
            }
            C.oval(cg, 218, 218, 76, 76)
        }
    ]

    private static let reactions: [Art] = [
        Art(id: "haha-cloud", name: "HAHA", category: .reactions, tags: ["haha", "laugh", "funny", "lol", "cloud"], aspectRatio: 1.5) { cg, size in
            let w = size.width, h = size.height
            silhouette(cg, [
                ellipse(w * 0.06, h * 0.3, w * 0.34, h * 0.46), ellipse(w * 0.22, h * 0.1, w * 0.32, h * 0.46),
                ellipse(w * 0.46, h * 0.1, w * 0.32, h * 0.44), ellipse(w * 0.6, h * 0.3, w * 0.34, h * 0.46),
                ellipse(w * 0.2, h * 0.42, w * 0.6, h * 0.4)
            ])
            C.oval(cg, w * 0.12, h * 0.84, w * 0.07, h * 0.08)
            labelLines(cg, "HAHA", in: CGRect(x: w * 0.18, y: h * 0.3, width: w * 0.64, height: h * 0.34))
        },
        Art(id: "yes-stamp", name: "YES!", category: .reactions, tags: ["yes", "approved", "stamp", "agree"], aspectRatio: 1.5) { cg, size in
            let w = size.width, h = size.height
            cg.saveGState()
            cg.translateBy(x: w / 2, y: h / 2); cg.rotate(by: -0.12); cg.translateBy(x: -w / 2, y: -h / 2)
            C.box(cg, w * 0.08, h * 0.18, w * 0.84, h * 0.64, radius: 18)
            F.strokeInk(cg, UIBezierPath(roundedRect: CGRect(x: w * 0.13, y: h * 0.26, width: w * 0.74, height: h * 0.48), cornerRadius: 10).cgPath, width: 10)
            labelLines(cg, "YES!", in: CGRect(x: w * 0.18, y: h * 0.3, width: w * 0.64, height: h * 0.4))
            cg.restoreGState()
        },
        Art(id: "no-way", name: "NO WAY", category: .reactions, tags: ["no way", "shock", "unbelievable", "omg", "sign"]) { cg, _ in
            let octagon = (0..<8).map { index -> (CGFloat, CGFloat) in
                let angle = CGFloat(index) * .pi / 4 + .pi / 8
                return (256 + cos(angle) * 220, 256 + sin(angle) * 220)
            }
            C.shape(cg, octagon, black: true)
            labelLines(cg, "NO\nWAY", in: CGRect(x: 110, y: 130, width: 292, height: 252), inverted: true)
        },
        Art(id: "so-fun-pennant", name: "So Fun", category: .reactions, tags: ["so fun", "pennant", "flag", "fun", "party"], aspectRatio: 1.6) { cg, size in
            let w = size.width, h = size.height
            C.line(cg, [(w * 0.07, h * 0.08), (w * 0.07, h * 0.94)], width: 22)
            C.shape(cg, [(w * 0.09, h * 0.12), (w * 0.96, h * 0.4), (w * 0.09, h * 0.68)])
            F.drawLabel(cg, "SO FUN", in: CGRect(x: w * 0.13, y: h * 0.25, width: w * 0.56, height: h * 0.3))
        },
        Art(id: "cutie-heart", name: "Cutie", category: .reactions, tags: ["cutie", "cute", "heart", "adorable"], aspectRatio: 1.2) { cg, size in
            let w = size.width, h = size.height
            C.heart(cg, CGRect(x: w * 0.05, y: h * 0.08, width: w * 0.9, height: h * 0.84))
            F.drawLabel(cg, "CUTIE", in: CGRect(x: w * 0.22, y: h * 0.32, width: w * 0.56, height: h * 0.22))
        },
        Art(id: "main-character", name: "Main Character", category: .reactions, tags: ["main character", "star", "film", "iconic", "meme"], aspectRatio: 2) { cg, size in
            let w = size.width, h = size.height
            C.box(cg, w * 0.03, h * 0.05, w * 0.94, h * 0.9, radius: 8)
            for index in 0..<11 {
                let x = w * 0.065 + CGFloat(index) * w * 0.084
                blackBox(cg, CGRect(x: x, y: h * 0.11, width: w * 0.036, height: h * 0.06), radius: 3)
                blackBox(cg, CGRect(x: x, y: h * 0.83, width: w * 0.036, height: h * 0.06), radius: 3)
            }
            labelLines(cg, "MAIN\nCHARACTER", in: CGRect(x: w * 0.08, y: h * 0.21, width: w * 0.84, height: h * 0.58))
        }
    ]

    private static let birthday: [Art] = [
        Art(id: "lollipop", name: "Swirl Lollipop", category: .birthday, tags: ["lollipop", "candy", "sweet", "treat"]) { cg, _ in
            C.box(cg, 240, 270, 32, 210, radius: 12)
            C.oval(cg, 126, 30, 260, 260)
            var points: [(CGFloat, CGFloat)] = []
            for step in 0...120 {
                let t = CGFloat(step) / 120
                let angle = t * 2.6 * 2 * .pi
                points.append((256 + cos(angle) * (10 + t * 100), 160 + sin(angle) * (10 + t * 100)))
            }
            C.line(cg, points, width: 18)
        },
        Art(id: "wrapped-candy", name: "Wrapped Candy", category: .birthday, tags: ["candy", "sweet", "treat", "wrapper"]) { cg, _ in
            C.shape(cg, [(170, 256), (52, 160), (86, 256), (52, 352)])
            C.shape(cg, [(342, 256), (460, 160), (426, 256), (460, 352)])
            C.oval(cg, 150, 176, 212, 160)
            for x in [204, 256, 308] as [CGFloat] {
                C.line(cg, [(x - 20, 196), (x + 20, 316)], width: 20)
            }
        },
        Art(id: "birthday-card", name: "Birthday Card", category: .birthday, tags: ["card", "birthday", "hbd", "greeting"]) { cg, _ in
            C.shape(cg, [(70, 120), (256, 80), (256, 440), (70, 470)])
            C.shape(cg, [(256, 80), (446, 124), (446, 474), (256, 440)])
            C.heart(cg, CGRect(x: 118, y: 230, width: 92, height: 86), black: true)
            C.star(cg, 306, 140, 92)
            F.drawLabel(cg, "HBD", in: CGRect(x: 280, y: 270, width: 140, height: 90))
        },
        Art(id: "cake-pop", name: "Cake Pop", category: .birthday, tags: ["cake pop", "dessert", "sweet", "party"]) { cg, _ in
            C.box(cg, 240, 270, 32, 200, radius: 10)
            C.shape(cg, [(256, 320), (196, 290), (196, 350)], black: true)
            C.shape(cg, [(256, 320), (316, 290), (316, 350)], black: true)
            C.oval(cg, 146, 60, 220, 220)
            let drip = CGMutablePath()
            drip.move(to: p(152, 150))
            drip.addCurve(to: p(360, 150), control1: p(180, 40), control2: p(332, 40))
            drip.addLine(to: p(340, 196)); drip.addQuadCurve(to: p(310, 196), control: p(325, 230))
            drip.addLine(to: p(270, 176)); drip.addQuadCurve(to: p(226, 190), control: p(248, 236))
            drip.addLine(to: p(190, 170)); drip.addQuadCurve(to: p(152, 150), control: p(160, 200))
            drip.closeSubpath()
            F.inkShape(cg, drip, fill: .black)
            for (x, y) in [(200, 236), (250, 252), (304, 232)] as [(CGFloat, CGFloat)] {
                C.line(cg, [(x, y), (x + 14, y + 12)], width: 12)
            }
        }
    ]

    private static let celebration: [Art] = [
        Art(id: "fireworks", name: "Fireworks", category: .celebration, tags: ["fireworks", "new year", "celebrate", "night"]) { cg, _ in
            rays(cg, center: p(200, 200), inner: 44, outer: 168, count: 12, width: 18)
            for index in 0..<12 {
                let angle = CGFloat(index) * .pi / 6
                C.oval(cg, 200 + cos(angle) * 186 - 9, 200 + sin(angle) * 186 - 9, 18, 18, black: true)
            }
            rays(cg, center: p(378, 356), inner: 24, outer: 96, count: 8, width: 14, offset: .pi / 8)
            C.oval(cg, 186, 186, 28, 28, black: true)
            F.inkShape(cg, F.sparklePath(center: p(110, 420), radius: 46), fill: .black)
        },
        Art(id: "wedding-rings", name: "Wedding Rings", category: .celebration, tags: ["rings", "wedding", "engaged", "married", "love"]) { cg, _ in
            F.strokeInk(cg, ellipse(70, 180, 240, 240), width: 30)
            F.strokeInk(cg, ellipse(202, 180, 240, 240), width: 30)
            C.shape(cg, [(190, 70), (250, 112), (190, 172), (130, 112)])
            C.line(cg, [(130, 112), (250, 112)], width: 10); C.line(cg, [(166, 112), (190, 172), (214, 112)], width: 10)
        },
        Art(id: "bouquet", name: "Flower Bouquet", category: .celebration, tags: ["bouquet", "flowers", "wedding", "bride", "thank you"]) { cg, _ in
            for (x, y) in [(150, 170), (256, 120), (362, 170)] as [(CGFloat, CGFloat)] {
                C.line(cg, [(256, 420), (x, y)], width: 16)
            }
            for (x, y) in [(150, 170), (256, 120), (362, 170)] as [(CGFloat, CGFloat)] {
                for index in 0..<5 {
                    let angle = CGFloat(index) * 2 * .pi / 5
                    C.oval(cg, x + cos(angle) * 36 - 30, y + sin(angle) * 36 - 30, 60, 60)
                }
                C.oval(cg, x - 22, y - 22, 44, 44, black: true)
            }
            C.shape(cg, [(170, 300), (342, 300), (282, 474), (230, 474)])
            C.shape(cg, [(256, 330), (196, 300), (196, 362)], black: true)
            C.shape(cg, [(256, 330), (316, 300), (316, 362)], black: true)
        },
        Art(id: "wedding-cake", name: "Tiered Wedding Cake", category: .celebration, tags: ["wedding cake", "cake", "wedding", "anniversary"]) { cg, _ in
            C.box(cg, 76, 344, 360, 116, radius: 14)
            C.box(cg, 122, 246, 268, 104, radius: 12)
            C.box(cg, 168, 160, 176, 92, radius: 10)
            for (y, from, to) in [(390, 96, 416), (290, 142, 370), (200, 186, 326)] as [(CGFloat, CGFloat, CGFloat)] {
                for x in stride(from: from, through: to, by: 40) { C.oval(cg, x, y, 16, 16, black: true) }
            }
            C.heart(cg, CGRect(x: 212, y: 62, width: 88, height: 84), black: true)
        },
        Art(id: "magic-wand", name: "Magic Wand", category: .celebration, tags: ["wand", "magic", "wish", "sparkle", "fairy"]) { cg, _ in
            C.line(cg, [(84, 456), (282, 220)], width: 34)
            C.star(cg, 236, 40, 220)
            F.inkShape(cg, F.sparklePath(center: p(120, 150), radius: 50), fill: .black)
            F.inkShape(cg, F.sparklePath(center: p(430, 340), radius: 40))
            C.oval(cg, 404, 254, 22, 22, black: true)
        }
    ]

    private static let retro: [Art] = [
        Art(id: "clapperboard", name: "Clapperboard", category: .retro, tags: ["clapperboard", "film", "movie", "action", "take"]) { cg, _ in
            C.box(cg, 60, 196, 392, 260, radius: 10)
            C.shape(cg, [(60, 112), (440, 62), (452, 140), (72, 190)])
            for index in 0..<4 {
                let x = 100 + CGFloat(index) * 92
                C.shape(cg, [(x, 108 - CGFloat(index) * 12), (x + 46, 102 - CGFloat(index) * 12), (x + 30, 176 - CGFloat(index) * 12), (x - 16, 182 - CGFloat(index) * 12)], black: true)
            }
            C.line(cg, [(60, 290), (452, 290)], width: 12)
            F.drawLabel(cg, "TAKE 1", in: CGRect(x: 104, y: 318, width: 304, height: 104))
        },
        Art(id: "film-reel", name: "Film Reel", category: .retro, tags: ["film reel", "movie", "cinema", "vintage"]) { cg, _ in
            C.oval(cg, 50, 50, 412, 412)
            for index in 0..<5 {
                let angle = CGFloat(index) * 2 * .pi / 5 - .pi / 2
                C.oval(cg, 256 + cos(angle) * 120 - 50, 256 + sin(angle) * 120 - 50, 100, 100)
            }
            C.oval(cg, 222, 222, 68, 68, black: true)
            C.curve(cg, p(440, 330), p(470, 400), p(480, 440), p(500, 470), width: 20)
        },
        Art(id: "flash-bulb", name: "Vintage Flash Bulb", category: .retro, tags: ["flash", "bulb", "camera", "vintage", "light"]) { cg, _ in
            rays(cg, center: p(256, 176), inner: 150, outer: 214, count: 9, width: 16, offset: -.pi / 2)
            C.box(cg, 204, 300, 104, 70, radius: 6)
            C.box(cg, 214, 364, 84, 60, radius: 6)
            C.line(cg, [(214, 386), (298, 386)], width: 12); C.line(cg, [(214, 406), (298, 406)], width: 12)
            C.oval(cg, 236, 420, 40, 36, black: true)
            C.oval(cg, 136, 56, 240, 250)
            C.line(cg, [(220, 290), (220, 200), (244, 160), (268, 200), (292, 160), (292, 290)], width: 12)
        },
        Art(id: "boombox", name: "Boombox", category: .retro, tags: ["boombox", "music", "stereo", "80s", "party"], aspectRatio: 1.5) { cg, size in
            let w = size.width, h = size.height
            C.line(cg, [(w * 0.24, h * 0.3), (w * 0.24, h * 0.12), (w * 0.76, h * 0.12), (w * 0.76, h * 0.3)], width: 24)
            C.box(cg, w * 0.04, h * 0.28, w * 0.92, h * 0.62, radius: 22)
            for x in [w * 0.1, w * 0.62] {
                C.oval(cg, x, h * 0.42, w * 0.28, w * 0.28)
                C.oval(cg, x + w * 0.07, h * 0.42 + w * 0.07, w * 0.14, w * 0.14, black: true)
            }
            C.box(cg, w * 0.41, h * 0.42, w * 0.18, h * 0.18, radius: 6)
            for index in 0..<3 { blackBox(cg, CGRect(x: w * 0.42 + CGFloat(index) * w * 0.06, y: h * 0.7, width: w * 0.04, height: h * 0.07), radius: 3) }
        },
        Art(id: "roller-skate", name: "Roller Skate", category: .retro, tags: ["roller skate", "skate", "disco", "70s", "retro"]) { cg, _ in
            C.oval(cg, 120, 360, 96, 96, black: true); C.oval(cg, 320, 360, 96, 96, black: true)
            C.oval(cg, 152, 392, 32, 32); C.oval(cg, 352, 392, 32, 32)
            C.oval(cg, 420, 330, 52, 50, black: true)
            C.shape(cg, [(130, 56), (262, 56), (272, 236), (420, 284), (436, 372), (112, 372)])
            C.line(cg, [(112, 330), (436, 330)], width: 14)
            for y in [104, 150, 196] as [CGFloat] { C.line(cg, [(180, y), (240, y + 26)], width: 12); C.line(cg, [(240, y), (180, y + 26)], width: 12) }
        }
    ]

    private static let travel: [Art] = [
        Art(id: "hot-air-balloon", name: "Hot Air Balloon", category: .travel, tags: ["hot air balloon", "balloon", "sky", "adventure", "travel"]) { cg, _ in
            C.line(cg, [(214, 336), (222, 404)], width: 12); C.line(cg, [(298, 336), (290, 404)], width: 12)
            C.box(cg, 210, 396, 92, 74, radius: 8)
            let envelope = CGMutablePath()
            envelope.move(to: p(212, 344))
            envelope.addCurve(to: p(256, 34), control1: p(80, 260), control2: p(90, 34))
            envelope.addCurve(to: p(300, 344), control1: p(422, 34), control2: p(432, 260))
            envelope.closeSubpath()
            F.inkShape(cg, envelope)
            let stripe = CGMutablePath()
            stripe.move(to: p(256, 42))
            stripe.addCurve(to: p(240, 342), control1: p(196, 120), control2: p(196, 270))
            stripe.addLine(to: p(272, 342))
            stripe.addCurve(to: p(256, 42), control1: p(316, 270), control2: p(316, 120))
            F.inkShape(cg, stripe, fill: .black)
        },
        Art(id: "camper-van", name: "Camper Van", category: .travel, tags: ["van", "camper", "road trip", "adventure", "travel"], aspectRatio: 1.4) { cg, size in
            let w = size.width, h = size.height
            C.box(cg, w * 0.04, h * 0.22, w * 0.92, h * 0.52, radius: 50)
            C.line(cg, [(w * 0.04, h * 0.56), (w * 0.96, h * 0.56)], width: 14)
            C.box(cg, w * 0.12, h * 0.3, w * 0.2, h * 0.18, radius: 10)
            C.box(cg, w * 0.38, h * 0.3, w * 0.2, h * 0.18, radius: 10)
            C.shape(cg, [(w * 0.66, h * 0.3), (w * 0.84, h * 0.3), (w * 0.92, h * 0.48), (w * 0.66, h * 0.48)])
            for x in [w * 0.14, w * 0.66] {
                C.oval(cg, x, h * 0.62, w * 0.18, w * 0.18, black: true)
                C.oval(cg, x + w * 0.06, h * 0.62 + w * 0.06, w * 0.06, w * 0.06)
            }
        },
        Art(id: "sailboat", name: "Sailboat", category: .travel, tags: ["sailboat", "boat", "sea", "ocean", "summer"]) { cg, _ in
            C.line(cg, [(256, 50), (256, 372)], width: 16)
            C.shape(cg, [(272, 60), (272, 336), (430, 336)])
            C.shape(cg, [(240, 104), (240, 336), (112, 336)], black: true)
            C.shape(cg, [(70, 360), (442, 360), (386, 436), (126, 436)])
            C.curve(cg, p(40, 470), p(110, 440), p(160, 500), p(240, 470), width: 14)
            C.curve(cg, p(272, 470), p(342, 440), p(392, 500), p(472, 470), width: 14)
        },
        Art(id: "lighthouse", name: "Lighthouse", category: .travel, tags: ["lighthouse", "coast", "sea", "beacon", "travel"]) { cg, _ in
            C.line(cg, [(160, 130), (60, 100)], width: 16); C.line(cg, [(160, 150), (60, 180)], width: 16)
            C.line(cg, [(352, 130), (452, 100)], width: 16); C.line(cg, [(352, 150), (452, 180)], width: 16)
            C.shape(cg, [(196, 190), (316, 190), (350, 466), (162, 466)])
            C.shape(cg, [(186, 270), (326, 270), (333, 326), (179, 326)], black: true)
            C.shape(cg, [(172, 382), (340, 382), (347, 438), (165, 438)], black: true)
            C.box(cg, 200, 104, 112, 88, radius: 6)
            C.line(cg, [(236, 112), (236, 186)], width: 10); C.line(cg, [(276, 112), (276, 186)], width: 10)
            C.shape(cg, [(178, 108), (256, 38), (334, 108)], black: true)
        }
    ]

    private static let everyday: [Art] = [
        Art(id: "sneaker", name: "Weekend Sneaker", category: .everyday, tags: ["sneaker", "shoe", "walk", "trainer"], aspectRatio: 1.4) { cg, size in
            let w = size.width, h = size.height
            C.shape(cg, [(w * 0.05, h * 0.28), (w * 0.3, h * 0.22), (w * 0.42, h * 0.42), (w * 0.82, h * 0.52), (w * 0.95, h * 0.66), (w * 0.95, h * 0.72), (w * 0.05, h * 0.72)])
            blackBox(cg, CGRect(x: w * 0.04, y: h * 0.7, width: w * 0.92, height: h * 0.12), radius: 10)
            for index in 0..<3 {
                let x = w * 0.28 + CGFloat(index) * w * 0.06
                C.line(cg, [(x, h * 0.32 + CGFloat(index) * h * 0.04), (x + w * 0.06, h * 0.4 + CGFloat(index) * h * 0.04)], width: 12)
            }
            C.line(cg, [(w * 0.12, h * 0.6), (w * 0.6, h * 0.6)], width: 12)
            C.curve(cg, p(w * 0.72, h * 0.72), p(w * 0.72, h * 0.6), p(w * 0.8, h * 0.54), p(w * 0.86, h * 0.56), width: 12)
        },
        Art(id: "watering-can", name: "Watering Can", category: .everyday, tags: ["watering can", "garden", "plants", "grow"]) { cg, _ in
            C.curve(cg, p(160, 210), p(170, 90), p(300, 90), p(310, 210), width: 24)
            C.shape(cg, [(330, 290), (446, 170), (472, 194), (350, 344)])
            C.shape(cg, [(432, 150), (488, 206), (500, 162), (476, 138)])
            C.box(cg, 110, 200, 240, 230, radius: 30)
            C.line(cg, [(140, 270), (320, 270)], width: 12)
            for (x, y) in [(470, 260), (446, 300), (490, 312)] as [(CGFloat, CGFloat)] { C.oval(cg, x, y, 18, 26, black: true) }
        },
        Art(id: "toast", name: "Toast Buddy", category: .everyday, tags: ["toast", "bread", "breakfast", "cute", "food"]) { cg, _ in
            silhouette(cg, [ellipse(96, 70, 180, 170), ellipse(236, 70, 180, 170), CGPath(roundedRect: CGRect(x: 112, y: 140, width: 288, height: 320), cornerWidth: 34, cornerHeight: 34, transform: nil)])
            F.strokeInk(cg, UIBezierPath(roundedRect: CGRect(x: 150, y: 168, width: 212, height: 254), cornerRadius: 26).cgPath, width: 10)
            C.face(cg, 250)
            C.oval(cg, 166, 300, 30, 18, black: true); C.oval(cg, 318, 300, 30, 18, black: true)
        },
        Art(id: "smartphone", name: "Selfie Phone", category: .everyday, tags: ["phone", "selfie", "mobile", "photo", "social"]) { cg, _ in
            C.box(cg, 140, 34, 232, 444, radius: 40)
            F.strokeInk(cg, UIBezierPath(roundedRect: CGRect(x: 166, y: 92, width: 180, height: 316), cornerRadius: 10).cgPath, width: 12)
            C.oval(cg, 244, 54, 24, 24, black: true)
            C.line(cg, [(222, 446), (290, 446)], width: 14)
            C.heart(cg, CGRect(x: 200, y: 190, width: 112, height: 104), black: true)
            C.line(cg, [(196, 350), (316, 350)], width: 12)
        }
    ]

    private static let madeToKeep: [Art] = [
        Art(id: "little-receipt", name: "Little Receipt", category: .madeToKeep, tags: ["receipt", "keepsake", "photobooth", "made to keep"]) { cg, _ in
            var outline: [(CGFloat, CGFloat)] = [(150, 34), (362, 34)]
            for index in 0...8 {
                let x = 362 - CGFloat(index) * 26.5
                outline.append((x, index.isMultiple(of: 2) ? 448 : 476))
            }
            C.shape(cg, outline)
            C.box(cg, 180, 70, 152, 112, radius: 4)
            C.box(cg, 180, 200, 152, 112, radius: 4)
            C.face(cg, 100)
            C.heart(cg, CGRect(x: 232, y: 226, width: 48, height: 46), black: true)
            C.line(cg, [(188, 354), (324, 354)], width: 12)
            for x in stride(from: 188, through: 316, by: 16) { C.line(cg, [(CGFloat(x), 384), (CGFloat(x), 416)], width: CGFloat(x).truncatingRemainder(dividingBy: 32) == 28 ? 10 : 5) }
        },
        Art(id: "photo-strip", name: "Booth Photo Strip", category: .madeToKeep, tags: ["photo strip", "photobooth", "strip", "keepsake", "made to keep"]) { cg, _ in
            cg.saveGState()
            cg.translateBy(x: 256, y: 256); cg.rotate(by: -0.14); cg.translateBy(x: -256, y: -256)
            C.box(cg, 166, 24, 180, 464, radius: 6)
            for (index, y) in ([46, 190, 334] as [CGFloat]).enumerated() {
                F.strokeInk(cg, UIBezierPath(rect: CGRect(x: 190, y: y, width: 132, height: 122)).cgPath, width: 12)
                switch index {
                case 0: C.heart(cg, CGRect(x: 224, y: y + 30, width: 64, height: 60), black: true)
                case 1: C.star(cg, 222, y + 26, 68, black: true)
                default:
                    C.oval(cg, 228, y + 38, 14, 18, black: true); C.oval(cg, 270, y + 38, 14, 18, black: true)
                    C.curve(cg, p(226, y + 76), p(240, y + 96), p(272, y + 96), p(286, y + 76), width: 10)
                }
            }
            cg.restoreGState()
        },
        Art(id: "little-moments-tag", name: "Little Moments", category: .madeToKeep, tags: ["little moments", "tag", "made to keep", "keepsake"], aspectRatio: 1.4) { cg, size in
            let w = size.width, h = size.height
            C.curve(cg, p(w * 0.84, h * 0.5), p(w * 0.94, h * 0.3), p(w * 0.9, h * 0.12), p(w * 0.98, h * 0.06), width: 12)
            C.shape(cg, [(w * 0.04, h * 0.2), (w * 0.74, h * 0.2), (w * 0.94, h * 0.5), (w * 0.74, h * 0.8), (w * 0.04, h * 0.8)])
            C.oval(cg, w * 0.79, h * 0.45, w * 0.06, w * 0.06)
            labelLines(cg, "LITTLE\nMOMENTS", in: CGRect(x: w * 0.1, y: h * 0.3, width: w * 0.58, height: h * 0.4))
        },
        Art(id: "keepsake-locket", name: "Keepsake Locket", category: .madeToKeep, tags: ["locket", "heart", "necklace", "keepsake", "made to keep"]) { cg, _ in
            for index in 0..<14 {
                let t = CGFloat(index) / 13
                let x = 96 + t * 320
                let y = 40 + 4 * t * (1 - t) * 160
                C.oval(cg, x - 10, y - 10, 20, 20, black: index.isMultiple(of: 2))
            }
            C.oval(cg, 236, 170, 40, 40)
            C.heart(cg, CGRect(x: 120, y: 200, width: 272, height: 262))
            F.strokeInk(cg, BundledStickerFactory.heartPath(in: CGRect(x: 176, y: 254, width: 160, height: 152)), width: 10)
            C.star(cg, 232, 296, 48, black: true)
        }
    ]
}
