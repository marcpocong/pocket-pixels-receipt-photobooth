import SwiftUI

/// A value-only projection. Inspecting either source never stages, saves or applies setup.
nonisolated struct EventPreparationPresentation {
    enum Source: String, CaseIterable { case saved = "Saved design", staged = "Staged draft" }
    let saved: SavedEventDesign?
    let staged: SavedEventDesign?
    let serverDraft: OperatorServerSetupDraft?
    let selection: OperatorSessionSetupDraft?
    let unavailable: String?
    let application: String
    let editsLiveEvent: Bool
    let serverBinding: String
    let serverEventID: String?

    init(designID: String, library: EventDesignLibrary, libraryError: String?,
         workspace: OperatorWorkspace.Snapshot, workspaceError: String?, binding: String,
         operationalRun: EventRunRecord?, historyUnreadable: Bool) {
        let record = library.events.first { $0.id == designID }
        saved = record
        // Library-owned identity and bindings always win over stale draft metadata.
        if var draft = workspace.designDrafts?[designID], let record, draft.id == designID {
            draft.serverEvents = record.serverEvents
            draft.retiredServerEvents = record.retiredServerEvents
            draft.archivedAt = record.archivedAt; draft.removedAt = record.removedAt
            staged = draft
        } else { staged = nil }
        serverBinding = binding
        serverEventID = record?.serverEventID(binding: binding)
        serverDraft = serverEventID.flatMap { workspace.serverDrafts["\(binding):\($0)"] }
        selection = workspace.sessionSetup.flatMap { $0.eventModeEnabled == true && $0.designID == designID ? $0 : nil }
        if let libraryError { unavailable = libraryError }
        else if record == nil { unavailable = "This saved event is no longer available. Return to Events to review the library." }
        else if record?.removedAt != nil { unavailable = "This event was removed. Restore it from Events → Show Removed Events before continuing setup." }
        else { unavailable = nil }
        editsLiveEvent = !historyUnreadable && library.appliedEventModeEnabled && library.appliedEventID == designID
            && operationalRun?.context.designID == designID && operationalRun?.status == .active
        if historyUnreadable { application = "Current event status unavailable" }
        else if let run = operationalRun {
            application = run.context.designID == designID
                ? "This event’s run is \(run.status.rawValue) on this iPad"
                : "\(run.displayName) is \(run.status.rawValue) on this iPad"
        } else { application = "No running event recorded on this iPad" }
        draftReadError = workspaceError
        isApplied = library.appliedEventModeEnabled && library.appliedEventID == designID
    }

    let draftReadError: String?
    let isApplied: Bool
    var hasDraft: Bool { staged != nil || serverDraft != nil || selection != nil }
    func design(for source: Source) -> SavedEventDesign? { source == .staged ? (staged ?? saved) : saved }
    func previewLabel(for source: Source) -> String {
        source == .staged && staged != nil ? "Staged draft preview" : "Saved design preview"
    }
    var setupRoute: OperatorWorkspaceRoute {
        editsLiveEvent ? .liveEvent : .savedEvent(saved?.id ?? "")
    }

    func policyRows(for source: Source) -> [(String, String)] {
        guard let design = design(for: source) else { return [] }
        var rows: [(String, String)] = []
        if let prepaid = design.prepaidPolicy {
            rows.append(("No-payment policy", GuestPaymentChoice.noPayment.title))
            rows.append(("Included / maximum copies", "\(prepaid.defaultCopies) / \(prepaid.maxCopies)"))
            rows.append(("No-payment formats", Self.formats(prepaid.supportedFormatRawValues)))
        }
        let paid = source == .staged ? (serverDraft?.policy ?? design.paidPolicy) : design.paidPolicy
        if let paid {
            rows.append((source == .staged && serverDraft != nil ? "Staged paid policy" : "Saved local paid policy",
                         GuestPaymentChoice(qrPhEnabled: paid.qrPhEnabled, cashEnabled: paid.cashEnabled).title))
            rows.append(("Paid default / maximum copies", "\(paid.defaultCopies) / \(paid.maxCopies)"))
            rows.append(("Paid formats", Self.formats(Array(paid.supportedFormats))))
        }
        if rows.isEmpty {
            rows.append(("Payment, copies & formats", serverEventID == nil
                         ? "Inherited settings — review in Event Setup"
                         : "Linked server policy — review in Event Setup"))
        } else if design.prepaidPolicy != nil && paid != nil {
            rows.append(("Payment selection", "Saved options; confirm the choice in Event Setup"))
        }
        if source == .staged, let selection, selection.serverBinding == serverBinding {
            rows.append(("Staged payment selection", selection.mode == .localPrepaid ? GuestPaymentChoice.noPayment.title : (selection.requestedMethods?.title ?? "Server managed — review in setup")))
        }
        return rows
    }

    private static func formats(_ values: [String]) -> String {
        let names = BoothFormat.allCases.filter { values.contains($0.rawValue) }.map(\.displayName)
        return names.isEmpty ? "No supported formats saved" : names.joined(separator: " · ")
    }
}

