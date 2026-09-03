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

enum PrinterTransportSelection: String {
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
    private var isJobActive = false

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
        isJobActive || state.isWorking
    }

    var requiresRecovery: Bool {
        state.requiresPrinterRestart
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
        bluetoothService.confirmPrinterRestarted()
        wifiService.confirmPrinterRestarted { [weak self] state in
            self?.publish(state)
        }
    }

    func quickBluetoothTextTest(completion: CompletionHandler? = nil) {
        guard !isJobActive else {
            publish(.failure(PrinterNetworkError.jobAlreadyActive.userMessage))
            completion?(.failure(PrinterNetworkError.jobAlreadyActive))
            return
        }

        isJobActive = true
        activeTransport = .bluetooth
        publish(.printing)

        bluetoothService.printQuickText { [weak self] result, bytesStarted in
            guard let self else { return }
            self.isJobActive = false

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
        onStateChange: StateHandler? = nil,
        completion: CompletionHandler? = nil
    ) {
        guard !isJobActive else {
            let state = PrinterConnectionState.failure(PrinterNetworkError.jobAlreadyActive.userMessage)
            publish(state, onStateChange: onStateChange)
            completion?(.failure(PrinterNetworkError.jobAlreadyActive))
            return
        }

        do {
            try ThermalImageRasterizer.validateRasterCommand(
                rasterizedImage.rasterCommand,
                imageWidth: rasterizedImage.width,
                imageHeight: rasterizedImage.height,
                bytesPerRow: rasterizedImage.widthBytes,
                rasterDataCount: rasterizedImage.rasterData.count
            )
        } catch {
            let state = PrinterConnectionState.failure(error.localizedDescription)
            publish(state, onStateChange: onStateChange)
            completion?(.failure(error))
            return
        }

        isJobActive = true
        fallbackReason = nil

        Task {
            await printReceiptWithSelectedTransport(
                rasterizedImage: rasterizedImage,
                wifiHost: wifiHost,
                wifiPort: wifiPort,
                onStateChange: onStateChange,
                completion: completion
            )
        }
    }

    private func printReceiptWithSelectedTransport(
        rasterizedImage: ThermalRasterizedImage,
        wifiHost: String,
        wifiPort: UInt16?,
        onStateChange: StateHandler?,
        completion: CompletionHandler?
    ) async {
        let mode = preferredMode

        if mode == .auto || mode == .bluetooth {
            publish(.connecting, onStateChange: onStateChange)

            if !bluetoothService.isConnectedAndReady {
                bluetoothService.prepareSavedPrinter()
                _ = await waitForBluetoothReady(timeout: 5)
            }

            if bluetoothService.isConnectedAndReady {
                activeTransport = .bluetooth
                sendBluetoothReceipt(
                    rasterizedImage: rasterizedImage,
                    wifiHost: wifiHost,
                    wifiPort: wifiPort,
                    allowWifiFallbackBeforeBytes: mode == .auto,
                    onStateChange: onStateChange,
                    completion: completion
                )
                return
            }

            if mode == .bluetooth {
                finishActiveJob()
                let state = PrinterConnectionState.failure("Bluetooth printer unavailable. Please ask staff for assistance.")
                publish(state, onStateChange: onStateChange)
                completion?(.failure(BluetoothPrinterServiceError.printerNotConnected))
                return
            }

            fallbackReason = "Bluetooth was unavailable before any print bytes were sent."
        }

        sendWifiReceipt(
            rasterizedImage: rasterizedImage,
            wifiHost: wifiHost,
            wifiPort: wifiPort,
            onStateChange: onStateChange,
            completion: completion
        )
    }

    private func sendBluetoothReceipt(
        rasterizedImage: ThermalRasterizedImage,
        wifiHost: String,
        wifiPort: UInt16?,
        allowWifiFallbackBeforeBytes: Bool,
        onStateChange: StateHandler?,
        completion: CompletionHandler?
    ) {
        publish(.sendingPhotograph, onStateChange: onStateChange)

        bluetoothService.printRasterizedReceipt(
            rasterizedImage: rasterizedImage,
            mode: .fast,
            balancedProfile: .medium
        ) { [weak self] result, bytesStarted in
            guard let self else { return }

            switch result {
            case .success:
                self.finishActiveJob()
                self.publish(.success("Your receipt is ready."), onStateChange: onStateChange)
                completion?(.success(()))

            case .failure(let error):
                if allowWifiFallbackBeforeBytes && !bytesStarted {
                    self.fallbackReason = "Bluetooth failed before print bytes started: \(error.localizedDescription)"
                    self.sendWifiReceipt(
                        rasterizedImage: rasterizedImage,
                        wifiHost: wifiHost,
                        wifiPort: wifiPort,
                        onStateChange: onStateChange,
                        completion: completion
                    )
                    return
                }

                self.finishActiveJob()
                let state: PrinterConnectionState = bytesStarted
                    ? .recoveryRequired("Printer needs attention. Please ask staff for assistance.")
                    : .failure("Printer unavailable. Please ask staff for assistance.")
                self.publish(state, onStateChange: onStateChange)
                completion?(.failure(error))
            }
        }
    }

    private func sendWifiReceipt(
        rasterizedImage: ThermalRasterizedImage,
        wifiHost: String,
        wifiPort: UInt16?,
        onStateChange: StateHandler?,
        completion: CompletionHandler?
    ) {
        activeTransport = .wifi

        guard let wifiPort else {
            finishActiveJob()
            let state = PrinterConnectionState.failure(PrinterNetworkError.invalidPort.userMessage)
            publish(state, onStateChange: onStateChange)
            completion?(.failure(PrinterNetworkError.invalidPort))
            return
        }

        wifiService.printPhoto(
            heading: ThermalImageRasterizer.receiptPrintHeading(),
            rasterCommand: rasterizedImage.rasterCommand,
            finishing: ThermalImageRasterizer.photoTestFinishing(),
            imageWidth: rasterizedImage.width,
            imageHeight: rasterizedImage.height,
            rasterDataByteCount: rasterizedImage.rasterData.count,
            sanitizationReport: rasterizedImage.sanitizationReport,
            yL: rasterizedImage.yL,
            yH: rasterizedImage.yH,
            host: wifiHost,
            port: wifiPort
        ) { [weak self] state in
            self?.publish(state, onStateChange: onStateChange)
        } completion: { [weak self] result in
            guard let self else { return }
            self.finishActiveJob()

            switch result {
            case .success:
                self.publish(.success("Your receipt is ready."), onStateChange: onStateChange)
                completion?(.success(()))
            case .failure(let error):
                completion?(.failure(error))
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

    private func finishActiveJob() {
        isJobActive = false
    }
}
