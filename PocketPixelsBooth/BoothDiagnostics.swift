//
//  BoothDiagnostics.swift
//  PocketPixelsBooth
//
//  Privacy-safe production diagnostics using Apple's unified logging (os.Logger) and MetricKit.
//  Retrieve after an event with Console.app or `log collect` on a connected iPad, filtering by
//  subsystem "com.pocketpixels.booth".
//
//  Privacy rules for every call site:
//  - Never log photos, receipt images, raster bytes, or customer-entered text.
//  - Never log Passport details or signatures.
//  - Never log device tokens. Gallery tokens are logged only via `BoothDiagnostics.redact(_:)`.
//  - Interpolated values default to `.private`; mark only non-sensitive values `.public`.
//

import Foundation
import MetricKit
import OSLog

nonisolated enum BoothDiagnostics {
    nonisolated static let subsystem = "com.pocketpixels.booth"

    nonisolated static let lifecycle = Logger(subsystem: subsystem, category: "lifecycle")
    nonisolated static let camera = Logger(subsystem: subsystem, category: "camera")
    nonisolated static let receipt = Logger(subsystem: subsystem, category: "receipt")
    nonisolated static let printer = Logger(subsystem: subsystem, category: "printer")
    nonisolated static let recovery = Logger(subsystem: subsystem, category: "recovery")
    nonisolated static let archive = Logger(subsystem: subsystem, category: "archive")
    nonisolated static let gallery = Logger(subsystem: subsystem, category: "gallery")
    nonisolated static let backend = Logger(subsystem: subsystem, category: "backend")

    /// A short, non-reversible reference for correlating a token across log lines without
    /// revealing it: the first 4 characters, an ellipsis and the length.
    nonisolated static func redact(_ token: String?) -> String {
        guard let token, !token.isEmpty else { return "none" }
        return "\(token.prefix(4))…(\(token.count))"
    }

    /// Starts MetricKit collection. Payloads (crash/hang/CPU/disk diagnostics) are summarized to
    /// the unified log; they contain no customer content.
    @MainActor
    static func startMetricCollection() {
        MetricKitReceiver.shared.start()
    }
}

@MainActor
private final class MetricKitReceiver: NSObject, MXMetricManagerSubscriber {
    static let shared = MetricKitReceiver()
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        MXMetricManager.shared.add(self)
        BoothDiagnostics.lifecycle.info("MetricKit collection started")
    }

    nonisolated func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            BoothDiagnostics.lifecycle.notice("MetricKit metrics \(payload.timeStampBegin, privacy: .public)–\(payload.timeStampEnd, privacy: .public) appVersion=\(payload.latestApplicationVersion, privacy: .public)")
        }
    }

    nonisolated func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            let crashes = payload.crashDiagnostics?.count ?? 0
            let hangs = payload.hangDiagnostics?.count ?? 0
            let cpu = payload.cpuExceptionDiagnostics?.count ?? 0
            let disk = payload.diskWriteExceptionDiagnostics?.count ?? 0
            BoothDiagnostics.lifecycle.error("MetricKit diagnostics crashes=\(crashes, privacy: .public) hangs=\(hangs, privacy: .public) cpuExceptions=\(cpu, privacy: .public) diskWriteExceptions=\(disk, privacy: .public)")
        }
    }
}
