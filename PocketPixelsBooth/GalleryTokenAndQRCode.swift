//
//  GalleryTokenAndQRCode.swift
//  PocketPixelsBooth
//

import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import Security
import UIKit

enum GalleryTokenGenerator {
    nonisolated static func makeGalleryToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw GalleryUploadError.configuration("Secure gallery token generation failed with status \(status).")
        }

        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func isValidGalleryToken(_ token: String) -> Bool {
        token.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil
    }

    nonisolated static func redacted(_ token: String) -> String {
        guard token.count > 12 else {
            return "<redacted>"
        }

        return "\(token.prefix(6))...\(token.suffix(6))"
    }
}

enum GalleryURLBuilder {
    nonisolated static func canonicalCustomerGalleryBaseURL(_ baseURL: URL) throws -> URL {
        var absoluteString = baseURL.absoluteString.trimmingCharacters(in: .whitespacesAndNewlines)
        while absoluteString.hasSuffix("/") {
            absoluteString.removeLast()
        }

        guard var components = URLComponents(string: absoluteString) else {
            throw GalleryUploadError.invalidGalleryURL
        }
        components.query = nil
        components.fragment = nil
        if components.path.isEmpty {
            components.path = "/"
        }

        guard let url = components.url else {
            throw GalleryUploadError.invalidGalleryURL
        }
        return url
    }

    nonisolated static func canonicalWebAppURL(_ webAppURL: URL) throws -> URL {
        var absoluteString = webAppURL.absoluteString.trimmingCharacters(in: .whitespacesAndNewlines)
        absoluteString = absoluteString.replacingOccurrences(
            of: #"/macros/u/[0-9]+/s/"#,
            with: "/macros/s/",
            options: .regularExpression
        )
        while absoluteString.hasSuffix("/") {
            absoluteString.removeLast()
        }

        guard var components = URLComponents(string: absoluteString) else {
            throw GalleryUploadError.invalidGalleryURL
        }
        components.query = nil
        components.fragment = nil

        guard let url = components.url else {
            throw GalleryUploadError.invalidGalleryURL
        }
        return url
    }

    nonisolated static func makeGalleryURL(customerGalleryBaseURL: URL, galleryToken: String) throws -> URL {
        guard GalleryTokenGenerator.isValidGalleryToken(galleryToken) else {
            throw GalleryUploadError.invalidGalleryToken
        }

        let canonicalBaseURL = try canonicalCustomerGalleryBaseURL(customerGalleryBaseURL)
        _ = try CustomerGalleryConfiguration.validate(rawValue: canonicalBaseURL.absoluteString)

        var components = URLComponents(url: canonicalBaseURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "g", value: galleryToken)
        ]

        guard let url = components?.url,
              validateGalleryURL(url, customerGalleryBaseURL: canonicalBaseURL, galleryToken: galleryToken) else {
            throw GalleryUploadError.invalidGalleryURL
        }

        return url
    }

    nonisolated static func validateGalleryURL(_ url: URL, customerGalleryBaseURL: URL, galleryToken: String) -> Bool {
        guard let canonicalBaseURL = try? canonicalCustomerGalleryBaseURL(customerGalleryBaseURL) else {
            return false
        }

        guard GalleryTokenGenerator.isValidGalleryToken(galleryToken),
              url.scheme?.lowercased() == "https",
              url.host()?.lowercased() == canonicalBaseURL.host()?.lowercased(),
              url.host()?.lowercased() != "script.google.com",
              url.path == canonicalBaseURL.path,
              !url.path.contains("/macros/u/"),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems,
              queryItems.count == 1,
              queryItems.filter({ $0.name == "g" && $0.value == galleryToken }).count == 1 else {
            return false
        }

        return (try? CustomerGalleryConfiguration.validate(rawValue: canonicalBaseURL.absoluteString)) != nil
    }
}

enum GalleryQRCodeGenerator {
    nonisolated static let pixelSize = 384
    nonisolated static let correctionLevel = "M"
    nonisolated static let quietZoneModules = 4

    nonisolated static func makeQRCodeImage(for galleryURL: URL, pixelSize: Int = Self.pixelSize) throws -> UIImage {
        guard galleryURL.scheme?.lowercased() == "https" else {
            throw GalleryUploadError.invalidGalleryURL
        }

        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(galleryURL.absoluteString.utf8)
        filter.correctionLevel = correctionLevel

        guard let outputImage = filter.outputImage else {
            throw GalleryUploadError.qrGeneration("QR output image could not be created.")
        }

        let colorFilter = CIFilter.falseColor()
        colorFilter.inputImage = outputImage
        colorFilter.color0 = CIColor(red: 0, green: 0, blue: 0, alpha: 1)
        colorFilter.color1 = CIColor(red: 1, green: 1, blue: 1, alpha: 1)

        guard let coloredImage = colorFilter.outputImage else {
            throw GalleryUploadError.qrGeneration("QR colors could not be applied.")
        }

        let extent = coloredImage.extent.integral
        let modulesWithQuietZone = max(extent.width, extent.height) + CGFloat(quietZoneModules * 2)
        let scale = max(1, floor(CGFloat(pixelSize) / modulesWithQuietZone))
        let transformedImage = coloredImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext(options: [.workingColorSpace: CGColorSpaceCreateDeviceRGB()])

        guard let cgImage = context.createCGImage(transformedImage, from: transformedImage.extent) else {
            throw GalleryUploadError.qrGeneration("QR image could not be rendered.")
        }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let size = CGSize(width: pixelSize, height: pixelSize)
        let scaledMatrixSize = CGSize(width: CGFloat(cgImage.width), height: CGFloat(cgImage.height))
        let quietZoneOffset = CGFloat(quietZoneModules) * scale
        let scaledTotalSize = CGSize(
            width: scaledMatrixSize.width + quietZoneOffset * 2,
            height: scaledMatrixSize.height + quietZoneOffset * 2
        )
        let totalOrigin = CGPoint(
            x: floor((size.width - scaledTotalSize.width) / 2),
            y: floor((size.height - scaledTotalSize.height) / 2)
        )
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            context.cgContext.interpolationQuality = .none
            UIImage(cgImage: cgImage, scale: 1, orientation: .up).draw(in: CGRect(origin: CGPoint(x: totalOrigin.x + quietZoneOffset, y: totalOrigin.y + quietZoneOffset), size: scaledMatrixSize))
        }
    }
}
