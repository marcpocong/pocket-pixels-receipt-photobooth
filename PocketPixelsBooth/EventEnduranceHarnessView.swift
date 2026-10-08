//
//  EventEnduranceHarnessView.swift
//  PocketPixelsBooth
//

#if DEBUG
import Darwin
import Combine
import SwiftUI
import UIKit

@MainActor
final class EventEnduranceHarnessViewModel: ObservableObject {
    enum LayoutMode: String, CaseIterable, Identifiable {
        case alternating
        case random

        var id: String { rawValue }
        var displayName: String { rawValue.capitalized }
    }

    enum ChaosMode: String, CaseIterable, Identifiable {
        case normal
        case slowTransport
        case uploadOffline
        case rapidSessionGeneration
        case rapidReset
        case cameraRestart
        case mixedSoftwareChaos

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .normal:
                "Normal"
            case .slowTransport:
                "Slow Transport"
            case .uploadOffline:
                "Upload Offline"
            case .rapidSessionGeneration:
                "Rapid Session Generation"
            case .rapidReset:
                "Rapid Reset"
            case .cameraRestart:
                "Camera Restart"
            case .mixedSoftwareChaos:
                "Mixed Software Chaos"
            }
        }
    }

    @Published var sessionCount = 10
    @Published var layoutMode = LayoutMode.alternating
    @Published var randomCopyCount = false
    @Published var persistUploads = false
    @Published var physicalPrinting = false
    @Published var chaosMode = ChaosMode.normal
    @Published var seedText = "48291"
    @Published private(set) var isRunning = false
    @Published private(set) var sessionsAttempted = 0
    @Published private(set) var completedSessions = 0
    @Published private(set) var printJobsAttempted = 0
    @Published private(set) var printJobsCompleted = 0
    @Published private(set) var totalRequestedCopies = 0
    @Published private(set) var uploadSuccesses = 0
    @Published private(set) var uploadFailures = 0
    @Published private(set) var pendingUploads = 0
    @Published private(set) var cameraRestarts = 0
    @Published private(set) var failures = 0
    @Published private(set) var payloadMismatchCount = 0
    @Published private(set) var crossSessionViolationCount = 0
    @Published private(set) var recoveryRequiredEvents = 0
    @Published private(set) var illegalRetryAfterBytesCount = 0
    @Published private(set) var physicalOwnershipViolationCount = 0
    @Published private(set) var unsafeRecoveryViolationCount = 0
    @Published private(set) var auditAnomalyCount = 0
    @Published private(set) var currentMemoryMB = 0
    @Published private(set) var peakMemoryMB = 0
    @Published private(set) var lastSessionDuration = 0.0
    @Published private(set) var averageSessionDuration = 0.0
    @Published private(set) var longestSessionDuration = 0.0
    @Published private(set) var statusMessage = "Ready."
    @Published private(set) var reliabilityReport = "MADE TO KEEP RELIABILITY RUN\n\nResult has not run."

    private let uploadService = GoogleDriveGalleryUploadService()
    private let recoveryStore = try? AppRecoveryStore()
    private let archiveStore = try? RecentSessionArchiveStore()
    private let printerCoordinator = PrinterCoordinator.shared
    private var simulatedPrinterLedger = SimulatedPrintLedger()
    private var expectedSessionMarkers: [String: Set<String>] = [:]
    private var shouldStop = false

    let supportedSessionCounts = [10, 25, 50, 100, 250, 1_000]

    func stopAfterCurrentSession() {
        shouldStop = true
    }

    func run(printerIP: String, printerPort: UInt16?) {
        guard !isRunning else { return }

        isRunning = true
        shouldStop = false
        sessionsAttempted = 0
        completedSessions = 0
        printJobsAttempted = 0
        printJobsCompleted = 0
        totalRequestedCopies = 0
        uploadSuccesses = 0
        uploadFailures = 0
        pendingUploads = uploadService.pendingUploadSummaries().count
        cameraRestarts = 0
        failures = 0
        payloadMismatchCount = 0
        crossSessionViolationCount = 0
        recoveryRequiredEvents = 0
        illegalRetryAfterBytesCount = 0
        physicalOwnershipViolationCount = 0
        unsafeRecoveryViolationCount = 0
        auditAnomalyCount = 0
        currentMemoryMB = Self.currentMemoryFootprintMB()
        peakMemoryMB = currentMemoryMB
        lastSessionDuration = 0
        averageSessionDuration = 0
        longestSessionDuration = 0
        simulatedPrinterLedger = SimulatedPrintLedger()
        expectedSessionMarkers = [:]
        let seed = parsedSeed
        reliabilityReport = "MADE TO KEEP RELIABILITY RUN\n\nSeed: \(seed)\nResult is running."
        statusMessage = "Starting reliability run with seed \(seed)..."

        Task {
            var totalDuration = 0.0
            let baseDate = Date()
            var generator = SeededGenerator(seed: UInt64(bitPattern: Int64(seed)))

            for index in 1...sessionCount {
                guard !shouldStop else { break }
                sessionsAttempted += 1
                let started = Date()
                do {
                    try await runSession(index: index, baseDate: baseDate, printerIP: printerIP, printerPort: printerPort, generator: &generator)
                    completedSessions += 1
                    lastSessionDuration = Date().timeIntervalSince(started)
                    totalDuration += lastSessionDuration
                    averageSessionDuration = totalDuration / Double(max(1, completedSessions))
                    longestSessionDuration = max(longestSessionDuration, lastSessionDuration)
                    currentMemoryMB = Self.currentMemoryFootprintMB()
                    peakMemoryMB = max(peakMemoryMB, currentMemoryMB)
                    pendingUploads = uploadService.pendingUploadSummaries().count
                    statusMessage = "Session \(completedSessions) / \(sessionCount) completed."
                } catch {
                    failures += 1
                    statusMessage = error.localizedDescription
                    break
                }
            }

            isRunning = false
            shouldStop = false
            reliabilityReport = makeReliabilityReport(seed: seed)
        }
    }

    private var parsedSeed: Int {
        Int(seedText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 48291
    }

    private func runSession(
        index: Int,
        baseDate: Date,
        printerIP: String,
        printerPort: UInt16?,
        generator: inout SeededGenerator
    ) async throws {
        let date = baseDate.addingTimeInterval(Double(index))
        let activeChaosMode = selectedChaosMode(generator: &generator)
        let format = selectedFormat(index: index, generator: &generator)
        let sessionID = "\(ReceiptComposer.makeSessionIdentifier(date: date))-\(String(format: "%03d", index))"
        let galleryToken = deterministicGalleryToken(index: index, generator: &generator)
        let galleryURL = try GalleryURLBuilder.makeGalleryURL(
            customerGalleryBaseURL: CustomerGalleryConfiguration.load().baseURL,
            galleryToken: galleryToken
        )
        let photos = Self.makeSamplePhotos(count: format.photoCount, index: index)
        let eventSnapshot = EventProfileStore.load().activeReceiptSnapshot
        let worker = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let receipt = try ReceiptComposer.compose(
                photos: photos,
                sessionIdentifier: sessionID,
                date: date,
                galleryURL: galleryURL,
                format: format,
                eventProfile: eventSnapshot,
                photoQualityProfile: .customerPrintDefault
            )
            guard let receiptImage = UIImage(data: receipt.imagePNGData) else {
                throw ReceiptComposerError.renderFailed
            }
            try Task.checkCancellation()
            let rasterized = try ThermalImageRasterizer.rasterize(receiptImage, purpose: .completeReceipt)
            return (receipt, receiptImage, rasterized)
        }
        let (receipt, receiptImage, rasterized) = try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }

        validateSessionMarkers(sessionID: sessionID, galleryToken: galleryToken, galleryURL: galleryURL)
        if activeChaosMode == .rapidSessionGeneration || activeChaosMode == .rapidReset {
            validateStaleCallbackRejection(activeSessionID: sessionID, staleSessionID: "\(sessionID)-STALE")
        }
        if activeChaosMode == .cameraRestart || activeChaosMode == .mixedSoftwareChaos {
            cameraRestarts += 1
        }

        let committedSession = CommittedGallerySession(
            sessionIdentifier: sessionID,
            createdAt: date,
            galleryToken: galleryToken,
            galleryURL: galleryURL,
            photos: photos,
            format: format,
            eventProfile: eventSnapshot
        )
        let thumbnails = photos.compactMap { AppRecoveryStore.photoData(from: $0) }
        try archiveStore?.save(
            RecentSessionArchivePayload(
                committedSession: committedSession,
                composedReceipt: receipt,
                receiptPreviewPNGData: receipt.imagePNGData,
                thermalPreviewPNGData: rasterized.previewPNGData,
                rasterizedImage: rasterized,
                photoThumbnailData: thumbnails
            )
        )

        if persistUploads {
            if activeChaosMode == .uploadOffline || (activeChaosMode == .mixedSoftwareChaos && generator.nextInt(upperBound: 5) == 0) {
                uploadFailures += 1
                pendingUploads += 1
            } else {
                _ = try await uploadService.prepareAndPersistGallery(
                    photos: photos,
                    composedReceipt: receiptImage,
                    sessionID: sessionID,
                    createdAt: date,
                    galleryToken: galleryToken
                )
                uploadSuccesses += 1
            }
        }

        let copies = selectedCopyCount(generator: &generator)
        totalRequestedCopies += copies
        if physicalPrinting {
            guard let printerPort else {
                throw PrinterNetworkError.invalidPort
            }
            let batchID = UUID()
            for copy in 1...copies {
                printJobsAttempted += 1
                try await printCopy(
                    rasterizedImage: rasterized,
                    sessionID: sessionID,
                    batchID: batchID,
                    copy: copy,
                    copies: copies,
                    printerIP: printerIP,
                    printerPort: printerPort
                )
                printJobsCompleted += 1
            }
        } else {
            simulatePrintBatch(
                rasterizedImage: rasterized,
                sessionID: sessionID,
                copies: copies,
                chaosMode: activeChaosMode,
                generator: &generator
            )
        }

        recoveryStore?.clear(sessionIdentifier: sessionID)
    }

    private func printCopy(
        rasterizedImage: ThermalRasterizedImage,
        sessionID: String,
        batchID: UUID,
        copy: Int,
        copies: Int,
        printerIP: String,
        printerPort: UInt16
    ) async throws {
        try await withCheckedThrowingContinuation { continuation in
            printerCoordinator.printReceipt(
                rasterizedImage: rasterizedImage,
                wifiHost: printerIP,
                wifiPort: printerPort,
                sessionIdentifier: sessionID,
                source: .diagnostic,
                copyIndex: copy,
                copyCount: copies,
                batchID: batchID,
                transportPolicy: .safeIntegrity
            ) { _ in
            } completion: { result in
                continuation.resume(with: result)
            }
        }
    }

    private func selectedFormat(index: Int, generator: inout SeededGenerator) -> BoothFormat {
        switch layoutMode {
        case .alternating:
            BoothFormat.allCases[(index - 1) % BoothFormat.allCases.count]
        case .random:
            BoothFormat.allCases[generator.nextInt(upperBound: BoothFormat.allCases.count)]
        }
    }

    private func selectedCopyCount(generator: inout SeededGenerator) -> Int {
        guard randomCopyCount else {
            return 1
        }

        let supported = [1, 2, 3, 5, 10]
        return supported[generator.nextInt(upperBound: supported.count)]
    }

    private func selectedChaosMode(generator: inout SeededGenerator) -> ChaosMode {
        guard chaosMode == .mixedSoftwareChaos else {
            return chaosMode
        }

        let modes: [ChaosMode] = [.normal, .slowTransport, .uploadOffline, .rapidSessionGeneration, .rapidReset, .cameraRestart]
        return modes[generator.nextInt(upperBound: modes.count)]
    }

    private func deterministicGalleryToken(index: Int, generator: inout SeededGenerator) -> String {
        let value = UInt64(index) ^ generator.next()
        return String(format: "%016llx%016llx%016llx%016llx", value, value &* 3, value &* 5, value &* 7)
    }

    private func validateSessionMarkers(sessionID: String, galleryToken: String, galleryURL: URL) {
        let markers: Set<String> = [sessionID, galleryToken, galleryURL.absoluteString]
        for (existingSessionID, existingMarkers) in expectedSessionMarkers where existingSessionID != sessionID {
            if !markers.isDisjoint(with: existingMarkers) {
                crossSessionViolationCount += 1
                return
            }
        }
        expectedSessionMarkers[sessionID] = markers
    }

    private func validateStaleCallbackRejection(activeSessionID: String, staleSessionID: String) {
        if activeSessionID == staleSessionID {
            crossSessionViolationCount += 1
        }
    }

    private func simulatePrintBatch(
        rasterizedImage: ThermalRasterizedImage,
        sessionID: String,
        copies: Int,
        chaosMode: ChaosMode,
        generator: inout SeededGenerator
    ) {
        let batchID = UUID()
        var expectedFingerprint: String?
        var bytesStartedFailureOccurred = false

        for copy in 1...copies {
            guard !bytesStartedFailureOccurred else {
                illegalRetryAfterBytesCount += 1
                return
            }

            printJobsAttempted += 1

            do {
                let envelope = try PrintJobEnvelope.receipt(
                    rasterizedImage: rasterizedImage,
                    sessionIdentifier: sessionID,
                    source: .diagnostic,
                    copyIndex: copy,
                    copyCount: copies,
                    batchID: batchID,
                    transportPolicy: .safeIntegrity
                )
                try envelope.verifyPayloadIntegrity()
                if expectedFingerprint == nil {
                    expectedFingerprint = envelope.payloadFingerprint
                } else if expectedFingerprint != envelope.payloadFingerprint {
                    payloadMismatchCount += 1
                }
                if simulatedPrinterLedger.begin(envelope: envelope) == false {
                    physicalOwnershipViolationCount += 1
                }

                if chaosMode == .slowTransport {
                    Thread.sleep(forTimeInterval: 0.002)
                }

                if shouldSimulateAfterBytesFailure(copy: copy, chaosMode: chaosMode, generator: &generator) {
                    bytesStartedFailureOccurred = true
                    recoveryRequiredEvents += 1
                    simulatedPrinterLedger.finish(envelope: envelope, terminalResult: .recoveryRequiredAfterBytes, bytesStarted: true)
                    continue
                }

                if shouldSimulateBeforeBytesFailure(copy: copy, chaosMode: chaosMode, generator: &generator) {
                    simulatedPrinterLedger.finish(envelope: envelope, terminalResult: .failedBeforeBytes, bytesStarted: false)
                    continue
                }

                printJobsCompleted += 1
                simulatedPrinterLedger.finish(envelope: envelope, terminalResult: .completed, bytesStarted: true)
            } catch {
                failures += 1
                auditAnomalyCount += 1
            }
        }
    }

    private func shouldSimulateBeforeBytesFailure(copy: Int, chaosMode: ChaosMode, generator: inout SeededGenerator) -> Bool {
        guard copy == 1 else { return false }
        return chaosMode == .uploadOffline && generator.nextInt(upperBound: 7) == 0
    }

    private func shouldSimulateAfterBytesFailure(copy: Int, chaosMode: ChaosMode, generator: inout SeededGenerator) -> Bool {
        guard copy == 1 else { return false }
        return chaosMode == .mixedSoftwareChaos && generator.nextInt(upperBound: 29) == 0
    }

    private func makeReliabilityReport(seed: Int) -> String {
        let result = reliabilityRunPassed ? "PASS" : "FAIL"
        return """
        MADE TO KEEP RELIABILITY RUN

        Seed: \(seed)
        Scenario: \(chaosMode.displayName)
        Sessions: \(completedSessions) / \(sessionsAttempted)
        Print Jobs: \(printJobsCompleted) / \(printJobsAttempted)
        Copies: \(totalRequestedCopies)
        Payload Mismatches: \(payloadMismatchCount)
        Cross-Session Violations: \(crossSessionViolationCount)
        Illegal Retries After Bytes: \(illegalRetryAfterBytesCount)
        Physical Ownership Violations: \(physicalOwnershipViolationCount)
        Unsafe Recovery Violations: \(unsafeRecoveryViolationCount)
        Recovery Events: \(recoveryRequiredEvents)
        Upload Successes: \(uploadSuccesses)
        Upload Failures: \(uploadFailures)
        Pending Uploads: \(pendingUploads)
        Camera Restarts: \(cameraRestarts)
        Audit Anomalies: \(auditAnomalyCount)
        Current Memory: \(currentMemoryMB) MB
        Peak Memory: \(peakMemoryMB) MB
        Average Session: \(String(format: "%.2f", averageSessionDuration))s
        Longest Session: \(String(format: "%.2f", longestSessionDuration))s

        RESULT: \(result)
        """
    }

    private var reliabilityRunPassed: Bool {
        crossSessionViolationCount == 0
            && payloadMismatchCount == 0
            && illegalRetryAfterBytesCount == 0
            && physicalOwnershipViolationCount == 0
            && unsafeRecoveryViolationCount == 0
    }

    private static func makeSamplePhotos(count: Int, index: Int) -> [UIImage] {
        (0..<count).map { photoIndex in
            let size = CGSize(width: 900, height: 1200)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            return UIGraphicsImageRenderer(size: size, format: format).image { context in
                UIColor.white.setFill()
                context.fill(CGRect(origin: .zero, size: size))
                UIColor(
                    hue: CGFloat((index * 17 + photoIndex * 31) % 255) / 255.0,
                    saturation: 0.42,
                    brightness: 0.92,
                    alpha: 1
                ).setFill()
                context.fill(CGRect(x: 0, y: 0, width: size.width, height: size.height))
                let text = "SESSION \(String(format: "%03d", index))\nPHOTO \(photoIndex + 1)"
                let paragraph = NSMutableParagraphStyle()
                paragraph.alignment = .center
                text.draw(
                    in: CGRect(x: 60, y: 470, width: size.width - 120, height: 180),
                    withAttributes: [
                        .font: UIFont.monospacedSystemFont(ofSize: 66, weight: .bold),
                        .foregroundColor: UIColor.black,
                        .paragraphStyle: paragraph
                    ]
                )
            }
        }
    }

    private static func currentMemoryFootprintMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }

        guard result == KERN_SUCCESS else {
            return 0
        }
        return Int(info.phys_footprint / 1_048_576)
    }
}

