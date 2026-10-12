//
//  HardwareQualificationPlan.swift
//  PocketPixelsBooth
//
//  Deterministic, preprogrammed hardware qualification plans. A plan is a pure value: the same
//  mode, session count and seed always produce the same scenarios, so a report can be
//  reproduced and two runs compared exactly.
//

import CryptoKit
import Foundation

nonisolated enum QualificationMode: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Mode A: deterministic software endurance and chaos with mock transport. Never prints.
    case simulation
    /// Mode B: watermarked diagnostic photos through the real thermal pipeline to the real printer.
    case physicalPrinterEndurance
    /// Mode C: real front camera, real capture, processing, receipt, printing and reset.
    case endToEnd

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .simulation: "A · Software Simulation"
        case .physicalPrinterEndurance: "B · Physical Printer Endurance"
        case .endToEnd: "C · End-to-End Physical Sessions"
        }
    }

    var shortName: String {
        switch self {
        case .simulation: "Simulation"
        case .physicalPrinterEndurance: "Printer Endurance"
        case .endToEnd: "End-to-End"
        }
    }

    var summary: String {
        switch self {
        case .simulation:
            "Synthetic photos and a mock printer. Exercises the production composer, raster, spooler ordering and session isolation. Results are SIMULATION ONLY."
        case .physicalPrinterEndurance:
            "Clearly watermarked diagnostic photos are composed and printed on the connected printer. Tests printer, paper and transport endurance — not the camera."
        case .endToEnd:
            "Drives the production booth session with the real front camera for every session, then prints, archives (diagnostic namespace) and resets. Pauses for physical checks and Photo Pass details."
        }
    }

    var usesPhysicalPrinter: Bool { self != .simulation }
    var usesLiveCamera: Bool { self == .endToEnd }
}

nonisolated enum QualificationScenarioCategory: String, Codable, CaseIterable, Sendable {
    case normal
    case highFrequency
    case multiPhotoLoad
    case printLoad
    case recovery
    case eventConfiguration
    case galleryDelivery

    var displayName: String {
        switch self {
        case .normal: "Normal operation"
        case .highFrequency: "High-frequency"
        case .multiPhotoLoad: "Multi-photo load"
        case .printLoad: "Print-load stress"
        case .recovery: "Recovery"
        case .eventConfiguration: "Event configuration"
        case .galleryDelivery: "Gallery delivery"
        }
    }
}

/// Physical or supervised steps. Automated checks run every session; these need a person.
nonisolated enum QualificationCheckpoint: String, Codable, CaseIterable, Sendable {
    /// Count the receipts that physically emerged and check each is complete and cut.
    case confirmPaperOutput
    /// Photo Pass: the operator enters a name/note and signs on the real customer screens.
    case photoPassDetailsAndSignature
    /// Turn the printer off and on between sessions, then confirm it reconnected.
    case printerPowerCycleBetweenSessions
    /// Send the app to the background and return while the camera is ready.
    case appBackgroundAndReturn
    /// Force-quit and relaunch the app; the run must reconstruct without resuming hardware.
    case appRelaunch
    /// Automatic: reload the earlier session's frozen archive after the event config changed.
    case verifyFrozenArchive
    /// Attestation only: gallery delivery is never exercised against customer galleries.
    case galleryDeliveryAttestation

    var isSupervised: Bool {
        self != .verifyFrozenArchive
    }

    var title: String {
        switch self {
        case .confirmPaperOutput: "Confirm paper output"
        case .photoPassDetailsAndSignature: "Photo Pass details & signature"
        case .printerPowerCycleBetweenSessions: "Printer power cycle"
        case .appBackgroundAndReturn: "Background & return"
        case .appRelaunch: "App relaunch"
        case .verifyFrozenArchive: "Frozen archive check"
        case .galleryDeliveryAttestation: "Gallery delivery (attestation)"
        }
    }

    var instruction: String {
        switch self {
        case .confirmPaperOutput:
            "Count the receipts that came out of the printer since the last checkpoint. Check every receipt is complete, uncut lines are absent, and each is correctly cut. Enter the exact count."
        case .photoPassDetailsAndSignature:
            "On the booth screen, type a test name and note, tap Continue, sign the pad, and tap Continue. The run resumes automatically at the Photo Pass preview."
        case .printerPowerCycleBetweenSessions:
            "Turn the printer OFF, wait 5 seconds, turn it ON, and wait until it is ready. No print is in progress. Then tap Done; the next session reconnects normally."
        case .appBackgroundAndReturn:
            "When the next session's camera is ready, swipe up to the Home Screen, wait 5 seconds and reopen the app. Then tap Done."
        case .appRelaunch:
            "Optional drill: force-quit the app now and relaunch it. The run is recorded as INTERRUPTED and nothing resumes automatically. Re-open Hardware Qualification to review it."
        case .verifyFrozenArchive:
            "The app reloads the earlier session's archive and proves its frozen event settings and raster are unchanged."
        case .galleryDeliveryAttestation:
            "Qualification never uploads to customer galleries. Confirm only if you verified offline/online gallery delivery separately with an approved diagnostic gallery."
        }
    }
}

