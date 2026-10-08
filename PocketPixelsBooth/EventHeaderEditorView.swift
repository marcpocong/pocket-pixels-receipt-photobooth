//
//  EventHeaderEditorView.swift
//  PocketPixelsBooth
//

import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Receipt header section of Event Setup. Kept deliberately compact: artwork placement lives in
/// the dedicated Receipt Artwork Editor.
struct EventHeaderEditorView: View {
    @Binding var profile: EventProfile
    @Binding var statusMessage: String

    @State private var photoItem: PhotosPickerItem?
    @State private var isPhotoPickerPresented = false
    @State private var isFileImporterPresented = false
    @State private var artwork: EventArtwork?
    @State private var thermalImage: UIImage?
    @State private var warnings: [EventHeaderQualityWarning] = []
    @State private var processingTask: Task<Void, Never>?
    @State private var processingGeneration = 0
    @State private var isEditorPresented = false
    @State private var isImporting = false
    @State private var loadError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("Receipt Header", selection: $profile.receiptHeader.mode) {
                ForEach(ReceiptHeaderMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityHint("Choose Made to Keep branding, event artwork, or no receipt header.")

            if profile.receiptHeader.mode == .customEventHeader {
                if let artwork {
                    EventArtworkSummaryCard(
                        thermalImage: thermalImage,
                        kind: artwork.kind,
                        warnings: warnings,
                        edit: { isEditorPresented = true },
                        changeFromPhotos: { isPhotoPickerPresented = true },
                        changeFromFiles: { isFileImporterPresented = true },
                        remove: removeArtwork
                    )
                } else {
                    VStack(spacing: 12) {
                        ContentUnavailableView(
                            "Choose Event Artwork",
                            systemImage: "photo.badge.plus",
                            description: Text(loadError ?? "Best results: transparent PNG or vector PDF. JPEG also works.")
                        )
                        ArtworkSourceMenu(
                            title: "Choose Artwork",
                            choosePhoto: { isPhotoPickerPresented = true },
                            chooseFile: { isFileImporterPresented = true }
                        )
                        .disabled(isImporting)
                    }
                    .frame(maxWidth: .infinity, minHeight: 150)
                }
                if isImporting {
                    ProgressView("Preparing artwork…")
                }
                if let loadError, artwork != nil {
                    Label(loadError, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }

            Toggle(
                profile.receiptHeader.mode == .customEventHeader ? "Show event details below artwork" : "Show event details below header",
                isOn: $profile.showEventTextBlock
            )
            .accessibilityHint("Shows the event name, host, date, location and message below the receipt header.")

            Text("Saved changes apply to the next customer. A session already in progress keeps its frozen artwork and receipt settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onAppear { reloadAsset() }
        .onChange(of: profile.receiptHeader) { _, _ in scheduleProcessing() }
        .onChange(of: photoItem) { _, item in importPhoto(item) }
        .photosPicker(isPresented: $isPhotoPickerPresented, selection: $photoItem, matching: .images)
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: [.png, .jpeg, .pdf],
            allowsMultipleSelection: false,
            onCompletion: importFile
        )
        .fullScreenCover(isPresented: $isEditorPresented) {
            if let artwork {
                NavigationStack {
                    EventArtworkEditorView(artwork: artwork, profile: $profile)
                }
            }
        }
        .onDisappear { processingTask?.cancel() }
    }

    private func removeArtwork() {
        // Only the reference is cleared. The immutable asset file stays on disk so any session
        // or archive that froze this identifier can still resolve it.
        profile.receiptHeader.assetIdentifier = nil
        artwork = nil
        thermalImage = nil
        warnings = []
        loadError = nil
    }

    private func reloadAsset() {
        guard let store = try? EventHeaderAssetStore(),
              let loaded = store.loadArtwork(identifier: profile.receiptHeader.assetIdentifier) else {
            if profile.receiptHeader.assetIdentifier != nil {
                loadError = "The saved artwork is missing. Choose a replacement; new receipts will safely use the Made to Keep header until then."
            }
            artwork = nil
            return
        }
        artwork = loaded
        loadError = nil
        scheduleProcessing()
    }

    private func importPhoto(_ item: PhotosPickerItem?) {
        guard let item else { return }
        Task {
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    throw EventHeaderAssetStoreError.unsupportedOrCorruptImage
                }
                try await importData(data)
            } catch {
                loadError = error.localizedDescription
                isImporting = false
            }
        }
    }

    private func importFile(_ result: Result<[URL], Error>) {
        Task {
            do {
                let url = try result.get().first ?? { throw EventHeaderAssetStoreError.unsupportedOrCorruptImage }()
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                try await importData(Data(contentsOf: url))
            } catch {
                loadError = error.localizedDescription
                isImporting = false
            }
        }
    }

    private func importData(_ data: Data) async throws {
        isImporting = true
        defer { isImporting = false }
        let result = try await Task.detached(priority: .userInitiated) {
            let store = try EventHeaderAssetStore()
            let identifier = try store.importArtworkData(data)
            guard let artwork = store.loadArtwork(identifier: identifier) else {
                throw EventHeaderAssetStoreError.encodingFailed
            }
            return (identifier, artwork)
        }.value

        profile.receiptHeader.assetIdentifier = result.0
        // New artwork always starts from the safe automatic layout (centered, whole artwork,
        // default size and spacing). Saved artwork keeps its adjustments; only replacement resets.
        profile.receiptHeader.mode = .customEventHeader
        profile.receiptHeader.resetAdjustments()
        photoItem = nil
        artwork = result.1
        loadError = nil
        statusMessage = "Artwork ready. Save to apply it to future sessions."
        scheduleProcessing()
    }

    /// Debounced and generation-checked so a slow render never overwrites newer settings.
    private func scheduleProcessing() {
        processingTask?.cancel()
        guard let artwork else { return }
        processingGeneration += 1
        let generation = processingGeneration
        let configuration = profile.receiptHeader.normalized()
        processingTask = Task {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            let result = await Task.detached(priority: .utility) {
                let preview = try? EventHeaderImageProcessor.thermalPreview(source: artwork, configuration: configuration)
                let warnings = EventHeaderImageProcessor.qualityWarnings(for: artwork, configuration: configuration)
                return (preview, warnings)
            }.value
            guard !Task.isCancelled, generation == processingGeneration else { return }
            thermalImage = result.0
            warnings = result.1
        }
    }
}

private struct ArtworkSourceMenu: View {
    let title: String
    let choosePhoto: () -> Void
    let chooseFile: () -> Void

