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
    @State private var isFileImporterPresented = false
    @State private var sourceImage: UIImage?
    @State private var thermalImage: UIImage?
    @State private var warnings: [EventHeaderQualityWarning] = []
    @State private var processingTask: Task<Void, Never>?
    @State private var isCropEditorPresented = false
    @State private var loadError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Header Style", selection: $profile.receiptHeader.mode) {
                ForEach(ReceiptHeaderMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.inline)

            if profile.receiptHeader.mode == .customEventHeader {
                imageControls

                if let sourceImage {
                    previewGrid(sourceImage: sourceImage)
                    qualityView
                    adjustmentControls
                } else {
                    ContentUnavailableView(
                        "Choose a Header Image",
                        systemImage: "photo.badge.plus",
                        description: Text(loadError ?? "Select a PNG or JPEG from Photos or Files.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 150)
                }
            }

            Toggle("Show Event Text Block", isOn: $profile.showEventTextBlock)
                .accessibilityHint("Shows the event name, host, date, location and message below the receipt header.")

            Text("Saved changes apply to the next customer. A session already in progress keeps its frozen header and receipt settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onAppear { reloadAsset() }
        .onChange(of: profile.receiptHeader) { _, _ in scheduleProcessing() }
        .onChange(of: profile.receiptHeader.mode) { _, mode in
            if mode != .pocketPixelsDefault { profile.isEnabled = true }
        }
        .onChange(of: photoItem) { _, item in importPhoto(item) }
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

    private var imageControls: some View {
        HStack {
            PhotosPicker(selection: $photoItem, matching: .images) {
                Label(profile.receiptHeader.assetIdentifier == nil ? "Choose Header Image" : "Replace from Photos", systemImage: "photo.on.rectangle")
            }
            Button {
                isFileImporterPresented = true
            } label: {
                Label(profile.receiptHeader.assetIdentifier == nil ? "Choose from Files" : "Replace from Files", systemImage: "folder")
            }
            if profile.receiptHeader.assetIdentifier != nil {
                Button("Remove Custom Header", role: .destructive) {
                    profile.receiptHeader.assetIdentifier = nil
                    sourceImage = nil
                    thermalImage = nil
                    warnings = []
                    loadError = nil
                }
            }
        }
        .buttonStyle(.bordered)
    }

    private func previewGrid(sourceImage: UIImage) -> some View {
        HStack(alignment: .top, spacing: 12) {
            previewCard(title: "Original", image: sourceImage)
            previewCard(title: "Thermal", image: thermalImage)
        }
    }

    private func previewCard(title: String, image: UIImage?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).font(.caption.bold()).foregroundStyle(.secondary)
            ZStack {
                Color.white
                if let image {
                    Image(uiImage: image).resizable().scaledToFit().padding(8)
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, minHeight: 120, maxHeight: 180)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).stroke(.secondary.opacity(0.25)) }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var qualityView: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("PRINT QUALITY").font(.caption.bold()).foregroundStyle(.secondary)
            if warnings.isEmpty {
                Label("Looks good for thermal printing.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                ForEach(warnings, id: \.self) { warning in
                    Label(warning.message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }
        }
        .font(.footnote)
    }

    private var adjustmentControls: some View {
        DisclosureGroup("Adjust Header") {
            VStack(alignment: .leading, spacing: 12) {
                slider("Size", value: $profile.receiptHeader.scale, range: ReceiptHeaderConfiguration.minimumScale...ReceiptHeaderConfiguration.maximumScale)
                Picker("Alignment", selection: $profile.receiptHeader.alignment) {
                    ForEach(ReceiptHeaderAlignment.allCases) { Text($0.displayName).tag($0) }
                }.pickerStyle(.segmented)
                Picker("Layout", selection: $profile.receiptHeader.layoutMode) {
                    ForEach(ReceiptHeaderLayoutMode.allCases) { Text($0.displayName).tag($0) }
                }.pickerStyle(.segmented)
                slider("Top Spacing", value: $profile.receiptHeader.topSpacing, range: 0...ReceiptHeaderConfiguration.maximumSpacing)
                slider("Bottom Spacing", value: $profile.receiptHeader.bottomSpacing, range: 0...ReceiptHeaderConfiguration.maximumSpacing)
                Button("Edit Crop / Position") { isCropEditorPresented = true }
                Button("Reset Adjustments") { profile.receiptHeader.resetAdjustments() }
            }
            .padding(.top, 8)
        }
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading) {
            Text(title)
            Slider(value: value, in: range)
        }
    }

    private func reloadAsset() {
        guard let store = try? EventHeaderAssetStore(),
              let image = store.loadImage(identifier: profile.receiptHeader.assetIdentifier) else {
            if profile.receiptHeader.assetIdentifier != nil {
                loadError = "The saved header image is missing. Choose a replacement; new receipts will safely use the Pocket Pixels header until then."
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
                guard let data = try await item.loadTransferable(type: Data.self) else { throw EventHeaderAssetStoreError.unsupportedOrCorruptImage }
                try await importData(data)
            } catch { await MainActor.run { loadError = error.localizedDescription } }
        }
    }

    private func importFile(_ result: Result<[URL], Error>) {
        Task {
            do {
                let url = try result.get().first ?? { throw EventHeaderAssetStoreError.unsupportedOrCorruptImage }()
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                try await importData(Data(contentsOf: url))
            } catch { await MainActor.run { loadError = error.localizedDescription } }
        }
    }

    private func importData(_ data: Data) async throws {
        let result = try await Task.detached(priority: .userInitiated) {
            let store = try EventHeaderAssetStore()
            let identifier = try store.importImageData(data)
            guard let image = store.loadImage(identifier: identifier) else { throw EventHeaderAssetStoreError.encodingFailed }
            return (identifier, image)
        }.value
        profile.receiptHeader.assetIdentifier = result.0
        profile.receiptHeader.mode = .customEventHeader
        profile.isEnabled = true
        profile.receiptHeader.resetAdjustments()
        sourceImage = result.1
        loadError = nil
        statusMessage = "Header image ready. Save to apply it to future sessions."
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
                let preview = try? EventHeaderImageProcessor.thermalPreview(source: sourceImage, configuration: configuration)
                let warnings = EventHeaderImageProcessor.qualityWarnings(for: sourceImage, configuration: configuration)
                return (preview, warnings)
            }.value
            guard !Task.isCancelled else { return }
            thermalImage = result.0
            warnings = result.1
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
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            GeometryReader { proxy in
                let result = EventHeaderImageProcessor.renderedHeader(source: sourceImage, configuration: configuration, receiptWidth: min(576, proxy.size.width))
                Image(uiImage: result.image)
                    .resizable().scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay { Rectangle().stroke(.primary, lineWidth: 2) }
                    .contentShape(Rectangle())
                    .gesture(dragGesture)
                    .simultaneousGesture(magnifyGesture)
            }
            .frame(height: 300)
            Button("Reset") { configuration.resetAdjustments() }.buttonStyle(.bordered)
        }
        .padding()
        .navigationTitle("Crop & Position")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                if value.translation == .zero { dragStart = CGPoint(x: configuration.cropPositionX, y: configuration.cropPositionY) }
                configuration.cropPositionX = min(1, max(-1, dragStart.x - value.translation.width / 140))
                configuration.cropPositionY = min(1, max(-1, dragStart.y - value.translation.height / 140))
            }
            .onEnded { _ in dragStart = CGPoint(x: configuration.cropPositionX, y: configuration.cropPositionY) }
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                configuration.cropZoom = min(ReceiptHeaderConfiguration.maximumZoom, max(1, zoomStart * value.magnification))
            }
            .onEnded { _ in zoomStart = configuration.cropZoom }
    }
}
