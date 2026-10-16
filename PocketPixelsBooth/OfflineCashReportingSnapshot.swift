import Foundation

/// Local evidence remains available independently of payments-server availability.
/// Legacy records without an environment stay visible but never become LIVE collections.
nonisolated struct OfflineCashReportingSnapshot: Sendable {
    let pending: [OfflineCashRecord]
    let unassigned: [OfflineCashRecord]
    let centavos: Int
    init(records: [OfflineCashRecord], eventID: String, environment: String, sessionIDs: Set<String>? = nil) throws {
        let scoped = records.filter {
            $0.eventID == eventID && ($0.syncState == .pending || $0.syncState == .syncing)
                && (sessionIDs == nil || sessionIDs!.contains($0.sessionID))
        }
        pending = scoped.filter { $0.environment == environment }
        unassigned = scoped.filter { $0.environment == nil }
        centavos = try pending.reduce(0) { total, record in
            let (sum, overflow) = total.addingReportingOverflow(record.totalCentavos)
            guard !overflow, record.totalCentavos >= 0 else { throw PaymentsAPIError.invalidResponse }
            return sum
        }
    }
}
