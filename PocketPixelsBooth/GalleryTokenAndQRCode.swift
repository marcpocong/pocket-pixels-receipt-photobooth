//
//  GalleryTokenAndQRCode.swift
//  PocketPixelsBooth
//

import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import Security
import UIKit

struct QRCodeRenderMetrics: Sendable {
    let matrixModules: Int
    let quietZoneModules: Int
    let moduleScale: Int
    let pixelSize: Int
    let renderedMatrixPixelSize: Int
    let renderedTotalPixelSize: Int
}

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

    /// Recovers the customer gallery front door that `galleryURL` was generated from, or nil when
    /// it is not a valid `<base>?g=<galleryToken>` URL. Lets frozen session URLs be reproduced
    /// exactly even after the configured front door has changed.
    nonisolated static func customerGalleryBaseURL(ofGalleryURL galleryURL: URL, galleryToken: String) -> URL? {
        guard var components = URLComponents(url: galleryURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.query = nil
        components.fragment = nil
        guard let rawBaseURL = components.url,
              let baseURL = try? canonicalCustomerGalleryBaseURL(rawBaseURL),
              validateGalleryURL(galleryURL, customerGalleryBaseURL: baseURL, galleryToken: galleryToken) else {
            return nil
        }
        return baseURL
    }

    /// True when both URLs are valid gallery links for the same token, regardless of which
    /// supported front door (legacy Pocket Pixels or Made to Keep) each one uses.
    nonisolated static func identifiesSameGallery(_ lhs: URL, _ rhs: URL, galleryToken: String) -> Bool {
        customerGalleryBaseURL(ofGalleryURL: lhs, galleryToken: galleryToken) != nil
            && customerGalleryBaseURL(ofGalleryURL: rhs, galleryToken: galleryToken) != nil
    }
}

enum GalleryQRCodeGenerator {
    nonisolated static let pixelSize = 384
    nonisolated static let correctionLevel = "M"
    nonisolated static let quietZoneModules = 4

    nonisolated static func makeRenderMetrics(for galleryURL: URL, pixelSize: Int = Self.pixelSize) throws -> QRCodeRenderMetrics {
        let outputImage = try makeQRCodeOutputImage(for: galleryURL)
        let extent = outputImage.extent.integral
        let matrixModules = Int(max(extent.width, extent.height))
        let totalModules = matrixModules + quietZoneModules * 2
        guard pixelSize >= totalModules else {
            throw GalleryUploadError.qrGeneration("The QR allocation cannot contain the matrix and its white quiet zone.")
        }
        let moduleScale = Int(floor(CGFloat(pixelSize) / CGFloat(totalModules)))
        return QRCodeRenderMetrics(
            matrixModules: matrixModules,
            quietZoneModules: quietZoneModules,
            moduleScale: moduleScale,
            pixelSize: pixelSize,
            renderedMatrixPixelSize: matrixModules * moduleScale,
            renderedTotalPixelSize: totalModules * moduleScale
        )
    }

    nonisolated static func moduleAlignedPixelSize(for galleryURL: URL, moduleScale: Int) throws -> Int {
        let outputImage = try makeQRCodeOutputImage(for: galleryURL)
        let extent = outputImage.extent.integral
        let matrixModules = Int(max(extent.width, extent.height))
        return (matrixModules + quietZoneModules * 2) * max(1, moduleScale)
    }

    nonisolated static func makeQRCodeImage(for galleryURL: URL, pixelSize: Int = Self.pixelSize) throws -> UIImage {
        guard galleryURL.scheme?.lowercased() == "https" else {
            throw GalleryUploadError.invalidGalleryURL
        }

        let outputImage = try makeQRCodeOutputImage(for: galleryURL)

        let colorFilter = CIFilter.falseColor()
        colorFilter.inputImage = outputImage
        colorFilter.color0 = CIColor(red: 0, green: 0, blue: 0, alpha: 1)
        colorFilter.color1 = CIColor(red: 1, green: 1, blue: 1, alpha: 1)

        guard let coloredImage = colorFilter.outputImage else {
            throw GalleryUploadError.qrGeneration("QR colors could not be applied.")
        }

        let extent = coloredImage.extent.integral
        let modulesWithQuietZone = max(extent.width, extent.height) + CGFloat(quietZoneModules * 2)
        guard CGFloat(pixelSize) >= modulesWithQuietZone else {
            throw GalleryUploadError.qrGeneration("The QR allocation cannot contain the matrix and its white quiet zone.")
        }
        let scale = floor(CGFloat(pixelSize) / modulesWithQuietZone)
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

    nonisolated private static func makeQRCodeOutputImage(for galleryURL: URL) throws -> CIImage {
        guard galleryURL.scheme?.lowercased() == "https" else {
            throw GalleryUploadError.invalidGalleryURL
        }

        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(galleryURL.absoluteString.utf8)
        filter.correctionLevel = correctionLevel

        guard let outputImage = filter.outputImage else {
            throw GalleryUploadError.qrGeneration("QR output image could not be created.")
        }

        // Core Image currently includes one white module around its QR matrix (e.g. a
        // 49-module symbol has a 51-pixel extent). Remove that native border before adding
        // our explicit four-module quiet zone, so metrics describe the actual QR matrix.
        // QR symbol edges are 21 + 4n; retain already-unbordered output on other OS versions.
        let extent = outputImage.extent.integral
        if Int(extent.width) >= 23, Int(extent.width) % 4 == 3, extent.width == extent.height {
            return outputImage.cropped(to: extent.insetBy(dx: 1, dy: 1))
        }
        return outputImage
    }
}
