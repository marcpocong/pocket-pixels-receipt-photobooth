//
//  PrinterNetworkService.swift
//  PocketPixelsBooth
//
//  Created by marc on 8/30/26.
//

import Foundation
import Network

enum PrinterConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case printing
    case sendingHeading
    case sendingPhotograph
    case finalizingAndCutting
    case printerProcessing
    case coolingDown
    case recoveryRequired(String)
    case success(String)
    case failure(String)

    var message: String {
        switch self {
        case .disconnected:
            "Ready to test the printer connection."
        case .connecting:
            "Connecting to the printer..."
        case .connected:
            "Connected to the printer."
        case .printing:
            "Sending test receipt..."
        case .sendingHeading:
            "Sending heading..."
        case .sendingPhotograph:
            "Sending photograph..."
        case .finalizingAndCutting:
            "Finalizing and cutting..."
        case .printerProcessing:
            "Printer processing..."
        case .coolingDown:
            "Cooling down before the next print..."
        case .recoveryRequired(let message):
            message
        case .success(let message):
            message
        case .failure(let message):
            message
        }
    }

    var isWorking: Bool {
        switch self {
        case .connecting, .connected, .printing, .sendingHeading, .sendingPhotograph, .finalizingAndCutting, .printerProcessing, .coolingDown:
            true
        case .disconnected, .recoveryRequired, .success, .failure:
            false
        }
    }

    var requiresPrinterRestart: Bool {
        if case .recoveryRequired = self {
            return true
        }

        return false
    }
}

enum PrinterNetworkError: Error, Equatable {
    case invalidHost
    case invalidPort
    case timedOut(host: String, port: UInt16)
    case jobAlreadyActive
    case printerRecoveryRequired
    case connectionTestRequired
    case connectionFailed(String)
    case sendFailed(String)
    case developmentError(String)

    var userMessage: String {
        switch self {
        case .invalidHost:
            "Enter a printer IP address."
        case .invalidPort:
            "Enter a valid TCP port from 1 to 65535."
        case .timedOut(let host, let port):
            "The printer job timed out while connected to \(host):\(port). If this happened during image data, restart the printer before trying again."
        case .jobAlreadyActive:
            "A printer job is already active. Wait for it to finish before starting another."
        case .printerRecoveryRequired:
            "The previous image transmission may have been interrupted. Turn the printer off for 10 seconds, turn it back on, then confirm below."
        case .connectionTestRequired:
            "Run Test Connection successfully before sending another image print."
        case .connectionFailed(let details):
            "Could not connect to the printer. \(details)"
        case .sendFailed(let details):
            "The printer job could not be sent. \(details) If this happened during image data, restart the printer before trying again."
        case .developmentError(let details):
            "Printer job preflight failed. \(details)"
        }
    }
}

final class PrinterNetworkService {
    typealias StateHandler = (PrinterConnectionState) -> Void
    typealias CompletionHandler = (Result<Void, PrinterNetworkError>) -> Void

    private enum JobStartResult {
        case allowed
        case rejected(PrinterNetworkError)

        var error: PrinterNetworkError {
            switch self {
            case .allowed:
                .jobAlreadyActive
            case .rejected(let error):
                error
            }
        }
    }

    private let timeout: TimeInterval
    private let stateQueue = DispatchQueue(label: "com.pocketpixels.printer-network-state")
    private var activeConnection: NWConnection?
    private var isJobActive = false
    private var isRecoveryLockoutActive = false
    private var requiresConnectionTestBeforeRasterPrint = false

    init(timeout: TimeInterval = 8) {
        self.timeout = timeout
    }

    func testConnection(
        host: String,
        port: UInt16,
        onStateChange: @escaping StateHandler,
        completion: @escaping CompletionHandler
    ) {
        perform(
            host: host,
            port: port,
            payload: nil,
            onStateChange: onStateChange,
            completion: completion
        )
    }

    func confirmPrinterRestarted(onStateChange: @escaping StateHandler) {
        stateQueue.sync {
            isRecoveryLockoutActive = false
            requiresConnectionTestBeforeRasterPrint = true
        }

        DispatchQueue.main.async {
            onStateChange(.disconnected)
        }
    }

    func print(
        payload: Data,
        host: String,
        port: UInt16,
        onStateChange: @escaping StateHandler,
        completion: @escaping CompletionHandler
    ) {
        perform(
            host: host,
            port: port,
            payloads: [payload],
            successMessage: "Test receipt sent.",
            onStateChange: onStateChange,
            completion: completion
        )
    }

