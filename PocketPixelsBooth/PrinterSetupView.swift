//
//  PrinterSetupView.swift
//  PocketPixelsBooth
//

import SwiftUI

struct PrinterSetupView: View {
    @StateObject private var printerCoordinator = PrinterCoordinator.shared
    @StateObject private var bluetoothService = PrinterBluetoothService.shared
    @AppStorage("printerIP") private var printerIP = BoothConfiguration.defaultPrinterIP
    @AppStorage("printerPort") private var printerPort = BoothConfiguration.defaultPrinterPort
    @State private var wifiState = PrinterConnectionState.disconnected

    private let wifiService = PrinterNetworkService()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Printer Setup")
                .font(.title2)
                .fontWeight(.semibold)

            modeSection
            bluetoothSection
            wifiSection
            activeTransportSection
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onAppear {
            printerCoordinator.prepare()
        }
    }

    private var modeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Connection Mode")
                .font(.headline)

            Picker(
                "Connection Mode",
                selection: Binding(
                    get: { printerCoordinator.preferredMode },
                    set: { printerCoordinator.preferredMode = $0 }
                )
            ) {
                Text("Auto").tag(PrinterConnectionMode.auto)
                Text("Bluetooth").tag(PrinterConnectionMode.bluetooth)
                Text("Wi-Fi").tag(PrinterConnectionMode.wifi)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 420)
        }
    }

    private var bluetoothSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Bluetooth Printer")
                .font(.headline)

            Label(bluetoothStatusText, systemImage: bluetoothService.isConnectedAndReady ? "checkmark.circle.fill" : "printer")
                .foregroundStyle(bluetoothService.isConnectedAndReady ? .green : .secondary)

            HStack(spacing: 12) {
                Button {
                    printerCoordinator.reconnectBluetoothPrinter()
                } label: {
                    Label("Reconnect Printer", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .disabled(bluetoothService.jobState.isWorking)

                Button {
                    bluetoothService.startScan()
                } label: {
                    Label(bluetoothService.hasSavedPrinter ? "Connect Another Bluetooth Printer" : "Connect Bluetooth Printer", systemImage: "dot.radiowaves.left.and.right")
                }
                .buttonStyle(.bordered)
                .disabled(!bluetoothService.canScan)

                Button("Forget Printer", role: .destructive) {
                    printerCoordinator.forgetBluetoothPrinter()
                }
                .buttonStyle(.bordered)
                .disabled(!bluetoothService.hasSavedPrinter && !bluetoothService.isConnectedAndReady)
            }

            if !bluetoothService.candidates.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(bluetoothService.candidates) { candidate in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(candidate.name)
                                    .font(.headline)
                                Text("RSSI \(candidate.rssi)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            if candidate.isLikelyPrinter {
                                Text("Likely VOZY")
                                    .font(.caption)
                                    .foregroundStyle(.green)
                            }

                            Spacer()

                            Button("Connect") {
                                bluetoothService.connect(to: candidate.id)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(!bluetoothService.canConnect)
                        }
                        .padding(10)
                        .background(Color(.tertiarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
    }

    private var wifiSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Wi-Fi Backup")
                .font(.headline)

            HStack(spacing: 12) {
                TextField("Printer IP", text: $printerIP)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.decimalPad)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 210)

                TextField("Port", text: $printerPort)
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)

                Button("Test Wi-Fi") {
                    testWiFi()
                }
                .buttonStyle(.bordered)
                .disabled(wifiState.isWorking)
            }

            Text(wifiState.message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var activeTransportSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Active Transport")
                .font(.headline)

            Text(printerCoordinator.activeTransport.displayName)
                .font(.body.monospacedDigit())

            if let fallbackReason = printerCoordinator.fallbackReason {
                Text(fallbackReason)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var bluetoothStatusText: String {
        if bluetoothService.isConnectedAndReady {
            return "\(printerCoordinator.bluetoothPrinterName) connected"
        }

        if bluetoothService.hasSavedPrinter {
            return "\(printerCoordinator.bluetoothPrinterName) saved"
        }

        return "No Bluetooth printer saved"
    }

    private var parsedPort: UInt16? {
        UInt16(printerPort.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func testWiFi() {
        guard let parsedPort else {
            wifiState = .failure("Enter a valid TCP port from 1 to 65535.")
            return
        }

        wifiService.testConnection(host: printerIP, port: parsedPort) { state in
            wifiState = state
        } completion: { _ in }
    }
}