nonisolated enum QualificationGalleryExpectation: String, Codable, Sendable {
    /// Diagnostic isolation: the gallery is never prepared, queued or uploaded.
    case notDelivered
    /// Gallery delivery is outside automated scope; operator attestation required.
    case operatorAttested
}

nonisolated enum QualificationArchiveExpectation: String, Codable, Sendable {
    /// Committed to the run's isolated diagnostic archive before any bytes are printed.
    case diagnosticArchiveBeforePrint
    /// As above, and later compared against the frozen copy after a configuration change.
    case frozenAcrossConfigurationChange
    /// Simulation and printer-only runs archive into the run's diagnostic namespace.
    case diagnosticArchive
}

nonisolated struct QualificationScenario: Codable, Equatable, Identifiable, Sendable {
    let sessionNumber: Int
    let format: BoothFormat
    let category: QualificationScenarioCategory
    let expectedPhotoCount: Int
    /// Per photo, e.g. "portrait 3:4" or "portrait 3:4 · prints rotated 90° CCW".
    let expectedCaptureOrientations: [String]
    let expectedReceiptLayout: String
    let plannedCopies: Int
    let eventModeEnabled: Bool
    /// The session whose frozen archive this one re-verifies (event configuration scenarios).
    let verifiesArchiveOfSession: Int?
    let galleryExpectation: QualificationGalleryExpectation
    let archiveExpectation: QualificationArchiveExpectation
    let checkpoints: [QualificationCheckpoint]
    /// Ends a supervised execution batch after this session.
    let endsBatch: Bool

    var id: Int { sessionNumber }
}

nonisolated struct QualificationPlan: Codable, Equatable, Sendable {
    static let supportedSessionCounts = [6, 12, 25, 50, 100]
    static let defaultSessionCount = 100
    static let defaultBatchSize = 10
    static let defaultSeed: UInt64 = 20_261_009
    /// Separate controlled batches. Each is ONE session printing N copies, never N sessions.
    static let printLoadCopyCounts = [1, 2, 3, 5, 10, 10]

    let mode: QualificationMode
    let seed: UInt64
    let batchSize: Int
    let scenarios: [QualificationScenario]

    var sessionCount: Int { scenarios.count }

    var plannedPhysicalReceipts: Int {
        mode.usesPhysicalPrinter ? scenarios.reduce(0) { $0 + $1.plannedCopies } : 0
    }

    var plannedPrintJobs: Int {
        scenarios.reduce(0) { $0 + $1.plannedCopies }
    }

    /// copies-per-session → number of sessions.
    var copyDistribution: [Int: Int] {
        scenarios.reduce(into: [:]) { $0[$1.plannedCopies, default: 0] += 1 }
    }

    var formatDistribution: [BoothFormat: Int] {
        scenarios.reduce(into: [:]) { $0[$1.format, default: 0] += 1 }
    }

    var batchEndSessions: [Int] {
        scenarios.filter(\.endsBatch).map(\.sessionNumber)
    }

    /// Stable fingerprint of everything the operator approves. Approval is bound to it.
    var fingerprint: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let digest = SHA256.hash(data: (try? encoder.encode(self)) ?? Data())
        return digest.prefix(8).map { String(format: "%02X", $0) }.joined()
    }

    /// Estimated paper per format, from the production layout plan height (8 dots/mm) plus the
    /// printer's feed-and-cut allowance. An estimate: event text length and QR change it.
    static func estimatedReceiptLengthMillimeters(format: BoothFormat, eventModeEnabled: Bool) -> Double? {
        let profile = eventModeEnabled ? QualificationEventProfiles.profileA : nil
        guard let plan = try? ReceiptComposer.makeLayoutPlan(
            format: format,
            includesGalleryQRCode: ReceiptPrintSettingsStore.load().includesPrintedGalleryQR,
            eventProfile: profile,
            passport: format == .passport ? PassportSessionData(configuration: PassportConfiguration.effective(for: profile)) : nil
        ) else { return nil }
        return Double(plan.height) / 8.0 + feedAndCutAllowanceMillimeters
    }

    static let feedAndCutAllowanceMillimeters = 12.0

    var estimatedPaperMillimeters: Double? {
        guard mode.usesPhysicalPrinter else { return 0 }
        var total = 0.0
        for scenario in scenarios {
            guard let length = Self.estimatedReceiptLengthMillimeters(format: scenario.format, eventModeEnabled: scenario.eventModeEnabled) else {
                return nil
            }
            total += length * Double(scenario.plannedCopies)
        }
        return total
    }
}

