import SwiftUI
import UIKit

struct CheckoutCopySelectionView: View {
    @ObservedObject var viewModel: BoothSessionViewModel

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Text("Choose your copies")
                    .font(.largeTitle.bold())
                    .accessibilityAddTraits(.isHeader)
                Text("Every copy is the same complete keepsake from one photo session.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                CheckoutNoticeView(message: viewModel.paymentNotice)

                Stepper(
                    value: $viewModel.selectedCheckoutCopies,
                    in: 1...viewModel.commercialEvent.activePolicy.maxCopies
                ) {
                    LabeledContent("Physical copies") {
                        Text(viewModel.selectedCheckoutCopies, format: .number)
                            .font(.title2.bold())
                    }
                }
                .accessibilityValue("\(viewModel.selectedCheckoutCopies) physical copies")

                if let total = viewModel.commercialEvent.activePolicy.totalCentavos(for: viewModel.selectedCheckoutCopies) {
                    VStack(spacing: 8) {
                        Text("\(PHPPriceFormatter.string(centavos: viewModel.commercialEvent.activePolicy.unitPriceCentavos)) × \(viewModel.selectedCheckoutCopies)")
                            .font(.headline)
                        Text(PHPPriceFormatter.string(centavos: total))
                            .font(.largeTitle.bold())
                        Text("Total")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }

                Button("Continue to Payment") {
                    viewModel.confirmCopySelection()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .frame(maxWidth: 560)
            .padding(40)
        }
    }
}

struct CheckoutPaymentMethodView: View {
    @ObservedObject var viewModel: BoothSessionViewModel
    @ObservedObject private var operations = EventOperationalState.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Text("How would you like to pay?")
                    .font(.largeTitle.bold())
                    .accessibilityAddTraits(.isHeader)

                if let total = viewModel.commercialEvent.activePolicy.totalCentavos(for: viewModel.selectedCheckoutCopies) {
                    Text("Total: \(PHPPriceFormatter.string(centavos: total))")
                        .font(.title2)
                }
                CheckoutNoticeView(message: viewModel.paymentNotice)

                if viewModel.commercialEvent.activePolicy.qrPhEnabled {
                    Button {
                        viewModel.chooseQRPh()
                    } label: {
                        Label("Pay with QR Ph", systemImage: "qrcode")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!viewModel.canChooseQRPh)
                    if operations.networkPathStatus != "Online" {
                        Text("QR Ph is unavailable while this iPad is offline. A pending QR payment is never switched to cash automatically.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                if viewModel.policyAuthority.isOfflineCashOnly {
                    Text("This iPad is offline. Cash is available under the event's signed offline policy.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                if viewModel.commercialEvent.activePolicy.cashEnabled && viewModel.canChooseCash {
                    Button {
                        viewModel.chooseCash()
                    } label: {
                        Label("Pay Cash", systemImage: "banknote")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
            }
            .frame(maxWidth: 560)
            .padding(40)
        }
    }
}

struct CashAttestationView: View {
    @ObservedObject var viewModel: BoothSessionViewModel

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Image(systemName: "banknote")
                    .font(.largeTitle)
                    .accessibilityHidden(true)
                Text("Cash Payment")
                    .font(.largeTitle.bold())
                    .accessibilityAddTraits(.isHeader)
                if let total = viewModel.commercialEvent.activePolicy.totalCentavos(for: viewModel.selectedCheckoutCopies) {
                    Text("Pay \(PHPPriceFormatter.string(centavos: total)) in cash to our attendant. Tap “I’ve Paid” after handing over your payment.")
                        .font(.title3)
                        .multilineTextAlignment(.center)
                }
                Text("Cash is self-reported by your tap. The system does not independently verify that cash was received.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("I’ve Paid") {
                    viewModel.declareCashPaid()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .frame(maxWidth: 620)
            .padding(40)
        }
    }
}

struct QRPhPaymentView: View {
    @ObservedObject var viewModel: BoothSessionViewModel
    @Environment(\.openURL) private var openURL
    @State private var isShowingTestSimulatorConfirmation = false

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Text("Scan to Pay")
                    .font(.largeTitle.bold())
                    .accessibilityAddTraits(.isHeader)
                    .onLongPressGesture(minimumDuration: 2) {
                        guard testSimulatorURL != nil else { return }
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        isShowingTestSimulatorConfirmation = true
                    }
                if let total = viewModel.commercialEvent.activePolicy.totalCentavos(for: viewModel.selectedCheckoutCopies) {
                    Text("Scan to pay \(PHPPriceFormatter.string(centavos: total)) using a QR Ph-supported app. Your session will begin when payment is confirmed.")
                        .font(.title3)
                        .multilineTextAlignment(.center)
                }
                if let image = qrImage {
                    Image(uiImage: image)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 420)
                        .accessibilityLabel("QR Ph payment code")
                } else {
                    ProgressView("Preparing QR Ph code")
                }
                Text("Keep this screen open. A screenshot or app callback cannot unlock the camera.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if let expiry = viewModel.paymentAttempt?.expiresAt {
                    Text(expiry, style: .timer)
                        .font(.headline.monospacedDigit())
                        .accessibilityLabel("QR code time remaining")
                        .accessibilityAddTraits(.updatesFrequently)
                }
            }
            .frame(maxWidth: 660)
            .padding(40)
        }
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
