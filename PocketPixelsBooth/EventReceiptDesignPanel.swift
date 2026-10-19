import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Event receipt design inside Session Setup: optional event logo, layout and a live preview.
/// Edits a design draft only; the saved event changes on Save Design, guests on Start.
struct EventReceiptDesignPanel: View {
    @Binding var design: SavedEventDesign
    let isDirty: Bool
    let save: () -> Void
    let discard: () -> Void

    @State private var photoItem: PhotosPickerItem?
    @State private var isPhotoPickerPresented = false
    @State private var isFileImporterPresented = false
    @State private var isImporting = false
    @State private var importError: String?
    @State private var artwork: EventArtwork?
    @State private var artworkMissing = false
    @State private var isStudioPresented = false
    @State private var isAdvancedLayoutExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Picker("Event Gallery Code Style", selection: $design.profile.receiptDesign.footerStyleOverride) {
                Text("Inherit Device Default").tag(Optional<ReceiptFooterStyle>.none)
                ForEach(ReceiptFooterStyle.allCases) { style in Text(style.displayName).tag(Optional(style)) }
            }
            Button("Restore Default — Inherit Device") { design.profile.receiptDesign.footerStyleOverride = nil }
            if design.profile.receiptDesign.footerStyleOverride == .decorativeBarcodeOnly {
                Label("Decorative barcode only: no printed gallery access. The iPad gallery QR remains available.", systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange)
            }

            Picker("Default QR Gallery Receipt Style", selection: $design.profile.galleryReceiptStyleOverride) {
                Text("Use Device Default").tag(Optional<GalleryReceiptStyle>.none)
                ForEach(GalleryReceiptStyle.allCases) { style in Text(style.title).tag(Optional(style)) }
            }
            Text("Customer Gallery only. Save Design, then Review & Start to apply.").font(.footnote).foregroundStyle(.secondary)

