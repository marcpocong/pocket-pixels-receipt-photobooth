//
//  PrinterTestView.swift
//  PocketPixelsBooth
//
//  Created by marc on 8/30/26.
//

import CoreImage
import CoreImage.CIFilterBuiltins
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
    @StateObject private var bluetoothPrinterService = PrinterBluetoothService.shared
    @State private var bluetoothRasterMode = BluetoothPrinterRasterMode.reliable
    @State private var balancedBluetoothProfile = BalancedBluetoothPrinterProfile.medium
    @State private var thermalPhotoCalibrationProfile = ThermalPhotoCalibrationProfile.original
    @State private var bluetoothReceiptFormat = BoothFormat.solo
    @State private var calibratedBluetoothPreviewImage: UIImage?
    @State private var calibratedBluetoothRasterizedImage: ThermalRasterizedImage?
    @State private var isProcessingBluetoothCalibration = false
    @State private var duoConsistencyPhotoItem: PhotosPickerItem?
    @State private var duoConsistencySourceImage: UIImage?
    @State private var duoConsistencyPreviewImage: UIImage?
    @State private var duoConsistencyRasterizedImage: ThermalRasterizedImage?
    @State private var duoConsistencyStatusMessage = "Select one photo to create a same-photo Duo receipt raster."
    @State private var duoConsistencyCoverageSummary: String?
    @State private var isProcessingDuoConsistency = false
    @State private var duoConsistencySecondPhotoCompensation = ThermalDuoSecondPhotoCompensation.none
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
#if DEBUG
                    PrinterSetupView()
#endif
                    actionButtons
                    discoveryStatusView
                    statusView
#if DEBUG
                    DisclosureGroup("Advanced Bluetooth Diagnostics") {
                        PrinterBluetoothDiagnosticView()
                            .padding(.top, 12)
                    }
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
            .onChange(of: duoConsistencyPhotoItem) { _, newItem in
                loadDuoConsistencyPhoto(from: newItem)
            }
            .onChange(of: duoConsistencySecondPhotoCompensation) { _, _ in
                updateDuoConsistencyRaster()
            }
