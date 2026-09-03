//
//  PrinterTestView.swift
//  PocketPixelsBooth
//
//  Created by marc on 8/30/26.
//

import PhotosUI
import SwiftUI
import UIKit

struct PrinterTestView: View {
    @AppStorage("printerIP") private var printerIP = BoothConfiguration.defaultPrinterIP
    @AppStorage("printerPort") private var printerPort = BoothConfiguration.defaultPrinterPort
    @State private var connectionState = PrinterConnectionState.disconnected
    @State private var photoStatusMessage = "Select one photo to create a 576-dot thermal preview."
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var originalImage: UIImage?
    @State private var previewImage: UIImage?
    @State private var rasterizedImage: ThermalRasterizedImage?
    @State private var isProcessingPhoto = false
    @State private var discoveryState = PrinterDiscoveryState.idle
    @State private var discoveryTask: Task<Void, Never>?
#if DEBUG
    @StateObject private var bluetoothPrinterService = PrinterBluetoothService()
    @State private var bluetoothRasterMode = BluetoothPrinterRasterMode.reliable
    @State private var balancedBluetoothProfile = BalancedBluetoothPrinterProfile.medium
    @State private var thermalPhotoCalibrationProfile = ThermalPhotoCalibrationProfile.original
    @State private var bluetoothReceiptFormat = BoothFormat.solo
    @State private var calibratedBluetoothPreviewImage: UIImage?
    @State private var calibratedBluetoothRasterizedImage: ThermalRasterizedImage?
    @State private var isProcessingBluetoothCalibration = false
#endif

    private let printerService = PrinterNetworkService()
    private let discoveryService = PrinterDiscoveryService()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    header
                    wifiPrinterTitle
                    printerFields
                    actionButtons
                    discoveryStatusView
                    statusView
#if DEBUG
                    PrinterBluetoothDiagnosticView()
#endif
                    photoSection
#if DEBUG
                    bluetoothRasterTestSection
#endif
                }
                .padding(40)
                .frame(maxWidth: 1_080, alignment: .topLeading)
            }
            .navigationTitle("Pocket Pixels Printer Test")
            .onChange(of: selectedPhotoItem) { _, newItem in
                loadPhoto(from: newItem)
            }
#if DEBUG
            .onChange(of: thermalPhotoCalibrationProfile) { _, _ in
                updateBluetoothCalibratedPreview()
            }
