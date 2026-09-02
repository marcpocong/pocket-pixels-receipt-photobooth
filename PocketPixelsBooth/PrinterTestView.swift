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

    private let printerService = PrinterNetworkService()
    private let discoveryService = PrinterDiscoveryService()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    header
                    printerFields
                    actionButtons
                    discoveryStatusView
                    statusView
                    photoSection
                }
                .padding(40)
                .frame(maxWidth: 1_080, alignment: .topLeading)
            }
            .navigationTitle("Pocket Pixels Printer Test")
            .onChange(of: selectedPhotoItem) { _, newItem in
                loadPhoto(from: newItem)
            }
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

            Text("VOZY G80 Wi-Fi ESC/POS connection")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
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
            .disabled(connectionState.isWorking || connectionState.requiresPrinterRestart || discoveryState.isSearching)

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
            .disabled(connectionState.isWorking || discoveryState.isSearching)

            Button("Print Test Receipt") {
                printTestReceipt()
            }
            .buttonStyle(.bordered)
            .disabled(connectionState.isWorking || connectionState.requiresPrinterRestart || discoveryState.isSearching)
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
                            .disabled(connectionState.isWorking)

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
                .disabled(isProcessingPhoto || connectionState.isWorking)

                Button("Print Photo Test") {
                    printPhotoTest()
                }
                .buttonStyle(.borderedProminent)
                .disabled(rasterizedImage == nil || isProcessingPhoto || connectionState.isWorking || connectionState.requiresPrinterRestart)
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

    private func loadPhoto(from item: PhotosPickerItem?) {
        guard let item else {
            return
        }

        isProcessingPhoto = true
        photoStatusMessage = "Loading selected photo..."
        originalImage = nil
        previewImage = nil
        rasterizedImage = nil

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
            } catch {
                photoStatusMessage = error.localizedDescription
                originalImage = nil
                previewImage = nil
                rasterizedImage = nil
            }

            isProcessingPhoto = false
        }
    }
}
