import Foundation
import XCTest
import UIKit
@testable import PocketPixelsBooth

enum ReliabilityTestError: Error, LocalizedError {
    case simulated(String)
    case invariantViolation(String)

    var errorDescription: String? {
        switch self {
        case .simulated(let message), .invariantViolation(let message):
            message
        }
    }
}

@MainActor
final class DeterministicFakePrinterTransport {
    enum Scenario: Sendable {
        case immediateSuccess
        case delayedSuccess(nanoseconds: UInt64)
        case failureBeforeBytes(String)
        case failureAfterBytes(byteCount: Int, String)
        case neverCompletes
    }

    struct Record: Sendable {
        let jobID: UUID
        let batchID: UUID
        let sessionIdentifier: String
        let source: PrintJobSource
        let copyIndex: Int
        let copyCount: Int
        let fingerprint: String
        let payloadByteCount: Int
        let imageWidth: Int
        let imageHeight: Int
        let rasterByteCount: Int
        let startedAt: Date
        var bytesStarted: Bool
        var terminalOutcome: PrintAuditRecord.TerminalResult?
    }

    private let scenario: Scenario
    private let chunkSize: Int
    private(set) var records: [Record] = []
    private(set) var activePhysicalJobs = 0
    private(set) var maximumConcurrentPhysicalJobs = 0

    init(scenario: Scenario = .immediateSuccess, chunkSize: Int = 128) {
        self.scenario = scenario
        self.chunkSize = chunkSize
    }

    func operation(envelope: PrintJobEnvelope) async -> Result<PhysicalPrintTransportResult, Error> {
        activePhysicalJobs += 1
        maximumConcurrentPhysicalJobs = max(maximumConcurrentPhysicalJobs, activePhysicalJobs)
        records.append(
            Record(
                jobID: envelope.jobID,
                batchID: envelope.batchID,
                sessionIdentifier: envelope.sessionIdentifier,
                source: envelope.source,
                copyIndex: envelope.copyIndex,
                copyCount: envelope.copyCount,
                fingerprint: envelope.payloadFingerprint,
                payloadByteCount: envelope.payloadByteCount,
                imageWidth: envelope.imageWidth,
                imageHeight: envelope.imageHeight,
                rasterByteCount: envelope.rasterByteCount,
                startedAt: Date(),
                bytesStarted: false,
                terminalOutcome: nil
            )
        )
        let index = records.index(before: records.endIndex)

        switch scenario {
        case .immediateSuccess:
            records[index].bytesStarted = true
            records[index].terminalOutcome = .completed
            activePhysicalJobs -= 1
            return .success(result(bytesStarted: true, envelope: envelope))
        case .delayedSuccess(let nanoseconds):
            records[index].bytesStarted = true
            try? await Task.sleep(nanoseconds: nanoseconds)
            records[index].terminalOutcome = .completed
            activePhysicalJobs -= 1
            return .success(result(bytesStarted: true, envelope: envelope))
        case .failureBeforeBytes(let message):
            records[index].terminalOutcome = .failedBeforeBytes
            activePhysicalJobs -= 1
            return .failure(ReliabilityTestError.simulated(message))
        case .failureAfterBytes(let byteCount, let message):
            records[index].bytesStarted = true
            records[index].terminalOutcome = .recoveryRequiredAfterBytes
            activePhysicalJobs -= 1
            return .failure(PrintTransportFailure(
                underlyingError: ReliabilityTestError.simulated(message),
                bytesStarted: true,
                transportResult: result(bytesStarted: true, envelope: envelope, transferredByteCount: byteCount)
            ))
        case .neverCompletes:
            records[index].bytesStarted = true
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            activePhysicalJobs -= 1
            return .failure(CancellationError())
        }
    }

    private func result(
        bytesStarted: Bool,
        envelope: PrintJobEnvelope,
        transferredByteCount: Int? = nil
    ) -> PhysicalPrintTransportResult {
        PhysicalPrintTransportResult(
            transport: .bluetooth,
            bluetoothMode: envelope.transportPolicy.bluetoothMode,
            chunkSize: chunkSize,
            chunkCount: Int(ceil(Double(transferredByteCount ?? envelope.payloadByteCount) / Double(chunkSize))),
            flowControlPauseCount: 0,
            writeTimeout: nil,
            bytesStarted: bytesStarted,
            transportFinishedAt: Date()
        )
    }
}

