import Foundation
import XCTest
@testable import PocketPixelsBooth

final class PrinterPaperReturnDiagnosticTests: XCTestCase {
    func testTransportSuccessDoesNotEnableBWithoutPhysicalCutConfirmation() {
        var progress = PrinterPaperReturnDiagnostic.Progress()
        XCTAssertFalse(progress.begin(.afterReturn))
        XCTAssertTrue(progress.begin(.beforeReturn))
        XCTAssertFalse(progress.observeACut(cutCleanly: true), "Cannot confirm a cut before A has finished sending")
        XCTAssertTrue(progress.finishSending(.beforeReturn, succeeded: true))
        XCTAssertTrue(progress.canObserveA)
        XCTAssertFalse(progress.canStartB)
        XCTAssertFalse(progress.begin(.afterReturn), "BLE/TCP success cannot stand in for an actual cut")
        XCTAssertFalse(progress.begin(.beforeReturn), "No repeated A send")
    }

    func testReportedNoCutOrPaperCatchEndsTheDiagnosticWithoutBOrRetry() {
        var progress = PrinterPaperReturnDiagnostic.Progress()
        XCTAssertTrue(progress.begin(.beforeReturn))
        XCTAssertTrue(progress.finishSending(.beforeReturn, succeeded: true))
        XCTAssertTrue(progress.observeACut(cutCleanly: false))
        XCTAssertEqual(progress.phase, .stopped)
        XCTAssertFalse(progress.canStartA)
        XCTAssertFalse(progress.canStartB)
        XCTAssertFalse(progress.begin(.afterReturn))
        XCTAssertFalse(progress.begin(.beforeReturn))
        XCTAssertFalse(progress.observeACut(cutCleanly: true), "A later toggle cannot revive a stopped probe")
        XCTAssertFalse(progress.finishSending(.beforeReturn, succeeded: true), "Stale completion cannot revive a stopped probe")
    }

    func testCleanCutAllowsExactlyOneBAndRejectsStaleCompletions() {
        var progress = PrinterPaperReturnDiagnostic.Progress()
        XCTAssertTrue(progress.begin(.beforeReturn))
        XCTAssertTrue(progress.finishSending(.beforeReturn, succeeded: true))
        XCTAssertTrue(progress.observeACut(cutCleanly: true))
        XCTAssertTrue(progress.canStartB)
        XCTAssertTrue(progress.begin(.afterReturn))
        XCTAssertTrue(progress.isSending)
        XCTAssertFalse(progress.begin(.afterReturn))
        XCTAssertFalse(progress.finishSending(.beforeReturn, succeeded: true))
        XCTAssertTrue(progress.isSending)
        XCTAssertTrue(progress.finishSending(.afterReturn, succeeded: true))
        XCTAssertEqual(progress.phase, .complete)
        XCTAssertFalse(progress.begin(.afterReturn))
        XCTAssertFalse(progress.begin(.beforeReturn))
    }

    func testTransportFailureStopsBothDiagnosticStagesWithoutRetry() {
        for failingStrip in PrinterPaperReturnDiagnostic.Strip.allCases {
            var progress = PrinterPaperReturnDiagnostic.Progress()
            XCTAssertTrue(progress.begin(.beforeReturn))
            if failingStrip == .afterReturn {
                XCTAssertTrue(progress.finishSending(.beforeReturn, succeeded: true))
                XCTAssertTrue(progress.observeACut(cutCleanly: true))
                XCTAssertTrue(progress.begin(.afterReturn))
            }
            XCTAssertTrue(progress.finishSending(failingStrip, succeeded: false))
            XCTAssertEqual(progress.phase, .stopped)
            XCTAssertFalse(progress.isSending)
            XCTAssertFalse(progress.begin(.beforeReturn))
            XCTAssertFalse(progress.begin(.afterReturn))
        }
    }

    func testComparisonStripsStartWithAnInkBarAndHaveMatchingDimensions() throws {
        for strip in PrinterPaperReturnDiagnostic.Strip.allCases {
            let envelope = try PrinterPaperReturnDiagnostic.envelope(for: strip)
            XCTAssertEqual(envelope.source, .diagnostic)
            XCTAssertEqual(envelope.imageWidth, 576)
            XCTAssertEqual(envelope.imageHeight, 192)
            XCTAssertEqual(envelope.rasterByteCount, 72 * 192)
            XCTAssertEqual(envelope.rasterDataRange.lowerBound, 10)
            XCTAssertEqual(envelope.payload.prefix(2), Data([0x1B, 0x40]), "No leading text or paper movement")
            let pixels = envelope.payload.subdata(in: envelope.rasterDataRange)
            XCTAssertTrue(pixels.prefix(72).contains { $0 != 0 }, "First ink must be at row zero for a meaningful paper-edge measurement")
            XCTAssertEqual(envelope.payload.count - envelope.rasterDataRange.upperBound, 4, "Only the selected per-job cut follows the raster")
            try RasterCommandSanitizer.validateNoReservedPatterns(in: pixels)
            try envelope.verifyPayloadIntegrity()
        }
    }

    func testOnlyTheExplicitAJobUsesTheExperimentalReturnCommand() throws {
        let first = try PrinterPaperReturnDiagnostic.envelope(for: .beforeReturn)
        let second = try PrinterPaperReturnDiagnostic.envelope(for: .afterReturn)
        let receipt = try ReliabilityFixtures.envelope(seed: 921)
        XCTAssertEqual(first.payload.suffix(4), Data([0x1D, 0x56, 0x68, 0x00]))
        XCTAssertEqual(second.payload.suffix(4), Data([0x1D, 0x56, 0x42, 0x00]))
        XCTAssertEqual(receipt.payload.suffix(4), second.payload.suffix(4), "Normal receipts must not silently adopt the unverified command")
        XCTAssertEqual(ThermalImageRasterizer.receiptPrintFinishing(), Data([0x1D, 0x56, 0x42, 0x00]))
    }

    func testEachStripIsAnIndependentSingleDiagnosticWithNoCustomerIdentity() throws {
        let first = try PrinterPaperReturnDiagnostic.envelope(for: .beforeReturn)
        let second = try PrinterPaperReturnDiagnostic.envelope(for: .afterReturn)
        XCTAssertNotEqual(first.jobID, second.jobID)
        XCTAssertNotEqual(first.batchID, second.batchID)
        for envelope in [first, second] {
            XCTAssertEqual(envelope.copyIndex, 1)
            XCTAssertEqual(envelope.copyCount, 1)
            XCTAssertTrue(envelope.sessionIdentifier.hasPrefix("paper-return-check-"))
            XCTAssertEqual(envelope.transportPolicy, .safeIntegrity)
        }
    }
}
