//
//  BoothSessionViewModel.swift
//  PocketPixelsBooth
//
//  Created by marc on 8/30/26.
//

import OSLog
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
    @Published private(set) var isPrintBatchActive = false
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
    @Published private(set) var customerEventProfile = EventProfileStore.load().normalized()
    /// Passport keepsake details for the current customer only. Cleared with every reset.
    @Published var passportDraft = PassportSessionData.empty
    /// Rendered Passport cards shown on the preview screen; built once per visit, never per edit.
    @Published private(set) var passportPreviewImage: UIImage?
    @Published private(set) var passportPreviewFailed = false

    let cameraService = CameraService()

    private let printerService = PrinterNetworkService()
    private let printerCoordinator = PrinterCoordinator.shared
    private let uploadService = GoogleDriveGalleryUploadService()
    private let credentialStore = DeviceCredentialStore()
    private let recoveryStore = try? AppRecoveryStore()
    /// Durable archive commit for the current session; resolves to nil on success or an error
    /// description on failure. See SessionArchiveCommitter for the durability contract.
    private var archiveCommitTask: Task<String?, Never>?
    private var archiveCommitPayload: RecentSessionArchivePayload?
    private let operationalState = EventOperationalState.shared
    private var activeTask: Task<Void, Never>?
    private var printBatchTask: Task<Void, Never>?
    private var cameraWatchdogTask: Task<Void, Never>?
    private var galleryUploadTasks: [String: Task<Void, Never>] = [:]
    private var queueRetryTask: Task<Void, Never>?
    private var passportPreviewTask: Task<Void, Never>?
    private var isTransitionActive = false
    private var retakeIndex: Int?
    private var isOperatorCameraRestartRunning = false
    private var sessionCreatedAt: Date?
    private var sessionEventProfile: EventProfile?
    private var committedGallerySession: CommittedGallerySession?
    private var customerSessionGeneration = 0
    private var customerPrintPhotoProfile = CustomerReceiptPhotoToneStore.load().profile
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
        guard canContinueFromReview else { return false }
        // Passport commits only from its preview, after details and signature.
        return selectedBoothFormat != .passport || state == .passportPreview
    }

    var canContinueFromReview: Bool {
        selectedBoothFormat != nil && capturedPhotos.count == requiredPhotoCount && !isTransitionActive && committedGallerySession == nil
    }

    var isPassportSession: Bool {
        selectedBoothFormat == .passport
    }

    var canReturnToReview: Bool {
        committedGallerySession == nil && !printerState.isWorking && printBatchTask == nil
    }

    var supportedPrintCopies: [Int] {
        Array(Self.printCopyRange)
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

    var customerTheme: CustomerScreenTheme {
        customerEventProfile.activeCustomerSnapshot?.customerTheme ?? .classic
    }

    var isCustomerResetSafe: Bool {
        CustomerIdleResetPolicy.isEligible(
            state: state,
            printerWorking: printerState.isWorking,
            printBatchActive: isPrintBatchActive,
            recoveryLocked: printerCoordinator.requiresRecovery,
            unresolvedPrint: operationalState.hasUnresolvedPrint
        )
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
        guard state == .welcome, !isTransitionActive else {
            return
        }

        operationalState.refresh()
        refreshCustomerExperience()
        guard !printerCoordinator.requiresRecovery, !operationalState.hasUnresolvedPrint else {
            state = .recoveryRequired("Printer needs operator attention.")
            return
        }
        cancelTasks()
        clearCustomerData()
        customerPrintPhotoProfile = CustomerReceiptPhotoToneStore.load().profile
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
        let savedEventProfile = EventProfileStore.load().normalized()
        customerEventProfile = savedEventProfile
        sessionEventProfile = savedEventProfile.activeReceiptSnapshot
        passportDraft = format == .passport
            ? PassportSessionData(configuration: PassportConfiguration.effective(for: sessionEventProfile))
            : .empty
        resetPassportPreview()
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
        guard !printerState.isWorking, !isPrintBatchActive,
              !printerCoordinator.requiresRecovery, !operationalState.hasUnresolvedPrint else {
            statusMessage = "Printer needs operator attention before this session can be cleared."
            return
        }
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

        capturedPhotos.append(Self.normalizedCapture(image, format: selectedBoothFormat))
        samplePhotoCount = capturedPhotos.count
        statusMessage = "Development sample photo \(samplePhotoCount) of \(requiredPhotoCount) loaded."

        if capturedPhotos.count == requiredPhotoCount {
            state = .review
        } else {
            state = .cameraReady
        }
    }

    /// Review's Continue: Passport moves on to its details step, other formats compose directly.
    func continueFromReview() {
        guard canContinueFromReview else { return }
        if selectedBoothFormat == .passport {
            showPassportDetails()
        } else {
            continueToReceipt()
        }
    }

    func showPassportDetails() {
        guard selectedBoothFormat == .passport, canContinueFromReview else { return }
        resetPassportPreview()
        statusMessage = "Add your name and an optional note."
        state = .passportDetails
    }

    func continueFromPassportDetails() {
        guard state == .passportDetails, canContinueFromReview else { return }
        passportDraft = passportDraft.normalized(referenceDate: sessionCreatedAt ?? Date())
        statusMessage = "Add your signature."
        state = .passportSignature
    }

    func redoPassportSignature() {
        guard selectedBoothFormat == .passport, canContinueFromReview else { return }
        resetPassportPreview()
        passportDraft.signature = .empty
        statusMessage = "Add your signature."
        state = .passportSignature
    }

    func backToPassportDetails() {
        guard state == .passportSignature || state == .passportPreview else { return }
        showPassportDetails()
    }

    func updatePassportSignature(_ signature: PassportSignature) {
        guard state == .passportSignature else { return }
        passportDraft.signature = signature.normalized()
    }

    /// Event-level Photo Pass values filled in for the customer, shown read-only on the details
    /// screen. Uses the same resolution as the printed receipt.
    var photoPassAutoFilledContent: PhotoPassContent {
        PhotoPassContent.resolve(passport: passportDraft, eventProfile: sessionEventProfile, referenceDate: sessionCreatedAt ?? Date())
    }

    func continueFromPassportSignature() {
        guard state == .passportSignature, canContinueFromReview else { return }
        statusMessage = "Here's your Photo Pass."
        state = .passportPreview
        renderPassportPreview()
    }

    func continueToReceipt() {
        if selectedBoothFormat == .passport, state != .passportPreview {
            continueFromReview()
            return
        }
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
            eventProfile: sessionEventProfile,
            passport: selectedBoothFormat == .passport ? passportDraft.committed(at: receiptDate) : nil
        )
        passportPreviewTask?.cancel()
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
                        passport: committedSession.passport,
                        photoQualityProfile: customerPrintPhotoProfile
                    )
                    guard let receiptImage = UIImage(data: receipt.imagePNGData) else {
                        throw ReceiptComposerError.renderFailed
                    }
                    try Task.checkCancellation()
                    let galleryReceiptImage = try Self.galleryReceiptImage(
                        for: committedSession,
                        printedReceiptImage: receiptImage,
                        photoQualityProfile: customerPrintPhotoProfile
                    )
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
                    return (receipt, receiptImage, receiptPhotoPreviewImage, preview, rasterized, galleryReceiptImage)
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
                    startGalleryUpload(committedSession: committedSession, receiptImage: result.5)
                }
                startArchiveCommit(
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

    /// The gallery copy of a Passport / Photo Pass receipt keeps the photos, branding and public
    /// event details but never the customer's name, note, signature or legacy personal fields.
    nonisolated static func galleryReceiptImage(
        for committedSession: CommittedGallerySession,
        printedReceiptImage: UIImage,
        photoQualityProfile: PocketPixelsThermalPhotoProfile
    ) throws -> UIImage {
        guard committedSession.format == .passport, let passport = committedSession.passport else {
            return printedReceiptImage
        }
        let redacted = try ReceiptComposer.compose(
            photos: committedSession.photos,
            sessionIdentifier: committedSession.sessionIdentifier,
            date: committedSession.createdAt,
            galleryURL: committedSession.galleryURL,
            format: committedSession.format,
            eventProfile: committedSession.eventProfile,
            passport: passport.redactedForGallery(),
            photoQualityProfile: photoQualityProfile
        )
        guard let image = UIImage(data: redacted.imagePNGData) else {
            throw ReceiptComposerError.renderFailed
        }
        return image
    }

    private func renderPassportPreview() {
        resetPassportPreview()
        guard selectedBoothFormat == .passport,
              capturedPhotos.count == BoothFormat.passport.photoCount else {
            passportPreviewFailed = true
            return
        }

        let date = sessionCreatedAt ?? Date()

        let photos = capturedPhotos
        let passport = passportDraft
        let eventProfile = sessionEventProfile
        let photoProfile = customerPrintPhotoProfile
        let sessionGeneration = customerSessionGeneration
        passportPreviewTask = Task {
            let worker = Task.detached(priority: .userInitiated) { () throws -> UIImage in
                let receipt = try ReceiptComposer.compose(
                    photos: photos,
                    sessionIdentifier: "PASSPORT-PREVIEW",
                    date: date,
                    galleryURL: nil,
                    format: .passport,
                    eventProfile: eventProfile,
                    passport: passport,
                    photoQualityProfile: photoProfile
                )
                guard let image = UIImage(data: receipt.imagePNGData) else {
                    throw ReceiptComposerError.renderFailed
                }
                try Task.checkCancellation()
                // previewContentHeight is the card bottom + 12; stop above the footer divider (+10).
                return ReceiptComposer.makePhotoSectionPreviewImage(from: image, previewContentHeight: receipt.previewContentHeight - 4)
            }
            let image = try? await withTaskCancellationHandler {
                try await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled,
                  isCurrentCustomerSession(sessionGeneration),
                  state == .passportPreview,
                  passportDraft == passport else {
                debugLog("[Passport] ignored stale preview render")
                return
            }
            passportPreviewImage = image
            passportPreviewFailed = image == nil
        }
    }

    private func resetPassportPreview() {
        passportPreviewTask?.cancel()
        passportPreviewTask = nil
        passportPreviewImage = nil
        passportPreviewFailed = false
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
        isPrintBatchActive = true
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

    func resumeAfterOperatorRecovery() {
        guard case .recoveryRequired = state,
              !printerCoordinator.requiresRecovery, !printerCoordinator.isWorking,
              !operationalState.hasUnresolvedPrint else { return }
        guard receiptRasterizedImage != nil else { resetToWelcome(); return }
        printerState = .disconnected
        state = .receiptPreview
        statusMessage = "Operator recovery confirmed. Reconnect the printer before choosing to print."
    }

    func restartCameraForOperator() {
        guard !printerState.isWorking, !isOperatorCameraRestartRunning else {
            statusMessage = "Wait for the current operation before restarting the camera."
            return
        }

        isOperatorCameraRestartRunning = true
        operationalState.recordCameraRestart()
        state = .preparingCamera
        statusMessage = "Camera is getting ready..."
        let sessionGeneration = customerSessionGeneration
        cameraService.restartSession { [weak self] result in
            guard let self else { return }
            self.isOperatorCameraRestartRunning = false
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

    func refreshCustomerExperience() {
        guard state == .welcome || state == .choosingFormat else { return }
        customerEventProfile = EventProfileStore.load().normalized()
    }

    @discardableResult
    func resetAbandonedSessionIfSafe() -> Bool {
        guard isCustomerResetSafe else { return false }
        resetToWelcome()
        return true
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
                    self.cameraService.configureAndStart { result in
                        self.cancelCameraReadinessWatchdog()
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
        let format = selectedBoothFormat
        return try await withCheckedThrowingContinuation { continuation in
            cameraService.capturePhoto { result in
                switch result {
                case .success(let image):
                    continuation.resume(returning: Self.normalizedCapture(image, format: format))
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Passport keeps the full orientation-normalized frame because its two cards crop
    /// differently; every other format keeps the established 3:4 capture crop.
    nonisolated private static func normalizedCapture(_ image: UIImage, format: BoothFormat?) -> UIImage {
        format == .passport
            ? PassportPhotoProcessor.normalizedSource(from: image)
            : BoothPhotoProcessor.normalizedPortraitPhoto(from: image)
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
        refreshCustomerExperience()
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
        passportDraft = .empty
        resetPassportPreview()
        // The detached archive commit is never cancelled (it owns immutable session values); the
        // reference is dropped so a later session can never await another session's archive.
        archiveCommitTask = nil
        archiveCommitPayload = nil
    }

    private func cancelTasks() {
        activeTask?.cancel()
        activeTask = nil
        printBatchTask?.cancel()
        printBatchTask = nil
        isPrintBatchActive = false
        cameraWatchdogTask?.cancel()
        cameraWatchdogTask = nil
        passportPreviewTask?.cancel()
        passportPreviewTask = nil
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
                isPrintBatchActive = false
            }
        }

        // Durability gate: the frozen reprint record must be committed before any bytes.
        if let archiveFailure = await ensureArchiveCommitted() {
            guard isCurrentCustomerSession(sessionGeneration) else { return }
            BoothDiagnostics.archive.error("Print blocked: archive not committed session=\(self.sessionIdentifier ?? "unknown", privacy: .public) error=\(archiveFailure, privacy: .public)")
            let message = "Nothing was printed. This session's reprint record could not be saved. Check iPad storage, then try again."
            state = .receiptPreview
            printerState = .failure(message)
            statusMessage = message
            return
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
            case .failure(let error) where error is PrintCheckpointError:
                // Fail-closed checkpoint: no bytes for this copy, no recovery lock, data kept.
                let message = "\(completedPrintCopies) of \(requestedCopies) copies printed. \(error.localizedDescription)"
                state = .receiptPreview
                printerState = .failure(message)
                statusMessage = message
                return
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
            printerCoordinator.printReceipt(
                rasterizedImage: rasterizedImage,
                wifiHost: wifiHost,
                wifiPort: wifiPort,
                sessionIdentifier: sessionIdentifier ?? "unknown",
                source: .liveCustomer,
                copyIndex: copy,
                copyCount: requestedCopies,
                batchID: batchID ?? UUID(),
                transportPolicy: printerCoordinator.productionReceiptTransportPolicy,
                prePrintCheckpoint: PrePrintCheckpointGate { [weak self] _ in
                    // Runs inside the print spooler immediately before transport. A stale session
                    // or a failed durable write blocks the job before any bytes are sent.
                    guard let self, self.isCurrentCustomerSession(sessionGeneration) else {
                        throw PrintCheckpointError.persistenceFailed("Customer session changed before printing.")
                    }
                    try self.persistCriticalRecoverySnapshot(stage: .printStatusUnknown)
                }
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
            operationalState.invalidateCameraCheck(message: "Camera interrupted. Run preflight after the customer session.")
            if state == .cameraReady || isCameraRunning {
                isCameraRunning = false
                statusMessage = "Camera is getting ready..."
            }
        case .interruptionEnded:
            if state == .cameraReady || state == .preparingCamera {
                restartCameraForOperator()
            }
        case .runtimeError(_, let shouldRestart):
            operationalState.invalidateCameraCheck(message: "Camera needs attention. Run preflight after the customer session.")
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
        guard let snapshot = makeRecoverySnapshot(stage: stage) else { return }
        recoveryStore?.save(snapshot)
        operationalState.refresh()
    }

    /// Fail-closed variant for the pre-print `printStatusUnknown` checkpoint.
    private func persistCriticalRecoverySnapshot(stage: AppRecoveryStage) throws {
        guard let recoveryStore else {
            throw PrintCheckpointError.persistenceFailed(AppRecoveryStoreError.unavailable.localizedDescription)
        }
        guard let snapshot = makeRecoverySnapshot(stage: stage) else {
            throw PrintCheckpointError.persistenceFailed("Session details are incomplete.")
        }
        do {
            try recoveryStore.saveCritical(snapshot)
        } catch {
            throw PrintCheckpointError.persistenceFailed(error.localizedDescription)
        }
        operationalState.refresh()
    }

    private func makeRecoverySnapshot(stage: AppRecoveryStage) -> AppRecoverySnapshot? {
        guard let sessionIdentifier,
              let selectedBoothFormat,
              let createdAt = sessionCreatedAt else {
            return nil
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
            updatedAt: Date(),
            // Only committed Passport data is persisted; in-progress drafts never touch disk.
            passport: committedGallerySession?.passport
        )
        return snapshot
    }

    private func startArchiveCommit(
        _ committedSession: CommittedGallerySession,
        composedReceipt: ComposedReceipt,
        receiptPreviewPNGData: Data,
        thermalPreviewPNGData: Data,
        rasterizedImage: ThermalRasterizedImage
    ) {
        let payload = RecentSessionArchivePayload(
            committedSession: committedSession,
            composedReceipt: composedReceipt,
            receiptPreviewPNGData: receiptPreviewPNGData,
            thermalPreviewPNGData: thermalPreviewPNGData,
            rasterizedImage: rasterizedImage,
            photoThumbnailData: []
        )
        archiveCommitPayload = payload
        archiveCommitTask = Task.detached(priority: .userInitiated) {
            do {
                try SessionArchiveCommitter.commitPrintPayload(payload)
            } catch {
                BoothDiagnostics.archive.error("Archive commit failed session=\(committedSession.sessionIdentifier, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                return error.localizedDescription
            }
            // Thumbnails are display-only and never delay printing.
            Task.detached(priority: .utility) {
                SessionArchiveCommitter.attachThumbnails(for: committedSession)
            }
            return nil
        }
    }

    /// Awaits the current session's durable archive commit, retrying once if it failed.
    /// Returns nil when the frozen reprint record is committed, otherwise an error description.
    private func ensureArchiveCommitted() async -> String? {
        guard let task = archiveCommitTask,
              let payload = archiveCommitPayload,
              payload.committedSession.sessionIdentifier == sessionIdentifier else {
            return SessionArchiveCommitter.CommitError.missingPayload.localizedDescription
        }
        guard let failure = await task.value else { return nil }
        BoothDiagnostics.archive.notice("Retrying archive commit before printing: \(failure, privacy: .public)")
        let retry = Task.detached(priority: .userInitiated) { () -> String? in
            do {
                try SessionArchiveCommitter.commitPrintPayload(payload)
                Task.detached(priority: .utility) {
                    SessionArchiveCommitter.attachThumbnails(for: payload.committedSession)
                }
                return nil
            } catch {
                return error.localizedDescription
            }
        }
        let result = await retry.value
        if result == nil, payload.committedSession.sessionIdentifier == sessionIdentifier {
            archiveCommitTask = Task { nil }
        }
        return result
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
                    galleryToken: committedSession.galleryToken,
                    frozenGalleryURL: committedSession.galleryURL
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
    /// Frozen Passport keepsake data; nil for every other format.
    var passport: PassportSessionData? = nil
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
