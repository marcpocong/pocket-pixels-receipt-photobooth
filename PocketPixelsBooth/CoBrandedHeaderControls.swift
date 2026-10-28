import SwiftUI

/// The single co-branded editing surface. All positions and limits come from production frames.
struct CoBrandedHeaderControls: View {
    @Binding var configuration: ReceiptHeaderConfiguration
    var showsPreview = true
    var selection: Binding<CoBrandedHeaderTarget>? = nil
    @State private var localTarget: CoBrandedHeaderTarget = .studio
    @State private var layoutExpanded = false
    private var target: CoBrandedHeaderTarget { selection?.wrappedValue ?? localTarget }
    private var adjustments: CoBrandedHeaderAdjustments {
        ReceiptComposer.prepareCoBrandedEditing(configuration).coBrandedAdjustments ?? .init(configuration: configuration)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showsPreview { CoBrandedHeaderPreview(configuration: configuration) }
            Text("Tap an element in the preview to edit it.").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                ForEach([CoBrandedHeaderTarget.studio, .separator, .event], id: \.self) { item in targetButton(item) }
            }
            Text("Editing: \(target.rawValue)").font(.headline).accessibilityIdentifier("receipt-editing-target")
            if target != .whole {
                elementControls
            }
            Divider()
            DisclosureGroup("Layout & Spacing", isExpanded: $layoutExpanded) {
                VStack(alignment: .leading, spacing: 12) {
                    targetButton(.whole)
                    if target == .whole { elementControls }
                    Stepper("Space above: \(Int(max(8, configuration.topSpacing))) dots", value: Binding(get: { max(8, configuration.topSpacing) }, set: { spacing in edit { $0.topSpacing = spacing } }), in: 8...ReceiptHeaderConfiguration.maximumSpacing, step: 4)
                    Stepper("Space below: \(Int(configuration.bottomSpacing)) dots", value: $configuration.bottomSpacing, in: 0...ReceiptHeaderConfiguration.maximumSpacing, step: 4)
                    Button("Center & Fit") { configuration.resetEntireCoBrandedHeader() }
                        .accessibilityHint("Uses the recommended balanced layout and spacing. Keeps the event artwork and its aspect ratio.")
                    Button("Reset Header") { configuration.resetEntireCoBrandedHeader() }
                        .accessibilityHint("Restores recommended geometry and crop. Keeps the imported event logo.")
                }.buttonStyle(.bordered).padding(.top, 10)
            }
        }
        .onChange(of: target) { _, value in if value == .whole { layoutExpanded = true } }
    }

    private func select(_ item: CoBrandedHeaderTarget) {
        if let selection { selection.wrappedValue = item } else { localTarget = item }
    }

    private func targetButton(_ item: CoBrandedHeaderTarget) -> some View {
        Button { select(item) } label: {
            VStack(spacing: 3) {
                if target == item { Image(systemName: "checkmark.circle.fill").font(.caption) }
                Text(item.rawValue).font(.subheadline.weight(.medium)).multilineTextAlignment(.center)
            }.frame(maxWidth: .infinity, minHeight: 44).padding(.horizontal, 4)
                .background(target == item ? OperatorPalette.ink : Color.white, in: RoundedRectangle(cornerRadius: 8))
                .foregroundStyle(target == item ? Color.white : OperatorPalette.ink)
                .overlay { RoundedRectangle(cornerRadius: 8).stroke(OperatorPalette.ink, lineWidth: target == item ? 2 : 1) }
        }.buttonStyle(.plain).accessibilityAddTraits(target == item ? [.isSelected] : [])
    }

    @ViewBuilder private var elementControls: some View {
        switch target {
        case .whole:
            sizeControl("Overall Size", value: adjustments.compositionScale) { $0.coBrandedAdjustments?.compositionScale = $1 }
        case .studio:
            sizeControl("Wordmark Size", value: adjustments.studioScale) { $0.coBrandedAdjustments?.studioScale = $1 }
        case .separator:
            sizeControl("Separator Size", value: adjustments.placement?.separatorScale ?? 1, maximum: 2) { $0.coBrandedAdjustments?.placement?.separatorScale = $1 }
        case .event:
            sizeControl("Logo Size", value: min(1, configuration.scale)) { $0.scale = $1 }
        }
        movement("Horizontal", vertical: false)
        movement("Vertical", vertical: true)
        if target == .event {
            DisclosureGroup("Advanced Artwork & Crop") {
                VStack(spacing: 12) {
                    Picker("Frame", selection: editBinding(\.layoutMode)) {
                        Text("Whole Logo (Fit)").tag(ReceiptHeaderLayoutMode.fit)
                        Text("Fill Banner").tag(ReceiptHeaderLayoutMode.fill)
                    }.pickerStyle(.segmented)
                    if configuration.layoutMode == .fill {
                        slider("Banner Height", value: Binding(get: { configuration.effectiveFillHeightRatio }, set: { value in edit { $0.fillHeightRatio = value } }), range: ReceiptHeaderConfiguration.fillHeightRatioRange)
                    }
                    slider("Crop Zoom", value: editBinding(\.cropZoom), range: 1...ReceiptHeaderConfiguration.maximumZoom)
                    slider("Crop Horizontal", value: editBinding(\.cropPositionX), range: -1...1)
                    slider("Crop Vertical", value: editBinding(\.cropPositionY), range: -1...1)
                }.padding(.top, 10)
            }
        }
        Button("Reset This Element") { configuration = ReceiptComposer.resetHeaderElement(configuration, target: target) }
            .buttonStyle(.bordered).frame(minHeight: 44)
    }

    private func frame(_ config: ReceiptHeaderConfiguration) -> CGRect? {
        guard let plan = ReceiptComposer.headerEditingPlan(config) else { return nil }
        return ReceiptEditorGeometry(plan: plan).elements[target]
    }

    /// Compare resolved frames, not merely requested offsets: clamping can consume a move.
    private func canMove(vertical: Bool, amount: Double) -> Bool {
        let moved = ReceiptComposer.moveHeaderElement(configuration, target: target, horizontal: vertical ? 0 : amount, vertical: vertical ? amount : 0)
        guard let before = frame(configuration), let after = frame(moved) else { return false }
        return abs(vertical ? after.midY - before.midY : after.midX - before.midX) > 0.5
    }

    private func movement(_ title: String, vertical: Bool) -> some View {
        let backward = canMove(vertical: vertical, amount: -4)
        let forward = canMove(vertical: vertical, amount: 4)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title + " Position").font(.subheadline)
                    Text(positionText(vertical: vertical)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .accessibilityIdentifier("receipt-position-\(vertical ? "vertical" : "horizontal")")
                }
                Spacer(minLength: 4)
                Button { move(vertical: vertical, amount: -4) } label: {
                    Image(systemName: vertical ? "arrow.up" : "arrow.left").frame(minWidth: 44, minHeight: 44)
                }.disabled(!backward).accessibilityLabel("Move \(target.rawValue) \(vertical ? "up" : "left")")
                Button { move(vertical: vertical, amount: 4) } label: {
                    Image(systemName: vertical ? "arrow.down" : "arrow.right").frame(minWidth: 44, minHeight: 44)
                }.disabled(!forward).accessibilityLabel("Move \(target.rawValue) \(vertical ? "down" : "right")")
            }.buttonStyle(.bordered)
            if !backward || !forward {
                Text(limitText(vertical: vertical, backward: backward, forward: forward)).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func limitText(vertical: Bool, backward: Bool, forward: Bool) -> String {
        if !backward && !forward { return "No room to move. Reduce the size to create space." }
        if vertical { return backward ? "At lower movement limit." : "At top printable margin." }
        let margin = (target == .studio && !backward) || (target == .event && !forward) || target == .whole
        return margin ? "At printable margin." : "Minimum gap between identities reached. Resize to create room."
    }

    private func positionText(vertical: Bool) -> String {
        var baseline = ReceiptHeaderConfiguration.coBrandedRecommended
        baseline.assetIdentifier = configuration.assetIdentifier
        guard let current = frame(configuration), let origin = frame(baseline) else { return "—" }
        let delta = Int((vertical ? current.midY - origin.midY : current.midX - origin.midX).rounded())
        if delta == 0 { return vertical ? "Default height" : "Default alignment" }
        if vertical { return "\(abs(delta)) dots \(delta < 0 ? "above" : "below") default" }
        return "\(abs(delta)) dots \(delta < 0 ? "left" : "right") of default"
    }

    private func move(vertical: Bool, amount: Double) {
        configuration = ReceiptComposer.moveHeaderElement(configuration, target: target, horizontal: vertical ? 0 : amount, vertical: vertical ? amount : 0)
    }
    private func edit(_ change: (inout ReceiptHeaderConfiguration) -> Void) {
        var value = ReceiptComposer.prepareCoBrandedEditing(configuration)
        change(&value); configuration = value.normalized()
    }
    private func editBinding<Value>(_ key: WritableKeyPath<ReceiptHeaderConfiguration, Value>) -> Binding<Value> {
        Binding(get: { configuration[keyPath: key] }, set: { value in edit { $0[keyPath: key] = value } })
    }
    private func sizeControl(_ title: String, value: Double, maximum: Double = 1, set: @escaping (inout ReceiptHeaderConfiguration, Double) -> Void) -> some View {
        let availability = ReceiptComposer.headerSizeAvailability(configuration, target: target, current: value, maximum: maximum)
        let limit = availability.limit
        return VStack(alignment: .leading, spacing: 4) {
            HStack { Text(title); Spacer(); Text(availability.canResize ? "\(Int((min(value, limit) * 100).rounded()))%" : "Fitted to space").monospacedDigit().foregroundStyle(.secondary) }
            Slider(value: Binding(get: { min(limit, value) }, set: { size in edit { set(&$0, size) } }), in: 0.5...max(0.501, limit))
                .disabled(!availability.canResize).accessibilityLabel(title)
            if !availability.canResize {
                Text("No resize range at the current margins. Move × or reduce the overall size to create room.").font(.caption).foregroundStyle(.secondary)
            } else if limit < maximum - 0.01 { Text("Size is limited by the current margins and × spacing.").font(.caption).foregroundStyle(.secondary) }
        }
    }
    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack { Text(title); Spacer(); Text(String(format: "%.2f", value.wrappedValue)).monospacedDigit().foregroundStyle(.secondary) }
            Slider(value: value, in: range).accessibilityLabel(title)
        }
    }
}

