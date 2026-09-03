//
//  ThermalPhotoCalibrationProfile.swift
//  PocketPixelsBooth
//

#if DEBUG
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import UIKit

struct ThermalPhotoCalibrationProfile: Identifiable, Equatable, Hashable {
    let id: String
    let displayName: String
    let brightness: Float
    let contrast: Float
    let gammaPower: Float

    nonisolated static let original = ThermalPhotoCalibrationProfile(
        id: "original",
        displayName: "Original",
        brightness: 0,
        contrast: 1,
        gammaPower: 1
    )

    nonisolated static let light = ThermalPhotoCalibrationProfile(
        id: "light",
        displayName: "Light",
        brightness: 0.05,
        contrast: 0.96,
        gammaPower: 0.90
    )

    nonisolated static let lighter = ThermalPhotoCalibrationProfile(
        id: "lighter",
        displayName: "Lighter",
        brightness: 0.10,
        contrast: 0.92,
        gammaPower: 0.82
    )

    nonisolated static let portrait = ThermalPhotoCalibrationProfile(
        id: "portrait",
        displayName: "Portrait",
        brightness: 0.07,
        contrast: 0.94,
        gammaPower: 0.78
    )

    nonisolated static let allPresets = [original, light, lighter, portrait]

    nonisolated var parametersDescription: String {
        "Brightness \(brightness.formatted(.number.precision(.fractionLength(2)))), contrast \(contrast.formatted(.number.precision(.fractionLength(2)))), gamma \(gammaPower.formatted(.number.precision(.fractionLength(2))))"
    }

    nonisolated func apply(to image: UIImage) throws -> UIImage {
        guard id != "original" else {
            return image
        }

        guard let inputImage = CIImage(image: image) else {
            throw ThermalImageRasterizerError.invalidImage
        }

        let colorControls = CIFilter.colorControls()
        colorControls.inputImage = inputImage
        colorControls.brightness = brightness
        colorControls.contrast = contrast
        colorControls.saturation = 1

        guard let colorAdjustedImage = colorControls.outputImage else {
            throw ThermalImageRasterizerError.renderFailed
        }

        let gammaAdjust = CIFilter.gammaAdjust()
        gammaAdjust.inputImage = colorAdjustedImage
        gammaAdjust.power = gammaPower

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
#endif
