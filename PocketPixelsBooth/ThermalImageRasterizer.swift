//
//  ThermalImageRasterizer.swift
//  PocketPixelsBooth
//
//  Created by marc on 8/30/26.
//

import CoreGraphics
import Foundation
import UIKit

struct ThermalRasterizedImage: Sendable {
    let width: Int
    let height: Int
    let widthBytes: Int
    let previewPNGData: Data
    let rasterData: Data
    let rasterCommand: Data
    let sanitizationReport: RasterSanitizationReport
    let yL: UInt8
    let yH: UInt8
}

enum ThermalRasterizationPurpose: Sendable {
    case photoTest
    case completeReceipt

    nonisolated var maximumHeight: Int {
        switch self {
        case .photoTest:
            1_000
        case .completeReceipt:
            BoothConfiguration.receiptMaximumHeight
        }
    }

    nonisolated var preservesExactWidthWhenPossible: Bool {
        switch self {
        case .photoTest:
            false
        case .completeReceipt:
            true
        }
    }

    nonisolated var preservesSharpExtremes: Bool {
        switch self {
        case .photoTest:
            false
        case .completeReceipt:
            true
        }
    }
}

enum ThermalImageRasterizerError: Error, LocalizedError {
    case invalidImage
    case renderFailed
    case pixelBufferFailed
    case invalidRasterCommand(String)

    var errorDescription: String? {
        switch self {
        case .invalidImage:
            "The selected image could not be read."
        case .renderFailed:
            "The selected image could not be prepared for thermal printing."
        case .pixelBufferFailed:
            "The selected image pixels could not be processed."
        case .invalidRasterCommand(let message):
            message
        }
    }
}

enum ThermalImageRasterizer {
    nonisolated static let printWidth = 576
    nonisolated static let widthBytes = 72

    nonisolated static func rasterize(_ image: UIImage, purpose: ThermalRasterizationPurpose = .photoTest) throws -> ThermalRasterizedImage {
        let canvas = try renderCanvas(from: image, purpose: purpose)
        let pixels = try rgbaPixels(from: canvas.image)
        let dithered = dither(pixels: pixels, width: canvas.width, height: canvas.height, purpose: purpose)
        let unsafeRasterData = packRows(dithered, width: canvas.width, height: canvas.height)
        let sanitized = try RasterCommandSanitizer.sanitizeRasterData(unsafeRasterData)
        let rasterData = sanitized.data
        let previewPNGData = try previewPNG(fromRasterData: rasterData, width: canvas.width, height: canvas.height, widthBytes: widthBytes)
        let rasterCommand = completeRasterCommand(rasterData: rasterData, height: canvas.height)
        try validateRasterCommand(
            rasterCommand,
            imageWidth: canvas.width,
            imageHeight: canvas.height,
            bytesPerRow: widthBytes,
            rasterDataCount: rasterData.count
        )

        let yL = UInt8(canvas.height & 0xFF)
        let yH = UInt8((canvas.height >> 8) & 0xFF)

        return ThermalRasterizedImage(
            width: canvas.width,
            height: canvas.height,
            widthBytes: widthBytes,
            previewPNGData: previewPNGData,
            rasterData: rasterData,
            rasterCommand: rasterCommand,
            sanitizationReport: sanitized.report,
            yL: yL,
            yH: yH
        )
    }

    nonisolated static func photoTestPayloads(for rasterizedImage: ThermalRasterizedImage) -> [Data] {
        [
            photoTestHeading(),
            rasterizedImage.rasterCommand,
            photoTestFinishing()
        ]
    }

    nonisolated static func photoTestHeading() -> Data {
        var heading = Data()
        heading.append(contentsOf: [0x1B, 0x40])
        heading.append(contentsOf: [0x1B, 0x61, 0x01])
        heading.appendASCII("POCKET PIXELS\n")
        heading.appendASCII("Photo raster test\n\n")
        return heading
    }

    nonisolated static func receiptPrintHeading() -> Data {
        Data([0x1B, 0x40])
    }

    nonisolated static func photoTestFinishing() -> Data {
        var finishing = Data()
        finishing.appendASCII("\n\n\n")
        finishing.append(contentsOf: [0x1D, 0x56, 0x42, 0x00])
        return finishing
    }

