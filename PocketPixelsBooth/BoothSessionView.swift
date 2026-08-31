//
//  BoothSessionView.swift
//  PocketPixelsBooth
//
//  Created by marc on 8/30/26.
//

import PhotosUI
import SwiftUI
import UIKit

struct BoothSessionView: View {
    @StateObject private var viewModel = BoothSessionViewModel()
    @State private var selectedSamplePhotoItem: PhotosPickerItem?
    @State private var showingCancelConfirmation = false
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("printerIP") private var printerIP = BoothConfiguration.defaultPrinterIP
    @AppStorage("printerPort") private var printerPort = BoothConfiguration.defaultPrinterPort

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                boothContent
            }
            .navigationTitle("Booth Session")
            .navigationBarTitleDisplayMode(.inline)
            .confirmationDialog("Cancel this session?", isPresented: $showingCancelConfirmation, titleVisibility: .visible) {
                Button("Cancel Session", role: .destructive) {
                    viewModel.cancelSession()
                }
                Button("Keep Session", role: .cancel) { }
            } message: {
                Text("All captured photos and the current receipt preview will be cleared.")
            }
            .onChange(of: selectedSamplePhotoItem) { _, newItem in
                loadSamplePhoto(from: newItem)
            }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active {
                    viewModel.retryQueuedGalleryUploads()
                }
            }
            .task {
                viewModel.retryQueuedGalleryUploads()
            }
        }
    }

    @ViewBuilder
    private var boothContent: some View {
        switch viewModel.state {
        case .welcome:
            welcomeScreen
        case .preparingCamera, .cameraReady, .countdown, .capturing, .betweenPhotos, .retaking:
            cameraScreen
        case .review:
            reviewScreen
        case .composingReceipt:
            progressScreen(title: "Building Receipt", message: viewModel.statusMessage)
        case .receiptPreview, .connectingToPrinter, .printing:
            receiptScreen
        case .thankYou:
            thankYouScreen
        case .recoveryRequired(let message):
            recoveryScreen(message: message)
        case .error(let message):
            errorScreen(message: message)
        }
    }

    private var welcomeScreen: some View {
        VStack(spacing: 26) {
            Spacer()

            VStack(spacing: 12) {
                Text("POCKET PIXELS")
                    .font(.system(size: 62, weight: .black))
                    .foregroundStyle(.white)

                Text("Receipt Photobooth")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(Color(red: 0.62, green: 0.20, blue: 0.25))

                Text("Create your receipt")
                    .font(.title2)
                    .foregroundStyle(.white.opacity(0.76))
            }

            if isPrinterKnownUnavailable {
                Text("Printer needs attention before receipt printing.")
                    .foregroundStyle(.red.opacity(0.9))
            }

            Button {
                viewModel.startSession()
            } label: {
                Text("Start")
                    .font(.title.bold())
                    .frame(width: 260, height: 72)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color(red: 0.55, green: 0.12, blue: 0.18))
            .disabled(viewModel.state.isActiveSession)

            Text("This session will take \(BoothConfiguration.photosPerSession) photos.")
                .foregroundStyle(.white.opacity(0.62))

            Spacer()
        }
        .padding(40)
    }

    private var cameraScreen: some View {
        VStack(alignment: .leading, spacing: 18) {
            sessionTopBar

            HStack(alignment: .top, spacing: 24) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.black)

                    if let transient = viewModel.transientCapturedPhoto {
                        Image(uiImage: transient)
                            .resizable()
                            .scaledToFill()
                    } else if viewModel.isCameraUnavailable {
                        simulatorFallback
                    } else {
                        CameraPreview(session: viewModel.cameraService.session, cameraService: viewModel.cameraService)
                    }

                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.white.opacity(0.82), lineWidth: 2)
                        .padding(38)

                    if let countdownValue {
                        Text("\(countdownValue)")
                            .font(.system(size: 156, weight: .black, design: .rounded))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.5), radius: 16, x: 0, y: 7)
                    }
                }
                .aspectRatio(4.0 / 3.0, contentMode: .fit)
                .frame(maxWidth: 790)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 18) {
                    Text(photoCounterText)
                        .font(.system(size: 34, weight: .bold))
                        .foregroundStyle(.white)

                    Text(viewModel.statusMessage)
                        .foregroundStyle(.white.opacity(0.7))
                        .fixedSize(horizontal: false, vertical: true)

                    if case .cameraReady = viewModel.state, !viewModel.isCameraUnavailable {
                        Button {
                            viewModel.beginPhotoSequence()
                        } label: {
                            Label("Begin Photos", systemImage: "camera.fill")
                                .font(.title2.weight(.semibold))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(!viewModel.canBeginPhotos)
                    }

                    if viewModel.isCameraUnavailable {
                        samplePhotoPicker
                    }

                    if viewModel.state.allowsCancellation {
                        Button("Cancel Session", role: .destructive) {
                            showingCancelConfirmation = true
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    }
                }
                .frame(width: 310, alignment: .topLeading)
            }

            Spacer(minLength: 0)
        }
        .padding(28)
    }

    private var reviewScreen: some View {
        VStack(alignment: .leading, spacing: 22) {
            sessionTopBar

            Text("Review your photos")
                .font(.system(size: 42, weight: .bold))
                .foregroundStyle(.white)

            HStack(spacing: 16) {
                ForEach(0..<BoothConfiguration.photosPerSession, id: \.self) { index in
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Photo \(index + 1)")
                            .font(.headline)
                            .foregroundStyle(.white.opacity(0.8))

                        ZStack {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.white.opacity(0.08))

                            if viewModel.capturedPhotos.indices.contains(index) {
                                Image(uiImage: viewModel.capturedPhotos[index])
                                    .resizable()
                                    .scaledToFit()
                                    .padding(8)
                            } else {
                                Text("Missing")
                                    .foregroundStyle(.white.opacity(0.55))
                            }
                        }
                        .frame(height: 230)
                        .clipShape(RoundedRectangle(cornerRadius: 8))

                        Button("Retake Photo \(index + 1)") {
                            viewModel.retakePhoto(at: index)
                        }
                        .buttonStyle(.bordered)
                        .disabled(!viewModel.capturedPhotos.indices.contains(index) || !viewModel.canReturnToReview)
                    }
                }
            }

            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Choose your receipt style")
                        .font(.title3.bold())
                        .foregroundStyle(.white)

                    HStack(spacing: 12) {
                        ForEach(ReceiptLayoutStyle.allCases) { style in
                            receiptStyleButton(style)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 12) {
                    Text("Choose your favorite")
                        .font(.title3.bold())
                        .foregroundStyle(.white)

                    HStack(spacing: 10) {
                        ForEach(0..<BoothConfiguration.photosPerSession, id: \.self) { index in
                            favoritePhotoButton(index)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 14) {
                Button {
                    viewModel.continueToReceipt()
                } label: {
                    Label("Continue", systemImage: "arrow.right.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!viewModel.canContinueToReceipt)

                Button("Retake All") {
                    viewModel.retakeAll()
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(!viewModel.canReturnToReview)

                Button("Cancel Session", role: .destructive) {
                    showingCancelConfirmation = true
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
        }
        .padding(28)
    }

    private var receiptScreen: some View {
        VStack(alignment: .leading, spacing: 18) {
            sessionTopBar

            HStack(alignment: .top, spacing: 20) {
                ReceiptPreviewView(title: "Composed Receipt", image: viewModel.receiptImage)
                ReceiptPreviewView(title: "Thermal Receipt Preview", image: viewModel.thermalReceiptPreview)

                VStack(alignment: .leading, spacing: 16) {
                    Text("Receipt")
                        .font(.title.bold())
                        .foregroundStyle(.white)

                    Text(receiptDetailsText)
                        .foregroundStyle(.white.opacity(0.72))
                        .fixedSize(horizontal: false, vertical: true)

                    printerFields

                    HStack(spacing: 10) {
                        Circle()
                            .fill(printerStatusColor)
                            .frame(width: 12, height: 12)

                        Text(viewModel.printerState.message)
                            .foregroundStyle(.white.opacity(0.72))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(12)
                    .background(Color.white.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                    Button {
                        testPrinterConnection()
                    } label: {
                        Label("Test Connection", systemImage: "network")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(viewModel.printerState.isWorking || viewModel.printerState.requiresPrinterRestart)

                    Button {
                        viewModel.printReceipt(host: printerIP, port: parsedPort)
                    } label: {
                        Label("Print Receipt", systemImage: "printer.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(viewModel.receiptRasterizedImage == nil || viewModel.printerState.isWorking || viewModel.printerState.requiresPrinterRestart)

                    Button("Back to Review") {
                        viewModel.backToReview()
                    }
                    .buttonStyle(.bordered)
                    .disabled(!viewModel.canReturnToReview)

                    Button("Rebuild Receipt") {
                        viewModel.rebuildReceipt()
                    }
                    .buttonStyle(.bordered)
                    .disabled(viewModel.printerState.isWorking)

                    galleryStatusPanel(compact: true)
                }
                .frame(width: 330)
            }
        }
        .padding(28)
    }

    private var recoveryScreen: some View {
        recoveryScreen(message: viewModel.printerState.message)
    }

    private func recoveryScreen(message: String) -> some View {
        VStack(spacing: 22) {
            Spacer()

            Text("Printer Restart Required")
                .font(.system(size: 44, weight: .bold))
                .foregroundStyle(.white)

            Text(message)
                .font(.title3)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.76))
                .frame(maxWidth: 680)

            Button("I Restarted the Printer") {
                viewModel.confirmPrinterRestarted()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Text("Your three photos and receipt preview are still kept for retry after Test Connection succeeds.")
                .foregroundStyle(.white.opacity(0.6))

            Spacer()
        }
        .padding(40)
    }

    private var thankYouScreen: some View {
        VStack(spacing: 24) {
            Spacer()

            Text("Your photos are ready")
                .font(.system(size: 46, weight: .bold))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)

            galleryStatusPanel(compact: false)

            Button("Done") {
                viewModel.resetAfterDone()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Spacer()
        }
        .padding(40)
    }

    private func galleryStatusPanel(compact: Bool) -> some View {
        VStack(spacing: compact ? 10 : 16) {
            if let qrImage = viewModel.galleryQRCodeImage {
                Image(uiImage: qrImage)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: compact ? 150 : 280, height: compact ? 150 : 280)
                    .padding(compact ? 8 : 14)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .accessibilityLabel("Gallery QR code")
            }

            Text("Scan to view and save your photos")
                .font(compact ? .headline : .title2.bold())
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)

            Text(customerUploadStatusText)
                .font(compact ? .footnote : .body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.72))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(compact ? 12 : 22)
        .frame(maxWidth: compact ? .infinity : 460)
        .background(Color.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func progressScreen(title: String, message: String) -> some View {
        VStack(spacing: 18) {
            Spacer()
            ProgressView()
                .tint(.white)
                .scaleEffect(1.4)
            Text(title)
                .font(.title.bold())
                .foregroundStyle(.white)
            Text(message)
                .foregroundStyle(.white.opacity(0.7))
            Spacer()
        }
    }

    private func errorScreen(message: String) -> some View {
        VStack(spacing: 18) {
            Spacer()
            Text("Something needs attention")
                .font(.title.bold())
                .foregroundStyle(.white)
            Text(message)
                .foregroundStyle(.red.opacity(0.9))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 700)
            Button("Cancel Session") {
                showingCancelConfirmation = true
            }
            .buttonStyle(.borderedProminent)
            Spacer()
        }
        .padding(40)
    }

    private var sessionTopBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("POCKET PIXELS")
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                Text(viewModel.sessionIdentifier ?? viewModel.state.title)
                    .foregroundStyle(.white.opacity(0.62))
            }

            Spacer()

            Text(viewModel.state.title)
                .font(.headline)
                .foregroundStyle(Color(red: 0.86, green: 0.44, blue: 0.50))
        }
    }

    private var simulatorFallback: some View {
        VStack(spacing: 14) {
            Image(systemName: "camera.slash")
                .font(.system(size: 58))
                .foregroundStyle(.white.opacity(0.75))

            Text("Development-only sample photo fallback")
                .font(.title2.bold())
                .foregroundStyle(.white)

            Text("The iPad camera must be tested on a physical device. Select exactly \(BoothConfiguration.photosPerSession) sample photos to continue.")
                .foregroundStyle(.white.opacity(0.68))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
        }
        .padding(32)
    }

    private var samplePhotoPicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            PhotosPicker(selection: $selectedSamplePhotoItem, matching: .images) {
                Label("Use Sample Photo", systemImage: "photo")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Text("Sample photos selected: \(viewModel.samplePhotoCount) of \(BoothConfiguration.photosPerSession)")
                .foregroundStyle(.white.opacity(0.7))
        }
    }

    private var printerFields: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
            GridRow {
                Text("Printer IP")
                    .foregroundStyle(.white.opacity(0.72))
                    .frame(width: 86, alignment: .leading)

                TextField("Printer IP", text: $printerIP)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.decimalPad)
                    .textFieldStyle(.roundedBorder)
            }

            GridRow {
                Text("Port")
                    .foregroundStyle(.white.opacity(0.72))
                    .frame(width: 86, alignment: .leading)

                TextField("Port", text: $printerPort)
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    private var countdownValue: Int? {
        if case .countdown(_, let value) = viewModel.state {
            return value
        }

        return nil
    }

    private var photoCounterText: String {
        switch viewModel.state {
        case .countdown(let index, _), .capturing(let index), .retaking(let index):
            "Photo \(index + 1) of \(BoothConfiguration.photosPerSession)"
        case .betweenPhotos(let nextIndex):
            "Next: Photo \(nextIndex + 1)"
        default:
            "Photo \(min(viewModel.capturedPhotos.count + 1, BoothConfiguration.photosPerSession)) of \(BoothConfiguration.photosPerSession)"
        }
    }

    private var receiptDetailsText: String {
        guard let receipt = viewModel.composedReceipt else {
            return "Receipt is not ready."
        }

        let length = String(format: "%.1f", receipt.estimatedLengthMillimeters)
        return "\(receipt.layoutStyle.displayName) receipt\n\(receipt.width) x \(receipt.height) pixels\nEstimated length: \(length) mm\nPrinter: \(printerIP):\(printerPort)"
    }

    private var printerStatusColor: Color {
        switch viewModel.printerState {
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

    private var customerUploadStatusText: String {
        switch viewModel.uploadPhase {
        case .idle, .preparing:
            "Preparing your gallery..."
        case .checkingInternet, .uploading:
            "Uploading your photos..."
        case .success:
            "Your photos are ready."
        case .pendingNoInternet, .deliveryUnknown, .retryAvailable:
            "Your gallery is queued. This QR will work once the connection is restored."
        case .unauthorized, .serverRejected, .failed:
            "Your gallery needs operator attention."
        }
    }

    private var parsedPort: UInt16? {
        UInt16(printerPort.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private var isPrinterKnownUnavailable: Bool {
        if case .failure = viewModel.printerState {
            return true
        }

        return viewModel.printerState.requiresPrinterRestart
    }

    private func testPrinterConnection() {
        viewModel.testPrinterConnection(host: printerIP, port: parsedPort)
    }

    private func receiptStyleButton(_ style: ReceiptLayoutStyle) -> some View {
        let isSelected = viewModel.selectedReceiptLayoutStyle == style
        return Button {
            viewModel.selectReceiptLayoutStyle(style)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: style == .collage ? "rectangle.grid.2x2.fill" : "rectangle.fill")
                        .font(.title3)
                    Text(style.displayName.uppercased())
                        .font(.headline.weight(.bold))
                    if style == .collage {
                        Text("Recommended")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.white.opacity(isSelected ? 0.22 : 0.12))
                            .clipShape(Capsule())
                    }
                }

                Text(style.detailText)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.72))
            }
            .frame(maxWidth: .infinity, minHeight: 78, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(isSelected ? Color(red: 0.55, green: 0.12, blue: 0.18) : Color.white.opacity(0.08))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.white.opacity(0.9) : Color.white.opacity(0.18), lineWidth: isSelected ? 2 : 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(!viewModel.canReturnToReview)
    }

    private func favoritePhotoButton(_ index: Int) -> some View {
        let isSelected = viewModel.selectedFavoritePhotoIndex == index
        return Button {
            viewModel.selectFavoritePhoto(at: index)
        } label: {
            VStack(spacing: 7) {
                ZStack(alignment: .topTrailing) {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.white.opacity(0.08))

                    if viewModel.capturedPhotos.indices.contains(index) {
                        Image(uiImage: viewModel.capturedPhotos[index])
                            .resizable()
                            .scaledToFill()
                            .frame(width: 88, height: 66)
                            .clipped()
                    }

                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.white)
                            .padding(5)
                    }
                }
                .frame(width: 88, height: 66)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isSelected ? Color.white.opacity(0.95) : Color.white.opacity(0.18), lineWidth: isSelected ? 2 : 1)
                }

                Text("Photo \(index + 1)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 106, height: 112)
            .background(isSelected ? Color(red: 0.55, green: 0.12, blue: 0.18) : Color.white.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(!viewModel.capturedPhotos.indices.contains(index) || !viewModel.canReturnToReview)
    }

    private func loadSamplePhoto(from item: PhotosPickerItem?) {
        guard let item else {
            return
        }

        Task {
            do {
                guard let imageData = try await item.loadTransferable(type: Data.self),
                      let image = UIImage(data: imageData) else {
                    throw ThermalImageRasterizerError.invalidImage
                }

                viewModel.addSamplePhoto(image)
                selectedSamplePhotoItem = nil
            } catch {
                viewModel.state = .error(error.localizedDescription)
                viewModel.errorMessage = error.localizedDescription
                viewModel.statusMessage = error.localizedDescription
            }
        }
    }
}
