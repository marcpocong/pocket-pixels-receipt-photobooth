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
    @Published private(set) var galleryStatuses: [String: ArchivedGalleryStatus] = [:]
    @Published private(set) var printStatuses: [String: ArchivedPrintSummary] = [:]
    @Published private(set) var filteredSummaries: [RecentSessionArchiveSummary] = []
    @Published private(set) var groupedSummaries: [(String, [RecentSessionArchiveSummary])] = []
    @Published private(set) var isLoading = false
    @Published private(set) var hasLoaded = false
    @Published var searchText = "" { didSet { rebuildFilters() } }
    @Published var formatFilter: BoothFormat? { didSet { rebuildFilters() } }
    @Published var showsOnlyAttention = false { didSet { rebuildFilters() } }
    @Published var todayOnly = false { didSet { rebuildFilters() } }
    @Published var eventFilter: String? { didSet { rebuildFilters() } }
    @Published var dateFrom: Date? { didSet { rebuildFilters() } }
    @Published var dateThrough: Date? { didSet { rebuildFilters() } }
    @Published var usesPhotoGrid = false
    @Published var selectedArchiveID: String?
    var scrollAnchor: String?
    @Published var statusMessage = ""
    @Published private(set) var loadError: String?
    let thumbnails = SessionThumbnailCache()
    private let store: RecentSessionArchiveStore?
    private let summaryLoader: (@Sendable () throws -> [RecentSessionArchiveSummary])?
    private var refreshTask: Task<Void, Never>?
    private var statusTask: Task<Void, Never>?
    private var subscriptions = Set<AnyCancellable>()
    private var verifiedSessions = Set<String>()
    private var searchIndex: [String: String] = [:]
    private var pendingIndex: [String: GalleryPendingUploadSummary] = [:]
    static let unreadableSectionTitle = "Unreadable archives"

    init(store: RecentSessionArchiveStore? = nil, summaryLoader: (@Sendable () throws -> [RecentSessionArchiveSummary])? = nil) {
        self.summaryLoader = summaryLoader
        do { self.store = try store ?? RecentSessionArchiveStore() }
        catch { self.store = nil; statusMessage = "Recent Sessions storage needs attention: \(error.localizedDescription)" }
        let operations = EventOperationalState.shared
        operations.$auditRecords.sink { [weak self] records in
            guard let self else { return }
            let groups = Dictionary(grouping: records, by: \.sessionIdentifier)
            self.printStatuses = groups.mapValues { ArchivedPrintSummary.resolve(records: $0) }
            self.rebuildFilters()
        }.store(in: &subscriptions)
        operations.$pendingUploads.sink { [weak self] pending in
            guard let self else { return }
            self.pendingIndex = Dictionary(grouping: pending, by: \.galleryToken).compactMapValues(\.first)
            self.rebuildGalleryStatuses()
        }.store(in: &subscriptions)
        EventRunStore.shared.$revision.dropFirst().debounce(for: .milliseconds(100), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.refreshVerification() }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)
            .sink { [weak self] _ in
                guard let cache = self?.thumbnails else { return }
                Task { await cache.removeAll() }
            }.store(in: &subscriptions)
    }

    var events: [String] { Array(Set(summaries.map { $0.eventName ?? "Regular Booth" })).sorted() }
    var selectedSummary: RecentSessionArchiveSummary? { summaries.first { $0.archiveID == selectedArchiveID } }
    var storagePath: String { store?.storagePath ?? "Unavailable" }

    private func rebuildFilters() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let calendar = Calendar.current
        let end = dateThrough.flatMap { calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: $0)) }
        filteredSummaries = summaries.filter { summary in
            if let formatFilter, summary.format != formatFilter || summary.rasterFingerprint == "CORRUPT" { return false }
            if showsOnlyAttention && !needsAttention(summary) { return false }
            if todayOnly && !calendar.isDateInToday(summary.createdAt) { return false }
            if let eventFilter, (summary.eventName ?? "Regular Booth") != eventFilter { return false }
            if let dateFrom, summary.createdAt < calendar.startOfDay(for: dateFrom) { return false }
            if let end, summary.createdAt >= end { return false }
            return query.isEmpty || (searchIndex[summary.archiveID]?.contains(query) ?? false)
        }
        var groups: [(String, [RecentSessionArchiveSummary])] = []
        var indices: [String: Int] = [:]
        for summary in filteredSummaries {
            let title: String
            if summary.rasterFingerprint == "CORRUPT" || summary.createdAt == .distantPast { title = Self.unreadableSectionTitle }
            else if calendar.isDateInToday(summary.createdAt) { title = "Today" }
            else if calendar.isDateInYesterday(summary.createdAt) { title = "Yesterday" }
            else { title = Self.sectionDateFormatter.string(from: summary.createdAt) }
            if let index = indices[title] { groups[index].1.append(summary) }
            else { indices[title] = groups.count; groups.append((title, [summary])) }
        }
        groupedSummaries = groups
    }

    func clearFilters() {
        searchText = ""; formatFilter = nil; showsOnlyAttention = false; todayOnly = false
        eventFilter = nil; dateFrom = nil; dateThrough = nil
    }
    func galleryStatus(for summary: RecentSessionArchiveSummary) -> ArchivedGalleryStatus { galleryStatuses[summary.archiveID] ?? .unknown }
    func printSummary(for summary: RecentSessionArchiveSummary) -> ArchivedPrintSummary { printStatuses[summary.sessionIdentifier] ?? .notRecorded }
    func needsAttention(_ summary: RecentSessionArchiveSummary) -> Bool {
        summary.rasterFingerprint == "CORRUPT" || galleryStatus(for: summary).isAttention || printSummary(for: summary).isAttention
    }
    func thumbnail(for summary: RecentSessionArchiveSummary) async -> UIImage? {
        guard let store, let filename = summary.thumbnailFilenames.first else { return nil }
        return await thumbnails.image(archiveID: summary.archiveID, filename: filename, store: store)
    }
    private func rebuildGalleryStatuses() {
        galleryStatuses = Dictionary(uniqueKeysWithValues: summaries.map { summary in
            (summary.archiveID, ArchivedGalleryStatus.resolve(linkIsValid: GalleryTokenGenerator.isValidGalleryToken(summary.archiveID),
                pendingItem: pendingIndex[summary.archiveID], verifiedAt: verifiedSessions.contains(summary.sessionIdentifier) ? Date.distantPast : nil))
        })
        rebuildFilters()
    }
    private func refreshVerification() {
        statusTask?.cancel()
        let directory = EventRunStore.shared.directory
        let validRuns = Set(EventRunStore.shared.runs.map(\.id))
        statusTask = Task {
            let records = await Task.detached(priority: .utility) { try? EventRunStore.loadSessions(directory: directory) }.value
            guard !Task.isCancelled else { return }
            if records == nil { statusMessage = "Gallery verification records could not be read. Original archives are retained." }
            verifiedSessions = Set((records ?? []).filter { validRuns.contains($0.runID) && $0.galleryVerifiedAt != nil }.map(\.sessionID))
            rebuildGalleryStatuses()
        }
    }
    func refresh() {
        guard let store else { statusMessage = "Recent Sessions storage is unavailable."; hasLoaded = true; return }
        refreshTask?.cancel(); isLoading = true
        let loader = summaryLoader
        refreshTask = Task {
            let worker = Task.detached(priority: .utility) { Result { try loader?() ?? store.summaries(includePayloadSize: false) } }
            let result = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
            guard !Task.isCancelled else { return }
            switch result {
            case .success(let loaded):
                loadError = nil
                summaries = loaded
                searchIndex = Dictionary(uniqueKeysWithValues: loaded.map {
                    ($0.archiveID, [$0.sessionIdentifier, $0.archiveID, $0.format.displayName, $0.format.rawValue, $0.eventName ?? "Regular Booth"].joined(separator: " ").lowercased())
                })
                rebuildGalleryStatuses(); refreshVerification()
                statusMessage = loaded.isEmpty ? "No recent sessions yet." : "\(loaded.count) sessions · originals retained on this iPad"
            case .failure(let error):
                loadError = "Session records could not be read. Originals are retained. " + error.localizedDescription
                statusMessage = loadError ?? error.localizedDescription
            }
            isLoading = false; hasLoaded = true; refreshTask = nil
        }
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
            // Refresh just the changed metadata. Preview/cache/filter identities stay stable.
            if let changed = try store.summary(archiveID: archiveID), let index = summaries.firstIndex(where: { $0.archiveID == archiveID }) {
                summaries[index] = changed
                rebuildFilters()
            }
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
        quantity == 1 ? "Print 1 Extra Copy" : "Print \(quantity) Extra Copies"
    }

    var reprintUnavailableMessage: String? {
        guard !isReprinting else { return nil }
        if printerState.requiresPrinterRestart || printerCoordinator.requiresRecovery || EventOperationalState.shared.hasUnresolvedPrint {
            return "Check the previous receipt in Help & Recovery before printing another copy."
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
                    self.statusMessage = self.printerState.requiresPrinterRestart
                        ? "\(self.completedCopies) of \(copies) copies sent. The last receipt may have printed; check the paper in Help & Recovery."
                        : "\(self.completedCopies) of \(copies) copies sent. The next copy failed before it was sent. Check the printer connection."
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
    @StateObject private var viewModel: RecentSessionsViewModel
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var filtersPresented = false
    init(initialSearch: String = "", viewModel: RecentSessionsViewModel? = nil) {
        self.initialSearch = initialSearch
        _viewModel = StateObject(wrappedValue: viewModel ?? RecentSessionsViewModel())
    }

    var body: some View {
        GeometryReader { geometry in
            let wide = OperatorWorkspaceLayout.usesSidebar(width: geometry.size.width, height: geometry.size.height)
            let hasSelection = viewModel.selectedSummary != nil
            HStack(spacing: 0) {
                browser
                    .frame(width: wide && hasSelection ? min(400, geometry.size.width * 0.4) : geometry.size.width)
                    .frame(width: !wide && hasSelection ? 0 : (wide && hasSelection ? min(400, geometry.size.width * 0.4) : geometry.size.width), alignment: .leading)
                    .clipped().opacity(!wide && hasSelection ? 0 : 1)
                    .allowsHitTesting(wide || !hasSelection).accessibilityHidden(!wide && hasSelection)
                if let selected = viewModel.selectedSummary {
                    if wide { Divider() }
                    VStack(spacing: 0) {
                        HStack {
                            Button { viewModel.selectedArchiveID = nil } label: {
                                Label(wide ? "Close Detail" : "Sessions", systemImage: "chevron.left").frame(minHeight: 44)
                            }.accessibilityIdentifier("sessions-back")
                            Spacer()
                            Text(selected.format.displayName).font(.subheadline).foregroundStyle(OperatorPalette.secondaryText)
                        }.padding(.horizontal, 16).background(OperatorPalette.surface)
                        ArchivedSessionDetailView(summary: selected, rootViewModel: viewModel)
                            .id(selected.archiveID)
                    }.frame(maxWidth: .infinity)
                }
            }
        }
        .background(OperatorPalette.canvas)
        .navigationTitle("Sessions").navigationBarTitleDisplayMode(.inline)
        .task {
            if !viewModel.hasLoaded {
                viewModel.searchText = initialSearch
            }
            // Re-entering a retained workspace picks up newly archived guests without
            // resetting filters/selection, clearing the cache or showing a loading screen.
            viewModel.refresh()
        }
        .sheet(isPresented: $filtersPresented) { filterSheet }
    }

    private var browser: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").accessibilityHidden(true)
                    TextField("Search session, event or format", text: $viewModel.searchText)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("sessions-search")
                    if !viewModel.searchText.isEmpty {
                        Button { viewModel.searchText = "" } label: { Image(systemName: "xmark.circle.fill").frame(width: 44, height: 44) }
                            .accessibilityLabel("Clear search")
                    }
                }.padding(.horizontal, 12).frame(minHeight: 48)
                    .background(OperatorPalette.surface, in: RoundedRectangle(cornerRadius: 10))
                ViewThatFits(in: .horizontal) {
                    HStack { filterControls; Spacer(minLength: 0); displayControl }
                    VStack(alignment: .leading) { filterControls; displayControl }
                }
            }.padding(16)
            ScrollViewReader { scroll in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if !viewModel.hasLoaded {
                            ProgressView("Loading sessions…").frame(maxWidth: .infinity, minHeight: 220)
                        } else if let error = viewModel.loadError, viewModel.summaries.isEmpty {
                            ContentUnavailableView("Sessions unavailable", systemImage: "exclamationmark.triangle", description: Text(error))
                            Button("Retry Loading") { viewModel.refresh() }.buttonStyle(.bordered).frame(minHeight: 44).padding()
                        } else if viewModel.filteredSummaries.isEmpty {
                            ContentUnavailableView(viewModel.summaries.isEmpty ? "No sessions yet" : "No matching sessions", systemImage: "photo.stack",
                                description: Text(viewModel.summaries.isEmpty ? "Finished receipts appear here with their original gallery and print history." : "Change the search or filters to find an earlier guest."))
                            if !viewModel.summaries.isEmpty { Button("Clear Filters") { viewModel.clearFilters() }.frame(minHeight: 44).padding() }
                        } else {
                            ForEach(viewModel.groupedSummaries, id: \.0) { title, summaries in
                                HStack { Text(title).font(.headline); Spacer(); Text("\(summaries.count)").font(.caption).monospacedDigit() }
                                    .foregroundStyle(OperatorPalette.secondaryText).padding(.horizontal, 16).padding(.vertical, 12)
                                    .accessibilityAddTraits(.isHeader)
                                if viewModel.usesPhotoGrid {
                                    LazyVGrid(columns: [GridItem(.adaptive(minimum: typeSize.isAccessibilitySize ? 260 : 180), spacing: 12)], spacing: 12) {
                                        ForEach(summaries) { summary in sessionButton(summary, grid: true).id(summary.archiveID) }
                                    }.padding(.horizontal, 16)
                                } else {
                                    ForEach(summaries) { summary in
                                        sessionButton(summary, grid: false).id(summary.archiveID)
                                        Divider().padding(.leading, 92)
                                    }
                                }
                            }
                        }
                    }.padding(.bottom, 16).scrollTargetLayout()
                }
                .scrollPosition(id: Binding(get: { viewModel.scrollAnchor }, set: { viewModel.scrollAnchor = $0 }), anchor: .top)
                .refreshable { viewModel.refresh() }
                .onChange(of: viewModel.selectedArchiveID) { previous, current in
                    if current == nil, let anchor = viewModel.scrollAnchor ?? previous { scroll.scrollTo(anchor, anchor: .top) }
                }
            }
            if !viewModel.statusMessage.isEmpty {
                Text(viewModel.statusMessage).font(.caption).foregroundStyle(OperatorPalette.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.vertical, 8)
            }
        }
    }

    private var filterControls: some View {
        HStack(spacing: 8) {
            Button { viewModel.todayOnly.toggle() } label: { Text(viewModel.todayOnly ? "Today ✓" : "All dates").frame(minHeight: 44) }
                .buttonStyle(.bordered).accessibilityLabel("Today only").accessibilityAddTraits(viewModel.todayOnly ? .isSelected : [])
            Button { filtersPresented = true } label: { Label("Filters", systemImage: "line.3.horizontal.decrease").frame(minHeight: 44) }
                .buttonStyle(.bordered).accessibilityIdentifier("sessions-filters")
        }
    }
    private var displayControl: some View {
        Button { viewModel.usesPhotoGrid.toggle() } label: {
            Label(viewModel.usesPhotoGrid ? "List" : "Photos", systemImage: viewModel.usesPhotoGrid ? "list.bullet" : "square.grid.2x2").frame(minHeight: 44)
        }.buttonStyle(.bordered).accessibilityIdentifier("sessions-display")
    }
    private func sessionButton(_ summary: RecentSessionArchiveSummary, grid: Bool) -> some View {
        Button { viewModel.selectedArchiveID = summary.archiveID } label: {
            RecentSessionRow(summary: summary, viewModel: viewModel, photoGrid: grid).equatable()
        }.buttonStyle(.plain).accessibilityIdentifier("session-\(summary.archiveID)")
    }
    private var filterSheet: some View {
        NavigationStack {
            Form {
                Section("Date") {
                    Toggle("Today", isOn: $viewModel.todayOnly)
                    Toggle("Date range", isOn: Binding(get: { viewModel.dateFrom != nil }, set: { enabled in
                        viewModel.dateFrom = enabled ? Calendar.current.startOfDay(for: Date()) : nil
                        viewModel.dateThrough = enabled ? Date() : nil
                        viewModel.todayOnly = false
                    }))
                    if viewModel.dateFrom != nil {
                        DatePicker("From", selection: Binding(get: { viewModel.dateFrom ?? Date() }, set: { viewModel.dateFrom = $0 }), displayedComponents: .date)
                        DatePicker("Through", selection: Binding(get: { viewModel.dateThrough ?? Date() }, set: { viewModel.dateThrough = $0 }), displayedComponents: .date)
                    }
                }
                Section("Session") {
                    Picker("Event", selection: $viewModel.eventFilter) {
                        Text("All events & Regular Booth").tag(Optional<String>.none)
                        ForEach(viewModel.events, id: \.self) { Text($0).tag(Optional($0)) }
                    }
                    Picker("Format", selection: $viewModel.formatFilter) {
                        Text("All formats").tag(Optional<BoothFormat>.none)
                        ForEach(BoothFormat.allCases) { Text($0.displayName).tag(Optional($0)) }
                    }
                    Toggle("Needs attention", isOn: $viewModel.showsOnlyAttention)
                    Text("Unknown print history stays visible here. It does not by itself block the next guest.").font(.footnote)
                }
                Section { Button("Clear Filters") { viewModel.clearFilters() } }
            }.navigationTitle("Filter Sessions").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { filtersPresented = false } } }
        }
    }
}