#endif
            .onDisappear {
                cancelPrinterDiscovery()
#if DEBUG
                bluetoothPrinterService.disconnect()
#endif
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Pocket Pixels Printer Test")
                .font(.largeTitle)
                .fontWeight(.semibold)

            Text("VOZY G80 Wi-Fi ESC/POS connection with Bluetooth compatibility diagnostics")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }

    private var wifiPrinterTitle: some View {
        Text("Wi-Fi Printer")
            .font(.title2)
            .fontWeight(.semibold)
    }

    private var printerFields: some View {
        Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 16) {
            GridRow {
                Text("Printer IP")
                    .foregroundStyle(.secondary)
                    .frame(width: 120, alignment: .leading)

                TextField("Printer IP", text: $printerIP)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.decimalPad)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 320)
            }

            GridRow {
                Text("Port")
                    .foregroundStyle(.secondary)
                    .frame(width: 120, alignment: .leading)

                TextField("Port", text: $printerPort)
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 160)
            }
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 16) {
            Button {
                findPrinter()
            } label: {
                Label("Find Printer", systemImage: "magnifyingglass")
            }
            .buttonStyle(.bordered)
            .disabled(isAnyPrinterBusy || connectionState.requiresPrinterRestart)

            if discoveryState.isSearching {
                Button("Cancel Search") {
                    cancelPrinterDiscovery()
                }
                .buttonStyle(.bordered)
            }

            Button("Test Connection") {
                testConnection()
            }
            .buttonStyle(.borderedProminent)
            .disabled(isAnyPrinterBusy)

            Button("Print Test Receipt") {
                printTestReceipt()
            }
            .buttonStyle(.bordered)
            .disabled(isAnyPrinterBusy || connectionState.requiresPrinterRestart)
        }
    }

    private var discoveryStatusView: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch discoveryState {
            case .idle:
                discoveryMessage("Ready to find a printer on the current network.", systemImage: "network", color: .secondary)
            case .checkingSavedPrinter:
                discoveryProgress("Checking saved printer...")
            case .determiningNetwork:
                discoveryProgress("Determining current local network...")
            case .scanning(let completed, let total, let network):
                VStack(alignment: .leading, spacing: 8) {
                    discoveryProgress("Searching local network... \(completed) / \(total)")
                    Text("iPad network: \(network.address) via \(network.interfaceName)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            case .found(let candidates):
                VStack(alignment: .leading, spacing: 12) {
                    discoveryMessage(discoveryFoundTitle(for: candidates), systemImage: "checkmark.circle.fill", color: .green)

                    ForEach(candidates) { candidate in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("\(candidate.host):\(candidate.port)")
                                    .font(.headline.monospacedDigit())
                                if candidate.isSavedPrinter {
                                    Text("Saved printer found")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                            }

                            Spacer()

                            Button("Test") {
                                testCandidate(candidate)
                            }
                            .buttonStyle(.bordered)
                            .disabled(isAnyPrinterBusy)

                            Button("Use") {
                                useCandidate(candidate)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .padding(12)
                        .background(Color(.tertiarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            case .notFound(let message):
                discoveryMessage(message, systemImage: "exclamationmark.magnifyingglass", color: .orange)
            case .failed(let message):
                discoveryMessage(message, systemImage: "exclamationmark.triangle.fill", color: .red)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func discoveryProgress(_ message: String) -> some View {
        HStack(spacing: 12) {
            ProgressView()
            Text(message)
                .font(.headline)
        }
    }

    private func discoveryMessage(_ message: String, systemImage: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(color)
                .frame(width: 24)

            Text(message)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var photoSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            Divider()

            HStack(alignment: .center, spacing: 16) {
                PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                    Label("Select Photo", systemImage: "photo")
                }
                .buttonStyle(.bordered)
                .disabled(isProcessingPhoto || isAnyPrinterBusy)

                Button("Print Photo Test") {
                    printPhotoTest()
                }
                .buttonStyle(.borderedProminent)
                .disabled(rasterizedImage == nil || isProcessingPhoto || isAnyPrinterBusy || connectionState.requiresPrinterRestart)
            }

            Text(photoStatusMessage)
                .foregroundStyle(isProcessingPhoto ? .primary : .secondary)
                .fixedSize(horizontal: false, vertical: true)

            if isProcessingPhoto {
                ProgressView("Processing photo...")
            }

            imagePreviewGrid
        }
    }

#if DEBUG
    private var bluetoothRasterTestSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Bluetooth Raster Test")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("DEBUG validation path for VOZY G80 service 18F0 / characteristic 2AF1.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .top, spacing: 12) {
                Circle()
                    .fill(bluetoothRasterStatusColor)
                    .frame(width: 14, height: 14)
                    .padding(.top, 4)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Bluetooth: \(bluetoothPrinterService.bluetoothState)")
                        .font(.headline)

                    Text(bluetoothPrinterService.jobState.message)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if bluetoothPrinterService.jobState.requiresRecovery {
                        Text("After raster bytes begin, a failed BLE job can leave the printer in a partial ESC/POS raster state.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        HStack(spacing: 12) {
                            Button("I Restarted Bluetooth Printer") {
                                bluetoothPrinterService.confirmPrinterRestarted()
                            }
                            .buttonStyle(.borderedProminent)

                            Button("Diagnostic Text Test Passed") {
                                bluetoothPrinterService.confirmDiagnosticTextTestSucceeded()
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            bluetoothConnectionControls

            bluetoothModeSelector

            if bluetoothRasterMode == .fast {
                thermalPhotoCalibrationSelector
            }

            if let metrics = bluetoothPrinterService.metrics {
                bluetoothMetricsView(metrics)
            }

            bluetoothRasterActions

            if !bluetoothPrinterService.diagnosticLog.isEmpty {
                DisclosureGroup("Bluetooth Transport Log") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(bluetoothPrinterService.diagnosticLog.enumerated()), id: \.offset) { _, entry in
                            Text(entry)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.top, 8)
                }
            }
        }
    }

    private var bluetoothConnectionControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Button {
                    bluetoothPrinterService.startScan()
                } label: {
                    Label("Scan for VOZY G80", systemImage: "dot.radiowaves.left.and.right")
                }
                .buttonStyle(.bordered)
                .disabled(!bluetoothPrinterService.canScan || connectionState.isWorking || discoveryState.isSearching)

                Button("Stop Scan") {
                    bluetoothPrinterService.stopScan()
                }
                .buttonStyle(.bordered)
                .disabled(!bluetoothPrinterService.isScanning)

                if bluetoothPrinterService.connectedPrinterName != nil {
                    Button("Disconnect") {
                        bluetoothPrinterService.disconnect()
                    }
                    .buttonStyle(.bordered)
                    .disabled(bluetoothPrinterService.jobState.isWorking)
                }
            }

            if let connectedPrinterName = bluetoothPrinterService.connectedPrinterName {
                Label("Connected to \(connectedPrinterName)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }

            if !bluetoothPrinterService.candidates.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("VOZY 18F0 Candidates")
                        .font(.headline)

                    ForEach(bluetoothPrinterService.candidates) { candidate in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(candidate.name)
                                    .font(.headline)

                                Text("\(candidate.id.uuidString) · RSSI \(candidate.rssi)")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }

                            if candidate.isLikelyPrinter {
                                Text("Likely printer")
                                    .font(.caption)
                                    .foregroundStyle(.green)
                            }

                            Spacer()

                            Button("Connect") {
                                bluetoothPrinterService.connect(to: candidate.id)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(!bluetoothPrinterService.canConnect || connectionState.isWorking || discoveryState.isSearching)
                        }
                        .padding(12)
                        .background(Color(.tertiarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var bluetoothModeSelector: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Bluetooth Raster Mode")
                .font(.headline)

            Picker("Bluetooth Raster Mode", selection: $bluetoothRasterMode) {
                ForEach(BluetoothPrinterRasterMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 360)
            .disabled(bluetoothPrinterService.jobState.isWorking)

            Text(bluetoothModeDescription)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if bluetoothRasterMode == .balanced {
                Divider()

                Text("Balanced Pacing")
                    .font(.headline)

                Picker("Balanced Pacing", selection: $balancedBluetoothProfile) {
                    ForEach(BalancedBluetoothPrinterProfile.allPresets) { profile in
                        Text(profile.displayName).tag(profile)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 360)
                .disabled(bluetoothPrinterService.jobState.isWorking)

                Text("Chunk \(balancedBluetoothProfile.chunkLimit) bytes, burst \(balancedBluetoothProfile.burstChunkCount) chunks, pause \(balancedBluetoothProfile.interBurstDelayMilliseconds) ms.")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var thermalPhotoCalibrationSelector: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Thermal Photo Calibration")
                .font(.headline)

            Picker("Thermal Photo Calibration", selection: $thermalPhotoCalibrationProfile) {
                ForEach(ThermalPhotoCalibrationProfile.allPresets) { profile in
                    Text(profile.displayName).tag(profile)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 520)
            .disabled(bluetoothPrinterService.jobState.isWorking || isProcessingBluetoothCalibration)

            Text(thermalPhotoCalibrationProfile.parametersDescription)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)

            if isProcessingBluetoothCalibration {
                ProgressView("Updating Bluetooth thermal preview...")
            }

            if let calibratedBluetoothPreviewImage {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Bluetooth Thermal Preview")
                        .font(.headline)

                    Image(uiImage: calibratedBluetoothPreviewImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 480, maxHeight: 420)
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var bluetoothRasterActions: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button {
                printPhotoViaBluetooth()
            } label: {
                Label("Print Photo via Bluetooth", systemImage: "printer")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canPrintPhotoViaBluetooth)

            HStack(spacing: 16) {
                Picker("Receipt Format", selection: $bluetoothReceiptFormat) {
                    ForEach(BoothFormat.allCases) { format in
                        Text(format.displayName).tag(format)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 420)

                Button {
                    printReceiptViaBluetooth()
                } label: {
                    Label("Print Receipt via Bluetooth", systemImage: "doc.text.image")
                }
                .buttonStyle(.bordered)
                .disabled(originalImage == nil || !bluetoothPrinterService.canPrintRaster || connectionState.isWorking || discoveryState.isSearching)
            }

            if bluetoothPrinterService.canMarkPaperComplete {
                Button {
                    bluetoothPrinterService.markPaperComplete()
                } label: {
                    Label("Mark Paper Complete", systemImage: "checkmark.circle")
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func bluetoothMetricsView(_ metrics: BluetoothPrinterMetrics) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ProgressView(value: metrics.progress)

            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
                GridRow {
                    Text("Mode")
                        .foregroundStyle(.secondary)
                    Text(metrics.balancedProfileName.map { "\(metrics.mode.displayName) \($0)" } ?? metrics.mode.displayName)
                        .font(.callout.monospacedDigit())
                }

                if let photoCalibrationProfileName = metrics.photoCalibrationProfileName {
                    GridRow {
                        Text("Calibration")
                            .foregroundStyle(.secondary)
                        Text(photoCalibrationProfileName)
                            .font(.callout.monospacedDigit())
                    }
                }

                GridRow {
                    Text(metrics.mode.progressLabel)
                        .foregroundStyle(.secondary)
                    Text("\(metrics.transferredBytes) / \(metrics.payloadByteCount) bytes")
                        .font(.callout.monospacedDigit())
                }

                GridRow {
                    Text("Payload")
                        .foregroundStyle(.secondary)
                    Text("\(metrics.payloadByteCount) bytes")
                        .font(.callout.monospacedDigit())
                }

                GridRow {
                    Text("Raster")
                        .foregroundStyle(.secondary)
                    Text("\(metrics.rasterByteCount) bytes")
                        .font(.callout.monospacedDigit())
                }

                GridRow {
                    Text("BLE chunk")
                        .foregroundStyle(.secondary)
                    Text("\(metrics.chunkSize) bytes of max \(metrics.maximumWriteLength)")
                        .font(.callout.monospacedDigit())
                }

                GridRow {
                    Text("Chunks")
                        .foregroundStyle(.secondary)
                    Text("\(metrics.chunkCount)")
                        .font(.callout.monospacedDigit())
                }

                if let burstChunkCount = metrics.burstChunkCount,
                   let interBurstDelayMilliseconds = metrics.interBurstDelayMilliseconds {
                    GridRow {
                        Text("Burst")
                            .foregroundStyle(.secondary)
                        Text("\(burstChunkCount) chunks, \(interBurstDelayMilliseconds) ms")
                            .font(.callout.monospacedDigit())
                    }

                    GridRow {
                        Text("Bursts")
                            .foregroundStyle(.secondary)
                        Text("\(metrics.burstCount)")
                            .font(.callout.monospacedDigit())
                    }

                    GridRow {
                        Text("Pacing pauses")
                            .foregroundStyle(.secondary)
                        Text("\(metrics.intentionalPacingPauseCount)")
                            .font(.callout.monospacedDigit())
                    }
                }

                if let duration = metrics.duration {
                    GridRow {
                        Text("BLE send")
                            .foregroundStyle(.secondary)
                        Text("\(duration.formatted(.number.precision(.fractionLength(2)))) sec")
                            .font(.callout.monospacedDigit())
                    }
                }

                if let throughputBytesPerSecond = metrics.throughputBytesPerSecond {
                    GridRow {
                        Text("Throughput")
                            .foregroundStyle(.secondary)
                        Text("\((throughputBytesPerSecond / 1024).formatted(.number.precision(.fractionLength(1)))) KB/s")
                            .font(.callout.monospacedDigit())
                    }
                }

                GridRow {
                    Text("Flow pauses")
                        .foregroundStyle(.secondary)
                    Text("\(metrics.flowControlPauseCount)")
                        .font(.callout.monospacedDigit())
                }

                if let longestFlowControlPause = metrics.longestFlowControlPause {
                    GridRow {
                        Text("Longest pause")
                            .foregroundStyle(.secondary)
                        Text("\(longestFlowControlPause.formatted(.number.precision(.fractionLength(3)))) sec")
                            .font(.callout.monospacedDigit())
                    }
                }

                if let physicalPrintDuration = metrics.physicalPrintDuration {
                    GridRow {
                        Text("Paper complete")
                            .foregroundStyle(.secondary)
                        Text("\(physicalPrintDuration.formatted(.number.precision(.fractionLength(2)))) sec")
                            .font(.callout.monospacedDigit())
                    }
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
#endif

    private var imagePreviewGrid: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 20, verticalSpacing: 12) {
            GridRow {
                imagePreview(title: "Original Image", image: originalImage)
                imagePreview(title: "Thermal Preview", image: previewImage)
            }
        }
    }

    private func imagePreview(title: String, image: UIImage?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)

            Group {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 480, maxHeight: 420)
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(.secondarySystemBackground))
                        .frame(width: 320, height: 220)
                        .overlay {
                            Text("No image")
                                .foregroundStyle(.secondary)
                        }
                }
            }
            .frame(maxWidth: 480, minHeight: 220, alignment: .center)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private var statusView: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(statusColor)
                .frame(width: 14, height: 14)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 4) {
                Text(statusTitle)
                    .font(.headline)

                Text(connectionState.message)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if connectionState.requiresPrinterRestart {
                    Button("I Restarted the Printer") {
                        printerService.confirmPrinterRestarted { state in
                            connectionState = state
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 8)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var statusTitle: String {
        switch connectionState {
        case .disconnected:
            "Ready"
        case .connecting, .connected, .printing, .sendingHeading, .sendingPhotograph, .finalizingAndCutting, .printerProcessing, .coolingDown:
            "Working"
        case .recoveryRequired:
            "Printer Restart Required"
        case .success:
            "Success"
        case .failure:
            "Failed"
        }
    }

    private var statusColor: Color {
        switch connectionState {
        case .disconnected:
            .secondary
        case .connecting, .connected, .printing, .sendingHeading, .sendingPhotograph, .finalizingAndCutting, .printerProcessing, .coolingDown:
            .orange
        case .success:
            .green
        case .recoveryRequired, .failure:
            .red
        }
    }

    private var parsedPort: UInt16? {
        let trimmedPort = printerPort.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let value = UInt16(trimmedPort), value > 0 else {
            return nil
        }

        return value
    }

    private var isAnyPrinterBusy: Bool {
        connectionState.isWorking || discoveryState.isSearching || isBluetoothPrinterBusy
    }

#if DEBUG
    private var isBluetoothPrinterBusy: Bool {
        bluetoothPrinterService.jobState.isWorking
    }

    private var bluetoothRasterStatusColor: Color {
        switch bluetoothPrinterService.jobState {
        case .idle, .connected:
            .secondary
        case .scanning, .connecting, .preparing, .sending, .finalizing, .cutting, .printerProcessing, .coolingDown:
            .orange
        case .success:
            .green
        case .recoveryRequired, .failure:
            .red
        }
    }

    private var bluetoothModeDescription: String {
        switch bluetoothRasterMode {
        case .reliable:
            return "Reliable mode uses response-based BLE writes as the known-good clarity control."
        case .balanced:
            return "Balanced mode uses writeWithoutResponse with coarse burst pacing for thermal calibration."
        case .fast:
            return "Fast mode uses writeWithoutResponse with CoreBluetooth flow control and no intentional pacing."
        }
    }

    private var canPrintPhotoViaBluetooth: Bool {
        let hasRaster = bluetoothRasterMode == .fast
            ? calibratedBluetoothRasterizedImage != nil
            : rasterizedImage != nil

        return hasRaster
            && !isProcessingPhoto
            && !isProcessingBluetoothCalibration
            && bluetoothPrinterService.canPrintRaster
            && !connectionState.isWorking
            && !discoveryState.isSearching
    }
#else
    private var isBluetoothPrinterBusy: Bool {
        false
    }
#endif

    private func discoveryFoundTitle(for candidates: [PrinterCandidate]) -> String {
        if candidates.count == 1 {
            candidates[0].isSavedPrinter ? "Saved printer found" : "Printer found"
        } else {
            "Devices found on printer port"
        }
    }

    private func findPrinter() {
        guard let port = parsedPort else {
            discoveryState = .failed("Enter a valid TCP port from 1 to 65535 before searching.")
            return
        }

        guard !connectionState.isWorking, !connectionState.requiresPrinterRestart else {
            discoveryState = .failed("Wait until the current printer operation finishes before searching.")
            return
        }

        discoveryTask?.cancel()
        discoveryService.cancel()
        discoveryTask = Task {
            _ = await discoveryService.discover(savedHost: printerIP, port: port) { state in
                discoveryState = state
            }
            discoveryTask = nil
        }
    }

    private func cancelPrinterDiscovery() {
        discoveryTask?.cancel()
        discoveryTask = nil
        discoveryService.cancel()
        if discoveryState.isSearching {
            discoveryState = .idle
        }
    }

    private func useCandidate(_ candidate: PrinterCandidate) {
        printerIP = candidate.host
        printerPort = "\(candidate.port)"
        discoveryState = .found([
            PrinterCandidate(host: candidate.host, port: candidate.port, isSavedPrinter: true)
        ])
    }

    private func testCandidate(_ candidate: PrinterCandidate) {
        printerIP = candidate.host
        printerPort = "\(candidate.port)"
        testConnection()
    }

    private func testConnection() {
        guard let port = parsedPort else {
            connectionState = .failure("Enter a valid TCP port from 1 to 65535.")
            return
        }

        printerService.testConnection(host: printerIP, port: port) { state in
            connectionState = state
        } completion: { _ in }
    }

    private func printTestReceipt() {
        guard let port = parsedPort else {
            connectionState = .failure("Enter a valid TCP port from 1 to 65535.")
            return
        }

        let payload = ESCPOSTestReceipt.payload(printerIP: printerIP, port: port)

        printerService.print(payload: payload, host: printerIP, port: port) { state in
            connectionState = state
        } completion: { _ in }
    }

    private func printPhotoTest() {
        guard let port = parsedPort else {
            connectionState = .failure("Enter a valid TCP port from 1 to 65535.")
            return
        }

        guard let rasterizedImage else {
            photoStatusMessage = "Select and process a photo before printing."
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
            connectionState = .failure(error.localizedDescription)
            return
        }

        printerService.printPhoto(
            heading: ThermalImageRasterizer.photoTestHeading(),
            rasterCommand: rasterizedImage.rasterCommand,
            finishing: ThermalImageRasterizer.photoTestFinishing(),
            imageWidth: rasterizedImage.width,
            imageHeight: rasterizedImage.height,
            rasterDataByteCount: rasterizedImage.rasterData.count,
            sanitizationReport: rasterizedImage.sanitizationReport,
            yL: rasterizedImage.yL,
            yH: rasterizedImage.yH,
            host: printerIP,
            port: port
        ) { state in
            connectionState = state
        } completion: { _ in }
    }

#if DEBUG
    private func printPhotoViaBluetooth() {
        let selectedRasterizedImage = bluetoothRasterMode == .fast
            ? calibratedBluetoothRasterizedImage
            : rasterizedImage

        guard let selectedRasterizedImage else {
            photoStatusMessage = "Select and process a photo before printing over Bluetooth."
            return
        }

        bluetoothPrinterService.printPhoto(
            rasterizedImage: selectedRasterizedImage,
            mode: bluetoothRasterMode,
            balancedProfile: balancedBluetoothProfile,
            calibrationProfileName: bluetoothRasterMode == .fast
                ? thermalPhotoCalibrationProfile.displayName
                : ThermalPhotoCalibrationProfile.original.displayName
        )
    }

    private func printReceiptViaBluetooth() {
        guard let originalImage else {
            photoStatusMessage = "Select a photo before composing a Bluetooth receipt test."
            return
        }

        do {
            let photos = Array(repeating: originalImage, count: bluetoothReceiptFormat.photoCount)
            let date = Date()
            let receipt = try ReceiptComposer.compose(
                photos: photos,
                sessionIdentifier: ReceiptComposer.makeSessionIdentifier(date: date),
                date: date,
                galleryURL: nil,
                format: bluetoothReceiptFormat
            )

            bluetoothPrinterService.printReceipt(
                receipt,
                mode: bluetoothRasterMode,
                balancedProfile: balancedBluetoothProfile
            )
        } catch {
            photoStatusMessage = error.localizedDescription
        }
    }
#endif

    private func loadPhoto(from item: PhotosPickerItem?) {
        guard let item else {
            return
        }

        isProcessingPhoto = true
        photoStatusMessage = "Loading selected photo..."
        originalImage = nil
        previewImage = nil
        rasterizedImage = nil
#if DEBUG
        calibratedBluetoothPreviewImage = nil
        calibratedBluetoothRasterizedImage = nil
#endif

        Task {
            do {
                guard let imageData = try await item.loadTransferable(type: Data.self),
                      let image = UIImage(data: imageData) else {
                    throw ThermalImageRasterizerError.invalidImage
                }

                originalImage = image
                photoStatusMessage = "Creating thermal preview..."

                let rasterized = try await Task.detached(priority: .userInitiated) {
                    try ThermalImageRasterizer.rasterize(image)
                }.value

                guard let preview = UIImage(data: rasterized.previewPNGData) else {
                    throw ThermalImageRasterizerError.renderFailed
                }

                rasterizedImage = rasterized
                previewImage = preview
                photoStatusMessage = "Thermal preview ready: \(rasterized.width) x \(rasterized.height) dots."
#if DEBUG
                updateBluetoothCalibratedPreview()
#endif
            } catch {
                photoStatusMessage = error.localizedDescription
                originalImage = nil
                previewImage = nil
                rasterizedImage = nil
#if DEBUG
                calibratedBluetoothPreviewImage = nil
                calibratedBluetoothRasterizedImage = nil
#endif
            }

            isProcessingPhoto = false
        }
    }

#if DEBUG
    private func updateBluetoothCalibratedPreview() {
        guard let originalImage else {
            calibratedBluetoothPreviewImage = nil
            calibratedBluetoothRasterizedImage = nil
            return
        }

        isProcessingBluetoothCalibration = true

        Task {
            do {
                let profile = thermalPhotoCalibrationProfile
                let rasterized = try await Task.detached(priority: .userInitiated) {
                    let calibratedImage = try profile.apply(to: originalImage)
                    return try ThermalImageRasterizer.rasterize(calibratedImage)
                }.value

                guard let preview = UIImage(data: rasterized.previewPNGData) else {
                    throw ThermalImageRasterizerError.renderFailed
                }

                calibratedBluetoothRasterizedImage = rasterized
                calibratedBluetoothPreviewImage = preview
            } catch {
                calibratedBluetoothRasterizedImage = nil
                calibratedBluetoothPreviewImage = nil
                photoStatusMessage = error.localizedDescription
            }

            isProcessingBluetoothCalibration = false
        }
    }
#endif
}
