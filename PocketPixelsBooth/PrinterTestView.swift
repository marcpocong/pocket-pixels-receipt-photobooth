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
    @State private var duoConsistencySourceDimensions: CGSize?
    @State private var duoConsistencyNormalizedDimensions: CGSize?
    @State private var duoConsistencySourceImage: UIImage?
    @State private var duoConsistencyPreviewImage: UIImage?
    @State private var duoConsistencyRasterizedImage: ThermalRasterizedImage?
    @State private var duoConsistencyStatusMessage = "Select one photo to create a same-photo Duo receipt raster."
    @State private var duoConsistencyCoverageSummary: String?
    @State private var isProcessingDuoConsistency = false
    @State private var duoConsistencySecondPhotoCompensation = ThermalDuoSecondPhotoCompensation.none
    @State private var stripProgressionPhotoItem: PhotosPickerItem?
    @State private var stripProgressionSourceDimensions: CGSize?
    @State private var stripProgressionNormalizedDimensions: CGSize?
    @State private var stripProgressionSourceImage: UIImage?
    @State private var stripProgressionPreviewImage: UIImage?
    @State private var stripProgressionRasterizedImage: ThermalRasterizedImage?
    @State private var stripProgressionStatusMessage = "Select one photo to create a same-photo Strip receipt raster."
    @State private var stripProgressionCoverageSummary: String?
    @State private var isProcessingStripProgression = false
    @State private var unifiedQualityPhotoItem: PhotosPickerItem?
    @State private var unifiedQualitySourceDimensions: CGSize?
    @State private var unifiedQualityNormalizedDimensions: CGSize?
    @State private var unifiedQualitySourceImage: UIImage?
    @State private var unifiedQualityProfile = PocketPixelsThermalPhotoProfile.customerPrintDefault
    @State private var unifiedQualityResults: [UnifiedPhotoQualityFormatResult] = []
    @State private var unifiedQualityStatusMessage = "Select one photo to generate all-format quality diagnostics."
    @State private var photoQualityCalibrationStatusMessage = "Print each profile separately with the same normalized source photo."
    @State private var photoQualityCalibrationMetricsSummary: String?
    @State private var isProcessingUnifiedQuality = false
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
            .onChange(of: stripProgressionPhotoItem) { _, newItem in
                loadStripProgressionPhoto(from: newItem)
            }
            .onChange(of: unifiedQualityPhotoItem) { _, newItem in
                loadUnifiedQualityPhoto(from: newItem)
            }
            .onChange(of: unifiedQualityProfile) { _, _ in
                updateUnifiedQualityDiagnostics()
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

            unifiedPhotoQualityTestSection
            duoConsistencyTestSection
            stripProgressionTestSection

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

            if let duoConsistencyDimensionSummary {
                Text(duoConsistencyDimensionSummary)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("P1: Control / None. P2: \(duoConsistencySecondPhotoCompensation.displayName).")
                .font(.caption)
                .foregroundStyle(.secondary)

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

    private var unifiedPhotoQualityTestSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Unified Photo Quality Test")
                    .font(.headline)

                Text("DEBUG all-format software matrix. One selected image is normalized once, then reused for Solo, Duo, Grid, and Strip with one global photo profile.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 12) {
                PhotosPicker(selection: $unifiedQualityPhotoItem, matching: .images) {
                    Label("Select Quality Test Photo", systemImage: "photo")
                }
                .buttonStyle(.bordered)
                .disabled(isProcessingUnifiedQuality || isAnyPrinterBusy)

                Button {
                    updateUnifiedQualityDiagnostics()
                } label: {
                    Label("Generate All Formats", systemImage: "square.grid.2x2")
                }
                .buttonStyle(.borderedProminent)
                .disabled(unifiedQualitySourceImage == nil || isProcessingUnifiedQuality || isAnyPrinterBusy)
            }

            Picker("Global Profile", selection: $unifiedQualityProfile) {
                ForEach(PocketPixelsThermalPhotoProfile.debugCandidates) { profile in
                    Text(profile.displayName).tag(profile)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 480)
            .disabled(unifiedQualitySourceImage == nil || isProcessingUnifiedQuality || isAnyPrinterBusy)

            Text(unifiedQualityProfile.parametersDescription)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 10) {
                Text("Physical Photo Calibration")
                    .font(.subheadline.weight(.semibold))

                Text("Each button prints one SOLO-position receipt from the same normalized source photo. Compare separate receipts physically; do not treat software preview as final.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    ForEach(PocketPixelsThermalPhotoProfile.debugCandidates) { profile in
                        Button {
                            printPhotoQualityCalibration(profile: profile)
                        } label: {
                            Label("Print \(profile.displayName)", systemImage: "printer")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(unifiedQualitySourceImage == nil || isProcessingUnifiedQuality || !bluetoothPrinterService.canPrintRaster || connectionState.isWorking || discoveryState.isSearching)
                    }

                    Button {
                        printCompactToneDiagnostic()
                    } label: {
                        Label("Print Tone Target", systemImage: "chart.bar")
                    }
                    .buttonStyle(.bordered)
                    .disabled(isProcessingUnifiedQuality || !bluetoothPrinterService.canPrintRaster || connectionState.isWorking || discoveryState.isSearching)
                }

                Text(photoQualityCalibrationStatusMessage)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let photoQualityCalibrationMetricsSummary {
                    Text(photoQualityCalibrationMetricsSummary)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Text(unifiedQualityStatusMessage)
                .font(.subheadline)
                .foregroundStyle(isProcessingUnifiedQuality ? .primary : .secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let unifiedQualityDimensionSummary {
                Text(unifiedQualityDimensionSummary)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if isProcessingUnifiedQuality {
                ProgressView("Generating all-format quality diagnostics...")
            }

            Grid(alignment: .topLeading, horizontalSpacing: 20, verticalSpacing: 14) {
                ForEach(unifiedQualityRows.indices, id: \.self) { rowIndex in
                    GridRow {
                        ForEach(unifiedQualityRows[rowIndex]) { result in
                            unifiedQualityResultView(result)
                        }
                    }
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func unifiedQualityResultView(_ result: UnifiedPhotoQualityFormatResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(result.format.displayName)
                .font(.subheadline.weight(.semibold))

            imagePreview(title: "1-bit Preview", image: result.previewImage)

            Text(result.summary)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 300, alignment: .leading)
        }
    }

    private var stripProgressionTestSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Strip Thermal Progression Test")
                    .font(.headline)

                Text("DEBUG same-photo Strip baseline. The selected image is normalized once, then the exact same UIImage is used for P1, P2, and P3 with no compensation.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 12) {
                PhotosPicker(selection: $stripProgressionPhotoItem, matching: .images) {
                    Label("Select Strip Test Photo", systemImage: "photo.stack")
                }
                .buttonStyle(.bordered)
                .disabled(isProcessingStripProgression || isAnyPrinterBusy)

                Button {
                    printStripProgressionViaBluetooth()
                } label: {
                    Label("Print Same-Photo Strip", systemImage: "printer")
                }
                .buttonStyle(.borderedProminent)
                .disabled(stripProgressionRasterizedImage == nil || isProcessingStripProgression || !bluetoothPrinterService.canPrintRaster || connectionState.isWorking || discoveryState.isSearching)
            }

            Text("Same image x3. P1: None. P2: None. P3: None.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(stripProgressionStatusMessage)
                .font(.subheadline)
                .foregroundStyle(isProcessingStripProgression ? .primary : .secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let stripProgressionCoverageSummary {
                Text(stripProgressionCoverageSummary)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let stripProgressionDimensionSummary {
                Text(stripProgressionDimensionSummary)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Operator result: compare P1 vs P2 and P2 vs P3. Record P1 ~= P2 ~= P3, P1 < P2 ~= P3, P1 < P2 < P3, or other / inconsistent.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if isProcessingStripProgression {
                ProgressView("Creating Strip progression raster...")
            }

            Grid(alignment: .topLeading, horizontalSpacing: 20, verticalSpacing: 12) {
                GridRow {
                    imagePreview(title: "Strip Test Source", image: stripProgressionSourceImage)
                    imagePreview(title: "Final 1-bit Raster Preview", image: stripProgressionPreviewImage)
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

                Text("DEBUG-only cutter opcode isolation using minimal non-raster BLE payloads. Observe cut and beep behavior physically after each run.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    silentCutTestButton(test: .minimalTextNoCutter, title: "A - No Cut", hex: "none")
                    silentCutTestButton(test: .currentGSVCut, title: "B - GS V 66 0", hex: "1D 56 42 00")
                    silentCutTestButton(test: .escICut, title: "C - ESC i", hex: "1B 69")
                }

                HStack(alignment: .top, spacing: 12) {
                    silentCutTestButton(test: .escMCut, title: "D - ESC m", hex: "1B 6D")
                    silentCutTestButton(test: .gsvOneCut, title: "E - GS V 1", hex: "1D 56 01")
                }
            }

            Text("Record observations: A did it beep? B did it cut and beep? C did it cut and beep? D did it cut and beep? E did it cut and beep?")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text("EXPERIMENTAL PRINTER CONFIGURATION")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.orange)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Variant 1 - Cutter with alarm OFF")
                        .font(.subheadline.weight(.semibold))

                    Text("1F 1B 1F E0 13 14 00 04 02 03")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)

                    Text("Result: DID NOT SILENCE CUT BEEP")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Button {
                        bluetoothPrinterService.sendVOZYCutterAlarmOffConfiguration()
                    } label: {
                        Label("Cutter Alarm OFF - Experimental", systemImage: "exclamationmark.triangle")
                    }
                    .buttonStyle(.bordered)
                    .disabled(!canRunSilentBLETest)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Variant 2 - ALT FIRMWARE")
                        .font(.subheadline.weight(.semibold))

                    Text("1F 1B 1F E0 13 14 00 05 05 01")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)

                    Text("Status: NOT YET TESTED")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)

                    Button {
                        bluetoothPrinterService.sendVOZYAltFirmwareCutterAlarmOffConfiguration()
                    } label: {
                        Label("Cutter Alarm OFF - Alt Firmware", systemImage: "exclamationmark.triangle")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .disabled(!canRunSilentBLETest)
                }

                Text("Send once, wait for BLE transmission to complete, turn printer off, wait about 5 seconds, turn printer on, reconnect if needed, then run cutter test B and record whether it cuts and beeps.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func silentCutTestButton(test: SilentBLETest, title: String, hex: String) -> some View {
        Button {
            bluetoothPrinterService.printSilentBLETest(test)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))

                Text(hex)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            .frame(minWidth: 126, alignment: .leading)
        }
        .buttonStyle(.bordered)
        .disabled(!canRunSilentBLETest)
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

    private var duoConsistencyDimensionSummary: String? {
        dimensionSummary(
            label: "Duo",
            sourceDimensions: duoConsistencySourceDimensions,
            normalizedDimensions: duoConsistencyNormalizedDimensions
        )
    }

    private var stripProgressionDimensionSummary: String? {
        dimensionSummary(
            label: "Strip",
            sourceDimensions: stripProgressionSourceDimensions,
            normalizedDimensions: stripProgressionNormalizedDimensions
        )
    }

    private var unifiedQualityDimensionSummary: String? {
        dimensionSummary(
            label: "Unified quality",
            sourceDimensions: unifiedQualitySourceDimensions,
            normalizedDimensions: unifiedQualityNormalizedDimensions
        )
    }

    private var unifiedQualityRows: [[UnifiedPhotoQualityFormatResult]] {
        stride(from: 0, to: unifiedQualityResults.count, by: 2).map { index in
            Array(unifiedQualityResults[index..<min(index + 2, unifiedQualityResults.count)])
        }
    }

    private func dimensionSummary(label: String, sourceDimensions: CGSize?, normalizedDimensions: CGSize?) -> String? {
        guard let sourceDimensions, let normalizedDimensions else {
            return nil
        }

        return "\(label) source image: \(Int(sourceDimensions.width)) x \(Int(sourceDimensions.height)) px. Normalized image: \(Int(normalizedDimensions.width)) x \(Int(normalizedDimensions.height)) px."
    }

    private var canRunSilentBLETest: Bool {
        bluetoothPrinterService.canPrintRaster
            && !connectionState.isWorking
            && !discoveryState.isSearching
            && !isProcessingPhoto
            && !isProcessingBluetoothCalibration
            && !isProcessingDuoConsistency
            && !isProcessingStripProgression
            && !isProcessingUnifiedQuality
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
                format: bluetoothReceiptFormat,
                photoQualityProfile: .customerPrintDefault
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

    private func loadUnifiedQualityPhoto(from item: PhotosPickerItem?) {
        guard let item else {
            return
        }

        isProcessingUnifiedQuality = true
        unifiedQualityStatusMessage = "Loading selected quality test photo..."
        unifiedQualitySourceImage = nil
        unifiedQualityResults = []
        photoQualityCalibrationMetricsSummary = nil
        unifiedQualitySourceDimensions = nil
        unifiedQualityNormalizedDimensions = nil

        Task {
            do {
                guard let imageData = try await item.loadTransferable(type: Data.self),
                      let image = UIImage(data: imageData) else {
                    throw ThermalImageRasterizerError.invalidImage
                }

                let sourceDimensions = Self.pixelDimensions(of: image)
                let normalizedPhoto = await Task.detached(priority: .userInitiated) {
                    BoothPhotoProcessor.normalizedPortraitPhoto(from: image)
                }.value

                unifiedQualitySourceDimensions = sourceDimensions
                unifiedQualityNormalizedDimensions = Self.pixelDimensions(of: normalizedPhoto)
                unifiedQualitySourceImage = normalizedPhoto
                renderUnifiedQualityDiagnostics(from: normalizedPhoto)
                return
            } catch {
                unifiedQualitySourceImage = nil
                unifiedQualityResults = []
                photoQualityCalibrationMetricsSummary = nil
                unifiedQualitySourceDimensions = nil
                unifiedQualityNormalizedDimensions = nil
                unifiedQualityStatusMessage = error.localizedDescription
            }

            isProcessingUnifiedQuality = false
        }
    }

    private func updateUnifiedQualityDiagnostics() {
        guard let unifiedQualitySourceImage, !isProcessingUnifiedQuality else {
            return
        }

        renderUnifiedQualityDiagnostics(from: unifiedQualitySourceImage)
    }

    private func renderUnifiedQualityDiagnostics(from normalizedPhoto: UIImage) {
        isProcessingUnifiedQuality = true
        unifiedQualityStatusMessage = "Generating all-format quality diagnostics..."
        unifiedQualityResults = []
        photoQualityCalibrationMetricsSummary = nil

        Task {
            do {
                let profile = unifiedQualityProfile
                let diagnostics = try await Task.detached(priority: .userInitiated) {
                    let results = try BoothFormat.allCases.map { format in
                        try Self.unifiedQualityResult(
                            format: format,
                            sourceImage: normalizedPhoto,
                            profile: profile
                        )
                    }
                    let calibrationSummary = try PocketPixelsThermalPhotoProfile.debugCandidates
                        .map { try Self.photoQualityCalibrationMetricLine(sourceImage: normalizedPhoto, profile: $0) }
                        .joined(separator: "\n")

                    return (results, calibrationSummary)
                }.value

                unifiedQualityResults = diagnostics.0
                photoQualityCalibrationMetricsSummary = diagnostics.1
                unifiedQualityStatusMessage = "Generated Solo, Duo, Grid, and Strip with \(profile.displayName) global profile."
            } catch {
                unifiedQualityResults = []
                photoQualityCalibrationMetricsSummary = nil
                unifiedQualityStatusMessage = error.localizedDescription
            }

            isProcessingUnifiedQuality = false
        }
    }

    private func printStripProgressionViaBluetooth() {
        guard let stripProgressionRasterizedImage else {
            stripProgressionStatusMessage = "Create the same-photo Strip raster before printing."
            return
        }

        bluetoothPrinterService.printRasterizedReceipt(
            rasterizedImage: stripProgressionRasterizedImage,
            mode: .fast,
            balancedProfile: balancedBluetoothProfile
        )
    }

    private func printPhotoQualityCalibration(profile: PocketPixelsThermalPhotoProfile) {
        guard let unifiedQualitySourceImage else {
            photoQualityCalibrationStatusMessage = "Select a quality test photo before printing calibration profiles."
            return
        }

        isProcessingUnifiedQuality = true
        photoQualityCalibrationStatusMessage = "Creating \(profile.displayName) physical calibration receipt..."

        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try Self.photoQualityCalibrationRaster(
                        sourceImage: unifiedQualitySourceImage,
                        profile: profile
                    )
                }.value

                photoQualityCalibrationStatusMessage = result.summary
                bluetoothPrinterService.printRasterizedReceipt(
                    rasterizedImage: result.rasterizedImage,
                    mode: .fast,
                    balancedProfile: balancedBluetoothProfile
                )
            } catch {
                photoQualityCalibrationStatusMessage = error.localizedDescription
            }

            isProcessingUnifiedQuality = false
        }
    }

    private func printCompactToneDiagnostic() {
        isProcessingUnifiedQuality = true
        photoQualityCalibrationStatusMessage = "Creating compact tone diagnostic..."

        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try Self.compactToneDiagnosticRaster()
                }.value

                photoQualityCalibrationStatusMessage = result.summary
                bluetoothPrinterService.printRasterizedReceipt(
                    rasterizedImage: result.rasterizedImage,
                    mode: .fast,
                    balancedProfile: balancedBluetoothProfile
                )
            } catch {
                photoQualityCalibrationStatusMessage = error.localizedDescription
            }

            isProcessingUnifiedQuality = false
        }
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
        duoConsistencySourceDimensions = nil
        duoConsistencyNormalizedDimensions = nil

        Task {
            do {
                guard let imageData = try await item.loadTransferable(type: Data.self),
                      let image = UIImage(data: imageData) else {
                    throw ThermalImageRasterizerError.invalidImage
                }

                let sourceDimensions = Self.pixelDimensions(of: image)
                let normalizedPhoto = await Task.detached(priority: .userInitiated) {
                    BoothPhotoProcessor.normalizedPortraitPhoto(from: image)
                }.value

                duoConsistencySourceDimensions = sourceDimensions
                duoConsistencyNormalizedDimensions = Self.pixelDimensions(of: normalizedPhoto)
                duoConsistencySourceImage = normalizedPhoto
                renderDuoConsistencyRaster(from: normalizedPhoto)
                return
            } catch {
                duoConsistencySourceImage = nil
                duoConsistencyPreviewImage = nil
                duoConsistencyRasterizedImage = nil
                duoConsistencyCoverageSummary = nil
                duoConsistencySourceDimensions = nil
                duoConsistencyNormalizedDimensions = nil
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
                        format: .duo,
                        photoQualityProfile: .customerPrintDefault
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

    private func loadStripProgressionPhoto(from item: PhotosPickerItem?) {
        guard let item else {
            return
        }

        isProcessingStripProgression = true
        stripProgressionStatusMessage = "Loading selected Strip test photo..."
        stripProgressionSourceImage = nil
        stripProgressionPreviewImage = nil
        stripProgressionRasterizedImage = nil
        stripProgressionCoverageSummary = nil
        stripProgressionSourceDimensions = nil
        stripProgressionNormalizedDimensions = nil

        Task {
            do {
                guard let imageData = try await item.loadTransferable(type: Data.self),
                      let image = UIImage(data: imageData) else {
                    throw ThermalImageRasterizerError.invalidImage
                }

                let sourceDimensions = Self.pixelDimensions(of: image)
                let normalizedPhoto = await Task.detached(priority: .userInitiated) {
                    BoothPhotoProcessor.normalizedPortraitPhoto(from: image)
                }.value

                stripProgressionSourceDimensions = sourceDimensions
                stripProgressionNormalizedDimensions = Self.pixelDimensions(of: normalizedPhoto)
                stripProgressionSourceImage = normalizedPhoto
                renderStripProgressionRaster(from: normalizedPhoto)
                return
            } catch {
                stripProgressionSourceImage = nil
                stripProgressionPreviewImage = nil
                stripProgressionRasterizedImage = nil
                stripProgressionCoverageSummary = nil
                stripProgressionSourceDimensions = nil
                stripProgressionNormalizedDimensions = nil
                stripProgressionStatusMessage = error.localizedDescription
            }

            isProcessingStripProgression = false
        }
    }

    private func renderStripProgressionRaster(from normalizedPhoto: UIImage) {
        isProcessingStripProgression = true
        stripProgressionStatusMessage = "Creating Strip progression raster..."
        stripProgressionPreviewImage = nil
        stripProgressionRasterizedImage = nil
        stripProgressionCoverageSummary = nil

        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    let date = Date()
                    let receipt = try ReceiptComposer.compose(
                        photos: [normalizedPhoto, normalizedPhoto, normalizedPhoto],
                        sessionIdentifier: "DEBUG-STRIP-\(ReceiptComposer.makeSessionIdentifier(date: date))",
                        date: date,
                        galleryURL: nil,
                        format: .strip,
                        photoQualityProfile: .customerPrintDefault
                    )

                    guard let receiptImage = UIImage(data: receipt.imagePNGData) else {
                        throw ThermalImageRasterizerError.renderFailed
                    }

                    let rasterized = try ThermalImageRasterizer.rasterize(receiptImage, purpose: .completeReceipt)

                    guard let preview = UIImage(data: rasterized.previewPNGData) else {
                        throw ThermalImageRasterizerError.renderFailed
                    }

                    let coverageSummary = Self.stripProgressionCoverageSummary(for: rasterized)

                    return (preview, rasterized, coverageSummary)
                }.value

                stripProgressionPreviewImage = result.0
                stripProgressionRasterizedImage = result.1
                stripProgressionCoverageSummary = result.2
                stripProgressionStatusMessage = "Same-photo Strip baseline raster ready with no compensation: \(result.1.width) x \(result.1.height) dots."
            } catch {
                stripProgressionPreviewImage = nil
                stripProgressionRasterizedImage = nil
                stripProgressionCoverageSummary = nil
                stripProgressionStatusMessage = error.localizedDescription
            }

            isProcessingStripProgression = false
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

    nonisolated private static func stripProgressionCoverageSummary(for rasterizedImage: ThermalRasterizedImage) -> String {
        let photoWidth = BoothConfiguration.receiptWidth - (BoothConfiguration.receiptHorizontalMargin * 2)
        let photoHeight = Int(round(Double(photoWidth) * 3.0 / 4.0))
        let photoX = BoothConfiguration.receiptHorizontalMargin
        let firstPhotoY = 86
        let photoGap = 10
        let secondPhotoY = firstPhotoY + photoHeight + photoGap
        let thirdPhotoY = secondPhotoY + photoHeight + photoGap

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
        let thirdCoverage = blackPixelCoverage(
            in: rasterizedImage,
            xRange: photoX..<(photoX + photoWidth),
            yRange: thirdPhotoY..<(thirdPhotoY + photoHeight)
        )

        return "Approx black coverage - Strip P1: \(firstCoverage.formatted(.number.precision(.fractionLength(1))))%, P2: \(secondCoverage.formatted(.number.precision(.fractionLength(1))))%, P3: \(thirdCoverage.formatted(.number.precision(.fractionLength(1))))%. Raster: \(rasterizedImage.width) x \(rasterizedImage.height), rows \(rasterizedImage.height), raster bytes \(rasterizedImage.rasterData.count)."
    }

    nonisolated private static func unifiedQualityResult(
        format: BoothFormat,
        sourceImage: UIImage,
        profile: PocketPixelsThermalPhotoProfile
    ) throws -> UnifiedPhotoQualityFormatResult {
        let plan = try ReceiptComposer.makeLayoutPlan(format: format, includesGalleryQRCode: false)
        let photos = Array(repeating: sourceImage, count: format.photoCount)
        let preparedPhotos = try ReceiptComposer.preparePhotos(photos, for: plan, profile: profile)
        let date = Date()
        let receipt = try ReceiptComposer.compose(
            photos: photos,
            sessionIdentifier: "DEBUG-QUALITY-\(format.rawValue.uppercased())-\(ReceiptComposer.makeSessionIdentifier(date: date))",
            date: date,
            galleryURL: nil,
            format: format,
            photoQualityProfile: profile
        )

        guard let receiptImage = UIImage(data: receipt.imagePNGData) else {
            throw ThermalImageRasterizerError.renderFailed
        }

        let rasterized = try ThermalImageRasterizer.rasterize(receiptImage, purpose: .completeReceipt)

        guard let preview = UIImage(data: rasterized.previewPNGData) else {
            throw ThermalImageRasterizerError.renderFailed
        }

        let photoCoverage = plan.photoFrames.map { frame in
            blackPixelCoverage(
                in: rasterized,
                xRange: Int(frame.rect.minX)..<Int(frame.rect.maxX),
                yRange: Int(frame.rect.minY)..<Int(frame.rect.maxY)
            )
        }
        let coverageSummary = photoCoverage.enumerated()
            .map { index, coverage in
                "P\(index + 1) \(coverage.formatted(.number.precision(.fractionLength(1))))%"
            }
            .joined(separator: ", ")
        let fullReceiptCoverage = blackPixelCoverage(
            in: rasterized,
            xRange: 0..<rasterized.width,
            yRange: 0..<rasterized.height
        )
        let firstPrepared = preparedPhotos[0]
        let firstFrame = plan.photoFrames[0].rect
        let summary = [
            "Profile: \(profile.displayName) (\(profile.parametersDescription))",
            "Tone samples 25/50/75%: \(profile.toneSampleDescription)",
            "Crop: \(Int(firstPrepared.croppedPixelSize.width)) x \(Int(firstPrepared.croppedPixelSize.height)) px",
            "Final photo: \(Int(firstPrepared.finalPixelSize.width)) x \(Int(firstPrepared.finalPixelSize.height)) px",
            "Frame: \(Int(firstFrame.width)) x \(Int(firstFrame.height)) px",
            "Scale: \(Double(firstPrepared.effectiveScale).formatted(.number.precision(.fractionLength(3))))x",
            "Photo black: \(coverageSummary)",
            "Full receipt black: \(fullReceiptCoverage.formatted(.number.precision(.fractionLength(1))))%",
            "Raster: \(rasterized.width) x \(rasterized.height), rows \(rasterized.height), bytes \(rasterized.rasterData.count)"
        ].joined(separator: "\n")

        return UnifiedPhotoQualityFormatResult(
            format: format,
            previewImage: preview,
            summary: summary
        )
    }

    nonisolated private static func photoQualityCalibrationRaster(
        sourceImage: UIImage,
        profile: PocketPixelsThermalPhotoProfile
    ) throws -> PhotoQualityCalibrationRasterResult {
        let plan = try ReceiptComposer.makeLayoutPlan(format: .solo, includesGalleryQRCode: false)
        guard let photoFrame = plan.photoFrames.first?.rect else {
            throw ThermalImageRasterizerError.renderFailed
        }

        let preparedPhoto = try ThermalPhotoProcessor.prepare(
            sourceImage,
            targetPixelSize: photoFrame.size,
            presentationMode: .portrait,
            profile: profile
        )
        let width = plan.width
        let height = Int(photoFrame.maxY) + 126
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true

        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: width, height: height),
            format: format
        )
        let calibrationImage = renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))

            drawCentered("PHOTO QUALITY TEST", y: 20, width: width, font: .systemFont(ofSize: 22, weight: .semibold))
            drawCentered(profile.displayName.uppercased(), y: 48, width: width, font: .systemFont(ofSize: 28, weight: .bold))
            drawCentered(profile.parametersDescription, y: 78, width: width, font: .monospacedSystemFont(ofSize: 18, weight: .regular))
            preparedPhoto.image.draw(in: photoFrame)

            let metricsTop = Int(photoFrame.maxY) + 18
            drawCentered("FINAL PHOTO \(Int(preparedPhoto.finalPixelSize.width)) x \(Int(preparedPhoto.finalPixelSize.height))", y: metricsTop, width: width, font: .monospacedSystemFont(ofSize: 17, weight: .regular))
            drawCentered("PROFILE \(profile.parametersDescription)", y: metricsTop + 24, width: width, font: .monospacedSystemFont(ofSize: 17, weight: .regular))
        }

        let rasterized = try ThermalImageRasterizer.rasterize(calibrationImage, purpose: .completeReceipt)
        let photoCoverage = blackPixelCoverage(
            in: rasterized,
            xRange: Int(photoFrame.minX)..<Int(photoFrame.maxX),
            yRange: Int(photoFrame.minY)..<Int(photoFrame.maxY)
        )
        let summary = "\(profile.displayName) ready. Photo \(Int(preparedPhoto.finalPixelSize.width)) x \(Int(preparedPhoto.finalPixelSize.height)) px. Raster \(rasterized.width) x \(rasterized.height), rows \(rasterized.height), bytes \(rasterized.rasterData.count). Approx photo black \(photoCoverage.formatted(.number.precision(.fractionLength(1))))%. Sanitizer modified \(rasterized.sanitizationReport.modifiedByteCount) bytes at \(rasterized.sanitizationReport.modifiedOffsetSummary). Tone samples \(profile.toneSampleDescription)."

        return PhotoQualityCalibrationRasterResult(
            rasterizedImage: rasterized,
            summary: summary
        )
    }

    nonisolated private static func compactToneDiagnosticRaster() throws -> PhotoQualityCalibrationRasterResult {
        let width = BoothConfiguration.receiptWidth
        let height = 360
        let margin = BoothConfiguration.receiptHorizontalMargin
        let contentWidth = width - (margin * 2)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true

        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: width, height: height),
            format: format
        )
        let targetImage = renderer.image { context in
            let cgContext = context.cgContext
            UIColor.white.setFill()
            cgContext.fill(CGRect(x: 0, y: 0, width: width, height: height))

            drawCentered("THERMAL TONE TARGET", y: 18, width: width, font: .systemFont(ofSize: 22, weight: .semibold))
            drawCentered("WEDGE PATCHES DETAIL", y: 46, width: width, font: .monospacedSystemFont(ofSize: 16, weight: .regular))

            let wedgeTop = 82
            let wedgeHeight = 42
            for x in 0..<contentWidth {
                let gray = CGFloat(x) / CGFloat(max(1, contentWidth - 1))
                UIColor(white: gray, alpha: 1).setFill()
                cgContext.fill(CGRect(x: margin + x, y: wedgeTop, width: 1, height: wedgeHeight))
            }
            UIColor.black.setStroke()
            cgContext.setLineWidth(1)
            cgContext.stroke(CGRect(x: margin, y: wedgeTop, width: contentWidth, height: wedgeHeight))

            let patchTop = wedgeTop + wedgeHeight + 28
            let patchGap = 8
            let patchCount = 5
            let patchWidth = (contentWidth - (patchGap * (patchCount - 1))) / patchCount
            let patchValues: [CGFloat] = [0.25, 0.38, 0.50, 0.62, 0.75]
            for (index, gray) in patchValues.enumerated() {
                let x = margin + index * (patchWidth + patchGap)
                UIColor(white: gray, alpha: 1).setFill()
                cgContext.fill(CGRect(x: x, y: patchTop, width: patchWidth, height: 56))
                UIColor.black.setStroke()
                cgContext.stroke(CGRect(x: x, y: patchTop, width: patchWidth, height: 56))
                drawCentered(
                    "\(Int(gray * 100))",
                    in: CGRect(x: x, y: patchTop + 62, width: patchWidth, height: 18),
                    font: .monospacedSystemFont(ofSize: 10, weight: .regular)
                )
            }

            let detailTop = patchTop + 96
            UIColor.black.setStroke()
            cgContext.setLineWidth(1)
            for offset in stride(from: 0, through: contentWidth, by: 8) {
                cgContext.move(to: CGPoint(x: margin + offset, y: detailTop))
                cgContext.addLine(to: CGPoint(x: margin + offset, y: detailTop + 42))
            }
            cgContext.strokePath()

            UIColor.black.setFill()
            for y in stride(from: 0, through: 40, by: 8) {
                cgContext.fill(CGRect(x: margin, y: detailTop + 62 + y, width: contentWidth, height: 1))
            }
            for x in stride(from: 0, through: contentWidth, by: 16) {
                cgContext.fill(CGRect(x: margin + x, y: detailTop + 58, width: 1, height: 48))
            }
        }

        let rasterized = try ThermalImageRasterizer.rasterize(targetImage, purpose: .completeReceipt)
        let summary = "Tone target ready. Raster \(rasterized.width) x \(rasterized.height), bytes \(rasterized.rasterData.count). Sanitizer modified \(rasterized.sanitizationReport.modifiedByteCount) bytes at \(rasterized.sanitizationReport.modifiedOffsetSummary)."

        return PhotoQualityCalibrationRasterResult(
            rasterizedImage: rasterized,
            summary: summary
        )
    }

    nonisolated private static func photoQualityCalibrationMetricLine(
        sourceImage: UIImage,
        profile: PocketPixelsThermalPhotoProfile
    ) throws -> String {
        let result = try photoQualityCalibrationRaster(sourceImage: sourceImage, profile: profile)
        let coverageFragment = result.summary
            .components(separatedBy: "Approx photo black ")
            .last ?? "unknown"

        return "\(profile.displayName): \(coverageFragment)"
    }

    nonisolated private static func pixelDimensions(of image: UIImage) -> CGSize {
        CGSize(
            width: max(1, round(image.size.width * image.scale)),
            height: max(1, round(image.size.height * image.scale))
        )
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

    nonisolated private static func drawCentered(_ text: String, y: Int, width: Int, font: UIFont) {
        drawCentered(text, in: CGRect(x: 0, y: y, width: width, height: Int(font.lineHeight) + 8), font: font)
    }

    nonisolated private static func drawCentered(_ text: String, in rect: CGRect, font: UIFont) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor.black,
            .paragraphStyle: paragraph
        ]

        NSString(string: text).draw(
            in: rect,
            withAttributes: attributes
        )
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
private struct UnifiedPhotoQualityFormatResult: Identifiable {
    let format: BoothFormat
    let previewImage: UIImage
    let summary: String

    var id: BoothFormat {
        format
    }
}

private struct PhotoQualityCalibrationRasterResult {
    let rasterizedImage: ThermalRasterizedImage
    let summary: String
}

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
