import SwiftUI
import PhotosUI

struct ManualPolicyEditor: View {
    @ObservedObject private var store = ManualPaymentStore.shared
    @Binding var policy: ManualPaymentPolicy?
    private var value: Binding<ManualPaymentPolicy> { Binding(get: { policy ?? .init() }, set: { policy = $0 }) }
    var body: some View {
        Picker("Payment mode", selection: value.mode) { ForEach(ManualPaymentMode.allCases) { Text($0.title).tag($0).disabled($0.acceptsDigital && store.receiver?.isReady != true) } }
            .accessibilityIdentifier("manual-payment-mode")
        if value.wrappedValue.mode != .none {
            TextField("Price per copy (PHP)", text: Binding(get: { PesoAmount.editingText(centavos: value.wrappedValue.unitPriceCentavos) }, set: { value.wrappedValue.unitPriceCentavos = PesoAmount.centavos(fromPesoText: $0) ?? 0 }))
                .keyboardType(.decimalPad).accessibilityIdentifier("manual-payment-price")
            if value.wrappedValue.mode.acceptsDigital {
                Picker("Payment receipt", selection: value.receiptPolicy) { ForEach(PaymentReceiptPolicy.allCases) { Text($0.title).tag($0) } }
                NavigationLink("Receiving Account & Authorized QR") { ManualReceivingAccountView() }
                Text(ManualPaymentStore.shared.receiver?.isReady == true ? "Guests pay using the receiving QR or account details on the iPad. Optional and required receipts are submitted in a separate step. Review funds independently after the session." : "Digital payments are disabled until a permitted receiving account is configured and enabled.")
                    .font(.footnote).foregroundStyle(OperatorPalette.secondaryText)
            }
            if let issue = value.wrappedValue.validationMessage { Text(issue).foregroundStyle(OperatorPalette.danger) }
        }
    }
}

struct ManualReceivingAccountView: View {
    @ObservedObject private var store = ManualPaymentStore.shared
    @State private var account = ManualPaymentStore.shared.receiver ?? ManualReceivingAccount()
    @State private var image: PhotosPickerItem?
    @State private var message = ""
    @State private var busy = false
    @State private var retention = ""
    @State private var confirmsRetention = false
    var body: some View {
        Form {
            Section("Receiving account") {
                TextField("Provider or account label", text: $account.provider)
                TextField("Recipient name", text: $account.recipient)
                TextField("Account identifier or number", text: $account.identifier)
                TextField("Payment instructions", text: $account.instructions, axis: .vertical)
                PhotosPicker("Choose Authorized Receiving QR", selection: $image, matching: .images)
                if let data = account.qrJPEG, let qr = UIImage(data: data) {
                    Image(uiImage: qr).resizable().scaledToFit().frame(maxHeight: 220)
                    Button("Remove receiving QR", role: .destructive) { account.qrJPEG = nil }
                }
                Toggle("This account is permitted for this activity", isOn: $account.permittedUseConfirmed)
                Toggle("Enable digital payments", isOn: $account.enabled)
                Text("Use an account and QR authorized for the intended activity. Manual acknowledgment does not bypass account/provider requirements. Details are stored privately on this iPad and disclosed only to this guest's checkout.")
                    .font(.footnote).foregroundStyle(OperatorPalette.secondaryText)
            }
            Section {
                Button("Save Receiving Account") {
                    do { try store.saveReceiver(account); account = store.receiver!; message = "Saved for future checkouts. Existing guests retain their original receiving account." }
                    catch { message = error.localizedDescription }
                }.disabled(busy)
                Button("Sync Private Mobile Checkout Configuration") {
                    busy = true
                    Task {
                        defer { busy = false }
                        do {
                            guard let account = store.receiver, let configuration = PaymentsConfiguration.current() else { throw SetupFailure("Save the receiver and pair this iPad in Payment Maintenance first.") }
                            try await PaymentsAPIClient(configuration: configuration).registerManualReceiver(account)
                            message = "Receiving-account revision synchronized. This does not verify a payment."
                        } catch { message = "Local configuration is retained. Mobile service configuration is pending: \(error.localizedDescription)" }
                    }
                }.disabled(busy || store.receiver == nil)
                if !message.isEmpty { Text(message).font(.callout) }
            }
            Section("Private receipt retention") {
                Text("No automatic cleanup runs. Establish a reviewed period before manually moving eligible receipts to recoverable Drive Trash. Payment records and storage proofs remain.").font(.footnote)
                LabeledContent("Established period", value: store.retentionDays.map { "\($0) days" } ?? "Not established")
                TextField("Reviewed retention period in days", text: $retention).keyboardType(.numberPad)
                Button("Establish Reviewed Retention Policy") { confirmsRetention = true }.disabled(busy)
            }
        }.operatorScreen().navigationTitle("Receiving Account")
        .confirmationDialog("Establish this receipt retention period?", isPresented: $confirmsRetention, titleVisibility: .visible) {
            Button("Establish Reviewed Period") {
                Task { do {
                    guard OperatorAccessPermit.shared.isAuthorized, let days = Int(retention), (1...3650).contains(days), let config = PaymentsConfiguration.current() else { throw SetupFailure("Unlock Operator, pair the service and enter 1–3650 days.") }
                    try await PaymentsAPIClient(configuration: config).establishManualRetention(days: days)
                    try store.setRetentionDays(days); message = "Retention established. No files were deleted and no automatic cleanup was enabled."
                } catch { message = error.localizedDescription } }
            }
        } message: { Text("This period controls eligibility for individual, explicitly confirmed Trash actions. Confirm your business retention requirements before establishing it.") }
        .onChange(of: image) { _, item in
            Task {
                guard let data = try? await item?.loadTransferable(type: Data.self), let image = UIImage(data: data) else { return }
                let scale = min(1, 800 / max(image.size.width, image.size.height))
                let format = UIGraphicsImageRendererFormat(); format.scale = 1
                let rendered = UIGraphicsImageRenderer(size: CGSize(width: image.size.width * scale, height: image.size.height * scale), format: format).image { _ in image.draw(in: CGRect(x: 0,y: 0,width: image.size.width * scale,height: image.size.height * scale)) }
                guard let encoded = rendered.jpegData(compressionQuality: 0.85), encoded.count <= 262_144 else { message = "Choose a smaller receiving QR image."; return }
                account.qrJPEG = encoded
            }
        }
    }
}

