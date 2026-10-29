import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Header controls in Receipt Studio. Production receipt preview belongs to the shared viewport.
/// Edits a design draft only; the saved event changes on Save Design, guests on Start.
struct EventReceiptDesignPanel: View {
    @Binding var design: SavedEventDesign
    @Environment(\.dynamicTypeSize) private var typeSize
    var studioProfile: EventProfile? = nil
    var headerTarget: Binding<CoBrandedHeaderTarget>? = nil
    var isRegularBooth = false

    @State private var photoItem: PhotosPickerItem?
    @State private var isPhotoPickerPresented = false
    @State private var isFileImporterPresented = false
    let artworkImport: ReceiptArtworkImportSession
    @State private var artwork: EventArtwork?
    @State private var artworkMissing = false
    @State private var isStudioPresented = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            studioHeaderControls
                .disabled(artworkImport.isImporting)
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

    @ViewBuilder private var studioHeaderControls: some View {
        Toggle(isRegularBooth ? "Use Custom Logo" : "Use Event Logo", isOn: personalizeBinding).frame(minHeight: 44)
        if design.personalizeReceipt {
            if artwork != nil, design.layout == .coBranded {
                CoBrandedHeaderControls(configuration: $design.profile.receiptHeader, showsPreview: false, selection: headerTarget)
            } else if artwork != nil {
                Text("Event Logo").font(.headline)
                Text("Logo Size").font(.subheadline)
                Slider(value: $design.profile.receiptHeader.scale, in: ReceiptHeaderConfiguration.minimumScale...ReceiptHeaderConfiguration.maximumEditorScale)
                    .accessibilityLabel("Logo Size")
                Button("Advanced Artwork & Crop") { isStudioPresented = true }.buttonStyle(.bordered)
            }
            DisclosureGroup("Artwork & Composition") {
                VStack(alignment: .leading, spacing: 12) {
                    logoArea
                    Picker("Branding Mode", selection: Binding(get: { design.layout }, set: { setLayout($0) })) {
                        ForEach(ReceiptBrandingMode.allCases) { Text($0.displayName).tag($0) }
                    }.frame(minHeight: 44)
                }
            }
            if artwork == nil { logoArea }

        } else {
            MadeToKeepWordmark(size: 28, color: OperatorPalette.ink).frame(height: 70)
            sourceMenu(title: "Add Event Logo", systemImage: "plus", prominent: true)
        }
        if let studioProfile {
            DisclosureGroup("Studio Defaults") {
                Button("Restore Studio Defaults") {
                    design.profile.receiptHeader = studioProfile.receiptHeader
                    design.personalizeReceipt = studioProfile.receiptHeader.assetIdentifier != nil
                    reloadArtwork()
                }.frame(minHeight: 44)
                Text("Replaces this staged header with Regular Booth’s saved header.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Logo

    @ViewBuilder private var logoArea: some View {
        if let artwork {
            let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) : AnyLayout(HStackLayout(alignment: .center, spacing: 12))
            layout {
                LogoThumbnail(artwork: artwork)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Current Event Logo").font(.headline)
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
        if let importError = artworkImport.errorMessage {
            VStack(alignment: .leading, spacing: 8) {
                Label(importError, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                HStack {
                    sourceMenu(title: "Choose Another File", systemImage: "folder", prominent: false)
                    if artwork == nil { Button("Turn Off Personalization") { design.personalizeReceipt = false; artworkImport.cancelImport() }.buttonStyle(.bordered) }
                }
            }
            .font(.callout)
        }
    }

    private func sourceMenu(title: String, systemImage: String, prominent: Bool) -> some View {
        Menu {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--event-operations-validation") {
                Button("Use Synthetic Test Logo") {
                    runImport {
                        let format = UIGraphicsImageRendererFormat(); format.scale = 1
                        let image = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 180), format: format).image { context in
                            UIColor.black.setFill()
                            context.fill(CGRect(x: 10, y: 10, width: 280, height: 160))
                            NSString(string: "CIM").draw(at: CGPoint(x: 50, y: 45), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 80), .foregroundColor: UIColor.white])
                        }
                        guard let data = image.pngData() else { throw EventArtworkImporter.ImportError.noFile }
                        return try await EventArtworkImporter.importData(data)
                    }
                }
            }
            #endif
            Button { isPhotoPickerPresented = true } label: { Label("Choose from Photos", systemImage: "photo.on.rectangle") }
            Button { isFileImporterPresented = true } label: { Label("Choose from Files (PNG, JPEG, PDF)", systemImage: "folder") }
        } label: {
            Label(title, systemImage: systemImage).font(.headline).frame(minHeight: 44).padding(.horizontal, 6)
        }
        .modifier(ProminentIf(prominent: prominent))
        .disabled(artworkImport.isImporting)
        .accessibilityHint("Choose the logo from Photos or Files.")
    }

    // MARK: Layout

    private var personalizeBinding: Binding<Bool> {
        Binding(get: { design.personalizeReceipt }, set: { enabled in
            design.personalizeReceipt = enabled
            // A newly personalized event starts on the recommended Co-Branded layout.
            if enabled, design.logoIdentifier == nil, design.profile.receiptHeader.brandingMode == nil { setLayout(.coBranded) }
            artworkImport.cancelImport()
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

    // MARK: Import

    private func runImport(_ operation: @escaping () async throws -> EventArtworkImporter.Imported) {
        if artworkImport.begin(operation) { photoItem = nil }
    }

    private func removeLogo() {
        // Only the reference is cleared; the immutable file is kept for frozen sessions.
        design.personalizeReceipt = false
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

/// Logo on white paper, as it will print (before thermal conversion).
private struct LogoThumbnail: View {
    let artwork: EventArtwork
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color.white
            if let image { Image(uiImage: image).resizable().scaledToFit().padding(10) } else { ProgressView() }
        }
        .frame(width: 72, height: 60)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).stroke(.secondary.opacity(0.3)) }
        .task(id: ObjectIdentifier(artwork)) {
            let artwork = artwork
            image = await Task.detached(priority: .userInitiated) { artwork.image(fitting: 600) }.value
        }
        .accessibilityLabel("Event logo")
    }
}
