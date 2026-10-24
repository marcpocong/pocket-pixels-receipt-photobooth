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
    private var originalCaptureBytes: [Int: Data] = [:]
    @Published var transientCapturedPhoto: UIImage?
    @Published private(set) var transientCapturedPhotoIndex: Int?
    @Published var composedReceipt: ComposedReceipt?
    @Published var receiptImage: UIImage?
    @Published var receiptPhotoPreviewImage: UIImage?
    /// Exact 1-bit printer raster preview. Operator diagnostics only; never shown to guests.
    @Published var thermalReceiptPreview: UIImage?
    /// Smooth grayscale customer preview ("Black & White"). Presentation only; never printed.
    @Published var monochromeReceiptPreview: UIImage?
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
    @Published private(set) var commercialEvent = CommercialEventRunStore.load()
    @Published private(set) var checkoutEntitlement: CheckoutEntitlement?
    @Published private(set) var paymentOrder: PaymentOrder?
    @Published private(set) var paymentAttempt: PaymentAttempt?
    @Published var selectedCheckoutCopies = 1
    @Published private(set) var policyAuthority: PolicyAuthority = .localPrepaid
    @Published private(set) var checkoutGuard = CheckoutGuard()
    /// Guest-visible checkout notice (for example an updated price or a failed QR start).
    @Published private(set) var paymentNotice: String?
    /// True while the attendant confirms cash or the checkout is being created.
    var isCheckoutTransitionActive: Bool { isTransitionActive }
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
    /// The current guest's sticker draft; nil unless this session reached Sticker Studio.
    @Published private(set) var stickerStudio: StickerStudioSession?

    let cameraService = CameraService()

    private let printerService = PrinterNetworkService()
    private let printerCoordinator = PrinterCoordinator.shared
    private let uploadService = GoogleDriveGalleryUploadService()
    private let credentialStore = DeviceCredentialStore()
    private let recoveryStore: AppRecoveryStore?
    /// Where this session's durable side effects go; `.customer` is production behavior.
    let environment: BoothSessionEnvironment
    /// Durable archive commit for the current session; resolves to nil on success or an error
    /// description on failure. See SessionArchiveCommitter for the durability contract.
    private var archiveCommitTask: Task<String?, Never>?
    private var archiveCommitPayload: RecentSessionArchivePayload?
    private let operationalState = EventOperationalState.shared
    /// Resolved per use so pairing changes take effect without relaunching.
    private var paymentsClient: PaymentsAPIClient? { injectedPaymentsClient ?? PaymentsConfiguration.current().map { PaymentsAPIClient(configuration: $0) } }
    private let injectedPaymentsClient: PaymentsAPIClient?
    private let eventRunStore: EventRunStore?
    private var sessionRunID: String?
    private let offlineCashLedger = OfflineCashLedger.shared
    private var serverEventPolicy: ServerEventPolicy?
    private var offlinePolicyPayload: OfflinePolicyPayload?
    private var supersedeOrderID: String?
    private var checkoutAttempt = 0
    /// One stable print batch per paid entitlement so a retry continues the same receipt.
    private var paidPrintBatchID: UUID?
    private let checkpointStore: CheckoutCheckpointStore?
    private let printOutbox = PrintOutcomeOutbox.shared
    private var activeTask: Task<Void, Never>?
    private var paymentPollTask: Task<Void, Never>?
    private var paymentPollOwner: UUID?
    /// Guest-facing escalation while a payment is being verified. Interface state only.
    @Published private(set) var paymentVerificationStage = PaymentVerificationStage.checking
    private var verificationClock = PaymentVerificationClock()
    private static let interactionLogger = Logger(subsystem: "com.pocketpixels.PocketPixelsBooth", category: "GuestInteraction")

    func logGuestAction(_ action: String, result: String) {
        Self.interactionLogger.notice("action=\(action, privacy: .public) result=\(result, privacy: .public) state=\(self.state.title, privacy: .public) transition=\(self.isTransitionActive) guidedAccess=\(UIAccessibility.isGuidedAccessEnabled)")
    }

    private func stopPaymentPolling() {
        paymentPollOwner = nil
        paymentPollTask?.cancel()
        paymentPollTask = nil
    }

    private func ownsPaymentPolling(_ owner: UUID, generation: Int) -> Bool {
        paymentPollOwner == owner && isCurrentCustomerSession(generation)
            && checkoutEntitlement == nil
            && (state == .awaitingQRPayment || state == .paymentReconciliation)
    }
    private var printBatchTask: Task<Void, Never>?
    private var cameraWatchdogTask: Task<Void, Never>?
    private var galleryUploadTasks: [String: Task<Void, Never>] = [:]
    private var queueRetryTask: Task<Void, Never>?
    private var passportPreviewTask: Task<Void, Never>?
    private var isTransitionActive = false
    private var retakeIndex: Int?
    private var isOperatorCameraRestartRunning = false
    private var sessionCreatedAt: Date?
    private(set) var sessionGalleryReceiptStyle: GalleryReceiptStyle = .shareFriendly
    private(set) var sessionPrintOptions: ReceiptPrintOptions = .default
    private var sessionEventProfile: EventProfile?
    private var committedGallerySession: CommittedGallerySession?
    private var customerSessionGeneration = 0
    private var customerPrintPhotoProfile = CustomerReceiptPhotoToneStore.load().profile
    /// Sticker Studio settings frozen when this customer session started.
    private(set) var sessionStickerConfiguration = StickerStudioSessionConfiguration.disabled
    /// Where Sticker Studio's Back returns to (Review, or the Photo Pass preview).
    private var stickerStudioReturnState: BoothSessionState?
    private var stickerPreparationTask: Task<Void, Never>?
    /// Counts committed finalizations; a guard against double commits in tests and diagnostics.
    private(set) var receiptFinalizationCount = 0
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
            return !isTransitionActive && !isCameraUnavailable && checkoutEntitlement?.permitsCapture == true
        }

        return false
    }

    var canContinueToReceipt: Bool {
        guard canContinueFromReview else { return false }
        // Passport commits only from its preview (or Sticker Studio reached from it).
        return selectedBoothFormat != .passport || state == .passportPreview
            || (state == .stickerStudio && stickerStudioReturnState == .passportPreview)
    }

    /// Whether this guest gets the Sticker Studio step before the receipt is committed.
    var stickerStepEnabledForSession: Bool {
        sessionStickerConfiguration.isGuestStepEnabled
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
        if let checkoutEntitlement, commercialEvent.activePolicy.commercialMode == .payPerPrint {
            return [checkoutEntitlement.purchasedCopies]
        }
        return Array(1...commercialEvent.activePolicy.maxCopies)
    }

    var printButtonTitle: String {
        selectedPrintCopies == 1 ? "Print Receipt" : "Print \(selectedPrintCopies) Copies"
    }

    var canDecreasePrintCopies: Bool {
        checkoutEntitlement?.authorizationSource == .privatePrepaid && commercialEvent.activePolicy.prepaidGuestCopyChoice && !isPrintBatchActive && selectedPrintCopies > 1
    }

    var canIncreasePrintCopies: Bool {
        checkoutEntitlement?.authorizationSource == .privatePrepaid && commercialEvent.activePolicy.prepaidGuestCopyChoice && !isPrintBatchActive && selectedPrintCopies < commercialEvent.activePolicy.maxCopies
    }

    var printProgressText: String {
        if case .connecting = printerState {
            return "Connecting to the printer… This can take up to 30 seconds."
        }

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
        guard !isTransitionActive else { return false }
        if checkoutEntitlement == nil && (checkoutGuard.serverCheckoutStarted || checkoutGuard.qrAttemptUnresolved || paymentOrder != nil || paymentAttempt != nil) { return false }
        if let entitlement = checkoutEntitlement, entitlement.authorizationSource != .privatePrepaid, capturedPhotos.isEmpty { return false }
        return CustomerIdleResetPolicy.isEligible(
            state: state,
            printerWorking: printerState.isWorking,
            printBatchActive: isPrintBatchActive,
            recoveryLocked: printerCoordinator.requiresRecovery,
            unresolvedPrint: operationalState.hasUnresolvedPrint
        )
    }

    /// Holds the captured-photo confirmation on screen. Injected so tests can step through the
    /// confirmation deterministically instead of sleeping; production waits the configured duration.
    private let captureConfirmationPause: @MainActor () async -> Void
    /// The in-flight sample-photo confirmation, kept so callers can await its real completion.
    private var captureConfirmationTask: Task<Void, Never>?

    /// - Parameter captureConfirmationPause: nil waits `capturedPhotoDisplayDuration` (production).
    init(
        environment: BoothSessionEnvironment? = nil,
        paymentsClient: PaymentsAPIClient? = nil,
        eventRunStore: EventRunStore? = .shared,
        checkpointStore: CheckoutCheckpointStore? = .shared,
        captureConfirmationPause: (@MainActor () async -> Void)? = nil
    ) {
        let environment = environment ?? .customer
        self.environment = environment
        self.injectedPaymentsClient = paymentsClient
        self.eventRunStore = eventRunStore
        self.checkpointStore = checkpointStore
        self.recoveryStore = try? AppRecoveryStore(directoryURL: environment.recoveryDirectory)
        self.captureConfirmationPause = captureConfirmationPause ?? {
            try? await Task.sleep(for: .seconds(BoothConfiguration.capturedPhotoDisplayDuration))
        }
        cameraService.onSessionMessage = { [weak self] message in
            self?.statusMessage = message
        }
        cameraService.onEvent = { [weak self] event in
            Task { @MainActor in
                self?.handleCameraEvent(event)
            }
        }
    }

    /// Register only the StateObject actually mounted by SwiftUI; temporary View initializers
    /// must not replace the running guest with a model SwiftUI immediately discards.
    func registerForOperatorControl() {
        if environment.recordsCustomerSessionMetrics && environment.recoveryDirectory == nil {
            ActiveGuestInteraction.model = self
        }
    }

    func preparePrinter() {
        printerCoordinator.prepare()
    }

    func startSession() {
        logGuestAction("start_tap", result: "recognized")
        guard state == .welcome, !isTransitionActive else {
            logGuestAction("start_tap", result: "rejected_state_or_transition")
            return
        }
        logGuestAction("start_tap", result: "accepted")

        operationalState.refresh()
        refreshCustomerExperience()
        commercialEvent = CommercialEventRunStore.load()
        guard !printerCoordinator.requiresRecovery, !operationalState.hasUnresolvedPrint else {
            logGuestAction("start_tap", result: "rejected_print_recovery")
            state = .recoveryRequired("Printer needs operator attention.")
            return
        }

        // An operator-armed, single-use recovery continues the original paid checkout.
        if let resume = PaymentRecoveryCoordinator.shared.takeArmedResume() {
            beginRecoveredCheckout(resume)
            return
        }

        guard !SessionAcceptanceStore.shared.state.blocked, EventRunStore.shared.pendingTransition == nil else {
            logGuestAction("start_tap", result: "rejected_admission_paused")
            state = .error("New sessions are paused. Please see the attendant.")
            return
        }

        if let reason = SessionSetupSafety.decision(for: .startUnrelatedGuest).reason {
            state = .error(reason)
            return
        }
        if environment.regularBoothModeSource() {
            do {
                let settings = try RegularBoothSettings.loadForSession()
                beginChoosingFormat(run: settings.configuration, authority: .localPrepaid,
                                    serverPolicy: nil, offlinePolicy: nil, regularBooth: true)
            } catch { state = .error("Regular Booth settings need review. Please see the attendant.") }
            return
        }
        guard CommercialPolicySource.load() == .serverManaged else {
            // Private / Prepaid booths never need the Payments Worker and never charge guests.
            let local = CommercialEventRunStore.load()
            guard SessionAdmission.localConfigurationIsReady(source: .localPrepaid, local: local) else {
                logGuestAction("start_tap", result: "rejected_event_configuration")
                state = .error("This event is paused or needs operator setup.")
                return
            }
            beginChoosingFormat(run: local, authority: .localPrepaid, serverPolicy: nil, offlinePolicy: nil)
            return
        }

        isTransitionActive = true
        statusMessage = "Checking today's event…"
        let generation = customerSessionGeneration
        activeTask = Task { [weak self] in
            guard let self else { return }
            let resolution = await resolveServerPolicy()
            guard isCurrentCustomerSession(generation), !Task.isCancelled else { return }
            isTransitionActive = false
            guard state == .welcome, !Task.isCancelled else { return }
            switch resolution {
            case .success(let resolved):
                beginChoosingFormat(run: resolved.run, authority: resolved.authority, serverPolicy: resolved.serverPolicy, offlinePolicy: resolved.offlinePolicy)
            case .failure(let failure):
                logGuestAction("start_tap", result: "rejected_server_policy")
                state = .error(failure.message)
            }
        }
    }

    private func beginChoosingFormat(run: CommercialEventRun, authority: PolicyAuthority, serverPolicy: ServerEventPolicy?, offlinePolicy: OfflinePolicyPayload?, regularBooth: Bool = false) {
        cancelTasks()
        clearCustomerData()
        if !regularBooth, environment.recordsCustomerSessionMetrics, let eventRunStore {
            do {
                let managed = authority != .localPrepaid
                let context = EventRunContext.admission(library: EventDesignLibraryStore.shared.library, commercialEventID: managed ? run.id : nil,
                    serverBinding: managed ? OperatorWorkspace.shared.serverBinding : nil, fallbackName: run.name)
                sessionRunID = try eventRunStore.runForAdmission(context: context).id
            } catch { isTransitionActive = false; state = .error(error.localizedDescription); return }
        }
        commercialEvent = run
        policyAuthority = authority
        serverEventPolicy = serverPolicy
        offlinePolicyPayload = offlinePolicy
        customerPrintPhotoProfile = CustomerReceiptPhotoToneStore.load().profile
        beginNewCustomerSession()
        customerEventProfile = environment.eventProfileSource().normalized()
        sessionPrintOptions = environment.receiptPrintOptionsSource().resolved(for: customerEventProfile)
        sessionGalleryReceiptStyle = .resolve(device: environment.galleryReceiptStyleSource(), profile: customerEventProfile)
        freezeSessionStickerConfiguration()
        errorMessage = nil
        statusMessage = "Choose your format."
        state = .choosingFormat
    }

    private struct ResolvedPolicy {
        let run: CommercialEventRun
        let authority: PolicyAuthority
        let serverPolicy: ServerEventPolicy?
        let offlinePolicy: OfflinePolicyPayload?
    }

    private struct PolicyResolutionFailure: Error {
        let message: String
    }

    /// Server-managed booths take price, methods and lifecycle only from the server. Without a
    /// server answer, only a verified signed offline policy may authorize (cash only).
    private func resolveServerPolicy() async -> Result<ResolvedPolicy, PolicyResolutionFailure> {
        guard let configuration = PaymentsConfiguration.current() else {
            return .failure(PolicyResolutionFailure(message: "Payments are not set up on this iPad. Please see the attendant."))
        }
        let client = PaymentsAPIClient(configuration: configuration)
        if operationalState.networkPathStatus == "Online" {
            do {
                let response = try await client.activeEvent()
                try? OfflineGrantStore.recordServerContact(device: response.device, environment: configuration.environment, serverTime: response.serverTime, grant: response.offlinePolicy)
                syncOfflineCashInBackground(client: client)
                syncPrintOutboxInBackground()
                guard let event = response.event, event.lifecycle == .active else {
                    let paused = response.inactiveEvent.map { "\($0.name) is \($0.lifecycle.lowercased())." } ?? "No event is active."
                    return .failure(PolicyResolutionFailure(message: "\(paused) Please see the attendant."))
                }
                guard SessionAcceptanceStore.shared.permits(eventID: event.id, binding: OperatorWorkspace.shared.serverBinding) else {
                    return .failure(PolicyResolutionFailure(message: "This event needs operator review. Please see the attendant."))
                }
                let run = event.eventRun
                guard run.activePolicy.validationMessage == nil else {
                    return .failure(PolicyResolutionFailure(message: "This event needs operator setup."))
                }
                return .success(ResolvedPolicy(run: run, authority: .serverConfirmed(fetchedAt: Date()), serverPolicy: event, offlinePolicy: nil))
            } catch let error as PaymentsAPIError where error == .unavailable || error == .outcomeUnknown {
                // Unreachable server: fall through to a signed offline policy, if any.
            } catch {
                return .failure(PolicyResolutionFailure(message: error.localizedDescription))
            }
        }
        do {
            let payload = try verifiedOfflinePolicy(environment: configuration.environment)
            return .success(ResolvedPolicy(run: payload.eventRun, authority: .signedOffline(snapshotID: payload.snapshotId, expiresAt: payload.expiresAt), serverPolicy: nil, offlinePolicy: payload))
        } catch {
            return .failure(PolicyResolutionFailure(message: "This iPad is offline and cannot start a paid session. \(error.localizedDescription)"))
        }
    }

    private func verifiedOfflinePolicy(environment: String, now: Date = Date()) throws -> OfflinePolicyPayload {
        guard let record = OfflineGrantStore.load(), let grant = record.grant, record.environment == environment else {
            throw OfflinePolicyError.malformed
        }
        let policy = try OfflinePolicyVerifier.bundled(environment: environment)
            .verify(grant, deviceID: record.deviceID, accountID: record.accountID, now: now, trustedClockFloor: record.trustedClockFloor)
        guard SessionAcceptanceStore.shared.permits(eventID: policy.eventId, binding: OperatorWorkspace.shared.serverBinding) else { throw OfflinePolicyError.malformed }
        return policy
    }

    private func syncOfflineCashInBackground(client: PaymentsAPIClient) {
        guard let offlineCashLedger else { return }
        Task {
            do {
                let result = try await offlineCashLedger.syncPending(using: client)
                if result.synced + result.conflicts > 0 {
                    debugLog("[OfflineCash] synced=\(result.synced) conflicts=\(result.conflicts)")
                }
            } catch {
                debugLog("[OfflineCash] sync deferred: \(error.localizedDescription)")
            }
        }
    }

    func selectBoothFormat(_ format: BoothFormat) {
        guard case .choosingFormat = state, !isTransitionActive else {
            return
        }

        selectedBoothFormat = format
        guard commercialEvent.activePolicy.supports(format) else {
            state = .error("That format is not available for this event.")
            return
        }
        let sessionDate = sessionCreatedAt ?? Date()
        guard prepareSessionContext(format: format, sessionIdentifier: sessionIdentifier ?? environment.makeSessionIdentifier(sessionDate), createdAt: sessionDate) else { return }
        if commercialEvent.activePolicy.commercialMode == .payPerPrint {
            selectedCheckoutCopies = min(commercialEvent.activePolicy.defaultCopies, commercialEvent.activePolicy.maxCopies)
            selectedPrintCopies = selectedCheckoutCopies
            statusMessage = "Choose how many identical copies to print."
            state = .choosingCopies
            return
        }
        selectedPrintCopies = commercialEvent.activePolicy.defaultCopies
        checkoutEntitlement = CheckoutEntitlement(id: "prepaid-\(sessionIdentifier ?? UUID().uuidString)", orderID: nil, eventID: commercialEvent.id, policyRevisionID: commercialEvent.activePolicy.revisionID, sessionID: sessionIdentifier, selectedFormatRawValue: format.rawValue, purchasedCopies: selectedPrintCopies, unitPriceCentavos: 0, totalCentavos: 0, authorizationSource: .privatePrepaid, authorizedAt: Date(), receiptFingerprint: nil)
        prepareCameraAfterAuthorization()
    }

    /// Session-scoped context shared by new sessions and recovered paid checkouts. Never loads a
    /// previous guest's photos; galleries always get a fresh token.
    @discardableResult
    private func prepareSessionContext(format: BoothFormat, sessionIdentifier identifier: String, createdAt sessionDate: Date) -> Bool {
        if environment.recordsCustomerSessionMetrics, let sessionRunID, let eventRunStore {
            do { try eventRunStore.beginSession(id: identifier, runID: sessionRunID, format: format.rawValue, now: sessionDate) }
            catch { state = .error(error.localizedDescription); return false }
        }
        selectedBoothFormat = format
        sessionCreatedAt = sessionDate
        sessionIdentifier = identifier
        let savedEventProfile = customerEventProfile
        customerEventProfile = savedEventProfile
        sessionEventProfile = savedEventProfile.activeReceiptSnapshot
        passportDraft = format == .passport
            ? PassportSessionData(configuration: PassportConfiguration.effective(for: sessionEventProfile))
            : .empty
        resetPassportPreview()
        do {
            let token = try galleryToken ?? GalleryTokenGenerator.makeGalleryToken()
            let url = try galleryURL ?? GalleryURLBuilder.makeGalleryURL(customerGalleryBaseURL: CustomerGalleryConfiguration.load().baseURL, galleryToken: token)
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
        return true
    }

    /// Navigation is permitted only before any checkout request or paid authorization exists.
    var canLeaveCopySelection: Bool {
        state == .choosingCopies && !isTransitionActive && paymentOrder == nil
            && paymentAttempt == nil && checkoutEntitlement == nil
            && !checkoutGuard.serverCheckoutStarted && !checkoutGuard.qrAttemptUnresolved
    }

    func adjustCheckoutCopies(by delta: Int) {
        guard canLeaveCopySelection else { return }
        selectedCheckoutCopies = min(commercialEvent.activePolicy.maxCopies, max(1, selectedCheckoutCopies + delta))
    }

    func backToFormatSelection() {
        guard canLeaveCopySelection else { return }
        paymentNotice = nil
        state = .choosingFormat
    }

    func confirmCopySelection() {
        guard canLeaveCopySelection, selectedBoothFormat != nil, commercialEvent.activePolicy.totalCentavos(for: selectedCheckoutCopies) != nil else { return }
        selectedPrintCopies = selectedCheckoutCopies
        paymentNotice = nil
        state = .choosingPayment
        // A single offered method skips the choice screen. This runs only from the guest's own
        // tap; QR creation stays idempotent and guarded by the payment state.
        switch soleOfferedPaymentMethod {
        case .qrPh? where canChooseQRPh: chooseQRPh()
        case .cash? where canChooseCash: chooseCash()
        default: break
        }
    }

    /// The only method this event offers, or nil when the guest chooses between QR Ph and cash.
    var soleOfferedPaymentMethod: GuestPaymentMethod? {
        let policy = commercialEvent.activePolicy
        guard policy.commercialMode == .payPerPrint else { return nil }
        if policy.qrPhEnabled && !policy.cashEnabled && !policyAuthority.isOfflineCashOnly { return .qrPh }
        if policy.cashEnabled && (!policy.qrPhEnabled || policyAuthority.isOfflineCashOnly) { return .cash }
        return nil
    }

    var canChooseCash: Bool {
        checkoutGuard.canChooseCash(authority: policyAuthority, cashEnabled: commercialEvent.activePolicy.cashEnabled)
    }

    var canChooseQRPh: Bool {
        checkoutGuard.canChooseQR(authority: policyAuthority, qrEnabled: commercialEvent.activePolicy.qrPhEnabled, online: operationalState.networkPathStatus == "Online")
    }

    var canStartNewCheckout: Bool {
        state == .paymentReconciliation && checkoutGuard.canStartNewCheckout() && paymentOrder != nil
    }

    /// Neither screen may abandon a checkout request that may have reached the server.
    var canLeavePaymentSelection: Bool {
        (state == .choosingPayment || state == .cashAttestation) && !isTransitionActive
            && paymentOrder == nil && paymentAttempt == nil && checkoutEntitlement == nil
            && !checkoutGuard.serverCheckoutStarted && !checkoutGuard.qrAttemptUnresolved
    }

    func backFromPaymentSelection() {
        guard canLeavePaymentSelection else { return }
        paymentNotice = nil
        state = state == .cashAttestation && soleOfferedPaymentMethod == nil ? .choosingPayment : .choosingCopies
    }

    var canLeaveCashPayment: Bool {
        state == .cashAttestation && canLeavePaymentSelection
            && commercialEvent.activePolicy.qrPhEnabled && soleOfferedPaymentMethod == nil
    }

    func chooseCash() {
        guard state == .choosingPayment, !isTransitionActive, canChooseCash else { return }
        paymentNotice = nil
        state = .cashAttestation
    }

    func leaveCashPayment() {
        guard canLeaveCashPayment else { return }
        backFromPaymentSelection()
    }

    /// Online customer declaration stays SELF_REPORTED; it never records staff confirmation.
    func declareCashPaidByGuest() {
        completeCashPayment(requireAttendant: false)
    }

    func confirmCashReceivedByAttendant() {
        completeCashPayment(requireAttendant: true)
    }

    private func completeCashPayment(requireAttendant: Bool) {
        guard state == .cashAttestation, !isTransitionActive, let format = selectedBoothFormat, let sessionIdentifier, canChooseCash,
              let total = commercialEvent.activePolicy.totalCentavos(for: selectedCheckoutCopies) else { return }
        isTransitionActive = true
        paymentNotice = nil
        let generation = customerSessionGeneration
        let copies = selectedCheckoutCopies
        activeTask = Task { [weak self] in
            guard let self else { return }
            let permit = OperatorAccessPermit.shared
            let wasAuthorized = permit.isAuthorized
            // Signed offline cash retains its existing attendant authentication requirement.
            let needsAuthentication = requireAttendant || policyAuthority.isOfflineCashOnly
            if needsAuthentication {
                let confirmed = await environment.authorizeAttendantCashConfirmation(PHPPriceFormatter.string(centavos: total))
                guard isCurrentCustomerSession(generation), state == .cashAttestation else { return }
                guard confirmed else {
                    isTransitionActive = false
                    paymentNotice = "Cash was not confirmed. Please ask the attendant for help."
                    return
                }
                permit.authorize()
            }
            defer { if needsAuthentication && !wasAuthorized { permit.revoke() } }
            do {
                switch policyAuthority {
                case .serverConfirmed:
                    guard let event = serverEventPolicy, let client = paymentsClient else { throw PaymentsAPIError.configuration("Payments are not set up on this iPad.") }
                    checkoutGuard.serverCheckoutStarted = true
                    // A retry after an unconfirmed attempt reuses this session's open order.
                    let order: PaymentOrder
                    if let existing = paymentOrder, existing.supersededByOrderID == nil, existing.paymentMethod == nil || existing.paymentMethod == "CASH_DECLARED" {
                        order = existing
                    } else {
                        order = try await createCheckoutOrder(client: client, event: event, format: format, copies: copies, sessionID: sessionIdentifier, method: "CASH_DECLARED")
                    }
                    checkpointStore?.update(id: sessionIdentifier) { $0.phase = .paymentRequested }
                    let response = try await retryingUnknownOutcome {
                        if requireAttendant {
                            return try await client.confirmCash(orderID: order.id, expectedTotalCentavos: total)
                        }
                        return try await client.declareCash(orderID: order.id)
                    }
                    let correctProvenance = requireAttendant
                        ? response.attempt?.isOperatorConfirmedCash == true
                        : response.attempt?.method == "CASH_DECLARED" && response.attempt?.state == "SELF_REPORTED"
                    guard correctProvenance, let entitlement = response.entitlement else { throw PaymentsAPIError.invalidResponse }
                    checkpointStore?.update(id: sessionIdentifier) { $0.phase = .entitled; $0.entitlementID = entitlement.id }
                    guard isCurrentCustomerSession(generation), !Task.isCancelled else { return }
                    paymentAttempt = response.attempt
                    try await claimAndPrepareCamera(entitlement, client: client, sessionID: sessionIdentifier, generation: generation)
                case .signedOffline:
                    // Offline cash is never a fallback for a session that already reached the server.
                    guard !checkoutGuard.serverCheckoutStarted, let offlineCashLedger, let configuration = PaymentsConfiguration.current() else {
                        throw OfflineCashLedger.LedgerError.invalidPolicy
                    }
                    let policy = try verifiedOfflinePolicy(environment: configuration.environment)
                    guard policy.snapshotId == offlinePolicyPayload?.snapshotId, policy.unitPriceCentavos == commercialEvent.activePolicy.unitPriceCentavos else {
                        throw OfflineCashLedger.LedgerError.invalidPolicy
                    }
                    try beginCheckpoint(sessionID: sessionIdentifier, eventID: policy.eventId, policyRevisionID: policy.policyRevisionId,
                                        unitPriceCentavos: policy.unitPriceCentavos, copies: copies, format: format, method: "OFFLINE_CASH", environment: configuration.environment)
                    let (record, entitlement) = try await offlineCashLedger.declare(policy: policy, sessionID: sessionIdentifier, format: format, copies: copies)
                    checkpointStore?.update(id: sessionIdentifier) { $0.phase = .entitled; $0.offlineRecordID = record.id }
                    guard isCurrentCustomerSession(generation) else { return }
                    checkoutEntitlement = entitlement
                    selectedPrintCopies = entitlement.purchasedCopies
                    isTransitionActive = false
                    prepareCameraAfterAuthorization()
                case .localPrepaid:
                    isTransitionActive = false
                }
            } catch {
                guard isCurrentCustomerSession(generation) else { return }
                isTransitionActive = false
                if requireAttendant, let apiError = error as? PaymentsAPIError, Self.isCashConfirmationUnavailable(apiError) {
                    // The payments service predates attendant confirmation, or the operator
                    // credential was refused. Never fall back to a guest self-declaration.
                    paymentNotice = "Cash could not be confirmed on the payments server. Please ask the attendant for help\(commercialEvent.activePolicy.qrPhEnabled ? " or pay with QR Ph" : "")."
                    return
                }
                handleCheckoutError(error)
            }
        }
    }

    /// The server cannot take attendant confirmations (older service, missing operator pairing or
    /// refused operator credential). Nothing was authorized; the guest stays on the cash screen.
    nonisolated static func isCashConfirmationUnavailable(_ error: PaymentsAPIError) -> Bool {
        if case .configuration = error { return true }
        return error == .unauthorized || ["not_found", "forbidden"].contains(error.code ?? "")
    }

    func chooseQRPh() {
        guard state == .choosingPayment, !isTransitionActive, canChooseQRPh, let format = selectedBoothFormat, let sessionIdentifier,
              let event = serverEventPolicy, let client = paymentsClient else { return }
        isTransitionActive = true
        let generation = customerSessionGeneration
        let copies = selectedCheckoutCopies
        activeTask = Task { [weak self] in
            guard let self else { return }
            do {
                if SessionAcceptanceStore.shared.state.unattendedQR == true {
                    statusMessage = "Checking booth readiness before payment…"
                    let acceptance = SessionAcceptanceStore.shared
                    guard acceptance.permits(eventID: event.id, binding: OperatorWorkspace.shared.serverBinding),
                          event.qrphEnabled, !event.cashEnabled, event.lifecycle == .active else { throw SetupFailure("The unattended event needs operator review.") }
                    let fresh = try await client.activeEvent()
                    guard fresh.event?.id == event.id, fresh.event?.policyRevisionId == event.policyRevisionId,
                          fresh.event?.qrphEnabled == true, fresh.event?.cashEnabled == false else { throw SetupFailure("Event payment settings changed. Please contact the booth owner.") }
                    guard let checkpointStore, checkpointStore.integrityFault == nil else { throw SetupFailure("Checkout storage needs operator attention.") }
                    try checkpointStore.verifyWritable()
                    try await CheckoutReadiness().check()
                    guard isCurrentCustomerSession(generation), !Task.isCancelled else { return }
                    guard acceptance.permits(eventID: event.id, binding: OperatorWorkspace.shared.serverBinding) else { throw SetupFailure("The booth paused during readiness. No payment QR was issued.") }
                }
                checkoutGuard.serverCheckoutStarted = true
                let order = try await createCheckoutOrder(client: client, event: event, format: format, copies: copies, sessionID: sessionIdentifier, method: "QRPH")
                guard isCurrentCustomerSession(generation), !Task.isCancelled else { return }
                checkoutGuard.qrAttemptUnresolved = true
                checkpointStore?.update(id: sessionIdentifier) { $0.phase = .paymentRequested }
                let attempt = try await retryingUnknownOutcome { try await client.createQR(orderID: order.id) }
                checkpointStore?.update(id: sessionIdentifier) { $0.phase = .awaitingProvider; $0.lastServerState = attempt.state }
                guard isCurrentCustomerSession(generation) else { return }
                paymentAttempt = attempt
                isTransitionActive = false
                state = .awaitingQRPayment
                pollQRStatus(orderID: order.id, generation: generation)
            } catch {
                guard isCurrentCustomerSession(generation) else { return }
                isTransitionActive = false
                handleCheckoutError(error)
            }
        }
    }

    /// A deliberate new checkout after the server confirmed the previous QR cannot be paid.
    func startNewCheckout() {
        guard canStartNewCheckout, let order = paymentOrder else { return }
        stopPaymentPolling()
        activeTask?.cancel()
        activeTask = nil
        prepareSupersedingCheckout(of: order.id, notice: "The previous QR code was not paid. Please choose how to pay.")
    }

    private func prepareSupersedingCheckout(of orderID: String, notice: String) {
        supersedeOrderID = orderID
        checkoutAttempt += 1
        paymentOrder = nil
        paymentAttempt = nil
        checkoutGuard = CheckoutGuard(serverCheckoutStarted: true, qrAttemptUnresolved: false, newCheckoutAllowed: false)
        paymentNotice = notice
        state = .choosingPayment
    }

    private func createCheckoutOrder(client: PaymentsAPIClient, event: ServerEventPolicy, format: BoothFormat, copies: Int, sessionID: String, method: String) async throws -> PaymentOrder {
        // Durable before the first server mutation: if it cannot be written, nothing is sent.
        try beginCheckpoint(sessionID: sessionID, eventID: event.id, policyRevisionID: event.policyRevisionId, unitPriceCentavos: event.unitPriceCentavos,
                            copies: copies, format: format, method: method, environment: client.environment)
        let key = "order-\(sessionID)-\(checkoutAttempt)"
        let supersedes = supersedeOrderID
        let generation = customerSessionGeneration
        let order = try await retryingUnknownOutcome {
            try await client.createOrder(event: event, format: format, copies: copies, checkoutSessionID: sessionID, supersedesOrderID: supersedes, idempotencyKey: key)
        }
        checkpointStore?.update(id: sessionID) { $0.orderID = order.id; $0.lastServerState = order.state }
        guard isCurrentCustomerSession(generation), !Task.isCancelled else { throw CancellationError() }
        if environment.recordsCustomerSessionMetrics {
            eventRunStore?.updateSession(id: sessionID) { if !$0.orderIDs.contains(order.id) { $0.orderIDs.append(order.id) } }
        }
        paymentOrder = order
        supersedeOrderID = nil
        return order
    }

    private func beginCheckpoint(sessionID: String, eventID: String, policyRevisionID: String, unitPriceCentavos: Int, copies: Int, format: BoothFormat, method: String, environment: String) throws {
        guard let checkpointStore else { throw CheckoutCheckpointStore.StoreError.persistFailed("checkout storage unavailable") }
        if let reason = SessionSetupSafety.decision(for: .initiatePaidCheckout, activeGuest: true,
            printerWorking: printerCoordinator.isWorking, needsReceiptCheck: operationalState.hasUnresolvedPrint || printerCoordinator.requiresRecovery,
            hasPendingSession: false, checkpoints: checkpointStore, outbox: printOutbox, currentCheckoutID: sessionID).reason { throw SetupFailure(reason) }
        let identity = OfflineGrantStore.load()
        let now = Date()
        try checkpointStore.begin(CheckoutCheckpoint(
            id: sessionID, environment: environment, deviceID: identity?.deviceID, accountID: identity?.accountID,
            eventID: eventID, policyRevisionID: policyRevisionID, unitPriceCentavos: unitPriceCentavos, copies: copies,
            format: format.rawValue, method: method, orderID: nil, entitlementID: nil, offlineRecordID: nil,
            phase: .orderRequested, lastServerState: nil, createdAt: now, updatedAt: now, resolution: nil, resolvedAt: nil, receiptPrintOptions: sessionPrintOptions, galleryReceiptStyle: sessionGalleryReceiptStyle, serverBinding: paymentsClient?.serverBinding))
    }

    /// Retries a write whose outcome is unknown with the same idempotent request.
    private func retryingUnknownOutcome<Value>(_ operation: () async throws -> Value) async throws -> Value {
        var attempt = 0
        while true {
            do {
                return try await operation()
            } catch let error as PaymentsAPIError where error == .outcomeUnknown && attempt < 2 {
                attempt += 1
                try await Task.sleep(for: .seconds(Double(attempt) * 1.5))
            }
        }
    }

    private func claimAndPrepareCamera(_ entitlement: CheckoutEntitlement, client: PaymentsAPIClient, sessionID: String, generation: Int) async throws {
        guard isCurrentCustomerSession(generation), !Task.isCancelled else { return }
        var claimed = entitlement
        if entitlement.requiresServerClaim {
            claimed = try await retryingUnknownOutcome {
                try await client.claim(entitlementID: entitlement.id, sessionID: sessionID, idempotencyKey: "claim-\(entitlement.id)")
            }
        }
        checkpointStore?.update(id: sessionID) { $0.phase = .claimed; $0.entitlementID = claimed.id; $0.lastServerState = claimed.serverState }
        guard isCurrentCustomerSession(generation), !Task.isCancelled else { return }
        guard claimed.permitsCapture, claimed.sessionID == sessionID else {
            state = .paymentReconciliation
            statusMessage = "This payment needs attendant review before the session can start."
            return
        }
        checkoutEntitlement = claimed
        selectedPrintCopies = claimed.purchasedCopies
        checkoutGuard.qrAttemptUnresolved = false
        isTransitionActive = false
        prepareCameraAfterAuthorization()
    }

    private func handleCheckoutError(_ error: Error) {
        guard let apiError = error as? PaymentsAPIError else {
            state = .error(error.localizedDescription)
            return
        }
        switch apiError.code {
        case "policy_changed":
            struct Details: Decodable { let currentPolicy: ServerEventPolicy }
            guard let policy = apiError.decodeDetails(Details.self)?.currentPolicy, policy.lifecycle == .active else {
                state = .error("This event changed. Please see the attendant.")
                return
            }
            // createOrder rejects a stale policy before inserting any order. Only that
            // conclusive rejection may reopen navigation; an existing order stays recoverable.
            guard paymentOrder == nil, paymentAttempt == nil, checkoutEntitlement == nil,
                  !checkoutGuard.qrAttemptUnresolved else {
                statusMessage = "Please ask the attendant to check this payment. Do not pay again."
                state = .paymentReconciliation
                return
            }
            checkoutGuard = CheckoutGuard()
            if let sessionIdentifier { checkpointStore?.resolve(id: sessionIdentifier, reason: "policy_changed_before_order") }
            serverEventPolicy = policy
            commercialEvent = policy.eventRun
            selectedCheckoutCopies = min(max(1, selectedCheckoutCopies), policy.maxCopies)
            selectedPrintCopies = selectedCheckoutCopies
            paymentNotice = "The price was updated to \(PHPPriceFormatter.string(centavos: policy.unitPriceCentavos)) per copy. Please review before paying."
            state = .choosingCopies
        case "qr_create_failed":
            guard let order = paymentOrder else { state = .error(apiError.localizedDescription); return }
            prepareSupersedingCheckout(of: order.id, notice: "QR Ph could not be started. No payment was taken. Please choose how to pay.")
        case "checkout_already_open", "previous_payment_unresolved":
            struct Details: Decodable { let openOrder: PaymentOrder? }
            if let open = apiError.decodeDetails(Details.self)?.openOrder { paymentOrder = open }
            enterReconciliation("A payment for this session is still being checked. Please do not pay again.")
        case "payment_method_locked", "qr_status_unknown", "qr_creation_in_progress":
            checkoutGuard.qrAttemptUnresolved = paymentOrder != nil
            enterReconciliation("Checking your QR Ph payment. Please do not pay again or pay another way.")
        case "event_not_active", "cash_disabled", "qrph_disabled":
            state = .error("\(apiError.localizedDescription) Please see the attendant.")
        default:
            if apiError == .outcomeUnknown {
                enterReconciliation("We could not confirm your payment request. Please see the attendant and do not pay again.")
            } else {
                state = .error(apiError.localizedDescription)
            }
        }
    }

    @Published private(set) var detachedRecoveryReference: String?

    var canDetachUnresolvedCheckout: Bool {
        state == .paymentReconciliation && !isTransitionActive && checkoutEntitlement == nil
            && capturedPhotos.isEmpty && !isPrintBatchActive && !printerCoordinator.requiresRecovery
            && detachedRecoveryReference == nil && sessionIdentifier != nil
    }

    func detachUnresolvedCheckout() {
        guard canDetachUnresolvedCheckout, let id = sessionIdentifier, let checkpointStore,
              let checkpoint = checkpointStore.checkpoint(id: id), checkpoint.phase < .entitled,
              let snapshot = recoveryStore?.load(), snapshot.sessionIdentifier == id else {
            statusMessage = "The original checkout could not be safely saved. Please call the attendant."; return
        }
        do {
            let store = DetachedCheckoutStore(directory: environment.detachedCheckoutDirectory)
            let existing = try store.load(sessionID: id)
            let reference = existing?.reference ?? UUID().uuidString.lowercased()
            let record = DetachedCheckoutRecord(checkpoint: checkpoint, snapshot: snapshot, reference: reference, detachedAt: existing?.detachedAt ?? Date())
            try store.save(record)
            guard checkpointStore.update(id: id, { $0.detachedAt = record.detachedAt; $0.recoveryReference = reference }) else { throw SetupFailure("The handoff journal could not be saved.") }
            // There is no suspension between durable handoff and invalidating every callback.
            stopPaymentPolling(); invalidateCustomerSessionCallbacks()
            recoveryStore?.clear(sessionIdentifier: id)
            operationalState.refresh()
            detachedRecoveryReference = reference
            statusMessage = "Your payment is still being checked. Save this reference and contact the booth owner before paying again. The reference alone cannot unlock a photo session."
        } catch { statusMessage = "Your checkout is still here: \(error.localizedDescription) Please call the attendant." }
    }

    func finishDetachedCheckout() {
        guard detachedRecoveryReference != nil, let id = sessionIdentifier,
              checkpointStore?.checkpoint(id: id)?.detachedAt != nil else { return }
        resetToWelcome()
    }

    func recheckPayment() {
        guard state == .paymentReconciliation, !isTransitionActive, detachedRecoveryReference == nil else {
            logGuestAction("payment_recheck", result: "rejected_state_or_transition")
            return
        }
        logGuestAction("payment_recheck", result: "original_checkout_only")
        pollQRStatus(orderID: paymentOrder?.id, generation: customerSessionGeneration)
    }

    private func enterReconciliation(_ message: String) {
        state = .paymentReconciliation
        statusMessage = message
        pollQRStatus(orderID: paymentOrder?.id, generation: customerSessionGeneration)
    }

    /// Polls the server until the QR is verified paid (claim and start), conclusively unpaid (a
    /// deliberate new checkout becomes available), or the session is reset. Never falls back to cash.
    private func pollQRStatus(orderID: String?, generation: Int) {
        stopPaymentPolling()
        guard detachedRecoveryReference == nil, let client = paymentsClient else {
            statusMessage = "Payments cannot be reached on this iPad. Please call the attendant. Do not pay again."
            return
        }
        let owner = UUID()
        paymentPollOwner = owner
        let checkoutSessionID = sessionIdentifier
        // Same checkout (foregrounding, Check Again, order discovered by recovery): the escalation
        // clock keeps running. Only a deliberate new checkout or a new guest restarts it.
        verificationClock.begin(key: "\(checkoutSessionID ?? "unknown")#\(checkoutAttempt)", now: Date())
        updateVerificationStage()
        paymentPollTask = Task { [weak self] in
            guard let self else { return }
            var iteration = 0
            var recoveredOrderID = orderID
            defer {
                if paymentPollOwner == owner {
                    paymentPollOwner = nil
                    paymentPollTask = nil
                }
            }
            while !Task.isCancelled, ownsPaymentPolling(owner, generation: generation) {
                iteration += 1
                do {
                    if recoveredOrderID == nil, let checkoutSessionID {
                        let recovery = try await client.checkoutRecovery(checkoutSessionID: checkoutSessionID)
                        guard ownsPaymentPolling(owner, generation: generation), !Task.isCancelled else { return }
                        guard recovery.checkoutSessionId == checkoutSessionID else { throw PaymentsAPIError.invalidResponse }
                        // An empty response cannot establish that an interrupted mutation never arrived.
                        recoveredOrderID = recovery.openOrderId
                        if recoveredOrderID == nil {
                            statusMessage = "The original request still needs attendant review. Do not pay again."
                            return
                        }
                    }
                    guard let recoveredOrderID else { return }
                    let response: PaymentStatusResponse
                    if iteration % 10 == 0 {
                        do { response = try await client.reconcileOriginal(orderID: recoveredOrderID) }
                        catch { response = try await client.status(orderID: recoveredOrderID) }
                    } else { response = try await client.status(orderID: recoveredOrderID) }
                    guard ownsPaymentPolling(owner, generation: generation), !Task.isCancelled else { return }
                    guard response.order.id == recoveredOrderID,
                          response.order.checkoutSessionID == nil || response.order.checkoutSessionID == checkoutSessionID else {
                        throw PaymentsAPIError.invalidResponse
                    }
                    if environment.recordsCustomerSessionMetrics, let checkoutSessionID {
                        eventRunStore?.updateSession(id: checkoutSessionID) { if !$0.orderIDs.contains(response.order.id) { $0.orderIDs.append(response.order.id) } }
                    }
                    paymentOrder = response.order
                    paymentAttempt = response.attempt
                    verificationClock.recordResponse(reviewHeld: response.attempt?.state == "MANUAL_REVIEW" || response.entitlement?.serverState == "REVIEW_REQUIRED"
                                                     || ["MANUAL_REVIEW", "LATE_PAID_REVIEW"].contains(response.order.state))
                    checkoutGuard.newCheckoutAllowed = response.attempt?.isConclusivelyUnpaid == true && response.newCheckout?.allowed == true
                    checkoutGuard.qrAttemptUnresolved = response.attempt?.isConclusivelyUnpaid != true
                    if let checkoutSessionID {
                        checkpointStore?.update(id: checkoutSessionID) {
                            $0.orderID = response.order.id
                            $0.lastServerState = response.entitlement?.serverState ?? response.attempt?.state ?? response.order.state
                        }
                    }
                    if let entitlement = response.entitlement {
                        if let sessionIdentifier {
                            checkpointStore?.update(id: sessionIdentifier) { $0.phase = .entitled; $0.entitlementID = entitlement.id; $0.lastServerState = entitlement.serverState }
                        }
                        guard entitlement.serverState != "REVIEW_REQUIRED" else {
                            state = .paymentReconciliation
                            statusMessage = "Your payment was received but needs attendant review. Please do not pay again."
                            return
                        }
                        if let sessionIdentifier {
                            try await claimAndPrepareCamera(entitlement, client: client, sessionID: sessionIdentifier, generation: generation)
                        }
                        return
                    }
                    if let attempt = response.attempt, attempt.isConclusivelyUnpaid {
                        checkoutGuard.qrAttemptUnresolved = false
                        checkoutGuard.newCheckoutAllowed = response.newCheckout?.allowed ?? false
                        state = .paymentReconciliation
                        statusMessage = checkoutGuard.newCheckoutAllowed
                            ? "The QR code was not paid. You can start a new checkout."
                            : "The QR code is expiring. Please wait a moment and do not pay the old code."
                    } else if response.attempt?.state == "AWAITING_PAYMENT", state == .paymentReconciliation, !checkoutGuard.newCheckoutAllowed {
                        state = .awaitingQRPayment
                    } else if response.attempt?.state == "UNKNOWN_RECONCILIATION" || response.attempt?.state == "MANUAL_REVIEW" {
                        state = .paymentReconciliation
                        statusMessage = "Payment status is being confirmed. Please do not pay again."
                    }
                } catch {
                    guard ownsPaymentPolling(owner, generation: generation), !Task.isCancelled else { return }
                    verificationClock.recordFailure()
                    checkoutGuard.newCheckoutAllowed = false
                    checkoutGuard.qrAttemptUnresolved = true
                    state = .paymentReconciliation
                    statusMessage = "Payment status is unknown. Reconnecting — please do not pay again."
                }
                updateVerificationStage()
                try? await Task.sleep(for: .seconds(iteration < 90 ? 2 : 5))
            }
        }
    }

    private func updateVerificationStage() {
        let next = verificationClock.stage(now: Date(), qrExpiresAt: paymentAttempt?.expiresAt)
        if next != paymentVerificationStage { paymentVerificationStage = next }
    }

    /// Paid sessions (server or offline cash) keep one batch so a retry continues the same receipt.
    private var isPaidSession: Bool {
        guard let source = checkoutEntitlement?.authorizationSource else { return false }
        return source != .privatePrepaid
    }

    /// Runs inside the spooler's fail-closed gate, after the recovery snapshot: the copy intent
    /// is durable before any byte is sent, or the copy is not sent at all.
    private func journalCopyIntent(_ envelope: PrintJobEnvelope) throws {
        guard let printOutbox else { throw PrintCheckpointError.persistenceFailed("Print accounting storage is unavailable.") }
        if let reason = SessionSetupSafety.decision(for: .sendCopy, activeGuest: true, printerWorking: false,
            needsReceiptCheck: printerCoordinator.requiresRecovery, hasPendingSession: false,
            checkpoints: checkpointStore, outbox: printOutbox, currentCheckoutID: envelope.sessionIdentifier).reason {
            throw PrintCheckpointError.persistenceFailed(reason)
        }
        do {
            try printOutbox.beginCopy(
                batchID: envelope.batchID.uuidString.lowercased(),
                sessionID: envelope.sessionIdentifier,
                entitlementID: checkoutEntitlement?.orderID == nil ? nil : checkoutEntitlement?.id,
                receiptFingerprint: envelope.payloadFingerprint.lowercased(),
                copyIndex: envelope.copyIndex,
                copyCount: envelope.copyCount,
                // The actual selection is persisted immediately before bytes may be sent. A
                // previous job's active transport is not evidence for this copy.
                transport: PrinterTransportSelection.none.rawValue
            )
        } catch {
            throw PrintCheckpointError.persistenceFailed(error.localizedDescription)
        }
        if environment.recordsCustomerSessionMetrics {
            eventRunStore?.updateSession(id: envelope.sessionIdentifier) {
                $0.printOutcomes[envelope.batchID.uuidString.lowercased() + "/" + String(envelope.copyIndex)] = PrintCopyLocalState.inFlight.rawValue
            }
        }
        if let sessionIdentifier, isPaidSession {
            checkpointStore?.update(id: sessionIdentifier) { $0.phase = .printing; $0.physicalReviewAt = nil }
        }
    }

    /// Records what the transport proved about one copy. Never stronger than the evidence.
    private func recordCopyOutcome(copy: Int, batchID: UUID, result: Result<Void, Error>) {
        let state: PrintCopyLocalState
        switch result {
        case .success:
            state = .delivered
        case .failure(let error) where error is PrintCheckpointError:
            state = .notStarted
        case .failure(let error):
            // Unknown failures are treated as possibly printed.
            state = ((error as? PrintTransportFailure)?.bytesStarted ?? true) ? .uncertain : .notStarted
        }
        if environment.recordsCustomerSessionMetrics, let sessionIdentifier {
            eventRunStore?.updateSession(id: sessionIdentifier) {
                $0.printOutcomes[batchID.uuidString.lowercased() + "/" + String(copy)] = state.rawValue
            }
        }
        let saved = printOutbox?.finishCopy(batchID: batchID.uuidString.lowercased(), copyIndex: copy, state: state) == true
        if saved, state == .notStarted, let id = sessionIdentifier,
           printOutbox?.copiesThatMayHavePrinted(sessionID: id).isEmpty == true {
            // The transport proved no bytes were sent. Refine only this exact session's
            // conservative pre-send snapshot; never weaken a possibly printed copy.
            do { try persistCriticalRecoverySnapshot(stage: receiptImage == nil ? .photosCaptured : .receiptComposed) }
            catch { statusMessage = "Nothing was sent, but recovery still needs saving. Retry Saving Resolution. \(error.localizedDescription)" }
            operationalState.refresh()
        }
        syncPrintOutboxInBackground()
    }

    private func finishPaidCheckout(batchID: UUID) {
        guard let entitlement = checkoutEntitlement, let sessionID = entitlement.sessionID ?? sessionIdentifier, isPaidSession else { return }
        if entitlement.orderID != nil {
            guard printOutbox?.enqueueCompletion(batchID: batchID.uuidString.lowercased(), sessionID: sessionID, entitlementID: entitlement.id) == true else {
                statusMessage = "Receipt delivery is recorded, but completion still needs saving. Open Help & Recovery; do not print again."
                return
            }
        }
        checkpointStore?.update(id: sessionID) { $0.phase = .completed }
        checkpointStore?.resolve(id: sessionID, reason: "completed")
        syncPrintOutboxInBackground()
    }

    private func syncPrintOutboxInBackground() {
        Task { await PaymentRecoveryCoordinator.shared.syncOutbox() }
    }

    /// An authenticated operator can resume the paying guest already waiting on this iPad.
    /// Never replace a different guest or interrupt capture/printing with an armed checkout.
    func resumeArmedCheckoutForCurrentGuest() {
        let recovery = PaymentRecoveryCoordinator.shared
        guard state == .paymentReconciliation, !isTransitionActive,
              checkoutEntitlement == nil,
              recovery.armedResume?.item.id == sessionIdentifier,
              !printerCoordinator.requiresRecovery, !operationalState.hasUnresolvedPrint,
              let item = recovery.takeArmedResume() else { return }
        logGuestAction("operator_resume", result: "original_checkout")
        beginRecoveredCheckout(item)
    }

    /// Continues an operator-armed interrupted paid checkout: same checkout session, same paid
    /// quantity and format, fresh photos. Never charges, never rebinds to another session.
    private func beginRecoveredCheckout(_ item: CheckoutRecoveryItem) {
        let checkpoint = item.checkpoint
        guard let format = BoothFormat(rawValue: checkpoint.format) else {
            state = .error("This paid session could not be resumed. Please see the attendant.")
            return
        }
        let recovery: AppRecoverySnapshot?
        do {
            guard let recoveryStore, let checkpointStore else { throw AppRecoveryStoreError.unavailable }
            recovery = try CheckoutInteractionClosure.snapshotForResume(id: checkpoint.id, checkpoints: checkpointStore,
                recovery: recoveryStore, detached: DetachedCheckoutStore(directory: environment.detachedCheckoutDirectory))
        } catch {
            state = .error("This checkout is still saved. \(error.localizedDescription)")
            return
        }
        if checkpoint.receiptPrintOptions != nil {
            // Current checkouts must retain their original gallery identity across recovery.
            // Never mint a replacement token after an interrupted customer's admission.
            guard let recovery, let token = recovery.galleryToken, let url = recovery.galleryURL,
                  GalleryURLBuilder.customerGalleryBaseURL(ofGalleryURL: url, galleryToken: token) != nil else {
                state = .error("The original gallery recovery record is unavailable. Please see the attendant; this paid checkout has been retained.")
                return
            }
        }
        cancelTasks()
        clearCustomerData()
        beginNewCustomerSession()
        // Resuming the original checkout must use its receipt profile, including an original
        // standard (nil) profile, rather than inheriting the current event or another guest.
        customerEventProfile = recovery.map { $0.eventProfile ?? .pocketPixelsDefault }
            ?? environment.eventProfileSource().normalized()
        galleryToken = recovery?.galleryToken
        galleryURL = recovery?.galleryURL
        let generation = customerSessionGeneration
        isTransitionActive = true
        statusMessage = "Resuming your paid session…"
        state = .paymentReconciliation
        activeTask = Task { [weak self] in
            guard let self else { return }
            do {
                let entitlement = try await recoveredEntitlement(for: checkpoint, generation: generation)
                guard isCurrentCustomerSession(generation) else { return }
                commercialEvent = CommercialEventRun(
                    id: checkpoint.eventID, name: commercialEvent.name, venue: "", lifecycle: .active,
                    activePolicy: PaymentPolicySnapshot(revisionID: checkpoint.policyRevisionID, revision: 0, commercialMode: .payPerPrint,
                                                        unitPriceCentavos: checkpoint.unitPriceCentavos, maxCopies: checkpoint.copies, defaultCopies: checkpoint.copies,
                                                        cashEnabled: false, qrPhEnabled: false, prepaidGuestCopyChoice: false,
                                                        supportedFormatRawValues: [checkpoint.format], offlineValidUntil: nil),
                    startsAt: nil, endsAt: nil, updatedAt: Date())
                sessionRunID = try eventRunStore?.session(id: checkpoint.id)?.runID
                sessionPrintOptions = checkpoint.receiptPrintOptions ?? recovery?.receiptPrintOptions ?? ReceiptPrintOptions(footerStyle: .classicBarcodeAndGalleryQR)
                sessionGalleryReceiptStyle = checkpoint.galleryReceiptStyle ?? recovery?.galleryReceiptStyle ?? .shareFriendly
                guard prepareSessionContext(format: format, sessionIdentifier: checkpoint.id, createdAt: recovery?.createdAt ?? checkpoint.createdAt) else { return }
                checkoutGuard = CheckoutGuard(serverCheckoutStarted: true, qrAttemptUnresolved: false, newCheckoutAllowed: false)
                checkoutEntitlement = entitlement
                selectedCheckoutCopies = entitlement.purchasedCopies
                selectedPrintCopies = entitlement.purchasedCopies
                guard checkpointStore?.update(id: checkpoint.id, {
                    $0.phase = .claimed; $0.locallyClosedAt = nil; $0.localCloseReason = nil; $0.detachedAt = nil
                }) == true else { throw SetupFailure("The resumed checkout could not be saved. Retry from Outstanding Payments.") }
                isTransitionActive = false
                prepareCameraAfterAuthorization()
            } catch {
                guard isCurrentCustomerSession(generation) else { return }
                isTransitionActive = false
                state = .error("This paid session could not be resumed. Please see the attendant.")
                Task { await PaymentRecoveryCoordinator.shared.refresh() }
            }
        }
    }

    private func recoveredEntitlement(for checkpoint: CheckoutCheckpoint, generation: Int) async throws -> CheckoutEntitlement {
        // Paper may already exist for this checkout: only the operator's paper inspection decides.
        guard let checkpointStore, checkpointStore.integrityFault == nil,
              let printOutbox, printOutbox.integrityFault == nil, printOutbox.persistenceFailure == nil,
              printOutbox.inspectionEntryIDs.isEmpty, !printOutbox.hasUnfinishedPhysicalSend,
              printOutbox.copiesThatMayHavePrinted(sessionID: checkpoint.id).isEmpty else {
            throw PaymentsAPIError.configuration("Printing had already started for this checkout.")
        }
        if checkpoint.method == "OFFLINE_CASH" {
            guard let ledger = offlineCashLedger,
                  let record = await ledger.allRecords().first(where: { $0.sessionID == checkpoint.id }) else {
                throw OfflineCashLedger.LedgerError.invalidPolicy
            }
            guard isCurrentCustomerSession(generation), !Task.isCancelled else { throw CancellationError() }
            policyAuthority = .signedOffline(snapshotID: record.snapshotID ?? "", expiresAt: record.declaredAt)
            return CheckoutEntitlement(id: "offline-cash-\(record.id)", orderID: nil, eventID: record.eventID, policyRevisionID: record.policyRevisionID,
                                       sessionID: checkpoint.id, selectedFormatRawValue: record.format, purchasedCopies: record.copies,
                                       unitPriceCentavos: record.unitPriceCentavos, totalCentavos: record.totalCentavos,
                                       authorizationSource: .localUnsyncedCashDeclared, authorizedAt: record.declaredAt, receiptFingerprint: nil)
        }
        guard let client = paymentsClient, client.environment == checkpoint.environment,
              checkpoint.serverBinding == nil || checkpoint.serverBinding == client.serverBinding else {
            throw PaymentsAPIError.configuration("Payments are not set up for this checkout's environment.")
        }
        let server = try await client.checkoutRecovery(checkoutSessionID: checkpoint.id)
        let classification = CheckoutRecoveryClassifier.classify(checkpoint: checkpoint, server: server, localPrintStarted: false, offlineRecordExists: false)
        guard classification.isResumable,
              let open = server.orders.first(where: { $0.order.id == server.openOrderId }),
              let entitlement = open.entitlement,
              entitlement.purchasedCopies == checkpoint.copies else {
            throw PaymentsAPIError.configuration("This checkout is not resumable.")
        }
        let claimed = try await retryingUnknownOutcome {
            try await client.claim(entitlementID: entitlement.id, sessionID: checkpoint.id, idempotencyKey: "claim-\(entitlement.id)", recovery: true)
        }
        guard claimed.sessionID == checkpoint.id, claimed.permitsCapture else { throw PaymentsAPIError.invalidResponse }
        guard isCurrentCustomerSession(generation), !Task.isCancelled else { throw CancellationError() }
        policyAuthority = .serverConfirmed(fetchedAt: Date())
        paymentOrder = open.order
        return claimed
    }

    private func prepareCameraAfterAuthorization() {
        guard checkoutEntitlement?.permitsCapture == true else { state = .error("Payment authorization is required before the camera can start."); return }
        let sessionGeneration = customerSessionGeneration
        guard releaseAuthorizationTaskForCamera(generation: sessionGeneration) else { return }
        let format = selectedBoothFormat ?? .solo
        isTransitionActive = true
        isCameraUnavailable = false
        errorMessage = nil
        statusMessage = "Preparing front camera..."
        state = .preparingCamera
        debugLog("[Session] authorized format: \(selectedBoothFormat?.displayName ?? "unknown")")
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

    /// Payment authorization owns `activeTask` until capture is permitted. Relinquish that
    /// ownership at the camera boundary so Start Photos can install the capture task. A stale
    /// authorization callback cannot release a newer customer session's task.
    @discardableResult
    func releaseAuthorizationTaskForCamera(generation: Int) -> Bool {
        guard isCurrentCustomerSession(generation) else { return false }
        activeTask = nil
        stopPaymentPolling()
        return true
    }

#if DEBUG
    var hasActiveTaskForTesting: Bool { activeTask != nil }

    func installAuthorizationTaskForTesting() {
        activeTask = Task { await Task.yield() }
    }

    func configureAuthorizedCameraReadyForTesting(authorizationSource: CheckoutAuthorizationSource = .privatePrepaid) {
        let identifier = "TEST-\(UUID().uuidString)"
        selectedBoothFormat = .solo
        sessionIdentifier = identifier
        checkoutEntitlement = CheckoutEntitlement(
            id: "prepaid-\(identifier)", orderID: nil, eventID: "test", policyRevisionID: "test",
            sessionID: identifier, selectedFormatRawValue: BoothFormat.solo.rawValue,
            purchasedCopies: 1, unitPriceCentavos: 0, totalCentavos: 0,
            authorizationSource: authorizationSource, authorizedAt: Date(), receiptFingerprint: nil
        )
        isTransitionActive = false
        isCameraUnavailable = false
        state = .cameraReady
    }

    /// A paid session at copy selection with the given methods, without touching the server.
    func configurePaidCheckoutForTesting(qrPhEnabled: Bool, cashEnabled: Bool, authority: PolicyAuthority = .serverConfirmed(fetchedAt: Date())) {
        var run = CommercialEventRun.legacy
        run.activePolicy.commercialMode = .payPerPrint
        run.activePolicy.unitPriceCentavos = 2_500
        run.activePolicy.qrPhEnabled = qrPhEnabled
        run.activePolicy.cashEnabled = cashEnabled
        commercialEvent = run
        policyAuthority = authority
        checkoutGuard = CheckoutGuard()
        selectedBoothFormat = .solo
        sessionIdentifier = "TEST-\(UUID().uuidString)"
        selectedCheckoutCopies = 2
        isTransitionActive = false
        state = .choosingCopies
    }

    func handleCheckoutErrorForTesting(_ error: PaymentsAPIError) { handleCheckoutError(error) }

    func configureUnresolvedCheckoutForTesting(qrAttemptUnresolved: Bool = true) {
        checkoutGuard = CheckoutGuard(serverCheckoutStarted: true, qrAttemptUnresolved: qrAttemptUnresolved, newCheckoutAllowed: false)
    }

    func completeSessionForReportingTest() { showThankYou() }

    var paymentPollTaskForTesting: Task<Void, Never>? { paymentPollTask }

    func beginPaymentReconciliationForTesting() {
        checkoutGuard = CheckoutGuard(serverCheckoutStarted: true, qrAttemptUnresolved: true, newCheckoutAllowed: false)
        enterReconciliation("Checking the original payment. Do not pay again.")
    }

    var activeTaskForTesting: Task<Void, Never>? { activeTask }

    func cancelActiveTaskForTesting() {
        stopPaymentPolling()
        activeTask?.cancel()
        activeTask = nil
        isTransitionActive = false
    }
#endif

    func beginPhotoSequence() {
        guard checkoutEntitlement?.permitsCapture == true, canBeginPhotos, selectedBoothFormat != nil, committedGallerySession == nil else {
            return
        }

        capturedPhotos.removeAll()
        originalCaptureBytes.removeAll()
        transientCapturedPhoto = nil
        transientCapturedPhotoIndex = nil
        receiptImage = nil
        receiptPhotoPreviewImage = nil
        thermalReceiptPreview = nil
        monochromeReceiptPreview = nil
        receiptRasterizedImage = nil
        composedReceipt = nil
        samplePhotoCount = 0
        runAutomaticSequence(startingAt: 0)
    }

    var operatorCloseBlockReason: String? {
        if printerCoordinator.isWorking || printerState.isWorking || isPrintBatchActive {
            return "The active print transport must finish before closing. Paper may already be moving."
        }
        if isTransitionActive { return "Wait for the current checkout or photo operation to finish, then Close Session & Continue."
        }
        return nil
    }

    /// Synchronous commit and callback invalidation on the main actor: a late verification
    /// cannot open a camera for the guest who just left.
    func closeSessionForOperator() throws {
        guard OperatorAccessPermit.shared.isAuthorized else { throw SetupFailure("Unlock Operator before closing a guest session.") }
        if let reason = operatorCloseBlockReason { throw SetupFailure(reason) }
        guard !printerCoordinator.requiresRecovery, !operationalState.hasUnresolvedPrint else {
            throw SetupFailure("Review Receipt and record the physical check before closing this session.")
        }
        guard let recoveryStore else { throw AppRecoveryStoreError.unavailable }
        let saved = try recoveryStore.loadChecked()
        let snapshot: AppRecoverySnapshot?
        if let saved, saved.sessionIdentifier == sessionIdentifier, saved.stage == .printStatusUnknown {
            snapshot = saved
        } else {
            snapshot = makeRecoverySnapshot(stage: receiptImage != nil ? .receiptComposed : (capturedPhotos.isEmpty ? .formatSelected : .photosCaptured))
                ?? saved.flatMap { $0.sessionIdentifier == sessionIdentifier ? $0 : nil }
            if let snapshot { try recoveryStore.saveCritical(snapshot) }
        }
        if let id = sessionIdentifier, let checkpoint = checkpointStore?.checkpoint(id: id), !checkpoint.isResolved {
            guard let checkpointStore else { throw SetupFailure("Checkout storage is unavailable.") }
            try CheckoutInteractionClosure.close(id: id, reason: "operator:guest_left", checkpoints: checkpointStore,
                recovery: recoveryStore, detached: DetachedCheckoutStore(directory: environment.detachedCheckoutDirectory), snapshot: snapshot)
        } else if let snapshot {
            _ = try OperatorRecoveryAcknowledgement.retainAndAcknowledge(snapshot, store: recoveryStore)
        }
        resetToWelcome()
        operationalState.customerSessionActive = false
        operationalState.refresh()
    }

    func cancelSession() {
        if isTransitionActive && (state == .choosingPayment || state == .cashAttestation || state == .paymentReconciliation) { return }
        if checkoutEntitlement == nil && (checkoutGuard.serverCheckoutStarted || checkoutGuard.qrAttemptUnresolved || paymentOrder != nil || paymentAttempt != nil) {
            statusMessage = "Please ask the attendant to check this payment. Do not pay again."
            state = .paymentReconciliation
            if !isTransitionActive, paymentPollTask == nil {
                pollQRStatus(orderID: paymentOrder?.id, generation: customerSessionGeneration)
            }
            logGuestAction("cancel", result: "retained_unresolved_checkout")
            return
        }
        guard !printerState.isWorking, !isPrintBatchActive,
              !printerCoordinator.requiresRecovery, !operationalState.hasUnresolvedPrint else {
            statusMessage = "Printer needs operator attention before this session can be cleared."
            return
        }
        if let entitlement = checkoutEntitlement,
           entitlement.authorizationSource != .privatePrepaid {
            // Payment is already authorized. End the guest interaction without rechecking it
            // or resolving/deleting its durable checkout; the attendant can resume the same
            // paid session from Payment Recovery. No printing has started (guards above).
            do {
                guard let id = sessionIdentifier, let checkpointStore, let recoveryStore else { throw AppRecoveryStoreError.unavailable }
                let current = makeRecoverySnapshot(stage: receiptImage != nil ? .receiptComposed : (capturedPhotos.isEmpty ? .formatSelected : .photosCaptured))
                guard let snapshot = try current ?? recoveryStore.loadChecked(), snapshot.sessionIdentifier == id else {
                    throw AppRecoveryStoreError.unavailable
                }
                try recoveryStore.saveCritical(snapshot)
                try CheckoutInteractionClosure.close(id: id, reason: "guest:cancelled", checkpoints: checkpointStore,
                    recovery: recoveryStore, detached: DetachedCheckoutStore(directory: environment.detachedCheckoutDirectory), snapshot: snapshot)
                resetToWelcome()
            } catch { statusMessage = "Session is still saved here: \(error.localizedDescription) Ask the attendant for help." }
            return
        }
        do {
            if let snapshot = makeRecoverySnapshot(stage: receiptImage != nil ? .receiptComposed : (capturedPhotos.isEmpty ? .formatSelected : .photosCaptured)),
               !snapshot.photoJPEGData.isEmpty || snapshot.receiptPreviewPNGData != nil {
                guard let recoveryStore else { throw AppRecoveryStoreError.unavailable }
                _ = try OperatorRecoveryAcknowledgement.retainAndAcknowledge(snapshot, store: recoveryStore)
            }
            recoveryStore?.clear(sessionIdentifier: sessionIdentifier)
            resetToWelcome()
        } catch { statusMessage = "Could not keep the photos safely: \(error.localizedDescription) Please retry or call the attendant." }
    }

    func retakePhoto(at index: Int) {
        guard capturedPhotos.indices.contains(index), !isTransitionActive, committedGallerySession == nil else {
            return
        }

        transientCapturedPhoto = nil
        transientCapturedPhotoIndex = nil
        retakeIndex = index
        state = .retaking(photoIndex: index)
        statusMessage = "Retaking photo \(index + 1)."
        receiptImage = nil
        receiptPhotoPreviewImage = nil
        thermalReceiptPreview = nil
        monochromeReceiptPreview = nil
        receiptRasterizedImage = nil
        composedReceipt = nil
        startCameraForRetake(index: index)
    }

    func retakeAll() {
        guard !isTransitionActive, committedGallerySession == nil else {
            return
        }

        capturedPhotos.removeAll()
        originalCaptureBytes.removeAll()
        transientCapturedPhoto = nil
        transientCapturedPhotoIndex = nil
        receiptImage = nil
        receiptPhotoPreviewImage = nil
        thermalReceiptPreview = nil
        monochromeReceiptPreview = nil
        receiptRasterizedImage = nil
        composedReceipt = nil
        // Every photo is replaced, so no sticker may carry over to the new pictures.
        discardStickerDraft()
        statusMessage = "Restarting the photo sequence."
        startCameraForSequence()
    }

    func addSamplePhoto(_ image: UIImage) {
        guard isCameraUnavailable, selectedBoothFormat != nil, capturedPhotos.count < requiredPhotoCount, !isTransitionActive, committedGallerySession == nil else {
            return
        }

        guard let format = selectedBoothFormat else { return }
        let index = capturedPhotos.count
        let normalized = Self.normalizedCapture(image, format: format)
        capturedPhotos.append(normalized)
        samplePhotoCount = capturedPhotos.count
        transientCapturedPhotoIndex = index
        transientCapturedPhoto = CapturePhotoPresentation.resolve(format: format, photoIndex: index)
            .confirmationPhoto(from: normalized, format: format, photoIndex: index)
        statusMessage = "Photo \(index + 1) captured."
        isTransitionActive = true

        let sessionGeneration = customerSessionGeneration
        let pause = captureConfirmationPause
        let task = Task {
            await pause()
            // A reset or new session during the confirmation owns the state now; never touch it.
            guard !Task.isCancelled, isCurrentCustomerSession(sessionGeneration) else { return }
            transientCapturedPhoto = nil
            transientCapturedPhotoIndex = nil
            state = capturedPhotos.count == requiredPhotoCount ? .review : .cameraReady
            statusMessage = capturedPhotos.count == requiredPhotoCount
                ? "Review your photos."
                : "Select the next sample photo."
            isTransitionActive = false
            activeTask = nil
            captureConfirmationTask = nil
        }
        activeTask = task
        captureConfirmationTask = task
    }

    /// Waits until the current sample-photo confirmation has finished (or was invalidated).
    /// Returns immediately when no confirmation is in flight.
    func awaitCaptureConfirmation() async {
        await captureConfirmationTask?.value
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

    /// Existing entry point used by Review, the Photo Pass preview and qualification.
    func continueToReceipt() {
        requestReceiptFinalization()
    }

    /// The guest is done with photos (and Photo Pass details). Opens Sticker Studio when this
    /// session froze it ON, otherwise commits the receipt exactly as before. Never recursive:
    /// Sticker Studio's Done/Skip call `finalizeReceipt` directly.
    func requestReceiptFinalization() {
        if selectedBoothFormat == .passport, state != .passportPreview, state != .stickerStudio {
            continueFromReview()
            return
        }
        guard state != .stickerStudio, state != .preparingStickers else { return }
        guard canContinueToReceipt else {
            finalizeReceipt(stickers: [])
            return
        }
        if stickerStepEnabledForSession {
            openStickerStudio()
        } else {
            finalizeReceipt(stickers: [])
        }
    }

    /// Freezes the committed session and starts composition, archive and gallery delivery.
    /// The single irreversible step; it runs at most once per session.
    private func finalizeReceipt(stickers: [FrozenStickerDecoration]) {
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
            passport: selectedBoothFormat == .passport ? passportDraft.committed(at: receiptDate) : nil,
            printOptions: sessionPrintOptions,
            galleryReceiptStyle: sessionGalleryReceiptStyle,
            stickers: stickers
        )
        passportPreviewTask?.cancel()
        stickerPreparationTask?.cancel()
        stickerPreparationTask = nil
        committedGallerySession = committedSession
        receiptFinalizationCount += 1
        // The draft is frozen into the committed session; release editor memory and network.
        stickerStudio?.close()
        stickerStudio = nil
        stickerStudioReturnState = nil
        composeReceipt(for: committedSession, enqueueUpload: true)
    }

    // MARK: Sticker Studio

    /// Freezes Sticker Studio settings for this session (called when the session starts).
    func freezeSessionStickerConfiguration() {
        sessionStickerConfiguration = environment.isQualification ? .disabled : environment.stickerConfigurationSource()
        if sessionStickerConfiguration.isGuestStepEnabled, sessionStickerConfiguration.settings.emojiCollectionEnabled {
            // Decode the bundled emoji catalog in the background long before Sticker Studio opens.
            Task.detached(priority: .utility) { _ = EmojiCatalog.shared }
        }
    }

    private func openStickerStudio() {
        guard canContinueToReceipt,
              stickerPreparationTask == nil,
              let selectedBoothFormat,
              let sessionIdentifier,
              let receiptDate = sessionCreatedAt else {
            finalizeReceipt(stickers: [])
            return
        }
        let configuration = sessionStickerConfiguration
        let sessionGeneration = customerSessionGeneration
        if stickerStudio == nil || stickerStudio?.generation != sessionGeneration {
            stickerStudio?.close()
            let store = configuration.settings.operatorCollectionEnabled ? environment.stickerCatalogStoreSource() : nil
            let catalog = StickerGuestCatalog.make(settings: configuration.settings, store: store)
            stickerStudio = StickerStudioSession(
                configuration: configuration,
                catalog: catalog,
                generation: sessionGeneration,
                catalogStore: store,
                provider: nil
            )
        }
        guard let studio = stickerStudio, studio.hasContent else {
            // Enabled but nothing to offer (e.g. every source off): continue without a blank editor.
            stickerStudio?.close()
            stickerStudio = nil
            finalizeReceipt(stickers: [])
            return
        }

        stickerStudioReturnState = state
        passportPreviewTask?.cancel()
        isTransitionActive = true
        state = .preparingStickers
        statusMessage = "Getting your stickers ready..."

        // The editor draws on the real, undecorated receipt so its geometry is the print geometry.
        let photos = capturedPhotos
        let galleryURL = self.galleryURL
        let eventProfile = sessionEventProfile
        let passport = selectedBoothFormat == .passport ? passportDraft.committed(at: receiptDate) : nil
        let photoProfile = customerPrintPhotoProfile
        let printOptions = sessionPrintOptions
        stickerPreparationTask = Task {
            let worker = Task.detached(priority: .userInitiated) { () throws -> (UIImage, StickerLayoutSnapshot) in
                let receipt = try ReceiptComposer.compose(
                    photos: photos,
                    sessionIdentifier: sessionIdentifier,
                    date: receiptDate,
                    galleryURL: galleryURL,
                    format: selectedBoothFormat,
                    eventProfile: eventProfile,
                    passport: passport,
                    photoQualityProfile: photoProfile,
                    printOptions: printOptions
                )
                guard let layout = receipt.stickerLayout, !layout.regions.isEmpty,
                      let image = UIImage(data: receipt.imagePNGData) else {
                    throw ReceiptComposerError.renderFailed
                }
                try Task.checkCancellation()
                return (ReceiptComposer.makePhotoSectionPreviewImage(from: image, previewContentHeight: layout.editorVisibleHeight), layout)
            }
            let result = try? await withTaskCancellationHandler {
                try await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled, isCurrentCustomerSession(sessionGeneration), state == .preparingStickers else {
                debugLog("[Stickers] ignored stale sticker canvas")
                return
            }
            stickerPreparationTask = nil
            isTransitionActive = false
            guard let result, let studio = stickerStudio, studio.generation == sessionGeneration else {
                debugLog("[Stickers] canvas unavailable; continuing without stickers")
                state = stickerStudioReturnState ?? .review
                finalizeReceipt(stickers: [])
                return
            }
            studio.setCanvas(image: result.0, layout: result.1)
            statusMessage = "Make it yours."
            state = .stickerStudio
        }
    }

    /// Done: commits the guest's stickers into the receipt, exactly once.
    func finishStickerStudio() {
        guard state == .stickerStudio, let studio = stickerStudio, studio.generation == customerSessionGeneration, studio.pendingInsertions == 0 else { return }
        finalizeReceipt(stickers: studio.freeze())
    }

    /// Skip: commits the original receipt with no stickers, exactly once.
    func skipStickerStudio() {
        guard state == .stickerStudio else { return }
        finalizeReceipt(stickers: [])
    }

    /// Back: returns to the previous step keeping photos, format, Photo Pass details, signature
    /// and the sticker draft. No upload, archive or printer action.
    func backFromStickerStudio() {
        guard state == .stickerStudio || state == .preparingStickers, committedGallerySession == nil else { return }
        stickerPreparationTask?.cancel()
        stickerPreparationTask = nil
        isTransitionActive = false
        let destination = stickerStudioReturnState ?? .review
        stickerStudioReturnState = nil
        if destination == .passportPreview, selectedBoothFormat == .passport {
            statusMessage = "Here's your Photo Pass."
            state = .passportPreview
            renderPassportPreview()
        } else {
            statusMessage = "Review your photos."
            state = .review
        }
    }

    /// Retained notification hook. Offline source settings are frozen until the next guest.
    func handleStickerSettingsChanged() {
        // Source choices are frozen for the current guest. There are no online requests to stop.
    }

    private func discardStickerDraft() {
        stickerPreparationTask?.cancel()
        stickerPreparationTask = nil
        stickerStudio?.close()
        stickerStudio = nil
        stickerStudioReturnState = nil
    }

    func rebuildReceipt() {
        guard let committedGallerySession else {
            receiptImage = nil
            receiptPhotoPreviewImage = nil
            thermalReceiptPreview = nil
            monochromeReceiptPreview = nil
            receiptRasterizedImage = nil
            composedReceipt = nil
            continueToReceipt()
            return
        }

        receiptImage = nil
        receiptPhotoPreviewImage = nil
        thermalReceiptPreview = nil
        monochromeReceiptPreview = nil
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
                        photoQualityProfile: customerPrintPhotoProfile,
                        printOptions: committedSession.printOptions,
                        stickers: committedSession.stickers
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
                    // Optional presentation copy: a failure here never blocks the print job.
                    let monochromePreview = try? MonochromeReceiptRenderer.render(receiptImage).image
                    try Task.checkCancellation()
                    return (receipt, receiptImage, receiptPhotoPreviewImage, preview, rasterized, galleryReceiptImage, monochromePreview)
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
                monochromeReceiptPreview = result.6
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
            photoQualityProfile: photoQualityProfile,
            printOptions: committedSession.printOptions,
            // Stickers only ever cover photos, so the redacted copy keeps them too.
            stickers: committedSession.stickers
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
        let printOptions = sessionPrintOptions
        let previewGalleryURL = galleryURL
        let sessionGeneration = customerSessionGeneration
        passportPreviewTask = Task {
            let worker = Task.detached(priority: .userInitiated) { () throws -> UIImage in
                let receipt = try ReceiptComposer.compose(
                    photos: photos,
                    sessionIdentifier: "PASSPORT-PREVIEW",
                    date: date,
                    galleryURL: previewGalleryURL,
                    format: .passport,
                    eventProfile: eventProfile,
                    passport: passport,
                    photoQualityProfile: photoProfile,
                    printOptions: printOptions
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

    /// The qualification engine calls this only after its run-bound print-budget gate passes.
    /// Customer/payment entitlements cannot be changed through this diagnostic entry point.
    func authorizeQualificationPrint(copies: Int) -> Bool {
        guard environment.isQualification, state == .receiptPreview,
              printBatchTask == nil, !isPrintBatchActive,
              Self.printCopyRange.contains(copies), receiptRasterizedImage != nil,
              let entitlement = checkoutEntitlement,
              entitlement.authorizationSource == .privatePrepaid, entitlement.orderID == nil,
              let sessionIdentifier, entitlement.sessionID == sessionIdentifier,
              entitlement.selectedFormatRawValue == selectedBoothFormat?.rawValue else { return false }
        checkoutEntitlement = CheckoutEntitlement(
            id: entitlement.id, orderID: nil, eventID: entitlement.eventID,
            policyRevisionID: entitlement.policyRevisionID, sessionID: sessionIdentifier,
            selectedFormatRawValue: entitlement.selectedFormatRawValue, purchasedCopies: copies,
            unitPriceCentavos: 0, totalCentavos: 0, authorizationSource: .privatePrepaid,
            authorizedAt: entitlement.authorizedAt, receiptFingerprint: entitlement.receiptFingerprint
        )
        selectedPrintCopies = copies
        return true
    }

    func printReceipt(host: String, port: UInt16?) {
        debugLog("[PrintTap] state=\(state) printerState=\(printerState) batchTaskActive=\(printBatchTask != nil) port=\(port.map(String.init) ?? "nil") rasterReady=\(receiptRasterizedImage != nil)")
        guard let checkoutEntitlement,
              checkoutEntitlement.purchasedCopies == selectedPrintCopies else {
            statusMessage = "This print quantity is not authorized for the session."
            printerState = .failure(statusMessage)
            return
        }
        guard printBatchTask == nil else {
            debugLog("[PrintTap] ignored: a print batch is already running")
            return
        }

        guard let port else {
            debugLog("[PrintTap] blocked: invalid printer port")
            printerState = .failure("Enter a valid TCP port from 1 to 65535.")
            return
        }

        guard let rasterized = receiptRasterizedImage else {
            debugLog("[PrintTap] receipt raster missing; rebuilding")
            statusMessage = "Rebuilding your receipt before printing…"
            rebuildReceipt()
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
            debugLog("[PrintTap] blocked: raster validation failed \(error.localizedDescription)")
            printerState = .failure(error.localizedDescription)
            return
        }

        let requestedCopies = selectedPrintCopies
        let sessionGeneration = customerSessionGeneration
        let printBatchID: UUID
        var firstCopy = 1
        if isPaidSession {
            // A paid retry continues the same batch from the first copy that cannot have printed.
            let batch = paidPrintBatchID ?? UUID()
            paidPrintBatchID = batch
            printBatchID = batch
            guard let next = printOutbox?.nextCopyToPrint(batchID: batch.uuidString.lowercased(), copyCount: requestedCopies) else {
                printerState = .failure("All paid copies were already sent. Please see the attendant.")
                return
            }
            firstCopy = next
        } else {
            printBatchID = UUID()
        }
        let receiptFingerprint = Self.receiptPayloadFingerprint(for: rasterized)
        currentPrintCopy = firstCopy - 1
        completedPrintCopies = firstCopy - 1
        isPrintBatchActive = true
        state = .connectingToPrinter
        statusMessage = "Preparing printer..."
        debugLog("[MULTI-COPY] requestedCopies=\(requestedCopies)")
        debugLog("[PrintBatch \(printBatchID)] session=\(sessionIdentifier ?? "unknown") requestedCopies=\(requestedCopies) receiptFingerprint=\(receiptFingerprint) bytes=\(Self.receiptPayloadByteCount(for: rasterized))")

        printBatchTask = Task { [weak self] in
            guard let self else { return }
            await self.printReceiptCopies(
                firstCopy: firstCopy,
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
            if (state == .paymentReconciliation || state == .awaitingQRPayment), !isTransitionActive {
                pollQRStatus(orderID: paymentOrder?.id, generation: customerSessionGeneration)
            }
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
        guard state == .welcome else { return }
        customerEventProfile = environment.eventProfileSource().normalized()
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
                    for result in queueFailure.successfulResults where isCurrentGalleryToken(result.galleryToken) {
                        setUploadPhase(.success(result.galleryURL), message: "Your photos are ready.", for: result.galleryToken)
                    }
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
            transientCapturedPhotoIndex = nil
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
            transientCapturedPhotoIndex = nil
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
            let capture = try await capturePhoto()
            let image = capture.image
            guard !Task.isCancelled else { return }
            guard isCurrentCustomerSession(sessionGeneration) else {
                debugLog("[Session] ignored stale captured photo")
                return
            }

            if !environment.isQualification && SessionMediaExport.keepsOriginals {
                originalCaptureBytes[index] = capture.encodedData
            }

            if replacing, capturedPhotos.indices.contains(index) {
                capturedPhotos[index] = image
            } else if capturedPhotos.count == index {
                capturedPhotos.append(image)
            } else if capturedPhotos.indices.contains(index) {
                capturedPhotos[index] = image
            }

            let format = selectedBoothFormat
            let confirmationWorker = Task.detached(priority: .userInitiated) {
                guard let format else { return image }
                return CapturePhotoPresentation.resolve(format: format, photoIndex: index)
                    .confirmationPhoto(from: image, format: format, photoIndex: index)
            }
            let confirmationPhoto = await confirmationWorker.value
            guard !Task.isCancelled, isCurrentCustomerSession(sessionGeneration) else { return }
            transientCapturedPhotoIndex = index
            transientCapturedPhoto = confirmationPhoto
            statusMessage = "Photo \(index + 1) captured."
            persistRecoverySnapshot(stage: .photosCaptured)
            if replacing {
                debugLog("[Retake] replaced photo index \(index + 1)")
            }
            debugLog("Session \(sessionIdentifier ?? "unknown") captured photo \(index + 1).")
            await captureConfirmationPause()
            guard isCurrentCustomerSession(sessionGeneration) else {
                debugLog("[Session] ignored stale captured photo display completion")
                return
            }
            transientCapturedPhoto = nil
            transientCapturedPhotoIndex = nil
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

    private func capturePhoto() async throws -> CameraCapture {
        let format = selectedBoothFormat
        return try await withCheckedThrowingContinuation { continuation in
            cameraService.captureOriginalPhoto { result in
                switch result {
                case .success(let capture):
                    continuation.resume(returning: CameraCapture(image: Self.normalizedCapture(capture.image, format: format), encodedData: capture.encodedData))
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
        if environment.recordsCustomerSessionMetrics {
            if let sessionIdentifier {
                let wasCompleted = (try? eventRunStore?.session(id: sessionIdentifier))?.completedAt != nil
                eventRunStore?.updateSession(id: sessionIdentifier) { if $0.completedAt == nil { $0.completedAt = Date() } }
                if !wasCompleted { operationalState.recordSessionCompleted() }
            }
        }
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
        detachedRecoveryReference = nil
        capturedPhotos.removeAll()
        originalCaptureBytes.removeAll()
        transientCapturedPhoto = nil
        transientCapturedPhotoIndex = nil
        composedReceipt = nil
        receiptImage = nil
        receiptPhotoPreviewImage = nil
        thermalReceiptPreview = nil
        monochromeReceiptPreview = nil
        receiptRasterizedImage = nil
        sessionIdentifier = nil
        sessionCreatedAt = nil
        sessionEventProfile = nil
        sessionRunID = nil
        galleryToken = nil
        galleryURL = nil
        galleryQRCodeImage = nil
        committedGallerySession = nil
        uploadPhase = .idle
        uploadStatusMessage = "Gallery upload has not started."
        samplePhotoCount = 0
        selectedBoothFormat = nil
        checkoutEntitlement = nil
        paymentOrder = nil
        paymentAttempt = nil
        checkoutGuard = CheckoutGuard()
        supersedeOrderID = nil
        checkoutAttempt = 0
        paidPrintBatchID = nil
        paymentNotice = nil
        selectedCheckoutCopies = 1
        selectedPrintCopies = 1
        currentPrintCopy = 0
        completedPrintCopies = 0
        passportDraft = .empty
        resetPassportPreview()
        discardStickerDraft()
        sessionStickerConfiguration = .disabled
        // The detached archive commit is never cancelled (it owns immutable session values); the
        // reference is dropped so a later session can never await another session's archive.
        archiveCommitTask = nil
        archiveCommitPayload = nil
    }

    private func cancelTasks() {
        stopPaymentPolling()
        activeTask?.cancel()
        activeTask = nil
        captureConfirmationTask?.cancel()
        captureConfirmationTask = nil
        printBatchTask?.cancel()
        printBatchTask = nil
        isPrintBatchActive = false
        cameraWatchdogTask?.cancel()
        cameraWatchdogTask = nil
        passportPreviewTask?.cancel()
        passportPreviewTask = nil
        stickerPreparationTask?.cancel()
        stickerPreparationTask = nil
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
        firstCopy: Int = 1,
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

        for copy in firstCopy...requestedCopies {
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
                recordCopyOutcome(copy: copy, batchID: printBatchID, result: result)
                debugLog("[MULTI-COPY] completedCopy=\(copy)")
                debugLog("[PrintBatch \(printBatchID)] copy=\(copy)/\(requestedCopies) complete fingerprint=\(receiptFingerprint) elapsed=\(Self.formatDuration(completionReportedAt.timeIntervalSince(copyRequestedAt)))")
                if copy < requestedCopies {
                    debugLog("[PrintBatch] copy \(copy + 1) requested immediately after copy \(copy) completion")
                }
            case .failure(let error) where error is PrintCheckpointError:
                // Fail-closed checkpoint: no bytes for this copy, no recovery lock, data kept.
                recordCopyOutcome(copy: copy, batchID: printBatchID, result: result)
                let message = "\(completedPrintCopies) of \(requestedCopies) copies printed. \(error.localizedDescription)"
                state = .receiptPreview
                printerState = .failure(message)
                statusMessage = message
                return
            case .failure(let error):
                let message = "\(completedPrintCopies) of \(requestedCopies) copies printed. \(error.localizedDescription)"
                // Bytes may have reached the printer: recorded as UNCERTAIN and never auto-reprinted.
                recordCopyOutcome(copy: copy, batchID: printBatchID, result: result)
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

        finishPaidCheckout(batchID: printBatchID)
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
                source: environment.printSource,
                copyIndex: copy,
                copyCount: requestedCopies,
                batchID: batchID ?? UUID(),
                transportPolicy: printerCoordinator.productionReceiptTransportPolicy,
                prePrintCheckpoint: PrePrintCheckpointGate({ [weak self] envelope in
                    // Runs inside the print spooler immediately before transport. A stale session
                    // or a failed durable write blocks the job before any bytes are sent.
                    guard let self, self.isCurrentCustomerSession(sessionGeneration) else {
                        throw PrintCheckpointError.persistenceFailed("Customer session changed before printing.")
                    }
                    try self.persistCriticalRecoverySnapshot(stage: .printStatusUnknown)
                    try self.journalCopyIntent(envelope)
                }, selectTransport: { [weak self] envelope, transport in
                    guard let self, self.isCurrentCustomerSession(sessionGeneration) else {
                        throw PrintCheckpointError.persistenceFailed("Customer session changed before printing.")
                    }
                    do {
                        try self.printOutbox?.selectTransportBeforeBytes(
                            batchID: envelope.batchID.uuidString.lowercased(),
                            copyIndex: envelope.copyIndex,
                            transport: transport
                        )
                    } catch {
                        guard self.isPaidSession else { return }
                        throw PrintCheckpointError.persistenceFailed(error.localizedDescription)
                    }
                })
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
            passport: committedGallerySession?.passport,
            receiptPrintOptions: sessionPrintOptions,
            galleryReceiptStyle: sessionGalleryReceiptStyle,
            checkpointID: UUID().uuidString,
            originalCaptureData: originalCaptureBytes.isEmpty ? nil : capturedPhotos.indices.map { originalCaptureBytes[$0] }
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
            photoThumbnailData: [],
            eventRunID: sessionRunID,
            eventDesignID: environment.recordsCustomerSessionMetrics ? EventDesignLibraryStore.shared.library.appliedEventID : nil
        )
        archiveCommitPayload = payload
        let archiveDirectory = environment.archiveDirectory
        let originalData = committedSession.photos.indices.compactMap { originalCaptureBytes[$0] }
        let retainsOriginals = !environment.isQualification && SessionMediaExport.keepsOriginals && originalData.count == committedSession.photos.count
        archiveCommitTask = Task.detached(priority: .userInitiated) {
            do {
                let store = try BoothSessionEnvironment.makeArchiveStore(directory: archiveDirectory)
                try SessionArchiveCommitter.commitPrintPayload(payload, store: store)
            } catch {
                BoothDiagnostics.archive.error("Archive commit failed session=\(committedSession.sessionIdentifier, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                return error.localizedDescription
            }
            // Thumbnails are display-only and never delay printing.
            Task.detached(priority: .utility) {
                // Never fall back to the production archive if a diagnostic store cannot open.
                guard let store = try? BoothSessionEnvironment.makeArchiveStore(directory: archiveDirectory) else { return }
                SessionArchiveCommitter.attachThumbnails(for: committedSession, store: store)
                if retainsOriginals {
                    do { try store.attachOriginalPhotos(archiveID: committedSession.galleryToken, sessionID: committedSession.sessionIdentifier, photos: originalData) }
                    catch {
                        // A media export failure never blocks an already durable receipt or print.
                        await MainActor.run {
                            UserDefaults.standard.set(true, forKey: SessionMediaExport.retentionErrorKey)
                            NotificationCenter.default.post(name: .originalPhotoRetentionFailed, object: nil)
                        }
                    }
                }
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
        let archiveDirectory = environment.archiveDirectory
        let originals = payload.committedSession.photos.indices.compactMap { originalCaptureBytes[$0] }
        let retainsOriginals = !environment.isQualification && SessionMediaExport.keepsOriginals && originals.count == payload.committedSession.photos.count
        let retry = Task.detached(priority: .userInitiated) { () -> String? in
            do {
                let store = try BoothSessionEnvironment.makeArchiveStore(directory: archiveDirectory)
                try SessionArchiveCommitter.commitPrintPayload(payload, store: store)
                Task.detached(priority: .utility) {
                    SessionArchiveCommitter.attachThumbnails(for: payload.committedSession, store: store)
                    if retainsOriginals {
                        do { try store.attachOriginalPhotos(archiveID: payload.committedSession.galleryToken, sessionID: payload.committedSession.sessionIdentifier, photos: originals) }
                        catch {
                            await MainActor.run {
                                UserDefaults.standard.set(true, forKey: SessionMediaExport.retentionErrorKey)
                                NotificationCenter.default.post(name: .originalPhotoRetentionFailed, object: nil)
                            }
                        }
                    }

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

    nonisolated static func shareFriendlyGalleryReceiptImage(for session: CommittedGallerySession,
        photoQualityProfile: PocketPixelsThermalPhotoProfile) throws -> UIImage? {
        guard session.printOptions.includesPrintedGalleryQR else { return nil }
        var publicSession = session
        publicSession.printOptions = ReceiptPrintOptions(footerStyle: .decorativeBarcodeOnly)
        let receipt = try ReceiptComposer.compose(photos: publicSession.photos,
            sessionIdentifier: publicSession.sessionIdentifier, date: publicSession.createdAt,
            galleryURL: publicSession.galleryURL, format: publicSession.format,
            eventProfile: publicSession.eventProfile, passport: publicSession.passport?.redactedForGallery(),
            photoQualityProfile: photoQualityProfile, printOptions: publicSession.printOptions,
            stickers: publicSession.stickers)
        guard let image = UIImage(data: receipt.imagePNGData) else { throw ReceiptComposerError.renderFailed }
        return image
    }

    private func startGalleryUpload(committedSession: CommittedGallerySession, receiptImage: UIImage) {
        // Qualification sessions never prepare, queue or upload a gallery.
        guard environment.deliversGallery else {
            setUploadPhase(.idle, message: "Diagnostic session: gallery delivery is disabled.", for: committedSession.galleryToken)
            return
        }
        guard GalleryUploadSessionIsolationPolicy.canStartPreparation(
            activeTaskTokens: Set(galleryUploadTasks.keys),
            newGalleryToken: committedSession.galleryToken
        ) else {
            return
        }
        if environment.recordsCustomerSessionMetrics {
            eventRunStore?.updateSession(id: committedSession.sessionIdentifier) { if $0.galleryPreparedAt == nil { $0.galleryPreparedAt = Date() } }
        }
        let frozenPhotoProfile = customerPrintPhotoProfile
        setUploadPhase(.preparing, message: "Preparing your gallery...", for: committedSession.galleryToken)
        galleryUploadTasks[committedSession.galleryToken] = Task {
            defer {
                galleryUploadTasks[committedSession.galleryToken] = nil
            }
            do {
                let shareReceipt = try await Task.detached(priority: .userInitiated) {
                    try Self.shareFriendlyGalleryReceiptImage(for: committedSession, photoQualityProfile: frozenPhotoProfile)
                }.value
                let payload = try await uploadService.prepareAndPersistGallery(
                    photos: committedSession.photos,
                    composedReceipt: receiptImage,
                    sessionID: committedSession.sessionIdentifier,
                    createdAt: committedSession.createdAt,
                    galleryToken: committedSession.galleryToken,
                    frozenGalleryURL: committedSession.galleryURL,
                    shareFriendlyReceipt: shareReceipt,
                    receiptVariants: GalleryReceiptVariants(originalFooterStyle: committedSession.printOptions.footerStyle, defaultStyle: committedSession.galleryReceiptStyle)
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
    /// Frozen physical-print choices. Gallery delivery and the iPad QR remain independent.
    var printOptions: ReceiptPrintOptions = .default
    var galleryReceiptStyle: GalleryReceiptStyle = .shareFriendly
    /// Guest stickers frozen on Done (empty for Skip or when Sticker Studio is off). Every
    /// rebuild, copy and the gallery receipt draw these exact pixels.
    var stickers: [FrozenStickerDecoration] = []
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
