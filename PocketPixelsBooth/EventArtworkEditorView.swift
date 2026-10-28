//
//  EventArtworkEditorView.swift
//  PocketPixelsBooth
//
//  Receipt Artwork Editor: places event artwork at the top of an 80 mm (576-dot) receipt.
//  Every control edits ReceiptHeaderConfiguration, whose normalization keeps the geometry valid,
//  and the canvas is drawn with the same frame maths and renderer as the printed receipt.
//

import SwiftUI
import UIKit

struct EventArtworkEditorView: View {
    let artwork: EventArtwork
    @Binding var profile: EventProfile

    @Environment(\.dismiss) private var dismiss
    @State private var previewMode: ArtworkPreviewMode = .original
    @State private var thermalStrip: UIImage?
    @State private var thermalGeneration = 0
    @State private var thermalTask: Task<Void, Never>?
    @State private var gestureStart: ReceiptHeaderConfiguration?
    /// On-screen canvas width; converts drag distance into printer dots.
    @State private var canvasWidth: CGFloat = 576

    private var configuration: ReceiptHeaderConfiguration { profile.receiptHeader.normalized() }
    /// Co-Branded places the logo beside the Made to Keep wordmark; the canvas shows that lockup.
    private var isCoBranded: Bool { configuration.brandingMode == .coBranded }
    private var coBrandedProfile: EventProfile {
        var value = profile
        value.isEnabled = true
        value.showEventTextBlock = false
        value.receiptHeader.mode = .customEventHeader
        return value
    }

