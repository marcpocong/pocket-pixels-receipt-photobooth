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
            Picker("Branding Mode", selection: brandingMode) {
                ForEach(ReceiptBrandingMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityHint("Choose whether Made to Keep or the event artwork leads the printed receipt.")

            Text(brandingMode.wrappedValue.summary)
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Show Event Artwork", isOn: showsEventArtwork)
                .accessibilityHint("Shows configured artwork as a bottom signature in Studio-First or as the top masthead in Event-First.")

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

            if profile.receiptHeader.brandingMode == .eventFirst {
                Toggle("Show small Made to Keep credit", isOn: showsStudioCredit)
            }

            VStack(alignment: .leading, spacing: 6) {
                TextField("Event Editorial Caption", text: editorialCaption, axis: .vertical)
                    .lineLimit(2)
                Text("Optional, up to two short lines printed below the receipt footer. Leave blank for no caption.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Toggle(eventDetailsToggleTitle, isOn: $profile.showEventTextBlock)
                .accessibilityHint("Shows the event name, host, date, location and message on the receipt.")

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

    private var brandingMode: Binding<ReceiptBrandingMode> {
        Binding(
            get: { profile.receiptHeader.brandingMode ?? .studioFirst },
            set: { profile.receiptHeader.brandingMode = $0 }
        )
    }

    private var showsEventArtwork: Binding<Bool> {
        Binding(
            get: { profile.receiptHeader.mode == .customEventHeader },
            set: { profile.receiptHeader.mode = $0 ? .customEventHeader : .pocketPixelsDefault }
        )
    }

    private var showsStudioCredit: Binding<Bool> {
        Binding(
            get: { profile.receiptHeader.showsStudioCredit ?? false },
            set: { profile.receiptHeader.showsStudioCredit = $0 }
        )
    }

    /// Profiles saved before branding modes keep event details under the header; Studio-First and
    /// Event-First print them in the supplementary area below the footer.
    private var eventDetailsToggleTitle: String {
        guard profile.receiptHeader.brandingMode == nil else { return "Show event details below the footer" }
        return profile.receiptHeader.mode == .customEventHeader ? "Show event details below artwork" : "Show event details below header"
    }

    private var editorialCaption: Binding<String> {
        Binding(
            get: { profile.receiptDesign.editorialCaption },
            set: { profile.receiptDesign.editorialCaption = String($0.prefix(ReceiptEditorialCaption.inputLimit)) }
        )
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
        guard let item, !isImporting else { return }
        runImport { try await EventArtworkImporter.importPhoto(item) }
    }

    private func importFile(_ result: Result<[URL], Error>) {
        if case .failure(let error) = result, (error as NSError).code == NSUserCancelledError { return }
        guard !isImporting else { return }
        runImport { try await EventArtworkImporter.importFile(result) }
    }

    private func runImport(_ operation: @escaping () async throws -> EventArtworkImporter.Imported) {
        isImporting = true
        Task {
            defer { isImporting = false; photoItem = nil }
            do {
                let result = try await operation()
                profile.receiptHeader.assetIdentifier = result.identifier
                // New artwork always starts from the safe automatic layout (centered, whole artwork,
                // default size and spacing). Saved artwork keeps its adjustments; only replacement resets.
                profile.receiptHeader.mode = .customEventHeader
                profile.receiptHeader.resetAdjustments()
                artwork = result.artwork
                loadError = nil
                statusMessage = "Artwork ready. Save to apply it to future sessions."
                scheduleProcessing()
            } catch {
                loadError = error.localizedDescription
            }
        }
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
