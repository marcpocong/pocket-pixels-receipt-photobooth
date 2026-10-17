// Run from the repository root: swift Tools/ReceiptFooter/MakeComparisons.swift
// These images use the production raster previews emitted by ReceiptFooterModeTests.
import AppKit
import CoreText
import ImageIO
import UniformTypeIdentifiers

let directory = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "BuildArtifacts/GalleryFooter", isDirectory: true)
let styles = ["classicBarcodeAndGalleryQR", "integratedGalleryQR", "decorativeBarcodeOnly"]
let labels = ["Before / Classic + QR", "After / Integrated QR", "Decorative Only"]
for format in ["solo", "strip", "passport"] {
    for logo in ["false", "true"] {
        let images = try styles.map { style -> CGImage in
            let url = directory.appendingPathComponent("\(format)_\(style)_logo_\(logo)_1bit.png")
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw NSError(domain: "Missing receipt artifact: \(url.lastPathComponent)", code: 1)
            }
            return image
        }
        let width = 576 * 3 + 48, height = images.map(\.height).max()! + 64
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(gray: 0.92, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for (index, image) in images.enumerated() {
            let x = index * 592
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: x, y: height - 48 - image.height, width: image.width, height: image.height))
            let label = NSAttributedString(string: labels[index], attributes: [.font: NSFont.systemFont(ofSize: 19), .foregroundColor: NSColor.black])
            context.textPosition = CGPoint(x: x + 16, y: height - 28)
            CTLineDraw(CTLineCreateWithAttributedString(label), context)
        }
        let target = directory.appendingPathComponent("comparison_\(format)_logo_\(logo).png")
        let destination = CGImageDestinationCreateWithURL(target as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        guard CGImageDestinationFinalize(destination) else { fatalError("Could not write comparison") }
        print(target.lastPathComponent)
    }
}
