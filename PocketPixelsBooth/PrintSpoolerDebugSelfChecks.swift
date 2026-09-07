//
//  PrintSpoolerDebugSelfChecks.swift
//  PocketPixelsBooth
//

import Foundation

#if DEBUG
enum PrintSpoolerDebugSelfChecks {
    struct Report: Sendable {
        let passed: Bool
        let checkedInvariants: Int
        let failures: [String]

        var summary: String {
            passed
                ? "Print spooler self-check passed (\(checkedInvariants) invariants)."
                : "Print spooler self-check failed: \(failures.joined(separator: "; "))"
        }
    }

    static func run() -> Report {
        var model = Model()
        var failures: [String] = []
        var checked = 0

        func check(_ condition: Bool, _ message: String) {
            checked += 1
            if !condition {
                failures.append(message)
            }
        }

        let first = UUID()
        let second = UUID()
        check(model.enqueue(first), "first enqueue rejected")
        check(model.enqueue(second), "second enqueue rejected")
        check(model.maximumActiveJobs == 0, "queued job became active early")
        check(model.startNext() == first, "FIFO start for first job failed")
        check(model.maximumActiveJobs == 1, "active job count exceeded one")
        check(!model.finish(second, bytesStarted: false, success: true), "stale completion mutated active job")
        check(model.finish(first, bytesStarted: true, success: true), "first job did not finish")
        check(model.startNext() == second, "FIFO start for second job failed")
        check(model.finish(second, bytesStarted: true, success: false), "second job did not finish")
        check(model.recoveryRequired, "post-byte failure did not lock recovery")
        check(!model.enqueue(UUID()), "recovery lockout accepted a new job")
        model.confirmRecovery()
        check(model.enqueue(UUID()), "enqueue after recovery confirmation failed")

        model = Model()
        let batch = (0..<100).map { _ in UUID() }
        for id in batch {
            _ = model.enqueue(id)
        }
        var order: [UUID] = []
        while let id = model.startNext() {
            order.append(id)
            _ = model.finish(id, bytesStarted: true, success: true)
        }
        check(order == batch, "100-job FIFO order changed")
        check(model.maximumActiveJobs == 1, "100-job run exceeded single active job")

        return Report(passed: failures.isEmpty, checkedInvariants: checked, failures: failures)
    }

    private struct Model {
        private var queue: [UUID] = []
        private var active: UUID?
        private(set) var recoveryRequired = false
        private(set) var maximumActiveJobs = 0

        mutating func enqueue(_ id: UUID) -> Bool {
            guard !recoveryRequired else {
                return false
            }
            queue.append(id)
            return true
        }

        mutating func startNext() -> UUID? {
            guard active == nil, !queue.isEmpty, !recoveryRequired else {
                return nil
            }
            active = queue.removeFirst()
            maximumActiveJobs = max(maximumActiveJobs, active == nil ? 0 : 1)
            return active
        }

        mutating func finish(_ id: UUID, bytesStarted: Bool, success: Bool) -> Bool {
            guard active == id else {
                return false
            }
            active = nil
            if !success && bytesStarted {
                recoveryRequired = true
                queue.removeAll()
            }
            return true
        }

        mutating func confirmRecovery() {
            recoveryRequired = false
        }
    }
}
#endif
