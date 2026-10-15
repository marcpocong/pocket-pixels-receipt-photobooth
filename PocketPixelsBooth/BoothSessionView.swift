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
    @ObservedObject private var operations = EventOperationalState.shared
    @ObservedObject private var paymentRecovery = PaymentRecoveryCoordinator.shared
    private let onAdminAccessRequested: (() -> Void)?
    private let showsReceiptDebugTools: Bool
    @State private var selectedSamplePhotoItem: PhotosPickerItem?
    @State private var showingCancelConfirmation = false
    @State private var welcomeMotionActive = false
    @State private var formatMotionActive = false
    @State private var chosenFormat: BoothFormat?
    @State private var reviewMotionActive = false
    @State private var receiptMotionActive = false
    @State private var progressMotionActive = false
    @State private var thankYouMotionActive = false
    @State private var shutterFlashActive = false
    @State private var idleResetTask: Task<Void, Never>?
    @State private var showsIdleWarning = false
    @State private var idleSecondsRemaining = CustomerIdleResetPolicy.warningDuration
#if DEBUG
    @State private var showingEndNoPrintConfirmation = false
    @State private var showingReceiptDebugTools = false
#endif
    /// Customer-chosen preview of the exact 1-bit thermal raster. Always starts on the keepsake view.
    @State private var receiptPreviewMode = ReceiptPreviewMode.keepsake
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("printerIP") private var printerIP = BoothConfiguration.defaultPrinterIP
    @AppStorage("printerPort") private var printerPort = BoothConfiguration.defaultPrinterPort

    init(
        onAdminAccessRequested: (() -> Void)? = nil,
        showsReceiptDebugTools: Bool = false,
        viewModel: BoothSessionViewModel? = nil
    ) {
        _viewModel = StateObject(wrappedValue: viewModel ?? BoothSessionViewModel())
        self.onAdminAccessRequested = onAdminAccessRequested
        self.showsReceiptDebugTools = showsReceiptDebugTools
    }

    private func clampedContentWidth(for proxy: GeometryProxy, maximum: CGFloat) -> CGFloat {
        let paddedWidth = proxy.size.width - (MadeToKeepTheme.Spacing.screenPadding * 2)
        guard paddedWidth.isFinite else {
            return 1
        }
        return max(1, min(paddedWidth, maximum))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                boothBackground
                boothContent
                    .id(customerScreenTransitionKey)
                    .transition(customerScreenTransition)

                if showsIdleWarning {
                    idleWarningOverlay
                        .transition(.opacity)
                        .zIndex(10)
                }
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
                if let entitlement = viewModel.checkoutEntitlement,
                   entitlement.authorizationSource != .privatePrepaid,
                   viewModel.capturedPhotos.isEmpty {
                    Text("Return to Welcome? Your paid session stays saved for the attendant to resume. Please do not pay again.")
                } else {
                    Text("All captured photos and the current receipt preview will be cleared.")
                }
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
            .onChange(of: operations.recoveryConfirmation) { _, _ in
                viewModel.resumeAfterOperatorRecovery()
            }
            .onChange(of: selectedSamplePhotoItem) { _, newItem in
                loadSamplePhoto(from: newItem)
            }
            .onChange(of: scenePhase) { _, newPhase in
                viewModel.handleScenePhase(newPhase)
                if newPhase == .active {
                    scheduleIdleReset()
                } else {
                    cancelIdleReset()
                }
            }
            .onChange(of: viewModel.state) { oldState, newState in
                if onAdminAccessRequested != nil {
                    operations.customerSessionActive = newState != .welcome && newState != .thankYou
                }
                handleCustomerStateChange(from: oldState, to: newState)
                scheduleIdleReset()
            }
            .onChange(of: viewModel.selectedPrintCopies) { _, _ in
                scheduleIdleReset()
            }
            .onChange(of: viewModel.passportDraft) { _, _ in
                // Typing or signing counts as activity for the abandoned-session timer.
                scheduleIdleReset()
            }
            .onReceive(NotificationCenter.default.publisher(for: EventProfileStore.didChangeNotification)) { _ in
                viewModel.refreshCustomerExperience()
            }
            .onReceive(NotificationCenter.default.publisher(for: StickerStudioSettingsStore.didChangeNotification)) { _ in
                // Settings apply to the next guest; only a safety switch-off of online use acts now.
                viewModel.handleStickerSettingsChanged()
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
                viewModel.refreshCustomerExperience()
                viewModel.preparePrinter()
                viewModel.retryQueuedGalleryUploads()
                scheduleIdleReset()
            }
            .onDisappear { cancelIdleReset() }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .preferredColorScheme(.light)
    }

    @ViewBuilder
    private var boothBackground: some View {
        MadeToKeepPaperBackground(tint: viewModel.customerTheme == .classic ? nil : viewModel.customerTheme.backgroundColors)
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
        case .choosingCopies:
            "choosingCopies"
        case .choosingPayment:
            "choosingPayment"
        case .awaitingQRPayment:
            "awaitingQRPayment"
        case .cashAttestation:
            "cashAttestation"
        case .paymentReconciliation:
            "paymentReconciliation"
        case .preparingCamera, .cameraReady, .countdown, .capturing, .betweenPhotos, .retaking:
            "camera"
        case .review:
            "review"
        case .passportDetails:
            "passportDetails"
        case .passportSignature:
            "passportSignature"
        case .passportPreview:
            "passportPreview"
        case .preparingStickers:
            "preparingStickers"
        case .stickerStudio:
            "stickerStudio"
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
            insertion: .opacity.combined(with: .offset(y: MadeToKeepTheme.Motion.entranceOffset)),
            removal: .opacity
        )
    }

    private var customerScreenAnimation: Animation {
        reduceMotion ? .easeOut(duration: MadeToKeepTheme.Motion.quick) : MadeToKeepTheme.Motion.screenTransitionAnimation
    }

    @ViewBuilder
    private var boothContent: some View {
        switch viewModel.state {
        case .welcome:
            welcomeScreen
        case .choosingFormat:
            formatSelectionScreen
        case .choosingCopies:
            CheckoutCopySelectionView(viewModel: viewModel)
        case .choosingPayment:
            CheckoutPaymentMethodView(viewModel: viewModel)
        case .awaitingQRPayment:
            QRPhPaymentView(viewModel: viewModel)
        case .cashAttestation:
            CashAttestationView(viewModel: viewModel)
        case .paymentReconciliation:
            PaymentReconciliationView(viewModel: viewModel)
        case .preparingCamera, .cameraReady, .countdown, .capturing, .betweenPhotos, .retaking:
            cameraScreen
        case .review:
            reviewScreen
        case .passportDetails:
            PassportDetailsView(viewModel: viewModel, onCancel: { showingCancelConfirmation = true })
        case .passportSignature:
            PassportSignatureView(viewModel: viewModel, onCancel: { showingCancelConfirmation = true })
        case .passportPreview:
            PassportPreviewView(viewModel: viewModel, onCancel: { showingCancelConfirmation = true })
        case .preparingStickers:
            progressScreen(title: "Getting your stickers ready", message: "Just a moment.")
        case .stickerStudio:
            if let studio = viewModel.stickerStudio {
                StickerStudioView(
                    session: studio,
                    onDone: { viewModel.finishStickerStudio() },
                    onSkip: { viewModel.skipStickerStudio() },
                    onBack: { viewModel.backFromStickerStudio() },
                    onCancel: { showingCancelConfirmation = true },
                    onActivity: { scheduleIdleReset() }
                )
            } else {
                progressScreen(title: "Getting your stickers ready", message: "Just a moment.")
            }
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

    /// Only an explicit attendant action adds a guest prompt. Saved checkout records belong
    /// in operator recovery and must not display another customer's interruption on Welcome.
    @ViewBuilder private var attendantResumeNotice: some View {
        if paymentRecovery.armedResume != nil {
            noticeText("Your attendant has prepared your session. Tap to continue.")
        }
    }

    private func noticeText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 15, weight: .medium, design: .serif))
            .foregroundStyle(MadeToKeepTheme.ColorPalette.mutedInk)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(.thinMaterial, in: Capsule())
            .padding(.top, 54)
            .accessibilityAddTraits(.isStaticText)
    }

    private var welcomeScreen: some View {
        MadeToKeepWelcomeView(
            eventIdentity: welcomeEventIdentity,
            isStartDisabled: viewModel.state.isActiveSession,
            showsPrinterWarning: isPrinterKnownUnavailable,
            motionActive: welcomeMotionActive,
            onStart: { viewModel.startSession() },
            onAdminLongPress: onAdminAccessRequested == nil ? nil : { openAdminAccess() }
        )
        .overlay(alignment: .top) { attendantResumeNotice }
#if DEBUG
        .overlay(alignment: .bottom) {
            if onAdminAccessRequested != nil {
                Button("Open Admin") {
                    openAdminAccess()
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(MadeToKeepTheme.ColorPalette.taupe)
                .buttonStyle(.plain)
                .padding(.bottom, 10)
                .accessibilityLabel("Open Admin diagnostics")
            }
        }
#endif
        .transition(.opacity)
        .onAppear {
            startWelcomeMotion()
        }
        .onDisappear {
            welcomeMotionActive = false
        }
    }

    /// Event Mode adds the event identity to the Made to Keep poster instead of replacing it.
    private var welcomeEventIdentity: MadeToKeepWelcomeEventIdentity? {
        guard let profile = viewModel.customerEventProfile.activeCustomerSnapshot else { return nil }
        let identity = MadeToKeepWelcomeEventIdentity(
            title: profile.customerDisplayTitle,
            subtitle: profile.customerDisplaySubtitle,
            message: profile.customerWelcomeMessage
        )
        return identity.isEmpty ? nil : identity
    }

    private var formatSelectionScreen: some View {
        KeepsakeFormatSelectionView(
            options: KeepsakeFormatOption.all,
            chosenFormat: chosenFormat,
            motionActive: formatMotionActive,
            onSelect: { chooseFormat($0) },
            onBack: { viewModel.cancelSession() }
        )
        .transition(.opacity)
        .onAppear {
            startFormatMotion()
        }
    }

    /// Shows the selected card treatment for a beat, then hands off to the existing selection.
    private func chooseFormat(_ format: BoothFormat) {
        guard chosenFormat == nil, case .choosingFormat = viewModel.state else {
            return
        }

        withAnimation(.easeOut(duration: MadeToKeepTheme.Motion.quick)) {
            chosenFormat = format
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(reduceMotion ? 60 : 160))
            viewModel.selectBoothFormat(format)
            // If the selection was refused (session cancelled, transition busy), unlock the cards.
            if case .choosingFormat = viewModel.state {
                chosenFormat = nil
            }
        }
    }

    private var cameraScreen: some View {
        GeometryReader { proxy in
            let contentWidth = clampedContentWidth(for: proxy, maximum: 620)
            let presentation = cameraPhotoPresentation

            VStack(spacing: 0) {
                cameraTopBar
                    .frame(width: contentWidth)
                    .frame(height: CameraScreenLayout.topBarHeight)

                GeometryReader { compositionProxy in
                    let layout = CameraScreenLayout(
                        available: compositionProxy.size,
                        maximumContentWidth: contentWidth,
                        aspectRatio: presentation.aspectRatio
                    )

                    VStack(spacing: 0) {
                        cameraPreviewSurface(width: layout.viewportSize.width, height: layout.viewportSize.height)

                        Text(cameraCustomerStatusText)
                            .font(MadeToKeepTheme.Typography.italicSerif(size: 28))
                            .foregroundStyle(MadeToKeepTheme.ColorPalette.burgundy)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .minimumScaleFactor(0.82)
                            .frame(width: contentWidth, height: CameraScreenLayout.statusHeight)
                            .padding(.top, CameraScreenLayout.viewportToStatus)

                        CameraPhotoProgress(
                            count: viewModel.requiredPhotoCount,
                            completedCount: completedCameraPhotoCount,
                            activeIndex: cameraPhotoIndex,
                            confirmsCapture: viewModel.transientCapturedPhoto != nil
                        )
                        .frame(height: CameraScreenLayout.progressHeight)
                        .padding(.top, CameraScreenLayout.statusToProgress)

                        ZStack {
                            if case .cameraReady = viewModel.state, !viewModel.isCameraUnavailable {
                                Button {
                                    viewModel.beginPhotoSequence()
                                } label: {
                                    Text("Start Photos")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(MadeToKeepPrimaryButtonStyle())
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
                        .frame(height: CameraScreenLayout.actionHeight)
                        .padding(.top, CameraScreenLayout.progressToAction)
                    }
                    .frame(width: contentWidth, height: layout.compositionHeight)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(MadeToKeepTheme.Spacing.screenPadding)
    }

    private var cameraTopBar: some View {
        HStack(alignment: .center) {
            MadeToKeepLockup(scale: .compact)
                .frame(width: 180, alignment: .leading)

            Spacer()

            MadeToKeepLabel(text: photoCounterText, size: 16)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .id(photoCounterText)
                .transition(.opacity)
                .animation(MadeToKeepTheme.Motion.quickAnimation, value: photoCounterText)

            Spacer()

            if viewModel.state.allowsCancellation {
                Button("Cancel") {
                    showingCancelConfirmation = true
                }
                .buttonStyle(MadeToKeepSecondaryButtonStyle())
            }
        }
    }

    private func cameraPreviewSurface(width: CGFloat, height: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: MadeToKeepTheme.Radius.photo)
                .fill(Color.black)

            if let transient = viewModel.transientCapturedPhoto {
                Image(uiImage: transient)
                    .resizable()
                    .scaledToFill()
                    .frame(width: width, height: height)
                    .clipped()
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 1.015)))
            } else if viewModel.isCameraUnavailable {
                simulatorFallback
            } else {
                CameraPreview(session: viewModel.cameraService.session, cameraService: viewModel.cameraService)
                    .frame(width: width, height: height)
            }

            RoundedRectangle(cornerRadius: MadeToKeepTheme.Radius.photo)
                .strokeBorder(MadeToKeepTheme.ColorPalette.burgundy.opacity(0.7), lineWidth: MadeToKeepTheme.Stroke.hairline)

            if let countdownValue {
                Text("\(countdownValue)")
                    .font(MadeToKeepTheme.Typography.serif(size: 168))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.68), radius: 18, x: 0, y: 8)
                    .transition(.scale(scale: 0.86).combined(with: .opacity))
                    .id(countdownValue)
            }

            if shutterFlashActive {
                Color.white
                    .opacity(MadeToKeepTheme.Motion.shutterFlashOpacity)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }

            if viewModel.transientCapturedPhoto != nil {
                CameraCaptureConfirmation(photoIndex: viewModel.transientCapturedPhotoIndex ?? cameraPhotoIndex)
                    .padding(14)
                    .transition(.opacity)
            }
        }
        .frame(width: width, height: height)
        .animation(.easeOut(duration: 0.18), value: countdownValue)
        .animation(MadeToKeepTheme.Motion.quickAnimation, value: viewModel.transientCapturedPhoto != nil)
        .animation(MadeToKeepTheme.Motion.quickAnimation, value: shutterFlashActive)
        .clipShape(RoundedRectangle(cornerRadius: MadeToKeepTheme.Radius.photo))
        // Printed-photo mount: ivory border around the live feed, never texture on top of it.
        .padding(10)
        .background(MadeToKeepTheme.ColorPalette.ivoryLight)
        .overlay(Rectangle().strokeBorder(MadeToKeepTheme.ColorPalette.hairline, lineWidth: 1))
        .shadow(color: MadeToKeepTheme.ColorPalette.shadowTint.opacity(0.14), radius: 14, x: 0, y: 6)
    }

    /// Every format renders through the editorial review design (`MadeToKeepReviewDesign.swift`);
    /// the actions are the same view-model calls the review always used.
    private var reviewScreen: some View {
        let format = viewModel.selectedBoothFormat ?? .grid
        let spec = MadeToKeepReviewFormatSpec.spec(for: format)
        return MadeToKeepPhotoReviewView(
            spec: spec,
            eyebrow: viewModel.selectedBoothFormat?.reviewSummary ?? "YOUR PHOTOS",
            title: spec.photoCount == 1 ? "Love this?" : "Love these?",
            subtitle: reviewSubtitle(format: format),
            continueTitle: viewModel.isPassportSession ? "Continue to Details" : "Continue",
            photos: (0..<spec.photoCount).map { reviewPhoto(index: $0, format: format) },
            canContinue: viewModel.canContinueFromReview,
            canRetakeAll: viewModel.canReturnToReview,
            motionActive: reviewMotionActive,
            onRetake: { viewModel.retakePhoto(at: $0) },
            onContinue: { viewModel.continueFromReview() },
            onRetakeAll: { viewModel.retakeAll() },
            onCancel: { showingCancelConfirmation = true }
        )
        .onAppear {
            startReviewMotion()
        }
    }

    private func reviewSubtitle(format: BoothFormat) -> String {
        switch format {
        case .passport:
            "Retake either photo, then add your name."
        case .solo:
            "Retake your photo, or continue when you're ready."
        default:
            "Retake any photo, or continue when you're ready."
        }
    }

    private func reviewPhoto(index: Int, format: BoothFormat) -> MadeToKeepPhotoReviewView.Photo {
        let role = format == .passport ? PassportPhotoRole(photoIndex: index) : nil
        // Same shared geometry the receipt uses, so review matches the printed photo.
        let image: UIImage? = if viewModel.capturedPhotos.indices.contains(index) {
            PhotoPresentationGeometry.resolve(format: format, photoIndex: index).uprightPhoto(from: viewModel.capturedPhotos[index])
        } else {
            nil
        }

        return MadeToKeepPhotoReviewView.Photo(
            image: image,
            identifier: reviewPhotoIdentifier(at: index),
            label: role.map { "Photo \(index + 1) · \($0.title)" } ?? "Photo \(index + 1)",
            accessibilityLabel: role.map { "Photo \(index + 1), \($0.title)" } ?? "Photo \(index + 1)",
            retakeAccessibilityLabel: role.map { "Retake Photo \(index + 1), \($0.title)" } ?? "Retake photo \(index + 1)",
            canRetake: viewModel.capturedPhotos.indices.contains(index) && viewModel.canReturnToReview
        )
    }

    private var receiptScreen: some View {
        GeometryReader { proxy in
            let availableHeight = max(1, proxy.size.height - (MadeToKeepTheme.Spacing.screenPadding * 2))
            let contentWidth = clampedContentWidth(for: proxy, maximum: 640)
            let isPostPrintFlow = viewModel.state != .receiptPreview
            let statusCardWidth = min(contentWidth * 0.78, 560)
            let statusQRSize = min(max(contentWidth * 0.20, 150), 180)
            let verticalSpacing: CGFloat = isPostPrintFlow ? 12 : 12
            let reservedHeight = receiptReservedScreenHeight(
                statusQRSize: statusQRSize,
                isPrinterWorking: viewModel.isPrintBatchActive,
                showsGalleryStatus: isPostPrintFlow
            )
            let receiptMaxWidth = isPostPrintFlow
                ? min(contentWidth * 0.66, 480)
                : min(contentWidth * 0.58, 420)
            let receiptAvailableHeight = max(220, availableHeight - reservedHeight - (verticalSpacing * 3))
            let receiptMaxHeight = min(receiptAvailableHeight, isPostPrintFlow ? 480 : 560)

            VStack(spacing: verticalSpacing) {
                receiptCustomerHeader
                    .frame(width: contentWidth)

                customerReceiptPreview(maxWidth: receiptMaxWidth, maxHeight: receiptMaxHeight, showsPrinterSlot: isPostPrintFlow)
                    .pocketPixelsEntrance(
                        active: receiptMotionActive,
                        reduceMotion: reduceMotion,
                        delay: 0,
                        offset: MadeToKeepTheme.Motion.receiptOffset,
                        scale: MadeToKeepTheme.Motion.subtleScale
                    )

                if !isPostPrintFlow {
                    receiptPreviewModePicker(width: receiptMaxWidth)
                }

                receiptCustomerActions(width: contentWidth, preferredControlWidth: receiptMaxWidth)
                    .pocketPixelsEntrance(active: receiptMotionActive, reduceMotion: reduceMotion, delay: 0.08, offset: 8)

                if isPostPrintFlow {
                    receiptGalleryStatus(qrSize: statusQRSize)
                        .frame(width: statusCardWidth)
                        .pocketPixelsEntrance(active: receiptMotionActive, reduceMotion: reduceMotion, delay: 0.12, offset: 8)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .bottom)))
                }

