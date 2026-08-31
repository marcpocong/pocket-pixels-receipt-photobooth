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
#if DEBUG
    @State private var showingEndNoPrintConfirmation = false
#endif
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
#if DEBUG
            .confirmationDialog("End this test session without printing?", isPresented: $showingEndNoPrintConfirmation, titleVisibility: .visible) {
                Button("End Session (No Print)", role: .destructive) {
                    viewModel.resetAfterDone()
                }
                Button("Keep Session", role: .cancel) { }
            } message: {
                Text("This clears only the current booth screen state. Pending gallery uploads remain queued.")
            }
#endif
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
        case .choosingFormat:
            formatSelectionScreen
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

            Text("Choose your receipt format before photos are taken.")
                .foregroundStyle(.white.opacity(0.62))

            Spacer()
        }
        .padding(40)
    }

    private var formatSelectionScreen: some View {
        VStack(alignment: .leading, spacing: 26) {
            HStack {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Choose your format")
                        .font(.system(size: 48, weight: .bold))
                        .foregroundStyle(.white)

                    Text("Pick the receipt layout before photos begin.")
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.68))
                }

                Spacer()

                Button("Back") {
                    viewModel.cancelSession()
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }

            LazyVGrid(columns: formatSelectionColumns, spacing: 18) {
                ForEach(BoothFormat.allCases) { format in
                    formatCard(format)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(34)
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

                    if let countdownValue {
                        Text("\(countdownValue)")
                            .font(.system(size: 156, weight: .black, design: .rounded))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.5), radius: 16, x: 0, y: 7)
                    }
                }
                .aspectRatio(3.0 / 4.0, contentMode: .fit)
                .frame(maxWidth: 560, maxHeight: 720)
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

            Text(viewModel.selectedBoothFormat?.reviewSummary ?? "")
                .font(.headline.weight(.semibold))
                .foregroundStyle(Color(red: 0.86, green: 0.44, blue: 0.50))

            HStack(spacing: 16) {
                ForEach(0..<viewModel.requiredPhotoCount, id: \.self) { index in
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
                                    .scaledToFill()
                                    .frame(width: 150, height: 200)
                                    .clipped()
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

#if DEBUG
                    Button("End Session (No Print)", role: .destructive) {
                        showingEndNoPrintConfirmation = true
                    }
                    .buttonStyle(.bordered)
                    .disabled(viewModel.printerState.isWorking)
#endif

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

            Text("Your photos and receipt preview are still kept for retry after Test Connection succeeds.")
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

            Text("The iPad camera must be tested on a physical device. Select sample photos to continue.")
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

            Text("Sample photos selected: \(viewModel.samplePhotoCount) of \(viewModel.requiredPhotoCount)")
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
            "Photo \(index + 1) of \(viewModel.requiredPhotoCount)"
        case .betweenPhotos(let nextIndex):
            "Next: Photo \(nextIndex + 1)"
        default:
            "Photo \(min(viewModel.capturedPhotos.count + 1, viewModel.requiredPhotoCount)) of \(viewModel.requiredPhotoCount)"
        }
    }

    private var receiptDetailsText: String {
        guard let receipt = viewModel.composedReceipt else {
            return "Receipt is not ready."
        }

        let length = String(format: "%.1f", receipt.estimatedLengthMillimeters)
        return "\(receipt.format.displayName) receipt\n\(receipt.width) x \(receipt.height) pixels\nEstimated length: \(length) mm\nPrinter: \(printerIP):\(printerPort)"
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

    private var formatSelectionColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(minimum: 230), spacing: 18), count: 3)
    }

    private func testPrinterConnection() {
        viewModel.testPrinterConnection(host: printerIP, port: parsedPort)
    }

    private func formatCard(_ format: BoothFormat) -> some View {
        return Button {
            viewModel.selectBoothFormat(format)
        } label: {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    Text(format.displayName.uppercased())
                        .font(.title2.weight(.black))
                    Spacer()
                    Text(format.photoCountLabel.uppercased())
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white.opacity(0.72))
                }

                formatPreview(format)
                    .frame(maxWidth: .infinity)
                    .frame(height: 190)

                Text(format.shortDescription)
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.74))
            }
            .foregroundStyle(.white)
            .padding(20)
            .frame(minHeight: 300, alignment: .topLeading)
            .background(Color.white.opacity(0.08))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.white.opacity(0.18), lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private func formatPreview(_ format: BoothFormat) -> some View {
        GeometryReader { proxy in
            ZStack {
                switch format {
                case .solo:
                    previewFrame(width: 108, height: 144)
                case .duo:
                    VStack(spacing: 10) {
                        previewFrame(width: 88, height: 117)
                        previewFrame(width: 88, height: 117)
                    }
                case .trio:
                    HStack(spacing: 10) {
                        previewFrame(width: 112, height: 149)
                        VStack(spacing: 7) {
                            previewFrame(width: 52, height: 69)
                            previewFrame(width: 52, height: 69)
                        }
                    }
                case .grid:
                    VStack(spacing: 10) {
                        HStack(spacing: 10) {
                            previewFrame(width: 72, height: 96)
                            previewFrame(width: 72, height: 96)
                        }
                        HStack(spacing: 10) {
                            previewFrame(width: 72, height: 96)
                            previewFrame(width: 72, height: 96)
                        }
                    }
                case .mosaic:
                    HStack(spacing: 10) {
                        previewFrame(width: 102, height: 136)
                        VStack(spacing: 5) {
                            ForEach(0..<3, id: \.self) { _ in
                                previewFrame(width: 42, height: 56)
                            }
                        }
                    }
                case .strip:
                    VStack(spacing: 6) {
                        ForEach(0..<4, id: \.self) { _ in
                            previewFrame(width: 58, height: 77)
                        }
                    }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }

    private func previewFrame(width: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .stroke(Color.white.opacity(0.82), lineWidth: 2)
            .background(Color.white.opacity(0.08))
            .frame(width: width, height: height)
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