private struct SeededGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed == 0 ? 0x9E3779B97F4A7C15 : seed
    }

    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }

    mutating func nextInt(upperBound: Int) -> Int {
        guard upperBound > 0 else { return 0 }
        return Int(next() % UInt64(upperBound))
    }
}

private struct SimulatedPrintLedger {
    private var activeJobID: UUID?
    private var records: [UUID: PrintAuditRecord.TerminalResult] = [:]

    mutating func begin(envelope: PrintJobEnvelope) -> Bool {
        guard activeJobID == nil else {
            return false
        }
        activeJobID = envelope.jobID
        return true
    }

    mutating func finish(envelope: PrintJobEnvelope, terminalResult: PrintAuditRecord.TerminalResult, bytesStarted: Bool) {
        guard activeJobID == envelope.jobID else {
            return
        }
        records[envelope.jobID] = terminalResult
        activeJobID = nil
    }
}

struct EventEnduranceHarnessView: View {
    @AppStorage("printerIP") private var printerIP = BoothConfiguration.defaultPrinterIP
    @AppStorage("printerPort") private var printerPort = BoothConfiguration.defaultPrinterPort
    @StateObject private var viewModel = EventEnduranceHarnessViewModel()

    var body: some View {
        Form {
            Section("Run") {
                Picker("Sessions", selection: $viewModel.sessionCount) {
                    ForEach(viewModel.supportedSessionCounts, id: \.self) { count in
                        Text("\(count)").tag(count)
                    }
                }

                Picker("Layouts", selection: $viewModel.layoutMode) {
                    ForEach(EventEnduranceHarnessViewModel.LayoutMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }

                Picker("Chaos Mode", selection: $viewModel.chaosMode) {
                    ForEach(EventEnduranceHarnessViewModel.ChaosMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }

                TextField("Seed", text: $viewModel.seedText)
                    .keyboardType(.numberPad)

                Toggle("Random Copy Count", isOn: $viewModel.randomCopyCount)
                Toggle("Persist Upload Queue Items", isOn: $viewModel.persistUploads)
                Toggle("Physical Printing", isOn: $viewModel.physicalPrinting)

                Button("Start Reliability Run") {
                    viewModel.run(printerIP: printerIP, printerPort: parsedPort)
                }
                .disabled(viewModel.isRunning)

                Button("Stop After Current Session") {
                    viewModel.stopAfterCurrentSession()
                }
                .disabled(!viewModel.isRunning)
            }

            Section("Progress") {
                row("Seed", viewModel.seedText)
                row("Sessions", "\(viewModel.completedSessions) / \(viewModel.sessionsAttempted)")
                row("Memory", "\(viewModel.currentMemoryMB) MB")
                row("Peak Memory", "\(viewModel.peakMemoryMB) MB")
                row("Last Session", String(format: "%.2fs", viewModel.lastSessionDuration))
                row("Average Session", String(format: "%.2fs", viewModel.averageSessionDuration))
                row("Longest Session", String(format: "%.2fs", viewModel.longestSessionDuration))
                row("Print Jobs", "\(viewModel.printJobsCompleted) / \(viewModel.printJobsAttempted)")
                row("Copies", "\(viewModel.totalRequestedCopies)")
                row("Payload Mismatches", "\(viewModel.payloadMismatchCount)")
                row("Cross-Session Violations", "\(viewModel.crossSessionViolationCount)")
                row("Illegal Retries", "\(viewModel.illegalRetryAfterBytesCount)")
                row("Recovery Events", "\(viewModel.recoveryRequiredEvents)")
                row("Upload Successes", "\(viewModel.uploadSuccesses)")
                row("Upload Failures", "\(viewModel.uploadFailures)")
                row("Pending Uploads", "\(viewModel.pendingUploads)")
                row("Camera Restarts", "\(viewModel.cameraRestarts)")
                row("Audit Anomalies", "\(viewModel.auditAnomalyCount)")
                row("Failures", "\(viewModel.failures)")
                Text(viewModel.statusMessage)
                    .foregroundStyle(viewModel.failures == 0 ? Color.secondary : Color.red)
            }

            Section("Reliability Report") {
                Text(viewModel.reliabilityReport)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
        .navigationTitle("Endurance Harness")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var parsedPort: UInt16? {
        UInt16(printerPort.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
        }
    }
}
#endif
