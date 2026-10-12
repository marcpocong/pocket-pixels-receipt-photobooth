//
//  PrinterBluetoothDiagnosticService.swift
//  PocketPixelsBooth
//

#if DEBUG
import CoreBluetooth
import Combine
import ExternalAccessory
import Foundation

struct BluetoothDiscoveredPeripheral: Identifiable, Equatable {
    let id: UUID
    let displayName: String
    let rssi: Int
    let isLikelyPrinter: Bool
}

struct BluetoothDiagnosticServiceInfo: Identifiable, Equatable {
    let id: String
    let uuid: String
    var characteristics: [BluetoothDiagnosticCharacteristicInfo]
}

struct BluetoothDiagnosticCharacteristicInfo: Identifiable, Equatable {
    let id: String
    let serviceUUID: String
    let uuid: String
    let properties: [String]
    let canWrite: Bool
    let canWriteWithoutResponse: Bool
    let isKnownVOZYG80DataCharacteristic: Bool
}

struct BluetoothExternalAccessoryInfo: Identifiable, Equatable {
    let id: String
    let name: String
    let manufacturer: String
    let modelNumber: String
    let isConnected: Bool
    let protocolStrings: [String]
}

enum BluetoothDiagnosticWriteState: Equatable {
    case idle
    case sending(chunkIndex: Int, totalChunks: Int)
    case waitingForResponse(chunkIndex: Int, totalChunks: Int)
    case success(String)
    case failed(String)
    case cancelled(String)

    var message: String {
        switch self {
        case .idle:
            "Select a writable characteristic after connecting."
        case .sending(let chunkIndex, let totalChunks):
            "Sending chunk \(chunkIndex) of \(totalChunks)..."
        case .waitingForResponse(let chunkIndex, let totalChunks):
            "Waiting for response for chunk \(chunkIndex) of \(totalChunks)..."
        case .success(let message), .failed(let message), .cancelled(let message):
            message
        }
    }

    var isActive: Bool {
        switch self {
        case .sending, .waitingForResponse:
            true
        case .idle, .success, .failed, .cancelled:
            false
        }
    }
}

@MainActor
final class PrinterBluetoothDiagnosticService: NSObject, ObservableObject {
    private enum PayloadKind {
        case textTest
        case cutTest
    }

    private static let knownVOZYServiceUUID = "18F0"
    private static let knownVOZYCharacteristicUUID = "2AF1"

    @Published private(set) var bluetoothState = "Unknown"
    @Published private(set) var isScanning = false
    @Published private(set) var discoveredPeripherals: [BluetoothDiscoveredPeripheral] = []
    @Published private(set) var connectedPeripheralName: String?
    @Published private(set) var connectionMessage = "No Bluetooth device connected."
    @Published private(set) var discoveredServices: [BluetoothDiagnosticServiceInfo] = []
    @Published private(set) var selectedCharacteristicID: String?
    @Published private(set) var writeState = BluetoothDiagnosticWriteState.idle
    @Published private(set) var diagnosticLog: [String] = []
    @Published private(set) var externalAccessories: [BluetoothExternalAccessoryInfo] = []

