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
    private let onAdminAccessRequested: (() -> Void)?
    private let showsReceiptDebugTools: Bool
    @State private var selectedSamplePhotoItem: PhotosPickerItem?
    @State private var showingCancelConfirmation = false
    @State private var welcomeMotionActive = false
    @State private var formatMotionActive = false
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
        MadeToKeepWelcomeView(
            eventIdentity: welcomeEventIdentity,
            isStartDisabled: viewModel.state.isActiveSession,
            showsPrinterWarning: isPrinterKnownUnavailable,
            motionActive: welcomeMotionActive,
            onStart: { viewModel.startSession() },
            onAdminLongPress: onAdminAccessRequested == nil ? nil : { openAdminAccess() }
        )
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
        GeometryReader { proxy in
            let contentWidth = clampedContentWidth(for: proxy, maximum: MadeToKeepTheme.Layout.maxContentWidth)
            let formats = BoothFormat.allCases
            let columnCount = Self.formatColumnCount
            let rowCount = max(1, Int((Double(formats.count) / Double(columnCount)).rounded(.up)))
            let cardHeight = min(max((proxy.size.height - 220) / CGFloat(rowCount) - 10, 240), 320)
            let cardWidth = max(1, (contentWidth - 20 * CGFloat(columnCount - 1)) / CGFloat(columnCount))
            let previewHeight = cardHeight - 154

            let gridSpacing: CGFloat = 20
            let headerToGridSpacing: CGFloat = 8
            let estimatedHeaderHeight: CGFloat = 150
            let estimatedContentHeight = estimatedHeaderHeight + headerToGridSpacing + (cardHeight * CGFloat(rowCount)) + gridSpacing * CGFloat(rowCount - 1)
            let topPadding = max(((proxy.size.height - estimatedContentHeight) / 2) - 62, 24)

            ScrollView {
                VStack(alignment: .leading, spacing: headerToGridSpacing) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 10) {
                            MadeToKeepLockup(scale: .compact)
                                .padding(.bottom, 8)

                            MadeToKeepTrackedText(
                                text: MadeToKeepBrand.formatHeadline,
                                font: MadeToKeepTheme.Typography.sans(size: 30, weight: .medium),
                                size: 30,
                                tracking: MadeToKeepTheme.Tracking.descriptor
                            )
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .accessibilityAddTraits(.isHeader)

                            MadeToKeepRule(width: 54)

                            Text("Pick how your little moment will print.")
                                .font(MadeToKeepTheme.Typography.italicSerif(size: 24))
                                .foregroundStyle(MadeToKeepTheme.ColorPalette.burgundySoft)
                        }

                        Spacer()

                        Button {
                            viewModel.cancelSession()
                        } label: {
                            Label("Back", systemImage: "chevron.left")
                                .font(.system(size: 16, weight: .medium))
                                .labelStyle(.titleAndIcon)
                                .padding(.horizontal, 16)
                                .frame(minHeight: 46)
                        }
                        .buttonStyle(FormatBackButtonStyle())
                    }
                    .frame(width: contentWidth)

                    VStack(alignment: .leading, spacing: gridSpacing) {
                        ForEach(0..<rowCount, id: \.self) { row in
                            HStack(spacing: gridSpacing) {
                                ForEach(Array(formats.dropFirst(row * columnCount).prefix(columnCount))) { format in
                                    formatCard(format, cardHeight: cardHeight, previewHeight: previewHeight)
                                        .frame(width: cardWidth)
                                }
                            }
                        }
                    }
                    .frame(width: contentWidth)
                }
                .frame(width: contentWidth)
                .padding(.top, topPadding)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .padding(MadeToKeepTheme.Spacing.screenPadding)
        .transition(.opacity)
        .onAppear {
            startFormatMotion()
        }
    }

    private static let formatColumnCount = 3

    private var cameraScreen: some View {
        GeometryReader { proxy in
            let contentWidth = clampedContentWidth(for: proxy, maximum: 620)
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
                        .font(MadeToKeepTheme.Typography.italicSerif(size: 28))
                        .foregroundStyle(MadeToKeepTheme.ColorPalette.burgundy)
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

                Spacer(minLength: 0)
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

    private var cameraPreviewSurface: some View {
        ZStack {
            RoundedRectangle(cornerRadius: MadeToKeepTheme.Radius.photo)
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
        }
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

    private var reviewScreen: some View {
        GeometryReader { proxy in
            let contentWidth = clampedContentWidth(for: proxy, maximum: 700)

            if viewModel.selectedBoothFormat == .gridSix && proxy.size.width > proxy.size.height {
                HStack(spacing: 28) {
                    VStack(spacing: 24) {
                        reviewHeader
                        reviewActionArea(width: contentWidth * 0.68)
                        Spacer(minLength: 0)
                    }
                    .frame(width: proxy.size.width * 0.46)
                    GeometryReader { photoArea in
                        ScrollView {
                            reviewGridSixLayout(width: photoArea.size.width, availableHeight: photoArea.size.height)
                        }
                    }
                }
            } else {
                VStack(spacing: 0) {
                    reviewHeader
                        .frame(width: contentWidth)

                    if viewModel.selectedBoothFormat == .gridSix {
                        GeometryReader { photoArea in
                            ScrollView {
                                reviewGridSixLayout(width: contentWidth, availableHeight: photoArea.size.height)
                            }
                        }
                        .padding(.top, 24)
                        reviewActionArea(width: contentWidth)
                            .padding(.top, reviewPhotoToActionSpacing)
                    } else {
                        reviewPhotoArea(width: contentWidth, availableHeight: proxy.size.height)
                            .padding(.top, 24)
                        reviewActionArea(width: contentWidth)
                            .padding(.top, reviewPhotoToActionSpacing)
                    }

                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(MadeToKeepTheme.Spacing.screenPadding)
        .onAppear {
            startReviewMotion()
        }
    }

    private var reviewHeader: some View {
        VStack(spacing: 0) {
            MadeToKeepLockup(scale: .compact)

            MadeToKeepEditorialHeader(
                eyebrow: viewModel.selectedBoothFormat.map { "\($0.displayName) · \($0.photoCountLabel)".uppercased() } ?? "YOUR PHOTOS",
                title: "love these?",
                subtitle: viewModel.isPassportSession
                    ? "Retake either photo, then add your name."
                    : "Retake any photo, or continue when you're ready.",
                titleSize: 52
            )
            .padding(.top, 16)
        }
    }

    @ViewBuilder
    private func reviewPhotoArea(width: CGFloat, availableHeight: CGFloat) -> some View {
        switch viewModel.selectedBoothFormat {
        case .solo:
            reviewSoloLayout(width: width)
        case .duo:
            reviewDuoLayout(width: width)
        case .grid:
            reviewGridLayout(width: width)
        case .gridSix:
            reviewGridSixLayout(width: width, availableHeight: availableHeight)
        case .strip:
            reviewStripLayout(width: width)
        case .passport:
            reviewPassportLayout(width: width)
        case nil:
            reviewGridLayout(width: width)
        }
    }

    /// Portrait and hero side by side at equal heights, each labelled with its passport role.
    private func reviewPassportLayout(width: CGFloat) -> some View {
        let spacing: CGFloat = 20
        // portraitWidth * 4/3 == heroWidth * 3/4  =>  heroWidth = portraitWidth * 16/9
        let portraitWidth = min(floor((width - spacing) * 9 / 25), 250)
        let heroWidth = floor(portraitWidth * 16 / 9)

        return HStack(alignment: .top, spacing: spacing) {
            reviewPassportItem(role: .portrait, photoWidth: portraitWidth)
                .reviewPhotoEntrance(index: 0, active: reviewMotionActive, reduceMotion: reduceMotion)
            reviewPassportItem(role: .hero, photoWidth: heroWidth)
                .reviewPhotoEntrance(index: 1, active: reviewMotionActive, reduceMotion: reduceMotion)
        }
        .frame(width: width)
    }

    private func reviewPassportItem(role: PassportPhotoRole, photoWidth: CGFloat) -> some View {
        let index = role.rawValue
        return VStack(spacing: 10) {
            VStack(spacing: 2) {
                MadeToKeepLabel(text: "Photo \(index + 1)", size: 12)
                Text(role.title.lowercased())
                    .font(MadeToKeepTheme.Typography.italicSerif(size: 24))
                    .foregroundStyle(MadeToKeepTheme.ColorPalette.burgundy)
            }

            reviewPhoto(index: index, presentation: role == .hero ? .landscape : .portrait, passportRole: role)
                .frame(width: photoWidth)

            Button("Retake Photo \(index + 1)") {
                viewModel.retakePhoto(at: index)
            }
            .buttonStyle(MadeToKeepSecondaryButtonStyle())
            .disabled(!viewModel.capturedPhotos.indices.contains(index) || !viewModel.canReturnToReview)
            .accessibilityLabel("Retake Photo \(index + 1), \(role.title)")
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

    private func reviewGridSixLayout(width: CGFloat, availableHeight: CGFloat) -> some View {
        let spacing: CGFloat = 12
        // Three portrait rows, three 48-point retake controls, and established gaps.
        let controlsAndGaps: CGFloat = 3 * (48 + 10) + 2 * spacing + 16
        let photoWidth = max(1, min((width - spacing) / 2, 170, max(90, (availableHeight - controlsAndGaps) / 4)))
        return VStack(spacing: spacing) {
            ForEach(0..<3, id: \.self) { row in
                HStack(alignment: .top, spacing: spacing) {
                    ForEach(0..<2, id: \.self) { column in
                        let index = row * 2 + column
                        reviewPhotoItem(index: index, photoWidth: photoWidth)
                            .reviewPhotoEntrance(index: index, active: reviewMotionActive, reduceMotion: reduceMotion)
                    }
                }
            }
        }
        .frame(width: width)
        .padding(.vertical, 8)
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
            .buttonStyle(MadeToKeepSecondaryButtonStyle())
            .disabled(!viewModel.capturedPhotos.indices.contains(index) || !viewModel.canReturnToReview)
            .accessibilityLabel("Retake photo \(index + 1)")
        }
    }

    private func reviewPhoto(index: Int, presentation: ReviewPhotoPresentation = .portrait, passportRole: PassportPhotoRole? = nil) -> some View {
        ZStack {
            Rectangle()
                .fill(MadeToKeepTheme.ColorPalette.ivoryShade)

            if viewModel.capturedPhotos.indices.contains(index) {
                let image = if let passportRole {
                    // Same crop the receipt uses, so review matches the printed card.
                    PassportPhotoProcessor.presentationPhoto(from: viewModel.capturedPhotos[index], role: passportRole)
                } else if presentation == .landscape {
                    ReceiptComposer.makeLandscapePresentationPhoto(from: viewModel.capturedPhotos[index])
                } else {
                    viewModel.capturedPhotos[index]
                }

                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .aspectRatio(presentation.aspectRatio, contentMode: .fill)
                    .id(reviewPhotoIdentifier(at: index))
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.975)))
            } else {
                Text("Missing")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(MadeToKeepTheme.ColorPalette.secondaryText)
            }
        }
        .aspectRatio(presentation.aspectRatio, contentMode: .fit)
        .clipped()
        // Photobooth print: thin ivory border and a soft paper shadow.
        .padding(5)
        .background(MadeToKeepTheme.ColorPalette.ivoryLight)
        .overlay {
            Rectangle()
                .strokeBorder(MadeToKeepTheme.ColorPalette.hairline, lineWidth: 1)
        }
        .shadow(color: MadeToKeepTheme.ColorPalette.shadowTint.opacity(0.14), radius: 8, x: 0, y: 4)
        .accessibilityLabel(passportRole.map { "Photo \(index + 1), \($0.title)" } ?? "Photo \(index + 1)")
        .animation(MadeToKeepTheme.Motion.standardAnimation, value: reviewPhotoIdentifier(at: index))
    }

    private func reviewActionArea(width: CGFloat) -> some View {
        VStack(spacing: 0) {
            Button {
                viewModel.continueFromReview()
            } label: {
                Text(viewModel.isPassportSession ? "Continue to Details" : "Continue")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(MadeToKeepPrimaryButtonStyle())
            .frame(width: width * 0.74)
            .disabled(!viewModel.canContinueFromReview)

            Button("Retake All") {
                viewModel.retakeAll()
            }
            .buttonStyle(MadeToKeepSecondaryButtonStyle())
            .disabled(!viewModel.canReturnToReview)
            .padding(.top, 16)

            Button("Cancel") {
                showingCancelConfirmation = true
            }
            .font(.system(size: 15, weight: .medium))
            .tracking(15 * 0.18)
            .textCase(.uppercase)
            .foregroundStyle(MadeToKeepTheme.ColorPalette.mutedInk)
            .frame(minHeight: 48)
            .padding(.top, 18)
        }
        .frame(width: width)
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
                isPrinterWorking: viewModel.printerState.isWorking,
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
        let debugDisclosureEstimate: CGFloat
#if DEBUG
        debugDisclosureEstimate = showingReceiptDebugTools ? 292 : 36
#else
        debugDisclosureEstimate = 0
#endif

        return headerEstimate + actionEstimate + galleryEstimate + debugDisclosureEstimate
    }

    private func customerReceiptPreview(maxWidth: CGFloat, maxHeight: CGFloat, showsPrinterSlot: Bool) -> some View {
        VStack(spacing: 0) {

            Group {
                if let previewImage = viewModel.receiptImage, showsPrinterSlot {
                    FeedingReceiptView(image: previewImage, maxWidth: maxWidth, maxHeight: maxHeight,
                                       isPrinting: viewModel.state == .printing)
                } else if let previewImage = viewModel.receiptImage {
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
        .accessibilityLabel("Receipt preview")
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
            if viewModel.printerState.isWorking {
                HStack(spacing: 10) {
                    ProgressView()
                        .tint(MadeToKeepTheme.ColorPalette.maroon)

                    Text(viewModel.printProgressText)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(MadeToKeepTheme.ColorPalette.secondaryText)
                }
                .transition(.opacity)
            }

            if !viewModel.printerState.isWorking {
                VStack(spacing: 6) {
                    MadeToKeepLabel(text: "Copies", size: 12, color: MadeToKeepTheme.ColorPalette.mutedInk)

                    receiptCopyStepper
                        .frame(width: min(controlWidth * 0.66, 210))
                        .disabled(viewModel.isPrintBatchActive || viewModel.printerState.requiresPrinterRestart)
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
            .disabled(viewModel.receiptRasterizedImage == nil || viewModel.printerState.isWorking || viewModel.isPrintBatchActive || viewModel.printerState.requiresPrinterRestart)
        }
        .frame(width: width)
        .animation(MadeToKeepTheme.Motion.quickAnimation, value: viewModel.printerState.isWorking)
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

    private var thankYouScreen: some View {
        GeometryReader { proxy in
            let contentWidth = clampedContentWidth(for: proxy, maximum: 620)
            let qrSize = min(max(contentWidth * 0.52, 280), 340)

            VStack(spacing: 0) {
                Spacer(minLength: 48)

                VStack(spacing: 16) {
                    MadeToKeepLockup(scale: .medium)

                    MadeToKeepTrackedText(
                        text: MadeToKeepBrand.thankYouHeadline,
                        font: MadeToKeepTheme.Typography.sans(size: 22, weight: .medium),
                        size: 22,
                        tracking: MadeToKeepTheme.Tracking.descriptor
                    )
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .accessibilityAddTraits(.isHeader)

                    MadeToKeepRule(width: 54)
                }
                .pocketPixelsEntrance(active: thankYouMotionActive, reduceMotion: reduceMotion, delay: 0, offset: 0, scale: 0.985)

                thankYouQRCode(size: qrSize)
                    .padding(.top, 34)
                    .pocketPixelsEntrance(active: thankYouMotionActive, reduceMotion: reduceMotion, delay: 0.08, offset: 0, scale: 0.97)

                VStack(spacing: 10) {
                    Text("scan to view and save your photos.")
                        .font(MadeToKeepTheme.Typography.italicSerif(size: 28))
                        .foregroundStyle(MadeToKeepTheme.ColorPalette.burgundy)
                        .multilineTextAlignment(.center)

                    Text("The same QR is on your receipt.")
                        .font(MadeToKeepTheme.Typography.sans(size: 17, weight: .regular))
                        .foregroundStyle(MadeToKeepTheme.ColorPalette.secondaryText)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 22)
                .pocketPixelsEntrance(active: thankYouMotionActive, reduceMotion: reduceMotion, delay: 0.16, offset: 8)

                thankYouGalleryStatus
                    .padding(.top, 14)
                    .pocketPixelsEntrance(active: thankYouMotionActive, reduceMotion: reduceMotion, delay: 0.22, offset: 8)

                if let message = customerThankYouMessage {
                    Text(message)
                        .font(MadeToKeepTheme.Typography.italicSerif(size: 22))
                        .foregroundStyle(viewModel.customerTheme.customerTextColor)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .frame(width: contentWidth * 0.82)
                        .padding(.top, 14)
                }

                Button {
                    viewModel.resetAfterDone()
                } label: {
                    Text("Start Another Session")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(MadeToKeepPrimaryButtonStyle())
                .frame(width: contentWidth * 0.74)
                .padding(.top, 40)
                .pocketPixelsEntrance(active: thankYouMotionActive, reduceMotion: reduceMotion, delay: 0.28, offset: 8)

                Spacer(minLength: 64)
            }
            .frame(width: contentWidth)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(MadeToKeepTheme.Spacing.screenPadding)
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
                    .foregroundStyle(MadeToKeepTheme.ColorPalette.secondaryText)
                    .frame(width: size, height: size)
            }
        }
        // Solid white quiet zone: no paper texture or imagery ever sits behind the QR.
        .padding(18)
        .background(Color.white)
        .overlay {
            Rectangle()
                .strokeBorder(MadeToKeepTheme.ColorPalette.burgundy.opacity(0.35), lineWidth: 1)
        }
        .shadow(color: MadeToKeepTheme.ColorPalette.shadowTint.opacity(0.14), radius: 12, x: 0, y: 6)
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

    private var reviewPhotoToActionSpacing: CGFloat {
        switch viewModel.selectedBoothFormat {
        case .gridSix:
            20
        case .grid:
            36
        case .duo:
            34
        case .strip:
            30
        case .passport:
            30
        case .solo, nil:
            44
        }
    }

    private var usesLandscapeCompositionGuide: Bool {
        if let role = cameraPassportRole {
            return role == .hero
        }
        return viewModel.selectedBoothFormat == .duo || viewModel.selectedBoothFormat == .strip
    }

    private var cameraCustomerStatusText: String {
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

    private func formatCard(_ format: BoothFormat, cardHeight: CGFloat, previewHeight: CGFloat) -> some View {
        return Button {
            viewModel.selectBoothFormat(format)
        } label: {
            VStack(alignment: .leading, spacing: 14) {
                formatPreview(format)
                    .frame(maxWidth: .infinity)
                    .frame(height: previewHeight)

                Rectangle()
                    .fill(MadeToKeepTheme.ColorPalette.burgundy.opacity(0.22))
                    .frame(height: 1)

                VStack(alignment: .leading, spacing: 4) {
                    Text(format.displayName.lowercased())
                        .font(MadeToKeepTheme.Typography.italicSerif(size: 32))
                        .foregroundStyle(MadeToKeepTheme.ColorPalette.burgundy)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)

                    MadeToKeepLabel(text: format.photoCountLabel, size: 12)

                    Text(customerFormatDescription(for: format))
                        .font(MadeToKeepTheme.Typography.sans(size: 15, weight: .regular))
                        .foregroundStyle(MadeToKeepTheme.ColorPalette.mutedInk)
                }
            }
            .padding(MadeToKeepTheme.Spacing.card)
            .frame(maxWidth: .infinity, minHeight: cardHeight, alignment: .topLeading)
            .overlay(alignment: .topTrailing) {
                if format == .passport {
                    MadeToKeepLabel(text: "Keepsake", size: 10)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .overlay(Capsule().strokeBorder(MadeToKeepTheme.ColorPalette.burgundy.opacity(0.6), lineWidth: 1))
                        .padding(12)
                        .accessibilityHidden(true)
                }
            }
            // Printed contact-sheet card: ivory stock, hairline burgundy edge, near-square corners.
            .background(MadeToKeepTheme.ColorPalette.ivoryLight.opacity(0.9))
            .overlay {
                RoundedRectangle(cornerRadius: MadeToKeepTheme.Radius.card)
                    .strokeBorder(MadeToKeepTheme.ColorPalette.burgundy.opacity(format == .passport ? 0.55 : 0.28), lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: MadeToKeepTheme.Radius.card))
        }
        .buttonStyle(FormatCardButtonStyle())
        .accessibilityLabel(formatAccessibilityLabel(for: format))
    }

    private func formatAccessibilityLabel(for format: BoothFormat) -> String {
        switch format {
        case .passport:
            "Photo Pass, 2 photos. A two-photo event keepsake with your name, an optional note and your signature."
        default:
            "\(format.displayName), \(format.photoCountLabel). \(customerFormatDescription(for: format))"
        }
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
        case .gridSix:
            let gap = footprint.height * 0.04
            let tileHeight = (footprint.height - gap * 2) / 3
            VStack(spacing: gap) {
                ForEach(0..<3, id: \.self) { _ in
                    HStack(spacing: gap) {
                        previewPhoto(width: tileHeight * 0.75, height: tileHeight)
                        previewPhoto(width: tileHeight * 0.75, height: tileHeight)
                    }
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
        case .passport:
            PassportFormatPreview(size: footprint)
        }
    }

    private func previewPhoto(width: CGFloat, height: CGFloat) -> some View {
        Rectangle()
            .fill(MadeToKeepTheme.ColorPalette.ivoryShade)
            .overlay {
                abstractPhotoMotif()
                    .clipped()
            }
            .overlay {
                Rectangle()
                    .strokeBorder(MadeToKeepTheme.ColorPalette.taupe.opacity(0.55), lineWidth: 1)
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
                    .fill(MadeToKeepTheme.ColorPalette.ivoryLight.opacity(0.7))
                    .frame(width: baseSize * 0.34, height: baseSize * 0.34)
                    .offset(x: -width * 0.22, y: -height * 0.22)

                RoundedRectangle(cornerRadius: baseSize * 0.18)
                    .fill(MadeToKeepTheme.ColorPalette.taupe.opacity(0.32))
                    .frame(width: width * 0.58, height: height * 0.46)
                    .offset(x: width * 0.16, y: height * 0.06)

                RoundedRectangle(cornerRadius: baseSize * 0.16)
                    .fill(MadeToKeepTheme.ColorPalette.taupe.opacity(0.18))
                    .frame(width: width * 0.62, height: height * 0.34)
                    .offset(x: -width * 0.05, y: height * 0.22)
            }
            .frame(width: width, height: height)
        }
    }

    private func formatPreviewFootprint(for format: BoothFormat, availableWidth: CGFloat, availableHeight: CGFloat) -> CGSize {
        let height = max(1, min(availableHeight - 4, 188))
        let requestedWidth = formatPreviewWidth(for: format, availableWidth: max(1, availableWidth))
        let width: CGFloat
        switch format {
        case .solo: width = min(requestedWidth, height / 0.88)
        case .grid: width = min(requestedWidth, height / 0.95)
        case .duo, .strip, .gridSix: width = requestedWidth
        case .passport: width = min(requestedWidth, height * 1.25)
        }
        return CGSize(width: width, height: height)
    }

    private func formatPreviewWidth(for format: BoothFormat, availableWidth: CGFloat) -> CGFloat {
        switch format {
        case .solo:
            min(availableWidth * 0.48, 148)
        case .duo:
            min(availableWidth * 0.46, 142)
        case .grid, .gridSix:
            min(availableWidth * 0.58, 174)
        case .strip:
            min(availableWidth * 0.34, 104)
        case .passport:
            min(availableWidth * 0.80, 232)
        }
    }

    private func customerFormatDescription(for format: BoothFormat) -> String {
        switch format {
        case .solo:
            "One portrait"
        case .duo:
            "Two moments"
        case .gridSix:
            "Six-photo collage"
        case .grid:
            "Four-photo collage"
        case .strip:
            "Classic photo strip"
        case .passport:
            "Two-photo event keepsake"
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
            .foregroundStyle(isEnabled ? MadeToKeepTheme.ColorPalette.burgundy : MadeToKeepTheme.ColorPalette.secondaryText)
            .background(
                Capsule()
                    .fill(MadeToKeepTheme.ColorPalette.ivoryLight.opacity(configuration.isPressed ? 0.95 : 0.6))
            )
            .overlay {
                Capsule()
                    .strokeBorder(MadeToKeepTheme.ColorPalette.burgundy.opacity(isEnabled ? 0.45 : 0.18), lineWidth: 1)
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

    func reviewPhotoEntrance(index: Int, active: Bool, reduceMotion: Bool) -> some View {
        pocketPixelsEntrance(
            active: active,
            reduceMotion: reduceMotion,
            delay: Double(index) * MadeToKeepTheme.Motion.stagger,
            offset: 8,
            scale: 0.975
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
