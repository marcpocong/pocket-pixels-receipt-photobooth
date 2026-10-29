import Foundation
import PhotosUI
import SwiftUI

/// One import path for event artwork from Photos or Files. Validation and storage stay in
/// EventArtwork / EventHeaderAssetStore; every import creates a new immutable identifier, so
/// frozen sessions and reprints keep resolving the artwork they started with. Importing never
/// changes what guests receive.
enum EventArtworkImporter {
    nonisolated static let timeout: Duration = .seconds(60)

    struct Imported: @unchecked Sendable {
        let identifier: String
        let artwork: EventArtwork
    }

    enum ImportError: LocalizedError {
        case timedOut
        case noFile

        var errorDescription: String? {
            switch self {
            case .timedOut: "The file took too long to load. Check the connection for iCloud photos and try again."
            case .noFile: "No file was selected."
            }
        }
    }

    static func importPhoto(_ item: PhotosPickerItem) async throws -> Imported {
        let data = try await withTimeout {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                throw EventHeaderAssetStoreError.unsupportedOrCorruptImage
            }
            return data
        }
        try Task.checkCancellation()
        return try await importData(data)
    }

    static func importFile(_ result: Result<[URL], Error>) async throws -> Imported {
        guard let url = try result.get().first else { throw ImportError.noFile }
        let data = try await withTimeout {
            try await Task.detached(priority: .userInitiated) {
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                guard size <= EventArtwork.maximumFileSize else { throw EventArtworkError.fileTooLarge }
                return try Data(contentsOf: url)
            }.value
        }
        try Task.checkCancellation()
        return try await importData(data)
    }

    /// Validates (PNG, JPEG or single-page unencrypted PDF, at most 25 MB), stores and reloads
    /// the artwork exactly as receipts will read it.
    nonisolated static func importData(_ data: Data, store: @escaping @Sendable () throws -> EventHeaderAssetStore = { try EventHeaderAssetStore() }) async throws -> Imported {
        try Task.checkCancellation()
        let result = try await Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let store = try store()
            let identifier = try store.importArtworkData(data)
            guard let artwork = store.loadArtwork(identifier: identifier) else { throw EventHeaderAssetStoreError.encodingFailed }
            try Task.checkCancellation()
            return Imported(identifier: identifier, artwork: artwork)
        }.value
        try Task.checkCancellation()
        return result
    }

    private static func withTimeout<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw ImportError.timedOut
            }
            defer { group.cancelAll() }
            guard let value = try await group.next() else { throw ImportError.timedOut }
            return value
        }
    }
}

/// Owned by Receipt Studio, so changing editing sections does not abandon the selected file.
/// SwiftUI's session-level task owns execution; the generation gate also protects against
/// Photos/File providers that finish after cancellation. Immutable stored files are never deleted.
@MainActor @Observable final class ReceiptArtworkImportSession {
    private(set) var requestID: UUID?
    private(set) var isImporting = false
    private(set) var errorMessage: String?
    private var operation: (() async throws -> EventArtworkImporter.Imported)?
    private var isClosed = false

    @discardableResult
    func begin(_ operation: @escaping () async throws -> EventArtworkImporter.Imported) -> Bool {
        guard !isClosed, !isImporting else { return false }
        self.operation = operation
        errorMessage = nil
        isImporting = true
        requestID = UUID()
        return true
    }

    func process(apply: (EventArtworkImporter.Imported) -> Void) async {
        guard let id = requestID, let operation, isImporting, !isClosed else { return }
        self.operation = nil
        do {
            let result = try await operation()
            try Task.checkCancellation()
            guard !isClosed, requestID == id else { return }
            apply(result)
        } catch {
            guard !isClosed, requestID == id else { return }
            if !(error is CancellationError) { errorMessage = error.localizedDescription }
        }
        guard requestID == id else { return }
        isImporting = false
    }

    /// Also enforce the UI gate at commit time, so queued Save actions cannot race an import.
    func save(_ draft: SavedEventDesign, baseline: SavedEventDesign, into latest: inout SavedEventDesign) -> [String] {
        guard !isClosed else { return ["Editing session is closed"] }
        guard !isImporting else { return ["Logo is still importing"] }
        return latest.applyReceiptEdits(from: draft, baseline: baseline)
    }

    func cancelImport() {
        requestID = nil
        operation = nil
        isImporting = false
        errorMessage = nil
    }

    func close() { isClosed = true; cancelImport() }
}
