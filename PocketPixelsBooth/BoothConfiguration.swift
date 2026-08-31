//
//  BoothConfiguration.swift
//  PocketPixelsBooth
//
//  Created by marc on 8/30/26.
//

import Foundation

enum BoothConfiguration {
    nonisolated static let photosPerSession = 3
    nonisolated static let countdownSeconds = 3
    nonisolated static let interPhotoDelay: TimeInterval = 1.5
    nonisolated static let capturedPhotoDisplayDuration: TimeInterval = 0.8
    nonisolated static let thankYouDuration: TimeInterval = 8
    nonisolated static let receiptWidth = 576
    nonisolated static let receiptHorizontalMargin = 24
    nonisolated static let receiptMaximumHeight = 3_500
    nonisolated static let defaultPrinterIP = "192.168.0.199"
    nonisolated static let defaultPrinterPort = "9100"
}
