//
//  PrinterDiscoveryService.swift
//  PocketPixelsBooth
//

import Darwin
import Foundation
import Network

struct PrinterCandidate: Identifiable, Equatable, Sendable {
    let host: String
    let port: UInt16
    let isSavedPrinter: Bool

    nonisolated var id: String {
        "\(host):\(port)"
    }
}

struct PrinterDiscoveryNetwork: Equatable, Sendable {
    let interfaceName: String
    let address: String
    let netmask: String
}

enum PrinterDiscoveryState: Equatable, Sendable {
    case idle
    case determiningNetwork
    case checkingSavedPrinter
    case scanning(completed: Int, total: Int, network: PrinterDiscoveryNetwork)
    case found([PrinterCandidate])
    case notFound(String)
    case failed(String)

    nonisolated var isSearching: Bool {
        switch self {
        case .determiningNetwork, .checkingSavedPrinter, .scanning:
            true
        case .idle, .found, .notFound, .failed:
            false
        }
    }
}

final class PrinterDiscoveryService: @unchecked Sendable {
    nonisolated static let maximumCandidateHosts = 254
    nonisolated static let maximumConcurrentProbes = 16
    nonisolated static let perHostTimeout: TimeInterval = 0.5

    typealias StateHandler = @MainActor (PrinterDiscoveryState) -> Void

    nonisolated private let lock = NSLock()
    nonisolated private let probeQueue = DispatchQueue(label: "com.pocketpixels.printer-discovery.probe", attributes: .concurrent)
    nonisolated(unsafe) private var activeConnections: [UUID: NWConnection] = [:]
    nonisolated(unsafe) private var isCancelled = false

    nonisolated func discover(
        savedHost: String,
        port: UInt16,
        onStateChange: @escaping StateHandler
    ) async -> PrinterDiscoveryState {
        cancel()
        resetCancellation()

        await onStateChange(.checkingSavedPrinter)

        let trimmedSavedHost = savedHost.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSavedHost.isEmpty,
           await probe(host: trimmedSavedHost, port: port) {
            let state = PrinterDiscoveryState.found([
                PrinterCandidate(host: trimmedSavedHost, port: port, isSavedPrinter: true)
            ])
            await onStateChange(state)
            return state
        }

        guard !isDiscoveryCancelled else {
            return .idle
        }

        await onStateChange(.determiningNetwork)

        guard let network = Self.currentLocalIPv4Network() else {
            let state = PrinterDiscoveryState.failed("Could not determine a usable local IPv4 Wi-Fi network. Printer discovery should be validated on a physical iPad connected to the same network as the printer.")
            await onStateChange(state)
            return state
        }

        let candidateHosts = Self.candidateHosts(
            address: network.address,
            netmask: network.netmask,
            excluding: network.address,
            maximumHosts: Self.maximumCandidateHosts
        )

        guard !candidateHosts.isEmpty else {
            let state = PrinterDiscoveryState.failed("Could not derive a safe local printer search range from the current IPv4 network.")
            await onStateChange(state)
            return state
        }

        let total = candidateHosts.count
        await onStateChange(.scanning(completed: 0, total: total, network: network))

        var foundCandidates: [PrinterCandidate] = []
        var completed = 0
        var nextIndex = 0

        await withTaskGroup(of: (String, Bool).self) { group in
            func addNextProbeIfNeeded() {
                guard !isDiscoveryCancelled, nextIndex < candidateHosts.count else {
                    return
                }

                let host = candidateHosts[nextIndex]
                nextIndex += 1
                group.addTask { [weak self] in
                    guard let self else {
                        return (host, false)
                    }

                    let didConnect = await self.probe(host: host, port: port)
                    return (host, didConnect)
                }
            }

            for _ in 0..<min(Self.maximumConcurrentProbes, total) {
                addNextProbeIfNeeded()
            }

            while let result = await group.next() {
                completed += 1

                if result.1 {
                    foundCandidates.append(PrinterCandidate(host: result.0, port: port, isSavedPrinter: false))
                }

                if isDiscoveryCancelled {
                    group.cancelAll()
                    break
                }

                await onStateChange(.scanning(completed: completed, total: total, network: network))
                addNextProbeIfNeeded()
            }
        }

        guard !isDiscoveryCancelled else {
            return .idle
        }

        let sortedCandidates = foundCandidates.sorted { $0.host.localizedStandardCompare($1.host) == .orderedAscending }
        let finalState: PrinterDiscoveryState
        if sortedCandidates.isEmpty {
            finalState = .notFound("No reachable printer was found on this network. Make sure the printer is powered on, the iPad and printer are connected to the same network, and the network allows connected devices to communicate with each other.")
        } else {
            finalState = .found(sortedCandidates)
        }

        await onStateChange(finalState)
        return finalState
    }

