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
    /// Downsampled thumbnails decoded off the main thread, so scrolling never decodes images.
    @Published private(set) var thumbnailImages: [String: UIImage] = [:]
    /// Delivery status per archive, from the pending queue and the verification journal.
    @Published private(set) var galleryStatuses: [String: ArchivedGalleryStatus] = [:]
    @Published private(set) var isLoading = false
    @Published private(set) var hasLoaded = false
    @Published var searchText = ""
    @Published var formatFilter: BoothFormat?
    @Published var showsOnlyAttention = false
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
        let filtered = summaries.filter { summary in
            (formatFilter == nil || (summary.format == formatFilter && summary.rasterFingerprint != "CORRUPT"))
                && (!showsOnlyAttention || needsAttention(summary))
        }
        guard !query.isEmpty else {
            return filtered
        }

        return filtered.filter { summary in
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
            // Unreadable archives carry no trustworthy date; keep them together at the end.
            if summary.rasterFingerprint == "CORRUPT" || summary.createdAt == .distantPast {
                return Self.unreadableSectionTitle
            }
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

    func galleryStatus(for summary: RecentSessionArchiveSummary) -> ArchivedGalleryStatus {
        galleryStatuses[summary.archiveID] ?? .unknown
    }

    func printSummary(for summary: RecentSessionArchiveSummary) -> ArchivedPrintSummary {
        ArchivedPrintSummary.resolve(records: EventOperationalState.shared.auditRecords.filter { $0.sessionIdentifier == summary.sessionIdentifier })
    }

    func needsAttention(_ summary: RecentSessionArchiveSummary) -> Bool {
        summary.rasterFingerprint == "CORRUPT" || galleryStatus(for: summary).isAttention || printSummary(for: summary).isAttention
    }

    func thumbnailImage(for summary: RecentSessionArchiveSummary, filename: String) -> UIImage? {
        thumbnailImages[Self.thumbnailCacheKey(archiveID: summary.archiveID, filename: filename)]
    }

    /// Status from on-device evidence: the pending queue (by gallery token) and the run journal's
    /// public-verification time. Cards use this summary check; the detail view also validates the
    /// frozen URL itself before drawing a QR.
    private func refreshGalleryStatuses() {
        let operations = EventOperationalState.shared
        var statuses: [String: ArchivedGalleryStatus] = [:]
        for summary in summaries where summary.rasterFingerprint != "CORRUPT" {
            let pending = operations.pendingUploads.first { $0.galleryToken == summary.archiveID }
            let verifiedAt = (try? EventRunStore.shared.session(id: summary.sessionIdentifier))?.galleryVerifiedAt
            statuses[summary.archiveID] = ArchivedGalleryStatus.resolve(
                linkIsValid: GalleryTokenGenerator.isValidGalleryToken(summary.archiveID),
                pendingItem: pending,
                verifiedAt: verifiedAt
            )
        }
        galleryStatuses = statuses
    }

    static let unreadableSectionTitle = "Unreadable archives"

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
                    var decoded: [String: UIImage] = [:]

                    for summary in loadedSummaries where summary.rasterFingerprint != "CORRUPT" {
                        for filename in summary.thumbnailFilenames.prefix(3) {
                            if let data = store.thumbnailData(archiveID: summary.archiveID, filename: filename) {
                                let key = Self.thumbnailCacheKey(archiveID: summary.archiveID, filename: filename)
                                loadedThumbnails[key] = data
                                decoded[key] = UIImage(data: data)?.preparingThumbnail(of: CGSize(width: 132, height: 176))
                            }
                        }
                    }

                    return (loadedSummaries, loadedThumbnails, decoded)
                }
            }.value

            guard !Task.isCancelled else { return }

            switch result {
            case .success(let loaded):
                summaries = loaded.0
                thumbnailCache = loaded.1
                thumbnailImages = loaded.2
                refreshGalleryStatuses()
                statusMessage = loaded.0.isEmpty ? "No recent sessions yet." : "\(loaded.0.count) recent sessions loaded."
            case .failure(let error):
                statusMessage = error.localizedDescription
            }

            isLoading = false
            hasLoaded = true
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
        OperatorPrintPolicy.canReprint(
            busy: printerCoordinator.isWorking,
            recoveryLocked: printerCoordinator.requiresRecovery,
            unresolvedPrint: EventOperationalState.shared.hasUnresolvedPrint)
            && !isReprinting
            && !printerCoordinator.isWorking
            && !PrinterBluetoothService.shared.jobState.isWorking
            && !printerState.requiresPrinterRestart
    }

    var buttonTitle: String {
        quantity == 1 ? "Operator Reprint" : "Operator Reprint \(quantity) Copies"
    }

    var reprintUnavailableMessage: String? {
        guard !isReprinting else { return nil }
        if printerState.requiresPrinterRestart || printerCoordinator.requiresRecovery || EventOperationalState.shared.hasUnresolvedPrint {
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
        EventOperationalState.shared.refresh()
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
        let currentRasterFingerprint = RecentSessionArchiveStore.rasterFingerprint(for: rasterizedImage)
        guard currentRasterFingerprint == fingerprint else {
            printerState = .failure("Archived receipt integrity check failed. Nothing was sent.")
            statusMessage = printerState.message
            debugLog("[RecentSessions] reprint blocked archive=\(GalleryTokenGenerator.redacted(archiveID)) archivedFingerprint=\(fingerprint) currentFingerprint=\(currentRasterFingerprint)")
            return
        }

        let batchID = UUID()
        completedCopies = 0
        currentCopy = 0
        isReprinting = true
        statusMessage = copies == 1 ? "Reprinting receipt..." : "Reprinting copy 1 of \(copies)..."
        debugLog("[RecentSessions] reprint start session=\(sessionID) archive=\(GalleryTokenGenerator.redacted(archiveID)) copies=\(copies) archivedFingerprint=\(fingerprint) reprintFingerprint=\(RecentSessionArchiveStore.rasterFingerprint(for: rasterizedImage))")

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
                    fingerprint: fingerprint,
                    batchID: batchID,
                    sessionID: sessionID
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
        fingerprint: String,
        batchID: UUID,
        sessionID: String
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
                wifiPort: wifiPort,
                sessionIdentifier: sessionID,
                source: .archivedReprint,
                copyIndex: copy,
                copyCount: copies,
                batchID: batchID,
                transportPolicy: printerCoordinator.productionReceiptTransportPolicy
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
    var initialSearch = ""
    @StateObject private var viewModel = RecentSessionsViewModel()

    private let columns = [GridItem(.adaptive(minimum: 330, maximum: 560), spacing: 16)]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18, pinnedViews: []) {
                filterBar
                if viewModel.isLoading && !viewModel.hasLoaded {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Loading recent sessions…").foregroundStyle(OperatorPalette.secondaryText)
                    }
                    .frame(maxWidth: .infinity, minHeight: 200)
                } else if viewModel.filteredSummaries.isEmpty {
                    emptyState
                } else {
                    ForEach(viewModel.groupedSummaries, id: \.0) { sectionTitle, summaries in
                        VStack(alignment: .leading, spacing: 12) {
                            sectionHeader(sectionTitle, count: summaries.count)
                            LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                                ForEach(summaries) { summary in
                                    NavigationLink {
                                        ArchivedSessionDetailView(summary: summary, rootViewModel: viewModel)
                                    } label: {
                                        RecentSessionRow(summary: summary, viewModel: viewModel)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
            .frame(maxWidth: 1180)
            .frame(maxWidth: .infinity)
        }
        .background(OperatorPalette.canvas.ignoresSafeArea())
        .navigationTitle("Recent Sessions")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $viewModel.searchText, prompt: "Search session, event, or format")
        .refreshable {
            viewModel.refresh()
        }
        .safeAreaInset(edge: .bottom) {
            if !viewModel.statusMessage.isEmpty {
                Text(viewModel.statusMessage)
                    .font(.footnote)
                    .foregroundStyle(OperatorPalette.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(.bar)
            }
        }
        .onAppear {
            viewModel.searchText = initialSearch
            EventOperationalState.shared.refresh()
            viewModel.refresh()
        }
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                filterChip("All formats", selected: viewModel.formatFilter == nil) { viewModel.formatFilter = nil }
                ForEach(BoothFormat.allCases) { format in
                    filterChip(format.displayName, selected: viewModel.formatFilter == format) {
                        viewModel.formatFilter = viewModel.formatFilter == format ? nil : format
                    }
                }
                Divider().frame(height: 26).padding(.horizontal, 4)
                filterChip("Needs attention", systemImage: "exclamationmark.triangle", selected: viewModel.showsOnlyAttention) {
                    viewModel.showsOnlyAttention.toggle()
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func filterChip(_ title: String, systemImage: String? = nil, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage { Image(systemName: systemImage).font(.caption) }
                Text(title)
            }
            .font(.subheadline.weight(selected ? .semibold : .regular))
            .foregroundStyle(selected ? MadeToKeepTheme.ColorPalette.ivoryLight : OperatorPalette.accent)
            .padding(.horizontal, 14)
            .frame(minHeight: 40)
            .background(Capsule().fill(selected ? OperatorPalette.accent : OperatorPalette.surface))
            .overlay(Capsule().strokeBorder(OperatorPalette.accent.opacity(0.25)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .frame(minHeight: 44)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title)
                .font(MadeToKeepTheme.Typography.italicSerif(size: 28))
                .foregroundStyle(OperatorPalette.accent)
                .accessibilityAddTraits(.isHeader)
            Text(count == 1 ? "1 session" : "\(count) sessions")
                .font(.caption.weight(.medium))
                .textCase(.uppercase)
                .tracking(1.2)
                .foregroundStyle(OperatorPalette.secondaryText)
            Rectangle().fill(OperatorPalette.accent.opacity(0.18)).frame(height: 1)
        }
        .padding(.top, 6)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 34))
                .foregroundStyle(OperatorPalette.accent.opacity(0.6))
            Text(viewModel.summaries.isEmpty ? "no recent sessions yet" : "no sessions match")
                .font(MadeToKeepTheme.Typography.italicSerif(size: 28))
                .foregroundStyle(OperatorPalette.accent)
            Text(viewModel.summaries.isEmpty
                 ? "Finished customer receipts appear here for gallery help and operator reprints."
                 : "Try another search or clear the filters.")
                .font(.callout)
                .foregroundStyle(OperatorPalette.secondaryText)
                .multilineTextAlignment(.center)
            if !viewModel.summaries.isEmpty {
                Button("Clear Filters") {
                    viewModel.formatFilter = nil
                    viewModel.showsOnlyAttention = false
                    viewModel.searchText = ""
                }
                .buttonStyle(.bordered)
                .tint(OperatorPalette.accent)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 260)
    }
}

/// One archived session as an ivory card: thumbnails, time, event, format and concise status.
/// Long identifiers stay in the detail's technical section.
struct RecentSessionRow: View {
    @ObservedObject private var operations = EventOperationalState.shared
    let summary: RecentSessionArchiveSummary
    @ObservedObject var viewModel: RecentSessionsViewModel
    var showsOperationalContext = true

    private var isCorrupt: Bool { summary.rasterFingerprint == "CORRUPT" }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            thumbnailStack
                .frame(width: 112, height: 96)

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(isCorrupt ? "Unreadable archive" : RecentSessionsViewModel.rowTimeFormatter.string(from: summary.createdAt))
                        .font(MadeToKeepTheme.Typography.serif(size: 24))
                        .foregroundStyle(OperatorPalette.ink)
                    if !isCorrupt {
                        Text(summary.createdAt.formatted(.dateTime.month(.abbreviated).day()))
                            .font(.caption)
                            .foregroundStyle(OperatorPalette.secondaryText)
                    }
                }
                Text(summary.eventName ?? MadeToKeepBrand.fullName)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(OperatorPalette.ink)
                    .lineLimit(1)
                if !isCorrupt {
                    Text(summary.format.displayName.uppercased())
                        .font(.caption2.weight(.semibold))
                        .tracking(1.4)
                        .foregroundStyle(OperatorPalette.accent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(OperatorPalette.accent.opacity(0.08)))
                }
                statusLines
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(OperatorPalette.secondaryText.opacity(0.6))
                .accessibilityHidden(true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(OperatorPalette.surface))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(isCorrupt ? OperatorPalette.danger.opacity(0.5) : OperatorPalette.border))
        .shadow(color: MadeToKeepTheme.ColorPalette.shadowTint.opacity(0.08), radius: 8, x: 0, y: 3)
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the receipt, gallery QR and operator reprint.")
    }

    @ViewBuilder
    private var statusLines: some View {
        if isCorrupt {
            Label("Archive needs attention", systemImage: "exclamationmark.triangle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(OperatorPalette.danger)
        } else {
            let gallery = viewModel.galleryStatus(for: summary)
            let print = viewModel.printSummary(for: summary)
            VStack(alignment: .leading, spacing: 3) {
                if showsOperationalContext {
                    Label(print.title, systemImage: print.systemImage)
                        .foregroundStyle(print.isAttention ? OperatorPalette.warning : OperatorPalette.secondaryText)
                    Label(gallery.shortTitle, systemImage: gallery.systemImage)
                        .foregroundStyle(gallery.isAttention ? OperatorPalette.warning : (gallery == .verified ? OperatorPalette.ready : OperatorPalette.secondaryText))
                }
                if summary.reprintCount > 0 {
                    Label("Reprinted \(summary.reprintCount)×", systemImage: "arrow.triangle.2.circlepath")
                        .foregroundStyle(OperatorPalette.secondaryText)
                }
            }
            .font(.caption)
            .labelStyle(.titleAndIcon)
        }
    }

    /// Up to three photos fanned like prints; decoding happened during refresh.
    private var thumbnailStack: some View {
        let filenames = Array(summary.thumbnailFilenames.prefix(3))
        return ZStack {
            if filenames.isEmpty {
                RoundedRectangle(cornerRadius: 6)
                    .fill(OperatorPalette.accent.opacity(0.06))
                    .frame(width: 72, height: 92)
                    .overlay {
                        Image(systemName: isCorrupt ? "exclamationmark.triangle" : "photo")
                            .foregroundStyle(isCorrupt ? OperatorPalette.danger : OperatorPalette.secondaryText)
                    }
            } else {
                ForEach(Array(filenames.enumerated()), id: \.offset) { index, filename in
                    let offset = CGFloat(index) - CGFloat(filenames.count - 1) / 2
                    Group {
                        if let image = viewModel.thumbnailImage(for: summary, filename: filename) {
                            Image(uiImage: image).resizable().scaledToFill()
                        } else {
                            OperatorPalette.accent.opacity(0.06)
                        }
                    }
                    .frame(width: 58, height: 76)
                    .clipped()
                    .padding(3)
                    .background(Color.white)
                    .shadow(color: .black.opacity(0.12), radius: 2, x: 0, y: 1)
                    .rotationEffect(.degrees(Double(offset) * 7))
                    .offset(x: offset * 22)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

struct ArchivedSessionDetailView: View {
    @ObservedObject private var operations = EventOperationalState.shared
    @ObservedObject private var printer = PrinterCoordinator.shared
    let summary: RecentSessionArchiveSummary
    @ObservedObject var rootViewModel: RecentSessionsViewModel

    @Environment(\.dismiss) private var dismiss
    @AppStorage("printerIP") private var printerIP = BoothConfiguration.defaultPrinterIP
    @AppStorage("printerPort") private var printerPort = BoothConfiguration.defaultPrinterPort
    @StateObject private var reprintController = ArchivedReceiptReprintController()
    @State private var archive: RecentSessionArchive?
    @State private var receiptImage: UIImage?
    @State private var thumbnails: [UIImage] = []
    @State private var galleryLink: ArchivedGalleryLink?
    @State private var galleryQR: UIImage?
    @State private var loadError: String?
    @State private var isLoadingArchive = false
    @State private var isConfirmingReprint = false
    @State private var isShowingFullReceiptPreview = false
    @State private var copiedNotice: String?

    var body: some View {
        GeometryReader { proxy in
            let wide = proxy.size.width >= 900
            ScrollView {
                Group {
                    if let archive {
                        if wide {
                            HStack(alignment: .top, spacing: 20) {
                                receiptCard(height: max(520, proxy.size.height - 60))
                                    .frame(width: min(440, proxy.size.width * 0.42))
                                VStack(spacing: 18) { infoCards(archive) }
                            }
                        } else {
                            VStack(spacing: 18) {
                                summaryCard(archive)
                                receiptCard(height: min(760, max(520, proxy.size.height * 0.62)))
                                galleryCard(archive)
                                photosCard
                                reprintCard(archive)
                                technicalCard(archive)
                            }
                        }
                    } else if let loadError {
                        ContentUnavailableView(
                            "This archived session cannot be loaded.",
                            systemImage: "exclamationmark.triangle",
                            description: Text(loadError)
                        )
                        .frame(maxWidth: .infinity, minHeight: 320)
                    } else {
                        ProgressView("Loading archived receipt…")
                            .frame(maxWidth: .infinity, minHeight: 320)
                    }
                }
                .padding(24)
                .frame(maxWidth: 1180)
                .frame(maxWidth: .infinity)
            }
        }
        .background(OperatorPalette.canvas.ignoresSafeArea())
        .navigationTitle(summary.eventName ?? "Archived Session")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Create a new OPERATOR REPRINT of this archived receipt?",
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
            Text("Inspect any previous paper output first. This is a new batch, never automatic recovery.\n\(operations.printContext(sessionID: summary.sessionIdentifier))\n\(summary.sessionIdentifier)\n\(reprintController.quantity) \(reprintController.quantity == 1 ? "copy" : "copies")")
        }
        .onAppear {
            operations.refresh()
            loadArchive()
        }
        .sheet(isPresented: $isShowingFullReceiptPreview) {
            FullReceiptPreviewSheet(image: receiptImage)
        }
    }

    @ViewBuilder
    private func infoCards(_ archive: RecentSessionArchive) -> some View {
        summaryCard(archive)
        galleryCard(archive)
        photosCard
        reprintCard(archive)
        technicalCard(archive)
    }

    private var parsedPort: UInt16? {
        UInt16(printerPort.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Archive bytes are read and decoded off the main thread; the QR is drawn from the frozen URL.
    private func loadArchive() {
        guard !isLoadingArchive, archive == nil else { return }
        isLoadingArchive = true

        Task {
            let result = await rootViewModel.loadArchiveResult(summary.archiveID)
            switch result {
            case .success(let loadedArchive):
                let link = ArchivedGalleryLink(galleryURL: loadedArchive.galleryURL, galleryToken: loadedArchive.galleryToken)
                let decoded = await Task.detached(priority: .userInitiated) { () -> (UIImage?, [UIImage], UIImage?) in
                    (UIImage(data: loadedArchive.receiptPreviewPNGData),
                     loadedArchive.thumbnailData.compactMap { UIImage(data: $0)?.preparingThumbnail(of: CGSize(width: 240, height: 320)) },
                     link.makeQRImage())
                }.value
                archive = loadedArchive
                galleryLink = link
                receiptImage = decoded.0
                thumbnails = decoded.1
                galleryQR = decoded.2
                loadError = nil
            case .failure(let error):
                archive = nil
                loadError = error.localizedDescription
            }
            isLoadingArchive = false
        }
    }

    // MARK: Cards

    private func card<Content: View>(_ title: String, systemImage: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .textCase(.uppercase)
                .tracking(1.4)
                .foregroundStyle(OperatorPalette.accent)
                .accessibilityAddTraits(.isHeader)
            content()
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(OperatorPalette.surface))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(OperatorPalette.border))
    }

    private func summaryCard(_ archive: RecentSessionArchive) -> some View {
        card("Session", systemImage: "calendar") {
            VStack(alignment: .leading, spacing: 6) {
                Text(archive.summary.eventName ?? MadeToKeepBrand.fullName)
                    .font(MadeToKeepTheme.Typography.italicSerif(size: 30))
                    .foregroundStyle(OperatorPalette.accent)
                Text(RecentSessionsViewModel.detailDateFormatter.string(from: archive.summary.createdAt))
                    .font(.headline)
                    .foregroundStyle(OperatorPalette.ink)
                Text("\(archive.summary.format.displayName) · \(archive.summary.photoCount) \(archive.summary.photoCount == 1 ? "photo" : "photos") · \(Int(archive.summary.estimatedLengthMillimeters.rounded())) mm receipt")
                    .foregroundStyle(OperatorPalette.secondaryText)
                if let passport = archive.passport {
                    Text("\(passport.usesPhotoPassDesign ? "Photo Pass" : "Legacy Passport · \(passport.configuration.theme.displayName)") · \(passport.name.isEmpty ? "No name" : passport.name) · \(passport.signature.isEmpty ? "No signature" : "Signed")")
                        .font(.callout)
                        .foregroundStyle(OperatorPalette.secondaryText)
                }
                let print = rootViewModel.printSummary(for: archive.summary)
                Label(print.title, systemImage: print.systemImage)
                    .foregroundStyle(print.isAttention ? OperatorPalette.warning : OperatorPalette.ink)
                    .padding(.top, 4)
                if archive.summary.reprintCount > 0 {
                    Label("Operator reprints: \(archive.summary.reprintCount)\(archive.summary.lastReprintedAt.map { " · last \($0.formatted(date: .omitted, time: .shortened))" } ?? "")", systemImage: "arrow.triangle.2.circlepath")
                        .foregroundStyle(OperatorPalette.secondaryText)
                }
            }
        }
    }

    private func receiptCard(height: CGFloat) -> some View {
        card("Original Receipt", systemImage: "doc.text.image") {
            if let receiptImage {
                OperatorZoomableReceiptView(image: receiptImage, rendering: .smooth, accessibilityLabel: "Original receipt")
                    .frame(height: height)
                Button {
                    isShowingFullReceiptPreview = true
                } label: {
                    Label("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .tint(OperatorPalette.accent)
            } else {
                Text("This archive does not include a readable receipt preview.")
                    .foregroundStyle(OperatorPalette.secondaryText)
            }
        }
    }

    private func galleryStatus(_ archive: RecentSessionArchive) -> ArchivedGalleryStatus {
        ArchivedGalleryStatus.resolve(
            linkIsValid: galleryLink?.isValid ?? false,
            pendingItem: operations.pendingUploads.first { $0.galleryToken == archive.galleryToken },
            verifiedAt: (try? EventRunStore.shared.session(id: archive.summary.sessionIdentifier))?.galleryVerifiedAt
        )
    }

    private func galleryCard(_ archive: RecentSessionArchive) -> some View {
        let status = galleryStatus(archive)
        return card("Customer Gallery", systemImage: "qrcode") {
            HStack(alignment: .top, spacing: 20) {
                if let galleryQR, galleryLink?.url != nil {
                    Image(uiImage: galleryQR)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 190, height: 190)
                        .padding(10)
                        .background(Color.white)
                        .overlay(Rectangle().strokeBorder(MadeToKeepTheme.ColorPalette.hairline))
                        .accessibilityLabel("Original gallery QR code for this session")
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: galleryLink == nil ? "hourglass" : "qrcode")
                            .font(.system(size: 36))
                        Text(galleryLink == nil ? "Preparing QR…" : "No QR")
                            .font(.caption)
                    }
                    .foregroundStyle(OperatorPalette.secondaryText)
                    .frame(width: 210, height: 210)
                    .background(RoundedRectangle(cornerRadius: 8).fill(OperatorPalette.accent.opacity(0.05)))
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Scan to view your photos")
                        .font(MadeToKeepTheme.Typography.italicSerif(size: 24))
                        .foregroundStyle(OperatorPalette.accent)
                    Label(status.title, systemImage: status.systemImage)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(status == .verified ? OperatorPalette.ready : (status.isAttention ? OperatorPalette.warning : OperatorPalette.ink))
                    Text(status.detail)
                        .font(.callout)
                        .foregroundStyle(OperatorPalette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let url = galleryLink?.url {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { galleryActions(url) }
                    VStack(alignment: .leading, spacing: 10) { galleryActions(url) }
                }
                if let copiedNotice {
                    Text(copiedNotice)
                        .font(.footnote)
                        .foregroundStyle(OperatorPalette.secondaryText)
                        .accessibilityAddTraits(.updatesFrequently)
                }
            }
            NavigationLink {
                PendingUploadsView()
            } label: {
                Label("Manage Gallery Upload", systemImage: "icloud.and.arrow.up")
                    .frame(minHeight: 44)
            }
            .tint(OperatorPalette.accent)
        }
    }

    @ViewBuilder
    private func galleryActions(_ url: URL) -> some View {
        Link(destination: url) {
            Label("Open Gallery", systemImage: "safari").frame(minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
        .tint(OperatorPalette.accent)
        Button {
            UIPasteboard.general.url = url
            copiedNotice = "Gallery link copied. Anyone with this link can view these photos."
        } label: {
            Label("Copy Gallery Link", systemImage: "doc.on.doc").frame(minHeight: 44)
        }
        .buttonStyle(.bordered)
        .tint(OperatorPalette.accent)
        ShareLink(item: url, message: Text("Your Made to Keep Studios photos")) {
            Label("Share Link", systemImage: "square.and.arrow.up").frame(minHeight: 44)
        }
        .buttonStyle(.bordered)
        .tint(OperatorPalette.accent)
    }

    private var photosCard: some View {
        card("Photos", systemImage: "photo.on.rectangle") {
            if thumbnails.isEmpty {
                Text("No photo thumbnails were saved with this archive.")
                    .foregroundStyle(OperatorPalette.secondaryText)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(Array(thumbnails.enumerated()), id: \.offset) { index, image in
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 104, height: 136)
                                .clipped()
                                .padding(4)
                                .background(Color.white)
                                .shadow(color: .black.opacity(0.1), radius: 3, x: 0, y: 1)
                                .accessibilityLabel("Photo \(index + 1)")
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    /// Operator-only and visually separate from previews: a new batch behind a confirmation.
    private func reprintCard(_ archive: RecentSessionArchive) -> some View {
        card("Operator Reprint", systemImage: "printer.dotmatrix") {
            Text("Prints a new copy of the exact archived receipt. Inspect any earlier paper first; this never resumes or recovers a previous print.")
                .font(.callout)
                .foregroundStyle(OperatorPalette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Text(operations.printContext(sessionID: summary.sessionIdentifier))
                .font(.footnote)
                .foregroundStyle(OperatorPalette.ink)

            HStack(spacing: 14) {
                HStack(spacing: 0) {
                    Button {
                        reprintController.decreaseQuantity()
                    } label: {
                        Image(systemName: "minus").frame(width: 48, height: 44)
                    }
                    .disabled(reprintController.quantity <= 1 || reprintController.isReprinting)
                    .accessibilityLabel("Fewer copies")

                    Text("\(reprintController.quantity)")
                        .font(.title3.monospacedDigit().weight(.bold))
                        .frame(width: 56, height: 44)
                        .accessibilityLabel("\(reprintController.quantity) \(reprintController.quantity == 1 ? "copy" : "copies")")

                    Button {
                        reprintController.increaseQuantity()
                    } label: {
                        Image(systemName: "plus").frame(width: 48, height: 44)
                    }
                    .disabled(reprintController.quantity >= 10 || reprintController.isReprinting)
                    .accessibilityLabel("More copies")
                }
                .buttonStyle(.bordered)

                Button(reprintController.buttonTitle) {
                    isConfirmingReprint = true
                }
                .buttonStyle(.borderedProminent)
                .tint(OperatorPalette.accent)
                .frame(minHeight: 44)
                .disabled(!reprintController.canReprint || printer.requiresRecovery || operations.hasUnresolvedPrint)
            }

            if reprintController.isReprinting {
                ProgressView(reprintController.statusMessage)
            } else if let message = reprintController.reprintUnavailableMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(OperatorPalette.danger)
            } else {
                Text(reprintController.statusMessage)
                    .font(.footnote)
                    .foregroundStyle(reprintController.printerState.requiresPrinterRestart ? OperatorPalette.danger : OperatorPalette.secondaryText)
            }
        }
    }

    private func technicalCard(_ archive: RecentSessionArchive) -> some View {
        card("Technical Details", systemImage: "wrench.and.screwdriver") {
            DisclosureGroup("Identifiers and integrity") {
                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent("Session ID") {
                        Text(archive.summary.sessionIdentifier).font(.callout.monospaced()).textSelection(.enabled)
                    }
                    Button {
                        UIPasteboard.general.string = archive.summary.sessionIdentifier
                        copiedNotice = "Session ID copied."
                    } label: {
                        Label("Copy Session ID", systemImage: "doc.on.doc").frame(minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    // The token is the gallery's only secret; never shown in full.
                    LabeledContent("Archive", value: GalleryTokenGenerator.redacted(archive.summary.archiveID))
                    LabeledContent("Raster fingerprint", value: archive.summary.rasterFingerprint)
                    LabeledContent("Receipt size", value: "\(archive.summary.receiptWidth) × \(archive.summary.receiptHeight) dots")
                    LabeledContent("Stored size", value: ByteCountFormatter.string(fromByteCount: Int64(archive.summary.payloadSizeBytes), countStyle: .file))
                    LabeledContent("Gallery queue", value: operations.galleryContext(sessionID: summary.sessionIdentifier))
                }
                .font(.callout)
                .padding(.top, 8)
            }
            .tint(OperatorPalette.accent)
        }
    }
}

/// Full-screen receipt inspector. Display only: nothing here can print or change the archive.
private struct FullReceiptPreviewSheet: View {
    let image: UIImage?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let image {
                    OperatorZoomableReceiptView(image: image, rendering: .smooth, accessibilityLabel: "Original receipt")
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
