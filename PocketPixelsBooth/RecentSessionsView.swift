//
//  RecentSessionsView.swift
//  PocketPixelsBooth
//

import Combine
import SwiftUI
import UIKit

@MainActor
final class RecentSessionsViewModel: ObservableObject {
    @Published private(set) var summaries: [RecentSessionArchiveSummary] = []
    @Published private(set) var thumbnailCache: [String: Data] = [:]
    @Published private(set) var isLoading = false
    @Published var searchText = ""
    @Published var statusMessage = ""

    private let store: RecentSessionArchiveStore?
    private var refreshTask: Task<Void, Never>?

    init(store: RecentSessionArchiveStore? = nil) {
        do {
            self.store = try store ?? RecentSessionArchiveStore()
        } catch {
            self.store = nil
            statusMessage = "Recent Sessions storage needs attention: \(error.localizedDescription)"
        }
    }

    var filteredSummaries: [RecentSessionArchiveSummary] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else {
            return summaries
        }

        return summaries.filter { summary in
            summary.sessionIdentifier.lowercased().contains(query)
                || summary.format.displayName.lowercased().contains(query)
                || summary.format.rawValue.lowercased().contains(query)
                || summary.archiveID.lowercased().contains(query)
                || (summary.eventName?.lowercased().contains(query) ?? false)
        }
    }

    var groupedSummaries: [(String, [RecentSessionArchiveSummary])] {
        let calendar = Calendar.current
        let groups = Dictionary(grouping: filteredSummaries) { summary in
            if calendar.isDateInToday(summary.createdAt) {
                return "Today"
            }
            if calendar.isDateInYesterday(summary.createdAt) {
                return "Yesterday"
            }
            return Self.sectionDateFormatter.string(from: summary.createdAt)
        }

        return groups
            .map { ($0.key, $0.value.sorted { $0.createdAt > $1.createdAt }) }
            .sorted { lhs, rhs in
                let leftDate = lhs.1.first?.createdAt ?? .distantPast
                let rightDate = rhs.1.first?.createdAt ?? .distantPast
                return leftDate > rightDate
            }
    }

    var storagePath: String {
        store?.storagePath ?? "Unavailable"
    }

    func refresh() {
        guard let store else {
            statusMessage = "Recent Sessions storage is unavailable."
            return
        }

        refreshTask?.cancel()
        isLoading = true
        refreshTask = Task { [store] in
            let result = await Task.detached(priority: .utility) {
                Result {
                    let loadedSummaries = try store.summaries()
                    var loadedThumbnails: [String: Data] = [:]

                    for summary in loadedSummaries where summary.rasterFingerprint != "CORRUPT" {
                        for filename in summary.thumbnailFilenames.prefix(3) {
                            if let data = store.thumbnailData(archiveID: summary.archiveID, filename: filename) {
                                loadedThumbnails[Self.thumbnailCacheKey(archiveID: summary.archiveID, filename: filename)] = data
                            }
                        }
                    }

                    return (loadedSummaries, loadedThumbnails)
                }
            }.value

            guard !Task.isCancelled else { return }

            switch result {
            case .success(let loaded):
                summaries = loaded.0
                thumbnailCache = loaded.1
                statusMessage = loaded.0.isEmpty ? "No recent sessions yet." : "\(loaded.0.count) recent sessions loaded."
            case .failure(let error):
                statusMessage = error.localizedDescription
            }

            isLoading = false
            refreshTask = nil
        }
    }

    func thumbnailData(for summary: RecentSessionArchiveSummary, filename: String) -> Data? {
        thumbnailCache[Self.thumbnailCacheKey(archiveID: summary.archiveID, filename: filename)]
    }

    func loadArchive(_ archiveID: String) throws -> RecentSessionArchive {
        guard let store else {
            throw RecentSessionArchiveError.archiveNotFound
        }
        return try store.load(archiveID: archiveID)
    }

    func loadArchiveResult(_ archiveID: String) async -> Result<RecentSessionArchive, Error> {
        guard let store else {
            return .failure(RecentSessionArchiveError.archiveNotFound)
        }

        return await Task.detached(priority: .userInitiated) {
            Result {
                try store.load(archiveID: archiveID)
            }
        }.value
    }

    func delete(_ archiveID: String) {
        guard let store else {
            statusMessage = "Recent Sessions storage is unavailable."
            return
        }

        do {
            try store.delete(archiveID: archiveID)
            refresh()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func clearAll() {
        guard let store else {
            statusMessage = "Recent Sessions storage is unavailable."
            return
        }

        do {
            try store.clearAll()
            refresh()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func markReprinted(_ archiveID: String, copies: Int) {
        guard let store else {
            statusMessage = "Recent Sessions storage is unavailable."
            return
        }

        do {
            try store.markReprinted(archiveID: archiveID, copies: copies)
            refresh()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    static let rowTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    static let detailDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private static let sectionDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    private nonisolated static func thumbnailCacheKey(archiveID: String, filename: String) -> String {
        "\(archiveID)/\(filename)"
    }
}

@MainActor
final class ArchivedReceiptReprintController: ObservableObject {
    @Published private(set) var quantity = 1
    @Published private(set) var printerState = PrinterConnectionState.disconnected
    @Published private(set) var currentCopy = 0
    @Published private(set) var completedCopies = 0
    @Published private(set) var isReprinting = false
    @Published var statusMessage = "Ready to reprint."

    private let printerCoordinator = PrinterCoordinator.shared
    private var reprintTask: Task<Void, Never>?

    var canReprint: Bool {
        !isReprinting
            && !printerCoordinator.isWorking
            && !PrinterBluetoothService.shared.jobState.isWorking
            && !printerState.requiresPrinterRestart
    }

    var buttonTitle: String {
        quantity == 1 ? "Reprint Receipt" : "Reprint \(quantity) Copies"
    }

    var reprintUnavailableMessage: String? {
        guard !isReprinting else { return nil }
        if printerState.requiresPrinterRestart {
            return "Printer recovery is required before reprinting."
        }
        if printerCoordinator.isWorking || PrinterBluetoothService.shared.jobState.isWorking {
            return "Printer is busy. Wait for the current job to finish."
        }
        return nil
    }

    func decreaseQuantity() {
        setQuantity(quantity - 1)
    }

    func increaseQuantity() {
        setQuantity(quantity + 1)
    }

    private func setQuantity(_ newValue: Int) {
        quantity = min(10, max(1, newValue))
    }

    func reprint(
        archive: RecentSessionArchive,
        wifiHost: String,
        wifiPort: UInt16?,
        completion: @escaping (Int) -> Void
    ) {
        guard canReprint else {
            statusMessage = "Printer is busy or needs recovery."
            return
        }

        guard let wifiPort else {
            printerState = .failure("Enter a valid TCP port from 1 to 65535.")
            statusMessage = printerState.message
            return
        }

        let copies = quantity
        let rasterizedImage = archive.rasterizedImage
        let archiveID = archive.summary.archiveID
        let sessionID = archive.summary.sessionIdentifier
        let fingerprint = archive.summary.rasterFingerprint
        completedCopies = 0
        currentCopy = 0
        isReprinting = true
        statusMessage = copies == 1 ? "Reprinting receipt..." : "Reprinting copy 1 of \(copies)..."
        debugLog("[RecentSessions] reprint start session=\(sessionID) archive=\(archiveID) copies=\(copies) archivedFingerprint=\(fingerprint) reprintFingerprint=\(RecentSessionArchiveStore.rasterFingerprint(for: rasterizedImage))")

        reprintTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.isReprinting = false
                self.reprintTask = nil
            }

            for copy in 1...copies {
                guard !Task.isCancelled else { return }
                self.currentCopy = copy
                self.statusMessage = copies == 1 ? "Reprinting receipt..." : "Reprinting copy \(copy) of \(copies)..."
                let result = await self.reprintSingleCopy(
                    rasterizedImage: rasterizedImage,
                    wifiHost: wifiHost,
                    wifiPort: wifiPort,
                    copy: copy,
                    copies: copies,
                    fingerprint: fingerprint
                )

                switch result {
                case .success:
                    self.completedCopies = copy
                    completion(1)
                case .failure:
                    self.statusMessage = "\(self.completedCopies) of \(copies) copies completed. Printer needs attention."
                    debugLog("[RecentSessions] reprint stopped session=\(sessionID) completed=\(self.completedCopies) requested=\(copies)")
                    return
                }
            }

            self.statusMessage = "Reprint complete."
            debugLog("[RecentSessions] reprint complete session=\(sessionID) copies=\(copies) fingerprint=\(fingerprint)")
        }
    }

    private func reprintSingleCopy(
        rasterizedImage: ThermalRasterizedImage,
        wifiHost: String,
        wifiPort: UInt16,
        copy: Int,
        copies: Int,
        fingerprint: String
    ) async -> Result<Void, Error> {
        do {
            try ThermalImageRasterizer.validateRasterCommand(
                rasterizedImage.rasterCommand,
                imageWidth: rasterizedImage.width,
                imageHeight: rasterizedImage.height,
                bytesPerRow: rasterizedImage.widthBytes,
                rasterDataCount: rasterizedImage.rasterData.count
            )
            try RasterCommandSanitizer.validateOutboundJob(
                heading: ThermalImageRasterizer.receiptPrintHeading(),
                rasterCommand: rasterizedImage.rasterCommand,
                finishing: ThermalImageRasterizer.photoTestFinishing(),
                rasterDataRange: 8..<rasterizedImage.rasterCommand.count
            )
        } catch {
            printerState = .failure(error.localizedDescription)
            statusMessage = error.localizedDescription
            return .failure(error)
        }

        return await withCheckedContinuation { continuation in
            debugLog("[RecentSessions] copy=\(copy)/\(copies) transport start fingerprint=\(fingerprint)")
            printerCoordinator.printReceipt(
                rasterizedImage: rasterizedImage,
                wifiHost: wifiHost,
                wifiPort: wifiPort
            ) { [weak self] state in
                guard let self else { return }
                self.printerState = state
                switch state {
                case .recoveryRequired(let message), .failure(let message):
                    self.statusMessage = message
                case .success:
                    break
                default:
                    self.statusMessage = copies == 1 ? "Reprinting receipt..." : "Reprinting copy \(copy) of \(copies)..."
                }
            } completion: { result in
                debugLog("[RecentSessions] copy=\(copy)/\(copies) transport complete fingerprint=\(fingerprint)")
                continuation.resume(returning: result)
            }
        }
    }
}

struct RecentSessionsView: View {
    @StateObject private var viewModel = RecentSessionsViewModel()
    @State private var isConfirmingClearAll = false

    var body: some View {
        List {
            if viewModel.isLoading {
                HStack {
                    ProgressView()
                    Text("Loading recent sessions...")
                }
            } else if viewModel.filteredSummaries.isEmpty {
                ContentUnavailableView(
                    "No recent sessions yet.",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Finished customer receipts will appear here for quick reprinting.")
                )
            } else {
                ForEach(viewModel.groupedSummaries, id: \.0) { sectionTitle, summaries in
                    Section(sectionTitle) {
                        ForEach(summaries) { summary in
                            NavigationLink {
                                ArchivedSessionDetailView(summary: summary, rootViewModel: viewModel)
                            } label: {
                                RecentSessionRow(summary: summary, viewModel: viewModel)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Recent Sessions")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $viewModel.searchText, prompt: "Search session, event, or format")
        .refreshable {
            viewModel.refresh()
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Clear") {
                    isConfirmingClearAll = true
                }
                .disabled(viewModel.summaries.isEmpty)
            }
        }
        .confirmationDialog(
            "Clear all recent sessions from this iPad?",
            isPresented: $isConfirmingClearAll,
            titleVisibility: .visible
        ) {
            Button("Clear Recent Sessions", role: .destructive) {
                viewModel.clearAll()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes only local reprint archives. It does not delete online galleries, pending uploads, Event Profile, or printer settings.")
        }
        .safeAreaInset(edge: .bottom) {
            if !viewModel.statusMessage.isEmpty {
                Text(viewModel.statusMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(.bar)
            }
        }
        .onAppear {
            viewModel.refresh()
        }
    }
}

private struct RecentSessionRow: View {
    let summary: RecentSessionArchiveSummary
    let viewModel: RecentSessionsViewModel

    private let thumbnailCellWidth: CGFloat = 34
    private let thumbnailCellHeight: CGFloat = 54

    var body: some View {
        HStack(spacing: 12) {
            thumbnailStrip
                .frame(width: 112, height: 54)

            VStack(alignment: .leading, spacing: 4) {
                Text(summary.eventName ?? "Pocket Pixels Receipt")
                    .font(.headline)
                    .lineLimit(1)

                Text("\(RecentSessionsViewModel.rowTimeFormatter.string(from: summary.createdAt)) • \(summary.format.displayName.uppercased())")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)

                Text(summary.sessionIdentifier)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)

                if summary.rasterFingerprint == "CORRUPT" {
                    Text("Archive needs attention")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.red)
                } else if summary.reprintCount > 0 {
                    Text("Reprinted \(summary.reprintCount)x")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var thumbnailStrip: some View {
        Group {
            if summary.thumbnailFilenames.isEmpty {
                RoundedRectangle(cornerRadius: 4)
                    .fill(.secondary.opacity(0.14))
                    .overlay {
                        Image(systemName: summary.rasterFingerprint == "CORRUPT" ? "exclamationmark.triangle" : "photo")
                            .foregroundStyle(summary.rasterFingerprint == "CORRUPT" ? .red : .secondary)
                    }
            } else {
                HStack(spacing: 4) {
                    ForEach(Array(summary.thumbnailFilenames.prefix(3).enumerated()), id: \.offset) { _, filename in
                        if let data = viewModel.thumbnailData(for: summary, filename: filename),
                           let image = UIImage(data: data) {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(width: thumbnailCellWidth, height: thumbnailCellHeight)
                                .clipped()
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        } else {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(.secondary.opacity(0.14))
                                .frame(width: thumbnailCellWidth, height: thumbnailCellHeight)
                                .overlay {
                                    Image(systemName: "photo")
                                        .foregroundStyle(.secondary)
                                }
                        }
                    }
                }
            }
        }
    }
}

private struct ArchivedSessionDetailView: View {
    let summary: RecentSessionArchiveSummary
    @ObservedObject var rootViewModel: RecentSessionsViewModel

    @Environment(\.dismiss) private var dismiss
    @AppStorage("printerIP") private var printerIP = BoothConfiguration.defaultPrinterIP
    @AppStorage("printerPort") private var printerPort = BoothConfiguration.defaultPrinterPort
    @StateObject private var reprintController = ArchivedReceiptReprintController()
    @State private var archive: RecentSessionArchive?
    @State private var loadError: String?
    @State private var isLoadingArchive = false
    @State private var isConfirmingReprint = false
    @State private var isConfirmingDelete = false
    @State private var isShowingFullReceiptPreview = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let archive {
                    receiptPreview(archive)
                    metadata(archive)
                    thumbnails(archive)
                    reprintControls(archive)
                } else if let loadError {
                    ContentUnavailableView(
                        "This archived session cannot be loaded.",
                        systemImage: "exclamationmark.triangle",
                        description: Text(loadError)
                    )

                    Button("Delete Archive", role: .destructive) {
                        isConfirmingDelete = true
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    ProgressView("Loading archived receipt...")
                }
            }
            .padding()
        }
        .navigationTitle(summary.sessionIdentifier)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Delete", role: .destructive) {
                    isConfirmingDelete = true
                }
                .disabled(reprintController.isReprinting)
            }
        }
        .confirmationDialog(
            "Delete this archived session?",
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete This Session", role: .destructive) {
                rootViewModel.delete(summary.archiveID)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the local reprint copy from this iPad. It does not delete the customer's online gallery.")
        }
        .confirmationDialog(
            "Reprint this exact receipt?",
            isPresented: $isConfirmingReprint,
            titleVisibility: .visible
        ) {
            if let archive {
                Button(reprintController.buttonTitle) {
                    reprintController.reprint(
                        archive: archive,
                        wifiHost: printerIP,
                        wifiPort: parsedPort
                    ) { completedCopies in
                        rootViewModel.markReprinted(summary.archiveID, copies: completedCopies)
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(summary.sessionIdentifier)\n\(reprintController.quantity) \(reprintController.quantity == 1 ? "copy" : "copies")")
        }
        .onAppear {
            loadArchive()
        }
        .sheet(isPresented: $isShowingFullReceiptPreview) {
            FullReceiptPreviewSheet(archive: archive)
        }
    }

    private var parsedPort: UInt16? {
        UInt16(printerPort.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func loadArchive() {
        guard !isLoadingArchive else { return }
        isLoadingArchive = true

        Task {
            let result = await rootViewModel.loadArchiveResult(summary.archiveID)
            isLoadingArchive = false

            switch result {
            case .success(let loadedArchive):
                archive = loadedArchive
                loadError = nil
            case .failure(let error):
                archive = nil
                loadError = error.localizedDescription
            }
        }
    }

    private func receiptPreview(_ archive: RecentSessionArchive) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Original Receipt")
                    .font(.headline)
                Spacer()
                Button("View Larger") {
                    isShowingFullReceiptPreview = true
                }
                .font(.subheadline.weight(.semibold))
            }
            if let image = UIImage(data: archive.receiptPreviewPNGData) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .frame(maxHeight: 520)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(.secondary.opacity(0.2))
                    }
            }
        }
    }

    private func metadata(_ archive: RecentSessionArchive) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(archive.summary.eventName ?? "Pocket Pixels Receipt")
                .font(.title3.weight(.semibold))
            Text(RecentSessionsViewModel.detailDateFormatter.string(from: archive.summary.createdAt))
            Text("\(archive.summary.format.displayName) • \(archive.summary.photoCount) photos • \(Int(archive.summary.estimatedLengthMillimeters.rounded())) mm")
            Text(archive.summary.sessionIdentifier)
                .font(.callout.monospaced())
            Text("Fingerprint \(archive.summary.rasterFingerprint)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            Text(archive.galleryURL.absoluteString)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    private func thumbnails(_ archive: RecentSessionArchive) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Photo Thumbnails")
                .font(.headline)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(archive.thumbnailData.enumerated()), id: \.offset) { _, data in
                        if let image = UIImage(data: data) {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 88, height: 88)
                                .clipped()
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
            }
        }
    }

    private func reprintControls(_ archive: RecentSessionArchive) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Reprint")
                .font(.headline)

            HStack(spacing: 0) {
                Button {
                    reprintController.decreaseQuantity()
                } label: {
                    Image(systemName: "minus")
                        .frame(width: 48, height: 42)
                }
                .disabled(reprintController.quantity <= 1 || reprintController.isReprinting)

                Text("\(reprintController.quantity)")
                    .font(.title3.monospacedDigit().weight(.bold))
                    .frame(width: 56, height: 42)

                Button {
                    reprintController.increaseQuantity()
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 48, height: 42)
                }
                .disabled(reprintController.quantity >= 10 || reprintController.isReprinting)
            }
            .buttonStyle(.bordered)

            Button(reprintController.buttonTitle) {
                isConfirmingReprint = true
            }
            .buttonStyle(.borderedProminent)
            .disabled(!reprintController.canReprint)

            if reprintController.isReprinting {
                ProgressView(reprintController.statusMessage)
            } else if let message = reprintController.reprintUnavailableMessage {
                Text(message)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.red)
            } else {
                Text(reprintController.statusMessage)
                    .font(.footnote)
                    .foregroundStyle(reprintController.printerState.requiresPrinterRestart ? .red : .secondary)
            }
        }
        .padding()
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct FullReceiptPreviewSheet: View {
    let archive: RecentSessionArchive?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                if let archive,
                   let image = UIImage(data: archive.receiptPreviewPNGData) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 520)
                        .background(Color.white)
                        .padding()
                } else {
                    ContentUnavailableView(
                        "Receipt preview unavailable.",
                        systemImage: "photo",
                        description: Text("This archive does not include a readable receipt preview.")
                    )
                }
            }
            .navigationTitle("Original Receipt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

nonisolated private func debugLog(_ message: String) {
#if DEBUG
    print("[RecentSessionsView] \(message)")
#endif
}
