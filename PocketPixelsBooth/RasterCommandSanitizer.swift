//
//  RasterCommandSanitizer.swift
//  PocketPixelsBooth
//
//  Created by marc on 8/30/26.
//

import Foundation

struct RasterSanitizationReport: Codable, Equatable, Sendable {
    let originalByteCount: Int
    let sanitizedByteCount: Int
    let dleEOTPatternCount: Int
    let dleDC4PatternCount: Int
    let modifiedByteCount: Int
    let modifiedByteOffsets: [Int]
    let finalSafetyScanPassed: Bool
}

enum RasterCommandSanitizerError: Error, LocalizedError {
    case lengthChanged(original: Int, sanitized: Int)
    case reservedPatternRemaining
    case reservedPatternOutsideRaster(String)
    case selfCheckFailed(String)

    var errorDescription: String? {
        switch self {
        case .lengthChanged(let original, let sanitized):
            "Raster sanitizer changed byte length. Original: \(original), sanitized: \(sanitized)."
        case .reservedPatternRemaining:
            "Raster sanitizer could not neutralize every printer real-time command pattern. Nothing was sent."
        case .reservedPatternOutsideRaster(let details):
            "Development error: outbound ESC/POS job contains a reserved real-time command sequence outside raster pixels. \(details)"
        case .selfCheckFailed(let details):
            "Raster sanitizer self-check failed. \(details)"
        }
    }
}

enum RasterCommandSanitizer {
    nonisolated static func sanitizeRasterData(_ rasterData: Data) throws -> (data: Data, report: RasterSanitizationReport) {
#if DEBUG
        try runDebugSelfCheck()
#endif

        let originalByteCount = rasterData.count
        var bytes = Array(rasterData)
        var dleEOTPatternCount = 0
        var dleDC4PatternCount = 0
        var modifiedByteCount = 0
        var modifiedByteOffsets: [Int] = []
        var index = 0

        while index < bytes.count {
            if isDLEEOT(in: bytes, at: index) {
                bytes[index] = 0x11
                dleEOTPatternCount += 1
                modifiedByteCount += 1
                modifiedByteOffsets.append(index)
                index += 3
                continue
            }

            if isDLEDC4(in: bytes, at: index) {
                bytes[index] = 0x11
                dleDC4PatternCount += 1
                modifiedByteCount += 1
                modifiedByteOffsets.append(index)
                index += 5
                continue
            }

            index += 1
        }

        let sanitizedData = Data(bytes)

        guard sanitizedData.count == originalByteCount else {
            throw RasterCommandSanitizerError.lengthChanged(original: originalByteCount, sanitized: sanitizedData.count)
        }

        let finalSafetyScanPassed = reservedPatterns(in: sanitizedData).isEmpty

        guard finalSafetyScanPassed else {
            throw RasterCommandSanitizerError.reservedPatternRemaining
        }

        let report = RasterSanitizationReport(
            originalByteCount: originalByteCount,
            sanitizedByteCount: sanitizedData.count,
            dleEOTPatternCount: dleEOTPatternCount,
            dleDC4PatternCount: dleDC4PatternCount,
            modifiedByteCount: modifiedByteCount,
            modifiedByteOffsets: modifiedByteOffsets,
            finalSafetyScanPassed: finalSafetyScanPassed
        )

        debugLog("Sanitized raster bytes. Original: \(report.originalByteCount). Sanitized: \(report.sanitizedByteCount). DLE EOT: \(report.dleEOTPatternCount). DLE DC4: \(report.dleDC4PatternCount). Modified bytes: \(report.modifiedByteCount). Offsets: \(report.modifiedOffsetSummary). Final scan passed: \(report.finalSafetyScanPassed).")

        return (sanitizedData, report)
    }

    nonisolated static func validateNoReservedPatterns(in data: Data) throws {
        let matches = reservedPatterns(in: data)

        guard matches.isEmpty else {
            throw RasterCommandSanitizerError.reservedPatternRemaining
        }
    }

