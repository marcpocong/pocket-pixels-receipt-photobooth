//
//  PrinterBluetoothDiagnosticView.swift
//  PocketPixelsBooth
//

#if DEBUG
import SwiftUI

struct PrinterBluetoothDiagnosticView: View {
    @StateObject private var diagnosticService = PrinterBluetoothDiagnosticService()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Divider()

            Text("Bluetooth Diagnostic")
                .font(.title2)
                .fontWeight(.semibold)

            bluetoothStateView
            scanControls
            nearbyDevicesView
            connectedDeviceView
            externalAccessoryView
            diagnosticLogView
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onDisappear {
            diagnosticService.cleanup()
        }
    }

    private var bluetoothStateView: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent("Bluetooth", value: diagnosticService.bluetoothState)

            Text(diagnosticService.connectionMessage)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var scanControls: some View {
        HStack(spacing: 12) {
            Button {
                diagnosticService.startScan()
            } label: {
                Label("Scan for Bluetooth Devices", systemImage: "dot.radiowaves.left.and.right")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!diagnosticService.canScan)

            if diagnosticService.isScanning {
                Button("Stop Scan") {
                    diagnosticService.stopScan()
                }
                .buttonStyle(.bordered)
            }

            Button {
                diagnosticService.refreshExternalAccessories()
            } label: {
                Label("Refresh Accessories", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
        }
    }

    private var nearbyDevicesView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Nearby BLE Devices")
                .font(.headline)

            if diagnosticService.discoveredPeripherals.isEmpty {
                Text(diagnosticService.isScanning ? "Scanning..." : "No devices discovered yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(diagnosticService.discoveredPeripherals) { peripheral in
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text(peripheral.displayName)
                                    .font(.headline)

                                if peripheral.isLikelyPrinter {
                                    Text("Likely Printer")
                                        .font(.caption)
                                        .fontWeight(.semibold)
                                        .padding(.vertical, 3)
                                        .padding(.horizontal, 8)
                                        .background(Color.orange.opacity(0.18))
                                        .clipShape(Capsule())
                                }
                            }

                            Text(peripheral.id.uuidString)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)

                            Text("RSSI \(peripheral.rssi)")
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Button("Connect") {
                            diagnosticService.connect(to: peripheral.id)
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(12)
                    .background(Color(.tertiarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    @ViewBuilder
    private var connectedDeviceView: some View {
        if let connectedPeripheralName = diagnosticService.connectedPeripheralName {
            VStack(alignment: .leading, spacing: 14) {
                Divider()

                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Connected Device")
                            .font(.headline)
                        Text(connectedPeripheralName)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button("Disconnect") {
                        diagnosticService.disconnect()
                    }
                    .buttonStyle(.bordered)
                }

                servicesView
                writableTestView
            }
        }
    }

    private var servicesView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Services")
                .font(.headline)

            if diagnosticService.discoveredServices.isEmpty {
                Text("No services discovered yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(diagnosticService.discoveredServices) { service in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(service.uuid)
                            .font(.subheadline.monospaced())
                            .fontWeight(.semibold)

                        if service.characteristics.isEmpty {
                            Text("No characteristics discovered.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(service.characteristics) { characteristic in
                                characteristicRow(characteristic)
                            }
                        }
                    }
                    .padding(12)
                    .background(Color(.tertiarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    private func characteristicRow(_ characteristic: BluetoothDiagnosticCharacteristicInfo) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(characteristic.uuid)
                    .font(.caption.monospaced())

                Text("Properties: \(characteristic.properties.joined(separator: ", "))")
                    .font(.subheadline)
                    .foregroundStyle(characteristic.canWrite || characteristic.canWriteWithoutResponse ? .primary : .secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if characteristic.isKnownVOZYG80DataCharacteristic {
                    Text("Known VOZY G80 diagnostic data channel")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.green)
                }
            }

            Spacer()

            if characteristic.canWrite || characteristic.canWriteWithoutResponse {
                if diagnosticService.selectedCharacteristicID == characteristic.id {
                    Button("Selected") {}
                    .buttonStyle(.borderedProminent)
                    .disabled(true)
                } else {
                    Button("Select") {
                        diagnosticService.selectCharacteristic(characteristic.id)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private var writableTestView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Manual Bluetooth Test")
                .font(.headline)

            Text(diagnosticService.writeStatus)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                diagnosticService.sendBluetoothTest()
            } label: {
                Label("Send Bluetooth Test", systemImage: "paperplane")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!diagnosticService.canSendBluetoothTest)

            Button {
                diagnosticService.sendBluetoothCutTest()
            } label: {
                Label("Test Bluetooth Cut", systemImage: "scissors")
            }
            .buttonStyle(.bordered)
            .disabled(!diagnosticService.canSendCutTest)
        }
    }

    private var externalAccessoryView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()

            Text("ExternalAccessory Read-Only Check")
                .font(.headline)

            if diagnosticService.externalAccessories.isEmpty {
                Text("No connected ExternalAccessory devices are visible to the app.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(diagnosticService.externalAccessories) { accessory in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(accessory.name)
                            .font(.headline)
                        Text("Manufacturer: \(accessory.manufacturer)")
                        Text("Model: \(accessory.modelNumber)")
                        Text("Connected: \(accessory.isConnected ? "Yes" : "No")")
                        Text("Protocols: \(accessory.protocolStrings.isEmpty ? "None advertised" : accessory.protocolStrings.joined(separator: ", "))")
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.subheadline)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.tertiarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    private var diagnosticLogView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()

            Text("Diagnostic Log")
                .font(.headline)

            if diagnosticService.diagnosticLog.isEmpty {
                Text("No Bluetooth diagnostic events yet.")
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(diagnosticService.diagnosticLog.enumerated()), id: \.offset) { _, entry in
                        Text(entry)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.tertiarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}
#endif
