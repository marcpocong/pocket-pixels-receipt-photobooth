//
//  PrinterCoordinator.swift
//  PocketPixelsBooth
//

import Foundation
import Combine

enum PrinterConnectionMode: String, CaseIterable, Identifiable {
    case auto
    case bluetooth
    case wifi

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto:
            return "Auto"
        case .bluetooth:
            return "Bluetooth"
        case .wifi:
            return "Wi-Fi"
        }
    }
}

enum PrinterTransportSelection: String, Codable, Sendable {
    case none
    case bluetooth
    case wifi

    var displayName: String {
        switch self {
        case .none:
            return "None"
        case .bluetooth:
            return "Bluetooth"
        case .wifi:
            return "Wi-Fi"
        }
    }
}

nonisolated enum ReceiptBluetoothTransferMode: String, CaseIterable, Identifiable, Sendable {
    case balanced
    case compatibility

    nonisolated var id: String { rawValue }

    nonisolated var displayName: String {
        switch self {
        case .balanced: "Balanced (Default)"
        case .compatibility: "Compatibility (Safe, Slower)"
        }
    }

    nonisolated var detail: String {
        switch self {
        case .balanced:
            "Paced BLE bursts using the printer's flow control for faster, more continuous output. Tuned on the VOZY G80 but still an experimental transport policy until the release hardware qualification passes. Switch to Compatibility if any receipt is incomplete."
        case .compatibility:
            "Waits for an acknowledgement after every small write (Safe / Integrity policy). Slower, but the most conservative option."
        }
    }

    nonisolated var transportPolicy: ProductionPrintTransportPolicy {
        switch self {
        case .balanced: .experimentalBalanced
        case .compatibility: .safeIntegrity
        }
    }

    /// One line for Equipment and diagnostic reports so operators can see the active behavior.
    nonisolated var operatorSummary: String {
        "\(self == .balanced ? "Balanced" : "Compatibility") · \(transportPolicy.displayName) policy"
    }
}

/// Production receipt transport decision — the single source of truth.
///
/// Customer receipts default to Balanced (`.experimentalBalanced`) because it was tuned on the
/// VOZY G80 and prints noticeably faster. The policy keeps its "experimental" name on purpose:
/// it is conditional on the physical release-candidate qualification in
/// Docs/ReleaseQualification.md. Compatibility (`.safeIntegrity`) is always available in Printer
/// Setup. Neither mode retries automatically after bytes may have started.
nonisolated enum ProductionReceiptTransportDecision {
    nonisolated static let defaultMode: ReceiptBluetoothTransferMode = .balanced
    nonisolated static let safeFallbackMode: ReceiptBluetoothTransferMode = .compatibility
}

/// Shared presentation/readiness vocabulary for Home, setup, checkout and owner monitoring.
nonisolated enum OperatorPrinterState: String, Equatable {
    case disconnected, connecting, connected, ready, busy, awaitingTest, unresolved
    var label: String {
        switch self {
        case .disconnected: "Disconnected"
        case .connecting: "Connecting"
        case .connected: "Connected · check paper"
        case .ready: "Ready · check paper"
        case .busy: "Printing · please wait"
        case .awaitingTest: "Needs attention"
        case .unresolved: "Needs attention"
        }
    }
    /// Preserve the deployed monitoring protocol; busy is healthy, not a new incident.
    var telemetryValue: String {
        switch self {
        case .ready, .connected, .busy: "ready"
        case .unresolved: "recovery"
        case .disconnected, .connecting, .awaitingTest: "unavailable"
        }
    }
    var acceptsJobs: Bool { self == .ready || self == .connected }
    static func resolve(mode: PrinterConnectionMode, bluetoothConnected: Bool, bluetoothReady: Bool,
                        bluetoothNeedsTest: Bool, wifiConnected: Bool, busy: Bool, unresolved: Bool) -> Self {
        if busy { return .busy }
        if unresolved { return .unresolved }
        if mode != .wifi {
            if bluetoothReady { return .ready }
            // Auto selects a connected Bluetooth printer before trying Wi-Fi, so its text-test
            // requirement must not be hidden by a previous Wi-Fi connection check.
            if bluetoothConnected { return bluetoothNeedsTest ? .awaitingTest : .connected }
        }
        if mode != .bluetooth && wifiConnected { return .connected }
        return .disconnected
    }
}