/// Fixed diagnostic event profiles. Qualification never reads or edits the operator's saved
/// event configuration; these values are frozen into each session like a real event would be.
nonisolated enum QualificationEventProfiles {
    static let profileA = EventProfile(
        isEnabled: true,
        eventName: "Qualification Event A",
        subtitle: "Diagnostic Configuration",
        includeEventDate: true,
        eventDate: Date(timeIntervalSince1970: 1_791_000_000),
        location: "Test Bench",
        shortMessage: "Diagnostic receipt. Not a customer keepsake."
    )

    static let profileB = EventProfile(
        isEnabled: true,
        eventName: "Qualification Event B",
        subtitle: "Changed Configuration",
        includeEventDate: true,
        eventDate: Date(timeIntervalSince1970: 1_791_086_400),
        location: "Second Bench",
        shortMessage: "Changed after the earlier session was frozen."
    )

    static let disabled = EventProfile(
        isEnabled: false,
        eventName: "",
        subtitle: "",
        includeEventDate: false,
        eventDate: Date(timeIntervalSince1970: 1_791_000_000),
        location: "",
        shortMessage: ""
    )

    static func profile(for scenario: QualificationScenario, plan: QualificationPlan) -> EventProfile {
        guard scenario.eventModeEnabled else { return disabled }
        // The second session of a configuration pair runs with the changed configuration.
        return scenario.verifiesArchiveOfSession != nil ? profileB : profileA
    }
}

/// Small deterministic generator (LCG). Placement only; never used for security.
nonisolated struct QualificationRandom {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
    }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state >> 11
    }

    mutating func nextInt(upperBound: Int) -> Int {
        guard upperBound > 0 else { return 0 }
        return Int(next() % UInt64(upperBound))
    }
}

