//
//  BluetoothPrinterJobLifecycle.swift
//  PocketPixelsBooth
//

import Foundation

enum BluetoothPrinterJobLifecycleDecision: Equatable {
    case accepted
    case duplicate
    case stale(activeJobID: UInt64?)
}

struct BluetoothPrinterJobLifecycle: Equatable {
    private(set) var activeJobID: UInt64?
    private(set) var transportCompletionScheduledJobID: UInt64?
    private var nextJobID: UInt64 = 1

    mutating func beginJob() -> UInt64? {
        guard activeJobID == nil else {
            return nil
        }

        let jobID = nextJobID
        nextJobID += 1
        activeJobID = jobID
        transportCompletionScheduledJobID = nil
        return jobID
    }

    mutating func scheduleTransportCompletion(expectedJobID: UInt64) -> BluetoothPrinterJobLifecycleDecision {
        guard activeJobID == expectedJobID else {
            return .stale(activeJobID: activeJobID)
        }

        guard transportCompletionScheduledJobID != expectedJobID else {
            return .duplicate
        }

        transportCompletionScheduledJobID = expectedJobID
        return .accepted
    }

    mutating func finishJob(expectedJobID: UInt64) -> BluetoothPrinterJobLifecycleDecision {
        guard activeJobID == expectedJobID else {
            return .stale(activeJobID: activeJobID)
        }

        activeJobID = nil
        transportCompletionScheduledJobID = nil
        return .accepted
    }

    mutating func clearInactiveTasks() {
        guard activeJobID == nil else {
            return
        }

        transportCompletionScheduledJobID = nil
    }
}

nonisolated enum PrinterReconnectPolicy {
    enum Action { case keepHealthyConnection, joinExistingAttempt, waitForPhysicalJob, reconnect }
    static func action(ready: Bool, connecting: Bool, transmitting: Bool) -> Action {
        if transmitting { return .waitForPhysicalJob }
        if ready { return .keepHealthyConnection }
        if connecting { return .joinExistingAttempt }
        return .reconnect
    }
}
