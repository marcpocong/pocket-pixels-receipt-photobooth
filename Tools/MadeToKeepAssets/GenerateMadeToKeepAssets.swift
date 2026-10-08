import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

struct RGBA { var r: UInt8; var g: UInt8; var b: UInt8; var a: UInt8 }
final class Bitmap {
    let w: Int, h: Int
    var px: [UInt8]
    init(w: Int, h: Int) { self.w = w; self.h = h; px = [UInt8](repeating: 0, count: w*h*4) }
    init(path: String) {
        let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil)!
        let img = CGImageSourceCreateImageAtIndex(src, 0, nil)!
        w = img.width; h = img.height
        px = [UInt8](repeating: 0, count: w*h*4)
        let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w*4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    }
    @inline(__always) func get(_ x: Int, _ y: Int) -> (Double, Double, Double) {
        let i = (y*w + x)*4; return (Double(px[i]), Double(px[i+1]), Double(px[i+2]))
    }
    @inline(__always) func set(_ x: Int, _ y: Int, _ c: (Double, Double, Double), _ a: Double = 255) {
        let i = (y*w + x)*4
        px[i] = UInt8(max(0, min(255, c.0.rounded()))); px[i+1] = UInt8(max(0, min(255, c.1.rounded()))); px[i+2] = UInt8(max(0, min(255, c.2.rounded()))); px[i+3] = UInt8(max(0, min(255, a.rounded())))
    }
    func cgImage() -> CGImage {
        let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w*4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }
    func save(_ path: String) {
        let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, cgImage(), nil); CGImageDestinationFinalize(dest)
    }
    func crop(x: Int, y: Int, w cw: Int, h ch: Int) -> Bitmap {
        let b = Bitmap(w: cw, h: ch)
        for yy in 0..<ch { for xx in 0..<cw { let i = ((y+yy)*w + (x+xx))*4; let j = (yy*cw+xx)*4; for k in 0..<4 { b.px[j+k] = px[i+k] } } }
        return b
    }
}
// In this coordinate system (CGContext bitmap memory), row 0 is the TOP of the image.
func redness(_ c: (Double, Double, Double)) -> Double { c.0 - (c.1 + c.2) / 2 }
import AppKit
// ---------- deterministic RNG ----------
struct RNG { var s: UInt64; mutating func next() -> Double { s = s &* 6364136223846793005 &+ 1442695040888963407; return Double((s >> 11) & ((1 << 53) - 1)) / Double(1 << 53) }
  mutating func gauss() -> Double { let u = max(1e-12, next()), v = next(); return sqrt(-2 * log(u)) * cos(2 * .pi * v) } }

let ref = Bitmap(path: CommandLine.arguments[1])
let out = CommandLine.arguments[2]
let W = ref.w, H = ref.h

// ---------- 1. Mask ----------
var mask = [Bool](repeating: false, count: W * H)
for y in 380...1095 { for x in 140...910 { if redness(ref.get(x, y)) > 19 { mask[y*W+x] = true } } }
// local luminance blur for gray text detection
func lum(_ x: Int, _ y: Int) -> Double { let c = ref.get(x, y); return (c.0 + c.1 + c.2) / 3 }
func boxMean(_ x: Int, _ y: Int, _ r: Int) -> Double { var s = 0.0, n = 0.0; for yy in max(0,y-r)...min(H-1,y+r) { for xx in max(0,x-r)...min(W-1,x+r) { s += lum(xx,yy); n += 1 } }; return s / n }
func grayText(x0: Int, x1: Int, y0: Int, y1: Int, thr: Double, keep: (Int, Int) -> Bool = { _, _ in true }) {
    for y in y0...y1 { for x in x0...x1 where keep(x, y) { if lum(x, y) < boxMean(x, y, 9) - thr { mask[y*W+x] = true } } }
}
let dotted: (Int, Int) -> Bool = { x, y in Double(y) < 225 - Double(x - 260) * 50 / 600 - 7 }
grayText(x0: 255, x1: 740, y0: 92, y1: 200, thr: 9, keep: dotted)
grayText(x0: 175, x1: 312, y0: 1342, y1: 1402, thr: 9)
grayText(x0: 878, x1: 982, y0: 1278, y1: 1326, thr: 9)
// dilate
func dilate(_ m: [Bool], _ r: Int) -> [Bool] { var o = m; for y in 0..<H { for x in 0..<W where m[y*W+x] { for yy in max(0,y-r)...min(H-1,y+r) { for xx in max(0,x-r)...min(W-1,x+r) { o[yy*W+xx] = true } } } }; return o }
mask = dilate(mask, 3)
var maskCount = 0; for m in mask where m { maskCount += 1 }; print("masked px", maskCount)

