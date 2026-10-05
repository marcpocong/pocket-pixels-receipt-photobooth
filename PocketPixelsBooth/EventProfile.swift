//
//  EventProfile.swift
//  PocketPixelsBooth
//

import Foundation
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
        passport: PassportConfiguration = .default
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
            passport: passport.normalized()
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
    @State private var draft = EventProfileStore.load()
    @State private var savedProfile = EventProfileStore.load()
    @State private var statusMessage = "Event profile loaded."

    var body: some View {
        Form {
            Section("Current Mode") {
                Label(
                    savedProfile.isEventModeActive ? "EVENT MODE ACTIVE" : "EVENT MODE OFF",
                    systemImage: savedProfile.isEventModeActive ? "checkmark.circle.fill" : "circle"
                )
                .font(.title3.bold())
                .foregroundStyle(savedProfile.isEventModeActive ? .green : .secondary)

                Text(savedProfile.eventModeSummary)
                    .font(.headline)

                if draft.isEnabled != draft.customerScreenEnabled {
                    Text("Screens and receipts currently use different settings. Turn on the switch below to enable both.")
                        .font(.caption)
                }
                Toggle("Event Mode · Screens & Receipts", isOn: eventModeBinding)
                    .font(.headline)

                if hasUnsavedChanges {
                    Label("Unsaved changes — tap Save above to apply them.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                } else {
                    Text("Saved settings apply to the next customer session. A session already in progress keeps its original frozen receipt.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Event Identity") {
                limitedTextField("Event Name", text: $draft.eventName, limit: EventProfile.eventNameLimit)
                if !canSave {
                    Text("Enter an event name to enable event receipts.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                limitedTextField("Subtitle / Host", text: $draft.subtitle, limit: EventProfile.subtitleLimit)

                Toggle("Include Event Date", isOn: $draft.includeEventDate)

                if draft.includeEventDate {
                    DatePicker("Event Date", selection: $draft.eventDate, displayedComponents: .date)
                }

                limitedTextField("Location", text: $draft.location, limit: EventProfile.locationLimit)
            }

            DisclosureGroup("Customize Guest Screens (Optional)") {
                Toggle("Event Screen Branding", isOn: $draft.customerScreenEnabled)
                    .accessibilityHint("Shows event wording and the selected theme on customer screens. It does not change the printed receipt.")

                limitedTextField("Screen Title", text: $draft.customerTitle, limit: EventProfile.customerTitleLimit)
                    .accessibilityHint("Optional. Event Name is used when this is blank.")

                limitedTextField("Screen Subtitle", text: $draft.customerSubtitle, limit: EventProfile.customerSubtitleLimit)
                    .accessibilityHint("Optional. Subtitle or Host is used when this is blank.")

                limitedTextField("Welcome Message", text: $draft.customerWelcomeMessage, limit: EventProfile.customerMessageLimit, autocapitalization: .sentences)
                limitedTextField("Thank-you Message", text: $draft.customerThankYouMessage, limit: EventProfile.customerMessageLimit, autocapitalization: .sentences)

                Picker("Screen Theme", selection: $draft.customerTheme) {
                    ForEach(CustomerScreenTheme.allCases) { theme in
                        Text(theme.displayName).tag(theme)
                    }
                }

                Text(draft.customerTheme.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            DisclosureGroup("Preview Guest Screens") {
                CustomerExperiencePreviewView(profile: draft.normalized())
            }

            DisclosureGroup("Customize Printed Receipt (Optional)") {
                Toggle("Receipt Event Branding", isOn: $draft.isEnabled)
                    .accessibilityHint("When enabled, new customer receipts include the saved event text.")

                Text("Receipt Header")
                    .font(.headline)

                EventHeaderEditorView(profile: $draft, statusMessage: $statusMessage)

                Text("The optional event text uses Event Name, Subtitle / Host, Date and Location from Event Identity above.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                limitedTextField("Receipt Message", text: $draft.shortMessage, limit: EventProfile.shortMessageLimit, autocapitalization: .sentences)

                DisclosureGroup("Passport Format (Optional)") {
                    passportSettings
                }
            }

            DisclosureGroup("Preview Printed Receipt") {
                EventReceiptComposerPreview(profile: draft.normalized())
                    .padding(.vertical, 6)
            }

            Section {
                Button("Save Event Profile") {
                    saveDraft()
                }
                .disabled(!canSave)

                Button("Use Pocket Pixels Default") {
                    draft.isEnabled = false
                    draft.customerScreenEnabled = false
                    draft.customerTheme = .classic
                    EventProfileStore.save(draft)
                    savedProfile = draft.normalized()
                    statusMessage = "Screen and receipt branding are off for future sessions."
                }
            } footer: {
                Text(statusMessage)
            }
        }
        .navigationTitle("Edit Event")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { saveDraft() }
                    .fontWeight(.bold)
                    .disabled(!canSave || !hasUnsavedChanges)
            }
        }
    }

    @ViewBuilder
    private var passportSettings: some View {
        Text("Used only for Passport sessions while Receipt Event Branding is on. The passport cards replace the large receipt header, so the header, title and event text are never stacked.")
            .font(.caption)
            .foregroundStyle(.secondary)

        Picker("Passport Theme", selection: $draft.passport.theme) {
            ForEach(PassportTheme.allCases) { theme in
                Text(theme.displayName).tag(theme)
            }
        }
        Text(draft.passport.theme.summary)
            .font(.caption)
            .foregroundStyle(.secondary)

        Picker("Passport Title Area", selection: $draft.passport.titleSource) {
            ForEach(PassportTitleSource.allCases) { source in
                Text(source.displayName).tag(source)
            }
        }
        Text(draft.passport.titleSource.summary)
            .font(.caption)
            .foregroundStyle(.secondary)

        limitedTextField("Passport Title", text: $draft.passport.title, limit: PassportConfiguration.titleLimit, autocapitalization: .characters)
            .accessibilityHint("Shown with Pocket Passport branding. Leave blank for POCKET PASSPORT.")
        limitedTextField("Passport Subtitle (Optional)", text: $draft.passport.subtitle, limit: PassportConfiguration.subtitleLimit, autocapitalization: .characters)
        limitedTextField("Event Label (Optional)", text: $draft.passport.eventLabel, limit: PassportConfiguration.eventLabelLimit, autocapitalization: .characters)
            .accessibilityHint("Shown under the event name or header graphic, for example WEDDING PASSPORT. Defaults to EVENT PASSPORT.")

        Text("Check the result in Preview Printed Receipt with Passport selected.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var canSave: Bool {
        !draft.isEnabled || !draft.showEventTextBlock || !draft.normalized().eventName.isEmpty
    }

    private var hasUnsavedChanges: Bool {
        draft.normalized() != savedProfile.normalized()
    }

    private var eventModeBinding: Binding<Bool> {
        Binding(
            get: { draft.isEnabled && draft.customerScreenEnabled },
            set: { enabled in
                draft.isEnabled = enabled
                draft.customerScreenEnabled = enabled
            }
        )
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
            statusMessage = "Event Name is required when Event Branding is on."
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

private struct EventReceiptComposerPreview: View {
    let profile: EventProfile

    @State private var selectedFormat: BoothFormat = .duo
    @State private var previewImage: UIImage?
    @State private var previewReceipt: ComposedReceipt?
    @State private var previewError: String?
    @State private var renderTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Preview Format", selection: $selectedFormat) {
                ForEach(BoothFormat.allCases) { format in
                    Text(format.displayName).tag(format)
                }
            }
            .pickerStyle(.segmented)

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
        }
        .onAppear {
            scheduleRender()
        }
        .onChange(of: previewIdentity) { _, _ in
            scheduleRender()
        }
        .onDisappear {
            renderTask?.cancel()
        }
        .frame(maxWidth: .infinity)
    }

    private var previewIdentity: String {
        let normalized = profile.normalized()
        return [
            selectedFormat.rawValue,
            normalized.isEnabled.description,
            normalized.eventName,
            normalized.subtitle,
            normalized.includeEventDate.description,
            String(normalized.eventDate.timeIntervalSince1970),
            normalized.location,
            normalized.shortMessage,
            normalized.showEventTextBlock.description,
            normalized.receiptHeader.mode.rawValue,
            normalized.receiptHeader.assetIdentifier ?? "",
            String(normalized.receiptHeader.scale),
            String(normalized.receiptHeader.topSpacing),
            String(normalized.receiptHeader.bottomSpacing),
            normalized.receiptHeader.alignment.rawValue,
            normalized.receiptHeader.layoutMode.rawValue,
            String(normalized.receiptHeader.cropPositionX),
            String(normalized.receiptHeader.cropPositionY),
            String(normalized.receiptHeader.cropZoom),
            normalized.passport.theme.rawValue,
            normalized.passport.titleSource.rawValue,
            normalized.passport.title,
            normalized.passport.subtitle,
            normalized.passport.eventLabel
        ].joined(separator: "|")
    }

    @MainActor
    private func scheduleRender() {
        renderTask?.cancel()
        previewError = nil
        let profile = profile.normalized()
        let format = selectedFormat
        renderTask = Task {
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled else {
                return
            }

            do {
                let receipt = try await Self.makePreviewReceipt(profile: profile, format: format)
                guard let image = UIImage(data: receipt.imagePNGData) else {
                    throw ReceiptComposerError.renderFailed
                }
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    previewReceipt = receipt
                    previewImage = image
                }
            } catch is CancellationError {
                return
            } catch {
                await MainActor.run {
                    previewReceipt = nil
                    previewImage = nil
                    previewError = error.localizedDescription
                }
            }
        }
    }

    nonisolated private static func makePreviewReceipt(profile: EventProfile, format: BoothFormat) async throws -> ComposedReceipt {
        let worker = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            guard let galleryURL = URL(string: "https://pocket-pixels-gallery.pocketpixels-ceb.workers.dev/?g=event-preview") else {
                throw GalleryUploadError.invalidGalleryURL
            }

            let date = previewDate
            return try ReceiptComposer.compose(
                photos: makeSamplePhotos(count: format.photoCount),
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
