//
//  EventProfile.swift
//  PocketPixelsBooth
//

import Foundation
import SwiftUI

struct EventProfile: Codable, Equatable, Sendable {
    nonisolated static let eventNameLimit = 48
    nonisolated static let subtitleLimit = 60
    nonisolated static let shortMessageLimit = 80

    var isEnabled: Bool
    var eventName: String
    var subtitle: String
    var includeEventDate: Bool
    var eventDate: Date
    var shortMessage: String

    nonisolated static var pocketPixelsDefault: EventProfile {
        EventProfile(
            isEnabled: false,
            eventName: "",
            subtitle: "",
            includeEventDate: false,
            eventDate: Date(),
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
            shortMessage: Self.normalizedSingleLine(shortMessage, limit: Self.shortMessageLimit)
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

#if DEBUG
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

                limitedTextField("Short Message", text: $draft.shortMessage, limit: EventProfile.shortMessageLimit)
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

    private func limitedTextField(_ title: String, text: Binding<String>, limit: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField(title, text: text)
                .textInputAutocapitalization(.words)
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

            if let snapshot = profile.activeReceiptSnapshot {
                VStack(spacing: 8) {
                    Text(snapshot.eventName.uppercased())
                        .font(.system(size: 20, weight: .black))
                        .multilineTextAlignment(.center)

                    if !snapshot.subtitle.isEmpty {
                        Text(snapshot.subtitle.uppercased())
                            .font(.system(size: 12, weight: .semibold))
                            .multilineTextAlignment(.center)
                    }

                    if snapshot.includeEventDate {
                        Text(Self.eventDateFormatter.string(from: snapshot.eventDate).uppercased())
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .multilineTextAlignment(.center)
                    }

                    if !snapshot.shortMessage.isEmpty {
                        Text(snapshot.shortMessage)
                            .font(.system(size: 13, weight: .regular))
                            .multilineTextAlignment(.center)
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

    private static let eventDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = ReceiptComposer.sessionIdentifierTimeZone
        formatter.dateFormat = "MMM d, yyyy"
        return formatter
    }()
}
#endif