    nonisolated func cancel() {
        let connections: [NWConnection]
        lock.lock()
        isCancelled = true
        connections = Array(activeConnections.values)
        activeConnections.removeAll()
        lock.unlock()

        for connection in connections {
            connection.stateUpdateHandler = nil
            connection.cancel()
        }
    }

    nonisolated static func candidateHosts(
        address: String,
        netmask: String,
        excluding excludedAddress: String,
        maximumHosts: Int = maximumCandidateHosts
    ) -> [String] {
        guard let addressValue = ipv4Value(address),
              let netmaskValue = ipv4Value(netmask),
              maximumHosts > 0 else {
            return []
        }

        let network = addressValue & netmaskValue
        let broadcast = network | ~netmaskValue
        guard broadcast > network + 1 else {
            return []
        }

        let availableHostCount = Int(min(UInt64(broadcast - network - 1), UInt64(Int.max)))
        let rangeStart: UInt32
        let rangeEnd: UInt32

        if availableHostCount <= maximumHosts {
            rangeStart = network + 1
            rangeEnd = broadcast - 1
        } else {
            let cappedNetwork = addressValue & 0xFFFF_FF00
            rangeStart = cappedNetwork + 1
            rangeEnd = min(cappedNetwork + UInt32(maximumHosts), broadcast - 1)
        }

        guard rangeEnd >= rangeStart else {
            return []
        }

        return (rangeStart...rangeEnd)
            .filter { $0 != addressValue }
            .map(ipv4String)
            .filter { $0 != excludedAddress }
    }

    nonisolated static func ipv4Value(_ address: String) -> UInt32? {
        let parts = address.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else {
            return nil
        }

        var value: UInt32 = 0
        for part in parts {
            guard let octet = UInt8(part) else {
                return nil
            }

            value = (value << 8) | UInt32(octet)
        }

        return value
    }

    nonisolated static func ipv4String(_ value: UInt32) -> String {
        [
            String((value >> 24) & 0xFF),
            String((value >> 16) & 0xFF),
            String((value >> 8) & 0xFF),
            String(value & 0xFF)
        ].joined(separator: ".")
    }

    nonisolated static func currentLocalIPv4Network() -> PrinterDiscoveryNetwork? {
        localIPv4Networks().first
    }

    nonisolated static func localIPv4Networks() -> [PrinterDiscoveryNetwork] {
        var interfacePointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfacePointer) == 0, let firstInterface = interfacePointer else {
            return []
        }

        defer {
            freeifaddrs(interfacePointer)
        }

        var networks: [PrinterDiscoveryNetwork] = []
        var pointer: UnsafeMutablePointer<ifaddrs>? = firstInterface

