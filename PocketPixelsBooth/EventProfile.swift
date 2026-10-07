//
//  EventProfile.swift
//  PocketPixelsBooth
//

import Foundation
import PhotosUI
import SwiftUI

nonisolated struct EventProfile: Codable, Equatable, Sendable {
    nonisolated static let eventNameLimit = 48
    nonisolated static let subtitleLimit = 60
    nonisolated static let locationLimit = 56
    nonisolated static let shortMessageLimit = 80
    nonisolated static let customerTitleLimit = 52
    nonisolated static let customerSubtitleLimit = 72
    nonisolated static let customerMessageLimit = 100

    var isEnabled: Bool
    var eventName: String
    var subtitle: String
    var includeEventDate: Bool
    var eventDate: Date
    var location: String
    var shortMessage: String
    var receiptHeader: ReceiptHeaderConfiguration
    var showEventTextBlock: Bool
    var customerScreenEnabled: Bool
    var customerTitle: String
    var customerSubtitle: String
    var customerWelcomeMessage: String
    var customerThankYouMessage: String
    var customerTheme: CustomerScreenTheme
    var passport: PassportConfiguration
    /// Typography and future receipt design modules. Artwork remains in `receiptHeader`.
    var receiptDesign: EventReceiptDesignConfiguration

    nonisolated init(
        isEnabled: Bool,
        eventName: String,
        subtitle: String,
        includeEventDate: Bool,
        eventDate: Date,
        location: String = "",
        shortMessage: String,
        receiptHeader: ReceiptHeaderConfiguration = .default,
        showEventTextBlock: Bool = true,
        customerScreenEnabled: Bool = false,
        customerTitle: String = "",
        customerSubtitle: String = "",
        customerWelcomeMessage: String = "",
        customerThankYouMessage: String = "",
        customerTheme: CustomerScreenTheme = .classic,
        passport: PassportConfiguration = .default,
        receiptDesign: EventReceiptDesignConfiguration = .default
    ) {
        self.isEnabled = isEnabled
        self.eventName = eventName
        self.subtitle = subtitle
        self.includeEventDate = includeEventDate
        self.eventDate = eventDate
        self.location = location
        self.shortMessage = shortMessage
        self.receiptHeader = receiptHeader
        self.showEventTextBlock = showEventTextBlock
        self.customerScreenEnabled = customerScreenEnabled
        self.customerTitle = customerTitle
        self.customerSubtitle = customerSubtitle
        self.customerWelcomeMessage = customerWelcomeMessage
        self.customerThankYouMessage = customerThankYouMessage
        self.customerTheme = customerTheme
        self.passport = passport
        self.receiptDesign = receiptDesign
    }

    enum CodingKeys: String, CodingKey {
        case isEnabled
        case eventName
        case subtitle
        case includeEventDate
        case eventDate
        case location
        case shortMessage
        case receiptHeader
        case showEventTextBlock
        case customerScreenEnabled
        case customerTitle
        case customerSubtitle
        case customerWelcomeMessage
        case customerThankYouMessage
        case customerTheme
        case passport
        case receiptDesign
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        eventName = try container.decode(String.self, forKey: .eventName)
        subtitle = try container.decode(String.self, forKey: .subtitle)
        includeEventDate = try container.decode(Bool.self, forKey: .includeEventDate)
        eventDate = try container.decode(Date.self, forKey: .eventDate)
        location = try container.decodeIfPresent(String.self, forKey: .location) ?? ""
        shortMessage = try container.decode(String.self, forKey: .shortMessage)
        receiptHeader = try container.decodeIfPresent(ReceiptHeaderConfiguration.self, forKey: .receiptHeader) ?? .default
        showEventTextBlock = try container.decodeIfPresent(Bool.self, forKey: .showEventTextBlock) ?? true
        customerScreenEnabled = try container.decodeIfPresent(Bool.self, forKey: .customerScreenEnabled) ?? false
        customerTitle = try container.decodeIfPresent(String.self, forKey: .customerTitle) ?? ""
        customerSubtitle = try container.decodeIfPresent(String.self, forKey: .customerSubtitle) ?? ""
        customerWelcomeMessage = try container.decodeIfPresent(String.self, forKey: .customerWelcomeMessage) ?? ""
        customerThankYouMessage = try container.decodeIfPresent(String.self, forKey: .customerThankYouMessage) ?? ""
        customerTheme = try container.decodeIfPresent(CustomerScreenTheme.self, forKey: .customerTheme) ?? .classic
        passport = try container.decodeIfPresent(PassportConfiguration.self, forKey: .passport) ?? .default
        // Added after the first release. Missing or unreadable design data must never make the
        // whole profile unreadable, so it falls back to the Classic design the event used before.
        receiptDesign = (try? container.decodeIfPresent(EventReceiptDesignConfiguration.self, forKey: .receiptDesign)) ?? .default
    }

    nonisolated static var pocketPixelsDefault: EventProfile {
        EventProfile(
            isEnabled: false,
            eventName: "",
            subtitle: "",
            includeEventDate: false,
            eventDate: Date(),
            location: "",
            shortMessage: "",
            receiptHeader: .default,
            showEventTextBlock: true,
            customerScreenEnabled: false,
            customerTitle: "",
            customerSubtitle: "",
            customerWelcomeMessage: "",
            customerThankYouMessage: "",
            customerTheme: .classic,
            passport: .default
        )
    }

    nonisolated var activeReceiptSnapshot: EventProfile? {
        let normalized = normalized()
        guard normalized.isEnabled,
              !normalized.showEventTextBlock || !normalized.eventName.isEmpty else {
            return nil
        }

        return normalized
    }

    nonisolated func normalized() -> EventProfile {
        EventProfile(
            isEnabled: isEnabled,
            eventName: Self.normalizedSingleLine(eventName, limit: Self.eventNameLimit),
            subtitle: Self.normalizedSingleLine(subtitle, limit: Self.subtitleLimit),
            includeEventDate: includeEventDate,
            eventDate: eventDate,
            location: Self.normalizedSingleLine(location, limit: Self.locationLimit),
            shortMessage: Self.normalizedSingleLine(shortMessage, limit: Self.shortMessageLimit),
            receiptHeader: receiptHeader.normalized(),
            showEventTextBlock: showEventTextBlock,
            customerScreenEnabled: customerScreenEnabled,
            customerTitle: Self.normalizedSingleLine(customerTitle, limit: Self.customerTitleLimit),
            customerSubtitle: Self.normalizedSingleLine(customerSubtitle, limit: Self.customerSubtitleLimit),
            customerWelcomeMessage: Self.normalizedSingleLine(customerWelcomeMessage, limit: Self.customerMessageLimit),
            customerThankYouMessage: Self.normalizedSingleLine(customerThankYouMessage, limit: Self.customerMessageLimit),
            customerTheme: customerTheme,
            passport: passport.normalized(),
            receiptDesign: receiptDesign.normalized()
        )
    }

    nonisolated var activeCustomerSnapshot: EventProfile? {
        let value = normalized()
        return value.customerScreenEnabled ? value : nil
    }

    nonisolated var isEventModeActive: Bool {
        activeReceiptSnapshot != nil || activeCustomerSnapshot != nil
    }

    nonisolated var eventModeSummary: String {
        switch (activeCustomerSnapshot != nil, activeReceiptSnapshot != nil) {
        case (true, true): "Guest screens and printed receipts"
        case (true, false): "Guest screens only"
        case (false, true): "Printed receipts only"
        case (false, false): "Pocket Pixels standard mode"
        }
    }

    nonisolated var customerDisplayTitle: String {
        let value = normalized()
        return value.customerTitle.isEmpty ? value.eventName : value.customerTitle
    }

    nonisolated var customerDisplaySubtitle: String {
        let value = normalized()
        return value.customerSubtitle.isEmpty ? value.subtitle : value.customerSubtitle
    }

    nonisolated var receiptBlockContent: EventReceiptBlockContent? {
        let snapshot = activeReceiptSnapshot
        guard let snapshot else {
            return nil
        }
        guard snapshot.showEventTextBlock else { return nil }

        let dateText = snapshot.includeEventDate ? Self.eventDateFormatter.string(from: snapshot.eventDate).uppercased() : nil
        let locationText = snapshot.location.isEmpty ? nil : snapshot.location.uppercased()
        let metadata = [dateText, locationText].compactMap { $0 }.joined(separator: " • ")

        return EventReceiptBlockContent(
            eyebrow: "A KEEPSAKE FROM",
            eventName: snapshot.eventName,
            subtitle: snapshot.subtitle,
            metadata: metadata,
            message: snapshot.shortMessage
        )
    }

    nonisolated static func limited(_ value: String, limit: Int) -> String {
        String(value.prefix(limit))
    }

    nonisolated private static func normalizedSingleLine(_ value: String, limit: Int) -> String {
        let collapsed = value
            .replacingOccurrences(of: "\n", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")

        return String(collapsed.prefix(limit))
    }

    nonisolated private static let eventDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Manila") ?? TimeZone(secondsFromGMT: 8 * 60 * 60)
        formatter.dateFormat = "MMM d, yyyy"
        return formatter
    }()
}