@MainActor
final class PrinterCoordinator: ObservableObject {
    typealias StateHandler = (PrinterConnectionState) -> Void
    typealias CompletionHandler = (Result<Void, Error>) -> Void

    static let shared = PrinterCoordinator()

    @Published private(set) var state = PrinterConnectionState.disconnected
    @Published private(set) var activeTransport = PrinterTransportSelection.none
    @Published private(set) var fallbackReason: String?
    @Published private(set) var wifiCheckMessage = "Reconnect to check the Wi-Fi printer."
    @Published private(set) var checkingWiFi = false
    private var wifiCheckedAt: Date?
    private var wifiCheckedEndpoint: String?
    @Published var receiptBluetoothTransferMode: ReceiptBluetoothTransferMode {
        didSet {
            UserDefaults.standard.set(receiptBluetoothTransferMode.rawValue, forKey: Self.receiptBluetoothTransferModeKey)
        }
    }

    private static let modeKey = "printerConnectionMode"
    private static let receiptBluetoothTransferModeKey = "receiptBluetoothTransferMode"
    private let bluetoothService: PrinterBluetoothService
    private let wifiService: PrinterNetworkService
    private let spooler: PrintSpooler
    private let printOutbox: () -> PrintOutcomeOutbox?
    private let operatorAuthorized: () -> Bool
    private let readinessOverride: (() -> String?)?
    private let transportOverride: PrintSpooler.TransportOperation?
    private var submissionReserved = false
    @Published private(set) var quickTestMessage = ""

    var transportConnected: Bool {
        preferredMode == .wifi ? wifiConnectionVerified : (bluetoothService.isConnectedAndReady || (preferredMode == .auto && wifiConnectionVerified))
    }

    func quickTestPrint() {
        guard operatorAuthorized(), operatorPrintBlockReason == nil else { return }
        do {
            let raster = try QuickPrinterTest.raster()
            let envelope = try PrintJobEnvelope.diagnostic(heading: ThermalImageRasterizer.receiptPrintHeading(),
                rasterizedImage: raster, finishing: ThermalImageRasterizer.receiptPrintFinishing(),
                sessionIdentifier: "operator-quick-test", copyIndex: 1, copyCount: 1, batchID: UUID(), transportPolicy: .safeIntegrity)
            let defaults = UserDefaults.standard
            quickTestMessage = "Sending test…"
            printEnvelope(envelope, wifiHost: defaults.string(forKey: "printerIP") ?? BoothConfiguration.defaultPrinterIP,
                wifiPort: UInt16(defaults.string(forKey: "printerPort") ?? BoothConfiguration.defaultPrinterPort), completion: { [weak self] result in
                switch result {
                case .success: self?.quickTestMessage = "Test sent. Check the paper."
                case .failure(let error): self?.quickTestMessage = "\(error.localizedDescription) No automatic retry."
                }
                EventOperationalState.shared.refresh()
            })
        } catch { quickTestMessage = error.localizedDescription }
    }

    init(spooler: PrintSpooler? = nil,
         outbox: @escaping () -> PrintOutcomeOutbox? = { .shared },
         authorized: @escaping () -> Bool = { OperatorAccessPermit.shared.isAuthorized },
         readiness: (() -> String?)? = nil,
         transport: PrintSpooler.TransportOperation? = nil) {
        self.spooler = spooler ?? .shared
        self.printOutbox = outbox
        self.operatorAuthorized = authorized
        self.readinessOverride = readiness
        self.transportOverride = transport
        bluetoothService = PrinterBluetoothService.shared
        wifiService = PrinterNetworkService()
        receiptBluetoothTransferMode = UserDefaults.standard.string(forKey: Self.receiptBluetoothTransferModeKey)
            .flatMap(ReceiptBluetoothTransferMode.init(rawValue:)) ?? ProductionReceiptTransportDecision.defaultMode
    }

    var productionReceiptTransportPolicy: ProductionPrintTransportPolicy {
        receiptBluetoothTransferMode.transportPolicy
    }

