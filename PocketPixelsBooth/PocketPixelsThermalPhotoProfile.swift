//
//  PocketPixelsThermalPhotoProfile.swift
//  PocketPixelsBooth
//

import Foundation

struct PocketPixelsThermalPhotoProfile: Identifiable, Equatable, Hashable, Sendable {
    let id: String
    let displayName: String
    let brightness: Float
    let contrast: Float
    let gammaPower: Float

    nonisolated static let neutral = PocketPixelsThermalPhotoProfile(
        id: "neutral",
        displayName: "Current Baseline",
        brightness: 0,
        contrast: 1,
        gammaPower: 1
    )

    nonisolated static let failedLocalPortrait = PocketPixelsThermalPhotoProfile(
        id: "failedLocalPortrait",
        displayName: "Failed Local Fix",
        brightness: 0.070,
        contrast: 0.925,
        gammaPower: 0.76
    )

    nonisolated static let productionPortrait = PocketPixelsThermalPhotoProfile(
        id: "productionPortrait",
        displayName: "Repaired Portrait",
        brightness: 0.020,
        contrast: 1.060,
        gammaPower: 0.88
    )

    nonisolated static let light1 = PocketPixelsThermalPhotoProfile(
        id: "light1",
        displayName: "Light 1",
        brightness: 0.050,
        contrast: 0.965,
        gammaPower: 0.91
    )

    nonisolated static let light2 = PocketPixelsThermalPhotoProfile(
        id: "light2",
        displayName: "Light 2",
        brightness: 0.090,
        contrast: 0.940,
        gammaPower: 0.84
    )

    nonisolated static let light3 = PocketPixelsThermalPhotoProfile(
        id: "light3",
        displayName: "Light 3",
        brightness: 0.130,
        contrast: 0.915,
        gammaPower: 0.78
    )

    nonisolated static let customerPrintDefault = productionPortrait

#if DEBUG
    nonisolated static let debugCandidates = [neutral, light1, light2, light3, failedLocalPortrait, productionPortrait]
#endif

    nonisolated var parametersDescription: String {
        "B +\(brightness.formatted(.number.precision(.fractionLength(3)))) C \(contrast.formatted(.number.precision(.fractionLength(3)))) G \(gammaPower.formatted(.number.precision(.fractionLength(2))))"
    }

    nonisolated var toneSampleDescription: String {
        [0.25, 0.50, 0.75]
            .map { sample in
                let adjusted = ThermalPhotoProcessor.adjustedUnitLuminance(sample, profile: self)
                return "\(Int(round(sample * 255)))->\(Int(round(adjusted * 255)))"
            }
            .joined(separator: ", ")
    }

    nonisolated var isNeutral: Bool {
        brightness == 0 && contrast == 1 && gammaPower == 1
    }
}