struct OperatorPrepareEventView: View {
    let designID: String
    @ObservedObject private var workspace: OperatorWorkspace
    @ObservedObject private var library: EventDesignLibraryStore
    @ObservedObject private var runs: EventRunStore
    @ObservedObject private var operations = EventOperationalState.shared
    @State private var source = EventPreparationPresentation.Source.saved
    @State private var receiptExpanded = false
    @State private var guestExpanded = false

    init(designID: String, workspace: OperatorWorkspace = .shared,
         library: EventDesignLibraryStore = .shared, runs: EventRunStore = .shared) {
        self.designID = designID
        self.workspace = workspace; self.library = library; self.runs = runs
    }

    private var presentation: EventPreparationPresentation {
        .init(designID: designID, library: library.library, libraryError: library.libraryUnreadable ? library.storageError : nil,
              workspace: workspace.snapshot, workspaceError: workspace.persistenceError, binding: workspace.serverBinding,
              operationalRun: runs.operational, historyUnreadable: runs.historyUnreadable)
    }

    var body: some View {
        let model = presentation
        ScrollView {
            VStack(alignment: .leading, spacing: OperatorStyle.Space.section) {
                if let reason = model.unavailable {
                    OperatorSectionHeading(title: "Event unavailable", detail: reason)
                    NavigationLink("Review Saved Events", value: OperatorWorkspaceRoute.eventLibrary)
                    NavigationLink("Help & Recovery", value: OperatorWorkspaceRoute.recovery)
                } else if let design = model.design(for: source) {
                    header(model, design: design)
                    configuration(model, design: design)
                    experience(model, design: design)
                    equipment
                    Text(model.editsLiveEvent ? "Live edits apply only to future sessions." : "Save for later or use Review & Start in Event Setup when you are ready to admit guests.")
                        .font(.footnote).foregroundStyle(OperatorPalette.secondaryText)
                }
            }
            .frame(maxWidth: OperatorStyle.contentWidth, alignment: .leading)
            .padding(OperatorStyle.Space.page).frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .bottom) {
            if model.unavailable == nil {
                NavigationLink(value: model.setupRoute) {
                    Text(model.editsLiveEvent ? "Continue to Live Event Setup" : "Continue to Event Setup")
                        .frame(maxWidth: .infinity, minHeight: 48)
                }.buttonStyle(.borderedProminent).padding(.horizontal, OperatorStyle.Space.page).padding(.vertical, 8)
                    .background(OperatorPalette.surface).accessibilityIdentifier("prepare-continue")
            }
        }
        .operatorScreen().navigationTitle("Prepare Event").navigationBarTitleDisplayMode(.inline)
    }