nonisolated enum QualificationPlanner {
    static func makePlan(
        mode: QualificationMode,
        sessionCount: Int = QualificationPlan.defaultSessionCount,
        seed: UInt64 = QualificationPlan.defaultSeed,
        batchSize: Int = QualificationPlan.defaultBatchSize
    ) -> QualificationPlan {
        let count = max(1, sessionCount)
        let batch = max(1, min(batchSize, count))
        var random = QualificationRandom(seed: seed)
        let formats = BoothFormat.allCases

        // Balanced round-robin: every format gets floor(n/6) or ceil(n/6) sessions.
        let sessionFormats = (0..<count).map { formats[$0 % formats.count] }
        var categories = Array(repeating: QualificationScenarioCategory.normal, count: count)
        var copies = Array(repeating: 1, count: count)
        var verifiesArchiveOf = [Int?](repeating: nil, count: count)
        var eventMode = (0..<count).map { _ in random.nextInt(upperBound: 4) == 0 }
        var extraCheckpoints = Array(repeating: [QualificationCheckpoint](), count: count)

        func freeIndex(where predicate: (Int) -> Bool = { _ in true }) -> Int? {
            let candidates = (0..<count).filter { categories[$0] == .normal && predicate($0) }
            guard !candidates.isEmpty else { return nil }
            return candidates[random.nextInt(upperBound: candidates.count)]
        }

        // High-frequency: one contiguous block of rapid back-to-back sessions.
        let rapidLength = min(10, max(1, count / 10))
        if count >= 12 {
            let start = random.nextInt(upperBound: count - rapidLength)
            for index in start..<(start + rapidLength) { categories[index] = .highFrequency }
        }

        // Multi-photo load: Grid 6 and Strip sessions in one seeded window.
        if count >= 12 {
            let window = min(count, 30)
            let start = random.nextInt(upperBound: max(1, count - window + 1))
            for index in start..<(start + window) where categories[index] == .normal
                && (sessionFormats[index] == .gridSix || sessionFormats[index] == .strip) {
                categories[index] = .multiPhotoLoad
            }
        }

        // Print-load: separate single-session batches of 1, 2, 3, 5 and 10 copies.
        let printLoadCounts = Array(QualificationPlan.printLoadCopyCounts.prefix(max(1, min(QualificationPlan.printLoadCopyCounts.count, count / 16))))
        for copyCount in printLoadCounts {
            guard let index = freeIndex() else { break }
            categories[index] = .printLoad
            copies[index] = copyCount
        }

        // Event configuration: a session with config A, then a later one with config B that
        // re-verifies the first session's frozen archive.
        // Only positions where both sessions of the pair are still free are eligible.
        if count >= 6, let first = freeIndex(where: { $0 + 1 < count && categories[$0 + 1] == .normal }) {
            let second = first + 1
            categories[first] = .eventConfiguration
            categories[second] = .eventConfiguration
            eventMode[first] = true
            eventMode[second] = true
            verifiesArchiveOf[second] = first + 1
        }

        // Recovery: supervised interruptions between sessions (never mid-print).
        if count >= 12 {
            for checkpoint in [QualificationCheckpoint.printerPowerCycleBetweenSessions, .appBackgroundAndReturn] {
                guard let index = freeIndex() else { break }
                categories[index] = .recovery
                extraCheckpoints[index].append(checkpoint)
            }
        }

        // Gallery delivery: attestation only — customer galleries are never touched.
        if count >= 25, let index = freeIndex() {
            categories[index] = .galleryDelivery
            extraCheckpoints[index].append(.galleryDeliveryAttestation)
        }

        let scenarios = (0..<count).map { index -> QualificationScenario in
            let number = index + 1
            let format = sessionFormats[index]
            let endsBatch = number % batch == 0 || number == count || categories[index] == .printLoad
            var checkpoints: [QualificationCheckpoint] = []
            if mode == .endToEnd, format.usesPassportFlow {
                checkpoints.append(.photoPassDetailsAndSignature)
            }
            if verifiesArchiveOf[index] != nil {
                checkpoints.append(.verifyFrozenArchive)
            }
            checkpoints += extraCheckpoints[index].filter { checkpoint in
                // Physical interruption drills only make sense with real hardware.
                mode.usesPhysicalPrinter || checkpoint == .galleryDeliveryAttestation
            }
            if mode.usesPhysicalPrinter, endsBatch {
                checkpoints.append(.confirmPaperOutput)
            }
            return QualificationScenario(
                sessionNumber: number,
                format: format,
                category: categories[index],
                expectedPhotoCount: format.photoCount,
                expectedCaptureOrientations: (0..<format.photoCount).map { Self.orientationDescription(format: format, photoIndex: $0) },
                expectedReceiptLayout: Self.layoutDescription(format),
                plannedCopies: copies[index],
                eventModeEnabled: eventMode[index],
                verifiesArchiveOfSession: verifiesArchiveOf[index],
                galleryExpectation: categories[index] == .galleryDelivery ? .operatorAttested : .notDelivered,
                archiveExpectation: categories[index] == .eventConfiguration
                    ? .frozenAcrossConfigurationChange
                    : (mode == .endToEnd ? .diagnosticArchiveBeforePrint : .diagnosticArchive),
                checkpoints: checkpoints,
                endsBatch: endsBatch
            )
        }

        return QualificationPlan(mode: mode, seed: seed, batchSize: batch, scenarios: scenarios)
    }

    static func orientationDescription(format: BoothFormat, photoIndex: Int) -> String {
        let geometry = PhotoPresentationGeometry.resolve(format: format, photoIndex: photoIndex)
        let shape = geometry.orientation == .portrait ? "portrait 3:4" : "landscape 4:3"
        return geometry.printRotation == .counterclockwise90 ? "\(shape) · prints rotated 90° CCW" : shape
    }

    static func layoutDescription(_ format: BoothFormat) -> String {
        switch format {
        case .solo: "Solo · one portrait"
        case .duo: "Duo · two stacked landscapes"
        case .grid: "Grid · 2×2 portraits"
        case .strip: "Strip · three stacked landscapes"
        case .gridSix: "Grid 6 · 2×3 portraits"
        case .passport: "Photo Pass · sideways hero card + portrait card"
        }
    }
}
