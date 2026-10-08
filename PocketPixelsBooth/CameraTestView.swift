//
//  CameraTestView.swift
//  PocketPixelsBooth
//
//  Created by marc on 8/30/26.
//

import AVFoundation
import PhotosUI
import SwiftUI
import UIKit

struct CameraTestView: View {
    @Environment(\.scenePhase) private var scenePhase

    @State private var cameraService = CameraService()
    @State private var cameraStatusMessage = "Camera is ready to set up."
    @State private var cameraErrorMessage: String?
    @State private var isSettingUpCamera = false
    @State private var isCameraRunning = false
    @State private var isCameraUnavailable = false
    @State private var isCountingDown = false
    @State private var isCapturing = false
    @State private var countdownNumber: Int?
    @State private var showFlash = false
    @State private var capturedImage: UIImage?
    @State private var thermalPreviewImage: UIImage?
    @State private var rasterizedImage: ThermalRasterizedImage?
    @State private var isProcessingPhoto = false
    @State private var processingStatusMessage = "Capture or choose a sample photo."
    @State private var selectedSamplePhotoItem: PhotosPickerItem?
    @AppStorage("printerIP") private var printerIP = BoothConfiguration.defaultPrinterIP
    @AppStorage("printerPort") private var printerPort = BoothConfiguration.defaultPrinterPort
    @State private var printerState = PrinterConnectionState.disconnected
    @State private var countdownTask: Task<Void, Never>?

    private let printerService = PrinterNetworkService()

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        header
#if DEBUG
                        colorReferenceSection
#endif

                        if capturedImage == nil {
                            cameraCaptureArea
                        } else {
                            reviewArea
                        }
                    }
                    .padding(28)
                    .frame(maxWidth: 1_180, alignment: .topLeading)
                }
            }
            .navigationTitle("Made to Keep Camera Test")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                setupCameraIfNeeded()
            }
            .onDisappear {
                countdownTask?.cancel()
                cameraService.stopSession()
                isCameraRunning = false
            }
            .onChange(of: scenePhase) { _, newPhase in
                handleScenePhase(newPhase)
            }
            .onChange(of: selectedSamplePhotoItem) { _, newItem in
                loadSamplePhoto(from: newItem)
            }
        }
    }

#if DEBUG
    private var colorReferenceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Color Reference")
                .font(.headline)
                .foregroundStyle(MadeToKeepTheme.ColorPalette.brandMaroon)

            Text("DEBUG reference swatches using production Made to Keep theme colors.")
                .font(.subheadline)
                .foregroundStyle(MadeToKeepTheme.ColorPalette.secondaryText)

            LazyVGrid(columns: colorReferenceColumns, alignment: .leading, spacing: 12) {
                colorReferenceSwatch(
                    name: "paper",
                    color: MadeToKeepTheme.ColorPalette.paper,
                    rgb: "255 / 248 / 242",
                    hex: "#FFF8F2"
                )
                colorReferenceSwatch(
                    name: "paperWarm",
                    color: MadeToKeepTheme.ColorPalette.paperWarm,
                    rgb: "255 / 240 / 230",
                    hex: "#FFF0E6"
                )
                colorReferenceSwatch(
                    name: "brandBlush",
                    color: MadeToKeepTheme.ColorPalette.brandBlush,
                    rgb: "249 / 217 / 199",
                    hex: "#F9D9C7"
                )
                colorReferenceSwatch(
                    name: "brandMaroon",
                    color: MadeToKeepTheme.ColorPalette.brandMaroon,
                    rgb: "119 / 33 / 48",
                    hex: "#772130"
                )
                colorReferenceSwatch(
                    name: "surface",
                    color: MadeToKeepTheme.ColorPalette.surface,
                    rgb: "255 / 253 / 249",
                    hex: "#FFFDF9"
                )
                colorReferenceSwatch(
                    name: "secondaryText",
                    color: MadeToKeepTheme.ColorPalette.secondaryText,
                    rgb: "112 / 92 / 84",
                    hex: "#705C54"
                )
            }
        }
        .padding(18)
        .background(MadeToKeepTheme.ColorPalette.acrylic)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(MadeToKeepTheme.ColorPalette.border.opacity(0.58), lineWidth: 1)
        }
    }

    private var colorReferenceColumns: [GridItem] {
        [
            GridItem(.adaptive(minimum: 180), spacing: 12, alignment: .leading)
        ]
    }

    private func colorReferenceSwatch(name: String, color: Color, rgb: String, hex: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: 6)
                .fill(color)
                .frame(height: 56)
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(MadeToKeepTheme.ColorPalette.border.opacity(0.72), lineWidth: 1)
                }

            Text(name)
                .font(.caption.weight(.semibold))
                .foregroundStyle(MadeToKeepTheme.ColorPalette.brandMaroon)

            Text("\(hex)  \(rgb)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(MadeToKeepTheme.ColorPalette.secondaryText)
        }
    }
