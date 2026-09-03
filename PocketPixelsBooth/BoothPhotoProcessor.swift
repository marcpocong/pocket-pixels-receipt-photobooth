//
//  BoothPhotoProcessor.swift
//  PocketPixelsBooth
//

import UIKit

enum BoothPhotoProcessor {
    nonisolated static let aspectRatio = CGSize(width: 3, height: 4)

    nonisolated static func normalizedPortraitPhoto(from image: UIImage) -> UIImage {
        let oriented = image.normalizedBoothOrientation(opaque: true)
        guard oriented.size.width > 0, oriented.size.height > 0 else {
            return oriented
        }

        var cropWidth = Int(floor(min(oriented.size.width, oriented.size.height * aspectRatio.width / aspectRatio.height)))
        cropWidth -= cropWidth % Int(aspectRatio.width)
        cropWidth = max(Int(aspectRatio.width), cropWidth)
        var cropHeight = cropWidth * Int(aspectRatio.height) / Int(aspectRatio.width)
        while CGFloat(cropHeight) > oriented.size.height, cropWidth > Int(aspectRatio.width) {
            cropWidth -= Int(aspectRatio.width)
            cropHeight = cropWidth * Int(aspectRatio.height) / Int(aspectRatio.width)
        }
        let cropSize = CGSize(width: cropWidth, height: cropHeight)

        let cropRect = CGRect(
            x: floor((oriented.size.width - cropSize.width) / 2),
            y: floor((oriented.size.height - cropSize.height) / 2),
            width: cropSize.width,
            height: cropSize.height
        )

        guard let cropped = oriented.cgImage?.cropping(to: cropRect) else {
            return oriented
        }

        return UIImage(cgImage: cropped, scale: 1, orientation: .up).redrawnBoothImage(opaque: true)
    }
}

private extension UIImage {
    nonisolated func normalizedBoothOrientation(opaque: Bool) -> UIImage {
        let pixelSize: CGSize
        if imageOrientation == .up, let cgImage {
            pixelSize = CGSize(width: cgImage.width, height: cgImage.height)
        } else {
            pixelSize = CGSize(
                width: max(1, floor(size.width * scale)),
                height: max(1, floor(size.height * scale))
            )
        }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = opaque

        let renderer = UIGraphicsImageRenderer(size: pixelSize, format: format)
        return renderer.image { context in
            if opaque {
                UIColor.white.setFill()
                context.fill(CGRect(origin: .zero, size: pixelSize))
            }
            draw(in: CGRect(origin: .zero, size: pixelSize))
        }
    }

    nonisolated func redrawnBoothImage(opaque: Bool) -> UIImage {
        let pixelSize: CGSize
        if let cgImage {
            pixelSize = CGSize(width: cgImage.width, height: cgImage.height)
        } else {
            pixelSize = CGSize(width: max(1, floor(size.width * scale)), height: max(1, floor(size.height * scale)))
        }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = opaque

        let renderer = UIGraphicsImageRenderer(size: pixelSize, format: format)
        return renderer.image { context in
            if opaque {
                UIColor.white.setFill()
                context.fill(CGRect(origin: .zero, size: pixelSize))
            }
            draw(in: CGRect(origin: .zero, size: pixelSize))
        }
    }
}