struct ManualDigitalCheckoutView: View {
    @ObservedObject var viewModel: BoothSessionViewModel
    var onHelp: () -> Void
    @State private var showingHelp = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .largeTitle) private var headingSize = 55.0
    @ScaledMetric(relativeTo: .title) private var amountSize = 62.0

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.height < 950
            let codeSize = min(compact ? 252.0 : 304.0, max(100, geometry.size.width - 106))
            ScrollView {
                if let record = viewModel.manualCheckout {
                    VStack(spacing: compact ? 21 : 30) {
                        MadeToKeepLockup(scale: .compact)
                            .padding(.bottom, compact ? 2 : 12)
                        switch viewModel.manualCheckoutStep {
                        case .pay:
                            payment(record, codeSize: codeSize)
                        case .receipt:
                            receipt(record, codeSize: codeSize)
                        case .continuing:
                            MadeToKeepEditorialHeader(eyebrow: nil, title: "Continuing to photos", titleSize: headingSize)
                            checkoutNotice
                            primaryAction("Try again", identifier: "manual-acknowledgment-retry") { viewModel.retryManualAcknowledgment() }
                        case .preparing, .expired:
                            availability
                        }
                        secondaryAction("Need help?", identifier: "manual-checkout-help") { showingHelp = true }
                    }
                    .frame(maxWidth: 580)
                    .padding(.horizontal, 28)
                    .padding(.vertical, compact ? 24 : 38)
                    .frame(maxWidth: .infinity, minHeight: geometry.size.height)
                    .task(id: record.acknowledgmentDeadline) {
                        do {
                            try await Task.sleep(for: .seconds(max(0, record.acknowledgmentDeadline.timeIntervalSinceNow) + 0.1))
                            viewModel.expireManualCheckoutIfNeeded()
                        } catch { }
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .multilineTextAlignment(.center)
        .foregroundStyle(MadeToKeepTheme.ColorPalette.burgundy)
        .tint(MadeToKeepTheme.ColorPalette.burgundy)
        .confirmationDialog("Checkout help", isPresented: $showingHelp, titleVisibility: .visible) {
            Button("Ask the attendant", action: onHelp)
            if viewModel.manualCheckoutStep == .receipt {
                Button("Check receipt status") { Task { await viewModel.refreshManualPayment() } }
            }
            Button("End this checkout", role: .destructive) { viewModel.cancelSession() }
            Button("Keep this checkout open", role: .cancel) { }
        } message: {
            if viewModel.manualCheckout?.acknowledgedAt != nil || viewModel.manualCheckoutStep == .pay || viewModel.manualCheckoutStep == .expired {
                Text("If you’ve already paid, ask the attendant to help with this checkout.")
            }
        }
    }

    private func payment(_ record: ManualCheckoutRecord, codeSize: CGFloat) -> some View {
        VStack(spacing: 21) {
            heading("Pay for your keepsake", record: record, isReceipt: false)
            if let receiver = record.receiver {
                let qr = receiver.qrJPEG.flatMap { UIImage(data: $0) }
                if let qr {
                    checkoutQR(qr, size: codeSize, label: "Receiving-account payment QR", identifier: "manual-payment-qr")
                }
                VStack(spacing: 7) {
                    Text(receiver.recipient)
                        .font(.headline)
                        .foregroundStyle(MadeToKeepTheme.ColorPalette.ink)
                    Text(receiver.provider)
                        .foregroundStyle(MadeToKeepTheme.ColorPalette.mutedInk)
                    if qr == nil {
                        Text(receiver.identifier)
                            .font(.title3.weight(.semibold).monospacedDigit())
                            .textSelection(.enabled)
                            .padding(.vertical, 5)
                    }
                }
                .accessibilityElement(children: .combine)
                VStack(spacing: 4) {
                    Text(qr == nil ? "Use these account details in your payment app and enter the exact amount shown."
                         : "Scan using your payment app and enter the exact amount shown.")
                    if qr == nil, !receiver.instructions.isEmpty,
                       receiver.instructions != ManualReceivingAccount().instructions,
                       receiver.instructions != "Transfer the exact amount, then acknowledge your payment. Please do not pay twice." {
                        Text(receiver.instructions)
                    }
                    if record.policy.receiptPolicy != .acknowledgmentOnly {
                        Text("Save a screenshot of your payment receipt.")
                    }
                }
                .font(.body)
                .foregroundStyle(MadeToKeepTheme.ColorPalette.mutedInk)
                .frame(maxWidth: 430)
            }
            checkoutNotice
            primaryAction("I've paid", identifier: "manual-local-acknowledgment") { viewModel.acknowledgeManualPayment() }
        }
    }

    private func receipt(_ record: ManualCheckoutRecord, codeSize: CGFloat) -> some View {
        VStack(spacing: 21) {
            heading("Upload your receipt", record: record, isReceipt: true)
            if let url = record.receiptSubmissionURL,
               (record.receiptLinkExpiresAt ?? record.createdAt.addingTimeInterval(86400)) > Date(),
               let qr = try? GalleryQRCodeGenerator.makeQRCodeImage(for: url) {
                checkoutQR(qr, size: codeSize, label: "Receipt submission QR", identifier: "manual-receipt-qr")
                Text("Scan with your phone’s camera and upload your payment screenshot.")
                    .font(.body)
                    .foregroundStyle(MadeToKeepTheme.ColorPalette.mutedInk)
                    .frame(maxWidth: 390)
                if viewModel.paymentNotice == nil {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small).accessibilityHidden(true)
                        Text("Waiting for your receipt…").font(.callout.weight(.medium))
                    }
                    .accessibilityIdentifier("manual-receipt-waiting")
                }
            } else if viewModel.paymentNotice == nil {
                ProgressView("Opening receipt upload…")
            }
            checkoutNotice
            if viewModel.paymentNotice != nil {
                secondaryAction("Check again", identifier: "manual-receipt-refresh") {
                    Task { await viewModel.refreshManualPayment() }
                }
                .disabled(viewModel.manualCheckoutIsRefreshing)
            }
            if record.policy.receiptPolicy == .optional {
                Button("Skip for now") { viewModel.skipOptionalManualReceipt() }
                    .buttonStyle(MadeToKeepSecondaryButtonStyle())
                    .accessibilityIdentifier("manual-optional-skip")
            }
        }
    }

    private var availability: some View {
        let title = viewModel.manualCheckoutStep == .expired ? "Checkout expired"
            : viewModel.paymentNotice == nil ? "Getting checkout ready" : "Receipt upload is unavailable"
        return VStack(spacing: 22) {
            MadeToKeepEditorialHeader(eyebrow: nil, title: title, titleSize: headingSize)
            if viewModel.manualCheckoutStep == .preparing {
                if viewModel.paymentNotice == nil {
                    ProgressView("Checking receipt upload…")
                        .accessibilityIdentifier("manual-receipt-readiness")
                } else {
                    checkoutNotice
                    primaryAction("Try again", identifier: "manual-readiness-retry") {
                        Task { await viewModel.refreshManualPayment() }
                    }
                    .disabled(viewModel.manualCheckoutIsRefreshing)
                    if viewModel.canSwitchManualCheckoutToCash {
                        secondaryAction("Pay with cash", identifier: "manual-cash-fallback") { viewModel.switchManualCheckoutToCash() }
                    }
                }
            } else {
                checkoutNotice
            }
        }
        .padding(.vertical, 32)
    }

    private func heading(_ title: String, record: ManualCheckoutRecord, isReceipt: Bool) -> some View {
        VStack(spacing: 9) {
            if record.policy.receiptPolicy != .acknowledgmentOnly {
                HStack(spacing: 11) {
                    Capsule().fill(MadeToKeepTheme.ColorPalette.burgundy).frame(width: 26, height: 2)
                    MadeToKeepLabel(text: isReceipt
                        ? (record.policy.receiptPolicy == .optional ? "2 OF 2 · OPTIONAL" : "2 OF 2 · RECEIPT")
                        : "1 OF 2 · PAYMENT", size: 12)
                    Capsule().fill(isReceipt ? MadeToKeepTheme.ColorPalette.burgundy : MadeToKeepTheme.ColorPalette.hairline)
                        .frame(width: 26, height: 2)
                }
                .animation(reduceMotion ? nil : MadeToKeepTheme.Motion.standardAnimation, value: isReceipt)
            }
            MadeToKeepEditorialHeader(eyebrow: nil, title: title, titleSize: headingSize)
            if isReceipt {
                Text("\(PHPPriceFormatter.string(centavos: record.totalCentavos))  ·  \(copyCount(record.copies))")
                    .font(.body)
                    .foregroundStyle(MadeToKeepTheme.ColorPalette.mutedInk)
            } else {
                Text(PHPPriceFormatter.string(centavos: record.totalCentavos))
                    .font(MadeToKeepTheme.Typography.serif(size: amountSize))
                    .monospacedDigit()
                    .minimumScaleFactor(0.62)
                    .lineLimit(1)
                    .accessibilityLabel("Total \(PHPPriceFormatter.string(centavos: record.totalCentavos))")
                Text(copyCount(record.copies))
                    .font(.body)
                    .foregroundStyle(MadeToKeepTheme.ColorPalette.mutedInk)
            }
        }
    }

    private func copyCount(_ count: Int) -> String { count == 1 ? "1 copy" : "\(count) copies" }

    private func checkoutQR(_ image: UIImage, size: CGFloat, label: String, identifier: String) -> some View {
        Image(uiImage: image)
            .interpolation(.none)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .padding(24)
            .background(.white, in: RoundedRectangle(cornerRadius: 16))
            .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(MadeToKeepTheme.ColorPalette.hairline) }
            .accessibilityLabel(label)
            .accessibilityIdentifier(identifier)
    }

    @ViewBuilder private var checkoutNotice: some View {
        if let notice = viewModel.paymentNotice {
            Text(notice)
                .font(.callout)
                .foregroundStyle(MadeToKeepTheme.ColorPalette.burgundy)
                .frame(maxWidth: 410)
                .accessibilityIdentifier("manual-checkout-notice")
        }
    }

    private func primaryAction(_ title: String, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).frame(maxWidth: .infinity)
        }
        .buttonStyle(MadeToKeepFilledButtonStyle())
        .frame(maxWidth: 340)
        .accessibilityIdentifier(identifier)
    }

    private func secondaryAction(_ title: String, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.callout.weight(.semibold))
                .underline()
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }
}

