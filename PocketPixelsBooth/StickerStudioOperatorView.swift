//
//  StickerStudioOperatorView.swift
//  PocketPixelsBooth
//
//  Operator controls for Sticker Studio: the master switch, sources, guest limits, visible
//  categories, the gated online catalog and a side-effect-free guest preview. Every change is
//  saved immediately and applies to the next guest session.
//

import SwiftUI
import UIKit

struct StickerStudioOperatorView: View {
    @ObservedObject private var operations = EventOperationalState.shared
    @State private var settings = StickerStudioSettingsStore.load()
    @State private var customRecords: [CustomStickerRecord] = []
    @State private var apiKeyDraft = ""
    @State private var hasAPIKey = false
    @State private var apiKeyDescription = ""
    @State private var keyMessage: String?
    @State private var showingRightsConfirmation = false
    @State private var showingRemoveKeyConfirmation = false

    private let credentials: OnlineStickerCredentialStoring = KeychainOnlineStickerCredentialStore()

    var body: some View {
        Form {
            statusSection
            masterSection
            if settings.isEnabled {
                sourcesSection
                guestSection
                categoriesSection
            }
            onlineSection
            previewSection
        }
        .navigationTitle("Sticker Studio")
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: StickerCatalogStore.didChangeNotification)) { _ in reload() }
        .confirmationDialog("Confirm commercial print rights", isPresented: $showingRightsConfirmation, titleVisibility: .visible) {
            Button("I Confirm — Our Licence Covers This") {
                settings.onlineRightsAcknowledgement = OnlineStickerRightsAcknowledgement(acknowledgedAt: Date())
                save()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(OnlineStickerRightsAcknowledgement.statement)
        }
        .confirmationDialog("Remove the saved API key?", isPresented: $showingRemoveKeyConfirmation, titleVisibility: .visible) {
            Button("Remove Key", role: .destructive) {
                credentials.deleteAPIKey()
                settings.onlineDiscoveryEnabled = false
                save()
                refreshKeyState()
            }
            Button("Keep Key", role: .cancel) { }
        }
    }

    // MARK: Sections

    private var statusSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label(settings.isEnabled ? "STICKER STUDIO ON" : "STICKER STUDIO OFF",
                      systemImage: settings.isEnabled ? "checkmark.circle.fill" : "circle")
                    .font(.title3.bold())
                    .foregroundStyle(settings.isEnabled ? .green : .secondary)
                Text(settings.isEnabled
                     ? "Guests can decorate their receipt before it prints."
                     : "Guests go straight from their photos to the receipt, exactly as before.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if operations.customerSessionActive {
                    Label("Changes apply to the next guest session", systemImage: "clock.arrow.circlepath")
                        .font(.subheadline.bold())
                        .foregroundStyle(.orange)
                }
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)

            statusRow("Built-in library", value: settings.builtInStickersEnabled ? "\(BundledStickerFactory.definitions.count) stickers available offline" : "Off", ok: settings.builtInStickersEnabled)
            statusRow("Approved collection", value: customSummary, ok: settings.operatorCollectionEnabled && enabledCustomCount > 0)
            statusRow("Online catalog", value: onlineAvailability.isReady ? "Ready" : (settings.onlineDiscoveryEnabled ? "Unavailable" : "Off"), ok: onlineAvailability.isReady)
        } header: {
            Text("Status")
        }
    }

    private var masterSection: some View {
        Section {
            Toggle(isOn: binding(\.isEnabled)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Enable Sticker Studio").font(.headline)
                    Text("Adds an optional sticker step before the receipt is composed and printed. Guests can always skip it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(minHeight: 52)
            .accessibilityHint("Turns the guest sticker step on or off for the next guest session.")
        } footer: {
            Text("Off by default. Test with Preview below before turning it on for guests.")
        }
    }

    private var sourcesSection: some View {
        Section {
            Toggle("Enable Built-in Stickers", isOn: binding(\.builtInStickersEnabled))
            Toggle("Enable Operator Collection", isOn: binding(\.operatorCollectionEnabled))
            NavigationLink {
                OperatorStickerLibraryView()
            } label: {
                HStack {
                    Label("Manage Stickers", systemImage: "square.grid.2x2")
                    Spacer()
                    Text("\(customRecords.count)").foregroundStyle(.secondary)
                }
            }
            if !settings.hasAnyLocalSource() && !onlineAvailability.isReady {
                Label("No sticker source is on, so guests will skip this step.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Sticker sources")
        } footer: {
            Text("Built-in stickers are original Made to Keep artwork and work offline. Only import images you own or are licensed to print on paid keepsakes.")
        }
    }

    private var guestSection: some View {
        Section("Guest editing") {
            Stepper(value: binding(\.guestStickerLimit), in: StickerStudioSettings.guestStickerLimitRange) {
                LabeledContent("Stickers per receipt", value: "\(settings.guestStickerLimit)")
            }
            Stepper(value: binding(\.minimumPrintedStickerDots), in: StickerStudioSettings.minimumPrintedDotsRange, step: 8) {
                LabeledContent("Smallest printed size", value: String(format: "%.0f mm", Double(settings.minimumPrintedStickerDots) / 8))
            }
        }
    }

    private var categoriesSection: some View {
        Section {
            ForEach(StickerCategory.assignableToImports) { category in
                Toggle(category.operatorDisplayName, isOn: Binding(
                    get: { !settings.hiddenCategories.contains(category) },
                    set: { visible in
                        if visible { settings.hiddenCategories.remove(category) } else { settings.hiddenCategories.insert(category) }
                        save()
                    }
                ))
            }
        } header: {
            Text("Visible categories")
        } footer: {
            Text("Categories with no stickers are hidden from guests automatically. Trending appears only when the online catalog is ready.")
        }
    }

    private var onlineSection: some View {
        Section {
            Label(onlineAvailability.operatorDescription, systemImage: onlineAvailability.isReady ? "checkmark.seal" : "wifi.slash")
                .foregroundStyle(onlineAvailability.isReady ? .green : .secondary)

            if hasAPIKey {
                LabeledContent("GIPHY API key", value: apiKeyDescription)
                Button("Remove API Key", role: .destructive) { showingRemoveKeyConfirmation = true }
            } else {
                SecureField("GIPHY API key", text: $apiKeyDraft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Save API Key") { saveKey() }
                    .disabled(apiKeyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let keyMessage {
                Text(keyMessage).font(.caption).foregroundStyle(.secondary)
            }

            if let acknowledgement = settings.onlineRightsAcknowledgement {
                LabeledContent("Print rights confirmed", value: acknowledgement.acknowledgedAt.formatted(date: .abbreviated, time: .shortened))
                Button("Withdraw Confirmation", role: .destructive) {
                    settings.onlineRightsAcknowledgement = nil
                    settings.onlineDiscoveryEnabled = false
                    save()
                }
            } else {
                Button("Confirm Commercial Print Rights…") { showingRightsConfirmation = true }
            }

            Toggle("Enable Online GIF/Meme Discovery", isOn: binding(\.onlineDiscoveryEnabled))
                .disabled(!hasAPIKey || settings.onlineRightsAcknowledgement == nil)
        } header: {
            Text("Online GIFs & memes (GIPHY)")
        } footer: {
            Text("Off by default. Requires your own GIPHY API key and written confirmation that your agreement permits printing third-party GIFs on paid physical receipts — the standard GIPHY API terms do not grant this. Guests see results with rating G only, with “Powered by GIPHY” attribution, and a still frame prints. Turning this off stops online requests immediately. Review: developers.giphy.com/docs/api and the GIPHY API Terms of Service.")
        }
    }

    private var previewSection: some View {
        Section {
            NavigationLink {
                StickerStudioPreviewView(settings: settings)
            } label: {
                Label("Preview Guest Sticker Studio", systemImage: "eye")
            }
            .disabled(!settings.hasAnyLocalSource() && !onlineAvailability.isReady)
        } footer: {
            Text("Uses sample photos. Nothing is printed, uploaded, archived or added to session history.")
        }
    }

    // MARK: Helpers

    private func statusRow(_ title: String, value: String, ok: Bool) -> some View {
        LabeledContent {
            Text(value).foregroundStyle(ok ? .primary : .secondary)
        } label: {
            Label(title, systemImage: ok ? "checkmark.circle" : "minus.circle")
                .foregroundStyle(ok ? .green : .secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var enabledCustomCount: Int { customRecords.filter(\.isEnabled).count }

    private var customSummary: String {
        guard settings.operatorCollectionEnabled else { return "Off" }
        let warnings = customRecords.filter { $0.printWarning != nil }.count
        var text = "\(enabledCustomCount) of \(customRecords.count) enabled"
        if warnings > 0 { text += " · \(warnings) may print poorly" }
        return text
    }

    private var onlineAvailability: OnlineStickerAvailability {
        settings.onlineAvailability(hasCredential: hasAPIKey)
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<StickerStudioSettings, Value>) -> Binding<Value> {
        Binding(
            get: { settings[keyPath: keyPath] },
            set: { value in
                settings[keyPath: keyPath] = value
                save()
            }
        )
    }

    private func save() {
        StickerStudioSettingsStore.save(settings)
        settings = StickerStudioSettingsStore.load()
    }

    private func reload() {
        settings = StickerStudioSettingsStore.load()
        customRecords = (try? StickerCatalogStore())?.records() ?? []
        refreshKeyState()
    }

    private func refreshKeyState() {
        hasAPIKey = credentials.hasAPIKey()
        apiKeyDescription = credentials.redactedDescription()
    }

    private func saveKey() {
        do {
            try credentials.saveAPIKey(apiKeyDraft)
            apiKeyDraft = ""
            // Saving a key never turns online discovery on by itself.
            keyMessage = "Key saved to this iPad's keychain. Online discovery stays off until you enable it."
        } catch {
            keyMessage = error.localizedDescription
        }
        refreshKeyState()
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
                ScrollView {
                    HStack(alignment: .top, spacing: 24) {
                        previewColumn("Keepsake", image: result.0)
                        previewColumn("As printed (1-bit thermal)", image: result.1)
                    }
                    .padding(24)
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

    private func previewColumn(_ title: String, image: UIImage) -> some View {
        VStack(spacing: 8) {
            Text(title).font(.headline)
            Image(uiImage: image).resizable().interpolation(.none).scaledToFit()
                .frame(maxWidth: 380)
                .border(Color.secondary.opacity(0.3))
        }
    }

    private func prepare() {
        let configuration = StickerStudioSessionConfiguration.current(settings: settings)
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
                provider: configuration.onlineReady ? KeychainOnlineStickerCredentialStore().loadAPIKey().map { GiphyStickerProvider(apiKey: $0) } : nil
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
