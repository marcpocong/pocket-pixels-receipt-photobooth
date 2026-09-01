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
                boothBackground
                boothContent
            }
            .navigationTitle(usesCustomerEntryStyle ? "" : "Booth Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(usesCustomerEntryStyle ? .hidden : .visible, for: .navigationBar)
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
    private var boothBackground: some View {
        switch viewModel.state {
        case .welcome, .choosingFormat:
            PocketPixelsTheme.ColorPalette.paper
                .ignoresSafeArea()
        default:
            Color.black
                .ignoresSafeArea()
        }
    }

    private var usesCustomerEntryStyle: Bool {
        viewModel.state == .welcome || viewModel.state == .choosingFormat
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
        GeometryReader { proxy in
            let contentWidth = min(proxy.size.width - (PocketPixelsTheme.Spacing.screenPadding * 2), 560)
            let receiptHeight = min(max(proxy.size.height * 0.35, 370), 440)

            VStack(spacing: 14) {
                Spacer(minLength: max(proxy.size.height * 0.07, 52))

                VStack(spacing: 12) {
                    Text("POCKET PIXELS")
                        .font(.system(size: 34, weight: .heavy))
                        .tracking(1.8)
                        .foregroundStyle(PocketPixelsTheme.ColorPalette.charcoal)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)

                    Text("Receipt Photobooth")
                        .font(.system(size: 60, weight: .black))
                        .foregroundStyle(PocketPixelsTheme.ColorPalette.charcoal)
                        .lineLimit(2)
                        .minimumScaleFactor(0.86)
                        .multilineTextAlignment(.center)

                    Text("Choose your format, then take your photos.")
                        .font(.system(size: 23, weight: .medium))
                        .foregroundStyle(PocketPixelsTheme.ColorPalette.secondaryText)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(width: contentWidth)

                ZStack {
                    Color.clear
                        .frame(height: 42)

                    if isPrinterKnownUnavailable {
                        printerWarning
                    }
                }
                .frame(width: contentWidth)

                welcomeReceiptMotif
                    .frame(width: contentWidth * 0.72, height: receiptHeight)

                Button {
                    viewModel.startSession()
                } label: {
                    Text("Start")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PocketPixelsPrimaryButtonStyle())
                .frame(width: contentWidth * 0.76)
                .disabled(viewModel.state.isActiveSession)

                Text("Your photos will also be available by QR.")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(PocketPixelsTheme.ColorPalette.secondaryText)
                    .multilineTextAlignment(.center)

                Spacer(minLength: max(proxy.size.height * 0.07, 52))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .offset(y: -42)
        }
        .padding(PocketPixelsTheme.Spacing.screenPadding)
        .transition(.opacity)
    }

    private var formatSelectionScreen: some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Choose your format")
                        .font(.system(size: 46, weight: .black))
                        .foregroundStyle(PocketPixelsTheme.ColorPalette.charcoal)

                    Text("Pick how your photos will print.")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(PocketPixelsTheme.ColorPalette.secondaryText)
                }

                Spacer()

                Button {
                    viewModel.cancelSession()
                } label: {
                    Label("Back", systemImage: "chevron.left")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(PocketPixelsSecondaryButtonStyle())
            }

            LazyVGrid(columns: formatSelectionColumns, spacing: 18) {
                ForEach(BoothFormat.allCases) { format in
                    formatCard(format)
                }
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: PocketPixelsTheme.Layout.maxContentWidth)
        .padding(PocketPixelsTheme.Spacing.screenPadding)
        .transition(.opacity)
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
        Array(repeating: GridItem(.flexible(minimum: 320, maximum: 481), spacing: 18), count: 2)
    }

    private func testPrinterConnection() {
        viewModel.testPrinterConnection(host: printerIP, port: parsedPort)
    }

    private var printerWarning: some View {
        HStack(spacing: 12) {
            Image(systemName: "printer.fill")
                .font(.system(size: 16, weight: .bold))

            Text("Printer needs attention before receipt printing.")
                .font(.system(size: 16, weight: .semibold))
        }
        .foregroundStyle(PocketPixelsTheme.ColorPalette.warningText)
        .padding(.vertical, 11)
        .padding(.horizontal, 14)
        .background(PocketPixelsTheme.ColorPalette.warningSurface)
        .overlay {
            RoundedRectangle(cornerRadius: PocketPixelsTheme.Radius.card)
                .stroke(PocketPixelsTheme.ColorPalette.warningText.opacity(0.18), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: PocketPixelsTheme.Radius.card))
    }

    private var welcomeReceiptMotif: some View {
        GeometryReader { proxy in
            let scale = min(proxy.size.width / 260, proxy.size.height / 380)

            ZStack {
                RoundedRectangle(cornerRadius: PocketPixelsTheme.Radius.card)
                    .fill(PocketPixelsTheme.ColorPalette.paperWarm)
                    .frame(width: 216, height: 318)
                    .rotationEffect(.degrees(-5))
                    .offset(x: -26, y: 12)

                receiptIllustration
                    .frame(width: 230, height: 348)
                    .rotationEffect(.degrees(3))
            }
            .scaleEffect(scale)
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }

    private var receiptIllustration: some View {
        VStack(spacing: 15) {
            RoundedRectangle(cornerRadius: 3)
                .fill(PocketPixelsTheme.ColorPalette.maroon)
                .frame(width: 54, height: 5)
                .padding(.top, 20)

            RoundedRectangle(cornerRadius: 5)
                .fill(PocketPixelsTheme.ColorPalette.paperWarm.opacity(0.55))
                .overlay {
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(PocketPixelsTheme.ColorPalette.border.opacity(0.55), lineWidth: 1)
                }
                .frame(width: 132, height: 166)

            VStack(spacing: 7) {
                Rectangle()
                    .fill(PocketPixelsTheme.ColorPalette.charcoal.opacity(0.15))
                    .frame(width: 132, height: 5)
                Rectangle()
                    .fill(PocketPixelsTheme.ColorPalette.charcoal.opacity(0.10))
                    .frame(width: 108, height: 5)
            }

            qrPlaceholder

            Spacer(minLength: 0)

            receiptTearEdge
                .frame(height: 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white)
        .overlay {
            RoundedRectangle(cornerRadius: PocketPixelsTheme.Radius.card)
                .stroke(PocketPixelsTheme.ColorPalette.border.opacity(0.55), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: PocketPixelsTheme.Radius.card))
        .shadow(color: PocketPixelsTheme.ColorPalette.charcoal.opacity(0.08), radius: 10, x: 0, y: 6)
    }

    private var qrPlaceholder: some View {
        VStack(spacing: 3) {
            ForEach(0..<5, id: \.self) { row in
                HStack(spacing: 3) {
                    ForEach(0..<5, id: \.self) { column in
                        Rectangle()
                            .fill(qrPlaceholderIsFilled(row: row, column: column) ? PocketPixelsTheme.ColorPalette.charcoal.opacity(0.72) : Color.clear)
                            .frame(width: 5, height: 5)
                    }
                }
            }
        }
        .padding(7)
        .background(PocketPixelsTheme.ColorPalette.paper.opacity(0.8))
    }

    private var receiptTearEdge: some View {
        HStack(spacing: 5) {
            ForEach(0..<18, id: \.self) { _ in
                Rectangle()
                    .fill(PocketPixelsTheme.ColorPalette.paper)
                    .frame(width: 7)
            }
        }
    }

    private func formatCard(_ format: BoothFormat) -> some View {
        return Button {
            viewModel.selectBoothFormat(format)
        } label: {
            VStack(alignment: .leading, spacing: 14) {
                formatPreview(format)
                    .frame(maxWidth: .infinity)
                    .frame(height: PocketPixelsTheme.Layout.formatPreviewHeight)

                VStack(alignment: .leading, spacing: 5) {
                    Text(format.displayName.uppercased())
                        .font(.system(size: 27, weight: .black))
                        .foregroundStyle(PocketPixelsTheme.ColorPalette.charcoal)

                    Text(format.photoCountLabel)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(PocketPixelsTheme.ColorPalette.maroon)

                    Text(customerFormatDescription(for: format))
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(PocketPixelsTheme.ColorPalette.secondaryText)
                }
            }
            .padding(PocketPixelsTheme.Spacing.card)
            .frame(maxWidth: .infinity, minHeight: PocketPixelsTheme.Layout.formatCardHeight, alignment: .topLeading)
            .background(PocketPixelsTheme.ColorPalette.surface)
            .overlay {
                RoundedRectangle(cornerRadius: PocketPixelsTheme.Radius.card)
                    .stroke(PocketPixelsTheme.ColorPalette.border.opacity(0.62), lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: PocketPixelsTheme.Radius.card))
        }
        .buttonStyle(FormatCardButtonStyle())
    }

    private func formatPreview(_ format: BoothFormat) -> some View {
        GeometryReader { proxy in
            let canvasHeight = proxy.size.height
            let receiptWidth = formatPreviewReceiptWidth(for: format, availableWidth: proxy.size.width)
            let receiptHeight = min(canvasHeight - 2, 148)

            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: PocketPixelsTheme.Radius.receipt)
                    .fill(Color.white)
                    .overlay {
                        RoundedRectangle(cornerRadius: PocketPixelsTheme.Radius.receipt)
                            .stroke(PocketPixelsTheme.ColorPalette.border.opacity(0.58), lineWidth: 1)
                    }
                    .frame(width: receiptWidth, height: receiptHeight)

                previewFrames(for: format, receiptWidth: receiptWidth, receiptHeight: receiptHeight)
                    .padding(.top, 10)

                Rectangle()
                    .fill(PocketPixelsTheme.ColorPalette.maroonMuted.opacity(0.22))
                    .frame(width: receiptWidth * 0.62, height: 4)
                    .offset(y: receiptHeight - 12)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }

    @ViewBuilder
    private func previewFrames(for format: BoothFormat, receiptWidth: CGFloat, receiptHeight: CGFloat) -> some View {
        switch format {
        case .solo:
            previewPhoto(width: receiptWidth * 0.62, height: receiptHeight * 0.70)
        case .duo:
            VStack(spacing: receiptHeight * 0.055) {
                previewPhoto(width: receiptWidth * 0.58, height: receiptHeight * 0.38)
                previewPhoto(width: receiptWidth * 0.58, height: receiptHeight * 0.38)
            }
        case .grid:
            VStack(spacing: receiptHeight * 0.047) {
                HStack(spacing: receiptWidth * 0.06) {
                    previewPhoto(width: receiptWidth * 0.30, height: receiptHeight * 0.30)
                    previewPhoto(width: receiptWidth * 0.30, height: receiptHeight * 0.30)
                }
                HStack(spacing: receiptWidth * 0.06) {
                    previewPhoto(width: receiptWidth * 0.30, height: receiptHeight * 0.30)
                    previewPhoto(width: receiptWidth * 0.30, height: receiptHeight * 0.30)
                }
            }
        case .strip:
            VStack(spacing: receiptHeight * 0.04) {
                ForEach(0..<3, id: \.self) { _ in
                    previewPhoto(width: receiptWidth * 0.54, height: receiptHeight * 0.24)
                }
            }
        }
    }

    private func previewPhoto(width: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(PocketPixelsTheme.ColorPalette.paperWarm.opacity(0.62))
            .overlay {
                RoundedRectangle(cornerRadius: 3)
                    .stroke(PocketPixelsTheme.ColorPalette.border.opacity(0.65), lineWidth: 1)
            }
            .frame(width: width, height: height)
    }

    private func qrPlaceholderIsFilled(row: Int, column: Int) -> Bool {
        row == 0 || column == 0 || row == 4 || column == 4 || row == column || (row == 3 && column == 1)
    }

    private func formatPreviewReceiptWidth(for format: BoothFormat, availableWidth: CGFloat) -> CGFloat {
        switch format {
        case .solo:
            min(availableWidth * 0.40, 124)
        case .duo:
            min(availableWidth * 0.38, 118)
        case .grid:
            min(availableWidth * 0.48, 144)
        case .strip:
            min(availableWidth * 0.28, 86)
        }
    }

    private func customerFormatDescription(for format: BoothFormat) -> String {
        switch format {
        case .solo:
            "One portrait"
        case .duo:
            "Two moments"
        case .grid:
            "Four-photo collage"
        case .strip:
            "Classic photo strip"
        }
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
