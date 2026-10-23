//
//  PrinterBluetoothService.swift
//  PocketPixelsBooth
//

import CoreBluetooth
import Combine
import CryptoKit
import Foundation
import UIKit

struct BluetoothPrinterCandidate: Identifiable, Equatable {
    let id: UUID
    let name: String
    let rssi: Int
    let isLikelyPrinter: Bool
}

enum BluetoothPrinterRasterMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case reliable
    case balanced
    case fast

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .reliable:
            return "Reliable"
        case .balanced:
            return "Balanced"
        case .fast:
            return "Fast"
        }
    }

    var writeType: CBCharacteristicWriteType {
        switch self {
        case .reliable:
            return .withResponse
        case .balanced, .fast:
            return .withoutResponse
        }
    }

    var progressLabel: String {
        switch self {
        case .reliable:
            return "Acknowledged"
        case .balanced, .fast:
            return "Queued to BLE"
        }
    }
}

struct BalancedBluetoothPrinterProfile: Identifiable, Equatable, Hashable {
    let id: String
    let displayName: String
    let chunkLimit: Int
    let burstChunkCount: Int
    let interBurstDelay: TimeInterval

    var interBurstDelayMilliseconds: Int {
        Int((interBurstDelay * 1_000).rounded())
    }

    static let light = BalancedBluetoothPrinterProfile(
        id: "light",
        displayName: "Light",
        chunkLimit: 512,
        burstChunkCount: 4,
        interBurstDelay: 0.020
    )

    static let medium = BalancedBluetoothPrinterProfile(
        id: "medium",
        displayName: "Medium",
        chunkLimit: 512,
        burstChunkCount: 8,
        interBurstDelay: 0.015
    )

    static let fast = BalancedBluetoothPrinterProfile(
        id: "fast",
        displayName: "Fast",
        chunkLimit: 512,
        burstChunkCount: 12,
        interBurstDelay: 0.010
    )

    static let allPresets = [light, medium, fast]
}

struct BluetoothPrinterMetrics: Equatable {
    let mode: BluetoothPrinterRasterMode
    let balancedProfileName: String?
    let photoCalibrationProfileName: String?
    let payloadByteCount: Int
    let rasterByteCount: Int
    let maximumWriteLength: Int
    let chunkSize: Int
    let chunkCount: Int
    let burstChunkCount: Int?
    let interBurstDelayMilliseconds: Int?
    let burstCount: Int
    let transferredBytes: Int
    let duration: TimeInterval?
    let throughputBytesPerSecond: Double?
    let flowControlPauseCount: Int
    let longestFlowControlPause: TimeInterval?
    let flowControlPauseEvents: [BluetoothPrinterFlowControlPauseEvent]
    let intentionalPacingPauseCount: Int
    let physicalPrintDuration: TimeInterval?

    var progress: Double {
        guard payloadByteCount > 0 else {
            return 0
        }

        return min(1, Double(transferredBytes) / Double(payloadByteCount))
    }

    var rasterFlowPauseRowSummary: String? {
        let rows = flowControlPauseEvents.compactMap(\.rasterRow)

        guard !rows.isEmpty else {
            return nil
        }

        let uniqueRows = Array(Set(rows)).sorted()
        let displayedRows = uniqueRows.prefix(12).map { "~\($0)" }.joined(separator: ", ")

        if uniqueRows.count > 12 {
            return "\(displayedRows), +\(uniqueRows.count - 12) more"
        }

        return displayedRows
    }
}

struct BluetoothPrinterFlowControlPauseEvent: Equatable {
    let transferredBytes: Int
    let rasterByteOffset: Int?
    let rasterRow: Int?
    let duration: TimeInterval
}

#if DEBUG
enum SilentBLETest: String, CaseIterable, Identifiable {
    case minimalTextNoCutter = "A"
    case currentGSVCut = "B"
    case escICut = "C"
    case escMCut = "D"
    case gsvOneCut = "E"

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .minimalTextNoCutter:
            "Test A - No Cut"
        case .currentGSVCut:
            "Test B - GS V 66 0"
        case .escICut:
            "Test C - ESC i"
        case .escMCut:
            "Test D - ESC m"
        case .gsvOneCut:
            "Test E - GS V 1"
        }
    }

    var hasCutter: Bool {
        cutterCommand != nil
    }

    var commandName: String {
        switch self {
        case .minimalTextNoCutter:
            "No cutter"
        case .currentGSVCut:
            "GS V 66 0"
        case .escICut:
            "ESC i"
        case .escMCut:
            "ESC m"
        case .gsvOneCut:
            "GS V 1"
        }
    }

    var cutterHex: String {
        cutterCommand?.hexString ?? "none"
    }

    var cutterCommand: Data? {
        switch self {
        case .minimalTextNoCutter:
            nil
        case .currentGSVCut:
            Data([0x1D, 0x56, 0x42, 0x00])
        case .escICut:
            Data([0x1B, 0x69])
        case .escMCut:
            Data([0x1B, 0x6D])
        case .gsvOneCut:
            Data([0x1D, 0x56, 0x01])
        }
    }
}
#endif

enum BluetoothPrinterJobState: Equatable {
    case idle
    case scanning
    case connecting(String)
    case connected(String)
    case preparing
    case sending(bytesSent: Int, totalBytes: Int)
    case finalizing
    case cutting
    case printerProcessing
    case coolingDown
    case recoveryRequired(String)
    case success(String)
    case failure(String)

    var message: String {
        switch self {
        case .idle:
            return "Bluetooth raster test is ready."
        case .scanning:
            return "Scanning for Bluetooth printers..."
        case .connecting(let name):
            return "Connecting to \(name)..."
        case .connected(let name):
            return "Connected to \(name)."
        case .preparing:
            return "Preparing Bluetooth raster job..."
        case .sending(let bytesSent, let totalBytes):
            let percent = totalBytes > 0 ? Int((Double(bytesSent) / Double(totalBytes)) * 100) : 0
            return "Sending to printer \(percent)% (\(bytesSent) / \(totalBytes) bytes)."
        case .finalizing:
            return "Finalizing Bluetooth print data..."
        case .cutting:
            return "Sending feed and partial cut..."
        case .printerProcessing:
            return "Bytes accepted by BLE. Waiting briefly while the printer processes."
        case .coolingDown:
            return "Cooling down before another Bluetooth raster test..."
        case .recoveryRequired(let message), .success(let message), .failure(let message):
            return message
        }
    }

    var isWorking: Bool {
        switch self {
        case .scanning, .connecting, .preparing, .sending, .finalizing, .cutting, .printerProcessing, .coolingDown:
            true
        case .idle, .connected, .recoveryRequired, .success, .failure:
            false
        }
    }

    var requiresRecovery: Bool {
        if case .recoveryRequired = self {
            return true
        }

        return false
    }
}

enum BluetoothPrinterServiceError: Error, LocalizedError {
    case bluetoothUnavailable(String)
    case printerNotConnected
    case knownCharacteristicUnavailable
    case jobAlreadyActive
    case recoveryRequired
    case connectionTestRequired
    case invalidRaster(String)
    case sendFailed(String)

    var errorDescription: String? {
        switch self {
        case .bluetoothUnavailable(let message):
            message
        case .printerNotConnected:
            "Connect to the VOZY G80 Bluetooth printer before sending a raster job."
        case .knownCharacteristicUnavailable:
            "The connected printer did not expose the confirmed 18F0 / 2AF1 write characteristic."
        case .jobAlreadyActive:
            "A Bluetooth printer job is already active."
        case .recoveryRequired:
            "Bluetooth Printer Recovery Required. Turn the printer off for 10 seconds, turn it back on, reconnect Bluetooth, then run a text test before another raster job."
        case .connectionTestRequired:
            "Run the Bluetooth diagnostic text test after reconnecting before another raster job."
        case .invalidRaster(let message):
            "Bluetooth raster preflight failed. \(message)"
        case .sendFailed(let message):
            "Bluetooth raster send failed. \(message)"
        }
    }
}

@MainActor
final class PrinterBluetoothService: NSObject, ObservableObject {
    typealias CompletionHandler = (Result<Void, BluetoothPrinterServiceError>, Bool) -> Void

    private struct PendingJob {
        let id: UInt64
        let label: String
        let mode: BluetoothPrinterRasterMode
        let balancedProfile: BalancedBluetoothPrinterProfile?
        let photoCalibrationProfileName: String?
        let payloadFingerprint: String
        let chunks: [Data]
        let totalBytes: Int
        let rasterByteCount: Int
        let rasterDataStartByteOffset: Int?
        let maximumWriteLength: Int
        let chunkSize: Int
        let chunkCount: Int
        let imageHeight: Int?
        let startedAt: Date
        let rasterStartChunkIndex: Int
        let finishingStartChunkIndex: Int
        var transportCompletionScheduled: Bool
    }

    static let vozyServiceUUID = CBUUID(string: "18F0")
    static let vozyWriteCharacteristicUUID = CBUUID(string: "2AF1")
    static let shared = PrinterBluetoothService()
    private static let reliableChunkLimit = 182
    private static let fastInitialChunkLimit = 512
    private static let knownPrinterIdentifierKey = "knownBluetoothPrinterIdentifier"
    private static let knownPrinterNameKey = "knownBluetoothPrinterName"

    @Published private(set) var bluetoothState = "Unknown"
    @Published private(set) var candidates: [BluetoothPrinterCandidate] = []
    @Published private(set) var connectedPrinterName: String?
    @Published private(set) var savedPrinterName: String?
    @Published private(set) var jobState = BluetoothPrinterJobState.idle
    @Published private(set) var metrics: BluetoothPrinterMetrics?
    @Published private(set) var diagnosticLog: [String] = []