        while let currentPointer = pointer {
            defer {
                pointer = currentPointer.pointee.ifa_next
            }

            let interface = currentPointer.pointee
            guard let addressPointer = interface.ifa_addr,
                  let netmaskPointer = interface.ifa_netmask,
                  addressPointer.pointee.sa_family == UInt8(AF_INET) else {
                continue
            }

            let flags = Int32(interface.ifa_flags)
            guard (flags & IFF_UP) != 0,
                  (flags & IFF_LOOPBACK) == 0 else {
                continue
            }

            let interfaceName = String(cString: interface.ifa_name)
            guard isPreferredLocalInterface(interfaceName),
                  let address = ipv4String(from: addressPointer),
                  let netmask = ipv4String(from: netmaskPointer),
                  !address.hasPrefix("169.254.") else {
                continue
            }

            networks.append(
                PrinterDiscoveryNetwork(
                    interfaceName: interfaceName,
                    address: address,
                    netmask: netmask
                )
            )
        }

        return networks.sorted { lhs, rhs in
            interfacePriority(lhs.interfaceName) < interfacePriority(rhs.interfaceName)
        }
    }

    nonisolated private static func ipv4String(from pointer: UnsafePointer<sockaddr>) -> String? {
        var address = pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sockaddr in
            sockaddr.pointee.sin_addr
        }
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))

        guard inet_ntop(AF_INET, &address, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else {
            return nil
        }

        return String(cString: buffer)
    }

    nonisolated private static func isPreferredLocalInterface(_ name: String) -> Bool {
        guard !name.hasPrefix("lo"),
              !name.hasPrefix("pdp_ip"),
              !name.hasPrefix("utun"),
              !name.hasPrefix("ipsec"),
              !name.hasPrefix("awdl"),
              !name.hasPrefix("llw") else {
            return false
        }

        return name.hasPrefix("en") || name.hasPrefix("bridge")
    }

    nonisolated private static func interfacePriority(_ name: String) -> Int {
        if name == "en0" {
            return 0
        }

        if name.hasPrefix("en") {
            return 1
        }

        if name.hasPrefix("bridge") {
            return 2
        }

        return 3
    }

    nonisolated private var isDiscoveryCancelled: Bool {
        lock.lock()
        let value = isCancelled
        lock.unlock()
        return value
    }

    nonisolated private func resetCancellation() {
        lock.lock()
        isCancelled = false
        lock.unlock()
    }

    nonisolated private func probe(host: String, port: UInt16) async -> Bool {
        guard !isDiscoveryCancelled,
              let endpointPort = NWEndpoint.Port(rawValue: port) else {
            return false
        }

        return await withCheckedContinuation { continuation in
            let id = UUID()
            let connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: .tcp)
            let completionState = PrinterDiscoveryProbeCompletionState()

            @Sendable
            func finish(_ result: Bool) {
                guard completionState.markCompleted() else {
                    return
                }

                connection.stateUpdateHandler = nil
                connection.cancel()
                self.removeConnection(id)
                continuation.resume(returning: result)
            }

            storeConnection(connection, id: id)

            let timeout = DispatchWorkItem {
                finish(false)
            }
            probeQueue.asyncAfter(deadline: .now() + Self.perHostTimeout, execute: timeout)

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    finish(true)
                case .failed, .cancelled:
                    finish(false)
                case .setup, .waiting, .preparing:
                    break
                @unknown default:
                    break
                }
            }

            connection.start(queue: probeQueue)
        }
    }

    nonisolated private func storeConnection(_ connection: NWConnection, id: UUID) {
        lock.lock()
        if isCancelled {
            lock.unlock()
            connection.cancel()
            return
        }

        activeConnections[id] = connection
        lock.unlock()
    }

    nonisolated private func removeConnection(_ id: UUID) {
        lock.lock()
        activeConnections[id] = nil
        lock.unlock()
    }
}

nonisolated private final class PrinterDiscoveryProbeCompletionState: @unchecked Sendable {
    nonisolated private let lock = NSLock()
    nonisolated(unsafe) private var completed = false

    nonisolated func markCompleted() -> Bool {
        lock.lock()
        defer {
            lock.unlock()
        }

        guard !completed else {
            return false
        }

        completed = true
        return true
    }
}