#endif

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Made to Keep Camera Test")
                .font(.largeTitle)
                .fontWeight(.semibold)
                .foregroundStyle(.white)

            Text(cameraStatusMessage)
                .font(.title3)
                .foregroundStyle(.white.opacity(0.72))
                .fixedSize(horizontal: false, vertical: true)

            if let cameraErrorMessage {
                Text(cameraErrorMessage)
                    .foregroundStyle(.red.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var cameraCaptureArea: some View {
        HStack(alignment: .top, spacing: 24) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.black)

                if isCameraUnavailable {
                    simulatorFallback
                } else {
                    CameraPreview(session: cameraService.session, cameraService: cameraService)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                if let countdownNumber {
                    Text("\(countdownNumber)")
                        .font(.system(size: 148, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.45), radius: 12, x: 0, y: 6)
                        .transition(.scale.combined(with: .opacity))
                }

                if showFlash {
                    Color.white
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .transition(.opacity)
                }
            }
            .aspectRatio(4.0 / 3.0, contentMode: .fit)
            .frame(maxWidth: 780)
            .clipped()

            VStack(alignment: .leading, spacing: 18) {
                Button {
                    takePhoto()
                } label: {
                    Label("Take Photo", systemImage: "camera.fill")
                        .font(.title2.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!isCameraRunning || isCountingDown || isCapturing || isSettingUpCamera || isCameraUnavailable)

                Button {
                    setupCameraIfNeeded(force: true)
                } label: {
                    Label("Retry Camera", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(isSettingUpCamera || isCountingDown || isCapturing)

                if isSettingUpCamera {
                    ProgressView("Starting camera...")
                        .tint(.white)
                        .foregroundStyle(.white)
                }

                if isCameraUnavailable {
                    PhotosPicker(selection: $selectedSamplePhotoItem, matching: .images) {
                        Label("Use Sample Photo", systemImage: "photo")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    Text("Simulator/development fallback")
                        .font(.headline)
                        .foregroundStyle(.white)

                    Text("The iPad camera must be tested on a physical device.")
                        .foregroundStyle(.white.opacity(0.68))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(width: 300)
        }
    }

    private var simulatorFallback: some View {
        VStack(spacing: 14) {
            Image(systemName: "camera.slash")
                .font(.system(size: 54))
                .foregroundStyle(.white.opacity(0.72))

            Text("The iPad camera must be tested on a physical device.")
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
                .padding(.horizontal, 28)
        }
    }

    private var reviewArea: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top, spacing: 20) {
                reviewedImage(title: "Captured Photo", image: capturedImage)
                reviewedImage(title: "Thermal Preview", image: thermalPreviewImage)
            }

            HStack(spacing: 14) {
                Button {
                    retakePhoto()
                } label: {
                    Label("Retake", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(isProcessingPhoto || printerState.isWorking)

                Button {
                    usePhoto()
                } label: {
                    Label("Use Photo", systemImage: "checkmark.circle")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(capturedImage == nil || isProcessingPhoto || rasterizedImage != nil || printerState.isWorking)
            }

            Text(processingStatusMessage)
                .foregroundStyle(.white.opacity(0.72))
                .fixedSize(horizontal: false, vertical: true)

            if isProcessingPhoto {
                ProgressView("Creating thermal preview...")
                    .tint(.white)
                    .foregroundStyle(.white)
            }

            if rasterizedImage != nil {
                printerControls
            }
        }
    }

    private func reviewedImage(title: String, image: UIImage?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.white)

            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.white.opacity(0.08))

                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding(8)
                } else {
                    Text("Not ready")
                        .foregroundStyle(.white.opacity(0.58))
                }
            }
            .frame(maxWidth: 540, minHeight: 300, maxHeight: 440)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private var printerControls: some View {
        VStack(alignment: .leading, spacing: 16) {
            Divider()
                .overlay(.white.opacity(0.18))

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 14) {
                GridRow {
                    Text("Printer IP")
                        .foregroundStyle(.white.opacity(0.72))
                        .frame(width: 120, alignment: .leading)

                    TextField("Printer IP", text: $printerIP)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.decimalPad)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 320)
                }

                GridRow {
                    Text("Port")
                        .foregroundStyle(.white.opacity(0.72))
                        .frame(width: 120, alignment: .leading)

                    TextField("Port", text: $printerPort)
                        .keyboardType(.numberPad)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 160)
                }
            }

            HStack(alignment: .center, spacing: 14) {
                Button {
                    testPrinterConnection()
                } label: {
                    Label("Test Connection", systemImage: "network")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(printerState.isWorking || printerState.requiresPrinterRestart)

                Button {
                    printCapturedPhotoTest()
                } label: {
                    Label("Print Captured Photo Test", systemImage: "printer.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(rasterizedImage == nil || printerState.isWorking || printerState.requiresPrinterRestart || isProcessingPhoto)

                statusPill
            }

            if printerState.requiresPrinterRestart {
                Button("I Restarted the Printer") {
                    printerService.confirmPrinterRestarted { state in
                        printerState = state
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
    }

    private var statusPill: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(printerStatusColor)
                .frame(width: 12, height: 12)

            Text(printerState.message)
                .foregroundStyle(.white.opacity(0.78))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var printerStatusColor: Color {
        switch printerState {
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

    private func setupCameraIfNeeded(force: Bool = false) {
        guard !isSettingUpCamera else {
            return
        }

        if isCameraRunning, !force {
            return
        }

        cameraService.onSessionMessage = { message in
            cameraStatusMessage = message
        }

        let status = cameraService.authorizationStatus()

        switch status {
        case .authorized:
            startCameraSession()
        case .notDetermined:
            isSettingUpCamera = true
            cameraStatusMessage = "Requesting camera permission..."
            cameraErrorMessage = nil

            Task {
                let granted = await cameraService.requestAccess()
                isSettingUpCamera = false

                if granted {
                    startCameraSession()
                } else {
                    cameraStatusMessage = "Camera permission is required for capture."
                    cameraErrorMessage = CameraServiceError.permissionDenied.localizedDescription
                }
            }
        case .denied:
            cameraStatusMessage = "Camera permission is denied."
            cameraErrorMessage = CameraServiceError.permissionDenied.localizedDescription
        case .restricted:
            cameraStatusMessage = "Camera permission is restricted."
            cameraErrorMessage = CameraServiceError.permissionRestricted.localizedDescription
        @unknown default:
            cameraStatusMessage = "Camera permission status is unknown."
            cameraErrorMessage = "Camera permission could not be determined."
        }
    }

    private func startCameraSession() {
        isSettingUpCamera = true
        isCameraUnavailable = false
        cameraErrorMessage = nil
        cameraStatusMessage = "Starting front camera..."

        cameraService.configureAndStart { result in
            isSettingUpCamera = false

            switch result {
            case .success:
                isCameraRunning = true
                cameraStatusMessage = "Front camera ready."
            case .failure(let error):
                isCameraRunning = false
                cameraStatusMessage = error.localizedDescription
                cameraErrorMessage = error.localizedDescription

                if case .cameraUnavailable = error {
                    isCameraUnavailable = true
                }
            }
        }
    }

    private func takePhoto() {
        guard isCameraRunning, !isCountingDown, !isCapturing else {
            return
        }

        isCountingDown = true
        cameraErrorMessage = nil
        processingStatusMessage = "Waiting for countdown..."

        countdownTask = Task {
            for number in [3, 2, 1] {
                guard !Task.isCancelled else {
                    return
                }

                withAnimation(.easeInOut(duration: 0.18)) {
                    countdownNumber = number
                }

                try? await Task.sleep(for: .seconds(1))
            }

            guard !Task.isCancelled else {
                return
            }

            countdownNumber = nil
            isCountingDown = false
            isCapturing = true
            cameraStatusMessage = "Capturing photo..."

            withAnimation(.easeOut(duration: 0.08)) {
                showFlash = true
            }

            Task {
                try? await Task.sleep(for: .milliseconds(140))
                withAnimation(.easeOut(duration: 0.18)) {
                    showFlash = false
                }
            }

            cameraService.capturePhoto { result in
                isCapturing = false

                switch result {
                case .success(let image):
                    capturedImage = image
                    thermalPreviewImage = nil
                    rasterizedImage = nil
                    processingStatusMessage = "Review the captured photo."
                    cameraStatusMessage = "Photo captured."
                    cameraService.stopSession()
                    isCameraRunning = false
                case .failure(let error):
                    cameraStatusMessage = "Capture failed."
                    cameraErrorMessage = error.localizedDescription
                    processingStatusMessage = error.localizedDescription
                }
            }
        }
    }

    private func retakePhoto() {
        capturedImage = nil
        thermalPreviewImage = nil
        rasterizedImage = nil
        processingStatusMessage = "Capture or choose a sample photo."
        printerState = .disconnected
        setupCameraIfNeeded(force: true)
    }

    private func usePhoto() {
        guard let capturedImage, rasterizedImage == nil, !isProcessingPhoto else {
            return
        }

        isProcessingPhoto = true
        processingStatusMessage = "Creating thermal preview..."

        Task {
            do {
                let rasterized = try await Task.detached(priority: .userInitiated) {
                    try ThermalImageRasterizer.rasterize(capturedImage)
                }.value

                guard let preview = UIImage(data: rasterized.previewPNGData) else {
                    throw ThermalImageRasterizerError.renderFailed
                }

                rasterizedImage = rasterized
                thermalPreviewImage = preview
                processingStatusMessage = "Thermal preview ready: \(rasterized.width) x \(rasterized.height) dots."
            } catch {
                rasterizedImage = nil
                thermalPreviewImage = nil
                processingStatusMessage = error.localizedDescription
            }

            isProcessingPhoto = false
        }
    }

    private func printCapturedPhotoTest() {
        guard let port = parsedPort else {
            printerState = .failure("Enter a valid TCP port from 1 to 65535.")
            return
        }

        guard let rasterizedImage else {
            processingStatusMessage = "Create the thermal preview before printing."
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
            printerState = .failure(error.localizedDescription)
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
            printerState = state
        } completion: { _ in }
    }

    private func testPrinterConnection() {
        guard let port = parsedPort else {
            printerState = .failure("Enter a valid TCP port from 1 to 65535.")
            return
        }

        printerService.testConnection(host: printerIP, port: port) { state in
            printerState = state
        } completion: { _ in }
    }

    private func loadSamplePhoto(from item: PhotosPickerItem?) {
        guard let item else {
            return
        }

        isProcessingPhoto = true
        processingStatusMessage = "Loading simulator sample photo..."

        Task {
            do {
                guard let imageData = try await item.loadTransferable(type: Data.self),
                      let image = UIImage(data: imageData) else {
                    throw ThermalImageRasterizerError.invalidImage
                }

                capturedImage = image.normalizedUpImage()
                thermalPreviewImage = nil
                rasterizedImage = nil
                processingStatusMessage = "Simulator sample loaded. Tap Use Photo to create the thermal preview."
            } catch {
                processingStatusMessage = error.localizedDescription
                capturedImage = nil
                thermalPreviewImage = nil
                rasterizedImage = nil
            }

            isProcessingPhoto = false
        }
    }

    private func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            if capturedImage == nil {
                setupCameraIfNeeded()
            }
        case .inactive, .background:
            countdownTask?.cancel()
            countdownNumber = nil
            isCountingDown = false
            cameraService.stopSession()
            isCameraRunning = false
        @unknown default:
            break
        }
    }
}

private extension UIImage {
    func normalizedUpImage() -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false

        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