#endif
            .onDisappear {
                cancelPrinterDiscovery()
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

            silentBLETestSection

            bluetoothModeSelector

            if bluetoothRasterMode == .fast {
                thermalPhotoCalibrationSelector
            }

            duoConsistencyTestSection

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

                if let rasterFlowPauseRowSummary = metrics.rasterFlowPauseRowSummary {
                    GridRow {
                        Text("Pause rows")
                            .foregroundStyle(.secondary)
                        Text(rasterFlowPauseRowSummary)
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

    private var duoConsistencyTestSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Duo Consistency Test")
                    .font(.headline)

                Text("DEBUG same-photo thermal test. The selected image is normalized once, then the exact same UIImage is used in both Duo positions.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 12) {
                PhotosPicker(selection: $duoConsistencyPhotoItem, matching: .images) {
                    Label("Select Duo Test Photo", systemImage: "photo.on.rectangle")
                }
                .buttonStyle(.bordered)
                .disabled(isProcessingDuoConsistency || isAnyPrinterBusy)

                Button {
                    printDuoConsistencyViaBluetooth()
                } label: {
                    Label("Print Same-Photo Duo (Fast BLE)", systemImage: "printer")
                }
                .buttonStyle(.borderedProminent)
                .disabled(duoConsistencyRasterizedImage == nil || isProcessingDuoConsistency || !bluetoothPrinterService.canPrintRaster || connectionState.isWorking || discoveryState.isSearching)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Second Photo Compensation")
                    .font(.subheadline.weight(.semibold))

                Picker("Second Photo Compensation", selection: $duoConsistencySecondPhotoCompensation) {
                    ForEach(ThermalDuoSecondPhotoCompensation.fineCalibrationProfiles) { profile in
                        Text(profile.displayName).tag(profile)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 360)
                .disabled(duoConsistencySourceImage == nil || isProcessingDuoConsistency || isAnyPrinterBusy)

                Text(duoConsistencySecondPhotoCompensation.parametersDescription)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                Text("Fine bracket for physical comparison: Mild- vs Mild vs Mild+.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(duoConsistencyStatusMessage)
                .font(.subheadline)
                .foregroundStyle(isProcessingDuoConsistency ? .primary : .secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let duoConsistencyCoverageSummary {
                Text(duoConsistencyCoverageSummary)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if isProcessingDuoConsistency {
                ProgressView("Creating Duo consistency raster...")
            }

            Grid(alignment: .topLeading, horizontalSpacing: 20, verticalSpacing: 12) {
                GridRow {
                    imagePreview(title: "Duo Test Source", image: duoConsistencySourceImage)
                    imagePreview(title: "Final 1-bit Raster Preview", image: duoConsistencyPreviewImage)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var silentBLETestSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Silent BLE Test")
                    .font(.headline)

                Text("DEBUG-only beep isolation using minimal non-raster BLE payloads. Test C intentionally sends the documented buzzer command once.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(alignment: .top, spacing: 12) {
                Button {
                    bluetoothPrinterService.printSilentBLETest(.minimalTextNoCutter)
                } label: {
                    Label("Test A: Text, No Cutter", systemImage: "text.alignleft")
                }
                .buttonStyle(.bordered)
                .disabled(!canRunSilentBLETest)

                Button {
                    bluetoothPrinterService.printSilentBLETest(.minimalTextWithCutter)
                } label: {
                    Label("Test B: Text + Cutter", systemImage: "scissors")
                }
                .buttonStyle(.bordered)
                .disabled(!canRunSilentBLETest)

                Button {
                    bluetoothPrinterService.printSilentBLETest(.explicitBuzzerControl)
                } label: {
                    Label("Test C: Trigger Buzzer Once", systemImage: "speaker.wave.2")
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .disabled(!canRunSilentBLETest)
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

    private var canRunSilentBLETest: Bool {
        bluetoothPrinterService.canPrintRaster
            && !connectionState.isWorking
            && !discoveryState.isSearching
            && !isProcessingPhoto
            && !isProcessingBluetoothCalibration
            && !isProcessingDuoConsistency
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

    private func printDuoConsistencyViaBluetooth() {
        guard let duoConsistencyRasterizedImage else {
            duoConsistencyStatusMessage = "Create the same-photo Duo raster before printing."
            return
        }

        bluetoothPrinterService.printRasterizedReceipt(
            rasterizedImage: duoConsistencyRasterizedImage,
            mode: .fast,
            balancedProfile: balancedBluetoothProfile
        )
    }

    private func loadDuoConsistencyPhoto(from item: PhotosPickerItem?) {
        guard let item else {
            return
        }

        isProcessingDuoConsistency = true
        duoConsistencyStatusMessage = "Loading selected Duo test photo..."
        duoConsistencySourceImage = nil
        duoConsistencyPreviewImage = nil
        duoConsistencyRasterizedImage = nil
        duoConsistencyCoverageSummary = nil

        Task {
            do {
                guard let imageData = try await item.loadTransferable(type: Data.self),
                      let image = UIImage(data: imageData) else {
                    throw ThermalImageRasterizerError.invalidImage
                }

                let normalizedPhoto = await Task.detached(priority: .userInitiated) {
                    BoothPhotoProcessor.normalizedPortraitPhoto(from: image)
                }.value

                duoConsistencySourceImage = normalizedPhoto
                renderDuoConsistencyRaster(from: normalizedPhoto)
                return
            } catch {
                duoConsistencySourceImage = nil
                duoConsistencyPreviewImage = nil
                duoConsistencyRasterizedImage = nil
                duoConsistencyCoverageSummary = nil
                duoConsistencyStatusMessage = error.localizedDescription
            }

            isProcessingDuoConsistency = false
        }
    }

    private func updateDuoConsistencyRaster() {
        guard let duoConsistencySourceImage, !isProcessingDuoConsistency else {
            return
        }

        renderDuoConsistencyRaster(from: duoConsistencySourceImage)
    }

    private func renderDuoConsistencyRaster(from normalizedPhoto: UIImage) {
        isProcessingDuoConsistency = true
        duoConsistencyStatusMessage = "Creating Duo consistency raster..."
        duoConsistencyPreviewImage = nil
        duoConsistencyRasterizedImage = nil
        duoConsistencyCoverageSummary = nil

        Task {
            do {
                let compensation = duoConsistencySecondPhotoCompensation
                let result = try await Task.detached(priority: .userInitiated) {
                    let secondPhoto = try compensation.apply(to: normalizedPhoto)
                    let date = Date()
                    let receipt = try ReceiptComposer.compose(
                        photos: [normalizedPhoto, secondPhoto],
                        sessionIdentifier: "DEBUG-DUO-\(ReceiptComposer.makeSessionIdentifier(date: date))",
                        date: date,
                        galleryURL: nil,
                        format: .duo
                    )

                    guard let receiptImage = UIImage(data: receipt.imagePNGData) else {
                        throw ThermalImageRasterizerError.renderFailed
                    }

                    let rasterized = try ThermalImageRasterizer.rasterize(receiptImage, purpose: .completeReceipt)

                    guard let preview = UIImage(data: rasterized.previewPNGData) else {
                        throw ThermalImageRasterizerError.renderFailed
                    }

                    let coverageSummary = Self.duoConsistencyCoverageSummary(for: rasterized)

                    return (preview, rasterized, coverageSummary)
                }.value

                duoConsistencyPreviewImage = result.0
                duoConsistencyRasterizedImage = result.1
                duoConsistencyCoverageSummary = result.2
                duoConsistencyStatusMessage = "Same-photo Duo raster ready with \(compensation.displayName) second-photo compensation: \(result.1.width) x \(result.1.height) dots."
            } catch {
                duoConsistencyPreviewImage = nil
                duoConsistencyRasterizedImage = nil
                duoConsistencyCoverageSummary = nil
                duoConsistencyStatusMessage = error.localizedDescription
            }

            isProcessingDuoConsistency = false
        }
    }

    nonisolated private static func duoConsistencyCoverageSummary(for rasterizedImage: ThermalRasterizedImage) -> String {
        let photoWidth = BoothConfiguration.receiptWidth - (BoothConfiguration.receiptHorizontalMargin * 2)
        let photoHeight = Int(round(Double(photoWidth) * 3.0 / 4.0))
        let photoX = BoothConfiguration.receiptHorizontalMargin
        let firstPhotoY = 86
        let photoGap = 10
        let secondPhotoY = firstPhotoY + photoHeight + photoGap

        let firstCoverage = blackPixelCoverage(
            in: rasterizedImage,
            xRange: photoX..<(photoX + photoWidth),
            yRange: firstPhotoY..<(firstPhotoY + photoHeight)
        )
        let secondCoverage = blackPixelCoverage(
            in: rasterizedImage,
            xRange: photoX..<(photoX + photoWidth),
            yRange: secondPhotoY..<(secondPhotoY + photoHeight)
        )

        return "Approx black coverage - Duo photo 1: \(firstCoverage.formatted(.number.precision(.fractionLength(1))))%, photo 2: \(secondCoverage.formatted(.number.precision(.fractionLength(1))))%."
    }

    nonisolated private static func blackPixelCoverage(in rasterizedImage: ThermalRasterizedImage, xRange: Range<Int>, yRange: Range<Int>) -> Double {
        let clampedXRange = max(0, xRange.lowerBound)..<min(rasterizedImage.width, xRange.upperBound)
        let clampedYRange = max(0, yRange.lowerBound)..<min(rasterizedImage.height, yRange.upperBound)
        var totalPixels = 0
        var blackPixels = 0

        guard !clampedXRange.isEmpty, !clampedYRange.isEmpty else {
            return 0
        }

        for y in clampedYRange {
            let rowOffset = y * rasterizedImage.widthBytes

            for x in clampedXRange {
                let byteIndex = rowOffset + (x / 8)
                let bitMask = UInt8(0x80) >> UInt8(x % 8)
                totalPixels += 1

                if rasterizedImage.rasterData[byteIndex] & bitMask != 0 {
                    blackPixels += 1
                }
            }
        }

        return totalPixels > 0 ? (Double(blackPixels) / Double(totalPixels)) * 100 : 0
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

#if DEBUG
private enum ThermalDuoSecondPhotoCompensation: String, CaseIterable, Identifiable, Sendable {
    case none
    case mildMinus
    case mild
    case mildPlus
    case medium
    case strong

    nonisolated static let fineCalibrationProfiles: [ThermalDuoSecondPhotoCompensation] = [
        .mildMinus,
        .mild,
        .mildPlus
    ]

    nonisolated var id: String {
        rawValue
    }

    nonisolated var displayName: String {
        switch self {
        case .none:
            "None"
        case .mildMinus:
            "Mild-"
        case .mild:
            "Mild"
        case .mildPlus:
            "Mild+"
        case .medium:
            "Medium"
        case .strong:
            "Strong"
        }
    }

    nonisolated var brightness: Float {
        switch self {
        case .none:
            0
        case .mildMinus:
            0.025
        case .mild:
            0.035
        case .mildPlus:
            0.045
        case .medium:
            0.065
        case .strong:
            0.095
        }
    }

    nonisolated var contrast: Float {
        switch self {
        case .none:
            1
        case .mildMinus:
            0.985
        case .mild:
            0.98
        case .mildPlus:
            0.975
        case .medium:
            0.96
        case .strong:
            0.94
        }
    }

    nonisolated var gammaPower: Float {
        switch self {
        case .none:
            1
        case .mildMinus:
            0.96
        case .mild:
            0.94
        case .mildPlus:
            0.92
        case .medium:
            0.88
        case .strong:
            0.82
        }
    }

    nonisolated var parametersDescription: String {
        "P2 only - brightness \(brightness.formatted(.number.precision(.fractionLength(3)))), contrast \(contrast.formatted(.number.precision(.fractionLength(2)))), gamma \(gammaPower.formatted(.number.precision(.fractionLength(2))))"
    }

    nonisolated func apply(to image: UIImage) throws -> UIImage {
        guard self != .none else {
            return image
        }

        guard let inputImage = CIImage(image: image) else {
            throw ThermalImageRasterizerError.invalidImage
        }

        let colorControls = CIFilter.colorControls()
        colorControls.inputImage = inputImage
        colorControls.brightness = brightness
        colorControls.contrast = contrast
        colorControls.saturation = 1

        guard let colorAdjustedImage = colorControls.outputImage else {
            throw ThermalImageRasterizerError.renderFailed
        }

        let gammaAdjust = CIFilter.gammaAdjust()
        gammaAdjust.inputImage = colorAdjustedImage
        gammaAdjust.power = gammaPower

        guard let outputImage = gammaAdjust.outputImage else {
            throw ThermalImageRasterizerError.renderFailed
        }

        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let cgImage = context.createCGImage(outputImage, from: inputImage.extent) else {
            throw ThermalImageRasterizerError.renderFailed
        }

        return UIImage(cgImage: cgImage, scale: image.scale, orientation: image.imageOrientation)
    }
}
#endif