    var body: some View {
        Menu {
            Button(action: choosePhoto) {
                Label("Photos", systemImage: "photo.on.rectangle")
            }
            Button(action: chooseFile) {
                Label("Files (PNG, JPEG or PDF)", systemImage: "folder")
            }
        } label: {
            Label(title, systemImage: "photo.badge.plus")
                .font(.headline)
                .frame(minHeight: 36)
        }
        .buttonStyle(.borderedProminent)
        .accessibilityHint("Choose artwork from Photos or Files.")
    }
}

private struct EventArtworkSummaryCard: View {
    let thermalImage: UIImage?
    let kind: EventArtworkKind
    let warnings: [EventHeaderQualityWarning]
    let edit: () -> Void
    let changeFromPhotos: () -> Void
    let changeFromFiles: () -> Void
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack {
                Color.white
                if let thermalImage {
                    Image(uiImage: thermalImage)
                        .resizable()
                        .interpolation(.none)
                        .scaledToFit()
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, minHeight: 90, maxHeight: 200)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).stroke(.secondary.opacity(0.25)) }
            .accessibilityLabel("Thermal print preview of the event artwork")

            HStack(spacing: 8) {
                if warnings.isEmpty {
                    Label("Optimized for thermal printing", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Label("\(warnings.count) print \(warnings.count == 1 ? "note" : "notes")", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                Spacer()
                Text(kind == .vector ? "Vector PDF" : "Image")
                    .foregroundStyle(.secondary)
            }
            .font(.footnote)

            ForEach(warnings, id: \.self) { warning in
                Text(warning.message)
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }

            HStack(spacing: 10) {
                Button(action: edit) {
                    Label("Edit Artwork", systemImage: "slider.horizontal.below.rectangle")
                        .font(.headline)
                        .frame(minHeight: 36)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityHint("Opens the receipt artwork editor.")

                Menu {
                    Button(action: changeFromPhotos) { Label("Photos", systemImage: "photo.on.rectangle") }
                    Button(action: changeFromFiles) { Label("Files (PNG, JPEG or PDF)", systemImage: "folder") }
                } label: {
                    Label("Change Artwork", systemImage: "arrow.triangle.2.circlepath")
                        .frame(minHeight: 36)
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("Remove Artwork", role: .destructive, action: remove)
                    .buttonStyle(.bordered)
            }
        }
    }
}