    var body: some View {
        GeometryReader { proxy in
            let isWide = proxy.size.width > proxy.size.height
            Group {
                if isWide {
                    HStack(alignment: .top, spacing: 24) {
                        canvasColumn.frame(maxWidth: .infinity)
                        ScrollView { controls }
                            .frame(width: min(420, proxy.size.width * 0.42))
                    }
                } else {
                    ScrollView {
                        VStack(spacing: 24) {
                            canvasColumn
                            controls
                        }
                    }
                }
            }
            .padding(20)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("Edit Artwork")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Reset", role: .destructive) { resetLayout() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
                    .fontWeight(.semibold)
            }
        }
        .onAppear { scheduleThermal() }
        .onChange(of: configuration) { _, _ in scheduleThermal() }
        .onChange(of: previewMode) { _, _ in scheduleThermal() }
        .onDisappear { thermalTask?.cancel() }
    }

    // MARK: Canvas

    private var canvasColumn: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Preview", selection: $previewMode) {
                ForEach(ArtworkPreviewMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityHint("Original shows the artwork on paper. Thermal shows it after printer conversion.")

            ArtworkReceiptCanvas(
                strip: previewMode == .original ? originalStrip : thermalStrip,
                frame: stripFrame,
                isProcessing: previewMode == .thermal && thermalStrip == nil
            )
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { canvasWidth = max(1, $0) }
            .gesture(dragGesture, including: isCoBranded ? .none : .all)
            .simultaneousGesture(magnifyGesture, including: isCoBranded ? .none : .all)

            Text(gestureHint)
                .font(.footnote)
                .foregroundStyle(.secondary)

            NavigationLink {
                ScrollView {
                    EventReceiptComposerPreview(profile: EventSetupPreview.previewProfile(for: profile))
                        .padding()
                }
                .navigationTitle("Receipt Preview")
                .navigationBarTitleDisplayMode(.inline)
            } label: {
                Label("Preview Full Receipt", systemImage: "doc.richtext")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .accessibilityHint("Shows the artwork with event details, sample photos and the QR footer. Nothing prints.")
        }
    }

    private var originalStrip: UIImage {
        if isCoBranded { return ReceiptComposer.renderHeaderStrip(eventProfile: coBrandedProfile).image }
        return EventHeaderImageProcessor.receiptStrip(source: artwork, configuration: configuration).image
    }

    /// Same placement maths as the receipt, without rendering.
    private var stripFrame: CGRect {
        if isCoBranded, let frame = ReceiptComposer.renderHeaderStrip(eventProfile: coBrandedProfile).artworkFrame { return frame }
        return EventHeaderImageProcessor.frameRect(
            sourceSize: artwork.size,
            configuration: configuration,
            y: CGFloat(Int(configuration.topSpacing.rounded()))
        )
    }

    private var overflow: CGSize {
        let frame = stripFrame
        let draw = EventHeaderImageProcessor.sourceDrawRect(sourceSize: artwork.size, frameSize: frame.size, configuration: configuration)
        return CGSize(width: max(0, draw.width - frame.width), height: max(0, draw.height - frame.height))
    }

    private var canCrop: Bool { overflow.width > 0.5 || overflow.height > 0.5 }

    private var gestureHint: String {
        isCoBranded ? "Use Adjust Header to position either identity or both together." : canCrop
            ? "Drag to reposition the artwork inside its frame. Pinch to zoom."
            : "Drag to move the artwork left or right. Pinch to resize."
    }

    // MARK: Gestures

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                let start = gestureStart ?? configuration
                if gestureStart == nil { gestureStart = start }
                // Canvas points → printer dots. The canvas shows the full 576-dot width.
                let dots = CGFloat(BoothConfiguration.receiptWidth) / max(1, canvasWidth)
                let dx = value.translation.width * dots
                let dy = value.translation.height * dots
                var updated = start
                if canCrop {
                    if overflow.width > 0.5 {
                        updated.cropPositionX = clamp(start.cropPositionX - Double(dx / (overflow.width / 2)), -1, 1)
                    }
                    if overflow.height > 0.5 {
                        updated.cropPositionY = clamp(start.cropPositionY - Double(dy / (overflow.height / 2)), -1, 1)
                    }
                } else if isCoBranded {
                    let available = CoBrandedHeaderGeometry.slotWidth() - stripFrame.width
                    guard available > 0.5 else { return }
                    updated.horizontalPosition = clamp(start.effectiveHorizontalPosition + Double(2 * dx / available), -1, 1)
                } else {
                    let available = CGFloat(BoothConfiguration.receiptWidth) - EventHeaderImageProcessor.horizontalInset * 2 - stripFrame.width
                    guard available > 0.5 else { return }
                    updated.horizontalPosition = clamp(start.effectiveHorizontalPosition + Double(2 * dx / available), -1, 1)
                }
                profile.receiptHeader = updated.normalized()
            }
            .onEnded { _ in gestureStart = nil }
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let start = gestureStart ?? configuration
                if gestureStart == nil { gestureStart = start }
                var updated = start
                if start.layoutMode == .fill || start.cropZoom > 1.001 {
                    updated.cropZoom = clamp(start.cropZoom * value.magnification, 1, ReceiptHeaderConfiguration.maximumZoom)
                } else {
                    updated.scale = clamp(start.scale * value.magnification, ReceiptHeaderConfiguration.minimumScale, ReceiptHeaderConfiguration.maximumEditorScale)
                }
                profile.receiptHeader = updated.normalized()
            }
            .onEnded { _ in gestureStart = nil }
    }

    // MARK: Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 18) {
            if !isCoBranded {
                EditorCard(title: "Quick Layout") {
                    HStack(spacing: 10) {
                        quickButton("Center", systemImage: "align.horizontal.center") {
                            profile.receiptHeader.align(.center)
                            profile.receiptHeader.cropPositionX = 0
                            profile.receiptHeader.cropPositionY = 0
                        }
                        quickButton("Fit Width", systemImage: "arrow.left.and.right") {
                            profile.receiptHeader.scale = ReceiptHeaderConfiguration.maximumEditorScale
                            profile.receiptHeader.align(.center)
                        }
                        quickButton("Fit Inside", systemImage: "rectangle.inset.filled") {
                            profile.receiptHeader.layoutMode = .fit
                            profile.receiptHeader.cropZoom = 1
                            profile.receiptHeader.cropPositionX = 0
                            profile.receiptHeader.cropPositionY = 0
                        }
                    }
                    Picker("Frame", selection: $profile.receiptHeader.layoutMode) {
                        Text("Whole Artwork").tag(ReceiptHeaderLayoutMode.fit)
                        Text("Fill Banner").tag(ReceiptHeaderLayoutMode.fill)
                    }
                    .pickerStyle(.segmented)
                }

            }
            if isCoBranded {
                Text("Use Adjust Header in Event Receipt Design to edit this co-branded header.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                EditorCard(title: "Size & Position") {
                    labeledSlider("Size", value: $profile.receiptHeader.scale, range: ReceiptHeaderConfiguration.minimumScale...ReceiptHeaderConfiguration.maximumEditorScale, format: .percent)
                    Picker("Alignment", selection: alignmentBinding) {
                        ForEach(ReceiptHeaderAlignment.allCases) { alignment in
                            Text(alignment.displayName).tag(alignment)
                        }
                    }
                    .pickerStyle(.segmented)
                    labeledSlider("Horizontal", value: horizontalBinding, range: -1...1, format: .offset)
                        .disabled(configuration.scale >= ReceiptHeaderConfiguration.maximumEditorScale)
                    if configuration.layoutMode == .fill {
                        labeledSlider("Banner Height", value: fillHeightBinding, range: ReceiptHeaderConfiguration.fillHeightRatioRange, format: .percent)
                    }
                }

            }

            EditorCard(title: "Crop · Event Logo") {
                labeledSlider("Zoom", value: $profile.receiptHeader.cropZoom, range: 1...ReceiptHeaderConfiguration.maximumZoom, format: .multiplier)
                labeledSlider("Crop Horizontal", value: $profile.receiptHeader.cropPositionX, range: -1...1, format: .offset)
                    .disabled(overflow.width <= 0.5)
                labeledSlider("Crop Vertical", value: $profile.receiptHeader.cropPositionY, range: -1...1, format: .offset)
                    .disabled(overflow.height <= 0.5)
            }

            EditorCard(title: "Spacing") {
                labeledSlider("Space Above", value: $profile.receiptHeader.topSpacing, range: 0...ReceiptHeaderConfiguration.maximumSpacing, format: .dots)
                labeledSlider("Space Below", value: $profile.receiptHeader.bottomSpacing, range: 0...ReceiptHeaderConfiguration.maximumSpacing, format: .dots)
            }

            Button(role: .destructive) {
                resetLayout()
            } label: {
                Label("Reset Artwork Layout", systemImage: "arrow.counterclockwise")
                    .frame(maxWidth: .infinity, minHeight: 40)
            }
            .buttonStyle(.bordered)

            Text("Artwork is limited to the printable width and a safe maximum height. Saved changes apply to the next customer only.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Co-Branded resets to its recommended placement beside the ×; other layouts to the default.
    private func resetLayout() {
        if isCoBranded {
            let identifier = profile.receiptHeader.assetIdentifier
            profile.receiptHeader = .coBrandedRecommended
            profile.receiptHeader.assetIdentifier = identifier
        } else {
            profile.receiptHeader.resetAdjustments()
        }
    }

    private var alignmentBinding: Binding<ReceiptHeaderAlignment> {
        Binding(
            get: { profile.receiptHeader.alignment },
            set: { profile.receiptHeader.align($0) }
        )
    }

    private var horizontalBinding: Binding<Double> {
        Binding(
            get: { configuration.effectiveHorizontalPosition },
            set: { profile.receiptHeader.horizontalPosition = clamp($0, -1, 1) }
        )
    }

    private var fillHeightBinding: Binding<Double> {
        Binding(
            get: { configuration.effectiveFillHeightRatio },
            set: { profile.receiptHeader.fillHeightRatio = $0 }
        )
    }

    private func quickButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage).font(.title3)
                Text(title).font(.subheadline.weight(.semibold))
            }
            .frame(maxWidth: .infinity, minHeight: 64)
        }
        .buttonStyle(.bordered)
    }

    private func labeledSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, format: SliderValueFormat) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(format.text(value.wrappedValue))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .font(.subheadline)
            Slider(value: value, in: range)
                .accessibilityLabel(title)
                .accessibilityValue(format.text(value.wrappedValue))
        }
    }

    // MARK: Thermal preview

    /// Debounced, cancellable, generation-checked so an older render never replaces a newer one.
    private func scheduleThermal() {
        thermalTask?.cancel()
        guard previewMode == .thermal else { return }
        thermalGeneration += 1
        let generation = thermalGeneration
        let configuration = configuration
        let artwork = artwork
        let coBranded = isCoBranded ? coBrandedProfile : nil
        thermalStrip = nil
        thermalTask = Task {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            let image = await Task.detached(priority: .userInitiated) { () -> UIImage? in
                if let coBranded {
                    let strip = ReceiptComposer.renderHeaderStrip(eventProfile: coBranded).image
                    return (try? ThermalImageRasterizer.rasterize(strip, purpose: .completeReceipt)).flatMap { UIImage(data: $0.previewPNGData) }
                }
                return try? EventHeaderImageProcessor.thermalPreview(source: artwork, configuration: configuration)
            }.value
            guard !Task.isCancelled, generation == thermalGeneration else { return }
            thermalStrip = image
        }
    }

    private func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
        guard value.isFinite else { return lower }
        return min(upper, max(lower, value))
    }
}