    var preferredMode: PrinterConnectionMode {
        get {
            guard let rawValue = UserDefaults.standard.string(forKey: Self.modeKey),
                  let mode = PrinterConnectionMode(rawValue: rawValue) else {
                return .auto
            }

            return mode
        }
        set {
            guard !isWorking else { return }
            objectWillChange.send()
            wifiCheckedAt = nil
            UserDefaults.standard.set(newValue.rawValue, forKey: Self.modeKey)
            fallbackReason = nil
        }
    }

    var bluetoothPrinterName: String {
        bluetoothService.connectedPrinterName ?? bluetoothService.savedPrinterName ?? "VOZY G80"
    }

    var bluetoothSummary: String {
        if bluetoothService.isConnectedAndReady {
            return "\(bluetoothPrinterName) connected"
        }

        if bluetoothService.hasSavedPrinter {
            return "\(bluetoothPrinterName) saved"
        }

        return "No Bluetooth printer saved"
    }

    var isBluetoothReady: Bool {
        bluetoothService.isConnectedAndReady
    }

    var isWorking: Bool {
        submissionReserved || spooler.isWorking || state.isWorking || bluetoothService.isTransmitting || checkingWiFi
    }

    var requiresRecovery: Bool {
        state.requiresPrinterRestart || spooler.requiresRecovery || bluetoothService.needsHardwareAcknowledgement
    }

    private var wifiEndpoint: String {
        let defaults = UserDefaults.standard
        return "\(defaults.string(forKey: "printerIP") ?? BoothConfiguration.defaultPrinterIP):\(defaults.string(forKey: "printerPort") ?? BoothConfiguration.defaultPrinterPort)"
    }
    var wifiConnectionVerified: Bool {
        guard let wifiCheckedAt else { return false }
        return wifiCheckedEndpoint == wifiEndpoint && wifiCheckedAt <= Date()
    }
    func invalidateWiFiConnectionCheck() {
        objectWillChange.send()
        wifiCheckedAt = nil
    }
    var needsHardwareAcknowledgement: Bool {
        requiresRecovery || EventOperationalState.shared.hasUnresolvedPrint
    }

    var canPerformOperatorPrint: Bool { operatorAuthorized() && operatorPrintBlockReason == nil }

    var operatorPrintBlockReason: String? {
        if isWorking { return "Another print is still finishing." }
        guard let outbox = printOutbox(), outbox.integrityFault == nil,
              outbox.persistenceFailure == nil, !outbox.hasUnfinishedPhysicalSend else {
            return "Print records need saving. Open Help & Recovery → Retry Saving Resolution."
        }
        if let readinessOverride { return readinessOverride() }
        if needsHardwareAcknowledgement { return "Check the printer, reconnect and acknowledge readiness below." }
        if !operatorState.acceptsJobs { return "Printer disconnected. Reconnect to print." }
        return nil
    }