    nonisolated static func validateRasterCommand(
        _ command: Data,
        imageWidth: Int,
        imageHeight: Int,
        bytesPerRow: Int,
        rasterDataCount: Int
    ) throws {
        guard imageWidth == printWidth else {
            throw ThermalImageRasterizerError.invalidRasterCommand("Thermal image width must be exactly 576 dots.")
        }

        guard bytesPerRow == widthBytes else {
            throw ThermalImageRasterizerError.invalidRasterCommand("Thermal raster width must be exactly 72 bytes per row.")
        }

        guard command.count >= 8 else {
            throw ThermalImageRasterizerError.invalidRasterCommand("The raster command is missing its GS v 0 header.")
        }

        guard command[0] == 0x1D,
              command[1] == 0x76,
              command[2] == 0x30,
              command[3] == 0x00,
              command[4] == 0x48,
              command[5] == 0x00 else {
            throw ThermalImageRasterizerError.invalidRasterCommand("The raster command has an invalid GS v 0 header.")
        }

        let headerHeight = Int(command[6]) + (Int(command[7]) * 256)
        let expectedRasterDataCount = widthBytes * imageHeight
        let expectedCommandCount = 8 + expectedRasterDataCount

        guard headerHeight == imageHeight else {
            throw ThermalImageRasterizerError.invalidRasterCommand("The raster command height does not match the processed image height.")
        }

        guard rasterDataCount == expectedRasterDataCount else {
            throw ThermalImageRasterizerError.invalidRasterCommand("Raster data length is invalid. Expected \(expectedRasterDataCount) bytes, got \(rasterDataCount).")
        }

        guard command.count == expectedCommandCount else {
            throw ThermalImageRasterizerError.invalidRasterCommand("Raster command length is invalid. Expected \(expectedCommandCount) bytes, got \(command.count).")
        }

        let rasterData = command.subdata(in: 8..<command.count)
        do {
            try RasterCommandSanitizer.validateNoReservedPatterns(in: rasterData)
        } catch {
            throw ThermalImageRasterizerError.invalidRasterCommand(error.localizedDescription)
        }

        debugLog("Validated one sanitized raster command for 576x\(imageHeight). Raster bytes: \(rasterDataCount). Command bytes: \(command.count). yL: \(command[6]). yH: \(command[7]).")
    }

