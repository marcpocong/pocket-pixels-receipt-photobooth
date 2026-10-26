#if DEBUG
import Foundation
import UIKit

/// Retired probe retained for development evidence. On the owner's 80-VI / 80.C-z04-AA,
/// A did not cut; only B cut. This failed probe has no production UI or Release code.
/// Do not repeat it without new, verified firmware documentation and owner authorization.
nonisolated enum PrinterPaperReturnDiagnostic {
    /// Transport acceptance is not evidence that an unsupported cutter command ran.
    /// B requires an explicit clean-cut observation; a negative/uncertain result ends this run.
    struct Progress {
        enum Phase: Equatable {
            case idle, sendingA, awaitingACutObservation, readyForB, sendingB, complete, stopped
        }

        private(set) var phase: Phase = .idle
        var canStartA: Bool { phase == .idle }
        var canObserveA: Bool { phase == .awaitingACutObservation }
        var canStartB: Bool { phase == .readyForB }
        var isSending: Bool { phase == .sendingA || phase == .sendingB }

        mutating func begin(_ strip: Strip) -> Bool {
            switch strip {
            case .beforeReturn:
                guard canStartA else { return false }
                phase = .sendingA
            case .afterReturn:
                guard canStartB else { return false }
                phase = .sendingB
            }
            return true
        }

        mutating func finishSending(_ strip: Strip, succeeded: Bool) -> Bool {
            let expected: Phase = strip == .beforeReturn ? .sendingA : .sendingB
            guard phase == expected else { return false }
            phase = succeeded ? (strip == .beforeReturn ? .awaitingACutObservation : .complete) : .stopped
            return true
        }

        mutating func observeACut(cutCleanly: Bool) -> Bool {
            guard canObserveA else { return false }
            phase = cutCleanly ? .readyForB : .stopped
            return true
        }
    }

    enum Strip: String, CaseIterable {
        case beforeReturn = "A"
        case afterReturn = "B"

        var finishing: Data {
            switch self {
            case .beforeReturn:
                // ESC/POS GS V Function D: partial cut and return to print start.
                // G80 support is unverified; only an observed paper test can establish it.
                Data([0x1D, 0x56, 0x68, 0x00])
            case .afterReturn:
                // Restore the ordinary per-job cut operation for the comparison strip.
                ThermalImageRasterizer.receiptPrintFinishing()
            }
        }
    }

    static func envelope(for strip: Strip) throws -> PrintJobEnvelope {
        let size = CGSize(width: 576, height: 192)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor.black.setFill()
            // First ink is exactly row zero: measure the paper edge to this bar.
            context.fill(CGRect(x: 36, y: 0, width: 504, height: 3))
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedSystemFont(ofSize: 20, weight: .medium),
                .foregroundColor: UIColor.black
            ]
            let label = strip == .beforeReturn ? "A - BEFORE PAPER RETURN" : "B - AFTER PAPER RETURN"
            (label as NSString).draw(at: CGPoint(x: 36, y: 18), withAttributes: attributes)
            ("Measure edge to first black bar" as NSString).draw(at: CGPoint(x: 36, y: 56), withAttributes: attributes)
            ("Diagnostic only - no guest copy" as NSString).draw(at: CGPoint(x: 36, y: 94), withAttributes: attributes)
            // Match both strip lengths; this final bar also makes the cut unambiguous.
            context.fill(CGRect(x: 36, y: 184, width: 504, height: 3))
        }
        let raster = try ThermalImageRasterizer.rasterize(image, purpose: .completeReceipt)
        return try PrintJobEnvelope.diagnostic(
            heading: ThermalImageRasterizer.receiptPrintHeading(),
            rasterizedImage: raster,
            finishing: strip.finishing,
            sessionIdentifier: "paper-return-check-\(strip.rawValue.lowercased())",
            copyIndex: 1, copyCount: 1, batchID: UUID(), transportPolicy: .safeIntegrity
        )
    }
}
#endif