#if DEBUG
                if showsReceiptDebugTools {
                    receiptDebugSection(width: contentWidth)
                }
#endif
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.vertical, 6)
        }
        .padding(MadeToKeepTheme.Spacing.screenPadding)
        .onAppear {
            receiptPreviewMode = .keepsake
            startReceiptMotion()
        }
    }

    private var receiptCustomerHeader: some View {
        VStack(spacing: 8) {
            MadeToKeepLockup(scale: .compact)

            Text(receiptScreenTitle.lowercased())
                .font(MadeToKeepTheme.Typography.italicSerif(size: 38))
                .foregroundStyle(MadeToKeepTheme.ColorPalette.burgundy)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)

            Text(receiptScreenSubtitle)
                .font(MadeToKeepTheme.Typography.sans(size: 16, weight: .regular))
                .foregroundStyle(MadeToKeepTheme.ColorPalette.mutedInk)
                .multilineTextAlignment(.center)
        }
    }

    private func receiptReservedScreenHeight(statusQRSize: CGFloat, isPrinterWorking: Bool, showsGalleryStatus: Bool) -> CGFloat {
        let headerEstimate: CGFloat = 126
        let actionEstimate: CGFloat = isPrinterWorking ? 54 : 124
        let galleryEstimate = showsGalleryStatus ? statusQRSize + 42 : 0
        // The keepsake / as-printed toggle only appears before printing.
        let previewModeEstimate: CGFloat = showsGalleryStatus ? 0 : ReceiptPreviewMode.pickerHeightEstimate
        let debugDisclosureEstimate: CGFloat
#if DEBUG
        debugDisclosureEstimate = showingReceiptDebugTools ? 292 : 36
#else
        debugDisclosureEstimate = 0
#endif

        return headerEstimate + actionEstimate + galleryEstimate + previewModeEstimate + debugDisclosureEstimate
    }

    private func customerReceiptPreview(maxWidth: CGFloat, maxHeight: CGFloat, showsPrinterSlot: Bool) -> some View {
        VStack(spacing: 0) {

            Group {
                if let previewImage = viewModel.receiptImage, showsPrinterSlot {
                    FeedingReceiptView(image: previewImage, maxWidth: maxWidth, maxHeight: maxHeight,
                                       isPrinting: viewModel.state == .printing)
                } else if let previewImage = receiptPreviewMode.image(
                    keepsake: viewModel.receiptImage,
                    thermal: viewModel.thermalReceiptPreview
                ) {
                    let previewLayout = receiptPreviewLayout(for: previewImage, maxWidth: maxWidth, maxHeight: maxHeight)
                    Group {
                        if previewLayout.requiresScrolling {
                            ScrollView(.vertical) {
                                receiptPreviewImage(previewImage, size: previewLayout.displaySize)
                            }
                            .scrollIndicators(.visible)
                            .frame(width: previewLayout.displaySize.width, height: previewLayout.viewportHeight)
                            .overlay(alignment: .bottom) {
                                receiptScrollAffordance(width: previewLayout.displaySize.width)
                            }
                        } else {
                            receiptPreviewImage(previewImage, size: previewLayout.displaySize)
                        }
                    }
                } else {
                    Text("Receipt preview is getting ready.")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(MadeToKeepTheme.ColorPalette.secondaryText)
                        .frame(width: maxWidth, height: min(maxHeight, 320))
                        .background(MadeToKeepTheme.ColorPalette.surface)
                }
            }
            .background(showsPrinterSlot ? Color.clear : MadeToKeepTheme.ColorPalette.surface)
            .overlay {
                Rectangle()
                    .strokeBorder(MadeToKeepTheme.ColorPalette.hairline.opacity(showsPrinterSlot ? 0 : 1), lineWidth: 1)
            }
            .shadow(color: MadeToKeepTheme.ColorPalette.amberGlow.opacity(0.12), radius: 18, x: 0, y: 8)
            .shadow(color: MadeToKeepTheme.ColorPalette.charcoal.opacity(0.10), radius: 14, x: 0, y: 7)
        }
        .accessibilityLabel(receiptPreviewMode == .thermal && !showsPrinterSlot ? "Receipt preview as printed" : "Receipt preview")
    }

    /// A quiet toggle under the pre-print preview. "As printed" shows the actual thermal raster the
    /// printer receives, so guests know the keepsake prints in black and white.
    private func receiptPreviewModePicker(width: CGFloat) -> some View {
        VStack(spacing: 5) {
            HStack(spacing: 6) {
                ForEach(ReceiptPreviewMode.available(motion: false), id: \.self) { mode in
                    let isSelected = receiptPreviewMode == mode
                    Button {
                        receiptPreviewMode = mode
                    } label: {
                        Text(mode.title)
                            .font(MadeToKeepTheme.Typography.sans(size: 13, weight: isSelected ? .semibold : .regular))
                            .foregroundStyle(isSelected ? MadeToKeepTheme.ColorPalette.ivoryLight : MadeToKeepTheme.ColorPalette.burgundy)
                            .padding(.horizontal, 14)
                            .frame(minHeight: 32)
                            .background(isSelected ? MadeToKeepTheme.ColorPalette.burgundy : Color.clear, in: Capsule())
                            .overlay(Capsule().strokeBorder(MadeToKeepTheme.ColorPalette.burgundy.opacity(0.45), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .disabled(mode == .thermal && viewModel.thermalReceiptPreview == nil)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                    .accessibilityIdentifier("receiptPreviewMode.\(mode.rawValue)")
                }
            }

            Text(ReceiptPreviewMode.printNote)
                .font(MadeToKeepTheme.Typography.sans(size: 12, weight: .regular))
                .foregroundStyle(MadeToKeepTheme.ColorPalette.mutedInk)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
        }
        .frame(maxWidth: width)
    }

    private func receiptPreviewImage(_ image: UIImage, size: CGSize) -> some View {
        Image(uiImage: image)
            .resizable()
            .interpolation(.high)
            .frame(width: size.width, height: size.height)
    }

    private func receiptScrollAffordance(width: CGFloat) -> some View {
        VStack(spacing: 4) {
            LinearGradient(
                colors: [
                    MadeToKeepTheme.ColorPalette.surface.opacity(0),
                    MadeToKeepTheme.ColorPalette.surface.opacity(0.92)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 30)

            Text("Scroll to see the full receipt")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(MadeToKeepTheme.ColorPalette.secondaryText)
                .padding(.bottom, 8)
        }
        .frame(width: width)
        .allowsHitTesting(false)
    }

    private func receiptPreviewLayout(for image: UIImage, maxWidth: CGFloat, maxHeight: CGFloat) -> ReceiptPreviewLayout {
        ReceiptPreviewLayout.make(imageSize: image.size, maxWidth: maxWidth, maxHeight: maxHeight)
    }

    struct ReceiptPreviewLayout {
        let displaySize: CGSize
        let viewportHeight: CGFloat
        let scale: CGFloat
        let requiresScrolling: Bool

        static let minimumWholeReceiptWidth: CGFloat = 250
        static let longReceiptDisplayWidth: CGFloat = 360

        static func make(imageSize: CGSize, maxWidth: CGFloat, maxHeight: CGFloat) -> ReceiptPreviewLayout {
            guard imageSize.width > 0, imageSize.height > 0 else {
                let fallbackSize = min(maxWidth, maxHeight)
                return ReceiptPreviewLayout(
                    displaySize: CGSize(width: fallbackSize, height: fallbackSize),
                    viewportHeight: fallbackSize,
                    scale: 1,
                    requiresScrolling: false
                )
            }

            let widthLimit = max(1, maxWidth)
            let heightLimit = max(1, maxHeight)
            let aspectRatio = imageSize.width / imageSize.height
            let wholeFitWidth = min(widthLimit, heightLimit * aspectRatio)

            if wholeFitWidth >= minimumWholeReceiptWidth {
                let scale = wholeFitWidth / imageSize.width
                let displaySize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
                return ReceiptPreviewLayout(
                    displaySize: displaySize,
                    viewportHeight: displaySize.height,
                    scale: scale,
                    requiresScrolling: false
                )
            }

            let displayWidth = min(widthLimit, longReceiptDisplayWidth)
            let scale = displayWidth / imageSize.width
            let displaySize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
            return ReceiptPreviewLayout(
                displaySize: displaySize,
                viewportHeight: min(displaySize.height, heightLimit),
                scale: scale,
                requiresScrolling: displaySize.height > heightLimit
            )
        }
    }

    private func receiptPreviewDisplaySize(for image: UIImage, maxWidth: CGFloat, maxHeight: CGFloat) -> CGSize {
        guard image.size.width > 0, image.size.height > 0 else {
            let fallbackSize = min(maxWidth, maxHeight)
            return CGSize(width: fallbackSize, height: fallbackSize)
        }

        return receiptPreviewLayout(for: image, maxWidth: maxWidth, maxHeight: maxHeight).displaySize
    }

    private func receiptCustomerActions(width: CGFloat, preferredControlWidth: CGFloat? = nil) -> some View {
        let controlWidth = min(preferredControlWidth ?? width * 0.58, 420)

        return VStack(spacing: 9) {
            if viewModel.isPrintBatchActive {
                HStack(spacing: 10) {
                    ProgressView()
                        .tint(MadeToKeepTheme.ColorPalette.maroon)

                    Text(viewModel.printProgressText)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(MadeToKeepTheme.ColorPalette.secondaryText)
                }
                .transition(.opacity)
            }

            if !viewModel.isPrintBatchActive {
                VStack(spacing: 6) {
                    MadeToKeepLabel(text: "Copies", size: 12, color: MadeToKeepTheme.ColorPalette.mutedInk)

                    if viewModel.commercialEvent.activePolicy.commercialMode == .payPerPrint {
                        Text(viewModel.selectedPrintCopies, format: .number)
                            .font(.title.bold())
                            .accessibilityLabel("\(viewModel.selectedPrintCopies) purchased copies")
                        Text("Purchased before the photo session")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        receiptCopyStepper
                            .frame(width: min(controlWidth * 0.66, 210))
                            .disabled(viewModel.isPrintBatchActive || viewModel.printerState.requiresPrinterRestart)
                    }
                }
            }

            Button {
                viewModel.printReceipt(host: printerIP, port: parsedPort)
            } label: {
                Text(viewModel.printButtonTitle)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(MadeToKeepPrimaryButtonStyle())
            .frame(width: controlWidth)
            // Keep the action tappable for recoverable problems so the view model can surface the
            // exact reason instead of leaving customers with a silently disabled control.
            .disabled(viewModel.isPrintBatchActive)

            // Failures before any bytes return to the preview; without this the tap looks ignored.
            if !viewModel.isPrintBatchActive, case .failure(let message) = viewModel.printerState {
                Text(message)
                    .font(MadeToKeepTheme.Typography.sans(size: 15, weight: .medium))
                    .foregroundStyle(MadeToKeepTheme.ColorPalette.burgundy)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: controlWidth)
                    .transition(.opacity)
            }
        }
        .frame(width: width)
        .animation(MadeToKeepTheme.Motion.quickAnimation, value: viewModel.isPrintBatchActive)
    }

    private var receiptCopyStepper: some View {
        HStack(spacing: 0) {
            Button {
                viewModel.decreasePrintCopies()
            } label: {
                Image(systemName: "minus")
                    .font(.system(size: 18, weight: .bold))
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .foregroundStyle(copyStepperControlColor(isEnabled: viewModel.canDecreasePrintCopies))
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.canDecreasePrintCopies)
            .accessibilityLabel("Decrease copies")

            Text("\(viewModel.selectedPrintCopies)")
                .font(MadeToKeepTheme.Typography.serif(size: 28))
                .monospacedDigit()
                .foregroundStyle(MadeToKeepTheme.ColorPalette.brandMaroon)
                .frame(maxWidth: .infinity, minHeight: 48)
                .accessibilityLabel("\(viewModel.selectedPrintCopies) \(viewModel.selectedPrintCopies == 1 ? "copy" : "copies") selected")

            Button {
                viewModel.increasePrintCopies()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .bold))
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .foregroundStyle(copyStepperControlColor(isEnabled: viewModel.canIncreasePrintCopies))
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.canIncreasePrintCopies)
            .accessibilityLabel("Increase copies")
        }
        .background(Capsule().fill(MadeToKeepTheme.ColorPalette.ivoryLight.opacity(0.85)))
        .overlay {
            Capsule()
                .strokeBorder(MadeToKeepTheme.ColorPalette.burgundy.opacity(0.4), lineWidth: 1)
        }
        .clipShape(Capsule())
    }

    private func copyStepperControlColor(isEnabled: Bool) -> Color {
        isEnabled ? MadeToKeepTheme.ColorPalette.brandMaroon : MadeToKeepTheme.ColorPalette.secondaryText.opacity(0.32)
    }

    private func receiptGalleryStatus(qrSize: CGFloat) -> some View {
        HStack(spacing: 22) {
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

            VStack(alignment: .leading, spacing: 6) {
                Text("scan to save your photos")
                    .font(MadeToKeepTheme.Typography.italicSerif(size: 26))
                    .foregroundStyle(MadeToKeepTheme.ColorPalette.burgundy)

                Text(receiptGalleryStatusText)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(MadeToKeepTheme.ColorPalette.secondaryText)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .id(receiptGalleryStatusText)
                    .transition(.opacity)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 18)
        .padding(.horizontal, 24)
        .background(MadeToKeepTheme.ColorPalette.ivoryLight.opacity(0.9))
        .overlay {
            RoundedRectangle(cornerRadius: MadeToKeepTheme.Radius.card)
                .strokeBorder(MadeToKeepTheme.ColorPalette.burgundy.opacity(0.3), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: MadeToKeepTheme.Radius.card))
        .animation(MadeToKeepTheme.Motion.standardAnimation, value: receiptGalleryStatusText)
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
                .foregroundStyle(MadeToKeepTheme.ColorPalette.secondaryText)
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
        .clipShape(RoundedRectangle(cornerRadius: MadeToKeepTheme.Radius.card))
    }
#endif

    private var recoveryScreen: some View {
        recoveryScreen(message: viewModel.printerState.message)
    }

    private func recoveryScreen(message: String) -> some View {
        GeometryReader { proxy in
            let contentWidth = clampedContentWidth(for: proxy, maximum: 620)

            VStack(spacing: 18) {
                Spacer()

                MadeToKeepLockup(scale: .compact)

                MadeToKeepEditorialHeader(eyebrow: "A LITTLE PAUSE", title: "printer needs attention", titleSize: 46)

                Text("Please ask the booth operator for help. Your photos are still saved for this session.")
                    .font(MadeToKeepTheme.Typography.sans(size: 19, weight: .regular))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(MadeToKeepTheme.ColorPalette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: contentWidth)

                Text(message)
                    .font(MadeToKeepTheme.Typography.sans(size: 16, weight: .medium))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(MadeToKeepTheme.ColorPalette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: contentWidth * 0.9)

                Button {
                    openAdminAccess()
                } label: {
                    Label("Open Staff Recovery", systemImage: "wrench.and.screwdriver.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(MadeToKeepSecondaryButtonStyle())
                .frame(width: min(contentWidth * 0.74, 420))
                .accessibilityHint("Opens protected operator controls to restore printer service.")

                Spacer()
            }
            .frame(width: contentWidth)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(MadeToKeepTheme.Spacing.screenPadding)
    }

    private var thankYouScreen: some View {
        SessionThankYouContent(
            qrImage: viewModel.galleryQRCodeImage,
            status: thankYouGalleryStatusText,
            message: customerThankYouMessage,
            startAnotherSession: { viewModel.resetAfterDone() }
        )
        .transition(.opacity)
    }

    private var thankYouGalleryStatus: some View {
        Text(thankYouGalleryStatusText)
            .font(.system(size: 18, weight: .medium))
            .foregroundStyle(MadeToKeepTheme.ColorPalette.secondaryText)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 12)
            .padding(.horizontal, 18)
            .background(MadeToKeepTheme.ColorPalette.ivoryLight.opacity(0.85))
            .overlay {
                RoundedRectangle(cornerRadius: MadeToKeepTheme.Radius.card)
                    .strokeBorder(MadeToKeepTheme.ColorPalette.burgundy.opacity(0.22), lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: MadeToKeepTheme.Radius.card))
    }

    private func progressScreen(title: String, message: String) -> some View {
        GeometryReader { proxy in
            let contentWidth = clampedContentWidth(for: proxy, maximum: 560)

            VStack(spacing: 18) {
                Spacer()

                MadeToKeepLockup(scale: .compact)

                ProgressView()
                    .tint(MadeToKeepTheme.ColorPalette.maroon)
                    .scaleEffect(1.35)
                    .opacity(reduceMotion || !progressMotionActive ? 1 : 0.64)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 1.15).repeatForever(autoreverses: true), value: progressMotionActive)

                Text(title.lowercased())
                    .font(MadeToKeepTheme.Typography.italicSerif(size: 44))
                    .foregroundStyle(MadeToKeepTheme.ColorPalette.burgundy)
                    .multilineTextAlignment(.center)

                Text(message)
                    .font(MadeToKeepTheme.Typography.sans(size: 19, weight: .regular))
                    .foregroundStyle(MadeToKeepTheme.ColorPalette.secondaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: contentWidth)

                Spacer()
            }
            .frame(width: contentWidth)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(MadeToKeepTheme.Spacing.screenPadding)
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
        let customerError = customerErrorKind(for: message)
        return GeometryReader { proxy in
            let contentWidth = clampedContentWidth(for: proxy, maximum: 620)

            VStack(spacing: 18) {
                Spacer()

                MadeToKeepLockup(scale: .compact)

                MadeToKeepEditorialHeader(eyebrow: "A LITTLE PAUSE", title: customerError.title.lowercased(), titleSize: 46)

                Text(customerError.guidance)
                    .font(MadeToKeepTheme.Typography.sans(size: 19, weight: .regular))
                    .foregroundStyle(MadeToKeepTheme.ColorPalette.secondaryText)
                    .multilineTextAlignment(.center)

                Button("Cancel") {
                    showingCancelConfirmation = true
                }
                .buttonStyle(MadeToKeepSecondaryButtonStyle())
                .padding(.top, 16)

                Text("Staff assistance required")
                    .font(.footnote)
                    .foregroundStyle(MadeToKeepTheme.ColorPalette.mutedInk)
                    .onLongPressGesture(minimumDuration: 2) { openAdminAccess() }

                Spacer()
            }
            .frame(width: contentWidth)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(MadeToKeepTheme.Spacing.screenPadding)
    }

    private var customerThankYouMessage: String? {
        guard let profile = viewModel.customerEventProfile.activeCustomerSnapshot else { return nil }
        return profile.customerThankYouMessage.isEmpty ? nil : profile.customerThankYouMessage
    }

    private func customerErrorKind(for technicalMessage: String) -> CustomerErrorKind {
        CustomerErrorKind.classify(technicalMessage: technicalMessage)
    }

    private var idleWarningOverlay: some View {
        ZStack {
            MadeToKeepTheme.ColorPalette.ink.opacity(0.38)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                Text("still there?")
                    .font(MadeToKeepTheme.Typography.italicSerif(size: 46))
                    .foregroundStyle(MadeToKeepTheme.ColorPalette.burgundy)

                Text("Session resets in \(idleSecondsRemaining) seconds")
                    .font(MadeToKeepTheme.Typography.sans(size: 19, weight: .regular))
                    .foregroundStyle(MadeToKeepTheme.ColorPalette.secondaryText)

                Button("Continue Session") {
                    scheduleIdleReset()
                }
                .buttonStyle(MadeToKeepPrimaryButtonStyle())
                .frame(minWidth: 300)
                .padding(.top, 8)
            }
            .padding(38)
            .background(MadeToKeepPaperBackground().clipped())
            .overlay(Rectangle().strokeBorder(MadeToKeepTheme.ColorPalette.burgundy.opacity(0.35), lineWidth: 1))
            .shadow(color: .black.opacity(0.18), radius: 24)
            .accessibilityElement(children: .contain)
        }
    }

    private func scheduleIdleReset() {
        cancelIdleReset()
        guard scenePhase == .active, viewModel.isCustomerResetSafe else { return }

        let state = viewModel.state
        let initialDelay = CustomerIdleResetPolicy.initialDelay(for: state)
        idleResetTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(initialDelay))
                guard viewModel.isCustomerResetSafe, viewModel.state == state else { return }

                idleSecondsRemaining = CustomerIdleResetPolicy.warningDuration
                showsIdleWarning = true
                while idleSecondsRemaining > 0 {
                    try await Task.sleep(for: .seconds(1))
                    guard viewModel.isCustomerResetSafe, viewModel.state == state else {
                        showsIdleWarning = false
                        return
                    }
                    idleSecondsRemaining -= 1
                }

                showsIdleWarning = false
                _ = viewModel.resetAbandonedSessionIfSafe()
            } catch {
                showsIdleWarning = false
            }
        }
    }

    private func cancelIdleReset() {
        idleResetTask?.cancel()
        idleResetTask = nil
        showsIdleWarning = false
        idleSecondsRemaining = CustomerIdleResetPolicy.warningDuration
    }

    private var sessionTopBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                MadeToKeepLockup(scale: .compact)
                Text(viewModel.sessionIdentifier ?? viewModel.state.title)
                    .foregroundStyle(MadeToKeepTheme.ColorPalette.secondaryText)
            }

            Spacer()

            Text(viewModel.state.title)
                .font(.headline)
                .foregroundStyle(MadeToKeepTheme.ColorPalette.brandMaroon)
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
            .buttonStyle(MadeToKeepPrimaryButtonStyle())

            Text("Sample photos selected: \(viewModel.samplePhotoCount) of \(viewModel.requiredPhotoCount)")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(MadeToKeepTheme.ColorPalette.secondaryText)
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

    /// Photo index the camera screen is currently framing.
    private var cameraPhotoIndex: Int {
        switch viewModel.state {
        case .countdown(let index, _), .capturing(let index), .retaking(let index):
            index
        case .betweenPhotos(let nextIndex):
            nextIndex
        default:
            viewModel.nextPhotoIndex
        }
    }

    private var cameraPassportRole: PassportPhotoRole? {
        viewModel.isPassportSession ? PassportPhotoRole(photoIndex: cameraPhotoIndex) : nil
    }

    private var photoCounterText: String {
        if let role = cameraPassportRole {
            return "Photo \(role.rawValue + 1) of 2 · \(role.title)"
        }
        return switch viewModel.state {
        case .countdown(let index, _), .capturing(let index), .retaking(let index):
            "Photo \(index + 1) of \(viewModel.requiredPhotoCount)"
        case .betweenPhotos(let nextIndex):
            "Next: Photo \(nextIndex + 1)"
        default:
            "Photo \(min(viewModel.capturedPhotos.count + 1, viewModel.requiredPhotoCount)) of \(viewModel.requiredPhotoCount)"
        }
    }

    private var cameraPhotoPresentation: CapturePhotoPresentation {
        guard let format = viewModel.selectedBoothFormat else { return .portrait }
        return .resolve(format: format, photoIndex: cameraPhotoIndex)
    }

    private var completedCameraPhotoCount: Int {
        viewModel.capturedPhotos.count
    }

    private var cameraCustomerStatusText: String {
        if viewModel.transientCapturedPhoto != nil {
            return "Got it!"
        }
        if let role = cameraPassportRole, let text = passportCameraStatusText(role: role) {
            return text
        }
        return switch viewModel.state {
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

    private func passportCameraStatusText(role: PassportPhotoRole) -> String? {
        switch viewModel.state {
        case .cameraReady where !viewModel.isCameraUnavailable, .countdown, .retaking:
            role == .portrait
                ? "Portrait time. Look at the camera and make it yours."
                : "One more! Give us your best hero shot."
        case .betweenPhotos:
            "Nice! Next up: your hero photo."
        default:
            nil
        }
    }

    private var receiptScreenTitle: String {
        switch viewModel.state {
        case .connectingToPrinter:
            "Getting your printer ready..."
        case .printing:
            "Printing your keepsake..."
        default:
            "Your receipt is ready"
        }
    }

    private var receiptScreenSubtitle: String {
        switch viewModel.state {
        case .connectingToPrinter, .printing:
            "Scan while your printed copy is on the way."
        default:
            "Take a quick look, then print your copy."
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
        case .idle, .preparing:
            "Preparing your gallery. Your QR will stay the same."
        case .checkingInternet:
            "Waiting for a connection. Your QR will stay the same."
        case .uploading:
            "Uploading your photos. Your QR will stay the same."
        case .pendingNoInternet, .deliveryUnknown, .retryAvailable:
            "Still uploading — your QR will remain the same."
        case .unauthorized, .serverRejected, .failed:
            "Please ask our attendant for help. Your QR will stay the same."
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

    private func handleCustomerStateChange(from oldState: BoothSessionState?, to newState: BoothSessionState) {
        if case .capturing = newState {
            triggerShutterFlash()
        }

        if case .welcome = newState {
            chosenFormat = nil
            formatMotionActive = false
            reviewMotionActive = false
            receiptMotionActive = false
            thankYouMotionActive = false
        }

        if case .choosingFormat = newState {
            chosenFormat = nil
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

        DispatchQueue.main.async {
            welcomeMotionActive = true
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

        DispatchQueue.main.asyncAfter(deadline: .now() + MadeToKeepTheme.Motion.shutterFlashDuration) {
            withAnimation(.easeOut(duration: 0.10)) {
                shutterFlashActive = false
            }
        }
    }

    private func openAdminAccess() {
        guard let onAdminAccessRequested else {
            return
        }

        adminDebugLog("long press recognized")
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        onAdminAccessRequested()
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

/// Geometry contract for the capture screen. The navigation region is separate; this solver
/// centers one stable camera composition in the remaining safe-area height.
struct CameraScreenLayout: Equatable {
    static let topBarHeight: CGFloat = 74
    static let viewportToStatus: CGFloat = 16
    static let statusHeight: CGFloat = 64
    static let statusToProgress: CGFloat = 8
    static let progressHeight: CGFloat = 14
    static let progressToAction: CGFloat = 10
    static let actionHeight: CGFloat = 54
    static let mountInset: CGFloat = 20
    static let maximumViewportWidth: CGFloat = 580

    let viewportSize: CGSize
    let compositionHeight: CGFloat

    init(available: CGSize, maximumContentWidth: CGFloat, aspectRatio: CGFloat) {
        let safeAspectRatio = max(0.1, aspectRatio)
        let chromeHeight = Self.viewportToStatus + Self.statusHeight + Self.statusToProgress
            + Self.progressHeight + Self.progressToAction + Self.actionHeight + Self.mountInset
        let widthLimit = max(1, min(maximumContentWidth - Self.mountInset, Self.maximumViewportWidth))
        let heightLimitedWidth = max(1, (available.height - chromeHeight) * safeAspectRatio)
        let width = floor(min(widthLimit, heightLimitedWidth))
        let height = floor(width / safeAspectRatio)
        viewportSize = CGSize(width: width, height: height)
        compositionHeight = height + chromeHeight
    }
}

private struct CameraCaptureConfirmation: View {
    let photoIndex: Int

    var body: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                HStack(spacing: 7) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .bold))
                    Text("Photo \(photoIndex + 1) captured")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(MadeToKeepTheme.ColorPalette.ivoryLight)
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background(MadeToKeepTheme.ColorPalette.burgundy.opacity(0.9), in: Capsule())
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Photo \(photoIndex + 1) captured")
        .allowsHitTesting(false)
    }
}

private struct CameraPhotoProgress: View {
    let count: Int
    let completedCount: Int
    let activeIndex: Int
    let confirmsCapture: Bool

    var body: some View {
        HStack(spacing: count > 4 ? 8 : 10) {
            ForEach(0..<count, id: \.self) { index in
                Circle()
                    .fill(markerFill(for: index))
                    .frame(width: count > 4 ? 8 : 10, height: count > 4 ? 8 : 10)
                    .overlay {
                        Circle()
                            .strokeBorder(MadeToKeepTheme.ColorPalette.burgundy.opacity(0.72), lineWidth: 1)
                    }
                    .accessibilityLabel("Photo \(index + 1)")
                    .accessibilityValue(index < completedCount ? "captured" : index == activeIndex ? "current" : "pending")
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func markerFill(for index: Int) -> Color {
        if index < completedCount {
            return MadeToKeepTheme.ColorPalette.burgundy
        }
        if index == activeIndex && confirmsCapture {
            return MadeToKeepTheme.ColorPalette.burgundy.opacity(0.72)
        }
        return MadeToKeepTheme.ColorPalette.ivoryLight
    }
}

private extension View {
    func pocketPixelsEntrance(
        active: Bool,
        reduceMotion: Bool,
        delay: TimeInterval = 0,
        offset: CGFloat = MadeToKeepTheme.Motion.entranceOffset,
        scale: CGFloat = 1
    ) -> some View {
        opacity(active ? 1 : 0)
            .offset(y: reduceMotion ? 0 : (active ? 0 : offset))
            .scaleEffect(reduceMotion ? 1 : (active ? 1 : scale))
            .animation(
                (reduceMotion ? Animation.easeOut(duration: MadeToKeepTheme.Motion.quick) : MadeToKeepTheme.Motion.entranceAnimation)
                    .delay(delay),
                value: active
            )
    }
}

nonisolated private func adminDebugLog(_ message: String) {
#if DEBUG
    print("[BoothSessionView][Admin] \(message)")
#endif
}

/// Visual paper feed only; it never schedules or controls a physical print job.
private struct FeedingReceiptView: View {
    let image: UIImage
    let maxWidth: CGFloat
    let maxHeight: CGFloat
    let isPrinting: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var feedStartedAt: Date?

    var body: some View {
        let scale = min(maxWidth / max(1, image.size.width), maxHeight / max(1, image.size.height))
        let width = image.size.width * scale
        let height = image.size.height * scale
        VStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 4)
                .fill(MadeToKeepTheme.ColorPalette.charcoal)
                .frame(width: width + 16, height: 8)
                .zIndex(1)
            TimelineView(.animation(paused: !isPrinting || reduceMotion || scenePhase != .active)) { context in
                let elapsed = feedStartedAt.map { max(0, context.date.timeIntervalSince($0)) } ?? 0
                let progress = min(1, elapsed / MadeToKeepTheme.Motion.printerFeedDuration)
                // Move the actual paper once, from behind the slot into a fixed viewport.
                // At the end it stays out: there is no loop or upward reset.
                let visibleFraction = reduceMotion ? 1 : (isPrinting ? progress : 0.025)
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: width, height: height)
                    .offset(y: -height * (1 - visibleFraction))
                    .frame(width: width, height: height, alignment: .top)
                    .clipped()
            }
        }
        .frame(width: width + 16, height: height + 8, alignment: .top)
        .onChange(of: isPrinting, initial: true) { _, printing in
            feedStartedAt = printing ? Date() : nil
        }
        .accessibilityLabel(isPrinting ? "Receipt feeding out of printer" : "Receipt ready at printer")
    }
}

/// Presentation uses only the session's frozen QR; rendering never creates a token or an upload.
struct SessionThankYouContent: View {
    let qrImage: UIImage?
    let status: String
    var message: String? = nil
    let startAnotherSession: () -> Void
    @ScaledMetric(relativeTo: .title) private var headingSize = 40.0

    var body: some View {
        GeometryReader { proxy in
            let compact = proxy.size.height < 900
            let qrSide = max(1, min(compact ? 260 : 340, proxy.size.width - 100))
            ScrollView {
                VStack(spacing: compact ? 16 : 24) {
                    MadeToKeepLockup(scale: .compact)
                    Text("A little moment, made to keep.")
                        .font(MadeToKeepTheme.Typography.serif(size: headingSize))
                        .accessibilityAddTraits(.isHeader)
                    Group {
                        if let qrImage {
                            Image(uiImage: qrImage)
                                .interpolation(.none)
                                .resizable()
                                .scaledToFit()
                                .accessibilityLabel("Gallery QR code. The same QR is on your receipt.")
                        } else {
                            Text("Preparing your QR. Please ask our attendant for help.")
                                .font(.body)
                        }
                    }
                    .frame(width: qrSide, height: qrSide)
                    .padding(20)
                    .background(Color.white)
                    .overlay { Rectangle().strokeBorder(MadeToKeepTheme.ColorPalette.hairline) }
                    .shadow(color: .black.opacity(0.08), radius: 12, y: 6)
                    Text("Scan to view and save your photos.")
                        .font(MadeToKeepTheme.Typography.body(.title3))
                    Text(status)
                        .font(MadeToKeepTheme.Typography.body(.callout))
                        .foregroundStyle(MadeToKeepTheme.ColorPalette.mutedInk)
                    if let message {
                        Text(message).font(MadeToKeepTheme.Typography.body())
                    }
                    Button("Start Another Session", action: startAnotherSession)
                        .buttonStyle(MadeToKeepPrimaryButtonStyle())
                        .padding(.top, 8)
                }
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.center)
                .foregroundStyle(MadeToKeepTheme.ColorPalette.burgundy)
                .frame(maxWidth: 620)
                .padding(24)
                .frame(maxWidth: .infinity)
                .frame(minHeight: proxy.size.height, alignment: .center)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }
}
