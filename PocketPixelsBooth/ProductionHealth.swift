import SwiftUI

/// Observational production health for the operator. It reads the existing state owners and
/// never triggers a payment, print or event mutation. Cached equipment state is reported as
/// "last reported", never as a live check.
nonisolated struct ProductionHealthReport: Equatable, Sendable {
    nonisolated enum Level: String, Equatable, Sendable, Comparable {
        case ready = "Ready", unavailable = "Unavailable", warning = "Warning", review = "Needs Operator Review"
        private var rank: Int { [.ready, .unavailable, .warning, .review].firstIndex(of: self) ?? 0 }
        static func < (lhs: Level, rhs: Level) -> Bool { lhs.rank < rhs.rank }
        var systemImage: String {
            switch self {
            case .ready: "checkmark.circle.fill"
            case .unavailable: "questionmark.circle"
            case .warning: "exclamationmark.triangle"
            case .review: "exclamationmark.octagon.fill"
            }
        }
    }
    nonisolated struct Item: Equatable, Identifiable, Sendable {
        let id: String
        let title: String
        let level: Level
        let detail: String
    }
    nonisolated struct Inputs: Sendable {
        var admissionOpen: Bool
        var eventStatus: EventOperatorStatus
        var runID: String?
        var runStatus: EventRunStatus?
        var paid: Bool
        var commercialEventID: String?
        var commercial: CommercialCheckState
        var lastEventCheck: Date?
        var paymentsConfigured: Bool
        var environment: String?
        var printerRequiresRecovery: Bool
        var unresolvedPrint: Bool
        var printerLastReported: String
        var printAccountingConflicts: Int
        var printAccountingPending: Int
        var checkoutsNeedingAttention: Int
        var checkoutIntegrityFault: Bool
        var lastRecoveryCheck: Date?
        var pendingGalleries: Int
        var galleryStorageProblem: Bool
        var storageErrors: [String]
        var pendingCreation: Bool
    }

    let generatedAt: Date
    let items: [Item]

    /// The worst level that needs action. "Unavailable" alone means "not verified", not broken.
    var overall: Level { items.map(\.level).max() ?? .ready }

    init(_ input: Inputs, now: Date = Date()) {
        generatedAt = now
        func time(_ date: Date?) -> String { date.map { $0.formatted(date: .omitted, time: .shortened) } ?? "never" }
        var items: [Item] = []

        let admission: Level = !input.admissionOpen ? .warning : (input.eventStatus.isAccepting ? .ready : .review)
        items.append(Item(id: "admission", title: "Guest admission", level: admission,
                          detail: input.admissionOpen ? (input.eventStatus.isAccepting ? "Open on this iPad." : "Open on this iPad, but the event status is \(input.eventStatus.title).")
                                                      : "Closed on this iPad."))

        let eventLevel: Level = switch input.eventStatus {
        case .accepting, .regular: .ready
        case .unconfirmed: .unavailable
        case .needsReview, .recoveryRequired: .review
        default: .warning
        }
        items.append(Item(id: "event", title: "Event state", level: eventLevel, detail: "\(input.eventStatus.title). \(input.eventStatus.detail)"))

        let run = input.runID.map { "run \($0.prefix(8)) (\(input.runStatus?.rawValue ?? "unknown"))" } ?? "no event run recorded"
        let commercial = input.paid ? (input.commercialEventID.map { "paid event \($0.prefix(8))" } ?? "no paid event identified") : "no payment (prepaid)"
        let identityLevel: Level = input.paid && input.commercialEventID == nil && input.admissionOpen ? .review : .ready
        items.append(Item(id: "identity", title: "Event identity", level: identityLevel, detail: "\(run.prefix(1).uppercased() + run.dropFirst()); \(commercial)."))

        let backend: (Level, String)
        if !input.paid { backend = (.ready, "Not needed for prepaid sessions.") }
        else if !input.paymentsConfigured { backend = (.review, "This iPad isn't paired with the payments server.") }
        else {
            switch input.commercial {
            case .confirmed: backend = (.ready, "\(input.environment?.uppercased() ?? "Payments") server answered at \(time(input.lastEventCheck)).")
            case .unavailable(let reason): backend = (.unavailable, "Payments server not reachable: \(reason)")
            case .notFound: backend = (.review, "The payments server doesn't know this iPad's paid event.")
            case .checking: backend = (.unavailable, "Checking now.")
            case .notNeeded: backend = (.unavailable, "Not checked yet.")
            }
        }
        items.append(Item(id: "backend", title: "Network & payments server", level: backend.0, detail: backend.1))

        let printer: (Level, String)
        if input.printerRequiresRecovery || input.unresolvedPrint { printer = (.review, "A print result needs confirmation in Fix Printer.") }
        else {
            printer = (.unavailable, "Not live-checked here. Last reported: \(input.printerLastReported). Run Booth Check to verify.")
        }
        items.append(Item(id: "printer", title: "Printer & print recovery", level: printer.0, detail: printer.1))

        if input.printAccountingConflicts > 0 || input.printAccountingPending > 0 {
            items.append(Item(id: "print-reports", title: "Saved payment reports", level: input.printAccountingConflicts > 0 ? .review : .ready,
                detail: input.printAccountingConflicts > 0
                    ? "\(input.printAccountingConflicts) report(s) need review in Payment Maintenance. The original purchase records are kept; this does not mean the printer is broken."
                    : "\(input.printAccountingPending) report(s) will sync automatically when online. Normal booth setup can continue. Sending reports never prints a receipt."))
        }

        let payment: (Level, String)
        if input.checkoutIntegrityFault { payment = (.review, "Checkout records need review in Payment Recovery.") }
        else if input.checkoutsNeedingAttention > 0 { payment = (.review, "\(input.checkoutsNeedingAttention) checkout(s) need review in Payment Recovery. Last checked \(time(input.lastRecoveryCheck)).") }
        else if input.lastRecoveryCheck == nil { payment = (.unavailable, "No complete payment-recovery check since launch.") }
        else { payment = (.ready, "No interrupted checkouts. Last checked \(time(input.lastRecoveryCheck)).") }
        items.append(Item(id: "payments", title: "Payment recovery", level: payment.0, detail: payment.1))

        let gallery: (Level, String) = input.galleryStorageProblem ? (.review, "Gallery storage needs review.")
            : input.pendingGalleries > 0 ? (.warning, "\(input.pendingGalleries) gallery upload(s) waiting. They keep uploading while online.")
            : (.ready, "No galleries waiting.")
        items.append(Item(id: "galleries", title: "Pending galleries", level: gallery.0, detail: gallery.1))

        if input.pendingCreation {
            items.append(Item(id: "creation", title: "Paid-event creation", level: .review, detail: "A paid-event creation needs confirmation in Event Setup."))
        }
        items.append(Item(id: "storage", title: "Local storage", level: input.storageErrors.isEmpty ? .ready : .review,
                          detail: input.storageErrors.isEmpty ? "All event, admission and attribution records are readable." : input.storageErrors.joined(separator: " ")))
        self.items = items
    }

    /// Plain text for support. No credentials, tokens, server URLs, gallery links, customer
    /// photos or names: identifiers are shortened and free text is scrubbed.
    func exportText(appVersion: String) -> String {
        var lines = ["Made to Keep Studios — booth health", "Generated: \(generatedAt.ISO8601Format())", "App: \(appVersion)", "Overall: \(overall.rawValue)", ""]
        for item in items { lines.append("[\(item.level.rawValue)] \(item.title): \(Self.scrub(item.detail))") }
        return lines.joined(separator: "\n") + "\n"
    }

    static func scrub(_ text: String) -> String {
        var value = text
        for pattern in [#"[a-zA-Z][a-zA-Z0-9+.-]*://\S+"#, #"(?:/[^\s/]+){2,}"#, #"\b(?:Bearer\s+)?[A-Za-z0-9_\-]{24,}\b"#] {
            value = value.replacingOccurrences(of: pattern, with: "[redacted]", options: .regularExpression)
        }
        return value
    }
}

