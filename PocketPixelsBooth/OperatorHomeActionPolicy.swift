import Foundation

/// Visibility only. Mutations still go through the lifecycle coordinator's authorization,
/// active-session, print recovery, publication and server-verification barriers.
nonisolated struct OperatorHomeActionPolicy {
    let status: EventOperatorStatus
    var showsPause: Bool {
        switch status { case .accepting, .regular, .unconfirmed: true; default: false }
    }
    var statusCheckIsPrimary: Bool {
        switch status { case .unconfirmed: true; default: false }
    }
}