// ---------- 2. Inpaint (multi-pass diffusion) ----------
var r = [Double](repeating: 0, count: W*H), g = r, b = r
for y in 0..<H { for x in 0..<W { let c = ref.get(x, y); r[y*W+x] = c.0; g[y*W+x] = c.1; b[y*W+x] = c.2 } }
// initialise masked pixels with nearest-row average of known neighbours
let idx = (0..<(W*H)).filter { mask[$0] }
for i in idx { r[i] = 245; g[i] = 239; b[i] = 231 }
for pass in 0..<600 {
    let w = pass < 300 ? 1 : 1
    for i in idx {
        let x = i % W, y = i / W
        var sr = 0.0, sg = 0.0, sb = 0.0, n = 0.0
        for (dx, dy) in [(-w,0),(w,0),(0,-w),(0,w),(-w,-w),(w,w),(-w,w),(w,-w)] {
            let xx = x+dx, yy = y+dy; if xx < 0 || yy < 0 || xx >= W || yy >= H { continue }
            let j = yy*W+xx; sr += r[j]; sg += g[j]; sb += b[j]; n += 1
        }
        r[i] = sr/n; g[i] = sg/n; b[i] = sb/n
    }
}
// re-add grain so inpainted regions don't look smudged
var rng = RNG(s: 0x4D544B)
for i in idx { let n = rng.gauss() * 4.2; r[i] += n; g[i] += n; b[i] += n * 0.95 }
let backdrop = Bitmap(w: W, h: H)
for i in 0..<(W*H) { backdrop.set(i % W, i / W, (r[i], g[i], b[i])) }
backdrop.save(out + "/MadeToKeepWelcomeBackdrop.png")