    private let scanDuration: TimeInterval = 10
    private let printerProcessingDelay: TimeInterval = 1.5
    private let postCutHandoffDelay: TimeInterval = 0.75
    private let conservativeThermalPrintMillimetersPerSecond: Double = 34
    private let estimatedCutAndSettleDelay: TimeInterval = 1.75
    private let reliableWriteAcknowledgementTimeout: TimeInterval = 6
    private let flowControlPauseTimeout: TimeInterval = 10
    private var centralManager: CBCentralManager?
    private var scanStopTask: Task<Void, Never>?
    private var peripheralsByID: [UUID: CBPeripheral] = [:]
    private var connectedPeripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var pendingCompletion: CompletionHandler?
    private var pendingJob: PendingJob?
    private var jobLifecycle = BluetoothPrinterJobLifecycle()
    private var pendingChunkIndex = 0
    private var transferredBytes = 0
    private var rasterTransmissionBegan = false
    private var printBytesStarted = false
    private var isJobActive = false
    private var recoveryLockoutActive = false
    private var requiresTextTestBeforeRasterPrint = false
    private var operatorDisconnectInProgress = false
    private var flowControlPauseCount = 0
    private var currentFlowControlPauseStartedAt: Date?
    private var currentFlowControlPausePosition: (transferredBytes: Int, rasterByteOffset: Int?, rasterRow: Int?)?
    private var flowControlPauseEvents: [BluetoothPrinterFlowControlPauseEvent] = []
    private var longestFlowControlPause: TimeInterval?
    private var lastJobStartedAt: Date?
    private var chunksSentInCurrentBurst = 0
    private var burstCount = 0
    private var intentionalPacingPauseCount = 0
    private var pacingPauseTask: Task<Void, Never>?
    private var postSendCompletionTask: Task<Void, Never>?
    private var reliableWriteWatchdogTask: Task<Void, Never>?
    private var flowControlWatchdogTask: Task<Void, Never>?
    private var lastWriteTimeoutDuration: TimeInterval?
    private var shouldPrepareWhenPoweredOn = false
    private var scanShouldConnectFirstCandidate = false
    private var reconnectAttemptsRemaining = 0
    private var idleReconnectBudget = 2

    override init() {
        savedPrinterName = UserDefaults.standard.string(forKey: Self.knownPrinterNameKey)
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
    }

    var canScan: Bool {
        centralManager?.state == .poweredOn && connectedPeripheral == nil && !jobState.isWorking
    }

    var isScanning: Bool {
        if case .scanning = jobState {
            return true
        }

        return false
    }

    var canConnect: Bool {
        centralManager?.state == .poweredOn && connectedPeripheral == nil && !jobState.isWorking
    }

    var needsDiagnosticTextTest: Bool { requiresTextTestBeforeRasterPrint }

    var canPrintRaster: Bool {
        isConnectedAndReady
            && !isJobActive
            && !jobState.isWorking
            && !recoveryLockoutActive
            && !requiresTextTestBeforeRasterPrint
    }

    var isConnectedAndReady: Bool {
        connectedPeripheral?.state == .connected && writeCharacteristic != nil
    }

    var lastReliableWriteTimeout: TimeInterval? {
        lastWriteTimeoutDuration
    }

    var hasSavedPrinter: Bool {
        knownPrinterIdentifier != nil
    }

    /// Explain recovery separately from a missing radio connection.
    var readinessMessage: String {
        if recoveryLockoutActive { return BluetoothPrinterServiceError.recoveryRequired.localizedDescription }
        if requiresTextTestBeforeRasterPrint { return "A diagnostic text check is required. Open Recovery, reconnect if needed, print diagnostic text, then confirm it printed correctly." }
        if isJobActive { return "Printer is finishing the current job." }
        if canPrintRaster { return "\(connectedPrinterName ?? savedPrinterName ?? "Bluetooth printer") ready" }
        return jobState.message
    }