enum ReliabilityFixtures {
    static func rasterizedImage(seed: Int, height: Int = 64) throws -> ThermalRasterizedImage {
        var unsafeRaster = Data(capacity: ThermalImageRasterizer.widthBytes * height)
        for index in 0..<(ThermalImageRasterizer.widthBytes * height) {
            unsafeRaster.append(UInt8((index * 31 + seed * 17) & 0xFF))
        }
        // Preserve the full seed: the pattern above repeats every 256 sessions.
        // ASCII hex avoids reserved command bytes and remains stable across copies.
        let seedMarker = Data(String(format: "%016llx", UInt64(bitPattern: Int64(seed))).utf8)
        unsafeRaster.replaceSubrange(0..<seedMarker.count, with: seedMarker)
        let sanitized = try RasterCommandSanitizer.sanitizeRasterData(unsafeRaster)
        var command = Data([0x1D, 0x76, 0x30, 0x00, UInt8(ThermalImageRasterizer.widthBytes), 0x00])
        command.append(UInt8(height & 0xFF))
        command.append(UInt8((height >> 8) & 0xFF))
        command.append(sanitized.data)
        try ThermalImageRasterizer.validateRasterCommand(
            command,
            imageWidth: ThermalImageRasterizer.printWidth,
            imageHeight: height,
            bytesPerRow: ThermalImageRasterizer.widthBytes,
            rasterDataCount: sanitized.data.count
        )
        return ThermalRasterizedImage(
            width: ThermalImageRasterizer.printWidth,
            height: height,
            widthBytes: ThermalImageRasterizer.widthBytes,
            previewPNGData: Data(),
            rasterData: sanitized.data,
            rasterCommand: command,
            sanitizationReport: sanitized.report,
            yL: UInt8(height & 0xFF),
            yH: UInt8((height >> 8) & 0xFF)
        )
    }

    static func envelope(
        seed: Int,
        sessionIdentifier: String = "PP-20260907-000001",
        batchID: UUID = UUID(),
        copyIndex: Int = 1,
        copyCount: Int = 1,
        source: PrintJobSource = .liveCustomer
    ) throws -> PrintJobEnvelope {
        try PrintJobEnvelope.receipt(
            rasterizedImage: rasterizedImage(seed: seed),
            sessionIdentifier: sessionIdentifier,
            source: source,
            copyIndex: copyIndex,
            copyCount: copyCount,
            batchID: batchID,
            transportPolicy: .safeIntegrity
        )
    }

    static func syntheticPhoto(session: Int, photo: Int, format: BoothFormat) -> UIImage {
        let size = CGSize(width: 240, height: 320)
        let rendererFormat = UIGraphicsImageRendererFormat()
        rendererFormat.scale = 1
        rendererFormat.opaque = true
        return UIGraphicsImageRenderer(size: size, format: rendererFormat).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor(
                hue: CGFloat((session * 29 + photo * 43) % 255) / 255,
                saturation: 0.55,
                brightness: 0.88,
                alpha: 1
            ).setFill()
            context.fill(CGRect(x: 0, y: 0, width: size.width, height: size.height))
            let text = "S\(session)-P\(photo)-\(format.rawValue)"
            text.draw(
                in: CGRect(x: 14, y: 132, width: size.width - 28, height: 44),
                withAttributes: [
                    .font: UIFont.monospacedSystemFont(ofSize: 18, weight: .bold),
                    .foregroundColor: UIColor.black
                ]
            )
        }
    }

    static func assertSameBatchIdenticalPayload(_ records: [DeterministicFakePrinterTransport.Record], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(records.isEmpty, file: file, line: line)
        guard let first = records.first else { return }
        for (offset, record) in records.enumerated() {
            XCTAssertEqual(record.batchID, first.batchID, file: file, line: line)
            XCTAssertEqual(record.sessionIdentifier, first.sessionIdentifier, file: file, line: line)
            XCTAssertEqual(record.fingerprint, first.fingerprint, file: file, line: line)
            XCTAssertEqual(record.payloadByteCount, first.payloadByteCount, file: file, line: line)
            XCTAssertEqual(record.imageWidth, first.imageWidth, file: file, line: line)
            XCTAssertEqual(record.imageHeight, first.imageHeight, file: file, line: line)
            XCTAssertEqual(record.rasterByteCount, first.rasterByteCount, file: file, line: line)
            XCTAssertEqual(record.copyIndex, offset + 1, file: file, line: line)
            XCTAssertEqual(record.copyCount, records.count, file: file, line: line)
        }
    }
}
