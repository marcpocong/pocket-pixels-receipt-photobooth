//
//  PrintJobEnvelope.swift
//  PocketPixelsBooth
//

import CryptoKit
import Foundation

enum PrintJobSource: String, Codable, Sendable, CaseIterable {
    case liveCustomer
    case archivedReprint
    case diagnostic

    var displayName: String {
        switch self {
        case .liveCustomer:
            "Live Customer"
        case .archivedReprint:
            "Archived Reprint"
        case .diagnostic:
            "Diagnostic"
        }
    }
}

enum ProductionPrintTransportPolicy: String, Codable, Sendable, CaseIterable, Identifiable {
    case safeIntegrity
    case experimentalBalanced
    case fastDiagnostic

    var id: String { rawValue }

    var bluetoothMode: BluetoothPrinterRasterMode {
        switch self {
        case .safeIntegrity:
            .reliable
        case .experimentalBalanced:
            .balanced
        case .fastDiagnostic:
            .fast
        }
    }

    var displayName: String {
        switch self {
        case .safeIntegrity:
            "Safe / Integrity"
        case .experimentalBalanced:
            "Experimental Balanced"
        case .fastDiagnostic:
            "Fast Diagnostic"
        }
    }
}

struct PrintJobEnvelope: Identifiable, Sendable {
    let jobID: UUID
    let batchID: UUID
    let sessionIdentifier: String
    let source: PrintJobSource
    let copyIndex: Int
    let copyCount: Int
    let createdAt: Date
    let transportPolicy: ProductionPrintTransportPolicy
    let payload: Data
    let payloadFingerprint: String
    let payloadByteCount: Int
    let imageWidth: Int
    let imageHeight: Int
    let rasterByteCount: Int
    let rasterCommandByteCount: Int
    let rasterDataRange: Range<Int>
    let sanitizationReport: RasterSanitizationReport

    var id: UUID { jobID }

    static func receipt(
        rasterizedImage: ThermalRasterizedImage,
        sessionIdentifier: String,
        source: PrintJobSource,
        copyIndex: Int,
        copyCount: Int,
        batchID: UUID,
        transportPolicy: ProductionPrintTransportPolicy
    ) throws -> PrintJobEnvelope {
        let heading = ThermalImageRasterizer.receiptPrintHeading()
        let finishing = ThermalImageRasterizer.photoTestFinishing()
        return try make(
            heading: heading,
            rasterizedImage: rasterizedImage,
            finishing: finishing,
            sessionIdentifier: sessionIdentifier,
            source: source,
            copyIndex: copyIndex,
            copyCount: copyCount,
            batchID: batchID,
            transportPolicy: transportPolicy
        )
    }

    static func diagnostic(
        heading: Data,
        rasterizedImage: ThermalRasterizedImage,
        finishing: Data,
        sessionIdentifier: String,
        copyIndex: Int,
        copyCount: Int,
        batchID: UUID,
        transportPolicy: ProductionPrintTransportPolicy
    ) throws -> PrintJobEnvelope {
        try make(
            heading: heading,
            rasterizedImage: rasterizedImage,
            finishing: finishing,
            sessionIdentifier: sessionIdentifier,
            source: .diagnostic,
            copyIndex: copyIndex,
            copyCount: copyCount,
            batchID: batchID,
            transportPolicy: transportPolicy
        )
    }

    func verifyPayloadIntegrity() throws {
        let actualFingerprint = payload.sha256HexString
        guard actualFingerprint == payloadFingerprint,
              payload.count == payloadByteCount else {
            throw PrintJobEnvelopeError.payloadIntegrityMismatch
        }
    }

    private static func make(
        heading: Data,
        rasterizedImage: ThermalRasterizedImage,
        finishing: Data,
        sessionIdentifier: String,
        source: PrintJobSource,
        copyIndex: Int,
        copyCount: Int,
        batchID: UUID,
        transportPolicy: ProductionPrintTransportPolicy
    ) throws -> PrintJobEnvelope {
        try ThermalImageRasterizer.validateRasterCommand(
            rasterizedImage.rasterCommand,
            imageWidth: rasterizedImage.width,
            imageHeight: rasterizedImage.height,
            bytesPerRow: rasterizedImage.widthBytes,
            rasterDataCount: rasterizedImage.rasterData.count
        )
        try RasterCommandSanitizer.validateOutboundJob(
            heading: heading,
            rasterCommand: rasterizedImage.rasterCommand,
            finishing: finishing,
            rasterDataRange: 8..<rasterizedImage.rasterCommand.count
        )

        var payload = Data(capacity: heading.count + rasterizedImage.rasterCommand.count + finishing.count)
        payload.append(heading)
        payload.append(rasterizedImage.rasterCommand)
        payload.append(finishing)

        return PrintJobEnvelope(
            jobID: UUID(),
            batchID: batchID,
            sessionIdentifier: sessionIdentifier,
            source: source,
            copyIndex: copyIndex,
            copyCount: copyCount,
            createdAt: Date(),
            transportPolicy: transportPolicy,
            payload: payload,
            payloadFingerprint: payload.sha256HexString,
            payloadByteCount: payload.count,
            imageWidth: rasterizedImage.width,
            imageHeight: rasterizedImage.height,
            rasterByteCount: rasterizedImage.rasterData.count,
            rasterCommandByteCount: rasterizedImage.rasterCommand.count,
            rasterDataRange: heading.count + 8..<heading.count + rasterizedImage.rasterCommand.count,
            sanitizationReport: rasterizedImage.sanitizationReport
        )
    }
}

enum PrintJobEnvelopeError: Error, LocalizedError {
    case payloadIntegrityMismatch

    var errorDescription: String? {
        switch self {
        case .payloadIntegrityMismatch:
            "Print payload integrity check failed before dispatch. Nothing was sent."
        }
    }
}

extension Data {
    var sha256HexString: String {
        SHA256.hash(data: self)
            .map { String(format: "%02X", $0) }
            .joined()
    }

    var shortSHA256Fingerprint: String {
        SHA256.hash(data: self)
            .prefix(6)
            .map { String(format: "%02X", $0) }
            .joined()
    }
}
