// Converts the official Made to Keep Studios MTK monogram into the receipt print asset.
//
//   swiftc -O Tools/MadeToKeepAssets/GenerateReceiptMonogram.swift -o /tmp/mtk-monogram
//   /tmp/mtk-monogram Tools/MadeToKeepAssets/Source/MadeToKeepMonogram-official.png \
//       PocketPixelsBooth/Assets.xcassets/MadeToKeepMonogram.imageset/MadeToKeepMonogram.png
//
// The output keeps the artwork's exact lettering and proportions: ink coverage is measured from
// each pixel's distance to the white paper, written as the alpha of pure black, and the canvas is
// cropped to the ink bounds plus a small transparent margin. No resampling happens here; the
// receipt renderer scales it to printer dots and protects the hairlines at that size.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: GenerateReceiptMonogram <source.png> <output.png>\n".utf8))
    exit(2)
}

guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: arguments[1]) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    FileHandle.standardError.write(Data("Could not read \(arguments[1])\n".utf8))
    exit(1)
}

let width = image.width
let height = image.height
var rgba = [UInt8](repeating: 0, count: width * height * 4)
let colorSpace = CGColorSpaceCreateDeviceRGB()
guard let input = CGContext(data: &rgba, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }
// Composite onto white so transparent sources and JPEG-style flattened sources behave alike.
input.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
input.fill(CGRect(x: 0, y: 0, width: width, height: height))
input.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

// Paper is the brightest tone; ink is the darkest solid stroke tone. Coverage is linear between.
var luminance = [Double](repeating: 1, count: width * height)
for index in 0..<(width * height) {
    let r = Double(rgba[index * 4]), g = Double(rgba[index * 4 + 1]), b = Double(rgba[index * 4 + 2])
    luminance[index] = (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255
}
let sorted = luminance.sorted()
let inkTone = sorted[Int(Double(sorted.count) * 0.01)]
let paperTone = sorted[Int(Double(sorted.count) * 0.60)]
let span = max(0.05, paperTone - inkTone)

var coverage = [UInt8](repeating: 0, count: width * height)
var minX = width, minY = height, maxX = -1, maxY = -1
for y in 0..<height {
    for x in 0..<width {
        let index = y * width + x
        let value = min(1, max(0, (paperTone - luminance[index]) / span))
        // Paper noise and JPEG halos below 8% are not ink.
        let alpha = value < 0.08 ? 0 : UInt8((value * 255).rounded())
        coverage[index] = alpha
        if alpha > 64 {
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
        }
    }
}
guard maxX >= minX, maxY >= minY else {
    FileHandle.standardError.write(Data("No ink found in \(arguments[1])\n".utf8))
    exit(1)
}

let margin = 8
let cropX = max(0, minX - margin), cropY = max(0, minY - margin)
let cropWidth = min(width, maxX + margin + 1) - cropX
let cropHeight = min(height, maxY + margin + 1) - cropY
var output = [UInt8](repeating: 0, count: cropWidth * cropHeight * 4)
for y in 0..<cropHeight {
    for x in 0..<cropWidth {
        // Premultiplied black: colour channels stay 0, alpha carries the coverage.
        output[(y * cropWidth + x) * 4 + 3] = coverage[(y + cropY) * width + (x + cropX)]
    }
}

guard let outputContext = CGContext(data: &output, width: cropWidth, height: cropHeight, bitsPerComponent: 8,
                                    bytesPerRow: cropWidth * 4, space: colorSpace,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
      let result = outputContext.makeImage(),
      let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: arguments[2]) as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    exit(1)
}
CGImageDestinationAddImage(destination, result, nil)
guard CGImageDestinationFinalize(destination) else { exit(1) }
print("Wrote \(cropWidth)x\(cropHeight) monogram (ink \(String(format: "%.2f", inkTone)), paper \(String(format: "%.2f", paperTone)))")
