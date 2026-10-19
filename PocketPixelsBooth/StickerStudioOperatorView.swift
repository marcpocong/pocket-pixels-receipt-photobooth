import SwiftUI
import UIKit

/// Local, persistent studio preferences. The bundled collection needs no setup or connection.
struct StickerStudioOperatorView: View {
    @State private var settings = StickerStudioSettingsStore.load()
    @State private var importedCount = 0

    var body: some View {
        Form {
            Section {
                Toggle("Enable Sticker Studio", isOn: binding(\.isEnabled))
            } header: {
                Text("Sticker Studio")
            } footer: {
                Text("Off means guests never see the sticker step. Changes apply to the next guest; their current draft stays intact.")
            }
            Section {
                Toggle(isOn: binding(\.emojiCollectionEnabled)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Emoji")
                        Text("Primary guest collection").font(.caption).foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Emoji catalog", value: emojiSummary)
                Toggle(isOn: binding(\.builtInStickersEnabled)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Original Made to Keep Artwork")
                        Text("Legacy · \(BundledStickerFactory.definitions.count) static stickers").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Toggle("Imported Operator Stickers", isOn: binding(\.operatorCollectionEnabled))
                NavigationLink {
                    OperatorStickerLibraryView()
                } label: {
                    LabeledContent("Manage Imported Stickers", value: "\(importedCount)")
                }
                Stepper(value: binding(\.guestStickerLimit), in: StickerStudioSettings.guestStickerLimitRange) {
                    LabeledContent("Maximum Stickers per Guest", value: "\(settings.guestStickerLimit)")
                }
            } header: {
                Text("Guest Collections")
            } footer: {
                Text("Emoji are standard Unicode emoji drawn by this iPad's system font, so they look like the emoji keyboard. Guests can also pick any emoji from the keyboard. Everything works offline. When both emoji and stickers are on, guests switch between them.")
            }
            Section {
                NavigationLink {
                    StickerStudioPreviewView(settings: settings)
                } label: {
                    Label("Preview Sticker Studio", systemImage: "eye")
                }
                .disabled(!settings.hasAnyLocalSource())
                NavigationLink {
                    EmojiPrintTestView()
                } label: {
                    Label("Emoji Print Preview Test", systemImage: "printer.dotmatrix")
                }
            } footer: {
                Text("Sample photos only. Nothing is printed, charged, uploaded or archived.")
            }
            Section {
                NavigationLink("Advanced Settings") {
                    Form {
                        Section("Print legibility") {
                            Stepper(value: binding(\.minimumPrintedStickerDots), in: StickerStudioSettings.minimumPrintedDotsRange, step: 8) {
                                LabeledContent("Smallest printed size", value: String(format: "%.0f mm", Double(settings.minimumPrintedStickerDots) / 8))
                            }
                        }
                        Section("Visible categories") {
                            ForEach(StickerCategory.assignableToImports) { category in
                                Toggle(category.operatorDisplayName, isOn: Binding(
                                    get: { !settings.hiddenCategories.contains(category) },
                                    set: { visible in
                                        if visible { settings.hiddenCategories.remove(category) }
                                        else { settings.hiddenCategories.insert(category) }
                                        save()
                                    }
                                ))
                            }
                        }
                    }
                    .navigationTitle("Advanced Sticker Settings")
                }
            }
        }
        .navigationTitle("Sticker Studio")
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: StickerCatalogStore.didChangeNotification)) { _ in reload() }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<StickerStudioSettings, Value>) -> Binding<Value> {
        Binding(get: { settings[keyPath: keyPath] }, set: { settings[keyPath: keyPath] = $0; save() })
    }

    private func save() {
        StickerStudioSettingsStore.save(settings)
        settings = StickerStudioSettingsStore.load()
    }

    private var emojiSummary: String {
        let catalog = EmojiCatalog.shared
        guard !catalog.groups.isEmpty else { return "Unavailable" }
        return "\(catalog.totalSelectableCount) emoji · Unicode \(catalog.unicodeVersion)"
    }

    private func reload() {
        settings = StickerStudioSettingsStore.load()
        importedCount = (try? StickerCatalogStore())?.records().count ?? 0
    }
}

// MARK: - Guest preview

/// The real guest editor on sample photos. Done shows the composed receipt and its exact
/// thermal raster preview in place — no view model, print, upload, archive or history.
struct StickerStudioPreviewView: View {
    let settings: StickerStudioSettings
    @State private var session: StickerStudioSession?
    @State private var result: (UIImage, UIImage)?
    @State private var message = "Preparing preview…"
    @State private var format: BoothFormat = .grid

