//
//  GalleryUploadTestView.swift
//  PocketPixelsBooth
//
//  Created by marc on 8/30/26.
//

#if DEBUG
import PhotosUI
import SwiftUI
import UIKit

struct GalleryUploadTestView: View {
    @Environment(\.openURL) private var openURL

    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var selectedPhotos: [UIImage] = []
    @State private var composedReceipt: ComposedReceipt?
    @State private var receiptImage: UIImage?
    @State private var savedTokenStatus = DeviceCredentialStore().redactedTokenDescription()
    @State private var tokenEntry = ""
    @State private var uploadPhase = GalleryUploadPhase.idle
    @State private var returnedGalleryURL: URL?
    @State private var statusMessage = "Select exactly three photos to prepare a test gallery."
    @State private var connectivityState: GalleryBackendConnectivityState?
    @State private var backendDiagnosticState: GalleryBackendConnectivityState?
    @State private var pendingSummary: GalleryPendingUploadSummary?
    @State private var hasLegacyPendingUpload = false
    @State private var preparedMetrics: GalleryPreparedUploadMetrics?
    @State private var galleryToken: String?
    @State private var galleryURL: URL?
    @State private var qrImage: UIImage?
    @State private var uploadResultStatus: GalleryUploadResultStatus?
    @State private var activeTask: Task<Void, Never>?

