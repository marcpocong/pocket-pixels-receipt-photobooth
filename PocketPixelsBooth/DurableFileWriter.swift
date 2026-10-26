//
//  DurableFileWriter.swift
//  PocketPixelsBooth
//

import Darwin
import Foundation

/// Writes small, durability-critical files (recovery checkpoint, archive print payload).
///
/// The data goes to a temporary sibling file, is flushed to stable storage (`fsync` plus
/// `F_FULLFSYNC`), and is then atomically renamed over the destination. A reader therefore sees
/// either the previous complete file or the new complete file, never a partial one, and a
/// successful return means the bytes survive app termination and power loss.
nonisolated enum DurableFileWriter {
    enum WriteError: Error, LocalizedError {
        case createFailed(String)
        case renameFailed(Int32)

        var errorDescription: String? {
            switch self {
            case .createFailed(let path): "Could not create \(path)."
            case .renameFailed(let code): "Could not finalize file (errno \(code))."
            }
        }
    }

    nonisolated static func write(_ data: Data, to url: URL, fileManager: FileManager = .default) throws {
        let temporaryURL = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        guard fileManager.createFile(atPath: temporaryURL.path, contents: nil) else {
            throw WriteError.createFailed(temporaryURL.lastPathComponent)
        }
        do {
            let handle = try FileHandle(forWritingTo: temporaryURL)
            do {
                try handle.write(contentsOf: data)
                try handle.synchronize()
                // Also ask the storage device to flush its own cache (best effort).
                _ = fcntl(handle.fileDescriptor, F_FULLFSYNC)
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
            guard rename(temporaryURL.path, url.path) == 0 else {
                throw WriteError.renameFailed(errno)
            }
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }
    }
}

/// Configuration snapshots are encoded and flushed off MainActor. The owning store commits
/// its in-memory state only after this returns; recovery and admission remain fail-closed.
nonisolated struct DurableJSONWrite<Value: Encodable & Sendable>: @unchecked Sendable {
    let value: Value
    let file: URL
    let write: (Data, URL) throws -> Void
    func perform() throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try write(JSONEncoder().encode(value), file)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete, .posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