struct PaymentsOperatorView: View {
    var salesOnly = false
    var allowsEventMaintenance = false
    @ObservedObject private var store = ManualPaymentStore.shared
    var body: some View {
        List {
            Section("Manual payments") {
                if let issue = store.storageError { Text(issue).foregroundStyle(OperatorPalette.danger) }
                LabeledContent("Digital payment", value: store.receiver?.isReady == true ? "Receiving account configured" : "Disabled — receiving account required")
                NavigationLink("Payment Records, Receipts & Review") { ManualPaymentHistoryView() }
                if !salesOnly { NavigationLink("Receiving Account & Authorized QR") { ManualReceivingAccountView() } }
                Text("Acknowledged amounts and independently confirmed funds are separate views of the same payments; do not add them together.").font(.footnote)
            }
            if !salesOnly {
                Section("Session setup") { NavigationLink("Regular Booth", value: OperatorWorkspaceRoute.regularBooth); NavigationLink("Event Setup", value: OperatorWorkspaceRoute.sessionSetup) }
            }
            Section("Historical payments & service connection") {
                NavigationLink("Legacy Records, Recovery & Pairing") { LegacyPaymentsOperatorView(salesOnly: salesOnly, allowsEventMaintenance: allowsEventMaintenance) }
                Text("Historical PayMongo and signed cash records retain their original verification and recovery rules. New QR Ph checkouts are retired.").font(.footnote)
            }
        }.operatorScreen().navigationTitle(salesOnly ? "Payment Reports" : "Payment Maintenance")
    }
}