// ---------- 3. Paper texture (procedural) ----------
let PW = 1600, PH = 1600
let paper = Bitmap(w: PW, h: PH)
// value noise
func makeNoise(_ cells: Int, seed: UInt64) -> [Double] { var rr = RNG(s: seed); return (0..<((cells+1)*(cells+1))).map { _ in rr.next() * 2 - 1 } }
func sample(_ grid: [Double], _ cells: Int, _ u: Double, _ v: Double) -> Double {
    let fx = u * Double(cells), fy = v * Double(cells); let ix = min(cells-1, Int(fx)), iy = min(cells-1, Int(fy))
    let tx = fx - Double(ix), ty = fy - Double(iy); let sx = tx*tx*(3-2*tx), sy = ty*ty*(3-2*ty)
    let a = grid[iy*(cells+1)+ix], bb = grid[iy*(cells+1)+ix+1], c = grid[(iy+1)*(cells+1)+ix], d = grid[(iy+1)*(cells+1)+ix+1]
    return (a*(1-sx)+bb*sx)*(1-sy) + (c*(1-sx)+d*sx)*sy
}
let n1 = makeNoise(5, seed: 11), n2 = makeNoise(17, seed: 23), n3 = makeNoise(61, seed: 37)
// creases: straight-ish folds producing a soft light/dark ridge
struct Crease { var x0, y0, x1, y1, strength, width: Double }
var cr = RNG(s: 991)
var creases: [Crease] = []
for _ in 0..<150 {
    let cx = cr.next() * Double(PW), cy = cr.next() * Double(PH), ang = cr.next() * .pi, len = 80 + cr.next() * 520
    creases.append(Crease(x0: cx - cos(ang)*len/2, y0: cy - sin(ang)*len/2, x1: cx + cos(ang)*len/2, y1: cy + sin(ang)*len/2, strength: 1.4 + cr.next() * 3.6, width: 1.0 + cr.next() * 2.6))
}
var grain = RNG(s: 4242)
let base = (247.0, 241.0, 232.0)
for y in 0..<PH { for x in 0..<PW {
    let u = Double(x)/Double(PW), v = Double(y)/Double(PH)
    var l = sample(n1, 5, u, v) * 3.2 + sample(n2, 17, u, v) * 1.8 + sample(n3, 61, u, v) * 1.0
    for c in creases {
        let dx = c.x1 - c.x0, dy = c.y1 - c.y0; let len2 = dx*dx + dy*dy
        let t = max(0, min(1, ((Double(x)-c.x0)*dx + (Double(y)-c.y0)*dy) / len2))
        let px = c.x0 + t*dx, py = c.y0 + t*dy
        let sd = ((Double(x)-c.x0)*dy - (Double(y)-c.y0)*dx) / sqrt(len2) // signed distance
        let along = sin(t * .pi) // fade at ends
        let d = hypot(Double(x)-px, Double(y)-py)
        if d < c.width * 6 { l += (sd > 0 ? 1 : -0.8) * c.strength * exp(-d / c.width) * along }
    }
    // edge vignette
    let ex = min(u, 1-u), ey = min(v, 1-v); l -= max(0, 0.12 - min(ex, ey)) * 22
    l += grain.gauss() * 2.1
    paper.set(x, y, (base.0 + l, base.1 + l, base.2 + l * 0.98))
} }
paper.save(out + "/MadeToKeepPaperTexture.png")

// ---------- 4. App icon ----------
let S = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: S, pixelsHigh: S, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
let gc = NSGraphicsContext(bitmapImageRep: rep)!; NSGraphicsContext.current = gc
let ctx = gc.cgContext
ctx.draw(paper.crop(x: 300, y: 300, w: 1024, h: 1024).cgImage(), in: CGRect(x: 0, y: 0, width: S, height: S))
let burgundy = NSColor(srgbRed: 0x70/255, green: 0x06/255, blue: 0x0B/255, alpha: 1)
func drawCentered(_ text: String, font: NSFont, kern: CGFloat, xScale: CGFloat, baselineY: CGFloat, color: NSColor) {
    let s = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .kern: kern])
    let bnd = s.boundingRect(with: .zero, options: [.usesDeviceMetrics])
    ctx.saveGState(); ctx.translateBy(x: CGFloat(S)/2, y: baselineY); ctx.scaleBy(x: xScale, y: 1)
    s.draw(at: NSPoint(x: -bnd.midX, y: 0)); ctx.restoreGState()
}
let italic = NSFont(name: "BodoniSvtyTwoITCTT-BookIta", size: 330) ?? NSFont(name: "Didot-Italic", size: 330)!
drawCentered("made", font: italic, kern: -0.05 * 330, xScale: 0.86, baselineY: 520, color: burgundy)
drawCentered("to keep", font: italic, kern: -0.05 * 330, xScale: 0.86, baselineY: 250, color: burgundy)
let sans = NSFont.systemFont(ofSize: 54, weight: .regular)
drawCentered("studios", font: sans, kern: 0.36 * 54, xScale: 1, baselineY: 140, color: burgundy)
ctx.setFillColor(burgundy.cgColor); ctx.fill(CGRect(x: S/2 - 44, y: 872, width: 88, height: 4))
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out + "/MadeToKeepAppIcon.png"))
print("done")
