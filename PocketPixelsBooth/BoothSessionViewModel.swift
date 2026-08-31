//
//  BoothSessionViewModel.swift
//  PocketPixelsBooth
//
//  Created by marc on 8/30/26.
//

import AVFoundation
import Combine
import SwiftUI
import UIKit

@MainActor
final class BoothSessionViewModel: ObservableObject {
    @Published var state: BoothSessionState = .welcome
    @Published var sessionIdentifier: String?
    @Published var statusMessage = "Ready."
    @Published var errorMessage: String?
    @Published var capturedPhotos: [UIImage] = []
    @Published var transientCapturedPhoto: UIImage?
    @Published var composedReceipt: ComposedReceipt?
    @Published var receiptImage: UIImage?
    @Published var thermalReceiptPreview: UIImage?
    @Published var receiptRasterizedImage: ThermalRasterizedImage?
    @Published var galleryToken: String?
    @Published var galleryURL: URL?
    @Published var galleryQRCodeImage: UIImage?
    @Published var uploadPhase = GalleryUploadPhase.idle
    @Published var uploadStatusMessage = "Gallery upload has not started."
    @Published var pendingUploadSummaries: [GalleryPendingUploadSummary] = []
    @Published var printerState = PrinterConnectionState.disconnected
    @Published var isCameraUnavailable = false
    @Published var isCameraRunning = false
    @Published var samplePhotoCount = 0

    let cameraService = CameraService()

    private let printerService = PrinterNetworkService()
    private let uploadService = GoogleDriveGalleryUploadService()
    private let credentialStore = DeviceCredentialStore()
    private var activeTask: Task<Void, Never>?
    private var uploadTask: Task<Void, Never>?
    private var thankYouResetTask: Task<Void, Never>?
    private var isTransitionActive = false
    private var retakeIndex: Int?
    private var sessionCreatedAt: Date?

    var nextPhotoIndex: Int {
        min(capturedPhotos.count, BoothConfiguration.photosPerSession - 1)
    }

    var canBeginPhotos: Bool {
        if case .cameraReady = state {
            return !isTransitionActive && !isCameraUnavailable
        }

        return false
    }

    var canContinueToReceipt: Bool {
        capturedPhotos.count == BoothConfiguration.photosPerSession && !isTransitionActive
    }

    var estimatedReceiptLength: Double? {
        composedReceipt?.estimatedLengthMillimeters
    }

    init() {
        cameraService.onSessionMessage = { [weak self] message in
            self?.statusMessage = message
        }
    }

    func startSession() {
        guard !isTransitionActive else {
            return
        }

        cancelTasks()
        clearCustomerData()
        let sessionDate = Date()
        sessionCreatedAt = sessionDate
        sessionIdentifier = ReceiptComposer.makeSessionIdentifier(date: sessionDate)
        do {
            let token = try GalleryTokenGenerator.makeGalleryToken()
            let url = try GalleryURLBuilder.makeGalleryURL(customerGalleryBaseURL: CustomerGalleryConfiguration.load().baseURL, galleryToken: token)
            galleryToken = token
            galleryURL = url
            galleryQRCodeImage = try GalleryQRCodeGenerator.makeQRCodeImage(for: url)
            uploadPhase = .idle
            uploadStatusMessage = "Gallery will be prepared after the photos are approved."
        } catch {
            galleryToken = nil
            galleryURL = nil
            galleryQRCodeImage = nil
            uploadPhase = .failed(error.localizedDescription)
            uploadStatusMessage = "Gallery setup needs operator attention."
        }
        isTransitionActive = true
        isCameraUnavailable = false
        errorMessage = nil
        statusMessage = "Preparing front camera..."
        state = .preparingCamera
        setIdleTimerDisabled(true)
        debugLog("Session \(sessionIdentifier ?? "unknown") started.")

        prepareCamera { [weak self] result in
            guard let self else { return }
            isTransitionActive = false

            switch result {
            case .success:
                isCameraRunning = true
                statusMessage = "Camera ready."
                state = .cameraReady
            case .failure(let error):
                isCameraRunning = false
                statusMessage = error.localizedDescription
                errorMessage = error.localizedDescription

                if case .cameraUnavailable = error {
                    isCameraUnavailable = true
                    state = .cameraReady
                } else {
                    state = .error(error.localizedDescription)
                }
            }
        }
    }