            Toggle(isOn: personalizeBinding) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Personalize Receipt with Event Logo").font(.headline)
                    Text(design.personalizeReceipt
                         ? "Your event logo prints with Made to Keep at the top of every receipt."
                         : "Guests receive the standard Made to Keep receipt.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .frame(minHeight: 52)

            if design.personalizeReceipt {
                logoArea
                if artwork != nil {
                    layoutChoices
                    adjustments
                }
            } else if design.logoIdentifier != nil {
                Label("The saved logo is kept for this event and returns when you turn personalization back on.", systemImage: "archivebox")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            if isDirty {
                HStack(spacing: 12) {
                    Label("Unsaved design changes", systemImage: "pencil.circle.fill").foregroundStyle(.orange).font(.callout)
                    Spacer()
                    Button("Cancel Changes", role: .destructive, action: discard).buttonStyle(.bordered)
                    Button("Save Design", action: save).buttonStyle(.borderedProminent)
                }
            }
        }
        .onAppear { reloadArtwork() }
        .onChange(of: design.logoIdentifier) { _, _ in reloadArtwork() }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            runImport { try await EventArtworkImporter.importPhoto(item) }
        }
        .photosPicker(isPresented: $isPhotoPickerPresented, selection: $photoItem, matching: .images)
        .fileImporter(isPresented: $isFileImporterPresented, allowedContentTypes: [.png, .jpeg, .pdf], allowsMultipleSelection: false) { result in
            if case .failure(let error) = result, (error as NSError).code == NSUserCancelledError { return }
            runImport { try await EventArtworkImporter.importFile(result) }
        }
        .fullScreenCover(isPresented: $isStudioPresented) {
            if let artwork {
                NavigationStack { EventArtworkEditorView(artwork: artwork, profile: $design.profile) }
            }
        }
    }

    // MARK: Logo

    @ViewBuilder private var logoArea: some View {
        if let artwork {
            HStack(alignment: .center, spacing: 18) {
                LogoThumbnail(artwork: artwork)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Event Logo").font(.headline)
                    Text(artwork.kind == .vector ? "Vector PDF — prints sharp at any size" : "Image — transparent areas print as white paper")
                        .font(.footnote).foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        sourceMenu(title: "Replace Logo", systemImage: "arrow.triangle.2.circlepath", prominent: false)
                        Button("Remove", role: .destructive) { removeLogo() }.buttonStyle(.bordered)
                    }
                }
                Spacer(minLength: 0)
            }
        } else {
            VStack(spacing: 14) {
                Image(systemName: "photo.badge.plus").font(.system(size: 40)).foregroundStyle(.secondary)
                Text(artworkMissing ? "The saved logo can’t be found" : "Add your event logo").font(.headline)
                Text(artworkMissing
                     ? "Choose the file again, or turn off personalization. Receipts never print a blank logo space."
                     : "Transparent PNG or vector PDF looks best. JPEG works too.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                sourceMenu(title: "Add Event Logo", systemImage: "plus", prominent: true)
                if artworkMissing {
                    Button("Turn Off Personalization") { design.personalizeReceipt = false }.buttonStyle(.bordered)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 200)
            .padding(16)
            .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
            .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])).foregroundStyle(.secondary.opacity(0.5)) }
        }
        if isImporting {
            ProgressView("Preparing logo…").frame(maxWidth: .infinity)
        }
        if let importError {
            VStack(alignment: .leading, spacing: 8) {
                Label(importError, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                HStack {
                    sourceMenu(title: "Choose Another File", systemImage: "folder", prominent: false)
                    if artwork == nil { Button("Turn Off Personalization") { design.personalizeReceipt = false; self.importError = nil }.buttonStyle(.bordered) }
                }
            }
            .font(.callout)
        }
    }

    private func sourceMenu(title: String, systemImage: String, prominent: Bool) -> some View {
        Menu {
            Button { isPhotoPickerPresented = true } label: { Label("Choose from Photos", systemImage: "photo.on.rectangle") }
            Button { isFileImporterPresented = true } label: { Label("Choose from Files (PNG, JPEG, PDF)", systemImage: "folder") }
        } label: {
            Label(title, systemImage: systemImage).font(.headline).frame(minHeight: 44).padding(.horizontal, 6)
        }
        .modifier(ProminentIf(prominent: prominent))
        .disabled(isImporting)
        .accessibilityHint("Choose the logo from Photos or Files.")
    }

    // MARK: Layout

    private var layoutChoices: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Receipt Layout").font(.headline)
            LayoutOption(title: "Co-Branded", subtitle: "Made to Keep × your logo at the top. Recommended.", systemImage: "rectangle.split.2x1",
                         selected: design.layout == .coBranded) { setLayout(.coBranded) }
            DisclosureGroup("Advanced Layouts", isExpanded: $isAdvancedLayoutExpanded) {
                VStack(spacing: 10) {
                    ForEach(ReceiptBrandingMode.advancedLayouts) { mode in
                        LayoutOption(title: mode.displayName, subtitle: mode.summary, systemImage: mode == .studioFirst ? "signature" : "photo",
                                     selected: design.layout == mode) { setLayout(mode) }
                    }
                }
                .padding(.top, 8)
            }
            .font(.callout)
        }
    }

    private var adjustments: some View {
        DisclosureGroup("Adjust Logo") {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack { Text("Logo Size"); Spacer(); Text("\(Int((design.profile.receiptHeader.scale * 100).rounded()))%").monospacedDigit().foregroundStyle(.secondary) }
                    Slider(value: $design.profile.receiptHeader.scale, in: ReceiptHeaderConfiguration.minimumScale...ReceiptHeaderConfiguration.maximumEditorScale)
                        .accessibilityLabel("Logo size")
                }
                if design.layout == .coBranded {
                    Picker("Placement", selection: placementBinding) {
                        Text("Beside ×").tag(-1.0)
                        Text("Centered").tag(0.0)
                        Text("Outer Edge").tag(1.0)
                    }
                    .pickerStyle(.segmented)
                }
                Picker("Frame", selection: $design.profile.receiptHeader.layoutMode) {
                    Text("Whole Logo (Fit)").tag(ReceiptHeaderLayoutMode.fit)
                    Text("Fill Banner").tag(ReceiptHeaderLayoutMode.fill)
                }
                .pickerStyle(.segmented)
                Stepper("Space above: \(Int(design.profile.receiptHeader.topSpacing)) dots", value: $design.profile.receiptHeader.topSpacing, in: 0...ReceiptHeaderConfiguration.maximumSpacing, step: 4)
                Stepper("Space below: \(Int(design.profile.receiptHeader.bottomSpacing)) dots", value: $design.profile.receiptHeader.bottomSpacing, in: 0...ReceiptHeaderConfiguration.maximumSpacing, step: 4)
                HStack {
                    Button("Reset to Recommended") { resetLayout() }.buttonStyle(.bordered)
                    Spacer()
                    Button { isStudioPresented = true } label: { Label("Open Event Artwork Studio", systemImage: "slider.horizontal.below.rectangle") }
                        .buttonStyle(.bordered)
                }
            }
            .padding(.top, 8)
        }
        .font(.callout)
    }

    private var placementBinding: Binding<Double> {
        Binding(
            get: {
                let value = design.profile.receiptHeader.effectiveHorizontalPosition
                return [-1.0, 0, 1].min { abs($0 - value) < abs($1 - value) } ?? -1
            },
            set: { design.profile.receiptHeader.horizontalPosition = $0 }
        )
    }

    private var personalizeBinding: Binding<Bool> {
        Binding(get: { design.personalizeReceipt }, set: { enabled in
            design.personalizeReceipt = enabled
            // A newly personalized event starts on the recommended Co-Branded layout.
            if enabled, design.logoIdentifier == nil, design.profile.receiptHeader.brandingMode == nil { setLayout(.coBranded) }
            importError = nil
        })
    }

    private func setLayout(_ mode: ReceiptBrandingMode) {
        guard design.profile.receiptHeader.brandingMode != mode else { return }
        let identifier = design.logoIdentifier
        if mode == .coBranded {
            design.profile.receiptHeader = .coBrandedRecommended
        } else {
            design.profile.receiptHeader.brandingMode = mode
            design.profile.receiptHeader.resetAdjustments()
            design.profile.receiptHeader.horizontalPosition = nil
        }
        design.profile.receiptHeader.assetIdentifier = identifier
    }

    private func resetLayout() {
        let mode = design.layout
        let identifier = design.logoIdentifier
        design.profile.receiptHeader = .coBrandedRecommended
        design.profile.receiptHeader.brandingMode = mode
        if mode != .coBranded { design.profile.receiptHeader.horizontalPosition = nil }
        design.profile.receiptHeader.assetIdentifier = identifier
    }

    // MARK: Import

    private func runImport(_ operation: @escaping () async throws -> EventArtworkImporter.Imported) {
        guard !isImporting else { return }
        isImporting = true
        importError = nil
        Task {
            defer { isImporting = false; photoItem = nil }
            do {
                let result = try await operation()
                // A new logo starts from the recommended layout; the old file stays on disk for
                // any frozen session or reprint that references it.
                let mode = design.profile.receiptHeader.brandingMode ?? .coBranded
                design.profile.receiptHeader = .coBrandedRecommended
                design.profile.receiptHeader.brandingMode = mode
                if mode != .coBranded { design.profile.receiptHeader.horizontalPosition = nil }
                design.profile.receiptHeader.assetIdentifier = result.identifier
                artwork = result.artwork
                artworkMissing = false
            } catch {
                importError = error.localizedDescription
            }
        }
    }

    private func removeLogo() {
        // Only the reference is cleared; the immutable file is kept for frozen sessions.
        design.profile.receiptHeader.assetIdentifier = nil
        artwork = nil
        artworkMissing = false
    }

    private func reloadArtwork() {
        guard let identifier = design.logoIdentifier else { artwork = nil; artworkMissing = false; return }
        let loaded = (try? EventHeaderAssetStore())?.loadArtwork(identifier: identifier)
        artwork = loaded
        artworkMissing = loaded == nil
    }
}

private struct ProminentIf: ViewModifier {
    let prominent: Bool
    func body(content: Content) -> some View {
        if prominent { content.buttonStyle(.borderedProminent) } else { content.buttonStyle(.bordered) }
    }
}

private struct LayoutOption: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: systemImage).font(.title3).frame(width: 30)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Image(systemName: selected ? "checkmark.circle.fill" : "circle").font(.title3)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .background(selected ? OperatorPalette.selected : Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
            .overlay { RoundedRectangle(cornerRadius: 14).stroke(selected ? OperatorPalette.ink : .secondary.opacity(0.25), lineWidth: selected ? 2 : 1) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Logo on white paper, as it will print (before thermal conversion).
private struct LogoThumbnail: View {
    let artwork: EventArtwork
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color.white
            if let image { Image(uiImage: image).resizable().scaledToFit().padding(10) } else { ProgressView() }
        }
        .frame(width: 150, height: 96)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).stroke(.secondary.opacity(0.3)) }
        .task(id: ObjectIdentifier(artwork)) {
            let artwork = artwork
            image = await Task.detached(priority: .userInitiated) { artwork.image(fitting: 600) }.value
        }
        .accessibilityLabel("Event logo")
    }
}
