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
    @State private var welcomeMotionActive = false
    @State private var welcomeReceiptFloatActive = false
    @State private var formatMotionActive = false
    @State private var reviewMotionActive = false
    @State private var receiptMotionActive = false
    @State private var progressMotionActive = false
    @State private var thankYouMotionActive = false
    @State private var shutterFlashActive = false
#if DEBUG
    @State private var showingEndNoPrintConfirmation = false
    @State private var showingReceiptDebugTools = false
#endif
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("printerIP") private var printerIP = BoothConfiguration.defaultPrinterIP
    @AppStorage("printerPort") private var printerPort = BoothConfiguration.defaultPrinterPort

    var body: some View {
        NavigationStack {
            ZStack {
                boothBackground
                boothContent
                    .id(customerScreenTransitionKey)
                    .transition(customerScreenTransition)
            }
            .animation(customerScreenAnimation, value: customerScreenTransitionKey)
            .navigationTitle(usesCustomerChromeHidden ? "" : "Booth Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(usesCustomerChromeHidden ? .hidden : .visible, for: .navigationBar)
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
            .onChange(of: viewModel.state) { oldState, newState in
                handleCustomerStateChange(from: oldState, to: newState)
            }
#if DEBUG
            .onChange(of: viewModel.state) { _, newState in
                if case .receiptPreview = newState {
                    showingReceiptDebugTools = false
                }
            }
#endif
            .task {
                handleCustomerStateChange(from: nil, to: viewModel.state)
                viewModel.preparePrinter()
                viewModel.retryQueuedGalleryUploads()
            }
        }
    }

    @ViewBuilder
    private var boothBackground: some View {
        LinearGradient(
            colors: [
                PocketPixelsTheme.ColorPalette.paper,
                PocketPixelsTheme.ColorPalette.brandBlush.opacity(0.34),
                PocketPixelsTheme.ColorPalette.paperWarm.opacity(0.72)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
            .ignoresSafeArea()
    }

    private var usesCustomerChromeHidden: Bool {
        true
    }

    private var customerScreenTransitionKey: String {
        switch viewModel.state {
        case .welcome:
            "welcome"
        case .choosingFormat:
            "choosingFormat"
        case .preparingCamera, .cameraReady, .countdown, .capturing, .betweenPhotos, .retaking:
            "camera"
        case .review:
            "review"
        case .composingReceipt:
            "composingReceipt"
        case .receiptPreview, .connectingToPrinter, .printing:
            "receipt"
        case .thankYou:
            "thankYou"
        case .recoveryRequired:
            "recovery"
        case .error:
            "error"
        }
    }

    private var customerScreenTransition: AnyTransition {
        if reduceMotion {
            return .opacity
        }

        return .asymmetric(
            insertion: .opacity.combined(with: .offset(y: PocketPixelsTheme.Motion.entranceOffset)),
            removal: .opacity
        )
    }

    private var customerScreenAnimation: Animation {
        reduceMotion ? .easeOut(duration: PocketPixelsTheme.Motion.quick) : PocketPixelsTheme.Motion.screenTransitionAnimation
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
            progressScreen(title: "Preparing your receipt", message: "This will just take a moment.")
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
            let contentWidth = min(proxy.size.width - (PocketPixelsTheme.Spacing.screenPadding * 2), 640)
            let lightboxWidth = min(contentWidth, 550)
            let lightboxHeight = lightboxWidth / 3.32
            let receiptWidth = min(contentWidth * 0.92, 588)
            let receiptHeight = min(max(proxy.size.height * 0.43, 500), 510)
            let warningHeight: CGFloat = isPrinterKnownUnavailable ? 42 : 6
            let bottomBreathingRoom = max(proxy.safeAreaInsets.bottom + 24, 34)

            VStack(spacing: 12) {
                VStack(spacing: 12) {
                    PocketPixelsLightboxLockup(scale: .hero, showGlow: true)
                        .frame(width: lightboxWidth, height: lightboxHeight)

                    Text("make your moment. print your keepsake.")
                        .font(.system(size: 23, weight: .regular, design: .serif))
                        .foregroundStyle(PocketPixelsTheme.ColorPalette.maroonMuted.opacity(0.94))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(width: contentWidth)
                .pocketPixelsEntrance(active: welcomeMotionActive, reduceMotion: reduceMotion)

                ZStack {
                    Color.clear
                        .frame(height: warningHeight)

                    if isPrinterKnownUnavailable {
                        printerWarning
                    }
                }
                .frame(width: contentWidth)

                welcomeReceiptVisual
                    .frame(width: receiptWidth, height: receiptHeight)
                    .offset(y: reduceMotion || !welcomeReceiptFloatActive ? 0 : -PocketPixelsTheme.Motion.idleFloatDistance)
                    .animation(reduceMotion ? nil : PocketPixelsTheme.Motion.idleFloatAnimation, value: welcomeReceiptFloatActive)
                    .pocketPixelsEntrance(
                        active: welcomeMotionActive,
                        reduceMotion: reduceMotion,
                        delay: 0.10,
                        offset: 0,
                        scale: 0.97
                    )

                Button {
                    viewModel.startSession()
                } label: {
                    Text("Start")
                        .font(.system(size: 23, weight: .bold))
                        .foregroundStyle(PocketPixelsTheme.ColorPalette.lightText)
                        .frame(maxWidth: .infinity)
                        .frame(height: 66)
                        .background(
                            RoundedRectangle(cornerRadius: 20)
                                .fill(PocketPixelsTheme.ColorPalette.brandMaroon)
                                .shadow(color: PocketPixelsTheme.ColorPalette.charcoal.opacity(0.085), radius: 8, x: 0, y: 5)
                        )
                }
                .buttonStyle(.plain)
                .frame(width: 480)
                .disabled(viewModel.state.isActiveSession)
                .opacity(viewModel.state.isActiveSession ? 0.55 : 1)
                .pocketPixelsEntrance(active: welcomeMotionActive, reduceMotion: reduceMotion, delay: 0.20, offset: 8)

                Text("photos also available by qr")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(PocketPixelsTheme.ColorPalette.secondaryText.opacity(0.82))
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)
                    .pocketPixelsEntrance(active: welcomeMotionActive, reduceMotion: reduceMotion, delay: 0.24, offset: 6)
            }
            .padding(.top, max(proxy.size.height * 0.028, 24))
            .padding(.bottom, bottomBreathingRoom)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .padding(PocketPixelsTheme.Spacing.screenPadding)
        .transition(.opacity)
        .onAppear {
            startWelcomeMotion()
        }
        .onDisappear {
            welcomeMotionActive = false
            welcomeReceiptFloatActive = false
        }
    }

    private var formatSelectionScreen: some View {
        GeometryReader { proxy in
            let contentWidth = min(proxy.size.width - (PocketPixelsTheme.Spacing.screenPadding * 2), PocketPixelsTheme.Layout.maxContentWidth)
            let cardHeight = min(max(proxy.size.height * 0.285, 304), 320)
            let previewHeight = min(max(cardHeight * 0.60, 184), 194)

            let gridSpacing: CGFloat = 20
            let headerToGridSpacing: CGFloat = 8
            let estimatedHeaderHeight: CGFloat = 150
            let estimatedContentHeight = estimatedHeaderHeight + headerToGridSpacing + (cardHeight * 2) + gridSpacing
            let topPadding = max(((proxy.size.height - estimatedContentHeight) / 2) - 62, 24)

            VStack(alignment: .leading, spacing: headerToGridSpacing) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 7) {
                        PocketPixelsLightboxLockup(scale: .compact)
                            .padding(.bottom, 10)

                        Text("Choose your format")
                            .font(.system(size: 48, weight: .bold))
                            .foregroundStyle(PocketPixelsTheme.ColorPalette.brandMaroon)

                        Text("Pick how your photos will print.")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(PocketPixelsTheme.ColorPalette.secondaryText)
                    }

                    Spacer()

                    Button {
                        viewModel.cancelSession()
                    } label: {
                        Label("Back", systemImage: "chevron.left")
                            .font(.system(size: 18, weight: .semibold))
                            .labelStyle(.titleAndIcon)
                            .padding(.horizontal, 16)
                            .frame(minHeight: 46)
                    }
                    .buttonStyle(FormatBackButtonStyle())
                }
                .frame(width: contentWidth)

                LazyVGrid(columns: formatSelectionColumns, spacing: gridSpacing) {
                    ForEach(Array(BoothFormat.allCases.enumerated()), id: \.element) { index, format in
                        formatCard(format, cardHeight: cardHeight, previewHeight: previewHeight)
                            .pocketPixelsEntrance(
                                active: formatMotionActive,
                                reduceMotion: reduceMotion,
                                delay: Double(index) * PocketPixelsTheme.Motion.stagger,
                                offset: 10,
                                scale: PocketPixelsTheme.Motion.subtleScale
                            )
                    }
                }
                .frame(width: contentWidth)
            }
            .frame(width: contentWidth)
            .padding(.top, topPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .padding(PocketPixelsTheme.Spacing.screenPadding)
        .transition(.opacity)
        .onAppear {
            startFormatMotion()
        }
    }

    private var cameraScreen: some View {
        GeometryReader { proxy in
            let contentWidth = min(proxy.size.width - (PocketPixelsTheme.Spacing.screenPadding * 2), 620)
            let previewWidth = min(contentWidth, 600)
            let previewAspectRatio = usesLandscapeCompositionGuide
                ? ReceiptComposer.landscapePresentationAspectRatio
                : ReviewPhotoPresentation.portrait.aspectRatio

            VStack(spacing: 18) {
                cameraTopBar
                    .frame(width: contentWidth)

                cameraPreviewSurface
                    .aspectRatio(previewAspectRatio, contentMode: .fit)
                    .frame(width: previewWidth)

                VStack(spacing: 16) {
                    Text(cameraCustomerStatusText)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(PocketPixelsTheme.ColorPalette.secondaryText)
                        .multilineTextAlignment(.center)
                        .frame(width: contentWidth)
                        .fixedSize(horizontal: false, vertical: true)

                    if case .cameraReady = viewModel.state, !viewModel.isCameraUnavailable {
                        Button {
                            viewModel.beginPhotoSequence()
                        } label: {
                            Text("Start Photos")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(PocketPixelsPrimaryButtonStyle())
                        .frame(width: contentWidth * 0.74)
                        .disabled(!viewModel.canBeginPhotos)
                    }

                    #if DEBUG
                    if viewModel.isCameraUnavailable {
                        samplePhotoPicker
                            .frame(width: contentWidth * 0.74)
                    }
                    #endif
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(PocketPixelsTheme.Spacing.screenPadding)
    }

    private var cameraTopBar: some View {
        HStack(alignment: .center) {
            PocketPixelsLightboxLockup(scale: .compact)
                .frame(width: 160, alignment: .leading)

            Spacer()

            Text(photoCounterText)
                .font(.system(size: 23, weight: .bold))
                .foregroundStyle(PocketPixelsTheme.ColorPalette.charcoal)
                .lineLimit(1)
                .id(photoCounterText)
                .transition(.opacity)
                .animation(PocketPixelsTheme.Motion.quickAnimation, value: photoCounterText)

            Spacer()

            if viewModel.state.allowsCancellation {
                Button("Cancel") {
                    showingCancelConfirmation = true
                }
                .buttonStyle(PocketPixelsSecondaryButtonStyle())
            }
        }
    }

    private var cameraPreviewSurface: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18)
                .fill(Color.black)

            if let transient = viewModel.transientCapturedPhoto {
                Image(uiImage: transient)
                    .resizable()
                    .scaledToFill()
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 1.015)))
            } else if viewModel.isCameraUnavailable {
                simulatorFallback
            } else {
                CameraPreview(session: viewModel.cameraService.session, cameraService: viewModel.cameraService)
            }

            RoundedRectangle(cornerRadius: 18)
                .stroke(PocketPixelsTheme.ColorPalette.brandMaroon.opacity(0.50), lineWidth: 1.5)

            if let countdownValue {
                Text("\(countdownValue)")
                    .font(.system(size: 142, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.68), radius: 18, x: 0, y: 8)
                    .transition(.scale(scale: 0.86).combined(with: .opacity))
                    .id(countdownValue)
            }

            if shutterFlashActive {
                Color.white
                    .opacity(PocketPixelsTheme.Motion.shutterFlashOpacity)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.18), value: countdownValue)
        .animation(PocketPixelsTheme.Motion.quickAnimation, value: viewModel.transientCapturedPhoto != nil)
        .animation(PocketPixelsTheme.Motion.quickAnimation, value: shutterFlashActive)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .shadow(color: PocketPixelsTheme.ColorPalette.amberGlow.opacity(0.16), radius: 20, x: 0, y: 8)
        .shadow(color: PocketPixelsTheme.ColorPalette.charcoal.opacity(0.10), radius: 14, x: 0, y: 8)
    }

    private var reviewScreen: some View {
        GeometryReader { proxy in
            let contentWidth = min(proxy.size.width - (PocketPixelsTheme.Spacing.screenPadding * 2), 700)

            VStack(spacing: 0) {
                reviewHeader
                    .frame(width: contentWidth)

                reviewPhotoArea(width: contentWidth)
                    .padding(.top, 24)

                reviewActionArea(width: contentWidth)
                    .padding(.top, reviewPhotoToActionSpacing)

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(PocketPixelsTheme.Spacing.screenPadding)
        .onAppear {
            startReviewMotion()
        }
    }

    private var reviewHeader: some View {
        VStack(spacing: 0) {
            PocketPixelsLightboxLockup(scale: .compact)

            Text("Love these?")
                .font(.system(size: 50, weight: .black))
                .foregroundStyle(PocketPixelsTheme.ColorPalette.brandMaroon)
                .multilineTextAlignment(.center)
                .padding(.top, 14)

            Text("Retake any photo, or continue when you're ready.")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(PocketPixelsTheme.ColorPalette.secondaryText)
                .multilineTextAlignment(.center)
                .padding(.top, 12)

            if let selectedBoothFormat = viewModel.selectedBoothFormat {
                Text(selectedBoothFormat.photoCountLabel)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(PocketPixelsTheme.ColorPalette.maroon)
                    .padding(.top, 9)
            }
        }
    }

    @ViewBuilder
    private func reviewPhotoArea(width: CGFloat) -> some View {
        switch viewModel.selectedBoothFormat {
        case .solo:
            reviewSoloLayout(width: width)
        case .duo:
            reviewDuoLayout(width: width)
        case .grid:
            reviewGridLayout(width: width)
        case .strip:
            reviewStripLayout(width: width)
        case nil:
            reviewGridLayout(width: width)
        }
    }

    private func reviewSoloLayout(width: CGFloat) -> some View {
        let photoWidth = min(width * 0.60, 430)

        return HStack {
            Spacer(minLength: 0)
            reviewPhotoItem(index: 0, photoWidth: photoWidth)
                .reviewPhotoEntrance(index: 0, active: reviewMotionActive, reduceMotion: reduceMotion)
            Spacer(minLength: 0)
        }
        .frame(width: width)
    }

    private func reviewDuoLayout(width: CGFloat) -> some View {
        let spacing: CGFloat = 18
        let photoWidth = min(width * 0.82, 560)

        return VStack(spacing: spacing) {
            reviewPhotoItem(index: 0, photoWidth: photoWidth, presentation: .landscape)
                .reviewPhotoEntrance(index: 0, active: reviewMotionActive, reduceMotion: reduceMotion)
            reviewPhotoItem(index: 1, photoWidth: photoWidth, presentation: .landscape)
                .reviewPhotoEntrance(index: 1, active: reviewMotionActive, reduceMotion: reduceMotion)
        }
        .frame(width: width)
    }

    private func reviewGridLayout(width: CGFloat) -> some View {
        let spacing: CGFloat = 16
        let photoWidth = min((width - spacing) / 2, 212)

        return VStack(spacing: spacing) {
            HStack(alignment: .top, spacing: spacing) {
                reviewPhotoItem(index: 0, photoWidth: photoWidth)
                    .reviewPhotoEntrance(index: 0, active: reviewMotionActive, reduceMotion: reduceMotion)
                reviewPhotoItem(index: 1, photoWidth: photoWidth)
                    .reviewPhotoEntrance(index: 1, active: reviewMotionActive, reduceMotion: reduceMotion)
            }
            HStack(alignment: .top, spacing: spacing) {
                reviewPhotoItem(index: 2, photoWidth: photoWidth)
                    .reviewPhotoEntrance(index: 2, active: reviewMotionActive, reduceMotion: reduceMotion)
                reviewPhotoItem(index: 3, photoWidth: photoWidth)
                    .reviewPhotoEntrance(index: 3, active: reviewMotionActive, reduceMotion: reduceMotion)
            }
        }
        .frame(width: width)
    }

    private func reviewStripLayout(width: CGFloat) -> some View {
        let spacing: CGFloat = 14
        let photoWidth = min(width * 0.82, 560)

        return VStack(spacing: spacing) {
            reviewPhotoItem(index: 0, photoWidth: photoWidth, presentation: .landscape)
                .reviewPhotoEntrance(index: 0, active: reviewMotionActive, reduceMotion: reduceMotion)
            reviewPhotoItem(index: 1, photoWidth: photoWidth, presentation: .landscape)
                .reviewPhotoEntrance(index: 1, active: reviewMotionActive, reduceMotion: reduceMotion)
            reviewPhotoItem(index: 2, photoWidth: photoWidth, presentation: .landscape)
                .reviewPhotoEntrance(index: 2, active: reviewMotionActive, reduceMotion: reduceMotion)
        }
        .frame(width: width)
    }

    private func reviewPhotoItem(index: Int, photoWidth: CGFloat, presentation: ReviewPhotoPresentation = .portrait) -> some View {
        VStack(spacing: 10) {
            reviewPhoto(index: index, presentation: presentation)
                .frame(width: photoWidth)

            Button("Retake") {
                viewModel.retakePhoto(at: index)
            }
            .buttonStyle(PocketPixelsSecondaryButtonStyle())
            .disabled(!viewModel.capturedPhotos.indices.contains(index) || !viewModel.canReturnToReview)
            .accessibilityLabel("Retake photo \(index + 1)")
        }
    }

    private func reviewPhoto(index: Int, presentation: ReviewPhotoPresentation = .portrait) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14)
                .fill(PocketPixelsTheme.ColorPalette.acrylic)

            if viewModel.capturedPhotos.indices.contains(index) {
                let image = presentation == .landscape
                    ? ReceiptComposer.makeLandscapePresentationPhoto(from: viewModel.capturedPhotos[index])
                    : viewModel.capturedPhotos[index]

                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .aspectRatio(presentation.aspectRatio, contentMode: .fill)
                    .id(reviewPhotoIdentifier(at: index))
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.975)))
            } else {
                Text("Missing")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(PocketPixelsTheme.ColorPalette.secondaryText)
            }
        }
        .aspectRatio(presentation.aspectRatio, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(PocketPixelsTheme.ColorPalette.border.opacity(0.58), lineWidth: 1)
        }
        .shadow(color: PocketPixelsTheme.ColorPalette.amberGlow.opacity(0.10), radius: 12, x: 0, y: 5)
        .shadow(color: PocketPixelsTheme.ColorPalette.charcoal.opacity(0.08), radius: 9, x: 0, y: 5)
        .accessibilityLabel("Photo \(index + 1)")
        .animation(PocketPixelsTheme.Motion.standardAnimation, value: reviewPhotoIdentifier(at: index))
    }

    private func reviewActionArea(width: CGFloat) -> some View {
        VStack(spacing: 0) {
            Button {
                viewModel.continueToReceipt()
            } label: {
                Text("Continue")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(PocketPixelsPrimaryButtonStyle())
            .frame(width: width * 0.74)
            .disabled(!viewModel.canContinueToReceipt)

            Button("Retake All") {
                viewModel.retakeAll()
            }
            .buttonStyle(PocketPixelsSecondaryButtonStyle())
            .disabled(!viewModel.canReturnToReview)
            .padding(.top, 16)

            Button("Cancel") {
                showingCancelConfirmation = true
            }
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(PocketPixelsTheme.ColorPalette.secondaryText)
            .frame(minHeight: 48)
            .padding(.top, 20)
        }
        .frame(width: width)
    }

    private var receiptScreen: some View {
        GeometryReader { proxy in
            let availableHeight = max(1, proxy.size.height - (PocketPixelsTheme.Spacing.screenPadding * 2))
            let contentWidth = min(proxy.size.width - (PocketPixelsTheme.Spacing.screenPadding * 2), 760)
            let statusCardWidth = contentWidth * 0.72
            let statusQRSize = min(max(contentWidth * 0.16, 120), 140)
            let verticalSpacing: CGFloat = 14
            let reservedHeight = receiptReservedScreenHeight(
                statusQRSize: statusQRSize,
                isPrinterWorking: viewModel.printerState.isWorking
            )
            let receiptMaxWidth = min(contentWidth, 500)
            let receiptMaxHeight = max(180, availableHeight - reservedHeight - (verticalSpacing * 3))

            VStack(spacing: verticalSpacing) {
                receiptCustomerHeader
                    .frame(width: contentWidth)

                customerReceiptPreview(maxWidth: receiptMaxWidth, maxHeight: receiptMaxHeight)
                    .pocketPixelsEntrance(
                        active: receiptMotionActive,
                        reduceMotion: reduceMotion,
                        delay: 0,
                        offset: PocketPixelsTheme.Motion.receiptOffset,
                        scale: PocketPixelsTheme.Motion.subtleScale
                    )

                receiptCustomerActions(width: contentWidth)
                    .pocketPixelsEntrance(active: receiptMotionActive, reduceMotion: reduceMotion, delay: 0.08, offset: 8)

                receiptGalleryStatus(qrSize: statusQRSize)
                    .frame(width: statusCardWidth)
                    .pocketPixelsEntrance(active: receiptMotionActive, reduceMotion: reduceMotion, delay: 0.12, offset: 8)

#if DEBUG
                receiptDebugSection(width: contentWidth)
#endif
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.vertical, 6)
        }
        .padding(PocketPixelsTheme.Spacing.screenPadding)
        .onAppear {
            startReceiptMotion()
        }
    }

    private var receiptCustomerHeader: some View {
        VStack(spacing: 8) {
            PocketPixelsLightboxLockup(scale: .compact)

            Text("Your receipt is ready")
                .font(.system(size: 42, weight: .black))
                .foregroundStyle(PocketPixelsTheme.ColorPalette.brandMaroon)
                .multilineTextAlignment(.center)

            Text("Take a quick look, then print your copy.")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(PocketPixelsTheme.ColorPalette.secondaryText)
                .multilineTextAlignment(.center)
        }
    }

    private func receiptReservedScreenHeight(statusQRSize: CGFloat, isPrinterWorking: Bool) -> CGFloat {
        let headerEstimate: CGFloat = 126
        let actionEstimate: CGFloat = isPrinterWorking ? 106 : 70
        let galleryEstimate = statusQRSize + 32
        let debugDisclosureEstimate: CGFloat
#if DEBUG
        debugDisclosureEstimate = showingReceiptDebugTools ? 292 : 36
#else
        debugDisclosureEstimate = 0
#endif

        return headerEstimate + actionEstimate + galleryEstimate + debugDisclosureEstimate
    }

    private func customerReceiptPreview(maxWidth: CGFloat, maxHeight: CGFloat) -> some View {
        Group {
            if let previewImage = viewModel.receiptPhotoPreviewImage ?? viewModel.receiptImage {
                let previewSize = receiptPreviewDisplaySize(for: previewImage, maxWidth: maxWidth, maxHeight: maxHeight)
                Image(uiImage: previewImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: previewSize.width, height: previewSize.height)
            } else {
                Text("Receipt preview is getting ready.")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(PocketPixelsTheme.ColorPalette.secondaryText)
                    .frame(width: maxWidth, height: min(maxHeight, 320))
                    .background(PocketPixelsTheme.ColorPalette.surface)
            }
        }
        .background(PocketPixelsTheme.ColorPalette.surface)
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(PocketPixelsTheme.ColorPalette.border.opacity(0.58), lineWidth: 1)
        }
        .shadow(color: PocketPixelsTheme.ColorPalette.amberGlow.opacity(0.12), radius: 18, x: 0, y: 8)
        .shadow(color: PocketPixelsTheme.ColorPalette.charcoal.opacity(0.10), radius: 14, x: 0, y: 7)
        .accessibilityLabel("Receipt preview")
    }

    private func receiptPreviewDisplaySize(for image: UIImage, maxWidth: CGFloat, maxHeight: CGFloat) -> CGSize {
        guard image.size.width > 0, image.size.height > 0 else {
            let fallbackSize = min(maxWidth, maxHeight)
            return CGSize(width: fallbackSize, height: fallbackSize)
        }

        let scale = min(maxWidth / image.size.width, maxHeight / image.size.height)
        return CGSize(width: image.size.width * scale, height: image.size.height * scale)
    }

    private func receiptCustomerActions(width: CGFloat) -> some View {
        VStack(spacing: 12) {
            if viewModel.printerState.isWorking {
                HStack(spacing: 10) {
                    ProgressView()
                        .tint(PocketPixelsTheme.ColorPalette.maroon)

                    Text("Printing your receipt...")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(PocketPixelsTheme.ColorPalette.secondaryText)
                }
                .transition(.opacity)
            }

            Button {
                viewModel.printReceipt(host: printerIP, port: parsedPort)
            } label: {
                Text("Print Receipt")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(PocketPixelsPrimaryButtonStyle())
            .frame(width: width * 0.74)
            .disabled(viewModel.receiptRasterizedImage == nil || viewModel.printerState.isWorking || viewModel.printerState.requiresPrinterRestart)
        }
        .frame(width: width)
        .animation(PocketPixelsTheme.Motion.quickAnimation, value: viewModel.printerState.isWorking)
    }

    private func receiptGalleryStatus(qrSize: CGFloat) -> some View {
        HStack(spacing: 26) {
            if let qrImage = viewModel.galleryQRCodeImage {
                Image(uiImage: qrImage)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: qrSize, height: qrSize)
                    .padding(8)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .accessibilityLabel("Gallery QR code")
            }

            Text(receiptGalleryStatusText)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(PocketPixelsTheme.ColorPalette.secondaryText)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .id(receiptGalleryStatusText)
                .transition(.opacity)
        }
        .padding(.vertical, 20)
        .padding(.horizontal, 24)
        .background(PocketPixelsTheme.ColorPalette.acrylic.opacity(0.82))
        .overlay {
            RoundedRectangle(cornerRadius: PocketPixelsTheme.Radius.card)
                .stroke(PocketPixelsTheme.ColorPalette.brandMaroon.opacity(0.18), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: PocketPixelsTheme.Radius.card))
        .shadow(color: PocketPixelsTheme.ColorPalette.amberGlow.opacity(0.10), radius: 12, x: 0, y: 5)
        .animation(PocketPixelsTheme.Motion.standardAnimation, value: receiptGalleryStatusText)
    }

