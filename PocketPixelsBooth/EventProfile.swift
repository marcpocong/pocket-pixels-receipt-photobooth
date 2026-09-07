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

    var isEnabled: Bool
    var eventName: String
    var subtitle: String
    var includeEventDate: Bool
    var eventDate: Date
    var location: String
    var shortMessage: String

    nonisolated init(
        isEnabled: Bool,
        eventName: String,
        subtitle: String,
        includeEventDate: Bool,
        eventDate: Date,
        location: String = "",
        shortMessage: String
    ) {
        self.isEnabled = isEnabled
        self.eventName = eventName
        self.subtitle = subtitle
        self.includeEventDate = includeEventDate
        self.eventDate = eventDate
        self.location = location
        self.shortMessage = shortMessage
    }

    enum CodingKeys: String, CodingKey {
        case isEnabled
        case eventName
        case subtitle
        case includeEventDate
        case eventDate
        case location
        case shortMessage
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
    }

    nonisolated static var pocketPixelsDefault: EventProfile {
        EventProfile(
            isEnabled: false,
            eventName: "",
            subtitle: "",
            includeEventDate: false,
            eventDate: Date(),
            location: "",
            shortMessage: ""
        )
    }

    nonisolated var activeReceiptSnapshot: EventProfile? {
        let normalized = normalized()
        guard normalized.isEnabled, !normalized.eventName.isEmpty else {
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
            shortMessage: Self.normalizedSingleLine(shortMessage, limit: Self.shortMessageLimit)
        )
    }

    nonisolated var receiptBlockContent: EventReceiptBlockContent? {
        let snapshot = activeReceiptSnapshot
        guard let snapshot else {
            return nil
        }

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
    }
}

struct EventSetupView: View {
    @State private var draft = EventProfileStore.load()
    @State private var statusMessage = "Event profile loaded."

    var body: some View {
        Form {
            Section("Event Profile") {
                Toggle("Event Branding", isOn: $draft.isEnabled)
                    .accessibilityHint("When enabled, new customer receipts include the saved event text.")

                limitedTextField("Event Name", text: $draft.eventName, limit: EventProfile.eventNameLimit)
                    .accessibilityHint("Required when event branding is enabled.")

                limitedTextField("Subtitle / Host", text: $draft.subtitle, limit: EventProfile.subtitleLimit)

                Toggle("Include Event Date", isOn: $draft.includeEventDate)

                if draft.includeEventDate {
                    DatePicker("Event Date", selection: $draft.eventDate, displayedComponents: .date)
                }

                limitedTextField("Location", text: $draft.location, limit: EventProfile.locationLimit)
                    .accessibilityHint("Optional event location printed compactly with the date on new receipts.")

                limitedTextField("Short Message", text: $draft.shortMessage, limit: EventProfile.shortMessageLimit, autocapitalization: .sentences)
            }

            Section("Event Receipt Preview") {
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
                    EventProfileStore.save(draft)
                    statusMessage = "Event branding is off for future sessions."
                }
            } footer: {
                Text(statusMessage)
            }
        }
        .navigationTitle("Event Setup")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var canSave: Bool {
        !draft.isEnabled || !draft.normalized().eventName.isEmpty
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
        guard !normalized.isEnabled || !normalized.eventName.isEmpty else {
            statusMessage = "Event Name is required when Event Branding is on."
            return
        }

        draft = normalized
        EventProfileStore.save(normalized)
        statusMessage = normalized.isEnabled ? "Event profile saved for future sessions." : "Event branding is off for future sessions."
    }
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
            normalized.shortMessage
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
                eventProfile: profile.activeReceiptSnapshot
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
