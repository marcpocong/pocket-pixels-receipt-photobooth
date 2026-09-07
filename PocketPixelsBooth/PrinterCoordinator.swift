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

@MainActor
final class PrinterCoordinator: ObservableObject {
    typealias StateHandler = (PrinterConnectionState) -> Void
    typealias CompletionHandler = (Result<Void, Error>) -> Void

    static let shared = PrinterCoordinator()

    @Published private(set) var state = PrinterConnectionState.disconnected
    @Published private(set) var activeTransport = PrinterTransportSelection.none
    @Published private(set) var fallbackReason: String?

    private static let modeKey = "printerConnectionMode"
    private let bluetoothService: PrinterBluetoothService
    private let wifiService: PrinterNetworkService
    private let spooler = PrintSpooler.shared

    private init() {
        bluetoothService = PrinterBluetoothService.shared
        wifiService = PrinterNetworkService()
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
        spooler.isWorking || state.isWorking
    }

    var requiresRecovery: Bool {
        state.requiresPrinterRestart || spooler.requiresRecovery
    }

    var auditExportText: String {
        spooler.auditExportText
    }

    func prepare() {
        guard preferredMode != .wifi else {
            return
        }

        bluetoothService.prepareSavedPrinter()
    }

    func reconnectBluetoothPrinter() {
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
        spooler.confirmPrinterRestarted()
        bluetoothService.confirmPrinterRestarted()
        wifiService.confirmPrinterRestarted { [weak self] state in
            self?.publish(state)
        }
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

        fallbackReason = nil

        Task {
            let result = await spooler.submit(envelope: envelope) { [weak self] envelope in
                guard let self else {
                    return .failure(PrintSpoolerError.physicalPrinterBusy)
                }

                return await self.printReceiptWithSelectedTransport(
                    envelope: envelope,
                    wifiHost: wifiHost,
                    wifiPort: wifiPort,
                    onStateChange: onStateChange
                )
            }

            switch result {
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
                activeTransport = .bluetooth
                return await sendBluetoothReceipt(
                    envelope: envelope,
                    wifiHost: wifiHost,
                    wifiPort: wifiPort,
                    allowWifiFallbackBeforeBytes: mode == .auto,
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
            onStateChange: onStateChange
        )
    }

    private func sendBluetoothReceipt(
        envelope: PrintJobEnvelope,
        wifiHost: String,
        wifiPort: UInt16?,
        allowWifiFallbackBeforeBytes: Bool,
        onStateChange: StateHandler?
    ) async -> Result<PhysicalPrintTransportResult, Error> {
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
        onStateChange: StateHandler?
    ) async -> Result<PhysicalPrintTransportResult, Error> {
        activeTransport = .wifi

        guard let wifiPort else {
            let state = PrinterConnectionState.failure(PrinterNetworkError.invalidPort.userMessage)
            publish(state, onStateChange: onStateChange)
            return .failure(PrinterNetworkError.invalidPort)
        }

        return await withCheckedContinuation { continuation in
            wifiService.printFrozenReceipt(
                envelope: envelope,
                host: wifiHost,
                port: wifiPort
            ) { [weak self] state in
                self?.publish(state, onStateChange: onStateChange)
            } completion: { result in
                let transportResult = PhysicalPrintTransportResult(
                    transport: .wifi,
                    bluetoothMode: nil,
                    chunkSize: nil,
                    chunkCount: nil,
                    flowControlPauseCount: nil,
                    writeTimeout: nil,
                    bytesStarted: true,
                    transportFinishedAt: Date()
                )

                switch result {
                case .success:
                    continuation.resume(returning: .success(transportResult))
                case .failure(let error):
                    continuation.resume(returning: .failure(PrintTransportFailure(
                        underlyingError: error,
                        bytesStarted: true,
                        transportResult: transportResult
                    )))
                }
            }
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
