//
//  StickerStudioView.swift
//  PocketPixelsBooth
//
//  Guest Sticker Studio: the live receipt canvas on the left, a sticker palette and large
//  Done / Skip actions on the right (stacked in portrait). Shown only when the session froze
//  Sticker Studio ON, before anything is committed, uploaded, archived or printed.
//

import SwiftUI
import UIKit

struct StickerStudioView: View {
    @Bindable var session: StickerStudioSession
    let onDone: () -> Void
    let onSkip: () -> Void
    let onBack: () -> Void
    let onCancel: () -> Void
    let onActivity: () -> Void

    @State private var isFinishing = false
    @State private var showingResetConfirmation = false
    @State private var showingSkipConfirmation = false
    @FocusState private var searchFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let gestureHint = "Drag to move • Pinch to resize • Twist to rotate"

    var body: some View {
        GeometryReader { proxy in
            let isLandscape = proxy.size.width > proxy.size.height
            VStack(spacing: 16) {
                header
                if isLandscape {
                    HStack(alignment: .top, spacing: 28) {
                        canvasColumn(available: CGSize(width: proxy.size.width - 470 - MadeToKeepTheme.Spacing.screenPadding * 2, height: proxy.size.height - 150))
                        controlColumn
                            .frame(width: 440)
                    }
                } else {
                    canvasColumn(available: CGSize(width: proxy.size.width - MadeToKeepTheme.Spacing.screenPadding * 2, height: proxy.size.height * 0.36))
                    controlColumn
                }
            }
            .padding(.horizontal, MadeToKeepTheme.Spacing.screenPadding)
            .padding(.top, 20)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .confirmationDialog("Remove all stickers?", isPresented: $showingResetConfirmation, titleVisibility: .visible) {
            Button("Remove All", role: .destructive) {
                session.resetAll()
                onActivity()
            }
            Button("Keep Stickers", role: .cancel) { }
        }
        .confirmationDialog("Skip stickers?", isPresented: $showingSkipConfirmation, titleVisibility: .visible) {
            Button("Skip — Print Without Stickers", role: .destructive) { finish(skip: true) }
            Button("Keep Decorating", role: .cancel) { }
        } message: {
            Text("Your stickers will be removed and your receipt prints as it was.")
        }
        .onChange(of: session.placements) { _, _ in onActivity() }
        .task(id: isFinishing) {
            // If the commit was refused (the screen is still here), unlock after a moment.
            guard isFinishing else { return }
            try? await Task.sleep(for: .seconds(2))
            isFinishing = false
        }
        .onChange(of: session.searchQuery) { _, _ in
            onActivity()
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center) {
            Button {
                onBack()
            } label: {
                Label("Back", systemImage: "chevron.left")
            }
            .buttonStyle(MadeToKeepSecondaryButtonStyle())
            .disabled(isFinishing)
            .accessibilityHint("Returns to the previous step. Your photos and stickers are kept.")

            Spacer()
            VStack(spacing: 4) {
                Text("make it yours")
                    .font(MadeToKeepTheme.Typography.italicSerif(size: 44))
                    .foregroundStyle(MadeToKeepTheme.ColorPalette.burgundy)
                    .accessibilityAddTraits(.isHeader)
                Text("Add a little something to your keepsake.")
                    .font(MadeToKeepTheme.Typography.sans(size: 17))
                    .foregroundStyle(MadeToKeepTheme.ColorPalette.secondaryText)
            }
            Spacer()

            Button("Cancel", action: onCancel)
                .buttonStyle(MadeToKeepSecondaryButtonStyle())
                .disabled(isFinishing)
        }
    }

    // MARK: Canvas

    private func canvasColumn(available: CGSize) -> some View {
        VStack(spacing: 10) {
            if let layout = session.layout {
                let scale = max(0.1, min(available.width / CGFloat(layout.canvasWidth), (available.height - 60) / CGFloat(layout.editorVisibleHeight)))
                StickerCanvasView(session: session, displayScale: scale, onActivity: onActivity)
                    .frame(maxWidth: .infinity)
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 200)
            }

            Group {
                if let selected = session.selectedPlacement, let warning = session.warning(for: selected) {
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(MadeToKeepTheme.ColorPalette.warningText)
                } else if let notice = session.notice {
                    Text(notice).foregroundStyle(MadeToKeepTheme.ColorPalette.warningText)
                } else {
                    Text(Self.gestureHint).foregroundStyle(MadeToKeepTheme.ColorPalette.secondaryText)
                }
            }
            .font(MadeToKeepTheme.Typography.sans(size: 16, weight: .medium))
            .multilineTextAlignment(.center)
            .frame(minHeight: 24)
            .accessibilityAddTraits(.updatesFrequently)
        }
    }