/// Value-only statuses and a local image task keep global operational invalidations out of rows.
struct RecentSessionRow: View, Equatable {
    let summary: RecentSessionArchiveSummary
    let viewModel: RecentSessionsViewModel
    var showsOperationalContext = true
    var photoGrid = false
    let gallery: ArchivedGalleryStatus
    let print: ArchivedPrintSummary
    init(summary: RecentSessionArchiveSummary, viewModel: RecentSessionsViewModel, showsOperationalContext: Bool = true, photoGrid: Bool = false) {
        self.summary = summary; self.viewModel = viewModel; self.showsOperationalContext = showsOperationalContext; self.photoGrid = photoGrid
        self.gallery = viewModel.galleryStatus(for: summary); self.print = viewModel.printSummary(for: summary)
    }
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.summary == rhs.summary && lhs.gallery == rhs.gallery && lhs.print == rhs.print
            && lhs.photoGrid == rhs.photoGrid && lhs.showsOperationalContext == rhs.showsOperationalContext && lhs.viewModel === rhs.viewModel
    }
    private var isCorrupt: Bool { summary.rasterFingerprint == "CORRUPT" }
    var body: some View {
        let layout = photoGrid ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10)) : AnyLayout(HStackLayout(spacing: 14))
        layout {
            SessionThumbnailView(summary: summary, model: viewModel)
                .frame(width: photoGrid ? nil : 60, height: photoGrid ? 160 : 80)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 4) {
                Text(isCorrupt ? "Unreadable archive" : RecentSessionsViewModel.rowTimeFormatter.string(from: summary.createdAt))
                    .font(.headline).foregroundStyle(OperatorPalette.ink)
                Text(summary.eventName ?? "Regular Booth").font(.subheadline.weight(.medium)).foregroundStyle(OperatorPalette.ink).lineLimit(2)
                Text(summary.format.displayName).font(.caption).foregroundStyle(OperatorPalette.secondaryText)
                if showsOperationalContext {
                    Text(isCorrupt ? "Archive needs attention" : print.title + " · " + gallery.shortTitle)
                        .font(.caption).foregroundStyle(isCorrupt || print.isAttention || gallery.isAttention ? OperatorPalette.warning : OperatorPalette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if summary.reprintCount > 0 { Text("Operator reprints: \(summary.reprintCount)").font(.caption).foregroundStyle(OperatorPalette.secondaryText) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if !photoGrid { Image(systemName: "chevron.right").font(.caption).foregroundStyle(OperatorPalette.secondaryText).accessibilityHidden(true) }
        }
        .padding(photoGrid ? 12 : 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(OperatorPalette.surface)
        .contentShape(Rectangle()).accessibilityElement(children: .combine)
        .accessibilityHint("Opens original receipt, photos, gallery QR and explicit operator reprint")
    }
}

struct ArchivedSessionDetailView: View {
    @Environment(\.dynamicTypeSize) private var typeSize
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
                                photosCard
                                galleryCard(archive)
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
            let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 16)) : AnyLayout(HStackLayout(alignment: .top, spacing: 20))
            layout {
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