    func beginPhotoSequence() {
        guard canBeginPhotos else {
            return
        }

        capturedPhotos.removeAll()
        receiptImage = nil
        thermalReceiptPreview = nil
        receiptRasterizedImage = nil
        composedReceipt = nil
        samplePhotoCount = 0
        runAutomaticSequence(startingAt: 0)
    }

    func cancelSession() {
        debugLog("Session \(sessionIdentifier ?? "unknown") cancelled.")
        resetToWelcome()
    }

    func retakePhoto(at index: Int) {
        guard capturedPhotos.indices.contains(index), !isTransitionActive else {
            return
        }

        retakeIndex = index
        state = .retaking(photoIndex: index)
        statusMessage = "Retaking photo \(index + 1)."
        receiptImage = nil
        thermalReceiptPreview = nil
        receiptRasterizedImage = nil
        composedReceipt = nil
        startCameraForRetake(index: index)
    }

    func retakeAll() {
        guard !isTransitionActive else {
            return
        }

        capturedPhotos.removeAll()
        receiptImage = nil
        thermalReceiptPreview = nil
        receiptRasterizedImage = nil
        composedReceipt = nil
        statusMessage = "Restarting the three-photo sequence."
        startCameraForSequence()
    }

    func addSamplePhoto(_ image: UIImage) {
        guard isCameraUnavailable, capturedPhotos.count < BoothConfiguration.photosPerSession, !isTransitionActive else {
            return
        }

        capturedPhotos.append(image.normalizedForBooth())
        samplePhotoCount = capturedPhotos.count
        statusMessage = "Development sample photo \(samplePhotoCount) of \(BoothConfiguration.photosPerSession) loaded."

        if capturedPhotos.count == BoothConfiguration.photosPerSession {
            state = .review
        } else {
            state = .cameraReady
        }
    }

    func continueToReceipt() {
        guard canContinueToReceipt, let sessionIdentifier, let galleryURL, let galleryToken else {
            uploadPhase = .failed(GalleryUploadError.invalidGalleryURL.localizedDescription)
            uploadStatusMessage = "Gallery setup needs operator attention."
            return
        }

        activeTask?.cancel()
        isTransitionActive = true
        state = .composingReceipt
        statusMessage = "Composing receipt..."
        errorMessage = nil

        let photos = capturedPhotos
        let receiptDate = sessionCreatedAt ?? Date()
        activeTask = Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    let receipt = try ReceiptComposer.compose(photos: photos, sessionIdentifier: sessionIdentifier, date: receiptDate, galleryURL: galleryURL)
                    guard let receiptImage = UIImage(data: receipt.imagePNGData) else {
                        throw ReceiptComposerError.renderFailed
                    }
                    let rasterized = try ThermalImageRasterizer.rasterize(receiptImage, purpose: .completeReceipt)
                    guard let preview = UIImage(data: rasterized.previewPNGData) else {
                        throw ThermalImageRasterizerError.renderFailed
                    }
                    return (receipt, receiptImage, preview, rasterized)
                }.value

                guard !Task.isCancelled else { return }