    var operatorState: OperatorPrinterState {
        if !isWorking, bluetoothService.jobState.isWorking { return .connecting }
        return OperatorPrinterState.resolve(mode: preferredMode, bluetoothConnected: bluetoothService.isConnectedAndReady,
            bluetoothReady: bluetoothService.canPrintRaster, bluetoothNeedsTest: bluetoothService.needsDiagnosticTextTest,
            wifiConnected: wifiConnectionVerified, busy: isWorking || checkingWiFi, unresolved: needsHardwareAcknowledgement)
    }
    var currentPrinterLabel: String {
        if preferredMode == .wifi || (preferredMode == .auto && !bluetoothService.isConnectedAndReady && wifiConnectionVerified) {
            return "Wi-Fi · \(wifiEndpoint)"
        }
        return bluetoothSummary
    }
    /// A bounded connection-only probe using the same network service that prints receipts.
    /// This clears its post-restart connection-test gate without sending receipt bytes.
    func checkWiFiConnection() async -> Bool {
        guard !isWorking, !checkingWiFi else { return false }
        let endpoint = wifiEndpoint
        let defaults = UserDefaults.standard
        let host = defaults.string(forKey: "printerIP") ?? BoothConfiguration.defaultPrinterIP
        guard let port = UInt16(defaults.string(forKey: "printerPort") ?? BoothConfiguration.defaultPrinterPort), port > 0 else {
            wifiCheckMessage = "Enter a Wi-Fi printer port from 1 to 65535 in Advanced."
            return false
        }
        checkingWiFi = true; wifiCheckedAt = nil
        defer { checkingWiFi = false }
        return await withCheckedContinuation { continuation in
            wifiService.testConnection(host: host, port: port, onStateChange: { _ in }) { [weak self] result in
                Task { @MainActor in
                    guard let self else { continuation.resume(returning: false); return }
                    if case .success = result, endpoint == self.wifiEndpoint {
                        self.wifiCheckedAt = Date(); self.wifiCheckedEndpoint = endpoint
                        self.wifiCheckMessage = "Wi-Fi connected. Check paper; connection alone cannot confirm a printed receipt."
                        continuation.resume(returning: true)
                    } else {
                        self.wifiCheckedAt = nil
                        self.wifiCheckMessage = "Wi-Fi printer unavailable. Check its power, network and address in Advanced."
                        continuation.resume(returning: false)
                    }
                }
            }
        }
    }
    func waitForSelectedPrinter() async throws -> Bool {
        try Task.checkCancellation()
        if preferredMode != .wifi {
            if try await bluetoothService.waitUntilReady() { return true }
            if preferredMode == .bluetooth || bluetoothService.isConnectedAndReady { return false }
        }
        try Task.checkCancellation()
        return await checkWiFiConnection()
    }
    func reconnectSelectedPrinter() {
        guard !isWorking else { return }
        if preferredMode == .wifi { Task { _ = await checkWiFiConnection() } }
        else { reconnectBluetoothPrinter() }
    }

    var auditExportText: String {
        spooler.auditExportText
    }

    func prepare() {
        if preferredMode == .wifi {
            if !EventOperationalState.shared.customerSessionActive { Task { _ = await checkWiFiConnection() } }
            return
        }
        bluetoothService.prepareSavedPrinter()
    }

    func reconnectBluetoothPrinter() {
        guard !isWorking else { return }
        fallbackReason = nil
        bluetoothService.reconnectSavedPrinter()
    }

    func forgetBluetoothPrinter() {
        fallbackReason = nil
        bluetoothService.forgetKnownPrinter()
        activeTransport = .none
        publish(.disconnected)
    }

    func confirmPrinterRestarted() {
        guard !isWorking else { return }
        spooler.confirmPrinterRestarted()
        bluetoothService.confirmPrinterRestarted()
        wifiService.confirmPrinterRestarted { _ in }
        publish(.disconnected)
    }

    func quickBluetoothTextTest(completion: CompletionHandler? = nil) {
        guard !spooler.isWorking else {
            publish(.failure(PrinterNetworkError.jobAlreadyActive.userMessage))
            completion?(.failure(PrinterNetworkError.jobAlreadyActive))
            return
        }

        activeTransport = .bluetooth
        publish(.printing)

        bluetoothService.printQuickText { [weak self] result, bytesStarted in
            guard let self else { return }

            switch result {
            case .success:
                self.publish(.success("Bluetooth test sent."))
                completion?(.success(()))
            case .failure(let error):
                let message = bytesStarted
                    ? BluetoothPrinterServiceError.recoveryRequired.localizedDescription
                    : error.localizedDescription
                self.publish(bytesStarted ? .recoveryRequired(message) : .failure(message))
                completion?(.failure(error))
            }
        }
    }