#if DEBUG
    private func receiptDebugSection(width: CGFloat) -> some View {
        VStack(spacing: 12) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    showingReceiptDebugTools.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Text("Show Debug Tools")
                    Image(systemName: showingReceiptDebugTools ? "chevron.up" : "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(PocketPixelsTheme.ColorPalette.secondaryText)
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(showingReceiptDebugTools ? "Hide Debug Tools" : "Show Debug Tools")

            if showingReceiptDebugTools {
                receiptDebugTools(width: width)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(width: width)
    }

    private func receiptDebugTools(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Debug Tools")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.white)

            HStack(alignment: .top, spacing: 16) {
                ReceiptPreviewView(title: "Thermal Receipt Preview", image: viewModel.thermalReceiptPreview)
                    .frame(maxWidth: 300)

                VStack(alignment: .leading, spacing: 14) {
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
                    .disabled(viewModel.printerState.isWorking || viewModel.printerState.requiresPrinterRestart)

                    Button("Rebuild Receipt") {
                        viewModel.rebuildReceipt()
                    }
                    .buttonStyle(.bordered)
                    .disabled(viewModel.printerState.isWorking)

                    Button("End Session (No Print)", role: .destructive) {
                        showingEndNoPrintConfirmation = true
                    }
                    .buttonStyle(.bordered)
                    .disabled(viewModel.printerState.isWorking)
                }
            }
        }
        .padding(18)
        .frame(width: width, alignment: .leading)
        .background(Color.black.opacity(0.82))
        .clipShape(RoundedRectangle(cornerRadius: PocketPixelsTheme.Radius.card))
    }
#endif

    private var recoveryScreen: some View {
        recoveryScreen(message: viewModel.printerState.message)
    }

    private func recoveryScreen(message: String) -> some View {
        GeometryReader { proxy in
            let contentWidth = min(proxy.size.width - (PocketPixelsTheme.Spacing.screenPadding * 2), 620)

            VStack(spacing: 18) {
                Spacer()

                PocketPixelsLightboxLockup(scale: .compact)

                Text("Printer needs attention")
                    .font(.system(size: 46, weight: .black))
                    .foregroundStyle(PocketPixelsTheme.ColorPalette.brandMaroon)
                    .multilineTextAlignment(.center)

                Text("Please ask the booth operator for help. Your photos are still saved for this session.")
                    .font(.system(size: 20, weight: .medium))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(PocketPixelsTheme.ColorPalette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: contentWidth)

                Button("I Restarted the Printer") {
                    viewModel.confirmPrinterRestarted()
                }
                .buttonStyle(PocketPixelsPrimaryButtonStyle())
                .padding(.top, 18)

#if DEBUG
                Text(message)
                    .font(.system(size: 15, weight: .medium))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(PocketPixelsTheme.ColorPalette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: contentWidth)
                    .padding(.top, 8)
#endif

                Spacer()
            }
            .frame(width: contentWidth)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(PocketPixelsTheme.Spacing.screenPadding)
    }

    private var thankYouScreen: some View {
        GeometryReader { proxy in
            let contentWidth = min(proxy.size.width - (PocketPixelsTheme.Spacing.screenPadding * 2), 620)
            let qrSize = min(max(contentWidth * 0.52, 280), 340)

            VStack(spacing: 0) {
                Spacer(minLength: 48)

                VStack(spacing: 12) {
                    PocketPixelsLightboxLockup(scale: .medium)

                    Text("You're all set!")
                        .font(.system(size: 52, weight: .black))
                        .foregroundStyle(PocketPixelsTheme.ColorPalette.brandMaroon)
                        .multilineTextAlignment(.center)
                }
                .pocketPixelsEntrance(active: thankYouMotionActive, reduceMotion: reduceMotion, delay: 0, offset: 0, scale: 0.985)

                thankYouQRCode(size: qrSize)
                    .padding(.top, 34)
                    .pocketPixelsEntrance(active: thankYouMotionActive, reduceMotion: reduceMotion, delay: 0.08, offset: 0, scale: 0.97)

                VStack(spacing: 10) {
                    Text("Scan to view and save your photos.")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(PocketPixelsTheme.ColorPalette.charcoal)
                        .multilineTextAlignment(.center)

                    Text("The same QR is on your receipt.")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(PocketPixelsTheme.ColorPalette.secondaryText)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 22)
                .pocketPixelsEntrance(active: thankYouMotionActive, reduceMotion: reduceMotion, delay: 0.16, offset: 8)

                thankYouGalleryStatus
                    .padding(.top, 14)
                    .pocketPixelsEntrance(active: thankYouMotionActive, reduceMotion: reduceMotion, delay: 0.22, offset: 8)

                Button {
                    viewModel.resetAfterDone()
                } label: {
                    Text("Done")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PocketPixelsPrimaryButtonStyle())
                .frame(width: contentWidth * 0.74)
                .padding(.top, 40)
                .pocketPixelsEntrance(active: thankYouMotionActive, reduceMotion: reduceMotion, delay: 0.28, offset: 8)

                Spacer(minLength: 64)
            }
            .frame(width: contentWidth)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(PocketPixelsTheme.Spacing.screenPadding)
        .transition(.opacity)
        .onAppear {
            startThankYouMotion()
        }
    }

    private func thankYouQRCode(size: CGFloat) -> some View {
        Group {
            if let qrImage = viewModel.galleryQRCodeImage {
                Image(uiImage: qrImage)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size, height: size)
                    .accessibilityLabel("Gallery QR code")
            } else {
                Text("QR is getting ready.")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(PocketPixelsTheme.ColorPalette.secondaryText)
                    .frame(width: size, height: size)
            }
        }
        .padding(16)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(PocketPixelsTheme.ColorPalette.border.opacity(0.52), lineWidth: 1)
        }
        .shadow(color: PocketPixelsTheme.ColorPalette.amberGlow.opacity(0.14), radius: 18, x: 0, y: 8)
        .shadow(color: PocketPixelsTheme.ColorPalette.charcoal.opacity(0.09), radius: 12, x: 0, y: 7)
    }

    private var thankYouGalleryStatus: some View {
        Text(thankYouGalleryStatusText)
            .font(.system(size: 18, weight: .medium))
            .foregroundStyle(PocketPixelsTheme.ColorPalette.secondaryText)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 12)
            .padding(.horizontal, 18)
            .background(PocketPixelsTheme.ColorPalette.acrylic.opacity(0.82))
            .overlay {
                RoundedRectangle(cornerRadius: PocketPixelsTheme.Radius.card)
                    .stroke(PocketPixelsTheme.ColorPalette.brandMaroon.opacity(0.16), lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: PocketPixelsTheme.Radius.card))
    }

    private func progressScreen(title: String, message: String) -> some View {
        GeometryReader { proxy in
            let contentWidth = min(proxy.size.width - (PocketPixelsTheme.Spacing.screenPadding * 2), 560)

            VStack(spacing: 18) {
                Spacer()

                PocketPixelsLightboxLockup(scale: .compact)

                ProgressView()
                    .tint(PocketPixelsTheme.ColorPalette.maroon)
                    .scaleEffect(1.35)
                    .opacity(reduceMotion || !progressMotionActive ? 1 : 0.64)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 1.15).repeatForever(autoreverses: true), value: progressMotionActive)

                Text(title)
                    .font(.system(size: 44, weight: .black))
                    .foregroundStyle(PocketPixelsTheme.ColorPalette.brandMaroon)
                    .multilineTextAlignment(.center)

                Text(message)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(PocketPixelsTheme.ColorPalette.secondaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: contentWidth)

                Spacer()
            }
            .frame(width: contentWidth)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(PocketPixelsTheme.Spacing.screenPadding)
        .onAppear {
            progressMotionActive = false
            guard !reduceMotion else {
                progressMotionActive = true
                return
            }

            DispatchQueue.main.async {
                progressMotionActive = true
            }
        }
    }

    private func errorScreen(message: String) -> some View {
        GeometryReader { proxy in
            let contentWidth = min(proxy.size.width - (PocketPixelsTheme.Spacing.screenPadding * 2), 620)

            VStack(spacing: 18) {
                Spacer()

                PocketPixelsLightboxLockup(scale: .compact)

                Text("Something needs attention")
                    .font(.system(size: 46, weight: .black))
                    .foregroundStyle(PocketPixelsTheme.ColorPalette.brandMaroon)
                    .multilineTextAlignment(.center)

                Text("Please ask the booth operator for help.")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(PocketPixelsTheme.ColorPalette.secondaryText)
                    .multilineTextAlignment(.center)

#if DEBUG
                Text(message)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(PocketPixelsTheme.ColorPalette.secondaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: contentWidth)
                    .padding(.top, 4)
#endif

                Button("Cancel") {
                    showingCancelConfirmation = true
                }
                .buttonStyle(PocketPixelsSecondaryButtonStyle())
                .padding(.top, 16)

                Spacer()
            }
            .frame(width: contentWidth)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(PocketPixelsTheme.Spacing.screenPadding)
    }

    private var sessionTopBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                PocketPixelsLightboxLockup(scale: .compact)
                Text(viewModel.sessionIdentifier ?? viewModel.state.title)
                    .foregroundStyle(PocketPixelsTheme.ColorPalette.secondaryText)
            }

            Spacer()

            Text(viewModel.state.title)
                .font(.headline)
                .foregroundStyle(PocketPixelsTheme.ColorPalette.brandMaroon)
        }
    }

    private var simulatorFallback: some View {
        VStack(spacing: 14) {
            Image(systemName: "camera.slash")
                .font(.system(size: 58))
                .foregroundStyle(.white.opacity(0.75))

            #if DEBUG
            Text("Development-only sample photo fallback")
                .font(.title2.bold())
                .foregroundStyle(.white)

            Text("The iPad camera must be tested on a physical device. Select sample photos to continue.")
                .foregroundStyle(.white.opacity(0.68))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
            #else
            Text("Camera needs attention")
                .font(.title2.bold())
                .foregroundStyle(.white)

            Text("Please ask the booth operator for help.")
                .foregroundStyle(.white.opacity(0.68))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
            #endif
        }
        .padding(32)
    }

    private var samplePhotoPicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            PhotosPicker(selection: $selectedSamplePhotoItem, matching: .images) {
                Label("Use Sample Photo", systemImage: "photo")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(PocketPixelsPrimaryButtonStyle())

            Text("Sample photos selected: \(viewModel.samplePhotoCount) of \(viewModel.requiredPhotoCount)")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(PocketPixelsTheme.ColorPalette.secondaryText)
                .frame(maxWidth: .infinity, alignment: .center)
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

    private var reviewPhotoToActionSpacing: CGFloat {
        switch viewModel.selectedBoothFormat {
        case .grid:
            36
        case .duo:
            34
        case .strip:
            30
        case .solo, nil:
            44
        }
    }

    private var usesLandscapeCompositionGuide: Bool {
        viewModel.selectedBoothFormat == .duo || viewModel.selectedBoothFormat == .strip
    }

    private var cameraCustomerStatusText: String {
        switch viewModel.state {
        case .preparingCamera:
            "Getting camera ready."
        case .cameraReady:
            viewModel.isCameraUnavailable ? "Select sample photos to continue." : "Ready when you are."
        case .countdown:
            "Look at the camera."
        case .capturing:
            "Hold still."
        case .betweenPhotos:
            "Nice. Next photo..."
        case .retaking:
            "Retaking photo."
        default:
            viewModel.statusMessage
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

    private var receiptGalleryStatusText: String {
        switch viewModel.uploadPhase {
        case .success:
            "Your photos are ready by QR."
        case .pendingNoInternet, .deliveryUnknown, .retryAvailable:
            "Your photos are still uploading. Your QR will stay the same."
        case .unauthorized, .serverRejected, .failed:
            "Your gallery needs operator attention."
        case .idle, .preparing, .checkingInternet, .uploading:
            "Your photos are still uploading. Your QR will stay the same."
        }
    }

    private var thankYouGalleryStatusText: String {
        switch viewModel.uploadPhase {
        case .success:
            "Your gallery is ready."
        case .idle, .preparing, .checkingInternet, .uploading, .pendingNoInternet, .deliveryUnknown, .retryAvailable:
            "Your photos are still uploading. This QR will stay the same."
        case .unauthorized, .serverRejected, .failed:
            "Your gallery needs a little more time."
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

    private func handleCustomerStateChange(from oldState: BoothSessionState?, to newState: BoothSessionState) {
        if case .capturing = newState {
            triggerShutterFlash()
        }

        if case .welcome = newState {
            formatMotionActive = false
            reviewMotionActive = false
            receiptMotionActive = false
            thankYouMotionActive = false
        }

        if case .choosingFormat = newState {
            reviewMotionActive = false
            receiptMotionActive = false
            thankYouMotionActive = false
        }

        if case .preparingCamera = newState {
            reviewMotionActive = false
        }

        if case .review = newState, oldState == nil {
            reviewMotionActive = false
            startReviewMotion()
        }
    }

    private func startWelcomeMotion() {
        welcomeMotionActive = false
        welcomeReceiptFloatActive = false

        DispatchQueue.main.async {
            welcomeMotionActive = true
            guard !reduceMotion else {
                return
            }

            welcomeReceiptFloatActive = true
        }
    }

    private func startFormatMotion() {
        guard !formatMotionActive else {
            return
        }

        formatMotionActive = false
        DispatchQueue.main.async {
            formatMotionActive = true
        }
    }

    private func startReviewMotion() {
        guard !reviewMotionActive else {
            return
        }

        reviewMotionActive = false
        DispatchQueue.main.async {
            reviewMotionActive = true
        }
    }

    private func startReceiptMotion() {
        guard !receiptMotionActive else {
            return
        }

        receiptMotionActive = false
        DispatchQueue.main.async {
            receiptMotionActive = true
        }
    }

    private func startThankYouMotion() {
        guard !thankYouMotionActive else {
            return
        }

        thankYouMotionActive = false
        DispatchQueue.main.async {
            thankYouMotionActive = true
        }
    }

    private func triggerShutterFlash() {
        guard !reduceMotion else {
            return
        }

        withAnimation(.easeOut(duration: 0.04)) {
            shutterFlashActive = true
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + PocketPixelsTheme.Motion.shutterFlashDuration) {
            withAnimation(.easeOut(duration: 0.10)) {
                shutterFlashActive = false
            }
        }
    }

    private func reviewPhotoIdentifier(at index: Int) -> String {
        guard viewModel.capturedPhotos.indices.contains(index) else {
            return "missing-\(index)"
        }

        return "\(index)-\(ObjectIdentifier(viewModel.capturedPhotos[index]).hashValue)"
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
        .background(PocketPixelsTheme.ColorPalette.warningSurface.opacity(0.92))
        .overlay {
            RoundedRectangle(cornerRadius: PocketPixelsTheme.Radius.card)
                .stroke(PocketPixelsTheme.ColorPalette.brandMaroon.opacity(0.18), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: PocketPixelsTheme.Radius.card))
    }

    private var welcomeReceiptVisual: some View {
        Image("WelcomeReceiptVisual")
            .resizable()
            .scaledToFit()
            .accessibilityHidden(true)
            .allowsHitTesting(false)
            .onAppear {
                assertWelcomeReceiptVisualAssetExists()
            }
    }

    private func formatCard(_ format: BoothFormat, cardHeight: CGFloat, previewHeight: CGFloat) -> some View {
        return Button {
            viewModel.selectBoothFormat(format)
        } label: {
            VStack(alignment: .leading, spacing: 16) {
                formatPreview(format)
                    .frame(maxWidth: .infinity)
                    .frame(height: previewHeight)

                VStack(alignment: .leading, spacing: 5) {
                    Text(format.displayName.uppercased())
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(PocketPixelsTheme.ColorPalette.brandMaroon)

                    Text(format.photoCountLabel)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(PocketPixelsTheme.ColorPalette.maroon)

                    Text(customerFormatDescription(for: format))
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(PocketPixelsTheme.ColorPalette.secondaryText)
                }
            }
            .padding(PocketPixelsTheme.Spacing.card)
            .frame(maxWidth: .infinity, minHeight: cardHeight, alignment: .topLeading)
            .background(PocketPixelsTheme.ColorPalette.acrylic.opacity(0.94))
            .overlay {
                RoundedRectangle(cornerRadius: PocketPixelsTheme.Radius.card)
                    .stroke(PocketPixelsTheme.ColorPalette.brandMaroon.opacity(0.22), lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: PocketPixelsTheme.Radius.card))
        }
        .buttonStyle(FormatCardButtonStyle())
    }

    private func formatPreview(_ format: BoothFormat) -> some View {
        GeometryReader { proxy in
            let footprint = formatPreviewFootprint(for: format, availableWidth: proxy.size.width, availableHeight: proxy.size.height)

            ZStack {
                previewFrames(for: format, footprint: footprint)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }

    @ViewBuilder
    private func previewFrames(for format: BoothFormat, footprint: CGSize) -> some View {
        switch format {
        case .solo:
            previewPhoto(width: footprint.width * 0.66, height: footprint.width * 0.88)
        case .duo:
            let spacing = footprint.height * 0.09
            let tileHeight = (footprint.height - spacing) / 2
            let tileWidth = min(tileHeight * (4.0 / 3.0), footprint.width * 0.92)
            VStack(spacing: spacing) {
                previewPhoto(width: tileWidth, height: tileHeight)
                previewPhoto(width: tileWidth, height: tileHeight)
            }
        case .grid:
            VStack(spacing: footprint.width * 0.07) {
                HStack(spacing: footprint.width * 0.07) {
                    previewPhoto(width: footprint.width * 0.33, height: footprint.width * 0.44)
                    previewPhoto(width: footprint.width * 0.33, height: footprint.width * 0.44)
                }
                HStack(spacing: footprint.width * 0.07) {
                    previewPhoto(width: footprint.width * 0.33, height: footprint.width * 0.44)
                    previewPhoto(width: footprint.width * 0.33, height: footprint.width * 0.44)
                }
            }
        case .strip:
            let spacing = footprint.height * 0.055
            let tileHeight = (footprint.height - (spacing * 2)) / 3
            let tileWidth = min(tileHeight * (4.0 / 3.0), footprint.width * 0.92)
            VStack(spacing: spacing) {
                ForEach(0..<3, id: \.self) { _ in
                    previewPhoto(width: tileWidth, height: tileHeight)
                }
            }
        }
    }

    private func previewPhoto(width: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(PocketPixelsTheme.ColorPalette.brandBlush.opacity(0.38))
            .overlay {
                abstractPhotoMotif()
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 3)
                    .stroke(PocketPixelsTheme.ColorPalette.brandMaroon.opacity(0.22), lineWidth: 1)
            }
            .frame(width: width, height: height)
    }

    private func abstractPhotoMotif() -> some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            let baseSize = min(width, height)

            ZStack {
                Circle()
                    .fill(PocketPixelsTheme.ColorPalette.paperWarm.opacity(0.52))
                    .frame(width: baseSize * 0.34, height: baseSize * 0.34)
                    .offset(x: -width * 0.22, y: -height * 0.22)

                RoundedRectangle(cornerRadius: baseSize * 0.18)
                    .fill(PocketPixelsTheme.ColorPalette.maroonMuted.opacity(0.10))
                    .frame(width: width * 0.58, height: height * 0.46)
                    .offset(x: width * 0.16, y: height * 0.06)

                RoundedRectangle(cornerRadius: baseSize * 0.16)
                    .fill(PocketPixelsTheme.ColorPalette.acrylic.opacity(0.30))
                    .frame(width: width * 0.62, height: height * 0.34)
                    .offset(x: -width * 0.05, y: height * 0.22)
            }
            .frame(width: width, height: height)
        }
    }

    private func formatPreviewFootprint(for format: BoothFormat, availableWidth: CGFloat, availableHeight: CGFloat) -> CGSize {
        let height = min(availableHeight - 4, 188)
        return CGSize(width: formatPreviewWidth(for: format, availableWidth: availableWidth), height: height)
    }

    private func formatPreviewWidth(for format: BoothFormat, availableWidth: CGFloat) -> CGFloat {
        switch format {
        case .solo:
            min(availableWidth * 0.48, 148)
        case .duo:
            min(availableWidth * 0.46, 142)
        case .grid:
            min(availableWidth * 0.58, 174)
        case .strip:
            min(availableWidth * 0.34, 104)
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

    private func assertWelcomeReceiptVisualAssetExists() {
#if DEBUG
        assert(UIImage(named: "WelcomeReceiptVisual") != nil, "Missing WelcomeReceiptVisual image asset")
#endif
    }
}

private enum ReviewPhotoPresentation {
    case portrait
    case landscape

    var aspectRatio: CGFloat {
        switch self {
        case .portrait:
            return 3.0 / 4.0
        case .landscape:
            return ReceiptComposer.landscapePresentationAspectRatio
        }
    }
}

private struct FormatBackButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isEnabled ? PocketPixelsTheme.ColorPalette.brandMaroon : PocketPixelsTheme.ColorPalette.secondaryText)
            .background(
                RoundedRectangle(cornerRadius: PocketPixelsTheme.Radius.button)
                    .fill(PocketPixelsTheme.ColorPalette.brandBlush.opacity(configuration.isPressed ? 0.30 : 0.16))
            )
            .overlay {
                RoundedRectangle(cornerRadius: PocketPixelsTheme.Radius.button)
                    .stroke(PocketPixelsTheme.ColorPalette.brandMaroon.opacity(isEnabled ? 0.18 : 0.12), lineWidth: 1)
            }
            .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 0.985 : 1))
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private extension View {
    func pocketPixelsEntrance(
        active: Bool,
        reduceMotion: Bool,
        delay: TimeInterval = 0,
        offset: CGFloat = PocketPixelsTheme.Motion.entranceOffset,
        scale: CGFloat = 1
    ) -> some View {
        opacity(active ? 1 : 0)
            .offset(y: reduceMotion ? 0 : (active ? 0 : offset))
            .scaleEffect(reduceMotion ? 1 : (active ? 1 : scale))
            .animation(
                (reduceMotion ? Animation.easeOut(duration: PocketPixelsTheme.Motion.quick) : PocketPixelsTheme.Motion.entranceAnimation)
                    .delay(delay),
                value: active
            )
    }

    func reviewPhotoEntrance(index: Int, active: Bool, reduceMotion: Bool) -> some View {
        pocketPixelsEntrance(
            active: active,
            reduceMotion: reduceMotion,
            delay: Double(index) * PocketPixelsTheme.Motion.stagger,
            offset: 8,
            scale: 0.975
        )
    }
}
