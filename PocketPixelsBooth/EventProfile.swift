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
            // New configurations start Studio-First. Saved profiles without a branding mode keep
            // their legacy header rendering until the operator chooses one.
            receiptHeader: .studioFirst,
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
        case (false, false): MadeToKeepBrand.standardModeSummary
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
        guard let activeProfile, !activeProfile.customerDisplayTitle.isEmpty else { return MadeToKeepBrand.shortName }
        return activeProfile.customerDisplayTitle
    }

    private var eventSubtitle: String { activeProfile?.customerDisplaySubtitle ?? "Receipt Photobooth" }
    private var welcomeText: String { activeProfile?.customerWelcomeMessage.nonEmpty ?? MadeToKeepBrand.tagline }
    private var thankYouText: String { activeProfile?.customerThankYouMessage.nonEmpty ?? "Thanks for making memories with us." }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

/// Read-only guest-receipt preview for branding screens, including unsaved drafts. Physical
/// display samples open in Sample Print Studio with a snapshot of this preview's design.
struct EventReceiptComposerPreview: View {
    let profile: EventProfile
    var printOptions: ReceiptPrintOptions = .default
    var showsSamplePrintLink = true
    var maximumPreviewWidth: CGFloat = 360

    @State private var selectedFormat: BoothFormat = .solo
    @State private var showsThermal = true
    @State private var normalImage: UIImage?
    @State private var previewImage: UIImage?
    @State private var previewReceipt: ComposedReceipt?
    @State private var previewError: String?
    @State private var renderTask: Task<Void, Never>?
    @State private var renderGeneration = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Preview Format", selection: $selectedFormat) {
                ForEach(BoothFormat.allCases) { format in
                    Text(format.displayName).tag(format)
                }
            }
            .pickerStyle(.segmented)

            Picker("Preview Type", selection: $showsThermal) {
                Text("Receipt").tag(false)
                Text("Thermal Print (1-bit)").tag(true)
            }
            .pickerStyle(.segmented)
            .accessibilityHint("Thermal shows the exact black-and-white dots the printer receives.")

            ForEach(ReceiptComposer.brandingResolution(for: profile).warnings, id: \.self) { warning in
                Label(warning.message, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }

            ScrollView(.vertical) {
                if let previewImage = showsThermal ? previewImage : normalImage {
                    Image(uiImage: previewImage)
                        .resizable()
                        .interpolation(showsThermal ? .none : .high)
                        .scaledToFit()
                        .frame(maxWidth: maximumPreviewWidth)
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

            if showsSamplePrintLink {
                NavigationLink {
                    SamplePrintStudioView(previewProfile: profile)
                } label: {
                    Label("Print Display Samples with Your Photos", systemImage: "printer.dotmatrix")
                }
                Text("Print this preview's design without applying it to guests or starting an event.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
        .onChange(of: printOptions) { _, _ in
            scheduleRender()
        }
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
        let printOptions = printOptions
        renderTask = Task {
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled else {
                return
            }

            do {
                let receipt = try await Self.makePreviewReceipt(profile: profile, format: format, printOptions: printOptions)
                guard let image = UIImage(data: receipt.imagePNGData) else {
                    throw ReceiptComposerError.renderFailed
                }
                let rasterized = try ThermalImageRasterizer.rasterize(image, purpose: .completeReceipt)
                guard let printerPreview = UIImage(data: rasterized.previewPNGData) else {
                    throw ThermalImageRasterizerError.renderFailed
                }
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard generation == renderGeneration else { return }
                    previewReceipt = receipt
                    normalImage = image
                    previewImage = printerPreview
                }
            } catch is CancellationError {
                return
            } catch {
                await MainActor.run {
                    guard generation == renderGeneration else { return }
                    previewReceipt = nil
                    previewImage = nil
                    normalImage = nil
                    previewError = error.localizedDescription
                }
            }
        }
    }

    /// Composes a guest-receipt preview in memory only. It never touches the print spooler,
    /// audit, archive or gallery queue.
    nonisolated static func makePreviewReceipt(
        profile: EventProfile,
        format: BoothFormat,
        printOptions: ReceiptPrintOptions = .default
    ) async throws -> ComposedReceipt {
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
                    : nil,
                printOptions: printOptions
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

    /// A soft tonal portrait scene: realistic midtones for judging thermal dithering, clearly a
    /// sample rather than a guest photograph.
    nonisolated static func makeSamplePhoto(index: Int) -> UIImage {
        let size = CGSize(width: 900, height: 1200)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cg = context.cgContext
            let space = CGColorSpaceCreateDeviceGray()
            let tones: [CGFloat] = [0.78, 0.62, 0.7, 0.55, 0.74, 0.66]
            let top = tones[index % tones.count]
            let background = CGGradient(colorsSpace: space, colors: [UIColor(white: top, alpha: 1).cgColor, UIColor(white: top - 0.32, alpha: 1).cgColor] as CFArray, locations: [0, 1])!
            cg.drawLinearGradient(background, start: .zero, end: CGPoint(x: size.width * 0.4, y: size.height), options: [])
            // Window light.
            let light = CGPoint(x: size.width * (0.25 + 0.12 * CGFloat(index % 3)), y: size.height * 0.22)
            let glow = CGGradient(colorsSpace: space, colors: [UIColor(white: 1, alpha: 0.85).cgColor, UIColor(white: 1, alpha: 0).cgColor] as CFArray, locations: [0, 1])!
            cg.drawRadialGradient(glow, startCenter: light, startRadius: 0, endCenter: light, endRadius: 380, options: [])
            // Silhouette: head and shoulders.
            let ink = UIColor(white: 0.18, alpha: 1)
            ink.setFill()
            let headSide: CGFloat = 250
            cg.fillEllipse(in: CGRect(x: size.width / 2 - headSide / 2, y: 430, width: headSide, height: headSide * 1.18))
            let shoulders = UIBezierPath(roundedRect: CGRect(x: size.width / 2 - 330, y: 760, width: 660, height: 600), cornerRadius: 260)
            shoulders.fill()
            let shade = CGGradient(colorsSpace: space, colors: [UIColor(white: 0.32, alpha: 0.6).cgColor, UIColor(white: 0.1, alpha: 0).cgColor] as CFArray, locations: [0, 1])!
            cg.drawRadialGradient(shade, startCenter: CGPoint(x: size.width / 2 - 40, y: 520), startRadius: 0, endCenter: CGPoint(x: size.width / 2, y: 560), endRadius: 160, options: [])
            let label = "SAMPLE \(index + 1)"
            let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 40, weight: .semibold), .foregroundColor: UIColor(white: 1, alpha: 0.85), .kern: 6]
            let labelSize = NSString(string: label).size(withAttributes: attributes)
            NSString(string: label).draw(at: CGPoint(x: (size.width - labelSize.width) / 2, y: size.height - 110), withAttributes: attributes)
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
