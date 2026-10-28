import SwiftUI

/// The single co-branded editing surface. All positions and limits come from production frames.
struct CoBrandedHeaderControls: View {
    @Binding var configuration: ReceiptHeaderConfiguration
    var showsPreview = true
    var selection: Binding<CoBrandedHeaderTarget>? = nil
    @State private var localTarget: CoBrandedHeaderTarget = .whole
    private var target: CoBrandedHeaderTarget { selection?.wrappedValue ?? localTarget }

    private var adjustments: CoBrandedHeaderAdjustments {
        ReceiptComposer.prepareCoBrandedEditing(configuration).coBrandedAdjustments ?? .init(configuration: configuration)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if showsPreview { CoBrandedHeaderPreview(configuration: configuration) }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(CoBrandedHeaderTarget.allCases, id: \.self) { item in
                    Button { if let selection { selection.wrappedValue = item } else { localTarget = item } } label: {
                        Text(item.rawValue).frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .tint(target == item ? OperatorPalette.ink : .secondary)
                    .accessibilityAddTraits(target == item ? [.isSelected] : [])
                }
            }
            switch target {
            case .whole:
                sizeControl("Overall Size", value: adjustments.compositionScale) { $0.coBrandedAdjustments?.compositionScale = $1 }
            case .studio:
                sizeControl("Wordmark Size", value: adjustments.studioScale) { $0.coBrandedAdjustments?.studioScale = $1 }
            case .separator:
                sizeControl("Separator Size", value: adjustments.placement?.separatorScale ?? 1, maximum: 2) {
                    $0.coBrandedAdjustments?.placement?.separatorScale = $1
                }
            case .event:
                sizeControl("Logo Size", value: min(1, configuration.scale)) { $0.scale = $1 }
                Picker("Frame", selection: editBinding(\.layoutMode)) {
                    Text("Whole Logo (Fit)").tag(ReceiptHeaderLayoutMode.fit)
                    Text("Fill Banner").tag(ReceiptHeaderLayoutMode.fill)
                }.pickerStyle(.segmented)
            }
            movement("Horizontal", vertical: false)
            movement("Vertical", vertical: true)
            Text("Moves in 4 printer dots. A dimmed arrow has reached the margin or the minimum gap. Resize an identity or adjust × to make room.")
                .font(.caption).foregroundStyle(.secondary)
            if target == .event {
            DisclosureGroup("Advanced Artwork & Crop") {
                VStack(spacing: 12) {
                    if configuration.layoutMode == .fill {
                        slider("Banner Height", value: Binding(get: { configuration.effectiveFillHeightRatio }, set: { value in
                            edit { $0.fillHeightRatio = value }
                        }), range: ReceiptHeaderConfiguration.fillHeightRatioRange)
                    }
                    slider("Crop Zoom", value: editBinding(\.cropZoom), range: 1...ReceiptHeaderConfiguration.maximumZoom)
                    slider("Crop Horizontal", value: editBinding(\.cropPositionX), range: -1...1)
                    slider("Crop Vertical", value: editBinding(\.cropPositionY), range: -1...1)
                    Text("Crop affects only the event artwork inside its frame.").font(.caption).foregroundStyle(.secondary)
                }.padding(.top, 10)
            }
            }
            ViewThatFits(in: .horizontal) {
                HStack { resetSelected; resetEntire }
                VStack(alignment: .leading) { resetSelected; resetEntire }
            }.buttonStyle(.bordered)
        }
    }

    private var resetSelected: some View {
        Button("Reset This Element") { configuration = ReceiptComposer.resetHeaderElement(configuration, target: target) }
    }
    private var resetEntire: some View {
        Button("Reset Header") { configuration.resetEntireCoBrandedHeader() }
            .accessibilityHint("Restores recommended header geometry and spacing. Keeps the imported event logo.")
    }

    private func movement(_ title: String, vertical: Bool) -> some View {
        let travel = ReceiptComposer.headerTravel(configuration, target: target, vertical: vertical)
        return HStack {
            Text(title + " Position")
            Spacer()
            Button { move(vertical: vertical, amount: -4) } label: {
                Image(systemName: vertical ? "arrow.up" : "arrow.left").frame(minWidth: 52, minHeight: 44)
            }.disabled(travel.lowerBound > -0.5).accessibilityLabel("Move \(target.rawValue) \(vertical ? "up" : "left")")
            Text(positionText(vertical: vertical)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .accessibilityLabel("Position in printer dots")
            Button { move(vertical: vertical, amount: 4) } label: {
                Image(systemName: vertical ? "arrow.down" : "arrow.right").frame(minWidth: 52, minHeight: 44)
            }.disabled(travel.upperBound < 0.5).accessibilityLabel("Move \(target.rawValue) \(vertical ? "down" : "right")")
        }.buttonStyle(.bordered)
    }

    private func positionText(vertical: Bool) -> String {
        guard let plan = ReceiptComposer.headerEditingPlan(configuration) else { return "—" }
        let rect: CGRect? = switch target {
        case .whole: plan.mastheadFrames.reduce(CGRect.null) { $0.union($1) }.union(plan.customHeaderFrame ?? .null).union(plan.coBrandSeparatorFrame ?? .null)
        case .studio: plan.mastheadFrames.reduce(CGRect.null) { $0.union($1) }
        case .separator: plan.coBrandSeparatorFrame
        case .event: plan.customHeaderFrame
        }
        guard let rect, !rect.isNull else { return "—" }
        return "\(Int((vertical ? rect.midY : rect.midX).rounded())) dots"
    }

    private func move(vertical: Bool, amount: Double) {
        configuration = ReceiptComposer.moveHeaderElement(configuration, target: target,
            horizontal: vertical ? 0 : amount, vertical: vertical ? amount : 0)
    }

    private func edit(_ change: (inout ReceiptHeaderConfiguration) -> Void) {
        var value = ReceiptComposer.prepareCoBrandedEditing(configuration)
        change(&value)
        configuration = value.normalized()
    }

    private func editBinding<Value>(_ key: WritableKeyPath<ReceiptHeaderConfiguration, Value>) -> Binding<Value> {
        Binding(get: { configuration[keyPath: key] }, set: { value in edit { $0[keyPath: key] = value } })
    }

    private func sizeControl(_ title: String, value: Double, maximum: Double = 1,
        set: @escaping (inout ReceiptHeaderConfiguration, Double) -> Void) -> some View {
        let limit = ReceiptComposer.headerMaximumScale(configuration, target: target, current: value, maximum: maximum)
        return VStack(alignment: .leading, spacing: 4) {
            HStack { Text(title); Spacer(); Text("\(Int((value * 100).rounded()))%").monospacedDigit().foregroundStyle(.secondary) }
            Slider(value: Binding(get: { min(limit, value) }, set: { size in edit { set(&$0, size) } }), in: 0.5...max(0.501, limit))
                .disabled(limit <= 0.501).accessibilityLabel(title)
            if limit < maximum - 0.01 {
                Text("Size is limited by the current margins and × spacing.").font(.caption).foregroundStyle(.secondary)
            }
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
