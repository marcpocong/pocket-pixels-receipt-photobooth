import Foundation

nonisolated enum OperatorSessionFilter {
    static func apply(_ sessions: [EventRunSession], query: String, format: String, status: String) -> [EventRunSession] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return sessions.filter { session in
            let formatName = BoothFormat(rawValue: session.format)?.displayName ?? session.format
            let matchesQuery = needle.isEmpty || session.sessionID.localizedCaseInsensitiveContains(needle) || formatName.localizedCaseInsensitiveContains(needle)
            let matchesStatus: Bool = switch status {
            case "completed": session.completedAt != nil
            case "waiting": session.galleryPreparedAt != nil && session.galleryVerifiedAt == nil
            case "review": session.printOutcomes.values.contains { $0 == "uncertain" || $0 == "inFlight" }
            default: true
            }
            return matchesQuery && (format == "all" || session.format == format) && matchesStatus
        }.sorted { $0.createdAt > $1.createdAt }
    }
}
