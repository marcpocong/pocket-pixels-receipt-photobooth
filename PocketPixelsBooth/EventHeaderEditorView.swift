//
//  EventHeaderEditorView.swift
//  PocketPixelsBooth
//

import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct EventHeaderEditorView: View {
    @Binding var profile: EventProfile
    @Binding var statusMessage: String

    @State private var photoItem: PhotosPickerItem?
    @State private var isPhotoPickerPresented = false
    @State private var isFileImporterPresented = false
    @State private var sourceImage: UIImage?
    @State private var thermalImage: UIImage?
    @State private var warnings: [EventHeaderQualityWarning] = []
    @State private var processingTask: Task<Void, Never>?
    @State private var isCropEditorPresented = false
    @State private var loadError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("Receipt Header", selection: $profile.receiptHeader.mode) {
                ForEach(ReceiptHeaderMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityHint("Choose Pocket Pixels branding, an event image, or no receipt header.")

            if profile.receiptHeader.mode == .customEventHeader {
                EventImageSourceControls(
                    hasImage: profile.receiptHeader.assetIdentifier != nil,
                    choosePhoto: { isPhotoPickerPresented = true },
                    chooseFile: { isFileImporterPresented = true },
                    removeImage: removeImage
                )

                if sourceImage != nil {
                    EventImagePrintPreview(image: thermalImage)

                    if warnings.isEmpty {
                        Label("Optimized for thermal printing", systemImage: "checkmark.circle.fill")
                            .font(.footnote)
                            .foregroundStyle(.green)
                    } else {
                        EventImageWarnings(warnings: warnings)
                    }

                    EventImageAdvancedAdjustments(
                        configuration: $profile.receiptHeader,
                        editCrop: { isCropEditorPresented = true }
                    )
                } else {
                    ContentUnavailableView(
                        "Choose an Event Image",
                        systemImage: "photo.badge.plus",
                        description: Text(loadError ?? "Choose a PNG or JPEG. Pocket Pixels will prepare it for thermal printing.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 150)
                }
            }

            Toggle(
                profile.receiptHeader.mode == .customEventHeader ? "Show event details below image" : "Show event details below header",
                isOn: $profile.showEventTextBlock
            )
                .accessibilityHint("Shows the event name, host, date, location and message below the receipt header.")

            Text("Saved changes apply to the next customer. A session already in progress keeps its frozen image and receipt settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onAppear { reloadAsset() }
        .onChange(of: profile.receiptHeader) { _, _ in scheduleProcessing() }
        .onChange(of: photoItem) { _, item in importPhoto(item) }
        .photosPicker(isPresented: $isPhotoPickerPresented, selection: $photoItem, matching: .images)
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: [.png, .jpeg],
            allowsMultipleSelection: false,
            onCompletion: importFile
        )
        .sheet(isPresented: $isCropEditorPresented) {
            if let sourceImage {
                NavigationStack {
                    EventHeaderCropEditor(sourceImage: sourceImage, configuration: $profile.receiptHeader)
                }
            }
        }
        .onDisappear { processingTask?.cancel() }
    }

    private func removeImage() {
        profile.receiptHeader.assetIdentifier = nil
        sourceImage = nil
        thermalImage = nil
        warnings = []
        loadError = nil
    }

    private func reloadAsset() {
        guard let store = try? EventHeaderAssetStore(),
              let image = store.loadImage(identifier: profile.receiptHeader.assetIdentifier) else {
            if profile.receiptHeader.assetIdentifier != nil {
                loadError = "The saved event image is missing. Choose a replacement; new receipts will safely use the Pocket Pixels header until then."
            }
            sourceImage = nil
            return
        }
        sourceImage = image
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
                await MainActor.run { loadError = error.localizedDescription }
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
                await MainActor.run { loadError = error.localizedDescription }
            }
        }
    }

    private func importData(_ data: Data) async throws {
        let result = try await Task.detached(priority: .userInitiated) {
            let store = try EventHeaderAssetStore()
            let identifier = try store.importImageData(data)
            guard let image = store.loadImage(identifier: identifier) else {
                throw EventHeaderAssetStoreError.encodingFailed
            }
            return (identifier, image)
        }.value

        profile.receiptHeader.assetIdentifier = result.0
        // A newly chosen image always starts from the safe automatic layout (centered, fit,
        // default size and spacing). Saved images keep their adjustments; only replacement resets.
        profile.receiptHeader.mode = .customEventHeader
        profile.receiptHeader.resetAdjustments()
        photoItem = nil
        sourceImage = result.1
        loadError = nil
        statusMessage = "Event image ready. Save to apply it to future sessions."
        scheduleProcessing()
    }

    private func scheduleProcessing() {
        processingTask?.cancel()
        guard let sourceImage else { return }
        let configuration = profile.receiptHeader.normalized()
        processingTask = Task {
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            let result = await Task.detached(priority: .utility) {
                let preview = try? EventHeaderImageProcessor.thermalPreview(
                    source: sourceImage,
                    configuration: configuration
                )
                let warnings = EventHeaderImageProcessor.qualityWarnings(
                    for: sourceImage,
                    configuration: configuration
                )
                return (preview, warnings)
            }.value
            guard !Task.isCancelled else { return }
            thermalImage = result.0
            warnings = result.1
        }
    }
}

private struct EventImageSourceControls: View {
    let hasImage: Bool
    let choosePhoto: () -> Void
    let chooseFile: () -> Void
    let removeImage: () -> Void

    var body: some View {
        HStack {
            Menu {
                Button(action: choosePhoto) {
                    Label("Photos", systemImage: "photo.on.rectangle")
                }
                Button(action: chooseFile) {
                    Label("Files", systemImage: "folder")
                }
            } label: {
                Label(hasImage ? "Change Image" : "Choose Image", systemImage: "photo.badge.plus")
                    .font(.headline)
                    .frame(minHeight: 36)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityHint("Choose an image from Photos or Files.")

            Spacer()

            if hasImage {
                Button("Remove", role: .destructive, action: removeImage)
                    .buttonStyle(.bordered)
            }
        }
    }
}

private struct EventImagePrintPreview: View {
    let image: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Print Preview")
                .font(.headline)
            ZStack {
                Color.white
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding(12)
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, minHeight: 150, maxHeight: 240)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).stroke(.secondary.opacity(0.25)) }
            .accessibilityLabel("Thermal print preview of the event image")

            Text("Shown as it will print. Use Preview Event for the full receipt.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct EventImageWarnings: View {
    let warnings: [EventHeaderQualityWarning]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(warnings, id: \.self) { warning in
                Label(warning.message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        }
        .font(.footnote)
    }
}

private struct EventImageAdvancedAdjustments: View {
    @Binding var configuration: ReceiptHeaderConfiguration
    let editCrop: () -> Void

    var body: some View {
        DisclosureGroup("Advanced Adjustments") {
            VStack(alignment: .leading, spacing: 14) {
                Button("Crop & Position", action: editCrop)

                adjustmentSlider(
                    "Size",
                    value: $configuration.scale,
                    range: ReceiptHeaderConfiguration.minimumScale...ReceiptHeaderConfiguration.maximumScale
                )

                Picker("Alignment", selection: $configuration.alignment) {
                    ForEach(ReceiptHeaderAlignment.allCases) { alignment in
                        Text(alignment.displayName).tag(alignment)
                    }
                }
                .pickerStyle(.segmented)

                Picker("Fit", selection: $configuration.layoutMode) {
                    ForEach(ReceiptHeaderLayoutMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                adjustmentSlider(
                    "Top Spacing",
                    value: $configuration.topSpacing,
                    range: 0...ReceiptHeaderConfiguration.maximumSpacing
                )
                adjustmentSlider(
                    "Bottom Spacing",
                    value: $configuration.bottomSpacing,
                    range: 0...ReceiptHeaderConfiguration.maximumSpacing
                )

                Button("Reset Adjustments") { configuration.resetAdjustments() }
            }
            .padding(.top, 8)
        }
    }

    private func adjustmentSlider(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>
    ) -> some View {
        VStack(alignment: .leading) {
            Text(title)
            Slider(value: value, in: range)
        }
    }
}

private struct EventHeaderCropEditor: View {
    let sourceImage: UIImage
    @Binding var configuration: ReceiptHeaderConfiguration
    @Environment(\.dismiss) private var dismiss
    @State private var dragStart = CGPoint.zero
    @State private var zoomStart = 1.0

    var body: some View {
        VStack(spacing: 20) {
            Text("Pinch to zoom and drag to position the artwork inside the printed header frame.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            GeometryReader { proxy in
                let result = EventHeaderImageProcessor.renderedHeader(
                    source: sourceImage,
                    configuration: configuration,
                    receiptWidth: min(576, proxy.size.width)
                )
                Image(uiImage: result.image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay { Rectangle().stroke(.primary, lineWidth: 2) }
                    .contentShape(Rectangle())
                    .gesture(dragGesture)
                    .simultaneousGesture(magnifyGesture)
            }
            .frame(height: 300)

            Button("Reset") { configuration.resetAdjustments() }
                .buttonStyle(.bordered)
        }
        .padding()
        .navigationTitle("Crop & Position")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                if value.translation == .zero {
                    dragStart = CGPoint(
                        x: configuration.cropPositionX,
                        y: configuration.cropPositionY
                    )
                }
                configuration.cropPositionX = min(1, max(-1, dragStart.x - value.translation.width / 140))
                configuration.cropPositionY = min(1, max(-1, dragStart.y - value.translation.height / 140))
            }
            .onEnded { _ in
                dragStart = CGPoint(
                    x: configuration.cropPositionX,
                    y: configuration.cropPositionY
                )
            }
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                configuration.cropZoom = min(
                    ReceiptHeaderConfiguration.maximumZoom,
                    max(1, zoomStart * value.magnification)
                )
            }
            .onEnded { _ in zoomStart = configuration.cropZoom }
    }
}