    func printPhoto(
        heading: Data,
        rasterCommand: Data,
        finishing: Data,
        imageWidth: Int,
        imageHeight: Int,
        rasterDataByteCount: Int,
        sanitizationReport: RasterSanitizationReport,
        yL: UInt8,
        yH: UInt8,
        host: String,
        port: UInt16,
        onStateChange: @escaping StateHandler,
        completion: @escaping CompletionHandler
    ) {
        let rasterDataRange = 8..<rasterCommand.count

        do {
            try RasterCommandSanitizer.validateOutboundJob(
                heading: heading,
                rasterCommand: rasterCommand,
                finishing: finishing,
                rasterDataRange: rasterDataRange
            )
        } catch {
            complete(.failure(.developmentError(error.localizedDescription)), onStateChange: onStateChange, completion: completion)
            return
        }

        performPhotoPrint(
            host: host,
            port: port,
            heading: heading,
            rasterCommand: rasterCommand,
            finishing: finishing,
            imageWidth: imageWidth,
            imageHeight: imageHeight,
            rasterDataByteCount: rasterDataByteCount,
            sanitizationReport: sanitizationReport,
            yL: yL,
            yH: yH,
            timeout: 30,
            onStateChange: onStateChange,
            completion: completion
        )
    }

    private func perform(
        host: String,
        port: UInt16,
        payload: Data?,
        onStateChange: @escaping StateHandler,
        completion: @escaping CompletionHandler
    ) {
        perform(
            host: host,
            port: port,
            payloads: payload.map { [$0] },
            successMessage: payload == nil ? "Connection successful." : "Test receipt sent.",
            onStateChange: onStateChange,
            completion: completion
        )
    }

    private func perform(
        host: String,
        port: UInt16,
        payloads: [Data]?,
        successMessage: String,
        onStateChange: @escaping StateHandler,
        completion: @escaping CompletionHandler
    ) {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedHost.isEmpty else {
            complete(.failure(.invalidHost), onStateChange: onStateChange, completion: completion)
            return
        }

        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            complete(.failure(.invalidPort), onStateChange: onStateChange, completion: completion)
            return
        }

        let isConnectionTest = payloads == nil
        let jobGate = beginJob(isConnectionTest: isConnectionTest, isRasterPrint: false)

        guard case .allowed = jobGate else {
            complete(.failure(jobGate.error), onStateChange: onStateChange, completion: completion)
            return
        }

        let queue = DispatchQueue(label: "com.pocketpixels.printer-network")
        let connection = NWConnection(host: NWEndpoint.Host(trimmedHost), port: endpointPort, using: .tcp)
        var didFinish = false
        var connectionTimeout: DispatchWorkItem?
        storeActiveConnection(connection)

        func update(_ state: PrinterConnectionState) {
            DispatchQueue.main.async {
                onStateChange(state)
            }
        }

        func finish(_ result: Result<Void, PrinterNetworkError>) {
            guard !didFinish else {
                return
            }

            didFinish = true
            connectionTimeout?.cancel()
            connection.stateUpdateHandler = nil
            connection.cancel()
            update(.coolingDown)

            queue.asyncAfter(deadline: .now() + 2) {
                self.clearActiveJob()

                DispatchQueue.main.async {
                    switch result {
                    case .success:
                        onStateChange(.success(successMessage))
                    case .failure(let error):
                        onStateChange(.failure(error.userMessage))
                    }

                    completion(result)
                }
            }
        }

        update(.connecting)

        let timeoutWorkItem = DispatchWorkItem {
            finish(.failure(.timedOut(host: trimmedHost, port: port)))
        }
        connectionTimeout = timeoutWorkItem
        queue.asyncAfter(deadline: .now() + timeout, execute: timeoutWorkItem)

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connectionTimeout?.cancel()
                update(.connected)

                guard let payloads else {
                    self.markConnectionTestSucceeded()
                    finish(.success(()))
                    return
                }

                update(.printing)
                self.sendPayloads(payloads, at: 0, connection: connection, finish: finish)

            case .failed(let error):
                finish(.failure(.connectionFailed(error.localizedDescription)))

            case .cancelled:
                break

            case .waiting, .setup, .preparing:
                break