                composedReceipt = result.0
                receiptImage = result.1
                thermalReceiptPreview = result.2
                receiptRasterizedImage = result.3
                state = .receiptPreview
                statusMessage = "Receipt ready: \(result.0.width) x \(result.0.height) pixels."
                startGalleryUpload(photos: photos, receiptImage: result.1, sessionID: sessionIdentifier, createdAt: receiptDate, galleryToken: galleryToken)
                debugLog("Session \(sessionIdentifier) receipt ready. Raster bytes: \(result.3.rasterData.count). Sanitized EOT: \(result.3.sanitizationReport.dleEOTPatternCount). Sanitized DC4: \(result.3.sanitizationReport.dleDC4PatternCount).")
            } catch {
                state = .error(error.localizedDescription)
                errorMessage = error.localizedDescription
                statusMessage = error.localizedDescription
            }

            isTransitionActive = false
        }
    }

    func rebuildReceipt() {
        receiptImage = nil
        thermalReceiptPreview = nil
        receiptRasterizedImage = nil
        composedReceipt = nil
        continueToReceipt()
    }

    func backToReview() {
        guard !isTransitionActive, !printerState.isWorking else {
            return
        }

        state = .review
    }

    func testPrinterConnection(host: String, port: UInt16?) {
        guard let port else {
            printerState = .failure("Enter a valid TCP port from 1 to 65535.")
            return
        }

        printerService.testConnection(host: host, port: port) { [weak self] state in
            self?.printerState = state
        } completion: { _ in }
    }

    func printReceipt(host: String, port: UInt16?) {
        guard let port else {
            printerState = .failure("Enter a valid TCP port from 1 to 65535.")
            return
        }

        guard let rasterized = receiptRasterizedImage else {
            printerState = .failure("Build the receipt before printing.")
            return
        }

        do {
            try ThermalImageRasterizer.validateRasterCommand(
                rasterized.rasterCommand,
                imageWidth: rasterized.width,
                imageHeight: rasterized.height,
                bytesPerRow: rasterized.widthBytes,
                rasterDataCount: rasterized.rasterData.count
            )
        } catch {
            printerState = .failure(error.localizedDescription)
            return
        }

        state = .connectingToPrinter
        statusMessage = "Connecting to printer..."

        printerService.printPhoto(
            heading: ThermalImageRasterizer.receiptPrintHeading(),
            rasterCommand: rasterized.rasterCommand,
            finishing: ThermalImageRasterizer.photoTestFinishing(),
            imageWidth: rasterized.width,
            imageHeight: rasterized.height,
            rasterDataByteCount: rasterized.rasterData.count,
            sanitizationReport: rasterized.sanitizationReport,
            yL: rasterized.yL,
            yH: rasterized.yH,
            host: host,
            port: port
        ) { [weak self] printerState in
            guard let self else { return }
            self.printerState = printerState

            switch printerState {
            case .connecting, .connected:
                self.state = .connectingToPrinter
            case .printing, .sendingHeading, .sendingPhotograph, .finalizingAndCutting, .printerProcessing, .coolingDown:
                self.state = .printing
            case .recoveryRequired(let message):
                self.state = .recoveryRequired(message)
                self.statusMessage = message
            case .failure(let message):
                self.state = .receiptPreview
                self.statusMessage = message
            case .success:
                break
            case .disconnected:
                break
            }
        } completion: { [weak self] result in
            guard let self else { return }

            switch result {
            case .success:
                self.showThankYou()
            case .failure:
                if self.printerState.requiresPrinterRestart {
                    self.state = .recoveryRequired(self.printerState.message)
                } else {
                    self.state = .receiptPreview
                }
            }
        }
    }

    func confirmPrinterRestarted() {
        printerService.confirmPrinterRestarted { [weak self] state in
            self?.printerState = state
            self?.state = .receiptPreview
            self?.statusMessage = "Run Test Connection before printing again."
        }
    }

    func resetAfterDone() {
        resetToWelcome()
    }

    func retryQueuedGalleryUploads() {
        refreshPendingUploads()
        guard !uploadPhase.isWorking, !pendingUploadSummaries.isEmpty else {
            return
        }

        guard (try? credentialStore.loadDeviceToken()) != nil else {
            uploadStatusMessage = "Gallery retry needs the saved device token."
            return
        }

        uploadTask?.cancel()
        uploadPhase = .uploading
        uploadStatusMessage = "Uploading queued gallery..."
        uploadTask = Task {
            do {
                guard let deviceToken = try credentialStore.loadDeviceToken() else {
                    throw GalleryUploadError.missingDeviceToken
                }
                let result = try await uploadService.retryNextPendingUpload(deviceToken: deviceToken)
                uploadPhase = .success(result.galleryURL)
                uploadStatusMessage = result.status.displayTitle
                refreshPendingUploads()
                if !pendingUploadSummaries.isEmpty {
                    retryQueuedGalleryUploads()
                }
            } catch {
                applyUploadError(error, customerFacing: false)
                refreshPendingUploads()
            }
        }
    }

    private func prepareCamera(completion: @escaping (Result<Void, CameraServiceError>) -> Void) {
        switch cameraService.authorizationStatus() {
        case .authorized:
            cameraService.configureAndStart(completion: completion)
        case .notDetermined:
            Task {
                let granted = await cameraService.requestAccess()
                if granted {
                    cameraService.configureAndStart(completion: completion)
                } else {
                    completion(.failure(.permissionDenied))
                }
            }
        case .denied:
            completion(.failure(.permissionDenied))
        case .restricted:
            completion(.failure(.permissionRestricted))
        @unknown default:
            completion(.failure(.configurationFailed("Camera permission could not be determined.")))
        }
    }

    private func startCameraForSequence() {
        isTransitionActive = true
        state = .preparingCamera
        prepareCamera { [weak self] result in
            guard let self else { return }
            isTransitionActive = false

            switch result {
            case .success:
                isCameraRunning = true
                runAutomaticSequence(startingAt: 0)
            case .failure(let error):
                state = .error(error.localizedDescription)
                errorMessage = error.localizedDescription
                statusMessage = error.localizedDescription
            }
        }
    }

    private func startCameraForRetake(index: Int) {
        isTransitionActive = true
        prepareCamera { [weak self] result in
            guard let self else { return }
            isTransitionActive = false

            switch result {
            case .success:
                isCameraRunning = true
                runSingleRetake(index: index)
            case .failure(let error):
                state = .error(error.localizedDescription)
                errorMessage = error.localizedDescription
                statusMessage = error.localizedDescription
            }
        }
    }

    private func runAutomaticSequence(startingAt startIndex: Int) {
        guard activeTask == nil else {
            return
        }

        isTransitionActive = true
        activeTask = Task {
            for index in startIndex..<BoothConfiguration.photosPerSession {
                guard !Task.isCancelled else { return }
                await countdownAndCapture(index: index, replacing: false)
                if case .error = state {
                    return
                }

                guard !Task.isCancelled else { return }
                if index < BoothConfiguration.photosPerSession - 1 {
                    state = .betweenPhotos(nextPhotoIndex: index + 1)
                    statusMessage = "Next photo in a moment."
                    try? await Task.sleep(for: .seconds(BoothConfiguration.interPhotoDelay))
                }
            }

            guard !Task.isCancelled else { return }
            cameraService.stopSession()
            isCameraRunning = false
            transientCapturedPhoto = nil
            state = .review
            statusMessage = "Review your photos."
            isTransitionActive = false
            activeTask = nil
        }
    }

    private func runSingleRetake(index: Int) {
        guard activeTask == nil else {
            return
        }

        isTransitionActive = true
        activeTask = Task {
            await countdownAndCapture(index: index, replacing: true)
            if case .error = state {
                return
            }

            guard !Task.isCancelled else { return }
            cameraService.stopSession()
            isCameraRunning = false
            transientCapturedPhoto = nil
            retakeIndex = nil
            state = .review
            statusMessage = "Review your photos."
            isTransitionActive = false
            activeTask = nil
        }
    }

    private func countdownAndCapture(index: Int, replacing: Bool) async {
        for value in stride(from: BoothConfiguration.countdownSeconds, through: 1, by: -1) {
            guard !Task.isCancelled else { return }
            state = .countdown(photoIndex: index, value: value)
            statusMessage = replacing ? "Retaking photo \(index + 1)." : "Photo \(index + 1) of \(BoothConfiguration.photosPerSession)."
            try? await Task.sleep(for: .seconds(1))
        }

        guard !Task.isCancelled else { return }
        state = .capturing(photoIndex: index)
        statusMessage = "Capturing photo \(index + 1)."

        do {
            let image = try await capturePhoto()
            guard !Task.isCancelled else { return }

            if replacing, capturedPhotos.indices.contains(index) {
                capturedPhotos[index] = image
            } else if capturedPhotos.count == index {
                capturedPhotos.append(image)
            } else if capturedPhotos.indices.contains(index) {
                capturedPhotos[index] = image
            }

            transientCapturedPhoto = image
            debugLog("Session \(sessionIdentifier ?? "unknown") captured photo \(index + 1).")
            try? await Task.sleep(for: .seconds(BoothConfiguration.capturedPhotoDisplayDuration))
            transientCapturedPhoto = nil
        } catch {
            state = .error(error.localizedDescription)
            errorMessage = error.localizedDescription
            statusMessage = error.localizedDescription
            isTransitionActive = false
            activeTask = nil
        }
    }

    private func capturePhoto() async throws -> UIImage {
        try await withCheckedThrowingContinuation { continuation in
            cameraService.capturePhoto { result in
                switch result {
                case .success(let image):
                    continuation.resume(returning: image.normalizedForBooth())
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func showThankYou() {
        state = .thankYou
        statusMessage = "Scan the QR to view and save your photos."
        debugLog("Session \(sessionIdentifier ?? "unknown") printed successfully.")
        thankYouResetTask?.cancel()
        thankYouResetTask = Task {
            try? await Task.sleep(for: .seconds(BoothConfiguration.thankYouDuration))
            guard !Task.isCancelled else { return }
            resetToWelcome()
        }
    }

    private func resetToWelcome() {
        cancelTasks()
        cameraService.stopSession()
        isCameraRunning = false
        clearCustomerData()
        state = .welcome
        statusMessage = "Ready."
        errorMessage = nil
        printerState = .disconnected
        isTransitionActive = false
        setIdleTimerDisabled(false)
    }

    private func clearCustomerData() {
        capturedPhotos.removeAll()
        transientCapturedPhoto = nil
        composedReceipt = nil
        receiptImage = nil
        thermalReceiptPreview = nil
        receiptRasterizedImage = nil
        sessionIdentifier = nil
        sessionCreatedAt = nil
        galleryToken = nil
        galleryURL = nil
        galleryQRCodeImage = nil
        uploadPhase = .idle
        uploadStatusMessage = "Gallery upload has not started."
        samplePhotoCount = 0
    }

    private func cancelTasks() {
        activeTask?.cancel()
        activeTask = nil
        thankYouResetTask?.cancel()
        thankYouResetTask = nil
    }

    private func startGalleryUpload(
        photos: [UIImage],
        receiptImage: UIImage,
        sessionID: String,
        createdAt: Date,
        galleryToken: String
    ) {
        uploadTask?.cancel()
        uploadPhase = .preparing
        uploadStatusMessage = "Preparing your gallery..."
        uploadTask = Task {
            do {
                guard let deviceToken = try credentialStore.loadDeviceToken() else {
                    throw GalleryUploadError.missingDeviceToken
                }
                uploadPhase = .uploading
                uploadStatusMessage = "Uploading your photos..."
                let result = try await uploadService.uploadGallery(
                    photos: photos,
                    composedReceipt: receiptImage,
                    sessionID: sessionID,
                    createdAt: createdAt,
                    galleryToken: galleryToken,
                    deviceToken: deviceToken
                )
                uploadPhase = .success(result.galleryURL)
                uploadStatusMessage = "Your photos are ready."
                refreshPendingUploads()
            } catch {
                applyUploadError(error, customerFacing: true)
                refreshPendingUploads()
            }
        }
    }

    private func applyUploadError(_ error: Error, customerFacing: Bool) {
        if let uploadError = error as? GalleryUploadError {
            switch uploadError {
            case .pendingNoInternet, .network, .deliveryUnknown, .timeout:
                uploadPhase = uploadError == .deliveryUnknown ? .deliveryUnknown : .pendingNoInternet
                uploadStatusMessage = customerFacing ? "Your gallery is queued. This QR will work once the connection is restored." : uploadError.localizedDescription
            case .missingDeviceToken, .invalidDeviceToken, .configuration, .unauthorized, .server, .conflictManualInspection, .requestTooLarge:
                uploadPhase = .failed(uploadError.localizedDescription)
                uploadStatusMessage = customerFacing ? "Your gallery needs operator attention." : uploadError.localizedDescription
            default:
                uploadPhase = .failed(uploadError.localizedDescription)
                uploadStatusMessage = customerFacing ? "Your gallery is queued for retry." : uploadError.localizedDescription
            }
        } else {
            uploadPhase = .failed(error.localizedDescription)
            uploadStatusMessage = customerFacing ? "Your gallery needs operator attention." : error.localizedDescription
        }
    }

    private func refreshPendingUploads() {
        pendingUploadSummaries = uploadService.pendingUploadSummaries()
    }

    private func setIdleTimerDisabled(_ disabled: Bool) {
        UIApplication.shared.isIdleTimerDisabled = disabled
    }
}

private extension UIImage {
    func normalizedForBooth() -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false

        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
    }
}

nonisolated private func debugLog(_ message: String) {
#if DEBUG
    print("[BoothSessionViewModel] \(message)")
#endif
}