    var body: some View {
        Group {
            if let result {
                GeometryReader { proxy in
                    HStack(alignment: .top, spacing: 24) {
                        previewColumn("Keepsake", image: result.0, rendering: .smooth)
                        previewColumn("Exact Printer Raster — Diagnostic", image: result.1, rendering: .exactRaster)
                    }
                    .padding(24)
                    .frame(height: proxy.size.height)
                }
                .toolbar {
                    Button("Edit Again") { self.result = nil }
                }
            } else if let session {
                StickerStudioView(
                    session: session,
                    onDone: { render(session.freeze()) },
                    onSkip: { render([]) },
                    onBack: { self.session = nil; prepare() },
                    onCancel: { self.session = nil; prepare() },
                    onActivity: { }
                )
                .background(MadeToKeepPaperBackground())
            } else {
                ProgressView(message)
            }
        }
        .navigationTitle("Sticker Studio Preview")
        .toolbar {
            Picker("Format", selection: $format) {
                ForEach(BoothFormat.allCases.filter { $0 != .passport }, id: \.self) { format in
                    Text(format.displayName).tag(format)
                }
            }
            .pickerStyle(.menu)
        }
        .onChange(of: format) { _, _ in
            session?.close()
            session = nil
            result = nil
            prepare()
        }
        .task { if session == nil { prepare() } }
        .onDisappear { session?.close() }
    }

    private func previewColumn(_ title: String, image: UIImage, rendering: OperatorZoomableReceiptView.Rendering) -> some View {
        VStack(spacing: 8) {
            Text(title).font(.headline)
            OperatorZoomableReceiptView(image: image, rendering: rendering, accessibilityLabel: title)
        }
        .frame(maxWidth: .infinity)
    }

    private func prepare() {
        var previewSettings = settings
        previewSettings.isEnabled = true
        let configuration = StickerStudioSessionConfiguration.current(settings: previewSettings)
        let format = self.format
        let photos = Self.samplePhotos(count: format.photoCount)
        Task {
            let prepared = await Task.detached(priority: .userInitiated) { () -> (UIImage, StickerLayoutSnapshot)? in
                guard let receipt = try? ReceiptComposer.compose(photos: photos, sessionIdentifier: "STICKER-PREVIEW", format: format),
                      let layout = receipt.stickerLayout,
                      let image = UIImage(data: receipt.imagePNGData) else { return nil }
                return (ReceiptComposer.makePhotoSectionPreviewImage(from: image, previewContentHeight: layout.editorVisibleHeight), layout)
            }.value
            guard let prepared else {
                message = "The preview could not be prepared."
                return
            }
            let store = configuration.settings.operatorCollectionEnabled ? try? StickerCatalogStore() : nil
            let studio = StickerStudioSession(
                configuration: configuration,
                catalog: StickerGuestCatalog.make(settings: configuration.settings, store: store),
                generation: 0,
                catalogStore: store,
                provider: nil
            )
            studio.setCanvas(image: prepared.0, layout: prepared.1)
            session = studio
        }
    }

    private func render(_ stickers: [FrozenStickerDecoration]) {
        let format = self.format
        let photos = Self.samplePhotos(count: format.photoCount)
        message = "Rendering…"
        Task {
            let rendered = await Task.detached(priority: .userInitiated) { () -> (UIImage, UIImage)? in
                guard let receipt = try? ReceiptComposer.compose(photos: photos, sessionIdentifier: "STICKER-PREVIEW", format: format, stickers: stickers),
                      let image = UIImage(data: receipt.imagePNGData),
                      let raster = try? ThermalImageRasterizer.rasterize(image, purpose: .completeReceipt),
                      let thermal = UIImage(data: raster.previewPNGData) else { return nil }
                return (image, thermal)
            }.value
            result = rendered
            if rendered == nil { message = "The preview could not be rendered." }
        }
    }

    /// Neutral synthetic portraits; no customer photo is ever used for the operator preview.
    nonisolated static func samplePhotos(count: Int) -> [UIImage] {
        (0..<count).map { index in
            let size = CGSize(width: 900, height: 1200)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            return UIGraphicsImageRenderer(size: size, format: format).image { context in
                let cg = context.cgContext
                let colors = [UIColor(white: 0.86 - CGFloat(index) * 0.04, alpha: 1).cgColor, UIColor(white: 0.5, alpha: 1).cgColor] as CFArray
                if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                    cg.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
                }
                UIColor(white: 0.3, alpha: 1).setFill()
                cg.fillEllipse(in: CGRect(x: size.width * 0.32, y: size.height * 0.22, width: size.width * 0.36, height: size.width * 0.44))
                cg.fillEllipse(in: CGRect(x: size.width * 0.12, y: size.height * 0.6, width: size.width * 0.76, height: size.height * 0.6))
            }
        }
    }
}