    private let credentialStore = DeviceCredentialStore()
    private let uploadService = GoogleDriveGalleryUploadService()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    configurationSection
                    tokenSection
                    photoPickerSection
                    receiptSection
                    uploadSection
                }
                .padding(28)
                .frame(maxWidth: 1_120, alignment: .topLeading)
            }
            .navigationTitle("Cloud Test")
            .onChange(of: selectedPhotoItem) { _, newItem in
                loadPhoto(from: newItem)
            }
            .task {
                runDebugSelfChecks()
                refreshPendingSummary()
            }
            .onDisappear {
                activeTask?.cancel()
                uploadService.cancel()
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Pocket Pixels Cloud Test")
                .font(.largeTitle.weight(.semibold))

            Text("DEBUG-only Google Apps Script gallery upload test. This screen never calls the thermal printer.")
                .foregroundStyle(.secondary)
        }
    }

    private var configurationSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Configuration")
                .font(.headline)

            Text(GoogleDriveGalleryConfiguration.statusMessage())
                .foregroundStyle(isWebAppConfigured ? .green : .red)
                .fixedSize(horizontal: false, vertical: true)

            Button("Test Internet & Backend") {
                testInternetAndBackend()
            }
            .buttonStyle(.bordered)
            .disabled(uploadPhase.isWorking)

            if let connectivityState {
                Text("Reachability: \(connectivityState.diagnosticDescription)")
                    .foregroundStyle(connectivityState.isReachable ? .green : .orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let backendDiagnosticState {
                Text("Deployment: \(backendDiagnosticState.diagnosticDescription)")
                    .foregroundStyle(backendDiagnosticState.isReachable ? .green : .orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var tokenSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Device Token")
                .font(.headline)

            Text(savedTokenStatus)
                .foregroundStyle(credentialStore.hasDeviceToken() ? .green : .secondary)

            SecureField("Device upload token", text: $tokenEntry)
                .textInputAutocapitalization(.never)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 520)

            HStack(spacing: 12) {
                Button("Save Token") {
                    saveToken()
                }
                .buttonStyle(.borderedProminent)

                Button("Remove Token", role: .destructive) {
                    removeToken()
                }
                .buttonStyle(.bordered)
                .disabled(!credentialStore.hasDeviceToken())
            }
        }
        .padding(16)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var photoPickerSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                    Label("Select Photo", systemImage: "photo")
                }
                .buttonStyle(.bordered)
                .disabled(uploadPhase.isWorking || selectedPhotos.count >= BoothConfiguration.photosPerSession)

                Button("Clear Photos") {
                    selectedPhotos.removeAll()
                    composedReceipt = nil
                    receiptImage = nil
                    returnedGalleryURL = nil
                    clearGalleryIdentifiers()
                    uploadPhase = .idle
                    statusMessage = "Select exactly three photos to prepare a test gallery."
                }
                .buttonStyle(.bordered)
                .disabled(uploadPhase.isWorking || selectedPhotos.isEmpty)
            }

            Text("Photos selected: \(selectedPhotos.count) of \(BoothConfiguration.photosPerSession)")
                .foregroundStyle(.secondary)

            HStack(spacing: 14) {
                ForEach(0..<BoothConfiguration.photosPerSession, id: \.self) { index in
                    previewTile(title: "Photo \(index + 1)", image: selectedPhotos.indices.contains(index) ? selectedPhotos[index] : nil)
                }
            }
        }
        .padding(16)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var receiptSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Button(hasLegacyPendingUpload ? "Build New Test Gallery" : "Build Receipt Preview") {
                    buildReceipt()
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedPhotos.count != BoothConfiguration.photosPerSession || uploadPhase.isWorking)

                if let composedReceipt {
                    Text("\(composedReceipt.width) x \(composedReceipt.height) px")
                        .foregroundStyle(.secondary)
                }
            }

            previewTile(title: "Composed Color Receipt", image: receiptImage, maxHeight: 460)
        }
        .padding(16)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var uploadSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Button("Upload Test Gallery") {
                    uploadTestGallery()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canUpload)

                Button("Retry Same Upload") {
                    retrySameUpload()
                }
                .buttonStyle(.bordered)
                .disabled(!canRetrySameUpload)

                Button("Discard Pending Test Upload", role: .destructive) {
                    discardPendingTestUpload()
                }
                .buttonStyle(.bordered)
                .disabled(!canDiscardPending)

                if uploadPhase.isWorking {
                    Button("Cancel Upload", role: .destructive) {
                        cancelUpload()
                    }
                    .buttonStyle(.bordered)
                }
            }

            Text("\(uploadPhase.title): \(statusMessage)")
                .foregroundStyle(statusColor)
                .fixedSize(horizontal: false, vertical: true)

            if let galleryToken, let galleryURL {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Gallery token: \(GalleryTokenGenerator.redacted(galleryToken))")
                        .font(.footnote.monospaced())
                    Text(galleryURL.absoluteString)
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    if let qrImage {
                        Image(uiImage: qrImage)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 220, height: 220)
                            .accessibilityLabel("Gallery QR code")
                    }
                    HStack(spacing: 12) {
                        Button("Open Gallery Link") {
                            openURL(galleryURL)
                        }
                        .buttonStyle(.borderedProminent)

                        Button("Copy Link") {
                            UIPasteboard.general.string = galleryURL.absoluteString
                            statusMessage = "Gallery link copied."
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }

            if let uploadResultStatus {
                Text(uploadResultStatus.displayTitle)
                    .font(.headline)
                    .foregroundStyle(.green)
            }

            if let pendingSummary {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Pending token: \(GalleryTokenGenerator.redacted(pendingSummary.galleryToken))")
                    Text("Pending session: \(pendingSummary.sessionID)")
                    Text("Created: \(pendingSummary.createdAt)")
                    Text("Payload: \(Self.byteString(pendingSummary.payloadSizeBytes))")
                    if let lastSafeError = pendingSummary.lastSafeError {
                        Text("Last safe error: \(lastSafeError)")
                    }
                    Text(pendingSummary.galleryURL.absoluteString)
                        .textSelection(.enabled)
                    if pendingSummary.deliveryState == .deliveryUnknown {
                        Text("The server may have received this upload. Check Google Drive before retrying.")
                            .foregroundStyle(.orange)
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            if hasLegacyPendingUpload {
                Text("A pending upload from an older app version exists. It will not be uploaded automatically. Build a new test gallery to create a Phase 6C request.")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let preparedMetrics {
                metricsView(preparedMetrics)
            } else if let pendingSummary {
                metricsView(pendingSummary.metrics)
            }

            if let returnedGalleryURL, returnedGalleryURL != galleryURL {
                Text(returnedGalleryURL.absoluteString)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func previewTile(title: String, image: UIImage?, maxHeight: CGFloat = 220) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)

            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(.systemBackground))

                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding(6)
                } else {
                    Text("Not ready")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: 320, minHeight: 180, maxHeight: maxHeight)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private var canUpload: Bool {
        isWebAppConfigured
            && credentialStore.hasDeviceToken()
            && selectedPhotos.count == BoothConfiguration.photosPerSession
            && receiptImage != nil
            && !uploadPhase.isWorking
    }

    private var canRetrySameUpload: Bool {
        isWebAppConfigured
            && credentialStore.hasDeviceToken()
            && (pendingSummary != nil || (galleryToken != nil && composedReceipt != nil && receiptImage != nil))
            && !uploadPhase.isWorking
    }

    private var canDiscardPending: Bool {
        (pendingSummary != nil || hasLegacyPendingUpload) && !uploadPhase.isWorking
    }

    private var isWebAppConfigured: Bool {
        (try? GoogleDriveGalleryConfiguration.load()) != nil
    }

    private var statusColor: Color {
        switch uploadPhase {
        case .idle:
            .secondary
        case .checkingInternet, .preparing, .uploading:
            .orange
        case .success:
            .green
        case .pendingNoInternet, .deliveryUnknown, .retryAvailable:
            .orange
        case .unauthorized, .serverRejected:
            .red
        case .failed:
            .red
        }
    }

    private func metricsView(_ metrics: GalleryPreparedUploadMetrics) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(metrics.files) { file in
                Text("\(file.filename): \(Self.byteString(file.decodedBytes))")
            }
            Text("Total decoded: \(Self.byteString(metrics.totalDecodedBytes))")
            Text("Estimated Base64 JSON: \(Self.byteString(metrics.estimatedBase64JSONBytes))")
        }
        .font(.footnote.monospaced())
        .foregroundStyle(.secondary)
    }

    private func saveToken() {
        do {
            try credentialStore.saveDeviceToken(tokenEntry)
            tokenEntry = ""
            savedTokenStatus = credentialStore.redactedTokenDescription()
            statusMessage = "Device token saved."
        } catch {
            statusMessage = error.localizedDescription
            uploadPhase = .failed(error.localizedDescription)
        }
    }

    private func removeToken() {
        do {
            try credentialStore.deleteDeviceToken()
            savedTokenStatus = credentialStore.redactedTokenDescription()
            statusMessage = "Device token removed."
        } catch {
            statusMessage = error.localizedDescription
            uploadPhase = .failed(error.localizedDescription)
        }
    }

    private func runDebugSelfChecks() {
        do {
            try GalleryUploadDebugSelfChecks.run()
        } catch {
            uploadPhase = .failed(error.localizedDescription)
            statusMessage = error.localizedDescription
        }
    }

    private func loadPhoto(from item: PhotosPickerItem?) {
        guard let item else {
            return
        }

        activeTask = Task {
            do {
                guard let data = try await item.loadTransferable(type: Data.self), let image = UIImage(data: data) else {
                    throw ThermalImageRasterizerError.invalidImage
                }

                guard selectedPhotos.count < BoothConfiguration.photosPerSession else {
                    return
                }

                selectedPhotos.append(image)
                composedReceipt = nil
                receiptImage = nil
                returnedGalleryURL = nil
                preparedMetrics = nil
                uploadResultStatus = nil
                clearGalleryIdentifiers()
                uploadPhase = .idle
                statusMessage = "Photo loaded."
                selectedPhotoItem = nil

                if selectedPhotos.count == BoothConfiguration.photosPerSession {
                    buildReceipt()
                }
            } catch {
                statusMessage = error.localizedDescription
                uploadPhase = .failed(error.localizedDescription)
            }
        }
    }

    private func buildReceipt() {
        guard selectedPhotos.count == BoothConfiguration.photosPerSession else {
            uploadPhase = .failed(GalleryUploadError.invalidPhotoCount.localizedDescription)
            statusMessage = GalleryUploadError.invalidPhotoCount.localizedDescription
            return
        }

        uploadPhase = .preparing
        statusMessage = "Preparing receipt preview."
        let photos = selectedPhotos
        activeTask = Task {
            do {
                let sessionDate = Date()
                let sessionID = ReceiptComposer.makeSessionIdentifier(date: sessionDate)
                try ensureGalleryIdentifiers()
                guard let galleryURL else {
                    throw GalleryUploadError.invalidGalleryURL
                }
                let receipt = try await Task.detached(priority: .userInitiated) {
                    try ReceiptComposer.compose(photos: photos, sessionIdentifier: sessionID, date: sessionDate, galleryURL: galleryURL)
                }.value

                guard let image = UIImage(data: receipt.imagePNGData) else {
                    throw ReceiptComposerError.renderFailed
                }

                composedReceipt = receipt
                receiptImage = image
                try ensureGalleryIdentifiers()
                preparedMetrics = try? GoogleDriveGalleryUploadService.preparePayload(
                    photos: photos,
                    composedReceipt: image,
                    sessionID: receipt.sessionIdentifier,
                    createdAt: receipt.createdAt,
                    galleryToken: galleryToken ?? "",
                    customerGalleryBaseURL: CustomerGalleryConfiguration.load().baseURL
                ).metrics
                uploadPhase = .idle
                statusMessage = "Receipt preview ready."
            } catch {
                uploadPhase = .failed(error.localizedDescription)
                statusMessage = error.localizedDescription
            }
        }
    }

    private func testInternetAndBackend() {
        uploadPhase = .checkingInternet
        statusMessage = "Checking internet and Google backend."
        activeTask = Task {
            let state = await uploadService.testBackendConnectivity()
            let diagnosticState = state.isReachable ? await uploadService.testBackendDiagnostic() : state
            connectivityState = state
            backendDiagnosticState = diagnosticState
            uploadPhase = diagnosticState.isReachable ? .idle : .failed(diagnosticState.diagnosticDescription)
            statusMessage = "\(state.diagnosticDescription) \(diagnosticState.diagnosticDescription)"
            refreshPendingSummary()
        }
    }

    private func uploadTestGallery() {
        guard let composedReceipt, let receiptImage else {
            uploadPhase = .failed(GalleryUploadError.missingReceipt.localizedDescription)
            statusMessage = GalleryUploadError.missingReceipt.localizedDescription
            return
        }

        let savedToken: String?
        do {
            savedToken = try credentialStore.loadDeviceToken()
        } catch {
            uploadPhase = .failed(error.localizedDescription)
            statusMessage = error.localizedDescription
            return
        }

        guard let token = savedToken else {
            uploadPhase = .failed(GalleryUploadError.missingDeviceToken.localizedDescription)
            statusMessage = GalleryUploadError.missingDeviceToken.localizedDescription
            return
        }

        uploadPhase = .checkingInternet
        statusMessage = "Checking internet before upload."
        returnedGalleryURL = nil
        uploadResultStatus = nil
        let photos = selectedPhotos

        activeTask = Task {
            do {
                try ensureGalleryIdentifiers()
                guard let galleryToken else {
                    throw GalleryUploadError.invalidGalleryToken
                }

                uploadPhase = .preparing
                statusMessage = "Preparing upload."
                preparedMetrics = try GoogleDriveGalleryUploadService.preparePayload(
                    photos: photos,
                    composedReceipt: receiptImage,
                    sessionID: composedReceipt.sessionIdentifier,
                    createdAt: composedReceipt.createdAt,
                    galleryToken: galleryToken,
                    customerGalleryBaseURL: CustomerGalleryConfiguration.load().baseURL
                ).metrics
                uploadPhase = .uploading
                statusMessage = "Uploading gallery."
                let result = try await uploadService.uploadGallery(
                    photos: photos,
                    composedReceipt: receiptImage,
                    sessionID: composedReceipt.sessionIdentifier,
                    createdAt: composedReceipt.createdAt,
                    galleryToken: galleryToken,
                    deviceToken: token
                )

                returnedGalleryURL = result.galleryURL
                galleryURL = result.galleryURL
                uploadResultStatus = result.status
                uploadPhase = .success(result.galleryURL)
                statusMessage = result.status.displayTitle
                refreshPendingSummary()
            } catch {
                applyUploadError(error)
                refreshPendingSummary()
            }
        }
    }

    private func retrySameUpload() {
        let savedToken: String?
        do {
            savedToken = try credentialStore.loadDeviceToken()
        } catch {
            uploadPhase = .failed(error.localizedDescription)
            statusMessage = error.localizedDescription
            return
        }

        guard let token = savedToken else {
            uploadPhase = .failed(GalleryUploadError.missingDeviceToken.localizedDescription)
            statusMessage = GalleryUploadError.missingDeviceToken.localizedDescription
            return
        }

        uploadPhase = .checkingInternet
        statusMessage = "Checking internet before retry."
        returnedGalleryURL = nil
        uploadResultStatus = nil

        activeTask = Task {
            do {
                let result: GalleryUploadResult
                if pendingSummary != nil {
                    uploadPhase = .uploading
                    statusMessage = "Uploading pending gallery."
                    result = try await uploadService.retryPendingUpload(deviceToken: token)
                } else {
                    guard let composedReceipt, let receiptImage, let galleryToken else {
                        throw GalleryUploadError.invalidGalleryToken
                    }

                    uploadPhase = .uploading
                    statusMessage = "Retrying same upload."
                    result = try await uploadService.uploadGallery(
                        photos: selectedPhotos,
                        composedReceipt: receiptImage,
                        sessionID: composedReceipt.sessionIdentifier,
                        createdAt: composedReceipt.createdAt,
                        galleryToken: galleryToken,
                        deviceToken: token
                    )
                }
                returnedGalleryURL = result.galleryURL
                galleryURL = result.galleryURL
                uploadResultStatus = result.status
                uploadPhase = .success(result.galleryURL)
                statusMessage = result.status.displayTitle
                refreshPendingSummary()
            } catch {
                applyUploadError(error)
                refreshPendingSummary()
            }
        }
    }

    private func cancelUpload() {
        activeTask?.cancel()
        activeTask = nil
        uploadService.cancel()
        uploadPhase = .failed(GalleryUploadError.cancelled.localizedDescription)
        statusMessage = GalleryUploadError.cancelled.localizedDescription
    }

    private func applyUploadError(_ error: Error) {
        if let uploadError = error as? GalleryUploadError {
            switch uploadError {
            case .pendingNoInternet:
                uploadPhase = .pendingNoInternet
            case .deliveryUnknown:
                uploadPhase = .deliveryUnknown
            case .unauthorized:
                uploadPhase = .unauthorized
            case .server(let message):
                uploadPhase = .serverRejected(message)
            case .conflictManualInspection(let message):
                uploadPhase = .serverRejected(message)
            default:
                uploadPhase = .failed(uploadError.localizedDescription)
            }
            statusMessage = uploadError.localizedDescription
        } else {
            uploadPhase = .failed(error.localizedDescription)
            statusMessage = error.localizedDescription
        }
    }

    private func refreshPendingSummary() {
        pendingSummary = uploadService.pendingUploadSummary()
        hasLegacyPendingUpload = uploadService.hasLegacyPendingUpload()
        if let pendingSummary {
            galleryToken = pendingSummary.galleryToken
            galleryURL = pendingSummary.galleryURL
            qrImage = try? GalleryQRCodeGenerator.makeQRCodeImage(for: pendingSummary.galleryURL)
        }
        if pendingSummary != nil, uploadPhase == .idle {
            uploadPhase = .retryAvailable
            statusMessage = "A pending gallery upload is available."
        }
    }

    private func discardPendingTestUpload() {
        do {
            try uploadService.discardLocalPendingUpload()
            pendingSummary = nil
            hasLegacyPendingUpload = false
            clearGalleryIdentifiers()
            uploadPhase = .idle
            statusMessage = "Local pending test upload discarded. Build a fresh test gallery."
        } catch {
            uploadPhase = .failed(error.localizedDescription)
            statusMessage = error.localizedDescription
        }
    }

    private func ensureGalleryIdentifiers() throws {
        if galleryToken == nil {
            galleryToken = try GalleryTokenGenerator.makeGalleryToken()
        }

        guard let galleryToken else {
            throw GalleryUploadError.invalidGalleryToken
        }

        let configuration = try CustomerGalleryConfiguration.load()
        let generatedURL = try GalleryURLBuilder.makeGalleryURL(customerGalleryBaseURL: configuration.baseURL, galleryToken: galleryToken)
        galleryURL = generatedURL
        qrImage = try GalleryQRCodeGenerator.makeQRCodeImage(for: generatedURL)
    }

    private func clearGalleryIdentifiers() {
        galleryToken = nil
        galleryURL = nil
        qrImage = nil
        preparedMetrics = nil
        uploadResultStatus = nil
    }

    private static func byteString(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
#endif