struct ManualPaymentHistoryView: View {
    @ObservedObject private var store = ManualPaymentStore.shared
    @State private var event = "all"
    @State private var method = "all"
    @State private var verification = "all"
    @State private var exportURL: URL?
    @State private var status = ""
    private var filtered: [ManualCheckoutRecord] { store.records.filter { (event == "all" || $0.eventID == event) && (method == "all" || $0.method == method) && (verification == "all" || $0.verification == verification) }.sorted { $0.createdAt > $1.createdAt } }
    var body: some View {
        List {
            Section("Scope") {
                Picker("Event", selection: $event) { Text("All / Regular Booth").tag("all"); Text("Regular Booth only").tag(""); ForEach(Array(Set(store.records.map(\.eventID))).filter { !$0.isEmpty }.sorted(), id: \.self) { id in Text(store.records.first { $0.eventID == id }?.eventName ?? id).tag(id) } }
                Picker("Method", selection: $method) { Text("All methods").tag("all"); Text("Cash").tag("CASH"); Text("Digital").tag("MANUAL_DIGITAL") }
                Picker("Verification", selection: $verification) { Text("All statuses").tag("all"); Text("Awaiting review").tag("AWAITING_REVIEW"); ForEach(ManualPaymentReview.Outcome.allCases, id: \.self) { Text($0.rawValue).tag($0.rawValue) } }
                LabeledContent("Acknowledged", value: PHPPriceFormatter.string(centavos: filtered.filter { $0.acknowledgedAt != nil }.reduce(0) { $0 + $1.totalCentavos }))
                LabeledContent("Independently confirmed", value: PHPPriceFormatter.string(centavos: filtered.reduce(0) { $0 + ($1.reviews.last?.outcome == .fundsConfirmed ? ($1.reviews.last?.confirmedCentavos ?? 0) : 0) }))
                Text("Overlapping categories; do not add these totals. Cash and digital acknowledgments are guest statements.").font(.footnote)
                Button("Sync Original Records") { Task { await ManualPaymentSync.syncPending(); status = "Synchronization attempted; pending records remain local." } }
                Button("Prepare CSV Export") { do { exportURL = try ManualPaymentCSV.export(filtered) } catch { status = error.localizedDescription } }
                if let exportURL { ShareLink("Share Payment Report", item: exportURL) }
                if !status.isEmpty { Text(status).font(.footnote) }
            }
            Section("Original checkouts") {
                if filtered.isEmpty { Text("No matching payment records.") }
                ForEach(filtered) { record in NavigationLink { ManualPaymentRecordView(id: record.id) } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(record.eventName.isEmpty ? "Regular Booth" : record.eventName).font(.headline)
                        Text("\(record.method == "CASH" ? "Cash" : "Digital") · \(PHPPriceFormatter.string(centavos: record.totalCentavos)) · \(record.copies) copies")
                        Text("\(record.acknowledgedAt == nil ? "Claim pending" : "Acknowledged") · \(record.receipt == nil ? "No receipt" : "Private receipt") · \(record.verification)").font(.caption)
                    }
                } }
            }
        }.operatorScreen().navigationTitle("Payment Records")
        .onDisappear { if let exportURL { try? FileManager.default.removeItem(at: exportURL) }; exportURL = nil }
    }
}

