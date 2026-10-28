import SwiftUI

/// Both editors write the same persisted configuration consumed by ReceiptComposer.
struct CoBrandedHeaderControls: View {
    enum Target: String, CaseIterable { case both = "Both", studio = "Made to Keep", event = "Event Logo" }
    @Binding var configuration: ReceiptHeaderConfiguration
    @State private var target: Target = .both

    private var adjustments: CoBrandedHeaderAdjustments {
        configuration.coBrandedAdjustments ?? .init(configuration: configuration)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Adjustment Target", selection: $target) {
                ForEach(Target.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
            switch target {
            case .both:
                control("Both Size", value: binding(\.compositionScale), range: 0.5...1, percent: true)
                Stepper("Both Horizontal · 4 dots", onIncrement: { move(horizontal: 4) }, onDecrement: { move(horizontal: -4) })
                Stepper("Both Vertical · 4 dots", onIncrement: { move(vertical: 4) }, onDecrement: { move(vertical: -4) })
            case .studio:
                control("Wordmark Size", value: binding(\.studioScale), range: 0.5...1, percent: true)
                control("Made to Keep Horizontal", value: binding(\.studioPosition), range: -1...1)
                control("Made to Keep Vertical", value: binding(\.studioY), range: -48...48)
                Button("Reset Made to Keep Adjustments") { configuration.resetStudioIdentity() }
            case .event:
                control("Logo Size", value: Binding(get: { configuration.scale }, set: { value in
                    configuration.editCoBranded { _ in }; configuration.scale = value
                }), range: 0.5...1, percent: true)
                control("Event Logo Horizontal", value: binding(\.eventPosition), range: -1...1)
                control("Event Logo Vertical", value: binding(\.eventY), range: -48...48)
                Picker("Frame", selection: Binding(get: { configuration.layoutMode }, set: { value in
                    configuration.editCoBranded { _ in }; configuration.layoutMode = value
                })) {
                    Text("Whole Logo (Fit)").tag(ReceiptHeaderLayoutMode.fit)
                    Text("Fill Banner").tag(ReceiptHeaderLayoutMode.fill)
                }.pickerStyle(.segmented)
                if configuration.layoutMode == .fill {
                    control("Banner Height", value: Binding(get: { configuration.effectiveFillHeightRatio }, set: { value in
                        configuration.editCoBranded { _ in }; configuration.fillHeightRatio = value
                    }), range: ReceiptHeaderConfiguration.fillHeightRatioRange, percent: true)
                }
                Button("Reset Event Logo Adjustments") { configuration.resetEventIdentity() }
            }
            Button("Reset Entire Header to Recommended") { configuration.resetEntireCoBrandedHeader() }
            Text("Movement stops at the printable margins and the ×. Size preserves each identity’s proportions. Use the Artwork Studio for crop adjustments.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func move(horizontal: Double = 0, vertical: Double = 0) {
        configuration = ReceiptComposer.translateCoBrandedHeader(configuration, horizontal: horizontal, vertical: vertical)
    }

    private func binding(_ key: WritableKeyPath<CoBrandedHeaderAdjustments, Double>) -> Binding<Double> {
        Binding(get: { adjustments[keyPath: key] }, set: { newValue in
            configuration.editCoBranded { $0[keyPath: key] = newValue }
        })
    }

    private func control(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, percent: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(percent ? "\(Int((value.wrappedValue * 100).rounded()))%" : range == -1...1 ? String(format: "%.2f", value.wrappedValue) : "\(Int(value.wrappedValue)) dots")
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: value, in: range).accessibilityLabel(title)
        }
    }
}
