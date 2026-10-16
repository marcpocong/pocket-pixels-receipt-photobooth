import Foundation
import CoreFoundation

nonisolated enum SavedDraftID: Codable, Hashable, Sendable {
    case design(String)
    case payment(binding: String, eventID: String)
    case sessionSelection, branding, prepaid, newEvent
}

nonisolated struct PaymentDraftBaseline: Codable, Equatable, Sendable {
    var name: String
    var venue: String
    var policy: ServerPolicyDraft
}

nonisolated struct SavedDraftChange: Identifiable, Equatable, Sendable {
    let id: String
    let label: String
    let before: String?
    let after: String
}

nonisolated struct SavedDraftEntry: Identifiable, Sendable {
    let id: SavedDraftID
    let eventName: String
    let category: String
    let changes: [SavedDraftChange]
    var notice: String? = nil
}

/// Presentation and comparison only. No payment, publishing, printing or camera operations.
@MainActor enum SavedDraftCatalog {
    static func entries(workspace: OperatorWorkspace, library: EventDesignLibrary,
                        profile: EventProfile = EventProfileStore.load(), prepaid: CommercialEventRun = CommercialEventRunStore.load(),
                        acceptance: SessionAcceptanceStore.State? = nil,
                        source: CommercialPolicySource = CommercialPolicySource.load(),
                        remote: [SavedDraftID: OperatorEventDetail] = [:]) -> [SavedDraftEntry] {
        let snapshot = workspace.snapshot
        let acceptance = acceptance ?? SessionAcceptanceStore.shared.state
        var result: [SavedDraftEntry] = []
        for (id, draft) in snapshot.designDrafts ?? [:] {
            let baseline = library.design(id: id)
            let changes = SavedDraftDiff.design(draft, baseline)
            if !changes.isEmpty {
                result.append(.init(id: .design(id), eventName: draft.displayName, category: "Receipt design", changes: changes,
                                    notice: baseline == nil ? "The saved design is unavailable. Your draft is preserved." : nil))
            }
        }
        for draft in snapshot.serverDrafts.values {
            let id = SavedDraftID.payment(binding: draft.serverBinding, eventID: draft.eventID)
            let fetched = remote[id]
            let baseline = fetched.flatMap { detail in detail.latestRevision.map {
                PaymentDraftBaseline(name: detail.event.name, venue: detail.event.venue, policy: ServerPolicyDraft(revision: $0))
            }} ?? draft.baseline
            let changes = SavedDraftDiff.payment(draft, baseline)
            let conflict = fetched.map { draft.conflicts(with: $0.event.version) } ?? false
            if !changes.isEmpty || conflict {
                let otherConnection = draft.serverBinding != workspace.serverBinding
                result.append(.init(id: id, eventName: draft.name.isEmpty ? "Untitled event" : draft.name, category: "Payment settings", changes: changes,
                                    notice: otherConnection ? "Saved for a different payments connection. Reconnect to that connection to edit."
                                    : conflict ? "Saved server settings changed. Review the current version before saving."
                                    : baseline == nil ? "Previous values are unavailable. Connect to compare saved settings." : nil))
            }
        }
        if let draft = snapshot.brandingDraft {
            let changes = SavedDraftDiff.profile(draft, profile)
            if !changes.isEmpty { result.append(.init(id: .branding, eventName: "Studio-wide", category: "Receipt branding", changes: changes)) }
        }
        if let draft = snapshot.prepaidDraft {
            let changes = SavedDraftDiff.prepaid(draft, prepaid)
            if !changes.isEmpty { result.append(.init(id: .prepaid, eventName: "Private / Prepaid", category: "Included copies and formats", changes: changes)) }
        }
        if let draft = snapshot.sessionSetup {
            let methods: GuestPaymentChoice? = draft.requestedMethods.flatMap { _ in
                guard let eventID = acceptance.eventID,
                      let policy = remote[.payment(binding: workspace.serverBinding, eventID: eventID)]?.activePolicy else { return nil }
                return GuestPaymentChoice(qrPhEnabled: policy.qrphEnabled, cashEnabled: policy.cashEnabled)
            }
            let baseline = OperatorSessionSetupDraft(mode: source, eventID: acceptance.eventID, serverBinding: workspace.serverBinding,
                                                      eventModeEnabled: library.appliedEventModeEnabled, designID: library.appliedEventID, requestedMethods: methods)
            let changes = SavedDraftDiff.selection(draft, baseline, library: library)
            let differentConnection = draft.mode == .serverManaged && draft.serverBinding != workspace.serverBinding
            if !changes.isEmpty || differentConnection {
                result.append(.init(id: .sessionSelection, eventName: library.design(id: draft.designID)?.displayName ?? "Session setup",
                                    category: "Session selection", changes: changes,
                                    notice: differentConnection ? "Saved for a different payments connection. Reconnect to that connection to edit." : nil))
            }
        }
        if !snapshot.newEventName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !snapshot.newEventVenue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result.append(.init(id: .newEvent, eventName: snapshot.newEventName.isEmpty ? "Unnamed new event" : snapshot.newEventName,
                                category: "Unfinished new event", changes: [
                                    .init(id: "name", label: "Event name", before: "Not entered", after: snapshot.newEventName.isEmpty ? "Not entered" : snapshot.newEventName),
                                    .init(id: "venue", label: "Venue", before: "Not entered", after: snapshot.newEventVenue.isEmpty ? "Not entered" : snapshot.newEventVenue)].filter { $0.before != $0.after }))
        }
        return result.sorted { ($0.eventName, $0.category) < ($1.eventName, $1.category) }
    }

    /// Removes only demonstrably equivalent records. Unknown baselines and conflicts are retained.
    static func removeEquivalentDrafts(workspace: OperatorWorkspace, library: EventDesignLibrary,
                                       remote: [SavedDraftID: OperatorEventDetail] = [:]) throws {
        let entries = entries(workspace: workspace, library: library, remote: remote)
        let remaining = Set(entries.map(\.id))
        for id in workspace.storedDraftIDs where !remaining.contains(id) {
            try workspace.discardDraft(id)
        }
    }
}