private struct CoBrandedHeaderPreview: View {
    let configuration: ReceiptHeaderConfiguration
    @State private var image: UIImage?
    @State private var thermal = false
    private struct Request: Equatable { let configuration: ReceiptHeaderConfiguration; let thermal: Bool }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Live Header Preview").font(.headline)
                Spacer()
                Toggle("Thermal Raster", isOn: $thermal).fixedSize()
            }
            if let image {
                Image(uiImage: image).resizable().interpolation(.none).scaledToFit()
                    .overlay {
                        GeometryReader { proxy in
                            let inset = proxy.size.width * 36 / 576
                            HStack { Rectangle().frame(width: 1); Spacer(); Rectangle().frame(width: 1) }
                                .foregroundStyle(.blue.opacity(0.35)).padding(.horizontal, inset)
                        }
                    }
                    .accessibilityLabel("Production receipt header with printable margin guides, 576 dots wide")
            } else { ProgressView().frame(maxWidth: .infinity, minHeight: 140) }
        }
        .padding(12).background(.white, in: RoundedRectangle(cornerRadius: 12))
        .task(id: Request(configuration: configuration, thermal: thermal)) {
            var profile = EventProfile.pocketPixelsDefault
            profile.isEnabled = true; profile.showEventTextBlock = false; profile.receiptHeader = configuration
            let usesThermal = thermal
            let rendered = await Task.detached(priority: .userInitiated) {
                let strip = ReceiptComposer.renderHeaderStrip(eventProfile: profile).image
                if usesThermal, let raster = try? ThermalImageRasterizer.rasterize(strip, purpose: .completeReceipt),
                   let converted = UIImage(data: raster.previewPNGData) { return converted }
                return strip
            }.value
            guard !Task.isCancelled else { return }
            image = rendered
        }
    }
}