    private let scanDuration: TimeInterval = 10
    private var centralManager: CBCentralManager?
    private var scanStopTask: Task<Void, Never>?
    private var peripheralsByID: [UUID: CBPeripheral] = [:]
    private var connectedPeripheral: CBPeripheral?
    private var characteristicsByID: [String: CBCharacteristic] = [:]
    private var pendingWriteChunks: [Data] = []
    private var pendingPayloadKind: PayloadKind?
    private var pendingWriteCharacteristic: CBCharacteristic?
    private var pendingWriteTotalChunks = 0
    private var lastTextTestCompletedSuccessfully = false

    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
        refreshExternalAccessories()
    }

    var canScan: Bool {
        centralManager?.state == .poweredOn && !isScanning && connectedPeripheral == nil && !writeState.isActive
    }

    var selectedCharacteristic: BluetoothDiagnosticCharacteristicInfo? {
        writableCharacteristics.first { $0.id == selectedCharacteristicID }
    }

    var canSendBluetoothTest: Bool {
        selectedCharacteristic != nil && connectedPeripheral != nil && !writeState.isActive
    }

    var canSendCutTest: Bool {
        canSendBluetoothTest && lastTextTestCompletedSuccessfully
    }

    var writeStatus: String {
        writeState.message
    }

    var writableCharacteristics: [BluetoothDiagnosticCharacteristicInfo] {
        discoveredServices.flatMap(\.characteristics).filter { $0.canWrite || $0.canWriteWithoutResponse }
    }

    func startScan() {
        guard centralManager?.state == .poweredOn else {
            connectionMessage = "Bluetooth must be powered on before scanning."
            return
        }

        guard connectedPeripheral == nil else {
            connectionMessage = "Disconnect before scanning for another Bluetooth device."
            return
        }

        stopScan()
        discoveredPeripherals = []
        peripheralsByID = [:]
        connectionMessage = "Scanning for nearby BLE peripherals..."
        appendLog("Scan started for \(Int(scanDuration)) seconds.")
        isScanning = true

        centralManager?.scanForPeripherals(withServices: nil, options: [
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
        isScanning = false
    }

    func connect(to peripheralID: UUID) {
        guard let peripheral = peripheralsByID[peripheralID] else {
            connectionMessage = "Selected peripheral is no longer available."
            return
        }

        stopScan()
        resetConnectionState(keepMessage: true)
        connectionMessage = "Connecting to \(peripheralDisplayName(peripheral))..."
        connectedPeripheral = peripheral
        peripheral.delegate = self
        centralManager?.connect(peripheral, options: nil)
    }

    func disconnect() {
        stopScan()
        handleOperatorDisconnect()

        if let connectedPeripheral {
            centralManager?.cancelPeripheralConnection(connectedPeripheral)
        }

        clearConnectionAfterDisconnect(keepMessage: false)
        connectionMessage = "Disconnected."
    }

    func selectCharacteristic(_ characteristicID: String) {
        selectedCharacteristicID = characteristicID
        if let characteristic = characteristicsByID[characteristicID] {
            writeState = .idle
            lastTextTestCompletedSuccessfully = false
            appendLog("Selected characteristic \(characteristic.uuid.uuidString) on service \(characteristic.service?.uuid.uuidString ?? "UnknownService").")
        }
    }

    func sendBluetoothTest() {
        let payload = bluetoothTextTestPayload()
        startWrite(payload: payload, payloadKind: .textTest, label: "Bluetooth Test")
    }

    func sendBluetoothCutTest() {
        guard lastTextTestCompletedSuccessfully else {
            writeState = .failed("Run a successful Bluetooth text test before testing the cutter.")
            return
        }

        let payload = Data([0x0A, 0x0A, 0x0A, 0x1D, 0x56, 0x01])
        startWrite(payload: payload, payloadKind: .cutTest, label: "Bluetooth Cut Test")
    }

    func refreshExternalAccessories() {
        externalAccessories = EAAccessoryManager.shared().connectedAccessories.map { accessory in
            BluetoothExternalAccessoryInfo(
                id: "\(accessory.name)-\(accessory.modelNumber)-\(accessory.serialNumber)",
                name: accessory.name,
                manufacturer: accessory.manufacturer,
                modelNumber: accessory.modelNumber,
                isConnected: accessory.isConnected,
                protocolStrings: accessory.protocolStrings
            )
        }
    }

    func cleanup() {
        stopScan()
        disconnect()
    }

    private func startWrite(payload: Data, payloadKind: PayloadKind, label: String) {
        guard let peripheral = connectedPeripheral,
              let selectedCharacteristicID,
              let characteristic = characteristicsByID[selectedCharacteristicID] else {
            writeState = .failed("Connect and select a writable characteristic first.")
            return
        }

        guard !writeState.isActive else {
            writeState = .failed("Wait for the current Bluetooth write to finish.")
            return
        }

        guard characteristic.properties.contains(.write) else {
            writeState = .failed("BT1.1 requires response-based writes. Select a characteristic with the write property.")
            return
        }

        let maximumLength = max(1, min(20, peripheral.maximumWriteValueLength(for: .withResponse)))
        pendingWriteChunks = payload.chunked(maximumLength: maximumLength)
        pendingPayloadKind = payloadKind
        pendingWriteCharacteristic = characteristic
        pendingWriteTotalChunks = pendingWriteChunks.count
        if payloadKind == .textTest {
            lastTextTestCompletedSuccessfully = false
        }

        appendLog("Starting \(label).")
        appendLog("Peripheral: \(peripheralDisplayName(peripheral))")
        appendLog("Service: \(characteristic.service?.uuid.uuidString ?? "UnknownService")")
        appendLog("Characteristic: \(characteristic.uuid.uuidString)")
        appendLog("Write type: withResponse")
        appendLog("maximumWriteValueLength(.withResponse): \(peripheral.maximumWriteValueLength(for: .withResponse))")
        appendLog("Conservative chunk size: \(maximumLength)")
        appendLog("Payload bytes: \(payload.count)")
        appendLog("Chunk count: \(pendingWriteChunks.count)")

        writeNextChunk()
    }

    private func bluetoothTextTestPayload() -> Data {
        var payload = Data([0x1B, 0x40])
        payload.append(Data("MADE TO KEEP".utf8))
        payload.append(0x0A)
        payload.append(Data("BLUETOOTH TEST".utf8))
        payload.append(contentsOf: [0x0A, 0x0A, 0x0A])
        return payload
    }

    private func finishTimedScan() {
        centralManager?.stopScan()
        isScanning = false
        connectionMessage = discoveredPeripherals.isEmpty
            ? "Scan finished. No BLE peripherals were discovered."
            : "Scan finished. Select a candidate to inspect services."
    }

    private func resetConnectionState(keepMessage: Bool) {
        connectedPeripheral?.delegate = nil
        connectedPeripheral = nil
        connectedPeripheralName = nil
        discoveredServices = []
        characteristicsByID = [:]
        selectedCharacteristicID = nil
        pendingWriteChunks = []
        pendingPayloadKind = nil
        pendingWriteCharacteristic = nil
        pendingWriteTotalChunks = 0
        lastTextTestCompletedSuccessfully = false
        writeState = .idle

        if !keepMessage {
            connectionMessage = "No Bluetooth device connected."
        }
    }

    private func peripheralDisplayName(_ peripheral: CBPeripheral, advertisedName: String? = nil) -> String {
        let name = advertisedName ?? peripheral.name
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedName?.isEmpty == false ? trimmedName! : "Unnamed BLE Device"
    }

    private func isLikelyPrinterName(_ name: String) -> Bool {
        let lowercasedName = name.lowercased()
        return ["vozy", "g80", "printer", "pos"].contains { lowercasedName.contains($0) }
    }

    private func characteristicID(for characteristic: CBCharacteristic, service: CBService?) -> String {
        "\(service?.uuid.uuidString ?? "UnknownService")/\(characteristic.uuid.uuidString)"
    }

    private func rebuildDiscoveredServices(for peripheral: CBPeripheral) {
        discoveredServices = (peripheral.services ?? []).map { service in
            BluetoothDiagnosticServiceInfo(
                id: service.uuid.uuidString,
                uuid: service.uuid.uuidString,
                characteristics: (service.characteristics ?? []).map { characteristic in
                    let id = characteristicID(for: characteristic, service: service)
                    characteristicsByID[id] = characteristic

                    return BluetoothDiagnosticCharacteristicInfo(
                        id: id,
                        serviceUUID: service.uuid.uuidString,
                        uuid: characteristic.uuid.uuidString,
                        properties: characteristic.propertyLabels,
                        canWrite: characteristic.properties.contains(.write),
                        canWriteWithoutResponse: characteristic.properties.contains(.writeWithoutResponse),
                        isKnownVOZYG80DataCharacteristic: service.uuid.uuidString.uppercased() == Self.knownVOZYServiceUUID
                            && characteristic.uuid.uuidString.uppercased() == Self.knownVOZYCharacteristicUUID
                    )
                }
            )
        }

        if selectedCharacteristicID == nil,
           let knownCharacteristic = writableCharacteristics.first(where: { $0.isKnownVOZYG80DataCharacteristic }) {
            selectCharacteristic(knownCharacteristic.id)
            appendLog("Known VOZY G80 diagnostic characteristic highlighted: 18F0 / 2AF1.")
        }
    }

    private func writeNextChunk() {
        guard let peripheral = connectedPeripheral,
              let characteristic = pendingWriteCharacteristic else {
            cancelActiveWrite("Write cancelled because the Bluetooth peripheral or characteristic reference was cleared.")
            return
        }

        guard peripheral.state == .connected else {
            cancelActiveWrite("Write cancelled because the peripheral state is \(peripheral.state.displayName).")
            return
        }

        guard characteristic.properties.contains(.write) else {
            cancelActiveWrite("Write cancelled because the selected characteristic no longer supports response-based writes.")
            return
        }

        guard pendingPayloadKind != nil else {
            cancelActiveWrite("Write cancelled because no active payload is registered.")
            return
        }

        guard !pendingWriteChunks.isEmpty else {
            completeActiveWrite()
            return
        }

        let chunkIndex = pendingWriteTotalChunks - pendingWriteChunks.count + 1
        let totalChunks = pendingWriteTotalChunks
        writeState = .sending(chunkIndex: chunkIndex, totalChunks: totalChunks)

        let chunk = pendingWriteChunks.removeFirst()
        appendLog("Writing chunk \(chunkIndex)/\(totalChunks), \(chunk.count) bytes.")
        peripheral.writeValue(chunk, for: characteristic, type: .withResponse)
        writeState = .waitingForResponse(chunkIndex: chunkIndex, totalChunks: totalChunks)
    }

    private func completeActiveWrite() {
        let completedKind = pendingPayloadKind
        pendingPayloadKind = nil
        pendingWriteCharacteristic = nil
        pendingWriteTotalChunks = 0

        switch completedKind {
        case .textTest:
            lastTextTestCompletedSuccessfully = true
            writeState = .success("Bluetooth Test sent and acknowledged. Confirm the complete text printed.")
            appendLog("Text test completed successfully.")
        case .cutTest:
            writeState = .success("Bluetooth Cut Test sent and acknowledged. Confirm the printer fed and partially cut.")
            appendLog("Cut test completed successfully.")
        case nil:
            writeState = .success("Bluetooth write completed.")
            appendLog("Write completed with no payload kind.")
        }
    }

    private func failActiveWrite(_ message: String) {
        pendingWriteChunks = []
        pendingPayloadKind = nil
        pendingWriteCharacteristic = nil
        pendingWriteTotalChunks = 0
        writeState = .failed(message)
        appendLog(message)
    }

    private func cancelActiveWrite(_ reason: String) {
        pendingWriteChunks = []
        pendingPayloadKind = nil
        pendingWriteCharacteristic = nil
        pendingWriteTotalChunks = 0
        lastTextTestCompletedSuccessfully = false
        writeState = .cancelled(reason)
        appendLog(reason)
    }

    private func appendLog(_ message: String) {
        diagnosticLog.append(message)

        if diagnosticLog.count > 80 {
            diagnosticLog.removeFirst(diagnosticLog.count - 80)
        }
    }

    private func handleUnexpectedDisconnect(error: Error?) {
        let detail = error?.localizedDescription ?? "No CoreBluetooth error was provided."
        let reason = "Peripheral disconnected. \(detail)"

        if writeState.isActive {
            cancelActiveWrite(reason)
        } else {
            appendLog(reason)
        }
    }

    private func handleOperatorDisconnect() {
        if writeState.isActive {
            cancelActiveWrite("Write cancelled by operator disconnect.")
        }
    }

    private func clearConnectionAfterDisconnect(keepMessage: Bool) {
        connectedPeripheral?.delegate = nil
        connectedPeripheral = nil
        connectedPeripheralName = nil
        discoveredServices = []
        characteristicsByID = [:]
        selectedCharacteristicID = nil

        if !keepMessage {
            connectionMessage = "No Bluetooth device connected."
        }
    }
}

extension PrinterBluetoothDiagnosticService: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        // Delivered on the main queue (the manager uses queue: nil); assumeIsolated
        // checks that and keeps every Bluetooth state access serialized on the main actor.
        MainActor.assumeIsolated {
            bluetoothState = central.state.displayName

            if central.state != .poweredOn {
                stopScan()
                if writeState.isActive {
                    cancelActiveWrite("Write cancelled because Bluetooth state changed to \(central.state.displayName).")
                }
                clearConnectionAfterDisconnect(keepMessage: true)
                connectionMessage = "Bluetooth is \(central.state.displayName.lowercased()). Wi-Fi printing is unaffected."
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
            let displayName = peripheralDisplayName(peripheral, advertisedName: advertisedName)

            peripheralsByID[peripheral.identifier] = peripheral

            let discovered = BluetoothDiscoveredPeripheral(
                id: peripheral.identifier,
                displayName: displayName,
                rssi: RSSI.intValue,
                isLikelyPrinter: isLikelyPrinterName(displayName)
            )

            if let existingIndex = discoveredPeripherals.firstIndex(where: { $0.id == discovered.id }) {
                discoveredPeripherals[existingIndex] = discovered
            } else {
                discoveredPeripherals.append(discovered)
            }

            discoveredPeripherals.sort {
                if $0.isLikelyPrinter != $1.isLikelyPrinter {
                    return $0.isLikelyPrinter && !$1.isLikelyPrinter
                }

                return $0.rssi > $1.rssi
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
            connectedPeripheralName = peripheralDisplayName(peripheral)
            connectionMessage = "Connected. Discovering services..."
            appendLog("Connected to \(peripheralDisplayName(peripheral)).")
            peripheral.discoverServices(nil)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        // Delivered on the main queue (the manager uses queue: nil); assumeIsolated
        // checks that and keeps every Bluetooth state access serialized on the main actor.
        MainActor.assumeIsolated {
            guard connectedPeripheral?.identifier == peripheral.identifier else {
                return
            }

            resetConnectionState(keepMessage: true)
            connectionMessage = "Connection failed. \(error?.localizedDescription ?? "No details available.")"
            appendLog(connectionMessage)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        // Delivered on the main queue (the manager uses queue: nil); assumeIsolated
        // checks that and keeps every Bluetooth state access serialized on the main actor.
        MainActor.assumeIsolated {
            guard connectedPeripheral?.identifier == peripheral.identifier else {
                return
            }

            handleUnexpectedDisconnect(error: error)
            clearConnectionAfterDisconnect(keepMessage: true)
            connectionMessage = error == nil
                ? "Peripheral disconnected without a CoreBluetooth error."
                : "Disconnected. \(error?.localizedDescription ?? "No details available.")"
        }
    }
}

extension PrinterBluetoothDiagnosticService: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        // Delivered on the main queue (the manager uses queue: nil); assumeIsolated
        // checks that and keeps every Bluetooth state access serialized on the main actor.
        MainActor.assumeIsolated {
            guard connectedPeripheral?.identifier == peripheral.identifier else {
                return
            }

            if let error {
                connectionMessage = "Service discovery failed. \(error.localizedDescription)"
                return
            }

            let services = peripheral.services ?? []
            discoveredServices = services.map {
                BluetoothDiagnosticServiceInfo(id: $0.uuid.uuidString, uuid: $0.uuid.uuidString, characteristics: [])
            }
            appendLog("Discovered \(services.count) service(s).")
            connectionMessage = services.isEmpty
                ? "Connected, but no services were exposed."
                : "Discovered \(services.count) service(s). Discovering characteristics..."

            for service in services {
                peripheral.discoverCharacteristics(nil, for: service)
            }
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
                connectionMessage = "Characteristic discovery failed for \(service.uuid.uuidString). \(error.localizedDescription)"
                appendLog(connectionMessage)
                return
            }

            rebuildDiscoveredServices(for: peripheral)

            let writableCount = writableCharacteristics.count
            appendLog("Service \(service.uuid.uuidString) characteristics discovered. Writable count: \(writableCount).")
            connectionMessage = writableCount == 0
                ? "Services discovered. No writable characteristics found yet."
                : "Services discovered. \(writableCount) writable characteristic(s) available for manual selection."
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        // Delivered on the main queue (the manager uses queue: nil); assumeIsolated
        // checks that and keeps every Bluetooth state access serialized on the main actor.
        MainActor.assumeIsolated {
            guard connectedPeripheral?.identifier == peripheral.identifier else {
                return
            }

            if let error {
                failActiveWrite("Bluetooth write failed for \(characteristic.uuid.uuidString). \(error.localizedDescription)")
                return
            }

            appendLog("didWrite success for \(characteristic.uuid.uuidString).")
            writeNextChunk()
        }
    }

    nonisolated func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        // Delivered on the main queue (the manager uses queue: nil); assumeIsolated
        // checks that and keeps every Bluetooth state access serialized on the main actor.
        MainActor.assumeIsolated {
            guard connectedPeripheral?.identifier == peripheral.identifier else {
                return
            }

            appendLog("Peripheral reported writeWithoutResponse capacity; BT1.1 text/cut tests use withResponse.")
        }
    }
}

private extension CBPeripheralState {
    var displayName: String {
        switch self {
        case .disconnected:
            "disconnected"
        case .connecting:
            "connecting"
        case .connected:
            "connected"
        case .disconnecting:
            "disconnecting"
        @unknown default:
            "unknown"
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