nonisolated enum SavedDraftDiff {
    static func design(_ draft: SavedEventDesign, _ baseline: SavedEventDesign?) -> [SavedDraftChange] {
        var draft = draft
        draft.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.venue = draft.venue.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.profile = comparisonProfile(draft.profile)
        let baseline = baseline.map { value in
            var normalized = value
            normalized.name = value.name.trimmingCharacters(in: .whitespacesAndNewlines)
            normalized.venue = value.venue.trimmingCharacters(in: .whitespacesAndNewlines)
            normalized.profile = comparisonProfile(value.profile)
            return normalized
        }
        return compare(values(draft, ignoring: ["id", "createdAt", "updatedAt", "serverEvents", "retiredServerEvents"]), baseline.map { values($0, ignoring: ["id", "createdAt", "updatedAt", "serverEvents", "retiredServerEvents"]) })
    }
    static func profile(_ draft: EventProfile, _ baseline: EventProfile) -> [SavedDraftChange] {
        compare(values(comparisonProfile(draft)), values(comparisonProfile(baseline)))
    }
    private static func comparisonProfile(_ profile: EventProfile) -> EventProfile {
        var normalized = profile.normalized()
        normalized.receiptHeader.horizontalPosition = normalized.receiptHeader.effectiveHorizontalPosition
        normalized.receiptHeader.fillHeightRatio = normalized.receiptHeader.effectiveFillHeightRatio
        normalized.receiptHeader.showsStudioCredit = normalized.receiptHeader.showsStudioCredit ?? false
        return normalized
    }
    static func payment(_ draft: OperatorServerSetupDraft, _ baseline: PaymentDraftBaseline?) -> [SavedDraftChange] {
        var after = policyValues(draft.policy)
        after["name"] = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        after["venue"] = draft.venue.trimmingCharacters(in: .whitespacesAndNewlines)
        let before = baseline.map { value -> [String: String] in
            var fields = policyValues(value.policy)
            fields["name"] = value.name.trimmingCharacters(in: .whitespacesAndNewlines)
            fields["venue"] = value.venue.trimmingCharacters(in: .whitespacesAndNewlines)
            return fields
        }
        return compare(after, before)
    }
    static func prepaid(_ draft: CommercialEventRun, _ baseline: CommercialEventRun) -> [SavedDraftChange] {
        // Lifecycle/revision metadata is managed by admission, not an operator's copy-setting edit.
        compare(values(draft.activePolicy, ignoring: ["revisionID", "revision"]), values(baseline.activePolicy, ignoring: ["revisionID", "revision"]))
    }
    static func selection(_ draft: OperatorSessionSetupDraft, _ baseline: OperatorSessionSetupDraft, library: EventDesignLibrary) -> [SavedDraftChange] {
        func fields(_ value: OperatorSessionSetupDraft) -> [String: String] {
            var fields = ["mode": value.mode == .serverManaged ? "Pay per print" : "Private / Prepaid",
                          "eventModeEnabled": value.eventModeEnabled == true ? "On" : "Off"]
            if value.eventModeEnabled == true { fields["designID"] = library.design(id: value.designID)?.displayName ?? "Unavailable event" }
            if let methods = value.requestedMethods { fields["requestedMethods"] = methods.title }
            return fields
        }
        var after = fields(draft), before = fields(baseline)
        if draft.mode == .serverManaged && draft.eventID != baseline.eventID {
            after["paidEvent"] = library.events.first { $0.serverEventID(binding: draft.serverBinding) == draft.eventID }?.displayName ?? "Selected paid event"
            before["paidEvent"] = library.events.first { $0.serverEventID(binding: baseline.serverBinding) == baseline.eventID }?.displayName ?? "No paid event selected"
        }
        return compare(after, before)
    }
    static func policyValues(_ policy: ServerPolicyDraft) -> [String: String] {
        var fields = ["commercialMode": policy.commercialMode == .payPerPrint ? "Pay per print" : "Private / Prepaid",
                      "priceText": policy.unitPriceCentavos.map { PHPPriceFormatter.string(centavos: $0) } ?? policy.priceText,
                      "maxCopies": String(policy.maxCopies), "defaultCopies": String(policy.defaultCopies),
                      "qrPhEnabled": policy.qrPhEnabled ? "On" : "Off", "cashEnabled": policy.cashEnabled ? "On" : "Off",
                      "prepaidGuestCopyChoice": policy.prepaidGuestCopyChoice ? "On" : "Off",
                      "supportedFormats": formats(Array(policy.supportedFormats)), "offlineCashEnabled": policy.offlineCashEnabled ? "On" : "Off"]
        if policy.offlineCashEnabled { fields["offlineValidUntil"] = policy.offlineValidUntil.formatted(date: .abbreviated, time: .shortened) }
        return fields
    }
    static func compare(_ after: [String: String], _ before: [String: String]?) -> [SavedDraftChange] {
        Set(after.keys).union(before?.keys.map { $0 } ?? []).sorted().compactMap { key in
            let next = after[key] ?? "Not set", previous = before?[key] ?? (before == nil ? nil : "Not set")
            guard next != previous else { return nil }
            if key.hasSuffix("assetIdentifier") {
                return .init(id: key, label: label(key), before: previous.map { $0 == "Not set" ? "No artwork" : "Saved artwork" }, after: next == "Not set" ? "No artwork" : "Different artwork selected")
            }
            return .init(id: key, label: label(key), before: previous.map { $0.isEmpty ? "Not set" : $0 }, after: next.isEmpty ? "Not set" : next)
        }
    }
    static func values<T: Encodable>(_ value: T, ignoring: Set<String> = []) -> [String: String] {
        guard let data = try? JSONEncoder().encode(value), let object = try? JSONSerialization.jsonObject(with: data) else { return [:] }
        var result: [String: String] = [:]
        func flatten(_ object: Any, path: String) {
            if let dictionary = object as? [String: Any] {
                for (key, value) in dictionary where !ignoring.contains(key) { flatten(value, path: path.isEmpty ? key : path + "." + key) }
            } else if let array = object as? [String] {
                result[path] = path.hasSuffix("supportedFormats") || path.hasSuffix("supportedFormatRawValues") ? formats(array) : array.sorted().joined(separator: ", ")
            } else if let number = object as? NSNumber {
                if CFGetTypeID(number) == CFBooleanGetTypeID() { result[path] = number.boolValue ? "On" : "Off" }
                else if path.hasSuffix("scale") || path.hasSuffix("fillHeightRatio") { result[path] = "\(Int((number.doubleValue * 100).rounded()))%" }
                else if path.hasSuffix("topSpacing") || path.hasSuffix("bottomSpacing") { result[path] = "\(number.intValue) dots" }
                else if path.hasSuffix("unitPriceCentavos") { result[path] = PHPPriceFormatter.string(centavos: number.intValue) }
                else if path.hasSuffix("eventDate") { result[path] = Date(timeIntervalSinceReferenceDate: number.doubleValue).formatted(date: .abbreviated, time: .omitted) }
                else if path.hasSuffix("offlineValidUntil") { result[path] = Date(timeIntervalSinceReferenceDate: number.doubleValue).formatted(date: .abbreviated, time: .shortened) }
                else { result[path] = number.stringValue }
            } else if let text = object as? String {
                result[path] = readable(text)
            } else { result[path] = "Not set" }
        }
        flatten(object, path: "")
        return result
    }
    private static func formats(_ values: [String]) -> String {
        Set(values.map { $0 == "photoPass" ? "Photo Pass" : BoothFormat(rawValue: $0)?.displayName ?? readable($0) }).sorted().joined(separator: ", ")
    }
    private static func readable(_ value: String) -> String {
        // Preserve user-entered text; only known stored enum spellings need display conversion.
        switch value {
        case "pocketPixelsDefault": return "Made to Keep standard"
        case "customEventHeader": return "Event artwork"
        case "coBranded": return "Co-Branded"
        case "studioFirst": return "Studio First"
        case "eventFirst": return "Event First"
        case "PAY_PER_PRINT": return "Pay per print"
        case "PRIVATE_PREPAID": return "Private / Prepaid"
        default: return value
        }
    }
    private static func label(_ key: String) -> String {
        let overrides = ["name": "Event name", "venue": "Venue", "priceText": "Price per copy", "maxCopies": "Maximum copies",
                         "defaultCopies": "Default copies", "qrPhEnabled": "QR Ph", "cashEnabled": "Cash", "supportedFormats": "Formats",
                         "profile.receiptHeader.scale": "Logo size", "profile.receiptHeader.topSpacing": "Space above logo",
                         "profile.receiptHeader.bottomSpacing": "Space below logo", "profile.receiptHeader.assetIdentifier": "Logo artwork",
                         "designID": "Selected event", "eventModeEnabled": "Event Mode", "mode": "Session mode",
                         "requestedMethods": "Payment methods", "paidEvent": "Paid event", "personalizeReceipt": "Personalize receipt",
                         "guestScreensEnabled": "Custom welcome screens"]
        if let label = overrides[key] { return label }
        return key.replacingOccurrences(of: "profile.", with: "").replacingOccurrences(of: ".", with: " · ")
            .replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression).capitalized
    }
}
