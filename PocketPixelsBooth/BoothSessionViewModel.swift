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
    @Published var receiptPhotoPreviewImage: UIImage?
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
    @Published var selectedBoothFormat: BoothFormat?
    @Published var selectedPrintCopies = 1 {
        didSet {
            guard printBatchTask == nil,
                  Self.printCopyRange.contains(selectedPrintCopies) else {
                selectedPrintCopies = oldValue
                return
            }
        }
    }
    @Published var currentPrintCopy = 0
    @Published var completedPrintCopies = 0

    let cameraService = CameraService()

    private let printerService = PrinterNetworkService()
    private let printerCoordinator = PrinterCoordinator.shared
    private let uploadService = GoogleDriveGalleryUploadService()
    private let credentialStore = DeviceCredentialStore()
    private let recoveryStore = try? AppRecoveryStore()
    private let operationalState = EventOperationalState.shared
    private var activeTask: Task<Void, Never>?
    private var printBatchTask: Task<Void, Never>?
    private var cameraWatchdogTask: Task<Void, Never>?
    private var galleryUploadTasks: [String: Task<Void, Never>] = [:]
    private var queueRetryTask: Task<Void, Never>?
    private var isTransitionActive = false
    private var retakeIndex: Int?
    private var sessionCreatedAt: Date?
    private var sessionEventProfile: EventProfile?
    private var committedGallerySession: CommittedGallerySession?
    private var customerSessionGeneration = 0
    private let customerPrintPhotoProfile = PocketPixelsThermalPhotoProfile.customerPrintDefault
    private static let printCopyRange = 1...10
#if DEBUG
    private var debugSessionSequence = 0
    private var currentDebugSessionSequence: Int?
    private var debugPrintBatchSequence = 0