/// Operator sheet showing the report, with a read-only Check Now and a privacy-safe export.
struct ProductionHealthSheet: View {
    @ObservedObject var lifecycle: EventLifecycleCoordinator
    @ObservedObject private var recovery = PaymentRecoveryCoordinator.shared
    @ObservedObject private var operations = EventOperationalState.shared
    @ObservedObject private var printer = PrinterCoordinator.shared
    @ObservedObject private var acceptance = SessionAcceptanceStore.shared
    @ObservedObject private var creations = CommercialEventCreationStore.shared
    @ObservedObject private var attributions = LegacyAttributionStore.shared
    @ObservedObject private var library = EventDesignLibraryStore.shared
    @Binding var isPresented: Bool
    let loadsRemote: Bool

    private var report: ProductionHealthReport {
        let outbox = PrintOutcomeOutbox.shared?.summary
        let configuration = PaymentsConfiguration.current()
        let runs = lifecycle.runs
        var errors = [runs.storageError, acceptance.storageError, attributions.storageError, creations.storageError, library.storageError].compactMap { $0 }
        if CheckoutCheckpointStore.shared == nil { errors.append("Checkout records are unavailable.") }
        return ProductionHealthReport(.init(
            admissionOpen: !acceptance.state.blocked, eventStatus: lifecycle.status, runID: runs.current?.id, runStatus: runs.current?.status,
            paid: CommercialPolicySource.load() == .serverManaged, commercialEventID: lifecycle.linkedCommercialEventID, commercial: lifecycle.commercial,
            lastEventCheck: lifecycle.lastCheckedAt, paymentsConfigured: configuration != nil, environment: configuration?.environment,
            printerRequiresRecovery: printer.requiresRecovery, unresolvedPrint: operations.hasUnresolvedPrint, printerLastReported: printer.state.message,
            printAccountingConflicts: outbox?.conflicts ?? 0, printAccountingPending: outbox?.pending ?? 0,
            checkoutsNeedingAttention: recovery.activeItems.filter { !$0.classification.isTerminal }.count,
            checkoutIntegrityFault: CheckoutCheckpointStore.shared?.integrityFault != nil, lastRecoveryCheck: recovery.lastRefreshCompletedAt,
            pendingGalleries: operations.pendingUploadCount, galleryStorageProblem: operations.queueError != nil, storageErrors: errors,
            pendingCreation: creations.open(binding: OperatorWorkspace.shared.serverBinding) != nil))
    }
    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }

    var body: some View {
        let report = report
        NavigationStack {
            List {
                Section {
                    Label(report.overall.rawValue, systemImage: report.overall.systemImage).font(.headline)
                    Text("Observed \(report.generatedAt.formatted(date: .omitted, time: .standard)). Nothing here changes payments, prints or the event.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Health") {
                    ForEach(report.items) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            Label(item.title, systemImage: item.level.systemImage).font(.headline)
                            Text("\(item.level.rawValue) — \(item.detail)").font(.callout).foregroundStyle(.secondary)
                        }
                        .frame(minHeight: 44, alignment: .leading)
                        .accessibilityElement(children: .combine)
                    }
                }
                Section {
                    Button("Check Event Status Now") { Task { if loadsRemote { await lifecycle.refresh() } } }
                        .frame(minHeight: 44).disabled(lifecycle.operation != nil)
                    ShareLink("Share Support Summary", item: report.exportText(appVersion: appVersion))
                        .frame(minHeight: 44)
                } footer: {
                    Text("The support summary contains statuses and shortened identifiers only — no credentials, payment tokens, gallery links, photos or guest details.")
                }
            }
            .navigationTitle("Booth Health")
            .tint(MadeToKeepTheme.ColorPalette.burgundy)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { isPresented = false } } }
        }
    }
}