    nonisolated private static func renderCanvas(from image: UIImage, purpose: ThermalRasterizationPurpose) throws -> (image: UIImage, width: Int, height: Int) {
        guard image.size.width > 0, image.size.height > 0 else {
            throw ThermalImageRasterizerError.invalidImage
        }

        let sourceWidth = max(1, Int(round(image.size.width * image.scale)))
        let sourceHeight = max(1, Int(round(image.size.height * image.scale)))

        let scale: CGFloat
        if purpose.preservesExactWidthWhenPossible, sourceWidth == printWidth, sourceHeight <= purpose.maximumHeight {
            scale = 1
        } else {
            scale = min(
                CGFloat(printWidth) / image.size.width,
                CGFloat(purpose.maximumHeight) / image.size.height
            )
        }

        let drawSize = CGSize(
            width: max(1, floor(image.size.width * scale)),
            height: max(1, floor(image.size.height * scale))
        )
        let canvasHeight = min(purpose.maximumHeight, max(1, Int(ceil(drawSize.height))))
        let canvasSize = CGSize(width: printWidth, height: canvasHeight)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true

        let renderer = UIGraphicsImageRenderer(size: canvasSize, format: format)
        let rendered = renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: canvasSize))

            let origin = CGPoint(
                x: floor((canvasSize.width - drawSize.width) / 2),
                y: floor((canvasSize.height - drawSize.height) / 2)
            )
            image.draw(in: CGRect(origin: origin, size: drawSize))
        }

        return (rendered, printWidth, canvasHeight)
    }

    nonisolated private static func rgbaPixels(from image: UIImage) throws -> [UInt8] {
        guard let cgImage = image.cgImage else {
            throw ThermalImageRasterizerError.renderFailed
        }

        let width = cgImage.width
        let height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            throw ThermalImageRasterizerError.pixelBufferFailed
        }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixels
    }

    nonisolated private static func dither(pixels: [UInt8], width: Int, height: Int, purpose: ThermalRasterizationPurpose) -> [Bool] {
        var luminance = [Double](repeating: 255, count: width * height)
        var fixedOutput = [Bool?](repeating: nil, count: width * height)

        for index in 0..<(width * height) {
            let pixelIndex = index * 4
            let red = Double(pixels[pixelIndex])
            let green = Double(pixels[pixelIndex + 1])
            let blue = Double(pixels[pixelIndex + 2])
            let value = (0.299 * red) + (0.587 * green) + (0.114 * blue)
            luminance[index] = value

            if purpose.preservesSharpExtremes {
                if value >= 250 {
                    fixedOutput[index] = false
                }
            }
        }

        var output = [Bool](repeating: false, count: width * height)

        for y in 0..<height {
            let movesLeftToRight = y.isMultiple(of: 2)
            let xSequence: any Sequence<Int> = movesLeftToRight ? 0..<width : stride(from: width - 1, through: 0, by: -1)

            for x in xSequence {
                let index = y * width + x
                let oldValue = luminance[index]
                let newValue: Double
                if let fixed = fixedOutput[index] {
                    newValue = fixed ? 0 : 255
                } else {
                    newValue = oldValue < 128 ? 0 : 255
                }
                let error = oldValue - newValue
                output[index] = newValue == 0

                if fixedOutput[index] == nil {
                    let forward = movesLeftToRight ? 1 : -1
                    distribute(error * 7 / 16, x: x + forward, y: y, width: width, height: height, luminance: &luminance)
                    distribute(error * 3 / 16, x: x - forward, y: y + 1, width: width, height: height, luminance: &luminance)
                    distribute(error * 5 / 16, x: x, y: y + 1, width: width, height: height, luminance: &luminance)
                    distribute(error * 1 / 16, x: x + forward, y: y + 1, width: width, height: height, luminance: &luminance)
                }
            }
        }

        return output
    }

    nonisolated private static func distribute(
        _ error: Double,
        x: Int,
        y: Int,
        width: Int,
        height: Int,
        luminance: inout [Double]
    ) {
        guard x >= 0, x < width, y >= 0, y < height else {
            return
        }

        let index = y * width + x
        luminance[index] += error
    }

    nonisolated private static func packRows(_ pixels: [Bool], width: Int, height: Int) -> Data {
        var packed = Data(capacity: widthBytes * height)

        for y in 0..<height {
            for byteIndex in 0..<widthBytes {
                var byte: UInt8 = 0

                for bitIndex in 0..<8 {
                    let x = byteIndex * 8 + bitIndex
                    guard x < width else {
                        continue
                    }

                    if pixels[y * width + x] {
                        byte |= 0x80 >> UInt8(bitIndex)
                    }
                }

                packed.append(byte)
            }
        }

        return packed
    }

    nonisolated private static func completeRasterCommand(rasterData: Data, height: Int) -> Data {
        var command = Data()
        command.append(contentsOf: rasterHeader(height: height))
        command.append(rasterData)
        return command
    }

    nonisolated private static func rasterHeader(height: Int) -> [UInt8] {
        let yL = UInt8(height & 0xFF)
        let yH = UInt8((height >> 8) & 0xFF)
        return [0x1D, 0x76, 0x30, 0x00, UInt8(widthBytes), 0x00, yL, yH]
    }

    nonisolated private static func previewPNG(from pixels: [Bool], width: Int, height: Int) throws -> Data {
        let bytesPerRow = width * 4
        var rgba = [UInt8](repeating: 255, count: width * height * 4)

        for index in pixels.indices {
            let value: UInt8 = pixels[index] ? 0 : 255
            let pixelIndex = index * 4
            rgba[pixelIndex] = value
            rgba[pixelIndex + 1] = value
            rgba[pixelIndex + 2] = value
            rgba[pixelIndex + 3] = 255
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

        guard let context = CGContext(
            data: &rgba,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ), let cgImage = context.makeImage() else {
            throw ThermalImageRasterizerError.renderFailed
        }

        let image = UIImage(cgImage: cgImage, scale: 1, orientation: .up)

        guard let data = image.pngData() else {
            throw ThermalImageRasterizerError.renderFailed
        }

        return data
    }

    nonisolated private static func previewPNG(fromRasterData rasterData: Data, width: Int, height: Int, widthBytes: Int) throws -> Data {
        var pixels = [Bool](repeating: false, count: width * height)

        for y in 0..<height {
            let rowOffset = y * widthBytes

            for x in 0..<width {
                let byteIndex = rowOffset + (x / 8)
                let bitMask = UInt8(0x80) >> UInt8(x % 8)
                pixels[y * width + x] = rasterData[byteIndex] & bitMask != 0
            }
        }

        return try previewPNG(from: pixels, width: width, height: height)
    }

    nonisolated private static func clamp(_ value: Double) -> Double {
        min(255, max(0, value))
    }
}

extension Data {
    nonisolated mutating func appendASCII(_ string: String) {
        if let bytes = string.data(using: .ascii, allowLossyConversion: true) {
            append(bytes)
        }
    }
}

nonisolated private func debugLog(_ message: String) {
#if DEBUG
    print("[ThermalImageRasterizer] \(message)")
#endif
}
