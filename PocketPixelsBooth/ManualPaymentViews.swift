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
                Text(ManualPaymentStore.shared.receiver?.isReady == true ? "Acknowledgment is a guest claim. Independent review is optional after the session." : "Digital payments are disabled until a permitted receiving account is configured and enabled.")
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
    @State private var confirmingAcknowledgment = false
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                MadeToKeepLockup(scale: .compact)
                Text("Digital payment").font(MadeToKeepTheme.Typography.serif(size: 38))
                if let record = viewModel.manualCheckout {
                    Text(PHPPriceFormatter.string(centavos: record.totalCentavos)).font(.largeTitle)
                    Text("\(record.copies) identical \(record.copies == 1 ? "copy" : "copies")")
                    if let url = record.checkoutURL, let qr = try? GalleryQRCodeGenerator.makeQRCodeImage(for: url) {
                        Image(uiImage: qr).interpolation(.none).resizable().scaledToFit().frame(maxWidth: 260)
                        Text("Scan to open your mobile checkout and privately submit a receipt.").font(.callout)
                    } else if record.policy.receiptPolicy == .required {
                        Text("Wait for the checkout QR before sending payment. You need that page to submit your receipt. If you already paid, ask the attendant about this checkout.")
                            .font(.callout)
                    } else if record.acknowledgedAt == nil {
                        Text("Mobile checkout is connecting. You may use the receiving details below.").font(.callout)
                    }
                    if record.policy.receiptPolicy != .required, record.acknowledgedAt == nil, let receiver = record.receiver {
                        VStack(spacing: 8) {
                            Text(receiver.provider).font(.headline); Text(receiver.recipient); Text(receiver.identifier).textSelection(.enabled)
                            Text(receiver.instructions).font(.callout)
                            if let data = receiver.qrJPEG, let image = UIImage(data: data) {
                                Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 200)
                                Text("Receiving-account payment QR").font(.caption)
                            }
                        }.padding().background(OperatorPalette.surface, in: RoundedRectangle(cornerRadius: 14))
                    }
                    Text(record.policy.receiptPolicy.title).font(.headline)
                    if record.receipt != nil { Label("Receipt stored privately", systemImage: "lock.doc") }
                    if record.acknowledgedAt != nil { Text("Payment acknowledged · funds not independently verified").font(.callout) }
                    if let notice = viewModel.paymentNotice { Text(notice).font(.callout).accessibilityIdentifier("manual-checkout-notice") }
                    Button("I've sent the payment") { confirmingAcknowledgment = true }
                        .buttonStyle(MadeToKeepPrimaryButtonStyle()).disabled(viewModel.isCheckoutTransitionActive)
                        .accessibilityIdentifier("manual-local-acknowledgment")
                    Button("Check Receipt & Mobile Acknowledgment") { Task { await viewModel.refreshManualPayment() } }.buttonStyle(.bordered)
                    Text("A receipt or acknowledgment is not independent verification of funds. If you already paid, do not pay again.").font(.footnote)
                }
                Button("Call Attendant / Get Help", action: onHelp).buttonStyle(.bordered)
                Button("Close & Keep My Claim") { viewModel.cancelSession() }.buttonStyle(.bordered)
            }.multilineTextAlignment(.center).padding(24).frame(maxWidth: 600).frame(maxWidth: .infinity)
        }.tint(OperatorPalette.accent)
        .confirmationDialog("Acknowledge this payment?", isPresented: $confirmingAcknowledgment, titleVisibility: .visible) {
            Button("I've transferred the exact amount") { viewModel.acknowledgeManualPayment() }
            Button("Not yet", role: .cancel) { }
        } message: { Text("Tap only after transferring to the receiving account shown for this checkout. No second payment will be requested automatically.") }
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
                        Button("Accept Original Guest's Payment Claim") {
                            do { try store.acceptOriginalClaimForRecovery(id, note: note); message = "Original claim retained as unverified. Required receipt rules remain in force." }
                            catch { message = error.localizedDescription }
                        }
                        Button("Prepare Original Authorization to Resume") {
                            do {
                                guard ActiveGuestInteraction.model.map({ $0.state == .welcome || $0.state == .thankYou }) ?? true else { throw SetupFailure("Close the current guest before preparing original recovery.") }
                                guard record.printingBeganAt == nil, PrintOutcomeOutbox.shared?.copiesThatMayHavePrinted(sessionID: record.sessionID).isEmpty == true else { throw SetupFailure("A copy may have printed. Use the existing physical receipt recovery; no automatic resend is allowed.") }
                                try store.reopenForRecovery(id); store.armedResumeID = id
                                message = "Return to the booth and tap Start to resume this exact authorization. No new payment or copy quantity is created."
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