    func printReceipt(
        rasterizedImage: ThermalRasterizedImage,
        wifiHost: String,
        wifiPort: UInt16?,
        sessionIdentifier: String = "operator",
        source: PrintJobSource = .diagnostic,
        copyIndex: Int = 1,
        copyCount: Int = 1,
        batchID: UUID = UUID(),
        transportPolicy: ProductionPrintTransportPolicy = .safeIntegrity,
        prePrintCheckpoint: PrePrintCheckpointGate? = nil,
        onStateChange: StateHandler? = nil,
        completion: CompletionHandler? = nil
    ) {
        guard !spooler.requiresRecovery else {
            let message = "Printer needs attention. Please ask staff for assistance."
            let state = PrinterConnectionState.recoveryRequired(message)
            publish(state, onStateChange: onStateChange)
            completion?(.failure(PrintSpoolerError.recoveryRequired(message)))
            return
        }

        do {
            let envelope = try PrintJobEnvelope.receipt(
                rasterizedImage: rasterizedImage,
                sessionIdentifier: sessionIdentifier,
                source: source,
                copyIndex: copyIndex,
                copyCount: copyCount,
                batchID: batchID,
                transportPolicy: transportPolicy
            )
            submitReceiptEnvelope(
                envelope,
                wifiHost: wifiHost,
                wifiPort: wifiPort,
                prePrintCheckpoint: prePrintCheckpoint,
                onStateChange: onStateChange,
                completion: completion
            )
        } catch {
            let state = PrinterConnectionState.failure(error.localizedDescription)
            publish(state, onStateChange: onStateChange)
            completion?(.failure(error))
        }
    }

    func printEnvelope(
        _ envelope: PrintJobEnvelope,
        wifiHost: String,
        wifiPort: UInt16?,
        onStateChange: StateHandler? = nil,
        completion: CompletionHandler? = nil
    ) {
        submitReceiptEnvelope(
            envelope,
            wifiHost: wifiHost,
            wifiPort: wifiPort,
            onStateChange: onStateChange,
            completion: completion
        )
    }

    private func submitReceiptEnvelope(
        _ envelope: PrintJobEnvelope,
        wifiHost: String,
        wifiPort: UInt16?,
        prePrintCheckpoint: PrePrintCheckpointGate? = nil,
        onStateChange: StateHandler?,
        completion: CompletionHandler?
    ) {
        guard !isWorking else {
            let state = PrinterConnectionState.failure(PrinterNetworkError.jobAlreadyActive.userMessage)
            publish(state, onStateChange: onStateChange)
            completion?(.failure(PrinterNetworkError.jobAlreadyActive))
            return
        }

        do {
            try envelope.verifyPayloadIntegrity()
        } catch {
            let state = PrinterConnectionState.failure(error.localizedDescription)
            publish(state, onStateChange: onStateChange)
            completion?(.failure(error))
            return
        }

        if envelope.source != .liveCustomer {
            guard operatorAuthorized() else {
                completion?(.failure(SetupFailure("Unlock Operator before printing."))); return
            }
            if let reason = operatorPrintBlockReason {
                completion?(.failure(SetupFailure(reason))); return
            }
        }
        fallbackReason = nil
        submissionReserved = true
        objectWillChange.send()
        let operatorJob = envelope.source != .liveCustomer && prePrintCheckpoint == nil
        let gate: PrePrintCheckpointGate?
        if operatorJob {
            gate = PrePrintCheckpointGate({ job in
                guard let outbox = self.printOutbox() else { throw AppRecoveryStoreError.unavailable }
                try outbox.beginCopy(batchID: job.batchID.uuidString.lowercased(), sessionID: job.sessionIdentifier,
                    entitlementID: nil, receiptFingerprint: job.payloadFingerprint, copyIndex: job.copyIndex,
                    copyCount: job.copyCount, transport: "none", source: job.source)
            }, selectTransport: { job, transport in
                try self.printOutbox()?.selectTransportBeforeBytes(batchID: job.batchID.uuidString.lowercased(), copyIndex: job.copyIndex, transport: transport)
            })
        } else { gate = prePrintCheckpoint }

        Task {
            let result = await spooler.submit(envelope: envelope, prePrintCheckpoint: gate?.persist) { envelope in
                if let transport = self.transportOverride { return await transport(envelope) }
                return await self.printReceiptWithSelectedTransport(
                    envelope: envelope,
                    wifiHost: wifiHost,
                    wifiPort: wifiPort,
                    prePrintCheckpoint: gate,
                    onStateChange: onStateChange
                )
            }
            var outcome = result
            if operatorJob {
                let local: PrintCopyLocalState
                switch result {
                case .success: local = .delivered
                case .failure(let error): local = ((error as? PrintTransportFailure)?.bytesStarted ?? false) ? .uncertain : .notStarted
                }
                if self.printOutbox()?.hasUnfinishedPhysicalSend == true, self.printOutbox()?.finishCopy(batchID: envelope.batchID.uuidString.lowercased(), copyIndex: envelope.copyIndex, state: local) != true {
                    outcome = .failure(SetupFailure("Print outcome needs saving. Do not resend; open Help & Recovery."))
                }
            }
            self.submissionReserved = false
            switch outcome {
            case .success:
                self.publish(.success("Your receipt is ready."), onStateChange: onStateChange)
                completion?(.success(()))
            case .failure(let error):
                let bytesStarted = (error as? PrintTransportFailure)?.bytesStarted ?? false
                let state: PrinterConnectionState = bytesStarted
                    ? .recoveryRequired("Printer needs attention. Please ask staff for assistance.")
                    : .failure(error.localizedDescription)
                self.publish(state, onStateChange: onStateChange)
                completion?(.failure(error))
            }
        }
    }