    /// Allow discovery/reconnection to finish before refusing a checkout. Never sends print bytes.
    func waitUntilReady(timeout: TimeInterval = 12) async throws -> Bool {
        try Task.checkCancellation()
        guard !isJobActive, !recoveryLockoutActive, !requiresTextTestBeforeRasterPrint else { return false }
        if canPrintRaster { return true }
        prepareSavedPrinter()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try Task.checkCancellation()
            if canPrintRaster { return true }
            if recoveryLockoutActive || requiresTextTestBeforeRasterPrint || isJobActive { return false }
            try await Task.sleep(for: .milliseconds(200))
        }
        return canPrintRaster
    }

    func prepareSavedPrinter() {
        // View appearances and readiness checks must not reset an active job or rediscover
        // characteristics while a connection/discovery is already in progress.
        guard !isJobActive else { return }
        if let peripheral = connectedPeripheral,
           peripheral.state == .connecting || peripheral.state == .connected { return }
        guard !isScanning else { return }
        guard let centralManager else {
            return
        }

        guard centralManager.state == .poweredOn else {
            shouldPrepareWhenPoweredOn = true
            bluetoothState = centralManager.state.displayName
            if centralManager.state == .poweredOff {
                jobState = .failure("Bluetooth is off on this iPad.")
            }
            return
        }

        shouldPrepareWhenPoweredOn = false

        stopScan()

        if let identifier = knownPrinterIdentifier {
            let peripherals = centralManager.retrievePeripherals(withIdentifiers: [identifier])
            if let peripheral = peripherals.first {
                connectForProduction(to: peripheral, reason: "saved identifier")
                return
            }
        }

        let connectedPeripherals = centralManager.retrieveConnectedPeripherals(withServices: [Self.vozyServiceUUID])
        if let peripheral = connectedPeripherals.first {
            connectForProduction(to: peripheral, reason: "connected 18F0 peripheral")
            return
        }

        startTargetedReconnectScan()
    }

    func reconnectSavedPrinter() {
        if isJobActive {
            jobState = .failure("Wait for the current Bluetooth printer job to finish before reconnecting.")
            return
        }

        if let connectedPeripheral {
            centralManager?.cancelPeripheralConnection(connectedPeripheral)
            clearConnection()
        }

        reconnectAttemptsRemaining = 1
        prepareSavedPrinter()
    }

    func forgetKnownPrinter() {
        disconnect()
        UserDefaults.standard.removeObject(forKey: Self.knownPrinterIdentifierKey)
        UserDefaults.standard.removeObject(forKey: Self.knownPrinterNameKey)
        savedPrinterName = nil
        candidates = []
        appendLog("Forgot saved Bluetooth printer.")
    }

    func startScan() {
        guard centralManager?.state == .poweredOn else {
            jobState = .failure("Bluetooth must be powered on before scanning.")
            return
        }

        guard connectedPeripheral == nil else {
            jobState = .failure("Disconnect before scanning for another Bluetooth printer.")
            return
        }

        stopScan()
        candidates = []
        peripheralsByID = [:]
        scanShouldConnectFirstCandidate = false
        jobState = .scanning
        appendLog("BT2 scan started for \(Int(scanDuration)) seconds.")

        centralManager?.scanForPeripherals(withServices: [Self.vozyServiceUUID], options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: false
        ])

        scanStopTask = Task { [weak self, scanDuration] in
            try? await Task.sleep(nanoseconds: UInt64(scanDuration * 1_000_000_000))
            self?.finishTimedScan()
        }
    }

    func stopScan() {
        scanStopTask?.cancel()
        scanStopTask = nil
        centralManager?.stopScan()
        scanShouldConnectFirstCandidate = false

        if case .scanning = jobState {
            jobState = candidates.isEmpty ? .idle : .failure("Scan stopped. Select a discovered printer or scan again.")
        }
    }

    func connect(to candidateID: UUID) {
        guard canConnect else {
            jobState = .failure("Bluetooth printer is busy or already connected.")
            return
        }

        guard let peripheral = peripheralsByID[candidateID] else {
            jobState = .failure("Selected Bluetooth printer is no longer available.")
            return
        }

        stopScan()
        connectedPeripheral = peripheral
        writeCharacteristic = nil
        operatorDisconnectInProgress = false
        peripheral.delegate = self
        jobState = .connecting(peripheralDisplayName(peripheral))
        appendLog("Connecting to \(peripheralDisplayName(peripheral)).")
        centralManager?.connect(peripheral, options: nil)
    }

    func disconnect() {
        stopScan()
        operatorDisconnectInProgress = true

        if isJobActive {
            failActiveJob(message: "Bluetooth raster job interrupted by operator disconnect.")
        }

        if let connectedPeripheral {
            centralManager?.cancelPeripheralConnection(connectedPeripheral)
        }

        clearConnection()
        jobState = .idle
        appendLog("Operator disconnected Bluetooth printer.")
    }

    func confirmPrinterRestarted() {
        recoveryLockoutActive = false
        requiresTextTestBeforeRasterPrint = true
        jobState = .idle
        appendLog("Bluetooth recovery lockout cleared by operator. Diagnostic text test is required before another raster job.")
    }

    func confirmDiagnosticTextTestSucceeded() {
        guard connectedPeripheral != nil, writeCharacteristic != nil else {
            jobState = .failure("Reconnect the VOZY G80 and discover 18F0 / 2AF1 before clearing the text-test requirement.")
            return
        }

        requiresTextTestBeforeRasterPrint = false
        jobState = .connected(connectedPrinterName ?? "Bluetooth printer")
        appendLog("Operator confirmed diagnostic text test after Bluetooth recovery.")
    }

    var canMarkPaperComplete: Bool {
        if case .success = jobState {
            return metrics?.physicalPrintDuration == nil
        }

        return false
    }

    func printPhoto(
        rasterizedImage: ThermalRasterizedImage,
        mode: BluetoothPrinterRasterMode,
        balancedProfile: BalancedBluetoothPrinterProfile,
        calibrationProfileName: String,
        completion: CompletionHandler? = nil
    ) {
        let heading = ThermalImageRasterizer.photoTestHeading()
        let finishing = ThermalImageRasterizer.photoTestFinishing()
        startRasterJob(
            label: "Photo Raster Test",
            mode: mode,
            balancedProfile: balancedProfile,
            photoCalibrationProfileName: calibrationProfileName,
            heading: heading,
            rasterCommand: rasterizedImage.rasterCommand,
            finishing: finishing,
            imageWidth: rasterizedImage.width,
            imageHeight: rasterizedImage.height,
            rasterDataByteCount: rasterizedImage.rasterData.count,
            sanitizationReport: rasterizedImage.sanitizationReport,
            yL: rasterizedImage.yL,
            yH: rasterizedImage.yH,
            completion: completion
        )
    }

    func printReceipt(
        _ receipt: ComposedReceipt,
        mode: BluetoothPrinterRasterMode,
        balancedProfile: BalancedBluetoothPrinterProfile,
        completion: CompletionHandler? = nil
    ) {
        guard let image = UIImage(data: receipt.imagePNGData) else {
            jobState = .failure("The composed receipt image could not be loaded for Bluetooth rasterization.")
            return
        }

        jobState = .preparing

        Task {
            do {
                let rasterized = try await Task.detached(priority: .userInitiated) {
                    try ThermalImageRasterizer.rasterize(image, purpose: .completeReceipt)
                }.value

                startReceiptRasterJob(
                    receipt: receipt,
                    rasterizedImage: rasterized,
                    mode: mode,
                    balancedProfile: balancedProfile,
                    completion: completion
                )
            } catch {
                completion?(.failure(.sendFailed(error.localizedDescription)), false)
                jobState = .failure(error.localizedDescription)
            }
        }
    }

    func printRasterizedReceipt(
        rasterizedImage: ThermalRasterizedImage,
        mode: BluetoothPrinterRasterMode,
        balancedProfile: BalancedBluetoothPrinterProfile,
        completion: CompletionHandler? = nil
    ) {
        startReceiptRasterJob(
            receiptLabel: "Customer Receipt",
            rasterizedImage: rasterizedImage,
            mode: mode,
            balancedProfile: balancedProfile,
            completion: completion
        )
    }

    func printEnvelope(
        _ envelope: PrintJobEnvelope,
        mode: BluetoothPrinterRasterMode,
        balancedProfile: BalancedBluetoothPrinterProfile,
        completion: CompletionHandler? = nil
    ) {
        startEnvelopeRasterJob(
            envelope: envelope,
            mode: mode,
            balancedProfile: balancedProfile,
            completion: completion
        )
    }

    func markPaperComplete() {
        guard let lastJobStartedAt, let currentMetrics = metrics else {
            return
        }

        self.metrics = BluetoothPrinterMetrics(
            mode: currentMetrics.mode,
            balancedProfileName: currentMetrics.balancedProfileName,
            photoCalibrationProfileName: currentMetrics.photoCalibrationProfileName,
            payloadByteCount: currentMetrics.payloadByteCount,
            rasterByteCount: currentMetrics.rasterByteCount,
            maximumWriteLength: currentMetrics.maximumWriteLength,
            chunkSize: currentMetrics.chunkSize,
            chunkCount: currentMetrics.chunkCount,
            burstChunkCount: currentMetrics.burstChunkCount,
            interBurstDelayMilliseconds: currentMetrics.interBurstDelayMilliseconds,
            burstCount: currentMetrics.burstCount,
            transferredBytes: currentMetrics.transferredBytes,
            duration: currentMetrics.duration,
            throughputBytesPerSecond: currentMetrics.throughputBytesPerSecond,
            flowControlPauseCount: currentMetrics.flowControlPauseCount,
            longestFlowControlPause: currentMetrics.longestFlowControlPause,
            flowControlPauseEvents: currentMetrics.flowControlPauseEvents,
            intentionalPacingPauseCount: currentMetrics.intentionalPacingPauseCount,
            physicalPrintDuration: Date().timeIntervalSince(lastJobStartedAt)
        )
        appendLog("Operator marked physical paper complete after \(String(format: "%.2f", self.metrics?.physicalPrintDuration ?? 0)) seconds.")
    }

    func printQuickText(completion: CompletionHandler? = nil) {
        // This is the test required to unlock raster printing after a physical restart.
        // Requiring that same test here makes recovery impossible. Active-job and
        // unacknowledged-restart lockouts still apply inside beginJob.
        guard let jobID = beginJob(requiresVerifiedTextTest: false) else {
            completion?(.failure(.jobAlreadyActive), false)
            return
        }

        pendingCompletion = completion

        guard let peripheral = connectedPeripheral, peripheral.state == .connected else {
            finishJob(expectedJobID: jobID, result: .failure(.printerNotConnected))
            return
        }

        guard let writeCharacteristic else {
            finishJob(expectedJobID: jobID, result: .failure(.knownCharacteristicUnavailable))
            return
        }

        guard writeCharacteristic.properties.contains(.writeWithoutResponse) else {
            finishJob(expectedJobID: jobID, result: .failure(.sendFailed("Characteristic 2AF1 does not support writeWithoutResponse.")))
            return
        }

        let payload = Data([0x1B, 0x40])
            + Data("MADE TO KEEP\nBT OK\n\n\n".utf8)
        let maximumLength = max(1, peripheral.maximumWriteValueLength(for: .withoutResponse))
        let chunkSize = max(1, min(Self.fastInitialChunkLimit, maximumLength))
        let chunks = payload.chunked(maximumLength: chunkSize)

        pendingJob = PendingJob(
            id: jobID,
            label: "Quick Bluetooth Text Test",
            mode: .fast,
            balancedProfile: nil,
            photoCalibrationProfileName: nil,
            payloadFingerprint: payload.shortSHA256Fingerprint,
            chunks: chunks,
            totalBytes: payload.count,
            rasterByteCount: 0,
            rasterDataStartByteOffset: nil,
            maximumWriteLength: maximumLength,
            chunkSize: chunkSize,
            chunkCount: chunks.count,
            imageHeight: nil,
            startedAt: Date(),
            rasterStartChunkIndex: 0,
            finishingStartChunkIndex: chunks.count,
            transportCompletionScheduled: false
        )
        pendingChunkIndex = 0
        transferredBytes = 0
        rasterTransmissionBegan = false
        printBytesStarted = false
        flowControlPauseCount = 0
        currentFlowControlPauseStartedAt = nil
        currentFlowControlPausePosition = nil
        flowControlPauseEvents = []
        longestFlowControlPause = nil
        lastJobStartedAt = Date()
        chunksSentInCurrentBurst = 0
        burstCount = chunks.isEmpty ? 0 : 1
        intentionalPacingPauseCount = 0
        metrics = BluetoothPrinterMetrics(
            mode: .fast,
            balancedProfileName: nil,
            photoCalibrationProfileName: nil,
            payloadByteCount: payload.count,
            rasterByteCount: 0,
            maximumWriteLength: maximumLength,
            chunkSize: chunkSize,
            chunkCount: chunks.count,
            burstChunkCount: nil,
            interBurstDelayMilliseconds: nil,
            burstCount: burstCount,
            transferredBytes: 0,
            duration: nil,
            throughputBytesPerSecond: nil,
            flowControlPauseCount: 0,
            longestFlowControlPause: nil,
            flowControlPauseEvents: [],
            intentionalPacingPauseCount: 0,
            physicalPrintDuration: nil
        )
        appendJobLog(jobID: jobID, "Quick Bluetooth text test started. Payload: \(payload.shortSHA256Fingerprint). Write characteristic: 18F0 / 2AF1. Chunk size: \(chunkSize).")
        sendNextChunk()
    }

#if DEBUG
    func printSilentBLETest(_ test: SilentBLETest, completion: CompletionHandler? = nil) {
        let payload = silentBLEPayload(for: test)
        startDebugFastPayloadJob(
            label: "Silent Cut Test \(test.rawValue)",
            payload: payload,
            completion: completion,
            logLines: [
                "[SILENT-CUT] test=\(test.rawValue)",
                "[SILENT-CUT] command=\(test.commandName)",
                "[SILENT-CUT] hex=\(test.cutterHex)",
                "[SILENT-CUT] hasCutter=\(test.hasCutter ? "yes" : "no")",
                "[SILENT-CUT] payloadBytes=\(payload.count)",
                "[SILENT-CUT] writeMode=\(BluetoothPrinterRasterMode.fast.writeType.logName)"
            ]
        )
    }

    func sendVOZYCutterAlarmOffConfiguration(completion: CompletionHandler? = nil) {
        sendVOZYCutterAlarmConfiguration(
            label: "VOZY Cutter Alarm Off Config",
            variant: "related-pos80",
            payload: Self.vozyCutterAlarmOffPayload,
            completion: completion
        )
    }

    func sendVOZYAltFirmwareCutterAlarmOffConfiguration(completion: CompletionHandler? = nil) {
        sendVOZYCutterAlarmConfiguration(
            label: "VOZY Cutter Alarm Off Alt Firmware Config",
            variant: "alt-firmware",
            payload: Self.vozyAltFirmwareCutterAlarmOffPayload,
            completion: completion
        )
    }

    private func sendVOZYCutterAlarmConfiguration(
        label: String,
        variant: String,
        payload: Data,
        completion: CompletionHandler?
    ) {
        startDebugFastPayloadJob(
            label: label,
            payload: payload,
            completion: completion,
            logLines: [
                "[VOZY-CONFIG] setting=cutter-with-alarm",
                "[VOZY-CONFIG] variant=\(variant)",
                "[VOZY-CONFIG] requestedState=off",
                "[VOZY-CONFIG] hex=\(payload.hexString)",
                "[VOZY-CONFIG] payloadBytes=\(payload.count)",
                "[VOZY-CONFIG] experimental=yes",
                "[VOZY-CONFIG] Command transmission only; power-cycle and physical cutter test required for validation."
            ]
        )
    }

    private func startDebugFastPayloadJob(
        label: String,
        payload: Data,
        completion: CompletionHandler?,
        logLines: [String]
    ) {
        guard let jobID = beginJob() else {
            completion?(.failure(.jobAlreadyActive), false)
            return
        }

        pendingCompletion = completion

        guard let peripheral = connectedPeripheral, peripheral.state == .connected else {
            finishJob(expectedJobID: jobID, result: .failure(.printerNotConnected))
            return
        }

        guard let writeCharacteristic else {
            finishJob(expectedJobID: jobID, result: .failure(.knownCharacteristicUnavailable))
            return
        }

        guard writeCharacteristic.properties.contains(.writeWithoutResponse) else {
            finishJob(expectedJobID: jobID, result: .failure(.sendFailed("Characteristic 2AF1 does not support writeWithoutResponse.")))
            return
        }

        let maximumLength = max(1, peripheral.maximumWriteValueLength(for: .withoutResponse))
        let chunkSize = max(1, min(Self.fastInitialChunkLimit, maximumLength))
        let chunks = payload.chunked(maximumLength: chunkSize)

        pendingJob = PendingJob(
            id: jobID,
            label: label,
            mode: .fast,
            balancedProfile: nil,
            photoCalibrationProfileName: nil,
            payloadFingerprint: payload.shortSHA256Fingerprint,
            chunks: chunks,
            totalBytes: payload.count,
            rasterByteCount: 0,
            rasterDataStartByteOffset: nil,
            maximumWriteLength: maximumLength,
            chunkSize: chunkSize,
            chunkCount: chunks.count,
            imageHeight: nil,
            startedAt: Date(),
            rasterStartChunkIndex: chunks.count,
            finishingStartChunkIndex: chunks.count,
            transportCompletionScheduled: false
        )
        pendingChunkIndex = 0
        transferredBytes = 0
        rasterTransmissionBegan = false
        printBytesStarted = false
        flowControlPauseCount = 0
        currentFlowControlPauseStartedAt = nil
        currentFlowControlPausePosition = nil
        flowControlPauseEvents = []
        longestFlowControlPause = nil
        lastJobStartedAt = Date()
        chunksSentInCurrentBurst = 0
        burstCount = chunks.isEmpty ? 0 : 1
        intentionalPacingPauseCount = 0
        metrics = BluetoothPrinterMetrics(
            mode: .fast,
            balancedProfileName: nil,
            photoCalibrationProfileName: nil,
            payloadByteCount: payload.count,
            rasterByteCount: 0,
            maximumWriteLength: maximumLength,
            chunkSize: chunkSize,
            chunkCount: chunks.count,
            burstChunkCount: nil,
            interBurstDelayMilliseconds: nil,
            burstCount: burstCount,
            transferredBytes: 0,
            duration: nil,
            throughputBytesPerSecond: nil,
            flowControlPauseCount: 0,
            longestFlowControlPause: nil,
            flowControlPauseEvents: [],
            intentionalPacingPauseCount: 0,
            physicalPrintDuration: nil
        )

        for logLine in logLines {
            appendLog(logLine)
        }
        appendJobLog(jobID: jobID, "\(label) started. Payload: \(payload.shortSHA256Fingerprint). Write characteristic: 18F0 / 2AF1. Chunk size: \(chunkSize).")
        sendNextChunk()
    }

    private func silentBLEPayload(for test: SilentBLETest) -> Data {
        var payload = Data([0x1B, 0x40])
        payload.appendASCII("MADE TO KEEP SILENT TEST \(test.rawValue)\n")
        payload.append(Self.silentCutCommonFeed)

        if let cutterCommand = test.cutterCommand {
            payload.append(cutterCommand)
        }

        return payload
    }

    private static let silentCutCommonFeed = Data([0x0A, 0x0A])
    private static let vozyCutterAlarmOffPayload = Data([0x1F, 0x1B, 0x1F, 0xE0, 0x13, 0x14, 0x00, 0x04, 0x02, 0x03])
    private static let vozyAltFirmwareCutterAlarmOffPayload = Data([0x1F, 0x1B, 0x1F, 0xE0, 0x13, 0x14, 0x00, 0x05, 0x05, 0x01])