    nonisolated static func validateOutboundJob(
        heading: Data,
        rasterCommand: Data,
        finishing: Data,
        rasterDataRange: Range<Int>
    ) throws {
        guard rasterCommand.count >= rasterDataRange.upperBound,
              rasterDataRange.lowerBound >= 0,
              rasterDataRange.upperBound >= rasterDataRange.lowerBound else {
            throw RasterCommandSanitizerError.reservedPatternOutsideRaster("Raster byte range is invalid.")
        }

        if let match = reservedPatterns(in: heading).first {
            throw RasterCommandSanitizerError.reservedPatternOutsideRaster("Heading contains \(match.description).")
        }

        if let match = reservedPatterns(in: rasterCommand, excluding: rasterDataRange).first {
            throw RasterCommandSanitizerError.reservedPatternOutsideRaster("Raster command wrapper contains \(match.description).")
        }

        if let match = reservedPatterns(in: finishing).first {
            throw RasterCommandSanitizerError.reservedPatternOutsideRaster("Finishing commands contain \(match.description).")
        }

        let rasterData = rasterCommand.subdata(in: rasterDataRange)
        try validateNoReservedPatterns(in: rasterData)

        var completeJob = Data(capacity: heading.count + rasterCommand.count + finishing.count)
        completeJob.append(heading)
        completeJob.append(rasterCommand)
        completeJob.append(finishing)

        if let match = reservedPatterns(in: completeJob).first {
            throw RasterCommandSanitizerError.reservedPatternOutsideRaster("Complete outbound job contains \(match.description).")
        }

        debugLog("Outbound job preflight passed. Heading: \(heading.count) bytes. Raster command: \(rasterCommand.count) bytes. Finishing: \(finishing.count) bytes.")
    }

    nonisolated static func reservedPatterns(in data: Data) -> [ReservedPatternMatch] {
        reservedPatterns(in: data, excluding: nil)
    }

    nonisolated private static func reservedPatterns(in data: Data, excluding excludedRange: Range<Int>?) -> [ReservedPatternMatch] {
        let bytes = Array(data)
        var matches: [ReservedPatternMatch] = []
        var index = 0

        while index < bytes.count {
            if let excludedRange, excludedRange.contains(index) {
                index = excludedRange.upperBound
                continue
            }

            if isDLEEOT(in: bytes, at: index) {
                matches.append(.dleEOT(offset: index, n: bytes[index + 2]))
                index += 3
                continue
            }

            if isDLEDC4(in: bytes, at: index) {
                matches.append(.dleDC4(offset: index, m: bytes[index + 3], t: bytes[index + 4]))
                index += 5
                continue
            }

            index += 1
        }

        return matches
    }

    nonisolated private static func isDLEEOT(in bytes: [UInt8], at index: Int) -> Bool {
        guard index + 2 < bytes.count else {
            return false
        }

        return bytes[index] == 0x10
            && bytes[index + 1] == 0x04
            && (0x01...0x04).contains(bytes[index + 2])
    }

    nonisolated private static func isDLEDC4(in bytes: [UInt8], at index: Int) -> Bool {
        guard index + 4 < bytes.count else {
            return false
        }

        return bytes[index] == 0x10
            && bytes[index + 1] == 0x14
            && bytes[index + 2] == 0x01
            && (bytes[index + 3] == 0x00 || bytes[index + 3] == 0x01)
            && (0x01...0x08).contains(bytes[index + 4])
    }

#if DEBUG
    nonisolated static func runDebugSelfCheck() throws {
        let cases: [(name: String, input: [UInt8], expectedEOT: Int, expectedDC4: Int, expectedOutput: [UInt8])] = [
            ("DLE EOT 1", [0x10, 0x04, 0x01], 1, 0, [0x11, 0x04, 0x01]),
            ("DLE EOT 2", [0x10, 0x04, 0x02], 1, 0, [0x11, 0x04, 0x02]),
            ("DLE EOT 3", [0x10, 0x04, 0x03], 1, 0, [0x11, 0x04, 0x03]),
            ("DLE EOT 4", [0x10, 0x04, 0x04], 1, 0, [0x11, 0x04, 0x04]),
            ("Invalid DLE EOT", [0x10, 0x04, 0x05], 0, 0, [0x10, 0x04, 0x05]),
            ("DLE DC4 low range", [0x10, 0x14, 0x01, 0x00, 0x01], 0, 1, [0x11, 0x14, 0x01, 0x00, 0x01]),
            ("DLE DC4 high range", [0x10, 0x14, 0x01, 0x01, 0x08], 0, 1, [0x11, 0x14, 0x01, 0x01, 0x08]),
            ("Invalid DLE DC4 m", [0x10, 0x14, 0x01, 0x02, 0x01], 0, 0, [0x10, 0x14, 0x01, 0x02, 0x01]),
            ("Invalid DLE DC4 t", [0x10, 0x14, 0x01, 0x01, 0x09], 0, 0, [0x10, 0x14, 0x01, 0x01, 0x09]),
            ("Multiple patterns", [0x10, 0x04, 0x01, 0x99, 0x10, 0x14, 0x01, 0x01, 0x08], 1, 1, [0x11, 0x04, 0x01, 0x99, 0x11, 0x14, 0x01, 0x01, 0x08]),
            ("First and last valid positions", [0x10, 0x04, 0x04, 0x77, 0x10, 0x14, 0x01, 0x00, 0x08], 1, 1, [0x11, 0x04, 0x04, 0x77, 0x11, 0x14, 0x01, 0x00, 0x08]),
            ("No patterns", [0x00, 0x10, 0x03, 0x04, 0x10, 0x14, 0x02, 0x00, 0x01], 0, 0, [0x00, 0x10, 0x03, 0x04, 0x10, 0x14, 0x02, 0x00, 0x01])
        ]

        for testCase in cases {
            let original = Data(testCase.input)
            let result = try sanitizeRasterDataWithoutSelfCheck(original)

            guard Array(result.data) == testCase.expectedOutput else {
                throw RasterCommandSanitizerError.selfCheckFailed("\(testCase.name) produced unexpected output.")
            }

            guard result.report.originalByteCount == result.report.sanitizedByteCount,
                  result.report.originalByteCount == original.count,
                  result.report.dleEOTPatternCount == testCase.expectedEOT,
                  result.report.dleDC4PatternCount == testCase.expectedDC4,
                  result.report.modifiedByteCount == testCase.expectedEOT + testCase.expectedDC4,
                  result.report.modifiedByteOffsets.count == testCase.expectedEOT + testCase.expectedDC4,
                  result.report.finalSafetyScanPassed else {
                throw RasterCommandSanitizerError.selfCheckFailed("\(testCase.name) produced an invalid report.")
            }
        }

        debugLog("DEBUG self-check passed for \(cases.count) crafted raster buffers.")
    }