    private func printReceiptWithSelectedTransport(
        envelope: PrintJobEnvelope,
        wifiHost: String,
        wifiPort: UInt16?,
        prePrintCheckpoint: PrePrintCheckpointGate?,
        onStateChange: StateHandler?
    ) async -> Result<PhysicalPrintTransportResult, Error> {
        let mode = preferredMode

        if mode == .auto || mode == .bluetooth {
            publish(.connecting, onStateChange: onStateChange)

            if !bluetoothService.isConnectedAndReady {
                bluetoothService.prepareSavedPrinter()
                _ = await waitForBluetoothReady(timeout: 5)
            }

            if bluetoothService.isConnectedAndReady {
                return await sendBluetoothReceipt(
                    envelope: envelope,
                    wifiHost: wifiHost,
                    wifiPort: wifiPort,
                    allowWifiFallbackBeforeBytes: mode == .auto,
                    prePrintCheckpoint: prePrintCheckpoint,
                    onStateChange: onStateChange
                )
            }

            if mode == .bluetooth {
                let state = PrinterConnectionState.failure("Bluetooth printer unavailable. Please ask staff for assistance.")
                publish(state, onStateChange: onStateChange)
                return .failure(BluetoothPrinterServiceError.printerNotConnected)
            }

            fallbackReason = "Bluetooth was unavailable before any print bytes were sent."
        }

        return await sendWifiReceipt(
            envelope: envelope,
            wifiHost: wifiHost,
            wifiPort: wifiPort,
            prePrintCheckpoint: prePrintCheckpoint,
            onStateChange: onStateChange
        )
    }

    private func sendBluetoothReceipt(
        envelope: PrintJobEnvelope,
        wifiHost: String,
        wifiPort: UInt16?,
        allowWifiFallbackBeforeBytes: Bool,
        prePrintCheckpoint: PrePrintCheckpointGate?,
        onStateChange: StateHandler?
    ) async -> Result<PhysicalPrintTransportResult, Error> {
        do {
            try prePrintCheckpoint?.selectTransport(envelope, .bluetooth)
        } catch {
            return .failure((error as? PrintCheckpointError) ?? PrintCheckpointError.persistenceFailed(error.localizedDescription))
        }
        activeTransport = .bluetooth
        publish(.sendingPhotograph, onStateChange: onStateChange)

        let startedAt = Date()
        let bluetoothMode = envelope.transportPolicy.bluetoothMode

        return await withCheckedContinuation { continuation in
            bluetoothService.printEnvelope(
                envelope,
                mode: bluetoothMode,
                balancedProfile: .medium
            ) { [weak self] result, bytesStarted in
                guard let self else { return }
                let metrics = self.bluetoothService.metrics
                let transportResult = PhysicalPrintTransportResult(
                    transport: .bluetooth,
                    bluetoothMode: bluetoothMode,
                    chunkSize: metrics?.chunkSize,
                    chunkCount: metrics?.chunkCount,
                    flowControlPauseCount: metrics?.flowControlPauseCount,
                    writeTimeout: self.bluetoothService.lastReliableWriteTimeout,
                    bytesStarted: bytesStarted,
                    transportFinishedAt: Date()
                )

                switch result {
                case .success:
                    debugLog("[PrinterCoordinator] Bluetooth envelope complete job=\(envelope.jobID.uuidString) elapsed=\(String(format: "%.2f", Date().timeIntervalSince(startedAt)))s")
                    continuation.resume(returning: .success(transportResult))

                case .failure(let error):
                    if allowWifiFallbackBeforeBytes && !bytesStarted {
                        self.fallbackReason = "Bluetooth failed before print bytes started: \(error.localizedDescription)"
                        Task {
                            let fallback = await self.sendWifiReceipt(
                                envelope: envelope,
                                wifiHost: wifiHost,
                                wifiPort: wifiPort,
                                prePrintCheckpoint: prePrintCheckpoint,
                                onStateChange: onStateChange
                            )
                            continuation.resume(returning: fallback)
                        }
                        return
                    }

                    continuation.resume(returning: .failure(PrintTransportFailure(
                        underlyingError: error,
                        bytesStarted: bytesStarted,
                        transportResult: transportResult
                    )))
                }
            }
        }
    }

