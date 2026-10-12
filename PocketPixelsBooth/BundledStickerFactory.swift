//
//  BundledStickerFactory.swift
//  PocketPixelsBooth
//
//  The built-in sticker library: original Made to Keep Studios artwork drawn in code so it is
//  available offline from first launch, prints crisp on 1-bit thermal paper (solid black ink,
//  white fills, heavy strokes) and needs no bundled media or licences. Text stickers use
//  system fonts with outlines — never emoji glyphs, which rasterize as colour or missing boxes.
//

import CoreGraphics
import Foundation
import UIKit

nonisolated enum BundledStickerFactory {
    /// Square-ish render size of the master artwork in pixels.
    static let canvasSize: CGFloat = 512
    static let strokeWidth: CGFloat = 18

    struct Definition: Sendable {
        let id: String
        let name: String
        let category: StickerCategory
        let tags: [String]
        /// width / height
        let aspectRatio: CGFloat
        let draw: @Sendable (CGContext, CGSize) -> Void
    }

    static var assets: [StickerAsset] {
        definitions.map { definition in
            StickerAsset(
                id: definition.id,
                name: definition.name,
                tags: definition.tags,
                category: definition.category,
                provenance: .builtIn,
                aspectRatio: definition.aspectRatio
            )
        }
    }

    static func definition(for id: String) -> Definition? {
        definitions.first { $0.id == id }
    }

    /// Rendered artwork, cached. Identical on every call, so placements reprint identically.
    static func image(for id: String, maximumPixelDimension: Int = 1_280) -> CGImage? {
        let edge = min(max(32, maximumPixelDimension), StickerImageLimits.maximumDecodedPixelDimension)
        let key = "\(id).\(edge)" as NSString
        if let cached = cache.object(forKey: key) { return cached.image }
        guard let definition = definition(for: id) else { return nil }
        let height = canvasSize
        let width = (canvasSize * definition.aspectRatio).rounded()
        let size = CGSize(width: width, height: height)
        let scale = min(1, CGFloat(edge) / max(size.width, size.height))
        let outputSize = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let rendered = UIGraphicsImageRenderer(size: outputSize, format: format).image { context in
            let cg = context.cgContext
            cg.scaleBy(x: scale, y: scale)
            cg.setLineJoin(.round)
            cg.setLineCap(.round)
            definition.draw(cg, size)
        }
        guard let cgImage = rendered.cgImage else { return nil }
        cache.setObject(CachedImage(image: cgImage), forKey: key, cost: cgImage.bytesPerRow * cgImage.height)
        return cgImage
    }

    private final class CachedImage: @unchecked Sendable {
        let image: CGImage
        init(image: CGImage) { self.image = image }
    }

    nonisolated(unsafe) private static let cache: NSCache<NSString, CachedImage> = {
        let cache = NSCache<NSString, CachedImage>()
        cache.countLimit = 256
        cache.totalCostLimit = 48 * 1024 * 1024
        return cache
    }()

    // MARK: Library

    static let definitions: [Definition] = [
        // Classic
        Definition(id: "builtin.star", name: "Star", category: .classic, tags: ["star", "shine"], aspectRatio: 1) { cg, size in
            inkShape(cg, starPath(in: CGRect(origin: .zero, size: size).insetBy(dx: 30, dy: 30), points: 5, innerRatio: 0.45))
        },
        Definition(id: "builtin.sparkles", name: "Sparkles", category: .classic, tags: ["sparkle", "shine", "glitter"], aspectRatio: 1) { cg, size in
            inkShape(cg, sparklePath(center: CGPoint(x: size.width * 0.42, y: size.height * 0.56), radius: size.width * 0.34), fill: .black)
            inkShape(cg, sparklePath(center: CGPoint(x: size.width * 0.78, y: size.height * 0.22), radius: size.width * 0.16))
            inkShape(cg, sparklePath(center: CGPoint(x: size.width * 0.8, y: size.height * 0.8), radius: size.width * 0.1), fill: .black)
        },
        Definition(id: "builtin.smiley", name: "Smiley", category: .classic, tags: ["smile", "happy", "face"], aspectRatio: 1) { cg, size in
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: 26, dy: 26)
            inkShape(cg, UIBezierPath(ovalIn: rect).cgPath)
            cg.setFillColor(UIColor.black.cgColor)
            cg.fillEllipse(in: CGRect(x: rect.midX - 120, y: rect.minY + 130, width: 60, height: 90))
            cg.fillEllipse(in: CGRect(x: rect.midX + 60, y: rect.minY + 130, width: 60, height: 90))
            let smile = UIBezierPath()
            smile.move(to: CGPoint(x: rect.midX - 130, y: rect.midY + 40))
            smile.addQuadCurve(to: CGPoint(x: rect.midX + 130, y: rect.midY + 40), controlPoint: CGPoint(x: rect.midX, y: rect.maxY - 30))
            strokeInk(cg, smile.cgPath, width: 26)
        },
        Definition(id: "builtin.crown", name: "Crown", category: .classic, tags: ["crown", "queen", "king", "royal"], aspectRatio: 1.25) { cg, size in
            let w = size.width, h = size.height
            let path = UIBezierPath()
            path.move(to: CGPoint(x: w * 0.1, y: h * 0.8))
            path.addLine(to: CGPoint(x: w * 0.06, y: h * 0.28))
            path.addLine(to: CGPoint(x: w * 0.3, y: h * 0.5))
            path.addLine(to: CGPoint(x: w * 0.5, y: h * 0.14))
            path.addLine(to: CGPoint(x: w * 0.7, y: h * 0.5))
            path.addLine(to: CGPoint(x: w * 0.94, y: h * 0.28))
            path.addLine(to: CGPoint(x: w * 0.9, y: h * 0.8))
            path.close()
            inkShape(cg, path.cgPath)
            cg.setFillColor(UIColor.black.cgColor)
            cg.fill(CGRect(x: w * 0.1, y: h * 0.8, width: w * 0.8, height: h * 0.1))
            for x in [0.06, 0.5, 0.94] {
                cg.fillEllipse(in: CGRect(x: w * x - 22, y: (x == 0.5 ? h * 0.14 : h * 0.28) - 40, width: 44, height: 44))
            }
        },
        Definition(id: "builtin.bolt", name: "Lightning", category: .classic, tags: ["lightning", "bolt", "energy", "zap"], aspectRatio: 0.7) { cg, size in
            let w = size.width, h = size.height
            let path = UIBezierPath()
            path.move(to: CGPoint(x: w * 0.62, y: h * 0.04))
            path.addLine(to: CGPoint(x: w * 0.1, y: h * 0.56))
            path.addLine(to: CGPoint(x: w * 0.48, y: h * 0.56))
            path.addLine(to: CGPoint(x: w * 0.34, y: h * 0.96))
            path.addLine(to: CGPoint(x: w * 0.9, y: h * 0.4))
            path.addLine(to: CGPoint(x: w * 0.54, y: h * 0.4))
            path.close()
            inkShape(cg, path.cgPath, fill: .black)
        },
        Definition(id: "builtin.sunglasses", name: "Cool Shades", category: .classic, tags: ["sunglasses", "cool", "shades"], aspectRatio: 2) { cg, size in
            let w = size.width, h = size.height
            let left = UIBezierPath(roundedRect: CGRect(x: w * 0.06, y: h * 0.3, width: w * 0.38, height: h * 0.5), cornerRadius: h * 0.2)
            let right = UIBezierPath(roundedRect: CGRect(x: w * 0.56, y: h * 0.3, width: w * 0.38, height: h * 0.5), cornerRadius: h * 0.2)
            inkShape(cg, left.cgPath, fill: .black)
            inkShape(cg, right.cgPath, fill: .black)
            let bridge = UIBezierPath()
            bridge.move(to: CGPoint(x: w * 0.44, y: h * 0.42))
            bridge.addQuadCurve(to: CGPoint(x: w * 0.56, y: h * 0.42), controlPoint: CGPoint(x: w * 0.5, y: h * 0.3))
            strokeInk(cg, bridge.cgPath, width: 22)
            cg.setFillColor(UIColor.white.cgColor)
            cg.fill(CGRect(x: w * 0.12, y: h * 0.38, width: w * 0.08, height: h * 0.08))
            cg.fill(CGRect(x: w * 0.62, y: h * 0.38, width: w * 0.08, height: h * 0.08))
        },

        // Cute
        Definition(id: "builtin.bow", name: "Bow", category: .cute, tags: ["bow", "ribbon", "cute", "coquette"], aspectRatio: 1.5) { cg, size in
            let w = size.width, h = size.height
            let left = UIBezierPath()
            left.move(to: CGPoint(x: w * 0.5, y: h * 0.5))
            left.addCurve(to: CGPoint(x: w * 0.06, y: h * 0.2), controlPoint1: CGPoint(x: w * 0.36, y: h * 0.1), controlPoint2: CGPoint(x: w * 0.1, y: h * 0.0))
            left.addCurve(to: CGPoint(x: w * 0.5, y: h * 0.5), controlPoint1: CGPoint(x: w * 0.0, y: h * 0.6), controlPoint2: CGPoint(x: w * 0.3, y: h * 0.7))
            let right = UIBezierPath(cgPath: left.cgPath)
            right.apply(CGAffineTransform(scaleX: -1, y: 1).translatedBy(x: -w, y: 0))
            inkShape(cg, left.cgPath)
            inkShape(cg, right.cgPath)
            let tailL = UIBezierPath()
            tailL.move(to: CGPoint(x: w * 0.47, y: h * 0.55))
            tailL.addLine(to: CGPoint(x: w * 0.3, y: h * 0.95))
            tailL.addLine(to: CGPoint(x: w * 0.42, y: h * 0.9))
            tailL.addLine(to: CGPoint(x: w * 0.5, y: h * 0.58))
            tailL.close()
            let tailR = UIBezierPath(cgPath: tailL.cgPath)
            tailR.apply(CGAffineTransform(scaleX: -1, y: 1).translatedBy(x: -w, y: 0))
            inkShape(cg, tailL.cgPath, fill: .black)
            inkShape(cg, tailR.cgPath, fill: .black)
            inkShape(cg, UIBezierPath(ovalIn: CGRect(x: w * 0.43, y: h * 0.38, width: w * 0.14, height: h * 0.24)).cgPath, fill: .black)
        },
        Definition(id: "builtin.flower", name: "Daisy", category: .cute, tags: ["flower", "daisy", "bloom"], aspectRatio: 1) { cg, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            for index in 0..<8 {
                let angle = CGFloat(index) * .pi / 4
                let petal = UIBezierPath(ovalIn: CGRect(x: -48, y: -190, width: 96, height: 170))
                petal.apply(CGAffineTransform(rotationAngle: angle))
                petal.apply(CGAffineTransform(translationX: center.x, y: center.y))
                inkShape(cg, petal.cgPath)
            }
            inkShape(cg, UIBezierPath(ovalIn: CGRect(x: center.x - 62, y: center.y - 62, width: 124, height: 124)).cgPath, fill: .black)
        },
        Definition(id: "builtin.cloud", name: "Happy Cloud", category: .cute, tags: ["cloud", "cute", "dreamy"], aspectRatio: 1.5) { cg, size in
            let w = size.width, h = size.height
            let path = UIBezierPath()
            path.move(to: CGPoint(x: w * 0.16, y: h * 0.8))
            path.addCurve(to: CGPoint(x: w * 0.22, y: h * 0.42), controlPoint1: CGPoint(x: w * 0.0, y: h * 0.8), controlPoint2: CGPoint(x: w * 0.02, y: h * 0.46))
            path.addCurve(to: CGPoint(x: w * 0.62, y: h * 0.26), controlPoint1: CGPoint(x: w * 0.26, y: h * 0.06), controlPoint2: CGPoint(x: w * 0.56, y: h * 0.04))
            path.addCurve(to: CGPoint(x: w * 0.84, y: h * 0.8), controlPoint1: CGPoint(x: w * 0.96, y: h * 0.2), controlPoint2: CGPoint(x: w * 1.04, y: h * 0.78))
            path.close()
            inkShape(cg, path.cgPath)
            cg.setFillColor(UIColor.black.cgColor)
            cg.fillEllipse(in: CGRect(x: w * 0.36, y: h * 0.48, width: 34, height: 44))
            cg.fillEllipse(in: CGRect(x: w * 0.58, y: h * 0.48, width: 34, height: 44))
            let smile = UIBezierPath()
            smile.move(to: CGPoint(x: w * 0.44, y: h * 0.66))
            smile.addQuadCurve(to: CGPoint(x: w * 0.58, y: h * 0.66), controlPoint: CGPoint(x: w * 0.51, y: h * 0.74))
            strokeInk(cg, smile.cgPath, width: 14)
        },
        Definition(id: "builtin.cherries", name: "Cherries", category: .cute, tags: ["cherry", "fruit", "sweet"], aspectRatio: 1) { cg, size in
            let w = size.width, h = size.height
            let stems = UIBezierPath()
            stems.move(to: CGPoint(x: w * 0.3, y: h * 0.62))
            stems.addQuadCurve(to: CGPoint(x: w * 0.62, y: h * 0.12), controlPoint: CGPoint(x: w * 0.36, y: h * 0.24))
            stems.move(to: CGPoint(x: w * 0.7, y: h * 0.66))
            stems.addQuadCurve(to: CGPoint(x: w * 0.62, y: h * 0.12), controlPoint: CGPoint(x: w * 0.72, y: h * 0.3))
            strokeInk(cg, stems.cgPath, width: 18)
            let leaf = UIBezierPath(ovalIn: CGRect(x: w * 0.6, y: h * 0.06, width: w * 0.3, height: h * 0.14))
            inkShape(cg, leaf.cgPath)
            inkShape(cg, UIBezierPath(ovalIn: CGRect(x: w * 0.1, y: h * 0.56, width: w * 0.38, height: w * 0.38)).cgPath, fill: .black)
            inkShape(cg, UIBezierPath(ovalIn: CGRect(x: w * 0.52, y: h * 0.6, width: w * 0.36, height: w * 0.36)).cgPath, fill: .black)
            cg.setFillColor(UIColor.white.cgColor)
            cg.fillEllipse(in: CGRect(x: w * 0.18, y: h * 0.64, width: 36, height: 36))
            cg.fillEllipse(in: CGRect(x: w * 0.6, y: h * 0.68, width: 32, height: 32))
        },

        // Hearts
        Definition(id: "builtin.heart", name: "Heart", category: .hearts, tags: ["heart", "love"], aspectRatio: 1) { cg, size in
            inkShape(cg, heartPath(in: CGRect(origin: .zero, size: size).insetBy(dx: 30, dy: 40)), fill: .black)
            cg.setFillColor(UIColor.white.cgColor)
            cg.fillEllipse(in: CGRect(x: size.width * 0.24, y: size.height * 0.26, width: 46, height: 46))
        },
        Definition(id: "builtin.heart-outline", name: "Open Heart", category: .hearts, tags: ["heart", "love", "outline"], aspectRatio: 1) { cg, size in
            inkShape(cg, heartPath(in: CGRect(origin: .zero, size: size).insetBy(dx: 34, dy: 44)))
            inkShape(cg, heartPath(in: CGRect(origin: .zero, size: size).insetBy(dx: 130, dy: 140)), fill: .black)
        },
        Definition(id: "builtin.hearts-trio", name: "Love Trio", category: .hearts, tags: ["hearts", "love", "cute"], aspectRatio: 1.3) { cg, size in
            let w = size.width, h = size.height
            inkShape(cg, heartPath(in: CGRect(x: w * 0.04, y: h * 0.3, width: w * 0.5, height: h * 0.6)), fill: .black)
            inkShape(cg, heartPath(in: CGRect(x: w * 0.52, y: h * 0.06, width: w * 0.36, height: h * 0.44)))
            inkShape(cg, heartPath(in: CGRect(x: w * 0.62, y: h * 0.58, width: w * 0.28, height: h * 0.34)), fill: .black)
        },
        Definition(id: "builtin.heart-arrow", name: "Cupid Arrow", category: .hearts, tags: ["heart", "arrow", "cupid", "love"], aspectRatio: 1.4) { cg, size in
            let w = size.width, h = size.height
            inkShape(cg, heartPath(in: CGRect(x: w * 0.24, y: h * 0.12, width: w * 0.52, height: h * 0.74)))
            let shaft = UIBezierPath()
            shaft.move(to: CGPoint(x: w * 0.06, y: h * 0.8))
            shaft.addLine(to: CGPoint(x: w * 0.9, y: h * 0.2))
            strokeInk(cg, shaft.cgPath, width: 22)
            let head = UIBezierPath()
            head.move(to: CGPoint(x: w * 0.97, y: h * 0.15))
            head.addLine(to: CGPoint(x: w * 0.82, y: h * 0.18))
            head.addLine(to: CGPoint(x: w * 0.9, y: h * 0.32))
            head.close()
            inkShape(cg, head.cgPath, fill: .black)
        },

        // Doodles
        Definition(id: "builtin.arrow", name: "Doodle Arrow", category: .doodles, tags: ["arrow", "point", "doodle", "this"], aspectRatio: 1.6) { cg, size in
            let w = size.width, h = size.height
            let path = UIBezierPath()
            path.move(to: CGPoint(x: w * 0.06, y: h * 0.72))
            path.addCurve(to: CGPoint(x: w * 0.86, y: h * 0.36), controlPoint1: CGPoint(x: w * 0.3, y: h * 0.1), controlPoint2: CGPoint(x: w * 0.56, y: h * 0.9))
            strokeInk(cg, path.cgPath, width: 26)
            let head = UIBezierPath()
            head.move(to: CGPoint(x: w * 0.7, y: h * 0.22))
            head.addLine(to: CGPoint(x: w * 0.9, y: h * 0.34))
            head.addLine(to: CGPoint(x: w * 0.76, y: h * 0.56))
            strokeInk(cg, head.cgPath, width: 26)
        },
        Definition(id: "builtin.squiggle", name: "Squiggle", category: .doodles, tags: ["squiggle", "line", "doodle"], aspectRatio: 2.2) { cg, size in
            let w = size.width, h = size.height
            let path = UIBezierPath()
            path.move(to: CGPoint(x: w * 0.04, y: h * 0.5))
            for index in 0..<5 {
                let x0 = w * (0.04 + CGFloat(index) * 0.184)
                path.addCurve(
                    to: CGPoint(x: x0 + w * 0.184, y: h * 0.5),
                    controlPoint1: CGPoint(x: x0 + w * 0.06, y: index.isMultiple(of: 2) ? h * 0.05 : h * 0.95),
                    controlPoint2: CGPoint(x: x0 + w * 0.124, y: index.isMultiple(of: 2) ? h * 0.05 : h * 0.95)
                )
            }
            strokeInk(cg, path.cgPath, width: 30)
        },
        Definition(id: "builtin.confetti", name: "Confetti", category: .doodles, tags: ["confetti", "party", "celebrate"], aspectRatio: 1) { cg, size in
            let pieces: [(CGFloat, CGFloat, CGFloat)] = [(0.2, 0.2, 0.4), (0.7, 0.16, -0.6), (0.5, 0.45, 0.9), (0.18, 0.66, -0.3), (0.78, 0.6, 0.2), (0.46, 0.84, -0.9), (0.84, 0.88, 0.7)]
            for (index, piece) in pieces.enumerated() {
                cg.saveGState()
                cg.translateBy(x: size.width * piece.0, y: size.height * piece.1)
                cg.rotate(by: piece.2)
                let rect = CGRect(x: -44, y: -20, width: 88, height: 40)
                inkShape(cg, UIBezierPath(roundedRect: rect, cornerRadius: 8).cgPath, fill: index.isMultiple(of: 2) ? .black : .white)
                cg.restoreGState()
            }
            cg.setFillColor(UIColor.black.cgColor)
            for point in [(0.4, 0.14), (0.88, 0.36), (0.1, 0.42), (0.3, 0.92), (0.66, 0.74)] {
                cg.fillEllipse(in: CGRect(x: size.width * point.0 - 18, y: size.height * point.1 - 18, width: 36, height: 36))
            }
        },
        Definition(id: "builtin.burst", name: "Burst", category: .doodles, tags: ["burst", "pop", "wow", "comic"], aspectRatio: 1) { cg, size in
            inkShape(cg, starPath(in: CGRect(origin: .zero, size: size).insetBy(dx: 18, dy: 18), points: 12, innerRatio: 0.72))
            inkShape(cg, starPath(in: CGRect(origin: .zero, size: size).insetBy(dx: 140, dy: 140), points: 8, innerRatio: 0.5), fill: .black)
        },
        Definition(id: "builtin.banner-yay", name: "YAY Banner", category: .doodles, tags: ["ribbon", "banner", "yay", "celebrate"], aspectRatio: 2.4) { cg, size in
            let w = size.width, h = size.height
            let ribbon = UIBezierPath()
            ribbon.move(to: CGPoint(x: w * 0.02, y: h * 0.3))
            ribbon.addLine(to: CGPoint(x: w * 0.98, y: h * 0.3))
            ribbon.addLine(to: CGPoint(x: w * 0.9, y: h * 0.52))
            ribbon.addLine(to: CGPoint(x: w * 0.98, y: h * 0.74))
            ribbon.addLine(to: CGPoint(x: w * 0.02, y: h * 0.74))
            ribbon.addLine(to: CGPoint(x: w * 0.1, y: h * 0.52))
            ribbon.close()
            inkShape(cg, ribbon.cgPath, fill: .black)
            drawLabel(cg, "YAY!", in: CGRect(x: w * 0.12, y: h * 0.3, width: w * 0.76, height: h * 0.44), inverted: true)
        },

        // Reactions (original type treatments, no third-party memes)
        Definition(id: "builtin.lol", name: "LOL", category: .reactions, tags: ["lol", "laugh", "funny", "meme"], aspectRatio: 1.6) { cg, size in
            speechBubble(cg, size: size, text: "LOL")
        },
        Definition(id: "builtin.omg", name: "OMG", category: .reactions, tags: ["omg", "shock", "wow", "meme"], aspectRatio: 1) { cg, size in
            inkShape(cg, starPath(in: CGRect(origin: .zero, size: size).insetBy(dx: 12, dy: 12), points: 14, innerRatio: 0.8))
            drawLabel(cg, "OMG", in: CGRect(origin: .zero, size: size).insetBy(dx: 96, dy: 150))
        },
        Definition(id: "builtin.wow", name: "WOW", category: .reactions, tags: ["wow", "amazing", "meme"], aspectRatio: 1.7) { cg, size in
            badge(cg, size: size, text: "WOW", filled: true)
        },
        Definition(id: "builtin.side-eye", name: "Side Eye", category: .reactions, tags: ["side eye", "eyes", "sus", "meme", "look"], aspectRatio: 1.8) { cg, size in
            let w = size.width, h = size.height
            for x in [0.06, 0.52] {
                let eye = CGRect(x: w * x, y: h * 0.12, width: w * 0.42, height: h * 0.56)
                inkShape(cg, UIBezierPath(ovalIn: eye).cgPath)
                cg.setFillColor(UIColor.black.cgColor)
                cg.fillEllipse(in: CGRect(x: eye.maxX - eye.width * 0.42, y: eye.midY - eye.height * 0.2, width: eye.width * 0.3, height: eye.height * 0.4))
                // Heavy lid sells the side eye.
                cg.fill(CGRect(x: eye.minX, y: eye.minY - 4, width: eye.width, height: eye.height * 0.3))
            }
            drawLabel(cg, "SIDE EYE", in: CGRect(x: w * 0.04, y: h * 0.72, width: w * 0.92, height: h * 0.26))
        },
        Definition(id: "builtin.mood", name: "MOOD", category: .reactions, tags: ["mood", "vibe", "meme"], aspectRatio: 2) { cg, size in
            badge(cg, size: size, text: "MOOD", filled: false)
        },
        Definition(id: "builtin.pov", name: "POV", category: .reactions, tags: ["pov", "point of view", "meme"], aspectRatio: 1.6) { cg, size in
            let w = size.width, h = size.height
            let tag = UIBezierPath(roundedRect: CGRect(x: w * 0.04, y: h * 0.16, width: w * 0.92, height: h * 0.68), cornerRadius: 30)
            inkShape(cg, tag.cgPath, fill: .black)
            drawLabel(cg, "POV:", in: CGRect(x: w * 0.1, y: h * 0.22, width: w * 0.8, height: h * 0.56), inverted: true)
        },
        Definition(id: "builtin.besties", name: "Besties", category: .reactions, tags: ["besties", "bff", "friends"], aspectRatio: 2.2) { cg, size in
            badge(cg, size: size, text: "BESTIES", filled: false)
        },
        Definition(id: "builtin.iykyk", name: "IYKYK", category: .reactions, tags: ["iykyk", "inside joke", "meme"], aspectRatio: 2.2) { cg, size in
            badge(cg, size: size, text: "IYKYK", filled: true)
        },
        Definition(id: "builtin.hi", name: "Hi!", category: .reactions, tags: ["hi", "hello", "wave", "speech"], aspectRatio: 1.4) { cg, size in
            speechBubble(cg, size: size, text: "HI!")
        }
    ] + CuratedStickerArtwork.definitions

    // MARK: Drawing helpers

    enum Fill { case white, black }

    /// A filled shape with a solid black outline: the core thermal-legible look.
    static func inkShape(_ cg: CGContext, _ path: CGPath, fill: Fill = .white) {
        cg.addPath(path)
        cg.setFillColor((fill == .white ? UIColor.white : UIColor.black).cgColor)
        cg.setStrokeColor(UIColor.black.cgColor)
        cg.setLineWidth(strokeWidth)
        cg.drawPath(using: .fillStroke)
    }

    static func strokeInk(_ cg: CGContext, _ path: CGPath, width: CGFloat) {
        cg.addPath(path)
        cg.setStrokeColor(UIColor.black.cgColor)
        cg.setLineWidth(width)
        cg.strokePath()
    }

    static func starPath(in rect: CGRect, points: Int, innerRatio: CGFloat) -> CGPath {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outer = min(rect.width, rect.height) / 2
        let inner = outer * innerRatio
        let path = UIBezierPath()
        for index in 0..<(points * 2) {
            let radius = index.isMultiple(of: 2) ? outer : inner
            let angle = CGFloat(index) * .pi / CGFloat(points) - .pi / 2
            let point = CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
            index == 0 ? path.move(to: point) : path.addLine(to: point)
        }
        path.close()
        return path.cgPath
    }

    static func sparklePath(center: CGPoint, radius: CGFloat) -> CGPath {
        let path = UIBezierPath()
        let waist = radius * 0.22
        path.move(to: CGPoint(x: center.x, y: center.y - radius))
        path.addQuadCurve(to: CGPoint(x: center.x + radius, y: center.y), controlPoint: CGPoint(x: center.x + waist, y: center.y - waist))
        path.addQuadCurve(to: CGPoint(x: center.x, y: center.y + radius), controlPoint: CGPoint(x: center.x + waist, y: center.y + waist))
        path.addQuadCurve(to: CGPoint(x: center.x - radius, y: center.y), controlPoint: CGPoint(x: center.x - waist, y: center.y + waist))
        path.addQuadCurve(to: CGPoint(x: center.x, y: center.y - radius), controlPoint: CGPoint(x: center.x - waist, y: center.y - waist))
        path.close()
        return path.cgPath
    }

    static func heartPath(in rect: CGRect) -> CGPath {
        let w = rect.width, h = rect.height, x = rect.minX, y = rect.minY
        let path = UIBezierPath()
        path.move(to: CGPoint(x: x + w * 0.5, y: y + h))
        path.addCurve(to: CGPoint(x: x, y: y + h * 0.3), controlPoint1: CGPoint(x: x + w * 0.2, y: y + h * 0.78), controlPoint2: CGPoint(x: x, y: y + h * 0.58))
        path.addCurve(to: CGPoint(x: x + w * 0.5, y: y + h * 0.16), controlPoint1: CGPoint(x: x, y: y - h * 0.04), controlPoint2: CGPoint(x: x + w * 0.4, y: y - h * 0.02))
        path.addCurve(to: CGPoint(x: x + w, y: y + h * 0.3), controlPoint1: CGPoint(x: x + w * 0.6, y: y - h * 0.02), controlPoint2: CGPoint(x: x + w, y: y - h * 0.04))
        path.addCurve(to: CGPoint(x: x + w * 0.5, y: y + h), controlPoint1: CGPoint(x: x + w, y: y + h * 0.58), controlPoint2: CGPoint(x: x + w * 0.8, y: y + h * 0.78))
        path.close()
        return path.cgPath
    }

    /// Heavy, outlined, fitted capitals. Inverted draws white letters for black shapes.
    static func drawLabel(_ cg: CGContext, _ text: String, in rect: CGRect, inverted: Bool = false) {
        var fontSize = rect.height
        var font = UIFont.systemFont(ofSize: fontSize, weight: .black)
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .kern: 2]
        var measured = NSString(string: text).size(withAttributes: attributes)
        while (measured.width > rect.width || measured.height > rect.height) && fontSize > 12 {
            fontSize -= 4
            font = UIFont.systemFont(ofSize: fontSize, weight: .black)
            attributes[.font] = font
            measured = NSString(string: text).size(withAttributes: attributes)
        }
        attributes[.foregroundColor] = inverted ? UIColor.white : UIColor.black
        let origin = CGPoint(x: rect.midX - measured.width / 2, y: rect.midY - measured.height / 2)
        UIGraphicsPushContext(cg)
        NSString(string: text).draw(at: origin, withAttributes: attributes)
        UIGraphicsPopContext()
    }

    static func speechBubble(_ cg: CGContext, size: CGSize, text: String) {
        let w = size.width, h = size.height
        let tail = UIBezierPath()
        tail.move(to: CGPoint(x: w * 0.24, y: h * 0.6))
        tail.addLine(to: CGPoint(x: w * 0.16, y: h * 0.96))
        tail.addLine(to: CGPoint(x: w * 0.44, y: h * 0.62))
        tail.close()
        inkShape(cg, tail.cgPath)
        let body = UIBezierPath(roundedRect: CGRect(x: w * 0.04, y: h * 0.06, width: w * 0.92, height: h * 0.66), cornerRadius: h * 0.3)
        inkShape(cg, body.cgPath)
        drawLabel(cg, text, in: CGRect(x: w * 0.14, y: h * 0.14, width: w * 0.72, height: h * 0.5))
    }

    static func badge(_ cg: CGContext, size: CGSize, text: String, filled: Bool) {
        let w = size.width, h = size.height
        let shape = UIBezierPath(roundedRect: CGRect(x: w * 0.03, y: h * 0.12, width: w * 0.94, height: h * 0.76), cornerRadius: h * 0.38)
        inkShape(cg, shape.cgPath, fill: filled ? .black : .white)
        drawLabel(cg, text, in: CGRect(x: w * 0.12, y: h * 0.2, width: w * 0.76, height: h * 0.6), inverted: filled)
    }
}
