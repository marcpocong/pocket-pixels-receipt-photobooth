//
//  ThermalPhotoProcessor.swift
//  PocketPixelsBooth
//

import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import UIKit

enum ThermalPhotoPresentationMode: Sendable {
    case portrait
    case landscape

    nonisolated var aspectRatio: CGSize {
        switch self {
        case .portrait:
            CGSize(width: 3, height: 4)
        case .landscape:
            CGSize(width: 4, height: 3)
        }
    }
}

struct ThermalPreparedPhoto {
    let image: UIImage
    let sourcePixelSize: CGSize
    let normalizedPixelSize: CGSize
    let croppedPixelSize: CGSize
    let finalPixelSize: CGSize
    let effectiveScale: CGFloat
    let profile: PocketPixelsThermalPhotoProfile
}

enum ThermalPhotoProcessor {
    nonisolated static func prepare(
        _ sourceImage: UIImage,
        targetPixelSize: CGSize,
        presentationMode: ThermalPhotoPresentationMode,
        profile: PocketPixelsThermalPhotoProfile = .neutral
    ) throws -> ThermalPreparedPhoto {
        guard targetPixelSize.width > 0, targetPixelSize.height > 0 else {
            throw ThermalImageRasterizerError.invalidImage
        }

        let sourcePixelSize = pixelSize(of: sourceImage)
        let normalized = normalizedImage(sourceImage, opaque: true)
        let normalizedPixelSize = pixelSize(of: normalized)
        let cropped = try centerCroppedImage(
            normalized,
            aspectRatio: presentationMode.aspectRatio
        )
        let croppedPixelSize = pixelSize(of: cropped)
        let finalSize = CGSize(
            width: max(1, floor(targetPixelSize.width)),
            height: max(1, floor(targetPixelSize.height))
        )
        let resized = resizedImage(cropped, to: finalSize)
        let profiled = try apply(profile, to: resized)

        return ThermalPreparedPhoto(
            image: profiled,
            sourcePixelSize: sourcePixelSize,
            normalizedPixelSize: normalizedPixelSize,
            croppedPixelSize: croppedPixelSize,
            finalPixelSize: finalSize,
            effectiveScale: finalSize.width / max(1, croppedPixelSize.width),
            profile: profile
        )
    }

    nonisolated static func pixelSize(of image: UIImage) -> CGSize {
        if let cgImage = image.cgImage {
            return CGSize(width: cgImage.width, height: cgImage.height)
        }

        return CGSize(
            width: max(1, floor(image.size.width * image.scale)),
            height: max(1, floor(image.size.height * image.scale))
        )
    }

    nonisolated private static func normalizedImage(_ image: UIImage, opaque: Bool) -> UIImage {
        let pixelSize = pixelSize(of: image)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = opaque

        let renderer = UIGraphicsImageRenderer(size: pixelSize, format: format)
        return renderer.image { context in
            if opaque {
                UIColor.white.setFill()
                context.fill(CGRect(origin: .zero, size: pixelSize))
            }
            image.draw(in: CGRect(origin: .zero, size: pixelSize))
        }
    }

    nonisolated private static func centerCroppedImage(_ image: UIImage, aspectRatio: CGSize) throws -> UIImage {
        guard let cgImage = image.cgImage,
              image.size.width > 0,
              image.size.height > 0,
              aspectRatio.width > 0,
              aspectRatio.height > 0 else {
            throw ThermalImageRasterizerError.invalidImage
        }

        let sourceSize = CGSize(width: cgImage.width, height: cgImage.height)
        let targetRatio = aspectRatio.width / aspectRatio.height
        let sourceRatio = sourceSize.width / sourceSize.height
        let cropSize: CGSize

        if sourceRatio > targetRatio {
            cropSize = CGSize(width: floor(sourceSize.height * targetRatio), height: sourceSize.height)
        } else {
            cropSize = CGSize(width: sourceSize.width, height: floor(sourceSize.width / targetRatio))
        }

        let cropRect = CGRect(
            x: floor((sourceSize.width - cropSize.width) / 2),
            y: floor((sourceSize.height - cropSize.height) / 2),
            width: cropSize.width,
            height: cropSize.height
        )

        guard let cropped = cgImage.cropping(to: cropRect) else {
            throw ThermalImageRasterizerError.renderFailed
        }

        return UIImage(cgImage: cropped, scale: 1, orientation: .up)
    }

    nonisolated private static func resizedImage(_ image: UIImage, to targetSize: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true

        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        return renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: targetSize))
            context.cgContext.interpolationQuality = .high
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }

    nonisolated private static func apply(_ profile: PocketPixelsThermalPhotoProfile, to image: UIImage) throws -> UIImage {
        guard !profile.isNeutral else {
            return image
        }

        guard let inputImage = CIImage(image: image) else {
            throw ThermalImageRasterizerError.invalidImage
        }

        let colorControls = CIFilter.colorControls()
        colorControls.inputImage = inputImage
        colorControls.brightness = profile.brightness
        colorControls.contrast = profile.contrast
        colorControls.saturation = 1

        guard let colorAdjustedImage = colorControls.outputImage else {
            throw ThermalImageRasterizerError.renderFailed
        }

        let gammaAdjust = CIFilter.gammaAdjust()
        gammaAdjust.inputImage = colorAdjustedImage
        gammaAdjust.power = profile.gammaPower

        guard let outputImage = gammaAdjust.outputImage else {
            throw ThermalImageRasterizerError.renderFailed
        }

        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let cgImage = context.createCGImage(outputImage, from: inputImage.extent) else {
            throw ThermalImageRasterizerError.renderFailed
        }

        return UIImage(cgImage: cgImage, scale: image.scale, orientation: image.imageOrientation)
    }
}