    private func sendWifiReceipt(
        envelope: PrintJobEnvelope,
        wifiHost: String,
        wifiPort: UInt16?,
        prePrintCheckpoint: PrePrintCheckpointGate?,
        onStateChange: StateHandler?
    ) async -> Result<PhysicalPrintTransportResult, Error> {
        guard let wifiPort else {
            let state = PrinterConnectionState.failure(PrinterNetworkError.invalidPort.userMessage)
            publish(state, onStateChange: onStateChange)
            return .failure(PrinterNetworkError.invalidPort)
        }

        do {
            try prePrintCheckpoint?.selectTransport(envelope, .wifi)
        } catch {
            return .failure((error as? PrintCheckpointError) ?? PrintCheckpointError.persistenceFailed(error.localizedDescription))
        }
        activeTransport = .wifi

        return await withCheckedContinuation { continuation in
            wifiService.printFrozenReceipt(
                envelope: envelope,
                host: wifiHost,
                port: wifiPort
            ) { [weak self] state in
                self?.publish(state, onStateChange: onStateChange)
            } completion: { result, transmission in
                Task { @MainActor in
                    if case .failure = result { self.wifiCheckedAt = nil }
                }
                continuation.resume(returning: Self.wifiTransportOutcome(result: result, transmission: transmission))
            }
        }
    }

    /// Maps a Wi-Fi job result to the spooler contract using the transmission state actually
    /// reached. Only failures at or after `sendStarted` are uncertain prints that lock recovery;
    /// a failure before any bytes is a safe, retryable failure.
    nonisolated static func wifiTransportOutcome(
        result: Result<Void, PrinterNetworkError>,
        transmission: NetworkPrintTransmission,
        finishedAt: Date = Date()
    ) -> Result<PhysicalPrintTransportResult, Error> {
        let succeeded: Bool
        if case .success = result { succeeded = true } else { succeeded = false }
        let transportResult = PhysicalPrintTransportResult(
            transport: .wifi,
            bluetoothMode: nil,
            chunkSize: nil,
            chunkCount: nil,
            flowControlPauseCount: nil,
            writeTimeout: nil,
            // A reported success always sent bytes, whatever stage was recorded.
            bytesStarted: succeeded || transmission.bytesMayHaveStarted,
            transportFinishedAt: finishedAt
        )
        switch result {
        case .success:
            return .success(transportResult)
        case .failure(let error):
            return .failure(PrintTransportFailure(
                underlyingError: error,
                bytesStarted: transmission.bytesMayHaveStarted,
                transportResult: transportResult
            ))
        }
    }

    private func waitForBluetoothReady(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if bluetoothService.isConnectedAndReady {
                return true
            }

            try? await Task.sleep(nanoseconds: 200_000_000)
        }

        return bluetoothService.isConnectedAndReady
    }

    private func publish(_ state: PrinterConnectionState, onStateChange: StateHandler? = nil) {
        self.state = state
        onStateChange?(state)
    }
}

private func debugLog(_ message: String) {
#if DEBUG
    print(message)
#endif
}