    nonisolated private static func sanitizeRasterDataWithoutSelfCheck(_ rasterData: Data) throws -> (data: Data, report: RasterSanitizationReport) {
        let originalByteCount = rasterData.count
        var bytes = Array(rasterData)
        var dleEOTPatternCount = 0
        var dleDC4PatternCount = 0
        var modifiedByteCount = 0
        var modifiedByteOffsets: [Int] = []
        var index = 0

        while index < bytes.count {
            if isDLEEOT(in: bytes, at: index) {
                bytes[index] = 0x11
                dleEOTPatternCount += 1
                modifiedByteCount += 1
                modifiedByteOffsets.append(index)
                index += 3
                continue
            }

            if isDLEDC4(in: bytes, at: index) {
                bytes[index] = 0x11
                dleDC4PatternCount += 1
                modifiedByteCount += 1
                modifiedByteOffsets.append(index)
                index += 5
                continue
            }

            index += 1
        }

        let sanitizedData = Data(bytes)
        let finalSafetyScanPassed = reservedPatterns(in: sanitizedData).isEmpty

        return (
            sanitizedData,
            RasterSanitizationReport(
                originalByteCount: originalByteCount,
                sanitizedByteCount: sanitizedData.count,
                dleEOTPatternCount: dleEOTPatternCount,
                dleDC4PatternCount: dleDC4PatternCount,
                modifiedByteCount: modifiedByteCount,
                modifiedByteOffsets: modifiedByteOffsets,
                finalSafetyScanPassed: finalSafetyScanPassed
            )
        )
    }
#endif
}

extension RasterSanitizationReport {
    nonisolated var modifiedOffsetSummary: String {
        guard !modifiedByteOffsets.isEmpty else {
            return "none"
        }

        let prefix = modifiedByteOffsets
            .prefix(8)
            .map(String.init)
            .joined(separator: ", ")
        let suffix = modifiedByteOffsets.count > 8 ? ", ..." : ""
        return "\(prefix)\(suffix)"
    }
}

struct ReservedPatternMatch: Sendable {
    enum Kind: Sendable {
        case dleEOT
        case dleDC4
    }

    let kind: Kind
    let offset: Int
    let values: [UInt8]

    nonisolated static func dleEOT(offset: Int, n: UInt8) -> ReservedPatternMatch {
        ReservedPatternMatch(kind: .dleEOT, offset: offset, values: [0x10, 0x04, n])
    }

    nonisolated static func dleDC4(offset: Int, m: UInt8, t: UInt8) -> ReservedPatternMatch {
        ReservedPatternMatch(kind: .dleDC4, offset: offset, values: [0x10, 0x14, 0x01, m, t])
    }

    nonisolated var description: String {
        let name: String
        switch kind {
        case .dleEOT:
            name = "DLE EOT"
        case .dleDC4:
            name = "DLE DC4"
        }

        let bytes = values.map { String(format: "0x%02X", $0) }.joined(separator: " ")
        return "\(name) at byte \(offset) [\(bytes)]"
    }
}

nonisolated private func debugLog(_ message: String) {
#if DEBUG
    print("[RasterCommandSanitizer] \(message)")
#endif
}