#endif

    private func startReceiptRasterJob(
        receipt: ComposedReceipt,
        rasterizedImage: ThermalRasterizedImage,
        mode: BluetoothPrinterRasterMode,
        balancedProfile: BalancedBluetoothPrinterProfile,
        completion: CompletionHandler?
    ) {
        startReceiptRasterJob(
            receiptLabel: "\(receipt.format.displayName) Receipt",
            rasterizedImage: rasterizedImage,
            mode: mode,
            balancedProfile: balancedProfile,
            completion: completion
        )
    }

    private func startReceiptRasterJob(
        receiptLabel: String,
        rasterizedImage: ThermalRasterizedImage,
        mode: BluetoothPrinterRasterMode,
        balancedProfile: BalancedBluetoothPrinterProfile,
        completion: CompletionHandler?
    ) {
        let heading = ThermalImageRasterizer.receiptPrintHeading()
        let finishing = ThermalImageRasterizer.photoTestFinishing()
        startRasterJob(
            label: receiptLabel,
            mode: mode,
            balancedProfile: balancedProfile,
            photoCalibrationProfileName: nil,
            heading: heading,
            rasterCommand: rasterizedImage.rasterCommand,
            finishing: finishing,
            imageWidth: rasterizedImage.width,
            imageHeight: rasterizedImage.height,
            rasterDataByteCount: rasterizedImage.rasterData.count,
            sanitizationReport: rasterizedImage.sanitizationReport,
            yL: rasterizedImage.yL,
            yH: rasterizedImage.yH,
            completion: completion
        )
    }

    private func startRasterJob(
        label: String,
        mode: BluetoothPrinterRasterMode,
        balancedProfile: BalancedBluetoothPrinterProfile,
        photoCalibrationProfileName: String?,
        heading: Data,
        rasterCommand: Data,
        finishing: Data,
        imageWidth: Int,
        imageHeight: Int,
        rasterDataByteCount: Int,
        sanitizationReport: RasterSanitizationReport,
        yL: UInt8,
        yH: UInt8,
        completion: CompletionHandler?
    ) {
        guard let jobID = beginJob() else {
            completion?(.failure(.jobAlreadyActive), false)
            return
        }

        pendingCompletion = completion

        guard let peripheral = connectedPeripheral, peripheral.state == .connected else {
            finishJob(expectedJobID: jobID, result: .failure(.printerNotConnected))
            return
        }

        guard let writeCharacteristic else {
            finishJob(expectedJobID: jobID, result: .failure(.knownCharacteristicUnavailable))
            return
        }

        if mode == .reliable && !writeCharacteristic.properties.contains(.write) {
            finishJob(expectedJobID: jobID, result: .failure(.sendFailed("Characteristic 2AF1 does not support response-based writes.")))
            return
        }

        if mode != .reliable && !writeCharacteristic.properties.contains(.writeWithoutResponse) {
            finishJob(expectedJobID: jobID, result: .failure(.sendFailed("Characteristic 2AF1 does not support writeWithoutResponse.")))
            return
        }

        do {
            try ThermalImageRasterizer.validateRasterCommand(
                rasterCommand,
                imageWidth: imageWidth,
                imageHeight: imageHeight,
                bytesPerRow: ThermalImageRasterizer.widthBytes,
                rasterDataCount: rasterDataByteCount
            )

            try RasterCommandSanitizer.validateOutboundJob(
                heading: heading,
                rasterCommand: rasterCommand,
                finishing: finishing,
                rasterDataRange: 8..<rasterCommand.count
            )
        } catch {
            finishJob(expectedJobID: jobID, result: .failure(.invalidRaster(error.localizedDescription)))
            return
        }

        let writeType = mode.writeType
        let maximumLength = max(1, peripheral.maximumWriteValueLength(for: writeType))
        let modeLimit: Int
        switch mode {
        case .reliable:
            modeLimit = Self.reliableChunkLimit
        case .balanced:
            modeLimit = balancedProfile.chunkLimit
        case .fast:
            modeLimit = Self.fastInitialChunkLimit
        }
        let chunkSize = max(1, min(modeLimit, maximumLength))
        let headingChunks = heading.chunked(maximumLength: chunkSize)
        let rasterChunks = rasterCommand.chunked(maximumLength: chunkSize)
        let finishingChunks = finishing.chunked(maximumLength: chunkSize)
        let chunks = headingChunks + rasterChunks + finishingChunks
        let totalBytes = heading.count + rasterCommand.count + finishing.count
        let rasterDataStartByteOffset = heading.count + 8
        let payloadFingerprint = (heading + rasterCommand + finishing).shortSHA256Fingerprint

        pendingJob = PendingJob(
            id: jobID,
            label: label,
            mode: mode,
            balancedProfile: mode == .balanced ? balancedProfile : nil,
            photoCalibrationProfileName: photoCalibrationProfileName,
            payloadFingerprint: payloadFingerprint,
            chunks: chunks,
            totalBytes: totalBytes,
            rasterByteCount: rasterDataByteCount,
            rasterDataStartByteOffset: rasterDataStartByteOffset,
            maximumWriteLength: maximumLength,
            chunkSize: chunkSize,
            chunkCount: chunks.count,
            imageHeight: imageHeight,
            startedAt: Date(),
            rasterStartChunkIndex: headingChunks.count,
            finishingStartChunkIndex: headingChunks.count + rasterChunks.count,
            transportCompletionScheduled: false
        )
        pendingChunkIndex = 0
        transferredBytes = 0
        rasterTransmissionBegan = false
        flowControlPauseCount = 0
        currentFlowControlPauseStartedAt = nil
        currentFlowControlPausePosition = nil
        flowControlPauseEvents = []
        longestFlowControlPause = nil
        lastJobStartedAt = Date()
        chunksSentInCurrentBurst = 0
        burstCount = chunks.isEmpty ? 0 : 1
        intentionalPacingPauseCount = 0
        metrics = BluetoothPrinterMetrics(
            mode: mode,
            balancedProfileName: mode == .balanced ? balancedProfile.displayName : nil,
            photoCalibrationProfileName: photoCalibrationProfileName,
            payloadByteCount: totalBytes,
            rasterByteCount: rasterDataByteCount,
            maximumWriteLength: maximumLength,
            chunkSize: chunkSize,
            chunkCount: chunks.count,
            burstChunkCount: mode == .balanced ? balancedProfile.burstChunkCount : nil,
            interBurstDelayMilliseconds: mode == .balanced ? balancedProfile.interBurstDelayMilliseconds : nil,
            burstCount: burstCount,
            transferredBytes: 0,
            duration: nil,
            throughputBytesPerSecond: nil,
            flowControlPauseCount: 0,
            longestFlowControlPause: nil,
            flowControlPauseEvents: [],
            intentionalPacingPauseCount: 0,
            physicalPrintDuration: nil
        )

        appendJobLog(jobID: jobID, "\(label) job started. Payload: \(payloadFingerprint).")
        appendJobLog(jobID: jobID, "Image: \(imageWidth)x\(imageHeight). Raster bytes: \(rasterDataByteCount). Command bytes: \(rasterCommand.count).")
        appendJobLog(jobID: jobID, "Sanitized bytes: \(sanitizationReport.sanitizedByteCount). DLE EOT: \(sanitizationReport.dleEOTPatternCount). DLE DC4: \(sanitizationReport.dleDC4PatternCount).")
        appendJobLog(jobID: jobID, "yL: \(yL). yH: \(yH).")
        appendJobLog(jobID: jobID, "Write characteristic: 18F0 / 2AF1.")
        appendJobLog(jobID: jobID, "Mode: \(mode.displayName). Write type: \(writeType.logName). Max: \(maximumLength). Chunk size: \(chunkSize). Chunks: \(chunks.count). Total bytes: \(totalBytes).")
        if let photoCalibrationProfileName {
            appendJobLog(jobID: jobID, "Photo calibration: \(photoCalibrationProfileName).")
        }
        if mode == .balanced {
            appendJobLog(jobID: jobID, "Balanced preset: \(balancedProfile.displayName). Burst: \(balancedProfile.burstChunkCount) chunks. Pause: \(balancedProfile.interBurstDelayMilliseconds) ms.")
        }
        jobState = .preparing
        sendNextChunk()
    }

    private func startEnvelopeRasterJob(
        envelope: PrintJobEnvelope,
        mode: BluetoothPrinterRasterMode,
        balancedProfile: BalancedBluetoothPrinterProfile,
        completion: CompletionHandler?
    ) {
        guard let jobID = beginJob() else {
            completion?(.failure(.jobAlreadyActive), false)
            return
        }

        pendingCompletion = completion

        do {
            try envelope.verifyPayloadIntegrity()
        } catch {
            finishJob(expectedJobID: jobID, result: .failure(.invalidRaster(error.localizedDescription)))
            return
        }

        guard let peripheral = connectedPeripheral, peripheral.state == .connected else {
            finishJob(expectedJobID: jobID, result: .failure(.printerNotConnected))
            return
        }

        guard let writeCharacteristic else {
            finishJob(expectedJobID: jobID, result: .failure(.knownCharacteristicUnavailable))
            return
        }

        if mode == .reliable && !writeCharacteristic.properties.contains(.write) {
            finishJob(expectedJobID: jobID, result: .failure(.sendFailed("Characteristic 2AF1 does not support response-based writes.")))
            return
        }

        if mode != .reliable && !writeCharacteristic.properties.contains(.writeWithoutResponse) {
            finishJob(expectedJobID: jobID, result: .failure(.sendFailed("Characteristic 2AF1 does not support writeWithoutResponse.")))
            return
        }

        let writeType = mode.writeType
        let maximumLength = max(1, peripheral.maximumWriteValueLength(for: writeType))
        let modeLimit: Int
        switch mode {
        case .reliable:
            modeLimit = Self.reliableChunkLimit
        case .balanced:
            modeLimit = balancedProfile.chunkLimit
        case .fast:
            modeLimit = Self.fastInitialChunkLimit
        }
        let chunkSize = max(1, min(modeLimit, maximumLength))
        let chunks = envelope.payload.chunked(maximumLength: chunkSize)
        let rasterStartChunkIndex = max(0, min(chunks.count, envelope.rasterDataRange.lowerBound / chunkSize))
        let finishingStartChunkIndex = max(0, min(chunks.count, envelope.rasterDataRange.upperBound / chunkSize))

        pendingJob = PendingJob(
            id: jobID,
            label: "\(envelope.source.displayName) Receipt",
            mode: mode,
            balancedProfile: mode == .balanced ? balancedProfile : nil,
            photoCalibrationProfileName: nil,
            payloadFingerprint: envelope.payloadFingerprint,
            chunks: chunks,
            totalBytes: envelope.payloadByteCount,
            rasterByteCount: envelope.rasterByteCount,
            rasterDataStartByteOffset: envelope.rasterDataRange.lowerBound,
            maximumWriteLength: maximumLength,
            chunkSize: chunkSize,
            chunkCount: chunks.count,
            imageHeight: envelope.imageHeight,
            startedAt: Date(),
            rasterStartChunkIndex: rasterStartChunkIndex,
            finishingStartChunkIndex: finishingStartChunkIndex,
            transportCompletionScheduled: false
        )
        pendingChunkIndex = 0
        transferredBytes = 0
        rasterTransmissionBegan = false
        printBytesStarted = false
        flowControlPauseCount = 0
        currentFlowControlPauseStartedAt = nil
        currentFlowControlPausePosition = nil
        flowControlPauseEvents = []
        longestFlowControlPause = nil
        lastJobStartedAt = Date()
        chunksSentInCurrentBurst = 0
        burstCount = chunks.isEmpty ? 0 : 1
        intentionalPacingPauseCount = 0
        metrics = BluetoothPrinterMetrics(
            mode: mode,
            balancedProfileName: mode == .balanced ? balancedProfile.displayName : nil,
            photoCalibrationProfileName: nil,
            payloadByteCount: envelope.payloadByteCount,
            rasterByteCount: envelope.rasterByteCount,
            maximumWriteLength: maximumLength,
            chunkSize: chunkSize,
            chunkCount: chunks.count,
            burstChunkCount: mode == .balanced ? balancedProfile.burstChunkCount : nil,
            interBurstDelayMilliseconds: mode == .balanced ? balancedProfile.interBurstDelayMilliseconds : nil,
            burstCount: burstCount,
            transferredBytes: 0,
            duration: nil,
            throughputBytesPerSecond: nil,
            flowControlPauseCount: 0,
            longestFlowControlPause: nil,
            flowControlPauseEvents: [],
            intentionalPacingPauseCount: 0,
            physicalPrintDuration: nil
        )

        appendJobLog(jobID: jobID, "\(envelope.source.displayName) envelope job started. App job: \(envelope.jobID.uuidString). Batch: \(envelope.batchID.uuidString). Copy: \(envelope.copyIndex)/\(envelope.copyCount). Session: \(envelope.sessionIdentifier).")
        appendJobLog(jobID: jobID, "Frozen payload: \(envelope.payloadFingerprint.prefix(12)). Bytes: \(envelope.payloadByteCount). Image: \(envelope.imageWidth)x\(envelope.imageHeight).")
        appendJobLog(jobID: jobID, "Mode: \(mode.displayName). Write type: \(writeType.logName). Max: \(maximumLength). Chunk size: \(chunkSize). Chunks: \(chunks.count).")
        jobState = .preparing
        sendNextChunk()
    }

    private func beginJob(requiresVerifiedTextTest: Bool = true) -> UInt64? {
        guard !isJobActive else {
            jobState = .failure(BluetoothPrinterServiceError.jobAlreadyActive.localizedDescription)
            return nil
        }

        guard !recoveryLockoutActive else {
            jobState = .recoveryRequired(BluetoothPrinterServiceError.recoveryRequired.localizedDescription)
            return nil
        }

        guard !requiresVerifiedTextTest || !requiresTextTestBeforeRasterPrint else {
            jobState = .failure(BluetoothPrinterServiceError.connectionTestRequired.localizedDescription)
            return nil
        }

        pacingPauseTask?.cancel()
        pacingPauseTask = nil
        postSendCompletionTask?.cancel()
        postSendCompletionTask = nil
        reliableWriteWatchdogTask?.cancel()
        reliableWriteWatchdogTask = nil
        flowControlWatchdogTask?.cancel()
        flowControlWatchdogTask = nil
        lastWriteTimeoutDuration = nil
        guard let jobID = jobLifecycle.beginJob() else {
            jobState = .failure(BluetoothPrinterServiceError.jobAlreadyActive.localizedDescription)
            return nil
        }

        isJobActive = true
        appendJobLog(jobID: jobID, "job ownership acquired.")
        return jobID
    }

    private var knownPrinterIdentifier: UUID? {
        guard let rawValue = UserDefaults.standard.string(forKey: Self.knownPrinterIdentifierKey) else {
            return nil
        }

        return UUID(uuidString: rawValue)
    }

    private func saveKnownPrinter(_ peripheral: CBPeripheral) {
        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: Self.knownPrinterIdentifierKey)
        let name = peripheralDisplayName(peripheral)
        UserDefaults.standard.set(name, forKey: Self.knownPrinterNameKey)
        savedPrinterName = name
        idleReconnectBudget = 2
        appendLog("Saved Bluetooth printer \(name) with identifier \(peripheral.identifier.uuidString).")
    }

    private func connectForProduction(to peripheral: CBPeripheral, reason: String) {
        stopScan()
        connectedPeripheral = peripheral
        writeCharacteristic = nil
        operatorDisconnectInProgress = false
        peripheral.delegate = self
        let name = peripheralDisplayName(peripheral)
        jobState = .connecting(name)
        appendLog("Production reconnect using \(reason): \(name).")
        centralManager?.connect(peripheral, options: nil)
    }

    private func startTargetedReconnectScan() {
        guard centralManager?.state == .poweredOn, connectedPeripheral == nil, !jobState.isWorking else {
            return
        }

        stopScan()
        candidates = []
        peripheralsByID = [:]
        scanShouldConnectFirstCandidate = true
        jobState = .scanning
        appendLog("Targeted production scan started for VOZY service 18F0.")
        centralManager?.scanForPeripherals(withServices: [Self.vozyServiceUUID], options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: false
        ])

        scanStopTask = Task { [weak self, scanDuration] in
            try? await Task.sleep(nanoseconds: UInt64(scanDuration * 1_000_000_000))
            self?.finishTimedScan()
        }
    }

    private func sendNextChunk() {
        guard let pendingJob else {
            appendLog("Ignored chunk send request because no BLE job is pending.")
            return
        }

        guard let peripheral = connectedPeripheral, peripheral.state == .connected else {
            failJob(expectedJobID: pendingJob.id, message: "Bluetooth printer disconnected before chunk \(pendingChunkIndex + 1).")
            return
        }

        guard let writeCharacteristic else {
            failJob(expectedJobID: pendingJob.id, message: "Bluetooth write characteristic disappeared before chunk \(pendingChunkIndex + 1).")
            return
        }

        guard pendingChunkIndex < pendingJob.chunks.count else {
            completeTransportSend(expectedJobID: pendingJob.id)
            return
        }

        if pendingJob.mode != .reliable {
            sendWithoutResponseChunks(peripheral: peripheral, characteristic: writeCharacteristic, job: pendingJob)
            return
        }

        if pendingChunkIndex >= pendingJob.finishingStartChunkIndex {
            jobState = .cutting
        } else if pendingChunkIndex >= pendingJob.rasterStartChunkIndex {
            rasterTransmissionBegan = true
            jobState = .sending(bytesSent: transferredBytes, totalBytes: pendingJob.totalBytes)
        } else {
            jobState = .preparing
        }

        let chunk = pendingJob.chunks[pendingChunkIndex]
        appendJobLog(jobID: pendingJob.id, "Writing chunk \(pendingChunkIndex + 1)/\(pendingJob.chunkCount), \(chunk.count) bytes.")
        printBytesStarted = true
        scheduleReliableWriteWatchdog(
            expectedJobID: pendingJob.id,
            expectedChunkIndex: pendingChunkIndex,
            peripheralID: peripheral.identifier,
            characteristicID: writeCharacteristic.uuid
        )
        peripheral.writeValue(chunk, for: writeCharacteristic, type: .withResponse)
    }

    private func sendWithoutResponseChunks(peripheral: CBPeripheral, characteristic: CBCharacteristic, job: PendingJob) {
        guard pendingJob?.id == job.id else {
            appendStaleJobLog(expectedJobID: job.id, "ignored no-response send for stale job.")
            return
        }

        var sentAnyChunk = false

        while pendingChunkIndex < job.chunks.count {
            guard pendingJob?.id == job.id else {
                appendStaleJobLog(expectedJobID: job.id, "stopped no-response send because active job changed.")
                return
            }

            guard peripheral.canSendWriteWithoutResponse else {
                registerFlowControlPause()
                appendJobLog(jobID: job.id, "\(job.mode.displayName) mode paused by CoreBluetooth flow control at chunk \(pendingChunkIndex + 1)/\(job.chunkCount).")
                return
            }

            clearFlowControlPauseIfNeeded()
            updateTransferPhase(for: job)

            let chunk = job.chunks[pendingChunkIndex]
            printBytesStarted = true
            peripheral.writeValue(chunk, for: characteristic, type: .withoutResponse)
            transferredBytes += chunk.count
            pendingChunkIndex += 1
            sentAnyChunk = true
            chunksSentInCurrentBurst += 1

            updateMetrics(duration: nil)

            if shouldPauseForBalancedBurst(job: job) {
                scheduleBalancedPacingPause(job: job)
                return
            }
        }

        if sentAnyChunk {
            appendJobLog(jobID: job.id, "\(job.mode.displayName) mode queued all chunks to CoreBluetooth.")
        }

        completeTransportSend(expectedJobID: job.id)
    }

    private func shouldPauseForBalancedBurst(job: PendingJob) -> Bool {
        guard job.mode == .balanced, let profile = job.balancedProfile else {
            return false
        }

        return pendingChunkIndex < job.chunks.count
            && chunksSentInCurrentBurst >= profile.burstChunkCount
    }

    private func scheduleBalancedPacingPause(job: PendingJob) {
        guard let profile = job.balancedProfile else {
            return
        }

        intentionalPacingPauseCount += 1
        updateMetrics(duration: nil)
        appendJobLog(jobID: job.id, "Balanced \(profile.displayName) pacing pause \(intentionalPacingPauseCount): \(profile.interBurstDelayMilliseconds) ms after \(chunksSentInCurrentBurst) chunks.")
        pacingPauseTask?.cancel()
        pacingPauseTask = Task { [weak self, expectedJobID = job.id, delay = profile.interBurstDelay] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            self?.resumeAfterBalancedPacingPause(expectedJobID: expectedJobID)
        }
    }

    private func resumeAfterBalancedPacingPause(expectedJobID: UInt64) {
        guard let pendingJob, pendingJob.id == expectedJobID, pendingJob.mode == .balanced, isJobActive else {
            appendStaleJobLog(expectedJobID: expectedJobID, "ignored stale balanced pacing resume.")
            return
        }

        chunksSentInCurrentBurst = 0
        burstCount += 1
        updateMetrics(duration: nil)
        sendNextChunk()
    }

    private func updateTransferPhase(for job: PendingJob) {
        if pendingChunkIndex >= job.finishingStartChunkIndex {
            jobState = .cutting
        } else if pendingChunkIndex >= job.rasterStartChunkIndex {
            rasterTransmissionBegan = true
            jobState = .sending(bytesSent: transferredBytes, totalBytes: job.totalBytes)
        } else {
            jobState = .preparing
        }
    }

    private func completeTransportSend(expectedJobID: UInt64) {
        switch jobLifecycle.scheduleTransportCompletion(expectedJobID: expectedJobID) {
        case .accepted:
            break
        case .duplicate:
            appendJobLog(jobID: expectedJobID, "duplicate transport completion request ignored.")
            return
        case .stale:
            appendStaleJobLog(expectedJobID: expectedJobID, "ignored stale transport completion request.")
            return
        }

        guard var pendingJob, pendingJob.id == expectedJobID else {
            appendStaleJobLog(expectedJobID: expectedJobID, "ignored stale transport completion request.")
            return
        }

        pendingJob.transportCompletionScheduled = true
        self.pendingJob = pendingJob

        let duration = Date().timeIntervalSince(pendingJob.startedAt)
        let processingDelay = postTransportProcessingDelay(for: pendingJob, transportDuration: duration)
        updateMetrics(duration: duration)
        reliableWriteWatchdogTask?.cancel()
        reliableWriteWatchdogTask = nil
        appendJobLog(jobID: expectedJobID, "\(pendingJob.mode.progressLabel) all BLE chunks in \(String(format: "%.2f", duration)) seconds. Waiting \(String(format: "%.2f", processingDelay))s processing + \(String(format: "%.2f", postCutHandoffDelay))s handoff.")
        appendJobLog(jobID: expectedJobID, "transport completion scheduled.")
        jobState = .printerProcessing

        postSendCompletionTask?.cancel()
        postSendCompletionTask = Task { [weak self, expectedJobID, processingDelay, postCutHandoffDelay] in
            try? await Task.sleep(nanoseconds: UInt64(processingDelay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            guard self?.isActiveJob(expectedJobID) == true else {
                self?.appendStaleJobLog(expectedJobID: expectedJobID, "ignored stale printer-processing wake.")
                return
            }
            self?.setCoolingDown(expectedJobID: expectedJobID)
            try? await Task.sleep(nanoseconds: UInt64(postCutHandoffDelay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.appendJobLog(jobID: expectedJobID, "Bluetooth post-cut handoff complete after \(String(format: "%.2f", processingDelay + postCutHandoffDelay)) seconds.")
            self?.finishJob(expectedJobID: expectedJobID, result: .success(()))
        }
    }

    private func postTransportProcessingDelay(for job: PendingJob, transportDuration: TimeInterval) -> TimeInterval {
        guard let imageHeight = job.imageHeight, imageHeight > 0 else {
            return printerProcessingDelay
        }

        let estimatedReceiptLengthMillimeters = Double(imageHeight) / 8.0
        let estimatedPhysicalDuration = (estimatedReceiptLengthMillimeters / conservativeThermalPrintMillimetersPerSecond) + estimatedCutAndSettleDelay
        let remainingPhysicalDuration = estimatedPhysicalDuration - transportDuration - postCutHandoffDelay
        let boundedRemaining = max(printerProcessingDelay, remainingPhysicalDuration)
        appendJobLog(
            jobID: job.id,
            "physical handoff estimate length=\(String(format: "%.1f", estimatedReceiptLengthMillimeters))mm conservativeSpeed=\(String(format: "%.1f", conservativeThermalPrintMillimetersPerSecond))mm/s transport=\(String(format: "%.2f", transportDuration))s remaining=\(String(format: "%.2f", boundedRemaining))s"
        )
        return boundedRemaining
    }

    private func scheduleReliableWriteWatchdog(
        expectedJobID: UInt64,
        expectedChunkIndex: Int,
        peripheralID: UUID,
        characteristicID: CBUUID
    ) {
        reliableWriteWatchdogTask?.cancel()
        reliableWriteWatchdogTask = Task { [weak self, reliableWriteAcknowledgementTimeout, expectedJobID, expectedChunkIndex, peripheralID, characteristicID] in
            try? await Task.sleep(nanoseconds: UInt64(reliableWriteAcknowledgementTimeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.handleReliableWriteWatchdog(
                expectedJobID: expectedJobID,
                expectedChunkIndex: expectedChunkIndex,
                peripheralID: peripheralID,
                characteristicID: characteristicID,
                timeout: reliableWriteAcknowledgementTimeout
            )
        }
    }

    private func handleReliableWriteWatchdog(
        expectedJobID: UInt64,
        expectedChunkIndex: Int,
        peripheralID: UUID,
        characteristicID: CBUUID,
        timeout: TimeInterval
    ) {
        guard let pendingJob,
              pendingJob.id == expectedJobID,
              pendingJob.mode == .reliable,
              pendingChunkIndex == expectedChunkIndex,
              connectedPeripheral?.identifier == peripheralID,
              writeCharacteristic?.uuid == characteristicID,
              isJobActive else {
            appendStaleJobLog(expectedJobID: expectedJobID, "ignored stale reliable-write watchdog for chunk \(expectedChunkIndex + 1).")
            return
        }

        lastWriteTimeoutDuration = timeout
        appendJobLog(jobID: expectedJobID, "reliable write acknowledgement watchdog fired at chunk \(expectedChunkIndex + 1)/\(pendingJob.chunkCount) after \(String(format: "%.1f", timeout))s.")
        failJob(expectedJobID: expectedJobID, message: "Timed out waiting for BLE write acknowledgement at chunk \(expectedChunkIndex + 1).")
    }

    private func finishJob(expectedJobID: UInt64, result: Result<Void, BluetoothPrinterServiceError>) {
        switch jobLifecycle.finishJob(expectedJobID: expectedJobID) {
        case .accepted:
            break
        case .duplicate:
            appendJobLog(jobID: expectedJobID, "duplicate terminal completion request ignored.")
            return
        case .stale:
            appendStaleJobLog(expectedJobID: expectedJobID, "ignored stale terminal completion request.")
            return
        }

        let job = pendingJob
        let completion = pendingCompletion
        let bytesStarted = printBytesStarted

        switch result {
        case .success:
            let progressLabel = job?.mode.progressLabel ?? "Sent"
            appendJobLog(jobID: expectedJobID, "terminal success. Payload: \(job?.payloadFingerprint ?? "unavailable").")
            appendJobLog(jobID: expectedJobID, "Bluetooth raster transport completed. Paper completion still requires physical confirmation.")
            jobState = .success("Bluetooth raster data, feed, and cut were \(progressLabel.lowercased()). Confirm the paper output physically completed.")
        case .failure(let error):
            if rasterTransmissionBegan {
                recoveryLockoutActive = true
                requiresTextTestBeforeRasterPrint = true
                let message = BluetoothPrinterServiceError.recoveryRequired.localizedDescription
                appendJobLog(jobID: expectedJobID, "terminal failure after raster began. Bluetooth recovery lockout activated. Error: \(error.localizedDescription)")
                jobState = .recoveryRequired(message)
            } else {
                appendJobLog(jobID: expectedJobID, "terminal failure before raster bytes began: \(error.localizedDescription)")
                jobState = .failure(error.localizedDescription)
            }
        }

        pendingJob = nil
        pendingCompletion = nil
        pendingChunkIndex = 0
        transferredBytes = 0
        rasterTransmissionBegan = false
        printBytesStarted = false
        isJobActive = false
        jobLifecycle.clearInactiveTasks()
        currentFlowControlPauseStartedAt = nil
        currentFlowControlPausePosition = nil
        chunksSentInCurrentBurst = 0
        pacingPauseTask?.cancel()
        pacingPauseTask = nil
        postSendCompletionTask?.cancel()
        postSendCompletionTask = nil
        reliableWriteWatchdogTask?.cancel()
        reliableWriteWatchdogTask = nil
        flowControlWatchdogTask?.cancel()
        flowControlWatchdogTask = nil
        completion?(result, bytesStarted)
    }

    private func failJob(expectedJobID: UInt64, message: String) {
        finishJob(expectedJobID: expectedJobID, result: .failure(.sendFailed(message)))
    }

    private func failActiveJob(message: String) {
        guard let pendingJob else {
            appendLog("Ignored active-job failure because no BLE job is pending. \(message)")
            return
        }

        failJob(expectedJobID: pendingJob.id, message: message)
    }

    private func updateMetrics(duration: TimeInterval?) {
        guard let pendingJob else {
            return
        }

        let throughput = duration.flatMap { duration in
            duration > 0 ? Double(pendingJob.totalBytes) / duration : nil
        }

        metrics = BluetoothPrinterMetrics(
            mode: pendingJob.mode,
            balancedProfileName: pendingJob.balancedProfile?.displayName,
            photoCalibrationProfileName: pendingJob.photoCalibrationProfileName,
            payloadByteCount: pendingJob.totalBytes,
            rasterByteCount: pendingJob.rasterByteCount,
            maximumWriteLength: pendingJob.maximumWriteLength,
            chunkSize: pendingJob.chunkSize,
            chunkCount: pendingJob.chunkCount,
            burstChunkCount: pendingJob.balancedProfile?.burstChunkCount,
            interBurstDelayMilliseconds: pendingJob.balancedProfile?.interBurstDelayMilliseconds,
            burstCount: burstCount,
            transferredBytes: transferredBytes,
            duration: duration,
            throughputBytesPerSecond: throughput,
            flowControlPauseCount: flowControlPauseCount,
            longestFlowControlPause: longestFlowControlPause,
            flowControlPauseEvents: flowControlPauseEvents,
            intentionalPacingPauseCount: intentionalPacingPauseCount,
            physicalPrintDuration: metrics?.physicalPrintDuration
        )
    }

    private func registerFlowControlPause() {
        guard currentFlowControlPauseStartedAt == nil else {
            return
        }

        currentFlowControlPauseStartedAt = Date()
        currentFlowControlPausePosition = currentRasterFlowPausePosition()
        flowControlPauseCount += 1
        updateMetrics(duration: nil)

        guard let pendingJob else {
            return
        }

        let expectedJobID = pendingJob.id
        flowControlWatchdogTask?.cancel()
        flowControlWatchdogTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(self.flowControlPauseTimeout))
            guard !Task.isCancelled,
                  self.pendingJob?.id == expectedJobID,
                  self.currentFlowControlPauseStartedAt != nil,
                  self.isJobActive else {
                return
            }

            self.appendJobLog(
                jobID: expectedJobID,
                "CoreBluetooth flow-control watchdog fired after \(String(format: "%.1f", self.flowControlPauseTimeout))s."
            )
            self.failJob(
                expectedJobID: expectedJobID,
                message: "Timed out waiting for the Bluetooth printer to accept more data."
            )
        }
    }

    private func clearFlowControlPauseIfNeeded() {
        guard let pauseStartedAt = currentFlowControlPauseStartedAt else {
            return
        }

        flowControlWatchdogTask?.cancel()
        flowControlWatchdogTask = nil

        let duration = Date().timeIntervalSince(pauseStartedAt)
        if let currentFlowControlPausePosition {
            let event = BluetoothPrinterFlowControlPauseEvent(
                transferredBytes: currentFlowControlPausePosition.transferredBytes,
                rasterByteOffset: currentFlowControlPausePosition.rasterByteOffset,
                rasterRow: currentFlowControlPausePosition.rasterRow,
                duration: duration
            )
            flowControlPauseEvents.append(event)
        }
        if let existingLongest = longestFlowControlPause {
            longestFlowControlPause = max(existingLongest, duration)
        } else {
            longestFlowControlPause = duration
        }
        currentFlowControlPauseStartedAt = nil
        currentFlowControlPausePosition = nil
        updateMetrics(duration: nil)
        if let row = flowControlPauseEvents.last?.rasterRow {
            appendLog("No-response flow-control pause cleared near raster row ~\(row) after \(String(format: "%.3f", duration)) seconds.")
        } else {
            appendLog("No-response flow-control pause cleared after \(String(format: "%.3f", duration)) seconds.")
        }
    }

    private func currentRasterFlowPausePosition() -> (transferredBytes: Int, rasterByteOffset: Int?, rasterRow: Int?) {
        guard let pendingJob,
              let rasterDataStartByteOffset = pendingJob.rasterDataStartByteOffset,
              pendingJob.rasterByteCount > 0 else {
            return (transferredBytes, nil, nil)
        }

        let rasterByteOffset = transferredBytes - rasterDataStartByteOffset

        guard rasterByteOffset >= 0, rasterByteOffset < pendingJob.rasterByteCount else {
            return (transferredBytes, nil, nil)
        }

        return (
            transferredBytes,
            rasterByteOffset,
            rasterByteOffset / ThermalImageRasterizer.widthBytes
        )
    }

    private func finishTimedScan() {
        centralManager?.stopScan()

        if case .scanning = jobState {
            jobState = candidates.isEmpty
                ? .failure("Scan finished. No VOZY 18F0 BLE candidates were discovered.")
                : .idle
        }

        scanShouldConnectFirstCandidate = false
        appendLog("BT2 scan finished. Candidates: \(candidates.count).")
    }

    private func clearConnection() {
        connectedPeripheral?.delegate = nil
        connectedPeripheral = nil
        connectedPrinterName = nil
        writeCharacteristic = nil
    }

    private func isActiveJob(_ expectedJobID: UInt64) -> Bool {
        pendingJob?.id == expectedJobID && isJobActive
    }

    private func setCoolingDown(expectedJobID: UInt64) {
        guard isActiveJob(expectedJobID) else {
            appendStaleJobLog(expectedJobID: expectedJobID, "ignored stale cooling-down transition.")
            return
        }

        jobState = .coolingDown
    }

    private func appendJobLog(jobID: UInt64, _ message: String) {
        appendLog("[BLEJob \(Self.shortJobID(jobID))] \(message)")
    }

    private func appendStaleJobLog(expectedJobID: UInt64, _ message: String) {
        appendLog("[BLEJob \(Self.shortJobID(expectedJobID))] \(message) Active: \(pendingJob.map { Self.shortJobID($0.id) } ?? "none").")
    }

    private static func shortJobID(_ jobID: UInt64) -> String {
        String(format: "%04llX", jobID)
    }

    private func appendLog(_ message: String) {
        diagnosticLog.append(message)

        if diagnosticLog.count > 100 {
            diagnosticLog.removeFirst(diagnosticLog.count - 100)
        }

        print("[PrinterBluetoothService] \(message)")
    }

    private func peripheralDisplayName(_ peripheral: CBPeripheral, advertisedName: String? = nil) -> String {
        let name = advertisedName ?? peripheral.name
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedName?.isEmpty == false ? trimmedName! : "Unnamed BLE Printer"
    }

    private func isLikelyPrinterName(_ name: String) -> Bool {
        let lowercasedName = name.lowercased()
        return ["vozy", "g80", "printer", "pos"].contains { lowercasedName.contains($0) }
    }
}

extension PrinterBluetoothService: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        // Delivered on the main queue (the manager uses queue: nil); assumeIsolated
        // checks that and keeps every Bluetooth state access serialized on the main actor.
        MainActor.assumeIsolated {
            bluetoothState = central.state.displayName

            if central.state == .poweredOn {
                if shouldPrepareWhenPoweredOn {
                    prepareSavedPrinter()
                }
                return
            } else {
                stopScan()
                if isJobActive {
                    failActiveJob(message: "Bluetooth state changed to \(central.state.displayName).")
                }
                clearConnection()
                jobState = .failure("Bluetooth is \(central.state.displayName.lowercased()). Wi-Fi printing is unaffected.")
            }
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        // Delivered on the main queue (the manager uses queue: nil); assumeIsolated
        // checks that and keeps every Bluetooth state access serialized on the main actor.
        MainActor.assumeIsolated {
            let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
            let name = peripheralDisplayName(peripheral, advertisedName: advertisedName)
            peripheralsByID[peripheral.identifier] = peripheral

            let candidate = BluetoothPrinterCandidate(
                id: peripheral.identifier,
                name: name,
                rssi: RSSI.intValue,
                isLikelyPrinter: isLikelyPrinterName(name)
            )

            if let existingIndex = candidates.firstIndex(where: { $0.id == candidate.id }) {
                candidates[existingIndex] = candidate
            } else {
                candidates.append(candidate)
            }

            candidates.sort {
                if $0.isLikelyPrinter != $1.isLikelyPrinter {
                    return $0.isLikelyPrinter && !$1.isLikelyPrinter
                }

                return $0.rssi > $1.rssi
            }

            if scanShouldConnectFirstCandidate, connectedPeripheral == nil, !isJobActive {
                connectForProduction(to: peripheral, reason: "targeted 18F0 scan")
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        // Delivered on the main queue (the manager uses queue: nil); assumeIsolated
        // checks that and keeps every Bluetooth state access serialized on the main actor.
        MainActor.assumeIsolated {
            guard connectedPeripheral?.identifier == peripheral.identifier else {
                central.cancelPeripheralConnection(peripheral)
                return
            }

            stopScan()
            connectedPrinterName = peripheralDisplayName(peripheral)
            jobState = .connected(connectedPrinterName ?? "Bluetooth printer")
            appendLog("Connected. Discovering VOZY service 18F0.")
            peripheral.discoverServices([Self.vozyServiceUUID])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        // Delivered on the main queue (the manager uses queue: nil); assumeIsolated
        // checks that and keeps every Bluetooth state access serialized on the main actor.
        MainActor.assumeIsolated {
            guard connectedPeripheral?.identifier == peripheral.identifier else {
                return
            }

            let detail = error?.localizedDescription ?? "No CoreBluetooth error was provided."
            clearConnection()
            jobState = .failure("Bluetooth connection failed. \(detail)")
            appendLog("Connection failed. \(detail)")
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        // Delivered on the main queue (the manager uses queue: nil); assumeIsolated
        // checks that and keeps every Bluetooth state access serialized on the main actor.
        MainActor.assumeIsolated {
            guard connectedPeripheral?.identifier == peripheral.identifier else {
                return
            }

            let detail = error?.localizedDescription ?? "No CoreBluetooth error was provided."
            clearConnection()

            if operatorDisconnectInProgress {
                operatorDisconnectInProgress = false
                appendLog("Operator disconnect completed.")
                return
            }

            if isJobActive {
                failActiveJob(message: "Bluetooth printer disconnected during raster job. \(detail)")
            } else {
                jobState = .failure("Bluetooth printer disconnected. \(detail)")
                appendLog("Bluetooth printer disconnected. \(detail)")
                if reconnectAttemptsRemaining > 0 || idleReconnectBudget > 0 {
                    let delay: TimeInterval = reconnectAttemptsRemaining > 0 ? 1 : 2
                    reconnectAttemptsRemaining = max(0, reconnectAttemptsRemaining - 1)
                    idleReconnectBudget = max(0, idleReconnectBudget - 1)
                    Task { [weak self] in
                        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                        self?.prepareSavedPrinter()
                    }
                }
            }
        }
    }
}

extension PrinterBluetoothService: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        // Delivered on the main queue (the manager uses queue: nil); assumeIsolated
        // checks that and keeps every Bluetooth state access serialized on the main actor.
        MainActor.assumeIsolated {
            guard connectedPeripheral?.identifier == peripheral.identifier else {
                return
            }

            if let error {
                jobState = .failure("Bluetooth service discovery failed. \(error.localizedDescription)")
                appendLog(jobState.message)
                return
            }

            guard let service = peripheral.services?.first(where: { $0.uuid == Self.vozyServiceUUID }) else {
                jobState = .failure("Connected peripheral did not expose VOZY service 18F0.")
                appendLog(jobState.message)
                return
            }

            appendLog("Service 18F0 discovered. Discovering characteristic 2AF1.")
            peripheral.discoverCharacteristics([Self.vozyWriteCharacteristicUUID], for: service)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        // Delivered on the main queue (the manager uses queue: nil); assumeIsolated
        // checks that and keeps every Bluetooth state access serialized on the main actor.
        MainActor.assumeIsolated {
            guard connectedPeripheral?.identifier == peripheral.identifier else {
                return
            }

            if let error {
                jobState = .failure("Bluetooth characteristic discovery failed. \(error.localizedDescription)")
                appendLog(jobState.message)
                return
            }

            guard let characteristic = service.characteristics?.first(where: { $0.uuid == Self.vozyWriteCharacteristicUUID }) else {
                jobState = .failure("VOZY service 18F0 did not expose characteristic 2AF1.")
                appendLog(jobState.message)
                return
            }

            guard characteristic.properties.contains(.write) || characteristic.properties.contains(.writeWithoutResponse) else {
                jobState = .failure("Characteristic 2AF1 does not support writable BLE transport.")
                appendLog(jobState.message)
                return
            }

            writeCharacteristic = characteristic
            saveKnownPrinter(peripheral)
            jobState = .connected(connectedPrinterName ?? "VOZY G80")
            appendLog("Characteristic 2AF1 ready. Properties: \(characteristic.propertyLabels.joined(separator: ", ")).")
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        // Delivered on the main queue (the manager uses queue: nil); assumeIsolated
        // checks that and keeps every Bluetooth state access serialized on the main actor.
        MainActor.assumeIsolated {
            guard connectedPeripheral?.identifier == peripheral.identifier else {
                return
            }

            guard writeCharacteristic?.uuid == characteristic.uuid else {
                appendLog("Ignored write acknowledgement for unexpected characteristic \(characteristic.uuid.uuidString).")
                return
            }

            if let error {
                failActiveJob(message: "Write failed at chunk \(pendingChunkIndex + 1). \(error.localizedDescription)")
                return
            }

            guard let pendingJob, pendingChunkIndex < pendingJob.chunks.count else {
                return
            }

            guard pendingJob.mode == .reliable else {
                return
            }

            reliableWriteWatchdogTask?.cancel()
            reliableWriteWatchdogTask = nil
            transferredBytes += pendingJob.chunks[pendingChunkIndex].count
            pendingChunkIndex += 1
            metrics = BluetoothPrinterMetrics(
                mode: pendingJob.mode,
                balancedProfileName: pendingJob.balancedProfile?.displayName,
                photoCalibrationProfileName: pendingJob.photoCalibrationProfileName,
                payloadByteCount: pendingJob.totalBytes,
                rasterByteCount: pendingJob.rasterByteCount,
                maximumWriteLength: pendingJob.maximumWriteLength,
                chunkSize: pendingJob.chunkSize,
                chunkCount: pendingJob.chunkCount,
                burstChunkCount: pendingJob.balancedProfile?.burstChunkCount,
                interBurstDelayMilliseconds: pendingJob.balancedProfile?.interBurstDelayMilliseconds,
                burstCount: burstCount,
                transferredBytes: transferredBytes,
                duration: nil,
                throughputBytesPerSecond: nil,
                flowControlPauseCount: flowControlPauseCount,
                longestFlowControlPause: longestFlowControlPause,
                flowControlPauseEvents: flowControlPauseEvents,
                intentionalPacingPauseCount: intentionalPacingPauseCount,
                physicalPrintDuration: metrics?.physicalPrintDuration
            )

            if pendingChunkIndex == pendingJob.rasterStartChunkIndex {
                appendLog("Heading acknowledged. Raster transmission begins next.")
            } else if pendingChunkIndex == pendingJob.finishingStartChunkIndex {
                appendLog("Raster command acknowledged. Finishing/feed/cut begins next.")
            }

            sendNextChunk()
        }
    }

    nonisolated func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        // Delivered on the main queue (the manager uses queue: nil); assumeIsolated
        // checks that and keeps every Bluetooth state access serialized on the main actor.
        MainActor.assumeIsolated {
            guard connectedPeripheral?.identifier == peripheral.identifier else {
                return
            }

            clearFlowControlPauseIfNeeded()

            guard let pendingJob, pendingJob.mode != .reliable, isJobActive else {
                return
            }

            guard let writeCharacteristic else {
                failJob(expectedJobID: pendingJob.id, message: "Bluetooth write characteristic disappeared while resuming fast mode.")
                return
            }

            if pendingChunkIndex >= pendingJob.chunks.count, pendingJob.transportCompletionScheduled {
                appendJobLog(jobID: pendingJob.id, "ready callback after all chunks queued ignored.")
                return
            }

            appendLog("CoreBluetooth is ready for more no-response writes.")
            sendWithoutResponseChunks(peripheral: peripheral, characteristic: writeCharacteristic, job: pendingJob)
        }
    }
}

private extension CBManagerState {
    var displayName: String {
        switch self {
        case .poweredOn:
            "Powered On"
        case .poweredOff:
            "Powered Off"
        case .unauthorized:
            "Unauthorized"
        case .unsupported:
            "Unsupported"
        case .resetting:
            "Resetting"
        case .unknown:
            "Unknown"
        @unknown default:
            "Unknown"
        }
    }
}

private extension CBCharacteristic {
    var propertyLabels: [String] {
        var labels: [String] = []

        if properties.contains(.read) {
            labels.append("read")
        }

        if properties.contains(.write) {
            labels.append("write")
        }

        if properties.contains(.writeWithoutResponse) {
            labels.append("writeWithoutResponse")
        }

        if properties.contains(.notify) {
            labels.append("notify")
        }

        if properties.contains(.indicate) {
            labels.append("indicate")
        }

        return labels.isEmpty ? ["none"] : labels
    }
}

private extension CBCharacteristicWriteType {
    var logName: String {
        switch self {
        case .withResponse:
            return "withResponse"
        case .withoutResponse:
            return "withoutResponse"
        @unknown default:
            return "unknown"
        }
    }
}

private extension Data {
    var hexString: String {
        map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    func chunked(maximumLength: Int) -> [Data] {
        guard maximumLength > 0 else {
            return [self]
        }

        var chunks: [Data] = []
        var offset = 0

        while offset < count {
            let nextOffset = Swift.min(offset + maximumLength, count)
            chunks.append(self[offset..<nextOffset])
            offset = nextOffset
        }

        return chunks
    }
}