struct EventReceiptBlockContent: Equatable, Sendable {
    let eyebrow: String
    let eventName: String
    let subtitle: String
    let metadata: String
    let message: String
}

enum EventProfileStore {
    private static let storageKey = "pocketPixels.eventProfile.v1"
    static let didChangeNotification = Notification.Name("pocketPixels.eventProfile.didChange")

    static func load() -> EventProfile {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let profile = try? JSONDecoder().decode(EventProfile.self, from: data) else {
            return .pocketPixelsDefault
        }

        return profile.normalized()
    }

    static func save(_ profile: EventProfile) {
        guard let data = try? JSONEncoder().encode(profile.normalized()) else {
            return
        }

        UserDefaults.standard.set(data, forKey: storageKey)
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }
}

struct EventSetupView: View {
    @State private var draft: EventProfile
    @State private var savedProfile: EventProfile
    @State private var statusMessage = "Event profile loaded."

    init() {
        // Load once so an unsaved default profile (which stamps the current date) does not
        // immediately read as having unsaved changes.
        let profile = EventProfileStore.load()
        _draft = State(initialValue: profile)
        _savedProfile = State(initialValue: profile)
    }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Label(
                        savedProfile.isEventModeActive ? "EVENT MODE ON" : "EVENT MODE OFF",
                        systemImage: savedProfile.isEventModeActive ? "checkmark.circle.fill" : "circle"
                    )
                    .font(.title3.bold())
                    .foregroundStyle(savedProfile.isEventModeActive ? .green : .secondary)
                    Text(savedProfile.isEventModeActive ? savedProfile.eventModeSummary : "Guests see the standard Pocket Pixels booth.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)

                NavigationLink {
                    EventPreviewView(draft: draft)
                } label: {
                    Label("Preview Event", systemImage: "eye.fill")
                        .font(.headline)
                        .foregroundStyle(.tint)
                        .frame(minHeight: 36)
                }
                .accessibilityHint("Shows guest screens, the receipt and Photo Pass without printing.")

                if hasUnsavedChanges {
                    Label("Unsaved changes", systemImage: "pencil.circle.fill")
                        .foregroundStyle(.orange)
                }
            }