            @unknown default:
                break
            }
        }

        connection.start(queue: queue)
    }

    private func performPhotoPrint(
        host: String,
        port: UInt16,
        heading: Data,
        rasterCommand: Data,
        finishing: Data,
        imageWidth: Int,
        imageHeight: Int,
        rasterDataByteCount: Int,
        sanitizationReport: RasterSanitizationReport,
        yL: UInt8,
        yH: UInt8,
        timeout: TimeInterval,
        onStateChange: @escaping StateHandler,
        completion: @escaping CompletionHandler
    ) {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedHost.isEmpty else {
            complete(.failure(.invalidHost), onStateChange: onStateChange, completion: completion)
            return
        }

        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            complete(.failure(.invalidPort), onStateChange: onStateChange, completion: completion)
            return
        }

        let jobGate = beginJob(isConnectionTest: false, isRasterPrint: true)

        guard case .allowed = jobGate else {
            complete(.failure(jobGate.error), onStateChange: onStateChange, completion: completion)
            return
        }

        let jobID = UUID().uuidString
        let queue = DispatchQueue(label: "com.pocketpixels.printer-photo-network")
        let connection = NWConnection(host: NWEndpoint.Host(trimmedHost), port: endpointPort, using: .tcp)
        var didFinish = false
        var rasterTransmissionBegan = false
        var timeoutWorkItem: DispatchWorkItem?
        storeActiveConnection(connection)

        debugLog("Photo print job \(jobID) started. Dimensions: \(imageWidth)x\(imageHeight). Original raster bytes: \(sanitizationReport.originalByteCount). Sanitized raster bytes: \(sanitizationReport.sanitizedByteCount). DLE EOT neutralized: \(sanitizationReport.dleEOTPatternCount). DLE DC4 neutralized: \(sanitizationReport.dleDC4PatternCount). Final safety scan passed: \(sanitizationReport.finalSafetyScanPassed). Raster data bytes sent: \(rasterDataByteCount). Raster command bytes: \(rasterCommand.count). yL: \(yL). yH: \(yH).")

        func update(_ state: PrinterConnectionState) {
            DispatchQueue.main.async {
                onStateChange(state)
            }
        }

        func cleanup(result: Result<Void, PrinterNetworkError>) {
            guard !didFinish else {
                return
            }

            didFinish = true
            timeoutWorkItem?.cancel()
            connection.stateUpdateHandler = nil
            connection.cancel()

            let shouldActivateRecovery = result.isFailure && rasterTransmissionBegan

            if shouldActivateRecovery {
                self.activateRecoveryLockout()
                debugLog("Photo print job \(jobID) activated recovery lockout after raster transmission began.")
            } else {
                debugLog("Photo print job \(jobID) did not activate recovery lockout. Raster transmission began: \(rasterTransmissionBegan).")
            }

            debugLog("Photo print job \(jobID) cleanup complete.")
            update(.coolingDown)

            queue.asyncAfter(deadline: .now() + 2) {
                self.clearActiveJob()
                debugLog("Photo print job \(jobID) cooldown complete.")

                DispatchQueue.main.async {
                    switch result {
                    case .success:
                        onStateChange(.success("Photo raster test sent. Raw TCP confirms data delivery to the socket, not that paper physically finished printing."))
                    case .failure(let error):
                        if shouldActivateRecovery {
                            onStateChange(.recoveryRequired(PrinterNetworkError.printerRecoveryRequired.userMessage))
                        } else {
                            onStateChange(.failure(error.userMessage))
                        }
                    }

                    completion(result)
                }
            }
        }

        func finish(_ result: Result<Void, PrinterNetworkError>) {
            queue.async {
                cleanup(result: result)
            }
        }

        let timeoutItem = DispatchWorkItem {
            debugLog("Photo print job \(jobID) timed out. Raster transmission began: \(rasterTransmissionBegan).")
            cleanup(result: .failure(.timedOut(host: trimmedHost, port: port)))
        }
        timeoutWorkItem = timeoutItem
        queue.asyncAfter(deadline: .now() + timeout, execute: timeoutItem)

        update(.connecting)

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                update(.connected)
                update(.sendingHeading)
                self.sendPhotoHeading(
                    heading,
                    rasterCommand: rasterCommand,
                    finishing: finishing,
                    connection: connection,
                    queue: queue,
                    jobID: jobID,
                    update: update,
                    onRasterBegan: {
                        rasterTransmissionBegan = true
                        debugLog("Photo print job \(jobID) raster transmission began.")
                    },
                    finish: finish
                )

            case .failed(let error):
                finish(.failure(.connectionFailed(error.localizedDescription)))

            case .cancelled:
                break

            case .waiting, .setup, .preparing:
                break

            @unknown default:
                break
            }
        }

        connection.start(queue: queue)
    }

    private func sendPhotoHeading(
        _ heading: Data,
        rasterCommand: Data,
        finishing: Data,
        connection: NWConnection,
        queue: DispatchQueue,
        jobID: String,
        update: @escaping StateHandler,
        onRasterBegan: @escaping () -> Void,
        finish: @escaping (Result<Void, PrinterNetworkError>) -> Void
    ) {
        connection.send(content: heading, completion: .contentProcessed { error in
            if let error {
                finish(.failure(.sendFailed(error.localizedDescription)))
                return
            }

            debugLog("Photo print job \(jobID) heading send complete.")
            queue.asyncAfter(deadline: .now() + 0.15) {
                self.sendPhotoRaster(
                    rasterCommand,
                    finishing: finishing,
                    connection: connection,
                    queue: queue,
                    jobID: jobID,
                    update: update,
                    onRasterBegan: onRasterBegan,
                    finish: finish
                )
            }
        })
    }

    private func sendPhotoRaster(
        _ rasterCommand: Data,
        finishing: Data,
        connection: NWConnection,
        queue: DispatchQueue,
        jobID: String,
        update: @escaping StateHandler,
        onRasterBegan: @escaping () -> Void,
        finish: @escaping (Result<Void, PrinterNetworkError>) -> Void
    ) {
        update(.sendingPhotograph)
        onRasterBegan()

        connection.send(content: rasterCommand, completion: .contentProcessed { error in
            if let error {
                finish(.failure(.sendFailed(error.localizedDescription)))
                return
            }

            debugLog("Photo print job \(jobID) raster send complete.")
            update(.finalizingAndCutting)
            self.sendPhotoFinishing(
                finishing,
                connection: connection,
                queue: queue,
                jobID: jobID,
                update: update,
                finish: finish
            )
        })
    }

    private func sendPhotoFinishing(
        _ finishing: Data,
        connection: NWConnection,
        queue: DispatchQueue,
        jobID: String,
        update: @escaping StateHandler,
        finish: @escaping (Result<Void, PrinterNetworkError>) -> Void
    ) {
        connection.send(content: finishing, completion: .contentProcessed { error in
            if let error {
                finish(.failure(.sendFailed(error.localizedDescription)))
                return
            }

            debugLog("Photo print job \(jobID) cut send complete. Holding connection open for 1500 ms.")
            // Raw TCP only confirms that bytes reached the socket stack. It does not confirm the printer has physically printed or cut the paper.
            update(.printerProcessing)
            queue.asyncAfter(deadline: .now() + 1.5) {
                finish(.success(()))
            }
        })
    }

    private func sendPayloads(
        _ payloads: [Data],
        at index: Int,
        connection: NWConnection,
        finish: @escaping (Result<Void, PrinterNetworkError>) -> Void
    ) {
        guard index < payloads.count else {
            finish(.success(()))
            return
        }

        connection.send(content: payloads[index], completion: .contentProcessed { error in
            if let error {
                finish(.failure(.sendFailed(error.localizedDescription)))
                return
            }

            self.sendPayloads(payloads, at: index + 1, connection: connection, finish: finish)
        })
    }

    private func complete(
        _ result: Result<Void, PrinterNetworkError>,
        onStateChange: @escaping StateHandler,
        completion: @escaping CompletionHandler
    ) {
        DispatchQueue.main.async {
            if case .failure(let error) = result {
                onStateChange(.failure(error.userMessage))
            }

            completion(result)
        }
    }

    private func beginJob(isConnectionTest: Bool, isRasterPrint: Bool) -> JobStartResult {
        stateQueue.sync {
            guard !isJobActive else {
                return .rejected(.jobAlreadyActive)
            }

            guard !isRecoveryLockoutActive else {
                return .rejected(.printerRecoveryRequired)
            }

            if isRasterPrint, requiresConnectionTestBeforeRasterPrint {
                return .rejected(.connectionTestRequired)
            }

            isJobActive = true
            return .allowed
        }
    }

    private func markConnectionTestSucceeded() {
        stateQueue.sync {
            requiresConnectionTestBeforeRasterPrint = false
        }
    }

    private func activateRecoveryLockout() {
        stateQueue.sync {
            isRecoveryLockoutActive = true
            requiresConnectionTestBeforeRasterPrint = true
        }
    }

    private func storeActiveConnection(_ connection: NWConnection) {
        stateQueue.sync {
            activeConnection = connection
        }
    }

    private func clearActiveJob() {
        stateQueue.sync {
            activeConnection = nil
            isJobActive = false
        }
    }
}

private extension Result {
    var isFailure: Bool {
        if case .failure = self {
            return true
        }

        return false
    }
}

private func debugLog(_ message: String) {
#if DEBUG
    print("[PrinterNetworkService] \(message)")
#endif
}
