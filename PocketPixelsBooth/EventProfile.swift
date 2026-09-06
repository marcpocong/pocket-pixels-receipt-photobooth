//
//  EventProfile.swift
//  PocketPixelsBooth
//

import Foundation
import SwiftUI

struct EventProfile: Codable, Equatable, Sendable {
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

    init(
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
                EventReceiptBlockPreview(profile: draft.normalized())
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

private struct EventReceiptBlockPreview: View {
    let profile: EventProfile

    var body: some View {
        VStack(spacing: 10) {
            Text("POCKET PIXELS")
                .font(.system(size: 16, weight: .bold))
                .tracking(1.2)

            Text("RECEIPT PHOTOBOOTH")
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.8)

            Divider()

            if let content = profile.receiptBlockContent {
                VStack(spacing: 5) {
                    Text(content.eyebrow)
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .tracking(1.0)
                        .foregroundStyle(.secondary)

                    Text(content.eventName)
                        .font(.system(size: 21, weight: .semibold, design: .serif))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)

                    if !content.subtitle.isEmpty {
                        Text(content.subtitle)
                            .font(.system(size: 12, weight: .semibold))
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                    }

                    if !content.metadata.isEmpty {
                        Text(content.metadata)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                    }

                    if !content.message.isEmpty {
                        Text(content.message)
                            .font(.system(size: 12, weight: .regular))
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                    }
                }
                .foregroundStyle(.primary)

                Divider()
            } else {
                Text("Pocket Pixels default receipt")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .background(Color.white)
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.24), lineWidth: 1)
        }
    }

}