#endif

    var nextPhotoIndex: Int {
        min(capturedPhotos.count, max(requiredPhotoCount - 1, 0))
    }

    var requiredPhotoCount: Int {
        selectedBoothFormat?.photoCount ?? BoothFormat.solo.photoCount
    }

    var canBeginPhotos: Bool {
        if case .cameraReady = state {
            return !isTransitionActive && !isCameraUnavailable
        }

        return false
    }

    var canContinueToReceipt: Bool {
        selectedBoothFormat != nil && capturedPhotos.count == requiredPhotoCount && !isTransitionActive && committedGallerySession == nil
    }

    var canReturnToReview: Bool {
        committedGallerySession == nil && !printerState.isWorking && printBatchTask == nil
    }

    var supportedPrintCopies: [Int] {
        Array(Self.printCopyRange)
    }

    var isPrintBatchActive: Bool {
        printBatchTask != nil
    }

    var printButtonTitle: String {
        selectedPrintCopies == 1 ? "Print Receipt" : "Print \(selectedPrintCopies) Copies"
    }

    var canDecreasePrintCopies: Bool {
        !isPrintBatchActive && selectedPrintCopies > Self.printCopyRange.lowerBound
    }

    var canIncreasePrintCopies: Bool {
        !isPrintBatchActive && selectedPrintCopies < Self.printCopyRange.upperBound
    }

    var printProgressText: String {
        if selectedPrintCopies > 1, currentPrintCopy > 0 {
            return "Printing copy \(currentPrintCopy) of \(selectedPrintCopies)..."
        }

        return "Printing your keepsake..."
    }

    var estimatedReceiptLength: Double? {
        composedReceipt?.estimatedLengthMillimeters
    }

    var receiptStyleSummary: String {
        guard let composedReceipt else {
            return "\(selectedBoothFormat?.displayName ?? "Selected") receipt"
        }

        return "\(composedReceipt.format.displayName) receipt"
    }

    init() {
        cameraService.onSessionMessage = { [weak self] message in
            self?.statusMessage = message
        }
        cameraService.onEvent = { [weak self] event in
            Task { @MainActor in
                self?.handleCameraEvent(event)
            }
        }
    }

    func preparePrinter() {
        printerCoordinator.prepare()
    }

    func startSession() {
        guard !isTransitionActive else {
            return
        }

        cancelTasks()
        clearCustomerData()
        beginNewCustomerSession()
        errorMessage = nil
        statusMessage = "Choose your format."
        state = .choosingFormat
    }

    func selectBoothFormat(_ format: BoothFormat) {
        guard case .choosingFormat = state, !isTransitionActive else {
            return
        }

        selectedBoothFormat = format
        let sessionDate = Date()
        sessionCreatedAt = sessionDate
        sessionIdentifier = ReceiptComposer.makeSessionIdentifier(date: sessionDate)
        sessionEventProfile = EventProfileStore.load().activeReceiptSnapshot
        do {
            let token = try GalleryTokenGenerator.makeGalleryToken()
            let url = try GalleryURLBuilder.makeGalleryURL(customerGalleryBaseURL: CustomerGalleryConfiguration.load().baseURL, galleryToken: token)
            galleryToken = token
            galleryURL = url
            galleryQRCodeImage = try GalleryQRCodeGenerator.makeQRCodeImage(for: url)
            uploadPhase = .idle
            uploadStatusMessage = "Gallery will be prepared after the photos are approved."
            persistRecoverySnapshot(stage: .formatSelected)
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
        let sessionGeneration = customerSessionGeneration
        debugLog("[Session] format selected: \(format.displayName)")
        if galleryToken != nil {
            debugLog("[Gallery] token state initialized")
        }
        debugLog("Session \(sessionIdentifier ?? "unknown") started.")

        prepareCamera { [weak self] result in
            guard let self else { return }
            guard self.isCurrentCustomerSession(sessionGeneration) else {
                debugLog("[Session] ignored stale format camera preparation callback")
                return
            }
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
        guard canBeginPhotos, selectedBoothFormat != nil, committedGallerySession == nil else {
            return
        }

        capturedPhotos.removeAll()
        receiptImage = nil
        receiptPhotoPreviewImage = nil
        thermalReceiptPreview = nil
        receiptRasterizedImage = nil
        composedReceipt = nil
        samplePhotoCount = 0
        runAutomaticSequence(startingAt: 0)
    }

    func cancelSession() {
        debugLog("Session \(sessionIdentifier ?? "unknown") cancelled.")
        recoveryStore?.clear(sessionIdentifier: sessionIdentifier)
        resetToWelcome()
    }

    func retakePhoto(at index: Int) {
        guard capturedPhotos.indices.contains(index), !isTransitionActive, committedGallerySession == nil else {
            return
        }

        retakeIndex = index
        state = .retaking(photoIndex: index)
        statusMessage = "Retaking photo \(index + 1)."
        receiptImage = nil
        receiptPhotoPreviewImage = nil
        thermalReceiptPreview = nil
        receiptRasterizedImage = nil
        composedReceipt = nil
        startCameraForRetake(index: index)
    }

    func retakeAll() {
        guard !isTransitionActive, committedGallerySession == nil else {
            return
        }

        capturedPhotos.removeAll()
        receiptImage = nil
        receiptPhotoPreviewImage = nil
        thermalReceiptPreview = nil
        receiptRasterizedImage = nil
        composedReceipt = nil
        statusMessage = "Restarting the photo sequence."
        startCameraForSequence()
    }

    func addSamplePhoto(_ image: UIImage) {
        guard isCameraUnavailable, selectedBoothFormat != nil, capturedPhotos.count < requiredPhotoCount, !isTransitionActive, committedGallerySession == nil else {
            return
        }

        capturedPhotos.append(BoothPhotoProcessor.normalizedPortraitPhoto(from: image))
        samplePhotoCount = capturedPhotos.count
        statusMessage = "Development sample photo \(samplePhotoCount) of \(requiredPhotoCount) loaded."

        if capturedPhotos.count == requiredPhotoCount {
            state = .review
        } else {
            state = .cameraReady
        }
    }

    func continueToReceipt() {
        guard canContinueToReceipt,
              let selectedBoothFormat,
              let sessionIdentifier,
              let receiptDate = sessionCreatedAt,
              let galleryURL,
              let galleryToken else {
            uploadPhase = .failed(GalleryUploadError.invalidGalleryURL.localizedDescription)
            uploadStatusMessage = "Gallery setup needs operator attention."
            return
        }

        let committedSession = CommittedGallerySession(
            sessionIdentifier: sessionIdentifier,
            createdAt: receiptDate,
            galleryToken: galleryToken,
            galleryURL: galleryURL,
            photos: capturedPhotos,
            format: selectedBoothFormat,
            eventProfile: sessionEventProfile
        )
        committedGallerySession = committedSession
        composeReceipt(for: committedSession, enqueueUpload: true)
    }

    func rebuildReceipt() {
        guard let committedGallerySession else {
            receiptImage = nil
            receiptPhotoPreviewImage = nil
            thermalReceiptPreview = nil
            receiptRasterizedImage = nil
            composedReceipt = nil
            continueToReceipt()
            return
        }

        receiptImage = nil
        receiptPhotoPreviewImage = nil
        thermalReceiptPreview = nil
        receiptRasterizedImage = nil
        composedReceipt = nil
        composeReceipt(for: committedGallerySession, enqueueUpload: false)
    }

    func backToReview() {
        guard canReturnToReview else {
            statusMessage = "Photos are locked for this receipt."
            return
        }

        state = .review
    }

    private func composeReceipt(for committedSession: CommittedGallerySession, enqueueUpload: Bool) {
        activeTask?.cancel()
        isTransitionActive = true
        state = .composingReceipt
        statusMessage = "Composing receipt..."
        errorMessage = nil
        let sessionGeneration = customerSessionGeneration
        let customerPrintPhotoProfile = self.customerPrintPhotoProfile

        activeTask = Task {
            do {
                let worker = Task.detached(priority: .userInitiated) {
                    try Task.checkCancellation()
                    let receipt = try ReceiptComposer.compose(
                        photos: committedSession.photos,
                        sessionIdentifier: committedSession.sessionIdentifier,
                        date: committedSession.createdAt,
                        galleryURL: committedSession.galleryURL,
                        format: committedSession.format,
                        eventProfile: committedSession.eventProfile,
                        photoQualityProfile: customerPrintPhotoProfile
                    )
                    guard let receiptImage = UIImage(data: receipt.imagePNGData) else {
                        throw ReceiptComposerError.renderFailed
                    }
                    try Task.checkCancellation()
                    let receiptPhotoPreviewImage = ReceiptComposer.makePhotoSectionPreviewImage(
                        from: receiptImage,
                        previewContentHeight: receipt.previewContentHeight
                    )
                    try Task.checkCancellation()
                    let rasterized = try ThermalImageRasterizer.rasterize(receiptImage, purpose: .completeReceipt)
                    guard let preview = UIImage(data: rasterized.previewPNGData) else {
                        throw ThermalImageRasterizerError.renderFailed
                    }
                    try Task.checkCancellation()
                    return (receipt, receiptImage, receiptPhotoPreviewImage, preview, rasterized)
                }
                let result = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }

                guard !Task.isCancelled else { return }
                guard isCurrentCustomerSession(sessionGeneration) else {
                    debugLog("[Session] ignored stale receipt composition result")
                    return
                }

                composedReceipt = result.0
                receiptImage = result.1
                receiptPhotoPreviewImage = result.2
                thermalReceiptPreview = result.3
                receiptRasterizedImage = result.4
                persistRecoverySnapshot(stage: .receiptComposed)
                state = .receiptPreview
                statusMessage = "Receipt ready: \(result.0.width) x \(result.0.height) pixels. Photo profile: \(result.0.photoQualityProfile.displayName)."
                if enqueueUpload {
                    startGalleryUpload(committedSession: committedSession, receiptImage: result.1)
                }
                archiveCommittedSession(
                    committedSession,
                    composedReceipt: result.0,
                    receiptPreviewPNGData: result.0.imagePNGData,
                    thermalPreviewPNGData: result.4.previewPNGData,
                    rasterizedImage: result.4
                )
                debugLog("Session \(committedSession.sessionIdentifier) receipt ready. Raster bytes: \(result.4.rasterData.count). Sanitized EOT: \(result.4.sanitizationReport.dleEOTPatternCount). Sanitized DC4: \(result.4.sanitizationReport.dleDC4PatternCount).")
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                guard isCurrentCustomerSession(sessionGeneration) else {
                    debugLog("[Session] ignored stale receipt composition failure")
                    return
                }
                state = .error(error.localizedDescription)
                errorMessage = error.localizedDescription
                statusMessage = error.localizedDescription
            }

            isTransitionActive = false
        }
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
        guard printBatchTask == nil else {
            return
        }

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

        let requestedCopies = selectedPrintCopies
        let sessionGeneration = customerSessionGeneration
        let printBatchID = UUID()
        let receiptFingerprint = Self.receiptPayloadFingerprint(for: rasterized)
        currentPrintCopy = 0
        completedPrintCopies = 0
        state = .connectingToPrinter
        statusMessage = "Preparing printer..."
        debugLog("[MULTI-COPY] requestedCopies=\(requestedCopies)")
        debugLog("[PrintBatch \(printBatchID)] session=\(sessionIdentifier ?? "unknown") requestedCopies=\(requestedCopies) receiptFingerprint=\(receiptFingerprint) bytes=\(Self.receiptPayloadByteCount(for: rasterized))")

        printBatchTask = Task { [weak self] in
            guard let self else { return }
            await self.printReceiptCopies(
                requestedCopies: requestedCopies,
                rasterizedImage: rasterized,
                wifiHost: host,
                wifiPort: port,
                sessionGeneration: sessionGeneration,
                printBatchID: printBatchID,
                receiptFingerprint: receiptFingerprint
            )
        }
    }

    func decreasePrintCopies() {
        guard canDecreasePrintCopies else {
            return
        }

        selectedPrintCopies -= 1
    }

    func increasePrintCopies() {
        guard canIncreasePrintCopies else {
            return
        }

        selectedPrintCopies += 1
    }

    func confirmPrinterRestarted() {
        printerCoordinator.confirmPrinterRestarted()
        printerState = .disconnected
        state = .receiptPreview
        statusMessage = "Ask the operator to reconnect and test the printer before printing again."
    }

    func restartCameraForOperator() {
        guard !printerState.isWorking else {
            statusMessage = "Wait for printing to finish before restarting the camera."
            return
        }

        operationalState.recordCameraRestart()
        state = .preparingCamera
        statusMessage = "Camera is getting ready..."
        let sessionGeneration = customerSessionGeneration
        cameraService.restartSession { [weak self] result in
            guard let self else { return }
            guard self.isCurrentCustomerSession(sessionGeneration) else {
                debugLog("[Camera] ignored stale operator restart result")
                return
            }

            switch result {
            case .success:
                isCameraRunning = true
                statusMessage = "Camera ready."
                state = .cameraReady
            case .failure:
                isCameraRunning = false
                statusMessage = "Camera needs operator attention."
                state = .error("Camera needs operator attention.")
            }
        }
    }

    func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            operationalState.handleScenePhaseActive()
            refreshPendingUploads()
            if state == .preparingCamera || state == .cameraReady {
                restartCameraForOperator()
            }
        case .inactive:
            if case .countdown = state {
                activeTask?.cancel()
                activeTask = nil
                state = .cameraReady
                statusMessage = "Camera ready."
                isTransitionActive = false
            }
        case .background:
            cameraService.stopSession()
            isCameraRunning = false
            if case .countdown = state {
                activeTask?.cancel()
                activeTask = nil
                state = .cameraReady
                statusMessage = "Camera paused. Tap when ready."
                isTransitionActive = false
            }
        @unknown default:
            break
        }
    }

    func resetAfterDone() {
        resetToWelcome()
    }

    func retryQueuedGalleryUploads() {
        refreshPendingUploads()
        guard queueRetryTask == nil, !uploadPhase.isWorking, !pendingUploadSummaries.isEmpty else {
            return
        }

        guard let deviceToken = try? credentialStore.loadDeviceToken() else {
            if galleryToken == nil {
                uploadStatusMessage = "Gallery retry needs the saved device token."
            }
            return
        }

        queueRetryTask = Task {
            defer {
                queueRetryTask = nil
            }
            do {
                let results = try await uploadService.retryPendingQueue(deviceToken: deviceToken)
                for result in results where isCurrentGalleryToken(result.galleryToken) {
                    setUploadPhase(.success(result.galleryURL), message: "Your photos are ready.", for: result.galleryToken)
                }
                refreshPendingUploads()
            } catch {
                if let queueFailure = error as? GalleryPendingQueueFailure {
                    applyUploadError(queueFailure.underlyingError, customerFacing: true, for: queueFailure.galleryToken)
                } else if galleryToken == nil {
                    applyUploadError(error, customerFacing: false)
                }
                refreshPendingUploads()
            }
        }
    }

    private func prepareCamera(completion: @escaping (Result<Void, CameraServiceError>) -> Void) {
        scheduleCameraReadinessWatchdog()
        switch cameraService.authorizationStatus() {
        case .authorized:
            cameraService.configureAndStart { [weak self] result in
                self?.cancelCameraReadinessWatchdog()
                completion(result)
            }
        case .notDetermined:
            Task {
                let granted = await cameraService.requestAccess()
                if granted {
                    self.cameraService.configureAndStart { [weak self] result in
                        self?.cancelCameraReadinessWatchdog()
                        completion(result)
                    }
                } else {
                    self.cancelCameraReadinessWatchdog()
                    completion(.failure(.permissionDenied))
                }
            }
        case .denied:
            cancelCameraReadinessWatchdog()
            completion(.failure(.permissionDenied))
        case .restricted:
            cancelCameraReadinessWatchdog()
            completion(.failure(.permissionRestricted))
        @unknown default:
            cancelCameraReadinessWatchdog()
            completion(.failure(.configurationFailed("Camera permission could not be determined.")))
        }
    }

    private func startCameraForSequence() {
        isTransitionActive = true
        state = .preparingCamera
        let sessionGeneration = customerSessionGeneration
        prepareCamera { [weak self] result in
            guard let self else { return }
            guard self.isCurrentCustomerSession(sessionGeneration) else {
                debugLog("[Session] ignored stale sequence camera preparation callback")
                return
            }
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
        let sessionGeneration = customerSessionGeneration
        prepareCamera { [weak self] result in
            guard let self else { return }
            guard self.isCurrentCustomerSession(sessionGeneration) else {
                debugLog("[Session] ignored stale retake camera preparation callback")
                return
            }
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
        let sessionGeneration = customerSessionGeneration
        activeTask = Task {
            let targetCount = requiredPhotoCount
            for index in startIndex..<targetCount {
                guard !Task.isCancelled else { return }
                guard isCurrentCustomerSession(sessionGeneration) else {
                    debugLog("[Session] stopped stale automatic sequence")
                    return
                }
                await countdownAndCapture(index: index, replacing: false, sessionGeneration: sessionGeneration)
                if case .error = state {
                    return
                }

                guard !Task.isCancelled else { return }
                guard isCurrentCustomerSession(sessionGeneration) else {
                    debugLog("[Session] stopped stale automatic sequence delay")
                    return
                }
                if index < targetCount - 1 {
                    state = .betweenPhotos(nextPhotoIndex: index + 1)
                    statusMessage = "Next photo in a moment."
                    try? await Task.sleep(for: .seconds(BoothConfiguration.interPhotoDelay))
                }
            }

            guard !Task.isCancelled else { return }
            guard isCurrentCustomerSession(sessionGeneration) else {
                debugLog("[Session] ignored stale automatic sequence completion")
                return
            }
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
        let sessionGeneration = customerSessionGeneration
        activeTask = Task {
            await countdownAndCapture(index: index, replacing: true, sessionGeneration: sessionGeneration)
            if case .error = state {
                return
            }

            guard !Task.isCancelled else { return }
            guard isCurrentCustomerSession(sessionGeneration) else {
                debugLog("[Session] ignored stale retake completion")
                return
            }
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

    private func countdownAndCapture(index: Int, replacing: Bool, sessionGeneration: Int) async {
        for value in stride(from: BoothConfiguration.countdownSeconds, through: 1, by: -1) {
            guard !Task.isCancelled else { return }
            guard isCurrentCustomerSession(sessionGeneration) else {
                debugLog("[Session] stopped stale countdown")
                return
            }
            state = .countdown(photoIndex: index, value: value)
            statusMessage = replacing ? "Retaking photo \(index + 1)." : "Photo \(index + 1) of \(requiredPhotoCount)."
            try? await Task.sleep(for: .seconds(1))
        }

        guard !Task.isCancelled else { return }
        guard isCurrentCustomerSession(sessionGeneration) else {
            debugLog("[Session] ignored stale capture start")
            return
        }
        state = .capturing(photoIndex: index)
        statusMessage = "Capturing photo \(index + 1)."

        do {
            let image = try await capturePhoto()
            guard !Task.isCancelled else { return }
            guard isCurrentCustomerSession(sessionGeneration) else {
                debugLog("[Session] ignored stale captured photo")
                return
            }

            if replacing, capturedPhotos.indices.contains(index) {
                capturedPhotos[index] = image
            } else if capturedPhotos.count == index {
                capturedPhotos.append(image)
            } else if capturedPhotos.indices.contains(index) {
                capturedPhotos[index] = image
            }

            transientCapturedPhoto = image
            persistRecoverySnapshot(stage: .photosCaptured)
            if replacing {
                debugLog("[Retake] replaced photo index \(index + 1)")
            }
            debugLog("Session \(sessionIdentifier ?? "unknown") captured photo \(index + 1).")
            try? await Task.sleep(for: .seconds(BoothConfiguration.capturedPhotoDisplayDuration))
            guard isCurrentCustomerSession(sessionGeneration) else {
                debugLog("[Session] ignored stale captured photo display completion")
                return
            }
            transientCapturedPhoto = nil
        } catch {
            guard isCurrentCustomerSession(sessionGeneration) else {
                debugLog("[Session] ignored stale capture failure")
                return
            }
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
                    continuation.resume(returning: BoothPhotoProcessor.normalizedPortraitPhoto(from: image))
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func showThankYou() {
        state = .thankYou
        statusMessage = "Scan the QR to view and save your photos."
        recoveryStore?.clear(sessionIdentifier: sessionIdentifier)
        operationalState.recordSessionCompleted()
        debugLog("[Session] session completed")
        debugLog("Session \(sessionIdentifier ?? "unknown") printed successfully.")
    }

    private func resetToWelcome() {
        debugLog("[Session] reset requested")
        cancelTasks()
        invalidateCustomerSessionCallbacks()
        cameraService.stopSession()
        isCameraRunning = false
        clearCustomerData()
        state = .welcome
        statusMessage = "Ready."
        errorMessage = nil
        printerState = .disconnected
        isTransitionActive = false
        debugLog("[Session] session state cleared")
    }

    private func clearCustomerData() {
        capturedPhotos.removeAll()
        transientCapturedPhoto = nil
        composedReceipt = nil
        receiptImage = nil
        receiptPhotoPreviewImage = nil
        thermalReceiptPreview = nil
        receiptRasterizedImage = nil
        sessionIdentifier = nil
        sessionCreatedAt = nil
        sessionEventProfile = nil
        galleryToken = nil
        galleryURL = nil
        galleryQRCodeImage = nil
        committedGallerySession = nil
        uploadPhase = .idle
        uploadStatusMessage = "Gallery upload has not started."
        samplePhotoCount = 0
        selectedBoothFormat = nil
        selectedPrintCopies = 1
        currentPrintCopy = 0
        completedPrintCopies = 0
    }

    private func cancelTasks() {
        activeTask?.cancel()
        activeTask = nil
        printBatchTask?.cancel()
        printBatchTask = nil
        cameraWatchdogTask?.cancel()
        cameraWatchdogTask = nil
    }

    private func beginNewCustomerSession() {
        customerSessionGeneration += 1
#if DEBUG
        debugSessionSequence += 1
        currentDebugSessionSequence = debugSessionSequence
        debugLog("[Session] new session initialized #\(debugSessionSequence)")
#endif
    }

    private func invalidateCustomerSessionCallbacks() {
        customerSessionGeneration += 1
#if DEBUG
        if let currentDebugSessionSequence {
            debugLog("[Session] invalidated session #\(currentDebugSessionSequence)")
        }
        currentDebugSessionSequence = nil
#endif
    }

    private func isCurrentCustomerSession(_ generation: Int) -> Bool {
        customerSessionGeneration == generation
    }

    private func printReceiptCopies(
        requestedCopies: Int,
        rasterizedImage: ThermalRasterizedImage,
        wifiHost: String,
        wifiPort: UInt16,
        sessionGeneration: Int,
        printBatchID: UUID,
        receiptFingerprint: String
    ) async {
        defer {
            if isCurrentCustomerSession(sessionGeneration) {
                printBatchTask = nil
            }
        }

        for copy in 1...requestedCopies {
            guard !Task.isCancelled else { return }
            guard isCurrentCustomerSession(sessionGeneration) else {
                debugLog("[Session] stopped stale print batch")
                return
            }

            let copyRequestedAt = Date()
            currentPrintCopy = copy
            state = .printing
            statusMessage = requestedCopies == 1 ? "Printing your keepsake..." : "Printing copy \(copy) of \(requestedCopies)..."
            debugLog("[MULTI-COPY] startingCopy=\(copy) totalCopies=\(requestedCopies)")
            debugLog("[PrintBatch \(printBatchID)] copy=\(copy)/\(requestedCopies) start fingerprint=\(receiptFingerprint)")

            let result = await printSingleReceiptCopy(
                rasterizedImage: rasterizedImage,
                wifiHost: wifiHost,
                wifiPort: wifiPort,
                requestedCopies: requestedCopies,
                sessionGeneration: sessionGeneration,
                copy: copy,
                copyRequestedAt: copyRequestedAt,
                batchID: printBatchID
            )
            let completionReportedAt = Date()

            guard !Task.isCancelled else { return }
            guard isCurrentCustomerSession(sessionGeneration) else {
                debugLog("[Session] ignored stale print copy result")
                return
            }

            switch result {
            case .success:
                completedPrintCopies = copy
                debugLog("[MULTI-COPY] completedCopy=\(copy)")
                debugLog("[PrintBatch \(printBatchID)] copy=\(copy)/\(requestedCopies) complete fingerprint=\(receiptFingerprint) elapsed=\(Self.formatDuration(completionReportedAt.timeIntervalSince(copyRequestedAt)))")
                if copy < requestedCopies {
                    debugLog("[PrintBatch] copy \(copy + 1) requested immediately after copy \(copy) completion")
                }
            case .failure:
                let message = "\(completedPrintCopies) of \(requestedCopies) copies printed. Printer needs attention before continuing."
                debugLog("[MULTI-COPY] failedCopy=\(copy) completedCopies=\(completedPrintCopies) requestedCopies=\(requestedCopies)")
                debugLog("[PrintBatch] copy \(copy) failed after \(Self.formatDuration(completionReportedAt.timeIntervalSince(copyRequestedAt))). completed=\(completedPrintCopies) requested=\(requestedCopies). stopping batch.")
                if printerState.requiresPrinterRestart {
                    state = .recoveryRequired(message)
                } else {
                    state = .receiptPreview
                    printerState = .failure(message)
                }
                statusMessage = message
                return
            }
        }

        showThankYou()
    }

    private func printSingleReceiptCopy(
        rasterizedImage: ThermalRasterizedImage,
        wifiHost: String,
        wifiPort: UInt16,
        requestedCopies: Int,
        sessionGeneration: Int,
        copy: Int,
        copyRequestedAt: Date,
        batchID: UUID? = nil
    ) async -> Result<Void, Error> {
        await withCheckedContinuation { continuation in
            debugLog("[PrintBatch] copy \(copy) transport start after \(Self.formatDuration(Date().timeIntervalSince(copyRequestedAt)))")
            persistRecoverySnapshot(stage: .printStatusUnknown)
            printerCoordinator.printReceipt(
                rasterizedImage: rasterizedImage,
                wifiHost: wifiHost,
                wifiPort: wifiPort,
                sessionIdentifier: sessionIdentifier ?? "unknown",
                source: .liveCustomer,
                copyIndex: copy,
                copyCount: requestedCopies,
                batchID: batchID ?? UUID(),
                transportPolicy: .safeIntegrity
            ) { [weak self] printerState in
                guard let self else { return }
                guard self.isCurrentCustomerSession(sessionGeneration) else {
                    debugLog("[Session] ignored stale printer state callback")
                    return
                }
                self.printerState = printerState

                switch printerState {
                case .connecting, .connected:
                    self.state = .connectingToPrinter
                    self.statusMessage = "Preparing printer..."
                case .printing, .sendingHeading, .sendingPhotograph, .finalizingAndCutting, .printerProcessing, .coolingDown:
                    if case .sendingPhotograph = printerState {
                        debugLog("[PrintBatch] copy \(copy) first payload bytes phase after \(Self.formatDuration(Date().timeIntervalSince(copyRequestedAt)))")
                    }
                    self.state = .printing
                    self.statusMessage = requestedCopies == 1 ? "Printing your keepsake..." : "Printing copy \(self.currentPrintCopy) of \(requestedCopies)..."
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
            } completion: { result in
                debugLog("[PrintBatch] copy \(copy) transport completion reported after \(Self.formatDuration(Date().timeIntervalSince(copyRequestedAt)))")
                continuation.resume(returning: result)
            }
        }
    }

    private static func formatDuration(_ duration: TimeInterval) -> String {
        "\(String(format: "%.2f", duration))s"
    }

    private func handleCameraEvent(_ event: CameraServiceEvent) {
        switch event {
        case .interrupted:
            if state == .cameraReady || isCameraRunning {
                isCameraRunning = false
                statusMessage = "Camera is getting ready..."
            }
        case .interruptionEnded:
            if state == .cameraReady || state == .preparingCamera {
                restartCameraForOperator()
            }
        case .runtimeError(_, let shouldRestart):
            isCameraRunning = false
            if shouldRestart, state == .cameraReady || state == .preparingCamera {
                restartCameraForOperator()
            } else if state.isActiveSession {
                statusMessage = "Camera needs operator attention."
            }
        }
    }

    private func scheduleCameraReadinessWatchdog() {
        cameraWatchdogTask?.cancel()
        let generation = customerSessionGeneration
        cameraWatchdogTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.isCurrentCustomerSession(generation), self.state == .preparingCamera else {
                    return
                }
                self.isTransitionActive = false
                self.isCameraRunning = false
                self.statusMessage = "Camera needs operator attention."
                self.state = .error("Camera needs operator attention.")
            }
        }
    }

    private func cancelCameraReadinessWatchdog() {
        cameraWatchdogTask?.cancel()
        cameraWatchdogTask = nil
    }

    private func persistRecoverySnapshot(stage: AppRecoveryStage) {
        guard let sessionIdentifier,
              let selectedBoothFormat,
              let createdAt = sessionCreatedAt else {
            return
        }

        let photos = capturedPhotos.compactMap { AppRecoveryStore.photoData(from: $0) }
        let snapshot = AppRecoverySnapshot(
            schemaVersion: AppRecoverySnapshot.schemaVersion,
            sessionIdentifier: sessionIdentifier,
            createdAt: createdAt,
            format: selectedBoothFormat,
            eventProfile: sessionEventProfile,
            galleryToken: galleryToken,
            galleryURL: galleryURL,
            photoJPEGData: photos,
            receiptPreviewPNGData: composedReceipt?.imagePNGData,
            thermalPreviewPNGData: receiptRasterizedImage?.previewPNGData,
            rasterFingerprint: receiptRasterizedImage.map { Self.receiptPayloadFingerprint(for: $0) },
            stage: stage,
            updatedAt: Date()
        )
        recoveryStore?.save(snapshot)
        operationalState.refresh()
    }

    private func archiveCommittedSession(
        _ committedSession: CommittedGallerySession,
        composedReceipt: ComposedReceipt,
        receiptPreviewPNGData: Data,
        thermalPreviewPNGData: Data,
        rasterizedImage: ThermalRasterizedImage
    ) {
        Task.detached(priority: .utility) {
            do {
                let thumbnails = try committedSession.photos.map {
                    try Self.makeRecentSessionThumbnailData(from: $0)
                }
                let payload = RecentSessionArchivePayload(
                    committedSession: committedSession,
                    composedReceipt: composedReceipt,
                    receiptPreviewPNGData: receiptPreviewPNGData,
                    thermalPreviewPNGData: thermalPreviewPNGData,
                    rasterizedImage: rasterizedImage,
                    photoThumbnailData: thumbnails
                )
                try RecentSessionArchiveStore().save(payload)
                debugLog("[RecentSessions] archived \(committedSession.sessionIdentifier) fingerprint=\(RecentSessionArchiveStore.rasterFingerprint(for: rasterizedImage))")
            } catch {
                debugLog("[RecentSessions] archive failed for \(committedSession.sessionIdentifier): \(error.localizedDescription)")
            }
        }
    }

    nonisolated private static func makeRecentSessionThumbnailData(from image: UIImage, maxLongestSide: Int = 220) throws -> Data {
        let normalized = image.normalizedForGalleryUpload()
        let resized = normalized.resizedForGalleryUpload(maxLongestSide: maxLongestSide)
        guard let data = resized.jpegData(compressionQuality: 0.72) else {
            throw GalleryUploadError.imageEncoding("Recent session thumbnail could not be encoded.")
        }
        return data
    }

    private static func receiptPayloadFingerprint(for rasterizedImage: ThermalRasterizedImage) -> String {
        receiptPayloadData(for: rasterizedImage).shortSHA256Fingerprint
    }

    private static func receiptPayloadByteCount(for rasterizedImage: ThermalRasterizedImage) -> Int {
        receiptPayloadData(for: rasterizedImage).count
    }

    private static func receiptPayloadData(for rasterizedImage: ThermalRasterizedImage) -> Data {
        ThermalImageRasterizer.receiptPrintHeading()
            + rasterizedImage.rasterCommand
            + ThermalImageRasterizer.photoTestFinishing()
    }

    private func startGalleryUpload(committedSession: CommittedGallerySession, receiptImage: UIImage) {
        guard GalleryUploadSessionIsolationPolicy.canStartPreparation(
            activeTaskTokens: Set(galleryUploadTasks.keys),
            newGalleryToken: committedSession.galleryToken
        ) else {
            return
        }
        setUploadPhase(.preparing, message: "Preparing your gallery...", for: committedSession.galleryToken)
        galleryUploadTasks[committedSession.galleryToken] = Task {
            defer {
                galleryUploadTasks[committedSession.galleryToken] = nil
            }
            do {
                let payload = try await uploadService.prepareAndPersistGallery(
                    photos: committedSession.photos,
                    composedReceipt: receiptImage,
                    sessionID: committedSession.sessionIdentifier,
                    createdAt: committedSession.createdAt,
                    galleryToken: committedSession.galleryToken
                )
                refreshPendingUploads()

                guard let deviceToken = try credentialStore.loadDeviceToken() else {
                    setUploadPhase(
                        .retryAvailable,
                        message: "Your gallery is queued. This QR will work once the connection is restored.",
                        for: payload.galleryToken
                    )
                    return
                }

                setUploadPhase(.uploading, message: "Uploading your photos...", for: payload.galleryToken)
                let result = try await uploadService.uploadPendingGallery(galleryToken: payload.galleryToken, deviceToken: deviceToken)
                setUploadPhase(.success(result.galleryURL), message: "Your photos are ready.", for: result.galleryToken)
                refreshPendingUploads()
                if !pendingUploadSummaries.isEmpty {
                    retryQueuedGalleryUploads()
                }
            } catch {
                applyUploadError(error, customerFacing: true, for: committedSession.galleryToken)
                refreshPendingUploads()
            }
        }
    }

    private func applyUploadError(_ error: Error, customerFacing: Bool, for galleryToken: String? = nil) {
        if let galleryToken, !isCurrentGalleryToken(galleryToken) {
            return
        }

        if let uploadError = error as? GalleryUploadError {
            switch uploadError {
            case .pendingNoInternet, .network, .deliveryUnknown, .timeout:
                uploadPhase = uploadError == .deliveryUnknown ? .deliveryUnknown : .pendingNoInternet
                uploadStatusMessage = customerFacing ? "Your gallery is queued. This QR will work once the connection is restored." : uploadError.localizedDescription
            case .missingDeviceToken, .invalidDeviceToken, .uploadAlreadyActive:
                uploadPhase = .retryAvailable
                uploadStatusMessage = customerFacing ? "Your gallery is queued. This QR will work once the connection is restored." : uploadError.localizedDescription
            case .configuration, .unauthorized, .server, .conflictManualInspection, .requestTooLarge:
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

    private func setUploadPhase(_ phase: GalleryUploadPhase, message: String, for galleryToken: String) {
        guard isCurrentGalleryToken(galleryToken) else {
            return
        }
        uploadPhase = phase
        uploadStatusMessage = message
    }

    private func isCurrentGalleryToken(_ token: String) -> Bool {
        GalleryUploadSessionIsolationPolicy.shouldApplyEvent(eventGalleryToken: token, currentGalleryToken: galleryToken)
    }

}

struct CommittedGallerySession {
    let sessionIdentifier: String
    let createdAt: Date
    let galleryToken: String
    let galleryURL: URL
    let photos: [UIImage]
    let format: BoothFormat
    let eventProfile: EventProfile?
}

enum GalleryUploadSessionIsolationPolicy {
    static func canStartPreparation(activeTaskTokens: Set<String>, newGalleryToken: String) -> Bool {
        !activeTaskTokens.contains(newGalleryToken)
    }

    static func shouldApplyEvent(eventGalleryToken: String, currentGalleryToken: String?) -> Bool {
        currentGalleryToken == eventGalleryToken
    }
}

nonisolated private func debugLog(_ message: String) {
#if DEBUG
    print("[BoothSessionViewModel] \(message)")
#endif
}