struct ManualPaymentRecordView: View {
    let id: String
    @ObservedObject private var store = ManualPaymentStore.shared
    @State private var note = ""
    @State private var amount = ""
    @State private var message = ""
    @State private var preview: UIImage?
    @State private var folder: URL?
    @State private var confirmsTrash = false
    var body: some View {
        List {
            if let record = store.record(id) {
                Section("Original checkout") {
                    LabeledContent("Session", value: record.sessionID).textSelection(.enabled)
                    LabeledContent("Amount / copies", value: "\(PHPPriceFormatter.string(centavos: record.totalCentavos)) / \(record.copies)")
                    LabeledContent("Acknowledgment", value: record.acknowledgedAt?.formatted() ?? "Not acknowledged")
                    LabeledContent("Receipt", value: record.receipt == nil ? "Not submitted" : (record.receipt?.trashedAt == nil ? "Stored privately" : "Retention Trash · proof retained"))
                    LabeledContent("Verification", value: record.verification)
                    LabeledContent("Physical print intent", value: record.printingBeganAt?.formatted() ?? "Not started")
                    let copies = PrintOutcomeOutbox.shared?.entries.filter { $0.isCustomerCopy && $0.sessionID == record.sessionID } ?? []
                    ForEach(copies) { copy in Text("Copy \(copy.copyIndex)/\(copy.copyCount) · \(copy.localState.rawValue)").font(.footnote) }
                    LabeledContent("Guest interaction", value: record.completedAt != nil ? "Completed" : (record.closedAt != nil ? "Closed / retained" : "Open"))
                    if let error = record.syncError { Text(error).font(.footnote) }
                    Button("Refresh Original Cloud Record") { Task { do { _ = try await ManualPaymentSync.sync(id) } catch { message = error.localizedDescription } } }
                }
                if let receipt = record.receipt {
                    Section("Private receipt") {
                        Button("Load Authenticated Receipt Preview") {
                            Task { do {
                                guard let config = PaymentsConfiguration.current() else { throw SetupFailure("Pair the original payments connection first.") }
                                let result = try await PaymentsAPIClient(configuration: config).privateManualReceipt(receipt.receiptId)
                                guard let data = Data(base64Encoded: result.base64), let image = UIImage(data: data) else { throw SetupFailure("Receipt preview unavailable.") }
                                preview = image; folder = result.folderURL
                            } catch { message = error.localizedDescription } }
                        }
                        if let preview { Image(uiImage: preview).resizable().scaledToFit().frame(maxHeight: 500) }
                        if let folder { Link("Open Authorized Private Drive Folder", destination: folder) }
                        if receipt.trashedAt == nil {
                            Button("Move Eligible Receipt to Drive Trash", role: .destructive) { confirmsTrash = true }
                            Text("Requires an established retention period, eligible age and a recorded reason below. No permanent deletion.").font(.footnote)
                        }
                    }
                }
                Section("Independent funds review") {
                    Text("Confirm funds only after independently checking the receiving account. Approving a screenshot alone is not verification.").font(.footnote)
                    TextField("Actual received amount (PHP)", text: $amount).keyboardType(.decimalPad)
                    TextField("What was independently checked / discrepancy", text: $note, axis: .vertical)
                    Button("Funds Independently Confirmed") { review(.fundsConfirmed) }
                    Button("Flag Discrepancy") { review(.discrepancy) }
                    Button("Keep Unresolved for Review") { review(.unresolved) }
                    ForEach(record.reviews) { review in Text("\(review.createdAt.formatted()) · \(review.outcome.rawValue) · \(review.note)").font(.footnote) }
                }
                if record.completedAt == nil {
                    Section("Original guest recovery") {
                        if record.acknowledgedAt != nil, record.policy.receiptPolicy != .acknowledgmentOnly,
                           let url = record.receiptSubmissionURL, (record.receiptLinkExpiresAt ?? .distantPast) > Date(),
                           let qr = try? GalleryQRCodeGenerator.makeQRCodeImage(for: url) {
                            DisclosureGroup("Show original receipt submission QR") {
                                Image(uiImage: qr).interpolation(.none).resizable().scaledToFit().frame(width: 240, height: 240)
                                    .accessibilityLabel("Original receipt submission QR")
                                Text("Late receipts stay with the original claim for review.").font(.footnote)
                            }
                        }
                        Button("Accept Original Guest's Payment Claim") {
                            do { try store.acceptOriginalClaimForRecovery(id, note: note); message = "Original claim retained as unverified. Required receipt rules remain in force." }
                            catch { message = error.localizedDescription }
                        }
                        Button("Prepare Original Checkout to Resume") {
                            do {
                                guard ActiveGuestInteraction.model.map({ $0.state == .welcome || $0.state == .thankYou }) ?? true else { throw SetupFailure("Close the current guest before preparing original recovery.") }
                                guard record.printingBeganAt == nil, PrintOutcomeOutbox.shared?.copiesThatMayHavePrinted(sessionID: record.sessionID).isEmpty == true else { throw SetupFailure("A copy may have printed. Use the existing physical receipt recovery; no automatic resend is allowed.") }
                                try store.reopenForRecovery(id); store.armedResumeID = id
                                message = "Return to the booth and tap Start to resume this guest’s original checkout."
                            } catch { message = error.localizedDescription }
                        }
                    }
                }
            }
            if !message.isEmpty { Section { Text(message) } }
        }.operatorScreen().navigationTitle("Payment Detail")
        .onDisappear { preview = nil; folder = nil }
        .confirmationDialog("Move this receipt to recoverable Drive Trash?", isPresented: $confirmsTrash, titleVisibility: .visible) {
            Button("Move Eligible Receipt to Trash", role: .destructive) {
                Task { do {
                    guard OperatorAccessPermit.shared.isAuthorized, let receipt = store.record(id)?.receipt, let config = PaymentsConfiguration.current(), !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SetupFailure("Unlock Operator and record a retention reason below.") }
                    try await PaymentsAPIClient(configuration: config).trashManualReceipt(receipt.receiptId, reason: note)
                    _ = try await ManualPaymentSync.sync(id); preview = nil; message = "Receipt moved to recoverable Drive Trash. Original facts and audit remain."
                } catch { message = error.localizedDescription } }
            }
        } message: { Text("The service checks the established retention period and original receipt identity. Payment association and storage proof remain.") }
    }
    private func review(_ outcome: ManualPaymentReview.Outcome) {
        do { try store.review(id, outcome: outcome, confirmedCentavos: PesoAmount.centavos(fromPesoText: amount), note: note); message = "Independent review recorded; acknowledgment and print evidence are unchanged."; Task { _ = try? await ManualPaymentSync.sync(id) } }
        catch { message = error.localizedDescription }
    }
}

@MainActor enum ManualPaymentCSV {
    static func export(_ records: [ManualCheckoutRecord]) throws -> URL {
        func cell(_ raw: String) -> String { let value = "=+-@".contains(raw.first ?? " ") ? "'" + raw : raw; return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        var rows = [["checkout_id","session_id","event_id","run_id","method","copies","total_centavos","acknowledged_at","receipt_submitted","verification","independently_confirmed_centavos","closed_at","completed_at"]]
        for r in records { rows.append([r.id,r.sessionID,r.eventID,r.runID ?? "",r.method,String(r.copies),String(r.totalCentavos),r.acknowledgedAt.map(PaymentsJSON.string) ?? "",r.receipt == nil ? "false" : "true",r.verification,r.reviews.last?.confirmedCentavos.map(String.init) ?? "",r.closedAt.map(PaymentsJSON.string) ?? "",r.completedAt.map(PaymentsJSON.string) ?? ""]) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("manual-payments-\(UUID().uuidString).csv")
        try Data(rows.map { $0.map(cell).joined(separator: ",") }.joined(separator: "\r\n").utf8).write(to: url, options: [.atomic,.completeFileProtection])
        return url
    }
}