            Section("Event") {
                limitedTextField("Event Name", text: $draft.eventName, limit: EventProfile.eventNameLimit)
                if !canActivate {
                    Text("Enter an event name to use event details on receipts.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                limitedTextField("Subtitle / Host", text: $draft.subtitle, limit: EventProfile.subtitleLimit)

                Toggle("Show Date", isOn: $draft.includeEventDate)

                if draft.includeEventDate {
                    DatePicker("Date", selection: $draft.eventDate, displayedComponents: .date)
                }

                limitedTextField("Location", text: $draft.location, limit: EventProfile.locationLimit)
            }

            Section("Receipt") {
                Text("Receipt Header")
                    .font(.headline)
                EventHeaderEditorView(profile: $draft, statusMessage: $statusMessage)
                limitedTextField("Optional Message", text: $draft.shortMessage, limit: EventProfile.shortMessageLimit, autocapitalization: .sentences)
            }

            EventTypographySection(typography: $draft.receiptDesign.typography)

            Section("Guest Screens") {
                Picker("Theme", selection: $draft.customerTheme) {
                    ForEach(CustomerScreenTheme.allCases) { theme in
                        Text(theme.displayName).tag(theme)
                    }
                }

                DisclosureGroup("Customize Guest Screens") {
                    limitedTextField("Title", text: $draft.customerTitle, limit: EventProfile.customerTitleLimit)
                        .accessibilityHint("Optional. Event Name is used when this is blank.")
                    limitedTextField("Subtitle", text: $draft.customerSubtitle, limit: EventProfile.customerSubtitleLimit)
                        .accessibilityHint("Optional. Subtitle or Host is used when this is blank.")
                    limitedTextField("Welcome Message", text: $draft.customerWelcomeMessage, limit: EventProfile.customerMessageLimit, autocapitalization: .sentences)
                    limitedTextField("Thank-you Message", text: $draft.customerThankYouMessage, limit: EventProfile.customerMessageLimit, autocapitalization: .sentences)
                }
            }

            Section {
                Text("Photo Pass prints the Event Name, Location and, when shown, the Event Date above. Guests only add their name, an optional note and a signature.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Photo Pass")
            } footer: {
                Text("The Photo Pass design is fixed so every keepsake prints predictably.")
            }

            Section {
                if !savedProfile.isEventModeActive {
                    Button {
                        draft.isEnabled = true
                        draft.customerScreenEnabled = true
                        saveDraft()
                    } label: {
                        Text("Save & Activate")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canActivate)
                }

                Button {
                    saveDraft()
                } label: {
                    Text("Save Changes")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .disabled(!canSave || !hasUnsavedChanges)

                if savedProfile.isEventModeActive {
                    Button(role: .destructive) {
                        draft.isEnabled = false
                        draft.customerScreenEnabled = false
                        saveDraft()
                    } label: {
                        Text("Turn Off Event Mode")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                }

                if draft.isEnabled != draft.customerScreenEnabled {
                    Text("Event branding is currently on for \(draft.isEnabled ? "printed receipts" : "guest screens") only.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                DisclosureGroup("Advanced Activation") {
                    Toggle("Event branding on printed receipts", isOn: $draft.isEnabled)
                        .accessibilityHint("When on, new receipts use the event header and details, including on the Photo Pass.")
                    Toggle("Event branding on guest screens", isOn: $draft.customerScreenEnabled)
                        .accessibilityHint("When on, guest screens use event wording and the selected theme.")
                    Text("Most events keep both on. Use Save Changes to apply.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Activation")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(statusMessage)
                    Text("Saved settings apply to the next customer. A session in progress keeps its frozen event settings.")
                }
            }
        }
        .navigationTitle("Event Setup")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { saveDraft() }
                    .fontWeight(.bold)
                    .disabled(!canSave || !hasUnsavedChanges)
            }
        }
    }

    private var canSave: Bool {
        !draft.isEnabled || !draft.showEventTextBlock || !draft.normalized().eventName.isEmpty
    }

    /// Activation turns on receipts, which require an event name whenever event details are shown.
    private var canActivate: Bool {
        !draft.showEventTextBlock || !draft.normalized().eventName.isEmpty
    }

    private var hasUnsavedChanges: Bool {
        draft.normalized() != savedProfile.normalized()
    }

    private func limitedTextField(
        _ title: String,
        text: Binding<String>,
        limit: Int,
        autocapitalization: TextInputAutocapitalization = .words
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField(title, text: text)
                .textInputAutocapitalization(autocapitalization)
                .onChange(of: text.wrappedValue) { _, newValue in
                    let limited = EventProfile.limited(newValue, limit: limit)
                    if limited != newValue {
                        text.wrappedValue = limited
                    }
                }

            Text("\(text.wrappedValue.count)/\(limit)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func saveDraft() {
        let normalized = draft.normalized()
        guard !normalized.isEnabled || !normalized.showEventTextBlock || !normalized.eventName.isEmpty else {
            statusMessage = "Enter an event name, or turn off event details below the header."
            return
        }

        draft = normalized
        EventProfileStore.save(normalized)
        savedProfile = normalized
        statusMessage = normalized.isEnabled || normalized.customerScreenEnabled
            ? "Event profile saved for future sessions."
            : "Event branding is off for future sessions."
    }
}

/// Pure helpers behind Preview Event. Nothing here saves, prints, archives or uploads.
enum EventSetupPreview {
    /// The profile Preview Event renders. While Event Mode is off the operator is previewing what
    /// Save & Activate will produce, so both outputs are shown as active. An explicit split
    /// configuration (screens-only or receipts-only) is previewed exactly as configured.
    nonisolated static func previewProfile(for draft: EventProfile) -> EventProfile {
        var profile = draft.normalized()
        if !profile.isEnabled && !profile.customerScreenEnabled {
            profile.isEnabled = true
            profile.customerScreenEnabled = true
        }
        return profile
    }

    nonisolated static func showsActivatedPreview(for draft: EventProfile) -> Bool {
        let profile = draft.normalized()
        return !profile.isEnabled && !profile.customerScreenEnabled
    }
}

private struct EventPreviewView: View {
    let draft: EventProfile

    var body: some View {
        let profile = EventSetupPreview.previewProfile(for: draft)
        List {
            if EventSetupPreview.showsActivatedPreview(for: draft) {
                Section {
                    Label("Event Mode is off. This shows how the booth will look after Save & Activate.", systemImage: "info.circle")
                        .font(.subheadline)
                }
            }
            Section("Guest Screens") {
                CustomerExperiencePreviewView(profile: profile)
            }
            Section {
                EventReceiptComposerPreview(profile: profile)
                    .padding(.vertical, 6)
            } header: {
                Text("Receipt & Photo Pass")
            } footer: {
                Text("Preview only. Nothing is printed, saved or uploaded.")
            }
        }
        .navigationTitle("Preview Event")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct CustomerExperiencePreviewView: View {
    let profile: EventProfile

    private var activeProfile: EventProfile? { profile.activeCustomerSnapshot }
    private var theme: CustomerScreenTheme { activeProfile?.customerTheme ?? .classic }

    var body: some View {
        VStack(spacing: 12) {
            previewCard(title: "WELCOME", message: welcomeText, icon: "camera.fill")
            previewCard(title: "THANK YOU", message: thankYouText, icon: "qrcode")

            Text("Static preview only. It does not start a session, create a gallery, save an archive, change counters or print.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
    }

    private func previewCard(title: String, message: String, icon: String) -> some View {
        VStack(spacing: 8) {
            Label(title, systemImage: icon)
                .font(.caption.bold())
                .tracking(1.2)
            Text(eventTitle)
                .font(.title3.bold())
                .multilineTextAlignment(.center)
            if !eventSubtitle.isEmpty {
                Text(eventSubtitle)
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
            }
            Text(message)
                .font(.footnote)
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(theme.customerTextColor)
        .frame(maxWidth: .infinity)
        .padding(18)
        .background(
            LinearGradient(colors: theme.backgroundColors, startPoint: .topLeading, endPoint: .bottomTrailing)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(theme.customerTextColor.opacity(0.16), lineWidth: 1)
        }
    }

    private var eventTitle: String {
        guard let activeProfile, !activeProfile.customerDisplayTitle.isEmpty else { return "Pocket Pixels" }
        return activeProfile.customerDisplayTitle
    }

    private var eventSubtitle: String { activeProfile?.customerDisplaySubtitle ?? "Receipt Photobooth" }
    private var welcomeText: String { activeProfile?.customerWelcomeMessage.nonEmpty ?? "Make your moment. Print your keepsake." }
    private var thankYouText: String { activeProfile?.customerThankYouMessage.nonEmpty ?? "Thanks for making memories with us." }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

struct EventReceiptComposerPreview: View {
    let profile: EventProfile

    @StateObject private var printer = PrinterCoordinator.shared
    @StateObject private var operations = EventOperationalState.shared
    @AppStorage("printerIP") private var printerIP = BoothConfiguration.defaultPrinterIP
    @AppStorage("printerPort") private var printerPort = BoothConfiguration.defaultPrinterPort
    @State private var selectedFormat: BoothFormat = .duo
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var importedPhotos: [UIImage] = []
    @State private var sampleStatus: String?
    @State private var previewImage: UIImage?
    @State private var previewReceipt: ComposedReceipt?
    @State private var previewError: String?
    @State private var renderTask: Task<Void, Never>?
    @State private var renderGeneration = 0
    @State private var isSamplePrintActive = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Preview Format", selection: $selectedFormat) {
                ForEach(BoothFormat.allCases) { format in
                    Text(format.displayName).tag(format)
                }
            }
            .pickerStyle(.segmented)
            .disabled(isSamplePrintActive)

            HStack {
                PhotosPicker(selection: $pickerItems, maxSelectionCount: 6, matching: .images) {
                    Label("Import Sample Photos", systemImage: "photo.on.rectangle.angled")
                }
                .buttonStyle(.bordered)
                .disabled(isSamplePrintActive)
                if !importedPhotos.isEmpty {
                    Button("Clear Imported Photos") {
                        importedPhotos = []
                        pickerItems = []
                        sampleStatus = nil
                        scheduleRender()
                    }
                    .buttonStyle(.bordered)
                    .disabled(isSamplePrintActive)
                }
            }
            if !importedPhotos.isEmpty {
                Text("\(importedPhotos.count) sample \(importedPhotos.count == 1 ? "photo" : "photos") imported")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ScrollView(.vertical) {
                if let previewImage {
                    Image(uiImage: previewImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 360)
                        .overlay {
                            Rectangle()
                                .stroke(Color.secondary.opacity(0.24), lineWidth: 1)
                        }
                        .frame(maxWidth: .infinity)
                } else if let previewError {
                    Text(previewError)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 260)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 260)
                }
            }
            .frame(maxHeight: 520)

            if let previewReceipt {
                Text("\(previewReceipt.format.displayName) • \(previewReceipt.width)x\(previewReceipt.height) px • \(String(format: "%.1f", previewReceipt.estimatedLengthMillimeters)) mm")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(profile.activeReceiptSnapshot == nil ? "Event branding is off or missing an event name." : "Rendering receipt preview.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button {
                printSampleReceipt()
            } label: {
                Label("Print Sample Receipt", systemImage: "printer.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!SamplePrintPolicy.canStart(
                hasPreview: previewReceipt != nil,
                printerBusy: printer.isWorking,
                recoveryLocked: printer.requiresRecovery,
                unresolvedPrint: operations.hasUnresolvedPrint,
                operationActive: isSamplePrintActive
            ))

            if let sampleStatus {
                Text(sampleStatus).font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear {
            scheduleRender()
        }
        .onChange(of: profile.normalized()) { _, _ in
            scheduleRender()
        }
        .onChange(of: selectedFormat) { _, _ in
            scheduleRender()
        }
        .onChange(of: pickerItems) { _, items in importPhotos(items) }
        .onDisappear {
            renderTask?.cancel()
        }
        .frame(maxWidth: .infinity)
    }

    /// Debounced, cancellable and generation-checked: a slow render for older settings can never
    /// replace the preview of newer settings.
    @MainActor
    private func scheduleRender() {
        renderTask?.cancel()
        previewError = nil
        renderGeneration += 1
        let generation = renderGeneration
        let profile = profile.normalized()
        let format = selectedFormat
        renderTask = Task {
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled else {
                return
            }

            do {
                let receipt = try await Self.makePreviewReceipt(profile: profile, format: format, importedPhotos: importedPhotos)
                guard let image = UIImage(data: receipt.imagePNGData) else {
                    throw ReceiptComposerError.renderFailed
                }
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard generation == renderGeneration else { return }
                    previewReceipt = receipt
                    previewImage = image
                }
            } catch is CancellationError {
                return
            } catch {
                await MainActor.run {
                    guard generation == renderGeneration else { return }
                    previewReceipt = nil
                    previewImage = nil
                    previewError = error.localizedDescription
                }
            }
        }
    }

    /// Composes a sample receipt in memory only. It never touches the print spooler, audit, archive or gallery queue.
    nonisolated static func makePreviewReceipt(profile: EventProfile, format: BoothFormat, importedPhotos: [UIImage] = []) async throws -> ComposedReceipt {
        let worker = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            guard let galleryURL = URL(string: "https://pocket-pixels-gallery.pocketpixels-ceb.workers.dev/?g=event-preview") else {
                throw GalleryUploadError.invalidGalleryURL
            }

            let date = previewDate
            return try ReceiptComposer.compose(
                photos: samplePhotos(importedPhotos: importedPhotos, count: format.photoCount),
                sessionIdentifier: "PP-20260907-192104",
                date: date,
                galleryURL: galleryURL,
                format: format,
                eventProfile: profile.activeReceiptSnapshot,
                passport: format == .passport
                    ? .operatorPreviewSample(configuration: PassportConfiguration.effective(for: profile))
                    : nil
            )
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    nonisolated static func samplePhotos(importedPhotos: [UIImage], count: Int) -> [UIImage] {
        guard !importedPhotos.isEmpty else { return makeSamplePhotos(count: count) }
        return (0..<count).map { importedPhotos[$0 % importedPhotos.count] }
    }

    private func importPhotos(_ items: [PhotosPickerItem]) {
        Task {
            var decoded: [UIImage] = []
            for item in items.prefix(6) {
                if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                    decoded.append(image.normalizedForGalleryUpload().resizedForGalleryUpload(maxLongestSide: 1_600))
                }
            }
            importedPhotos = decoded
            sampleStatus = decoded.isEmpty ? "No sample photos could be imported." : nil
            scheduleRender()
        }
    }

    private func printSampleReceipt() {
        guard SamplePrintPolicy.canStart(
            hasPreview: previewReceipt != nil,
            printerBusy: printer.isWorking,
            recoveryLocked: printer.requiresRecovery,
            unresolvedPrint: operations.hasUnresolvedPrint,
            operationActive: isSamplePrintActive
        ) else {
            if operations.hasUnresolvedPrint {
                sampleStatus = "Resolve the previous print before printing a sample."
                return
            }
            sampleStatus = "Printer needs attention."
            return
        }
        isSamplePrintActive = true
        sampleStatus = "Preparing sample..."
        Task {
            do {
                let receipt = try await Self.makePhysicalSampleReceipt(
                    profile: profile.normalized(), format: selectedFormat, importedPhotos: importedPhotos
                )
                guard let image = UIImage(data: receipt.imagePNGData) else { throw ReceiptComposerError.renderFailed }
                let raster = try await Task.detached(priority: .userInitiated) {
                    try ThermalImageRasterizer.rasterize(image, purpose: .completeReceipt)
                }.value
                sampleStatus = "Printing sample..."
                printer.printReceipt(
                    rasterizedImage: raster,
                    wifiHost: printerIP,
                    wifiPort: UInt16(printerPort.trimmingCharacters(in: .whitespacesAndNewlines)),
                    sessionIdentifier: "operator-sample",
                    source: .operatorSample,
                    transportPolicy: printer.productionReceiptTransportPolicy
                ) { result in
                    isSamplePrintActive = false
                    switch result {
                    case .success: sampleStatus = "Sample printed."
                    case .failure: sampleStatus = "Printer needs attention."
                    }
                }
            } catch {
                isSamplePrintActive = false
                sampleStatus = "Printer needs attention."
            }
        }
    }

    nonisolated static func makePhysicalSampleReceipt(
        profile: EventProfile,
        format: BoothFormat,
        importedPhotos: [UIImage]
    ) async throws -> ComposedReceipt {
        try await Task.detached(priority: .utility) {
            try ReceiptComposer.compose(
                photos: samplePhotos(importedPhotos: importedPhotos, count: format.photoCount),
                sessionIdentifier: "operator-sample",
                date: previewDate,
                galleryURL: nil,
                format: format,
                eventProfile: profile.activeReceiptSnapshot,
                passport: format == .passport
                    ? .operatorPreviewSample(configuration: PassportConfiguration.effective(for: profile))
                    : nil
            )
        }.value
    }

    nonisolated private static func makeSamplePhotos(count: Int) -> [UIImage] {
        (0..<count).map { index in
            makeSamplePhoto(index: index)
        }
    }

    nonisolated private static func makeSamplePhoto(index: Int) -> UIImage {
        let size = CGSize(width: 900, height: 1200)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))

            UIColor.black.setFill()
            context.fill(CGRect(x: 84, y: 92, width: 732, height: 906))
            UIColor.white.setFill()
            context.fill(CGRect(x: 126, y: 134, width: 648, height: 822))

            UIColor.black.setFill()
            UIColor.black.setStroke()
            context.cgContext.setLineWidth(22)
            context.cgContext.stroke(CGRect(x: 176, y: 206, width: 548, height: 612))
            context.fill(CGRect(x: 126, y: 878, width: 648, height: 78))

            let label = "PHOTO \(index + 1)"
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedSystemFont(ofSize: 72, weight: .bold),
                .foregroundColor: UIColor.white
            ]
            let labelSize = NSString(string: label).size(withAttributes: attributes)
            NSString(string: label).draw(
                at: CGPoint(x: (size.width - labelSize.width) / 2, y: 884),
                withAttributes: attributes
            )
        }
    }

    nonisolated private static var previewDate: Date {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(identifier: "Asia/Manila")
        components.year = 2026
        components.month = 9
        components.day = 7
        components.hour = 19
        components.minute = 21
        return components.date ?? Date(timeIntervalSince1970: 1_789_155_660)
    }
}