    // MARK: Controls

    private var controlColumn: some View {
        VStack(spacing: 14) {
            categoryTabs
            searchField
            palette
                .frame(maxHeight: .infinity)
            editToolbar
            finishButtons
        }
    }

    private var categoryTabs: some View {
        ScrollViewReader { reader in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(session.categories) { category in
                        let selected = session.selectedCategory == category && session.searchQuery.isEmpty
                        Button {
                            session.selectedCategory = category
                            session.searchQuery = ""
                            searchFocused = false
                            onActivity()
                        } label: {
                            Text(category.displayName)
                                .font(MadeToKeepTheme.Typography.sans(size: 16, weight: selected ? .semibold : .regular))
                                .foregroundStyle(selected ? MadeToKeepTheme.ColorPalette.ivoryLight : MadeToKeepTheme.ColorPalette.burgundy)
                                .padding(.horizontal, 18)
                                .frame(minHeight: 48)
                                .background(Capsule().fill(selected ? MadeToKeepTheme.ColorPalette.burgundy : MadeToKeepTheme.ColorPalette.ivoryLight))
                                .overlay(Capsule().strokeBorder(MadeToKeepTheme.ColorPalette.burgundy.opacity(0.4), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .id(category)
                        .accessibilityLabel("\(category.displayName), \(session.assetCount(in: category)) stickers")
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
                .padding(.vertical, 2)
            }
            .onChange(of: session.selectedCategory) { _, category in
                guard let category else { return }
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) { reader.scrollTo(category, anchor: .center) }
            }
        }
    }

    private var searchField: some View {
        HStack {
            Image(systemName: "magnifyingglass").foregroundStyle(MadeToKeepTheme.ColorPalette.mutedInk)
            TextField("Search stickers", text: $session.searchQuery)
                .focused($searchFocused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit { searchFocused = false }
            if !session.searchQuery.isEmpty {
                Button {
                    session.searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(MadeToKeepTheme.ColorPalette.mutedInk)
                }
                .buttonStyle(.plain)
                .frame(width: 44, height: 44)
                .accessibilityLabel("Clear search")
            }
        }
        .font(MadeToKeepTheme.Typography.sans(size: 17))
        .padding(.horizontal, 14)
        .frame(minHeight: 50)
        .background(RoundedRectangle(cornerRadius: 12).fill(MadeToKeepTheme.ColorPalette.ivoryLight))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(MadeToKeepTheme.ColorPalette.hairline))
    }

    @ViewBuilder
    private var palette: some View {
        ScrollViewReader { reader in
            ScrollView {
                localPalette
            }
            .scrollDismissesKeyboard(.interactively)
            .onScrollPhaseChange { _, phase in if phase == .interacting { onActivity() } }
            // A new category or search always starts at its first sticker.
            .onChange(of: session.selectedCategory) { _, _ in reader.scrollTo(Self.paletteTop, anchor: .top) }
            .onChange(of: session.searchQuery) { _, _ in reader.scrollTo(Self.paletteTop, anchor: .top) }
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(MadeToKeepTheme.ColorPalette.ivoryLight.opacity(0.6)))
        .sensoryFeedback(.success, trigger: session.placements.count) { old, new in new > old }
    }

    private static let paletteTop = "sticker-palette-top"
    private let gridColumns = [GridItem(.adaptive(minimum: 92, maximum: 120), spacing: 10)]
    private static let searchSuggestions = ["heart", "cute", "birthday", "love", "party", "travel", "retro", "funny"]

    private var isSearching: Bool { !session.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private var localPalette: some View {
        let assets = session.visibleAssets
        return VStack(alignment: .leading, spacing: 10) {
            Color.clear.frame(height: 0).id(Self.paletteTop)
            if isSearching && !assets.isEmpty {
                Text(assets.count == 1 ? "1 sticker" : "\(assets.count) stickers")
                    .font(MadeToKeepTheme.Typography.sans(size: 14, weight: .medium))
                    .foregroundStyle(MadeToKeepTheme.ColorPalette.secondaryText)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .accessibilityAddTraits(.updatesFrequently)
            }
            if assets.isEmpty {
                emptyPalette
            }
            LazyVGrid(columns: gridColumns, spacing: 10) {
                ForEach(assets) { asset in
                    Button {
                        session.add(asset)
                        searchFocused = false
                        onActivity()
                    } label: {
                        StickerThumbnail(image: session.thumbnails[asset.id], failed: session.failedThumbnails.contains(asset.id), badge: nil)
                            .opacity(session.isAtLimit ? 0.45 : 1)
                    }
                    .buttonStyle(StickerThumbnailButtonStyle(reduceMotion: reduceMotion))
                    .disabled(session.isAtLimit || session.failedThumbnails.contains(asset.id))
                    .onAppear { session.requestThumbnail(for: asset) }
                    .accessibilityLabel("Add \(asset.name) sticker")
                }
            }
            .padding(10)
        }
    }

    @ViewBuilder
    private var emptyPalette: some View {
        VStack(spacing: 14) {
            Text(isSearching ? "No stickers match “\(session.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines))”." : "No stickers here yet.")
                .font(MadeToKeepTheme.Typography.sans(size: 16))
                .foregroundStyle(MadeToKeepTheme.ColorPalette.secondaryText)
                .multilineTextAlignment(.center)
            if isSearching {
                Text("Try one of these:")
                    .font(MadeToKeepTheme.Typography.sans(size: 14))
                    .foregroundStyle(MadeToKeepTheme.ColorPalette.secondaryText)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], spacing: 8) {
                    ForEach(Self.searchSuggestions.filter { !session.catalogSearch($0).isEmpty }, id: \.self) { suggestion in
                        Button(suggestion) {
                            session.searchQuery = suggestion
                            onActivity()
                        }
                        .font(MadeToKeepTheme.Typography.sans(size: 15, weight: .medium))
                        .foregroundStyle(MadeToKeepTheme.ColorPalette.burgundy)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(Capsule().fill(MadeToKeepTheme.ColorPalette.ivoryLight))
                        .overlay(Capsule().strokeBorder(MadeToKeepTheme.ColorPalette.burgundy.opacity(0.35)))
                        .buttonStyle(.plain)
                    }
                }
                Button("Clear Search") {
                    session.searchQuery = ""
                    searchFocused = false
                    onActivity()
                }
                .buttonStyle(MadeToKeepSecondaryButtonStyle())
            }
        }
        .frame(maxWidth: .infinity)
        .padding(24)
    }

    private var editToolbar: some View {
        HStack(spacing: 8) {
            toolbarButton("Undo", systemImage: "arrow.uturn.backward", enabled: session.canUndo) { session.undo() }
            toolbarButton("Redo", systemImage: "arrow.uturn.forward", enabled: session.canRedo) { session.redo() }
            toolbarButton("Delete", systemImage: "trash", enabled: session.selectedPlacementID != nil) { session.deleteSelected() }
            toolbarButton("Reset", systemImage: "arrow.counterclockwise", enabled: !session.placements.isEmpty) { showingResetConfirmation = true }
        }
        .overlay(alignment: .topTrailing) {
            Text("\(session.placements.count)/\(session.limit)")
                .font(MadeToKeepTheme.Typography.sans(size: 12, weight: .semibold))
                .foregroundStyle(MadeToKeepTheme.ColorPalette.secondaryText)
                .offset(y: -16)
                .accessibilityLabel("\(session.placements.count) of \(session.limit) stickers used")
        }
    }

    private func toolbarButton(_ title: String, systemImage: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button {
            action()
            onActivity()
        } label: {
            VStack(spacing: 3) {
                Image(systemName: systemImage).font(.system(size: 19, weight: .semibold))
                Text(title).font(.system(size: 12, weight: .medium))
            }
            .frame(maxWidth: .infinity, minHeight: 56)
            .foregroundStyle(enabled ? MadeToKeepTheme.ColorPalette.burgundy : MadeToKeepTheme.ColorPalette.mutedInk.opacity(0.45))
            .background(RoundedRectangle(cornerRadius: 12).fill(MadeToKeepTheme.ColorPalette.ivoryLight))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(MadeToKeepTheme.ColorPalette.hairline))
        }
        .buttonStyle(.plain)
        .disabled(!enabled || isFinishing)
        .accessibilityLabel(title)
    }