// MARK: - Emoji print test

/// Places representative emoji (ordinary, skin tone, flag, ZWJ family, selector, tag flag) on
/// synthetic photos and shows the keepsake and the exact printer raster. Nothing is printed,
/// charged, uploaded or archived; no guest session or view model is involved.
struct EmojiPrintTestView: View {
    static let samples = ["😀", "👍🏽", "🇵🇭", "👨‍👩‍👧‍👦", "❤️", "🏳️‍🌈"]
    @State private var format: BoothFormat = .grid
    @State private var result: (keepsake: UIImage, raster: UIImage)?
    @State private var message = "Rendering emoji on sample photos…"
    @State private var task: Task<Void, Never>?

    var body: some View {
        GeometryReader { proxy in
            VStack(alignment: .leading, spacing: 12) {
                Text("Sample photos with \(Self.samples.joined(separator: " ")). Check the raster for faint or clipped emoji before an event.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if let result {
                    HStack(alignment: .top, spacing: 24) {
                        column("Keepsake", image: result.keepsake, rendering: .smooth)
                        column("Exact Printer Raster — Diagnostic", image: result.raster, rendering: .exactRaster)
                    }
                    .frame(height: max(300, proxy.size.height - 70))
                } else {
                    ProgressView(message).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .padding(24)
        }
        .navigationTitle("Emoji Print Preview Test")
        .toolbar {
            Picker("Format", selection: $format) {
                ForEach(BoothFormat.allCases.filter { $0 != .passport }, id: \.self) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.menu)
        }
        .task(id: format) { render() }
        .onDisappear { task?.cancel() }
    }

    private func column(_ title: String, image: UIImage, rendering: OperatorZoomableReceiptView.Rendering) -> some View {
        VStack(spacing: 8) {
            Text(title).font(.headline)
            OperatorZoomableReceiptView(image: image, rendering: rendering, accessibilityLabel: title)
        }
        .frame(maxWidth: .infinity)
    }

    private func render() {
        task?.cancel()
        result = nil
        message = "Rendering emoji on sample photos…"
        let format = self.format
        task = Task {
            let rendered = await Task.detached(priority: .userInitiated) { () -> (UIImage, UIImage)? in
                Self.renderSample(format: format)
            }.value
            guard !Task.isCancelled else { return }
            if let rendered { result = (rendered.0, rendered.1) } else { message = "The emoji preview could not be rendered." }
        }
    }

    nonisolated static func renderSample(format: BoothFormat) -> (UIImage, UIImage)? {
        let photos = StickerStudioPreviewView.samplePhotos(count: format.photoCount)
        guard let base = try? ReceiptComposer.compose(photos: photos, sessionIdentifier: "EMOJI-PREVIEW", format: format),
              let layout = base.stickerLayout, !layout.regions.isEmpty else { return nil }
        var decorations: [FrozenStickerDecoration] = []
        for (index, glyph) in samples.enumerated() {
            guard let artwork = try? EmojiStickerRenderer.makeArtwork(for: glyph) else { continue }
            let region = layout.regions[index % layout.regions.count]
            let perRegion = Double(index / layout.regions.count)
            let placement = StickerPlacement(
                id: UUID(), assetID: StickerStudioSession.emojiAssetID(for: glyph), assetName: glyph, provenance: .systemEmoji,
                frameIndex: 0, target: region.target, centerX: 0.32 + perRegion * 0.36, centerY: 0.38 + perRegion * 0.3,
                scale: 0.4, rotation: 0, zOrder: index, aspectRatio: artwork.aspectRatio)
            decorations.append(FrozenStickerDecoration(placement: StickerGeometry.clamped(placement, in: region, minimumPrintedDots: StickerStudioSettings.defaultMinimumPrintedDots), printImage: artwork.print))
        }
        guard let receipt = try? ReceiptComposer.compose(photos: photos, sessionIdentifier: "EMOJI-PREVIEW", format: format, stickers: decorations),
              let image = UIImage(data: receipt.imagePNGData),
              let raster = try? ThermalImageRasterizer.rasterize(image, purpose: .completeReceipt),
              let thermal = UIImage(data: raster.previewPNGData) else { return nil }
        return (image, thermal)
    }
}
