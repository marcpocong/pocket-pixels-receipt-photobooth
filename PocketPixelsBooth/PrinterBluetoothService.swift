//
//  PrinterBluetoothService.swift
//  PocketPixelsBooth
//

#if DEBUG
import CoreBluetooth
import Combine
import Foundation
import UIKit

struct BluetoothPrinterCandidate: Identifiable, Equatable {
    let id: UUID
    let name: String
    let rssi: Int
    let isLikelyPrinter: Bool
}

enum BluetoothPrinterRasterMode: String, CaseIterable, Identifiable {
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
    let intentionalPacingPauseCount: Int
    let physicalPrintDuration: TimeInterval?

    var progress: Double {
        guard payloadByteCount > 0 else {
            return 0
        }

        return min(1, Double(transferredBytes) / Double(payloadByteCount))
    }
}

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
    private struct PendingJob {
        let label: String
        let mode: BluetoothPrinterRasterMode
        let balancedProfile: BalancedBluetoothPrinterProfile?
        let photoCalibrationProfileName: String?
        let chunks: [Data]
        let totalBytes: Int
        let rasterByteCount: Int
        let maximumWriteLength: Int
        let chunkSize: Int
        let chunkCount: Int
        let startedAt: Date
        let rasterStartChunkIndex: Int
        let finishingStartChunkIndex: Int
    }

    static let vozyServiceUUID = CBUUID(string: "18F0")
    static let vozyWriteCharacteristicUUID = CBUUID(string: "2AF1")
    private static let reliableChunkLimit = 182
    private static let fastInitialChunkLimit = 512

    @Published private(set) var bluetoothState = "Unknown"
    @Published private(set) var candidates: [BluetoothPrinterCandidate] = []
    @Published private(set) var connectedPrinterName: String?
    @Published private(set) var jobState = BluetoothPrinterJobState.idle
    @Published private(set) var metrics: BluetoothPrinterMetrics?
    @Published private(set) var diagnosticLog: [String] = []

    private let scanDuration: TimeInterval = 10
    private let printerProcessingDelay: TimeInterval = 1.5
    private let cooldownDelay: TimeInterval = 2
    private var centralManager: CBCentralManager?
    private var scanStopTask: Task<Void, Never>?
    private var peripheralsByID: [UUID: CBPeripheral] = [:]
    private var connectedPeripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var pendingJob: PendingJob?
    private var pendingChunkIndex = 0
    private var transferredBytes = 0
    private var rasterTransmissionBegan = false
    private var isJobActive = false
    private var recoveryLockoutActive = false
    private var requiresTextTestBeforeRasterPrint = false
    private var operatorDisconnectInProgress = false
    private var flowControlPauseCount = 0
    private var currentFlowControlPauseStartedAt: Date?
    private var longestFlowControlPause: TimeInterval?
    private var lastJobStartedAt: Date?
    private var chunksSentInCurrentBurst = 0
    private var burstCount = 0
    private var intentionalPacingPauseCount = 0
    private var pacingPauseTask: Task<Void, Never>?

    override init() {
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

    var canPrintRaster: Bool {
        connectedPeripheral != nil
            && writeCharacteristic != nil
            && !jobState.isWorking
            && !recoveryLockoutActive
            && !requiresTextTestBeforeRasterPrint
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
            failJob(message: "Bluetooth raster job interrupted by operator disconnect.")
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
        calibrationProfileName: String
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
            yH: rasterizedImage.yH
        )
    }

    func printReceipt(
        _ receipt: ComposedReceipt,
        mode: BluetoothPrinterRasterMode,
        balancedProfile: BalancedBluetoothPrinterProfile
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
                    balancedProfile: balancedProfile
                )
            } catch {
                jobState = .failure(error.localizedDescription)
            }
        }
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
            intentionalPacingPauseCount: currentMetrics.intentionalPacingPauseCount,
            physicalPrintDuration: Date().timeIntervalSince(lastJobStartedAt)
        )
        appendLog("Operator marked physical paper complete after \(String(format: "%.2f", self.metrics?.physicalPrintDuration ?? 0)) seconds.")
    }

    private func startReceiptRasterJob(
        receipt: ComposedReceipt,
        rasterizedImage: ThermalRasterizedImage,
        mode: BluetoothPrinterRasterMode,
        balancedProfile: BalancedBluetoothPrinterProfile
    ) {
        let heading = ThermalImageRasterizer.receiptPrintHeading()
        let finishing = ThermalImageRasterizer.photoTestFinishing()
        startRasterJob(
            label: "\(receipt.format.displayName) Receipt",
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
            yH: rasterizedImage.yH
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
        yH: UInt8
    ) {
        guard beginJob() else {
            return
        }

        guard let peripheral = connectedPeripheral, peripheral.state == .connected else {
            finishJob(.failure(.printerNotConnected))
            return
        }

        guard let writeCharacteristic else {
            finishJob(.failure(.knownCharacteristicUnavailable))
            return
        }

        if mode == .reliable && !writeCharacteristic.properties.contains(.write) {
            finishJob(.failure(.sendFailed("Characteristic 2AF1 does not support response-based writes.")))
            return
        }

        if mode != .reliable && !writeCharacteristic.properties.contains(.writeWithoutResponse) {
            finishJob(.failure(.sendFailed("Characteristic 2AF1 does not support writeWithoutResponse.")))
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
            finishJob(.failure(.invalidRaster(error.localizedDescription)))
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

        pendingJob = PendingJob(
            label: label,
            mode: mode,
            balancedProfile: mode == .balanced ? balancedProfile : nil,
            photoCalibrationProfileName: photoCalibrationProfileName,
            chunks: chunks,
            totalBytes: totalBytes,
            rasterByteCount: rasterDataByteCount,
            maximumWriteLength: maximumLength,
            chunkSize: chunkSize,
            chunkCount: chunks.count,
            startedAt: Date(),
            rasterStartChunkIndex: headingChunks.count,
            finishingStartChunkIndex: headingChunks.count + rasterChunks.count
        )
        pendingChunkIndex = 0
        transferredBytes = 0
        rasterTransmissionBegan = false
        flowControlPauseCount = 0
        currentFlowControlPauseStartedAt = nil
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
            intentionalPacingPauseCount: 0,
            physicalPrintDuration: nil
        )

        appendLog("\(label) job started.")
        appendLog("Image: \(imageWidth)x\(imageHeight). Raster bytes: \(rasterDataByteCount). Command bytes: \(rasterCommand.count).")
        appendLog("Sanitized bytes: \(sanitizationReport.sanitizedByteCount). DLE EOT: \(sanitizationReport.dleEOTPatternCount). DLE DC4: \(sanitizationReport.dleDC4PatternCount).")
        appendLog("yL: \(yL). yH: \(yH).")
        appendLog("Write characteristic: 18F0 / 2AF1.")
        appendLog("Mode: \(mode.displayName). Write type: \(writeType.logName). Max: \(maximumLength). Chunk size: \(chunkSize). Chunks: \(chunks.count). Total bytes: \(totalBytes).")
        if let photoCalibrationProfileName {
            appendLog("Photo calibration: \(photoCalibrationProfileName).")
        }
        if mode == .balanced {
            appendLog("Balanced preset: \(balancedProfile.displayName). Burst: \(balancedProfile.burstChunkCount) chunks. Pause: \(balancedProfile.interBurstDelayMilliseconds) ms.")
        }
        jobState = .preparing
        sendNextChunk()
    }

    private func beginJob() -> Bool {
        guard !isJobActive else {
            jobState = .failure(BluetoothPrinterServiceError.jobAlreadyActive.localizedDescription)
            return false
        }

        guard !recoveryLockoutActive else {
            jobState = .recoveryRequired(BluetoothPrinterServiceError.recoveryRequired.localizedDescription)
            return false
        }

        guard !requiresTextTestBeforeRasterPrint else {
            jobState = .failure(BluetoothPrinterServiceError.connectionTestRequired.localizedDescription)
            return false
        }

        isJobActive = true
        return true
    }

    private func sendNextChunk() {
        guard let pendingJob else {
            failJob(message: "Bluetooth raster job lost its pending state.")
            return
        }

        guard let peripheral = connectedPeripheral, peripheral.state == .connected else {
            failJob(message: "Bluetooth printer disconnected before chunk \(pendingChunkIndex + 1).")
            return
        }

        guard let writeCharacteristic else {
            failJob(message: "Bluetooth write characteristic disappeared before chunk \(pendingChunkIndex + 1).")
            return
        }

        guard pendingChunkIndex < pendingJob.chunks.count else {
            completeTransportSend()
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
        appendLog("Writing chunk \(pendingChunkIndex + 1)/\(pendingJob.chunkCount), \(chunk.count) bytes.")
        peripheral.writeValue(chunk, for: writeCharacteristic, type: .withResponse)
    }

    private func sendWithoutResponseChunks(peripheral: CBPeripheral, characteristic: CBCharacteristic, job: PendingJob) {
        var sentAnyChunk = false

        while pendingChunkIndex < job.chunks.count {
            guard peripheral.canSendWriteWithoutResponse else {
                registerFlowControlPause()
                appendLog("\(job.mode.displayName) mode paused by CoreBluetooth flow control at chunk \(pendingChunkIndex + 1)/\(job.chunkCount).")
                return
            }

            clearFlowControlPauseIfNeeded()
            updateTransferPhase(for: job)

            let chunk = job.chunks[pendingChunkIndex]
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
            appendLog("\(job.mode.displayName) mode queued all chunks to CoreBluetooth.")
        }

        completeTransportSend()
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
        appendLog("Balanced \(profile.displayName) pacing pause \(intentionalPacingPauseCount): \(profile.interBurstDelayMilliseconds) ms after \(chunksSentInCurrentBurst) chunks.")
        pacingPauseTask?.cancel()
        pacingPauseTask = Task { [weak self, delay = profile.interBurstDelay] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            self?.resumeAfterBalancedPacingPause()
        }
    }

    private func resumeAfterBalancedPacingPause() {
        guard let pendingJob, pendingJob.mode == .balanced, isJobActive else {
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

    private func completeTransportSend() {
        guard let pendingJob else {
            failJob(message: "Bluetooth raster job completed without pending metrics.")
            return
        }

        let duration = Date().timeIntervalSince(pendingJob.startedAt)
        updateMetrics(duration: duration)
        appendLog("\(pendingJob.mode.progressLabel) all BLE chunks in \(String(format: "%.2f", duration)) seconds. Waiting for printer processing.")
        jobState = .printerProcessing

        Task { [weak self, printerProcessingDelay, cooldownDelay] in
            try? await Task.sleep(nanoseconds: UInt64(printerProcessingDelay * 1_000_000_000))
            self?.jobState = .coolingDown
            try? await Task.sleep(nanoseconds: UInt64(cooldownDelay * 1_000_000_000))
            self?.finishJob(.success(()))
        }
    }

    private func finishJob(_ result: Result<Void, BluetoothPrinterServiceError>) {
        switch result {
        case .success:
            let progressLabel = pendingJob?.mode.progressLabel ?? "Sent"
            appendLog("Bluetooth raster transport completed. Paper completion still requires physical confirmation.")
            jobState = .success("Bluetooth raster data, feed, and cut were \(progressLabel.lowercased()). Confirm the paper output physically completed.")
        case .failure(let error):
            if rasterTransmissionBegan {
                recoveryLockoutActive = true
                requiresTextTestBeforeRasterPrint = true
                let message = BluetoothPrinterServiceError.recoveryRequired.localizedDescription
                appendLog("Bluetooth recovery lockout activated after raster transmission began. Error: \(error.localizedDescription)")
                jobState = .recoveryRequired(message)
            } else {
                appendLog("Bluetooth raster job failed before raster bytes began: \(error.localizedDescription)")
                jobState = .failure(error.localizedDescription)
            }
        }

        pendingJob = nil
        pendingChunkIndex = 0
        transferredBytes = 0
        rasterTransmissionBegan = false
        isJobActive = false
        currentFlowControlPauseStartedAt = nil
        chunksSentInCurrentBurst = 0
        pacingPauseTask?.cancel()
        pacingPauseTask = nil
    }

    private func failJob(message: String) {
        finishJob(.failure(.sendFailed(message)))
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
            intentionalPacingPauseCount: intentionalPacingPauseCount,
            physicalPrintDuration: metrics?.physicalPrintDuration
        )
    }

    private func registerFlowControlPause() {
        guard currentFlowControlPauseStartedAt == nil else {
            return
        }

        currentFlowControlPauseStartedAt = Date()
        flowControlPauseCount += 1
        updateMetrics(duration: nil)
    }

    private func clearFlowControlPauseIfNeeded() {
        guard let pauseStartedAt = currentFlowControlPauseStartedAt else {
            return
        }

        let duration = Date().timeIntervalSince(pauseStartedAt)
        if let existingLongest = longestFlowControlPause {
            longestFlowControlPause = max(existingLongest, duration)
        } else {
            longestFlowControlPause = duration
        }
        currentFlowControlPauseStartedAt = nil
        updateMetrics(duration: nil)
        appendLog("No-response flow-control pause cleared after \(String(format: "%.3f", duration)) seconds.")
    }

    private func finishTimedScan() {
        centralManager?.stopScan()

        if case .scanning = jobState {
            jobState = candidates.isEmpty
                ? .failure("Scan finished. No VOZY 18F0 BLE candidates were discovered.")
                : .idle
        }

        appendLog("BT2 scan finished. Candidates: \(candidates.count).")
    }

    private func clearConnection() {
        connectedPeripheral?.delegate = nil
        connectedPeripheral = nil
        connectedPrinterName = nil
        writeCharacteristic = nil
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
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        bluetoothState = central.state.displayName

        if central.state != .poweredOn {
            stopScan()
            if isJobActive {
                failJob(message: "Bluetooth state changed to \(central.state.displayName).")
            }
            clearConnection()
            jobState = .failure("Bluetooth is \(central.state.displayName.lowercased()). Wi-Fi printing is unaffected.")
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
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
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
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

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard connectedPeripheral?.identifier == peripheral.identifier else {
            return
        }

        let detail = error?.localizedDescription ?? "No CoreBluetooth error was provided."
        clearConnection()
        jobState = .failure("Bluetooth connection failed. \(detail)")
        appendLog("Connection failed. \(detail)")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
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
            failJob(message: "Bluetooth printer disconnected during raster job. \(detail)")
        } else {
            jobState = .failure("Bluetooth printer disconnected. \(detail)")
            appendLog("Bluetooth printer disconnected. \(detail)")
        }
    }
}

extension PrinterBluetoothService: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
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

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
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
        jobState = .connected(connectedPrinterName ?? "VOZY G80")
        appendLog("Characteristic 2AF1 ready. Properties: \(characteristic.propertyLabels.joined(separator: ", ")).")
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard connectedPeripheral?.identifier == peripheral.identifier else {
            return
        }

        if let error {
            failJob(message: "Write failed at chunk \(pendingChunkIndex + 1). \(error.localizedDescription)")
            return
        }

        guard let pendingJob, pendingChunkIndex < pendingJob.chunks.count else {
            return
        }

        guard pendingJob.mode == .reliable else {
            return
        }

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

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        guard connectedPeripheral?.identifier == peripheral.identifier else {
            return
        }

        clearFlowControlPauseIfNeeded()

        guard let pendingJob, pendingJob.mode != .reliable, isJobActive else {
            return
        }

        guard let writeCharacteristic else {
            failJob(message: "Bluetooth write characteristic disappeared while resuming fast mode.")
            return
        }

        appendLog("CoreBluetooth is ready for more no-response writes.")
        sendWithoutResponseChunks(peripheral: peripheral, characteristic: writeCharacteristic, job: pendingJob)
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
#endif
