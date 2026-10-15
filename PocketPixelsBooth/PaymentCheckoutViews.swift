import SwiftUI
import UIKit

struct CheckoutCopySelectionView: View {
    @ObservedObject var viewModel: BoothSessionViewModel

    private var continueTitle: String {
        switch viewModel.soleOfferedPaymentMethod {
        case .qrPh?: "Continue to QR Ph Payment"
        case .cash?: "Continue to Cash Payment"
        case nil: "Continue to Payment"
        }
    }

    @State private var showingCancel = false
    @ScaledMetric(relativeTo: .largeTitle) private var headingSize = 54.0
    @ScaledMetric(relativeTo: .title) private var amountSize = 48.0

    var body: some View {
        GeometryReader { proxy in
            let compact = proxy.size.height < 900
            ScrollView {
                VStack(spacing: compact ? 20 : 32) {
                    HStack {
                        Button { viewModel.backToFormatSelection() } label: {
                            Label("Back", systemImage: "chevron.left").frame(minWidth: 72, minHeight: 48)
                        }
                        Spacer()
                        MadeToKeepLockup(scale: .compact)
                        Spacer()
                        Button("Cancel") { showingCancel = true }
                            .frame(minWidth: 72, minHeight: 48)
                    }
                    .buttonStyle(.plain)
                    .disabled(!viewModel.canLeaveCopySelection)

                    Spacer(minLength: compact ? 0 : 24)
                    VStack(spacing: compact ? 18 : 28) {
                        Text("Choose your copies")
                            .font(MadeToKeepTheme.Typography.serif(size: headingSize * (compact ? 0.85 : 1)))
                            .accessibilityAddTraits(.isHeader)
                        Text("Every copy is the same complete keepsake from one photo session.")
                            .font(MadeToKeepTheme.Typography.body())
                            .foregroundStyle(MadeToKeepTheme.ColorPalette.mutedInk)
                        CheckoutNoticeView(message: viewModel.paymentNotice)
                        HStack(spacing: 32) {
                            quantityButton("minus", label: "Fewer copies", enabled: viewModel.selectedCheckoutCopies > 1) {
                                viewModel.adjustCheckoutCopies(by: -1)
                            }
                            VStack(spacing: 4) {
                                Text(viewModel.selectedCheckoutCopies, format: .number)
                                    .font(MadeToKeepTheme.Typography.serif(size: amountSize))
                                    .monospacedDigit()
                                Text(viewModel.selectedCheckoutCopies == 1 ? "copy" : "copies")
                                    .font(.body)
                            }
                            .frame(minWidth: 80)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("Physical copies")
                            .accessibilityValue("\(viewModel.selectedCheckoutCopies)")
                            .accessibilityAdjustableAction { direction in
                                if direction == .increment { viewModel.adjustCheckoutCopies(by: 1) }
                                if direction == .decrement { viewModel.adjustCheckoutCopies(by: -1) }
                            }
                            quantityButton("plus", label: "More copies", enabled: viewModel.selectedCheckoutCopies < viewModel.commercialEvent.activePolicy.maxCopies) {
                                viewModel.adjustCheckoutCopies(by: 1)
                            }
                        }
                        .padding(20)
                        .background(.white.opacity(0.5), in: RoundedRectangle(cornerRadius: 18))
                        .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(MadeToKeepTheme.ColorPalette.hairline) }

                        if let total = viewModel.commercialEvent.activePolicy.totalCentavos(for: viewModel.selectedCheckoutCopies) {
                            VStack(spacing: 8) {
                                Text("\(PHPPriceFormatter.string(centavos: viewModel.commercialEvent.activePolicy.unitPriceCentavos)) per copy")
                                    .font(.body)
                                Text(PHPPriceFormatter.string(centavos: total))
                                    .font(MadeToKeepTheme.Typography.serif(size: amountSize))
                                Text("TOTAL").font(.caption).tracking(3)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: compact ? 0 : 24)
                    VStack(spacing: 12) {
                        Button(continueTitle) { viewModel.confirmCopySelection() }
                            .buttonStyle(MadeToKeepPrimaryButtonStyle())
                            .disabled(!viewModel.canLeaveCopySelection)
                        Text("Your photos begin after payment confirmation.")
                            .font(.footnote)
                            .foregroundStyle(MadeToKeepTheme.ColorPalette.mutedInk)
                    }
                }
                .multilineTextAlignment(.center)
                .foregroundStyle(MadeToKeepTheme.ColorPalette.burgundy)
                .frame(maxWidth: 620)
                .padding(24)
                .frame(maxWidth: .infinity)
                .frame(minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .confirmationDialog("Cancel this session?", isPresented: $showingCancel, titleVisibility: .visible) {
            Button("Return to Welcome", role: .destructive) { viewModel.cancelSession() }
            Button("Keep Session", role: .cancel) { }
        } message: {
            Text("No payment has started. Pending galleries from earlier sessions stay safely queued.")
        }
    }

    private func quantityButton(_ symbol: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.title2).frame(width: 60, height: 60)
                .background(MadeToKeepTheme.ColorPalette.burgundy.opacity(0.06), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .disabled(!enabled || !viewModel.canLeaveCopySelection)
        .opacity(enabled ? 1 : 0.3)
    }
}

/// Shared safe-area layout for the two screens before payment confirmation.
private struct CheckoutNavigationLayout<Content: View>: View {
    @ObservedObject var viewModel: BoothSessionViewModel
    @ViewBuilder let content: Content
    @State private var showingCancel = false

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 24) {
                    HStack {
                        Button { viewModel.backFromPaymentSelection() } label: {
                            Label("Back", systemImage: "chevron.left")
                                .frame(minWidth: 72, minHeight: 48)
                        }
                        Spacer()
                        MadeToKeepLockup(scale: .compact)
                        Spacer()
                        Button("Cancel") { showingCancel = true }
                            .frame(minWidth: 72, minHeight: 48)
                    }
                    .buttonStyle(.plain)
                    .disabled(!viewModel.canLeavePaymentSelection)
                    Spacer(minLength: 0)
                    content
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    // Balance the header so the payment content sits in the viewport's center.
                    Color.clear.frame(height: 48).accessibilityHidden(true)
                }
                .multilineTextAlignment(.center)
                .foregroundStyle(MadeToKeepTheme.ColorPalette.burgundy)
                .frame(maxWidth: 620)
                .padding(24)
                .frame(maxWidth: .infinity)
                .frame(minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .confirmationDialog("Cancel this session?", isPresented: $showingCancel, titleVisibility: .visible) {
            Button("Return to Welcome", role: .destructive) { viewModel.cancelSession() }
            Button("Keep Session", role: .cancel) { }
        } message: {
            Text("Payment has not been confirmed on this iPad. If you have handed over cash, please ask the attendant for help before leaving.")
        }
    }
}

struct CheckoutPaymentMethodView: View {
    @ObservedObject var viewModel: BoothSessionViewModel
    @ObservedObject private var operations = EventOperationalState.shared
    @ScaledMetric(relativeTo: .largeTitle) private var headingSize = 48.0

    var body: some View {
        CheckoutNavigationLayout(viewModel: viewModel) {
            VStack(spacing: 24) {
                Text("How would you like to pay?")
                    .font(MadeToKeepTheme.Typography.serif(size: headingSize))
                    .accessibilityAddTraits(.isHeader)
                if let total = viewModel.commercialEvent.activePolicy.totalCentavos(for: viewModel.selectedCheckoutCopies) {
                    Text("Total: \(PHPPriceFormatter.string(centavos: total))")
                        .font(MadeToKeepTheme.Typography.serif(size: 32))
                }
                CheckoutNoticeView(message: viewModel.paymentNotice)
                if viewModel.commercialEvent.activePolicy.qrPhEnabled {
                    Button { viewModel.chooseQRPh() } label: {
                        Label("Pay with QR Ph", systemImage: "qrcode")
                            .frame(maxWidth: .infinity, minHeight: 48)
                    }
                    .buttonStyle(MadeToKeepPrimaryButtonStyle())
                    .disabled(!viewModel.canChooseQRPh || viewModel.isCheckoutTransitionActive)
                    if operations.networkPathStatus != "Online" {
                        Text("QR Ph is unavailable while this iPad is offline. A pending QR payment is never switched to cash automatically.")
                            .font(.callout)
                            .foregroundStyle(MadeToKeepTheme.ColorPalette.mutedInk)
                    }
                }
                if viewModel.policyAuthority.isOfflineCashOnly {
                    Text("This iPad is offline. Cash is available under the event's signed offline policy.")
                        .font(.callout)
                        .foregroundStyle(MadeToKeepTheme.ColorPalette.mutedInk)
                }
                if viewModel.commercialEvent.activePolicy.cashEnabled && viewModel.canChooseCash {
                    Button { viewModel.chooseCash() } label: {
                        Label("Pay Cash to the Attendant", systemImage: "banknote")
                            .frame(maxWidth: .infinity, minHeight: 48)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(viewModel.isCheckoutTransitionActive)
                }
            }
        }
    }
}

/// Online cash is customer-declared; signed offline cash keeps attendant authentication.
struct CashAttestationView: View {
    @ObservedObject var viewModel: BoothSessionViewModel
    @ScaledMetric(relativeTo: .largeTitle) private var headingSize = 48.0
    @ScaledMetric(relativeTo: .title) private var amountSize = 48.0

    var body: some View {
        CheckoutNavigationLayout(viewModel: viewModel) {
            VStack(spacing: 24) {
                Image(systemName: "banknote")
                    .font(.system(size: 40))
                    .accessibilityHidden(true)
                Text("Please pay the attendant")
                    .font(MadeToKeepTheme.Typography.serif(size: headingSize))
                    .accessibilityAddTraits(.isHeader)
                if let total = viewModel.commercialEvent.activePolicy.totalCentavos(for: viewModel.selectedCheckoutCopies) {
                    VStack(spacing: 6) {
                        Text(PHPPriceFormatter.string(centavos: total))
                            .font(MadeToKeepTheme.Typography.serif(size: amountSize))
                        Text("\(viewModel.selectedCheckoutCopies) \(viewModel.selectedCheckoutCopies == 1 ? "copy" : "copies") · cash")
                            .font(.headline)
                    }
                    .accessibilityElement(children: .combine)
                }
                Text(viewModel.policyAuthority.isOfflineCashOnly
                     ? "Hand your cash to the attendant. They will confirm on this iPad."
                     : "Hand your cash to the attendant, then tap below to start your photos.")
                    .font(MadeToKeepTheme.Typography.body())
                CheckoutNoticeView(message: viewModel.paymentNotice)
                VStack(spacing: 12) {
                    Button {
                        if viewModel.policyAuthority.isOfflineCashOnly {
                            viewModel.confirmCashReceivedByAttendant()
                        } else {
                            viewModel.declareCashPaidByGuest()
                        }
                    } label: {
                        Label(viewModel.isCheckoutTransitionActive ? "Starting…" : (viewModel.policyAuthority.isOfflineCashOnly ? "Attendant: Confirm Cash Received" : "I’ve paid the attendant"), systemImage: "checkmark.circle")
                            .frame(maxWidth: .infinity, minHeight: 48)
                    }
                    .buttonStyle(MadeToKeepPrimaryButtonStyle())
                    .disabled(viewModel.isCheckoutTransitionActive)
                    .accessibilityHint(viewModel.policyAuthority.isOfflineCashOnly ? "Requires attendant Face ID or the iPad passcode." : "Starts your photos after you declare your cash payment.")
                    Text(viewModel.policyAuthority.isOfflineCashOnly
                         ? "Requires attendant Face ID or the iPad passcode."
                         : "Tap only after handing over the full amount.")
                        .font(.footnote)
                        .foregroundStyle(MadeToKeepTheme.ColorPalette.mutedInk)
                }
                if viewModel.canLeaveCashPayment {
                    Button("Pay with QR Ph instead") { viewModel.leaveCashPayment() }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                }
            }
        }
    }
}

struct QRPhPaymentView: View {
    @ObservedObject var viewModel: BoothSessionViewModel
    @Environment(\.openURL) private var openURL
    @State private var isShowingTestSimulatorConfirmation = false

    var body: some View {
        QRPhPaymentContent(
            totalCentavos: viewModel.commercialEvent.activePolicy.totalCentavos(for: viewModel.selectedCheckoutCopies),
            copies: viewModel.selectedCheckoutCopies,
            image: qrImage,
            hasImagePayload: viewModel.paymentAttempt?.qrImageDataURL != nil,
            expiresAt: viewModel.paymentAttempt?.expiresAt,
            onTitleLongPress: {
                guard testSimulatorURL != nil else { return }
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                isShowingTestSimulatorConfirmation = true
            }
        )
        .confirmationDialog(
            "Open PayMongo TEST simulator?",
            isPresented: $isShowingTestSimulatorConfirmation,
            titleVisibility: .visible
        ) {
            if let testSimulatorURL {
                Button("Open TEST Simulator") {
                    openURL(testSimulatorURL)
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Operator testing only. Opening the simulator does not prove payment or unlock the camera; the server must still verify the Payment Intent.")
        }
    }

    private var testSimulatorURL: URL? {
        guard let environment = PaymentsConfiguration.current()?.environment else { return nil }
        return viewModel.paymentAttempt?.testSimulatorURL(environment: environment)
    }

    private var qrImage: UIImage? {
        guard let raw = viewModel.paymentAttempt?.qrImageDataURL,
              let comma = raw.firstIndex(of: ","),
              let data = Data(base64Encoded: String(raw[raw.index(after: comma)...])) else {
            return nil
        }
        return UIImage(data: data)
    }
}

/// Presentation only: payment creation, polling and entitlement stay with the session model.
/// Value inputs also let UI tests render fixtures without starting a checkout or camera.
struct QRPhPaymentContent: View {
    let totalCentavos: Int?
    let copies: Int
    let image: UIImage?
    let hasImagePayload: Bool
    let expiresAt: Date?
    var onTitleLongPress: () -> Void = { }

    @ScaledMetric(relativeTo: .largeTitle) private var headingSize = 56.0
    @ScaledMetric(relativeTo: .title) private var amountSize = 40.0
    @ScaledMetric(relativeTo: .caption) private var labelSize = 12.0

    private let ink = MadeToKeepTheme.ColorPalette.burgundy
    private let mutedInk = MadeToKeepTheme.ColorPalette.mutedInk

    var body: some View {
        GeometryReader { proxy in
            // Geometry is the safe-area viewport. The inner column is bounded, while the
            // outer frame fills both axes; overflowing content grows and scrolls naturally.
            let compact = proxy.size.height < 900
            let inset: CGFloat = 24
            let qrSide = max(1, min(compact ? 300 : 360, proxy.size.width - inset * 2 - 40))
            ScrollView {
                VStack(spacing: compact ? 10 : 26) {
                    VStack(spacing: compact ? 10 : 24) {
                        MadeToKeepLockup(scale: .compact)
                        MadeToKeepEditorialHeader(eyebrow: "PAYMENT", title: "Scan to Pay", titleSize: headingSize * (compact ? 0.79 : 1))
                            .onLongPressGesture(minimumDuration: 2, perform: onTitleLongPress)
                    }

                    VStack(spacing: 6) {
                        if let totalCentavos {
                            Text(PHPPriceFormatter.string(centavos: totalCentavos))
                                .font(MadeToKeepTheme.Typography.serif(size: amountSize * (compact ? 0.85 : 1)))
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityLabel("Total to pay")
                                .accessibilityValue(PHPPriceFormatter.string(centavos: totalCentavos))
                        }
                        MadeToKeepLabel(text: "\(copies) \(copies == 1 ? "KEEPSAKE COPY" : "KEEPSAKE COPIES")", size: labelSize)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    qrCenterpiece(side: qrSide)

                    VStack(spacing: compact ? 8 : 12) {
                        Text("Scan using your preferred QR Ph-supported payment app.")
                            .font(MadeToKeepTheme.Typography.body())
                        HStack(spacing: 8) {
                            ProgressView()
                                .tint(ink)
                                .accessibilityHidden(true)
                            Text("Waiting for payment confirmation")
                                .font(MadeToKeepTheme.Typography.body(.callout))
                        }
                        Text("Keep this screen open. Your camera opens after automatic payment verification. Screenshots or payment-app callbacks cannot start your session.")
                            .font(MadeToKeepTheme.Typography.body(.footnote))
                            .foregroundStyle(mutedInk)
                    }
                    .fixedSize(horizontal: false, vertical: true)

                    if let expiresAt {
                        VStack(spacing: 6) {
                            MadeToKeepLabel(text: "TIME REMAINING", size: labelSize, color: mutedInk)
                            Text(expiresAt, style: .timer)
                                .font(MadeToKeepTheme.Typography.body(.callout).monospacedDigit())
                                .accessibilityLabel("QR code time remaining")
                                .accessibilityAddTraits(.updatesFrequently)
                        }
                    }
                }
                .foregroundStyle(ink)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 560)
                .padding(.horizontal, inset)
                .padding(.vertical, compact ? 16 : inset)
                .frame(maxWidth: .infinity)
                .frame(minHeight: proxy.size.height, alignment: .center)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private func qrCenterpiece(side: CGFloat) -> some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: side, height: side)
                    .accessibilityLabel("QR Ph payment code")
            } else {
                VStack(spacing: 12) {
                    if hasImagePayload {
                        Image(systemName: "exclamationmark.circle")
                            .font(.title2)
                            .accessibilityHidden(true)
                        Text("QR code unavailable")
                        Text("Please ask the attendant for help. Keep this screen open while we check your payment. Do not pay again.")
                            .font(MadeToKeepTheme.Typography.body(.footnote))
                    } else {
                        ProgressView()
                            .tint(ink)
                            .accessibilityHidden(true)
                        Text("Preparing your QR Ph code")
                    }
                }
                .font(MadeToKeepTheme.Typography.body(.callout))
                .foregroundStyle(mutedInk)
                .padding(16)
            }
        }
        // Reserve the same square for loading and ready. Fit preserves the complete provider
        // image (including non-square payloads); the white margin never overlays QR pixels.
        .frame(width: side)
        .frame(minHeight: side)
        .padding(20)
        .background(Color.white)
        .overlay {
            Rectangle().strokeBorder(MadeToKeepTheme.ColorPalette.hairline, lineWidth: 0.5)
        }
    }
}

struct PaymentReconciliationView: View {
    @ObservedObject var viewModel: BoothSessionViewModel

    private var message: String { viewModel.statusMessage }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                ProgressView()
                    .controlSize(.large)
                Text("Checking payment")
                    .font(.largeTitle.bold())
                    .accessibilityAddTraits(.isHeader)
                Text(message)
                    .font(.title3)
                    .multilineTextAlignment(.center)
                if viewModel.canStartNewCheckout {
                    Button("Start a New Checkout") {
                        viewModel.startNewCheckout()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .accessibilityHint("Starts a new payment. The previous QR code can no longer be paid.")
                } else {
                    Text("Do not make a second payment while this status is unknown.")
                        .font(.headline)
                        .foregroundStyle(.red)
                }
            }
            .frame(maxWidth: 620)
            .padding(40)
        }
    }
}

/// Short guest-facing notice, for example after a price update or a QR that could not start.
struct CheckoutNoticeView: View {
    let message: String?

    var body: some View {
        if let message {
            Label(message, systemImage: "info.circle")
                .font(.callout)
                .multilineTextAlignment(.leading)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                .accessibilityElement(children: .combine)
        }
    }
}