    private func header(_ model: EventPreparationPresentation, design: SavedEventDesign) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            OperatorSectionHeading(title: design.displayName, detail: design.venue.isEmpty ? "Review your event before setup." : design.venue)
            Text(model.saved?.archivedAt != nil ? "Archived saved design" : (model.isApplied ? "Currently Applied · Saved design" : "Saved design"))
                .font(.callout.weight(.semibold))
            Text(model.application).font(.callout).foregroundStyle(OperatorPalette.secondaryText)
            if let error = library.storageError { Text(error).font(.callout).foregroundStyle(OperatorPalette.danger) }
            if let error = model.draftReadError { Text(error).font(.callout).foregroundStyle(OperatorPalette.danger) }
            if model.isApplied {
                Text("Saved configuration may differ from settings already applied to guests.").font(.footnote).foregroundStyle(OperatorPalette.secondaryText)
            }
            if model.hasDraft {
                Label("Unsaved changes available", systemImage: "doc.badge.ellipsis").font(.callout.weight(.semibold))
                Picker("Configuration source", selection: $source) {
                    ForEach(EventPreparationPresentation.Source.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.menu).accessibilityIdentifier("prepare-source")
                NavigationLink("Open Unsaved Changes", value: model.setupRoute)
            }
            if model.saved?.archivedAt != nil {
                Text("Archived designs can be edited. Restore this design in Saved Events before starting it.").font(.footnote)
                NavigationLink("Review Archived Design", value: OperatorWorkspaceRoute.eventLibrary)
            }
        }
    }

    private func configuration(_ model: EventPreparationPresentation, design: SavedEventDesign) -> some View {
        SetupCard {
            Text("Event Configuration").font(.headline)
            Text("\(source.rawValue) · configuration & preview").font(.caption).foregroundStyle(OperatorPalette.secondaryText)
                .accessibilityIdentifier("prepare-source-label")
            ForEach(Array(model.policyRows(for: source).enumerated()), id: \.offset) { _, row in
                summaryRow(row.0, row.1)
            }
            summaryRow("Receipt personalization", design.personalizeReceipt ? design.layout.displayName : "Studio branding")
            summaryRow("Guest welcome", design.guestScreensEnabled ? "Event welcome & thank you" : "Studio welcome & thank you")
            summaryRow("Sticker Studio", design.profile.stickerStudioEnabled.map { $0 ? "Enabled" : "Disabled" } ?? "Inherits booth setting")
            if source == .staged, let draft = model.serverDraft {
                summaryRow("Staged server event name", draft.name)
                if !draft.venue.isEmpty { summaryRow("Staged server venue", draft.venue) }
            }
            if model.serverEventID != nil {
                summaryRow("Saved payment link", "Available for this connection")
            }
            if model.serverEventID != nil || design.paidPolicy != nil || model.serverDraft != nil {
                Text("Payments: \(model.serverBinding.hasPrefix("live:") ? "LIVE" : (model.serverBinding.hasPrefix("test:") ? "TEST" : "current connection")). Live server status has not been checked here. Review checkout availability in Event Setup.")
                    .font(.footnote).foregroundStyle(OperatorPalette.secondaryText)
            }
            NavigationLink("Edit Event Configuration", value: model.setupRoute).frame(minHeight: 44)
        }
    }

    private func summaryRow(_ title: String, _ value: String) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline) { Text(title).foregroundStyle(OperatorPalette.secondaryText); Spacer(minLength: 16); Text(value).multilineTextAlignment(.trailing) }
            VStack(alignment: .leading, spacing: 4) { Text(title).foregroundStyle(OperatorPalette.secondaryText); Text(value) }
        }.font(.callout).fixedSize(horizontal: false, vertical: true)
    }

    private func experience(_ model: EventPreparationPresentation, design: SavedEventDesign) -> some View {
        SetupCard {
            Text("Receipt & Guest Experience").font(.headline)
            Text(model.previewLabel(for: source)).font(.caption).accessibilityIdentifier("prepare-preview-label")
            DisclosureGroup("Preview Receipt", isExpanded: $receiptExpanded) {
                EventReceiptComposerPreview(profile: design.appliedProfile(), printOptions: ReceiptPrintSettingsStore.load(), showsSamplePrintLink: false, allowsPhotoExport: false, maximumPreviewWidth: 280, compact: true)
            }.frame(minHeight: 44)
            DisclosureGroup("Preview Guest Experience", isExpanded: $guestExpanded) {
                CustomerExperiencePreviewView(profile: design.appliedProfile())
            }.frame(minHeight: 44)
            NavigationLink {
                    if model.editsLiveEvent { SessionSetupView(editingLiveEvent: true, opensReceiptEditor: true) }
                    else { OperatorSavedEventSetupView(designID: designID, receiptOnly: true, workspace: workspace, library: library, runs: runs) }
            } label: { Label("Customize Receipt & Branding", systemImage: "paintpalette") }.frame(minHeight: 44)
        }
    }

    private var equipment: some View {
        SetupCard {
            Text("Equipment & Services").font(.headline)
            Text("Open a tool when needed. Checks and test prints remain explicit actions.").font(.footnote).foregroundStyle(OperatorPalette.secondaryText)
            if let observation = operations.readinessReport.checks.first(where: { $0.title == "Printer" }) {
                summaryRow("Printer · last observation", observation.detail)
                Text(operations.readinessReport.generatedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(OperatorPalette.secondaryText)
            } else {
                summaryRow("Printer", "No printer observation available")
            }
            NavigationLink("Printer Setup", value: OperatorWorkspaceRoute.printer).frame(minHeight: 44)
            NavigationLink("Booth Check", value: OperatorWorkspaceRoute.boothCheck).frame(minHeight: 44)
            NavigationLink("Gallery Setup", value: OperatorWorkspaceRoute.gallery).frame(minHeight: 44)
            if let error = operations.queueError {
                Text(error).font(.footnote).foregroundStyle(OperatorPalette.danger)
                NavigationLink("Review Waiting Galleries", value: OperatorWorkspaceRoute.waitingGalleries)
            } else if operations.pendingUploadCount > 0 {
                NavigationLink("Waiting Galleries · \(operations.pendingUploadCount)", value: OperatorWorkspaceRoute.waitingGalleries)
            }
        }
    }
}