    private var finishButtons: some View {
        VStack(spacing: 10) {
            Button {
                finish(skip: false)
            } label: {
                Text("Done")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(MadeToKeepPrimaryButtonStyle())
            .disabled(isFinishing || session.pendingInsertions > 0)
            .accessibilityHint("Adds your stickers to the receipt.")

            Button {
                if session.placements.isEmpty { finish(skip: true) } else { showingSkipConfirmation = true }
            } label: {
                Text("Skip stickers").frame(maxWidth: .infinity)
            }
            .buttonStyle(MadeToKeepSecondaryButtonStyle())
            .disabled(isFinishing)
            .accessibilityHint("Continues with your original receipt.")
        }
    }

    /// One tap only: the view locks itself and the view model also refuses a second commit.
    private func finish(skip: Bool) {
        guard !isFinishing else { return }
        isFinishing = true
        searchFocused = false
        session.select(nil)
        skip ? onSkip() : onDone()
    }
}

/// Immediate press feedback so a tap on a small thumbnail clearly registers.
private struct StickerThumbnailButtonStyle: ButtonStyle {
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.92 : 1)
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(MadeToKeepTheme.ColorPalette.burgundy, lineWidth: configuration.isPressed ? 2.5 : 0)
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct StickerThumbnail: View {
    let image: UIImage?
    let failed: Bool
    let badge: String?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white)
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(MadeToKeepTheme.ColorPalette.hairline))
            Group {
                if let image {
                    Image(uiImage: image).resizable().interpolation(.medium).scaledToFit().padding(10)
                } else if failed {
                    Image(systemName: "photo.badge.exclamationmark")
                        .font(.system(size: 26))
                        .foregroundStyle(MadeToKeepTheme.ColorPalette.mutedInk.opacity(0.5))
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let badge {
                Text(badge)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Capsule().fill(MadeToKeepTheme.ColorPalette.burgundy))
                    .padding(6)
                    .accessibilityHidden(true)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(minWidth: 88, minHeight: 88)
    }
}

#if DEBUG
#Preview("Sticker Studio", traits: .landscapeLeft) {
    let photos = StickerStudioPreviewView.samplePhotos(count: BoothFormat.grid.photoCount)
    var settings = StickerStudioSettings()
    settings.isEnabled = true
    let session = StickerStudioSession(
        configuration: StickerStudioSessionConfiguration(settings: settings, onlineReady: false),
        catalog: StickerGuestCatalog.make(settings: settings, store: nil),
        generation: 0,
        catalogStore: nil,
        provider: nil
    )
    if let receipt = try? ReceiptComposer.compose(photos: photos, sessionIdentifier: "PREVIEW", format: .grid),
       let layout = receipt.stickerLayout,
       let image = UIImage(data: receipt.imagePNGData) {
        session.setCanvas(image: ReceiptComposer.makePhotoSectionPreviewImage(from: image, previewContentHeight: layout.editorVisibleHeight), layout: layout)
    }
    return StickerStudioView(session: session, onDone: {}, onSkip: {}, onBack: {}, onCancel: {}, onActivity: {})
        .background(MadeToKeepPaperBackground())
}
#endif