enum ArtworkPreviewMode: String, CaseIterable, Identifiable {
    case original
    case thermal

    var id: String { rawValue }
    var title: String { self == .original ? "Original" : "Printer Raster" }
}

private enum SliderValueFormat {
    case percent, offset, multiplier, dots

    func text(_ value: Double) -> String {
        switch self {
        case .percent: "\(Int((value * 100).rounded()))%"
        case .offset: value.magnitude < 0.01 ? "Center" : String(format: "%+.0f%%", value * 100)
        case .multiplier: String(format: "%.1f×", value)
        case .dots: "\(Int(value.rounded())) dots"
        }
    }
}

/// The 576-dot receipt band at full width, with printable-area guides and the artwork frame.
private struct ArtworkReceiptCanvas: View {
    let strip: UIImage?
    let frame: CGRect
    let isProcessing: Bool

    var body: some View {
        GeometryReader { proxy in
            let receiptWidth = CGFloat(BoothConfiguration.receiptWidth)
            let scale = proxy.size.width / receiptWidth
            let inset = EventHeaderImageProcessor.horizontalInset * scale
            ZStack(alignment: .topLeading) {
                Color.white
                if let strip {
                    Image(uiImage: strip)
                        .resizable()
                        .interpolation(.none)
                        .frame(width: proxy.size.width, height: strip.size.height * scale)
                } else if isProcessing {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                // Printable-area guides.
                Path { path in
                    path.move(to: CGPoint(x: inset, y: 0))
                    path.addLine(to: CGPoint(x: inset, y: proxy.size.height))
                    path.move(to: CGPoint(x: proxy.size.width - inset, y: 0))
                    path.addLine(to: CGPoint(x: proxy.size.width - inset, y: proxy.size.height))
                }
                .stroke(Color.blue.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                Rectangle()
                    .stroke(Color.accentColor, lineWidth: 2)
                    .frame(width: frame.width * scale, height: frame.height * scale)
                    .offset(x: frame.minX * scale, y: frame.minY * scale)
            }
            .contentShape(Rectangle())
        }
        .aspectRatio(CGFloat(BoothConfiguration.receiptWidth) / max(1, stripHeight), contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay { RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.3)) }
        .shadow(color: .black.opacity(0.08), radius: 8, y: 3)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Receipt artwork canvas, 576 dots wide")
        .accessibilityHint("Drag to position. Pinch to resize or zoom.")
    }

    private var stripHeight: CGFloat {
        max(frame.maxY + 12, strip?.size.height ?? frame.maxY)
    }
}

private struct EditorCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title.uppercased())
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }
}
