//
//  OperatorStickerLibraryView.swift
//  PocketPixelsBooth
//
//  Manage Stickers: import approved PNG / JPEG / GIF files from Files, name and categorise
//  them, tag them for the current event, enable / disable, reorder and delete. Images are
//  copied into Application Support; nothing needs a backend.
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct OperatorStickerLibraryView: View {
    @State private var records: [CustomStickerRecord] = []
    @State private var thumbnails: [UUID: UIImage] = [:]
    @State private var importCategory: StickerCategory = .reactions
    @State private var showingImporter = false
    @State private var message: String?
    @State private var pendingDeletion: CustomStickerRecord?

    private var store: StickerCatalogStore? { try? StickerCatalogStore() }

    var body: some View {
        List {
            Section {
                LabeledContent("Stickers", value: "\(records.count) (\(records.filter(\.isEnabled).count) enabled)")
                LabeledContent("Storage used", value: ByteCountFormatter.string(fromByteCount: Int64(records.reduce(0) { $0 + $1.byteCount }), countStyle: .file))
                let warnings = records.filter { $0.printWarning != nil }.count
                if warnings > 0 {
                    Label("\(warnings) sticker\(warnings == 1 ? "" : "s") may not print clearly", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                Picker("Import into", selection: $importCategory) {
                    ForEach(StickerCategory.assignableToImports) { Text($0.operatorDisplayName).tag($0) }
                }
                Button {
                    showingImporter = true
                } label: {
                    Label("Import PNG, JPEG or GIF…", systemImage: "square.and.arrow.down")
                }
                if let message {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            } footer: {
                Text("Up to \(StickerImageLimits.maximumImportBytes / 1_048_576) MB per file. Only import images you own or are licensed to print on paid keepsakes. JPEG backgrounds stay as they are (they are not made transparent); PNG transparency is kept. GIFs print as one still frame.")
            }

            Section("Library") {
                if records.isEmpty {
                    Text("No imported stickers yet.").foregroundStyle(.secondary)
                }
                ForEach(records) { record in
                    row(for: record)
                }
                .onMove { source, destination in
                    perform { try $0.move(fromOffsets: source, toOffset: destination) }
                }
            }
        }
        .navigationTitle("Manage Stickers")
        .toolbar { EditButton() }
        .onAppear(perform: reload)
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.png, .jpeg, .gif], allowsMultipleSelection: true) { result in
            importFiles(result)
        }
        .confirmationDialog(
            "Delete “\(pendingDeletion?.name ?? "sticker")”?",
            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Sticker", role: .destructive) {
                if let record = pendingDeletion {
                    perform { try $0.delete(record.id) }
                }
                pendingDeletion = nil
            }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: {
            Text("This removes the image from this iPad. Receipts already printed are not affected.")
        }
    }

    private func row(for record: CustomStickerRecord) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Group {
                if let image = thumbnails[record.id] {
                    Image(uiImage: image).resizable().scaledToFit()
                } else {
                    Image(systemName: "photo").foregroundStyle(.secondary)
                }
            }
            .frame(width: 72, height: 72)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))
            .task(id: record.id) { await loadThumbnail(record) }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 8) {
                TextField("Name", text: Binding(
                    get: { record.name },
                    set: { name in update(record.id) { $0.name = name } }
                ))
                .font(.headline)
                HStack {
                    Picker("Category", selection: Binding(
                        get: { record.category },
                        set: { category in update(record.id) { $0.category = category } }
                    )) {
                        ForEach(StickerCategory.assignableToImports) { Text($0.operatorDisplayName).tag($0) }
                    }
                    .labelsHidden()
                    Toggle("Event", isOn: Binding(
                        get: { record.isInEventCollection },
                        set: { value in update(record.id) { $0.isInEventCollection = value } }
                    ))
                    .toggleStyle(.button)
                    .accessibilityHint("Shows this sticker in the Event collection.")
                }
                HStack(spacing: 10) {
                    Text("\(record.pixelWidth)×\(record.pixelHeight) · \(ByteCountFormatter.string(fromByteCount: Int64(record.byteCount), countStyle: .file))\(record.frameCount > 1 ? " · animated, prints a still" : "")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let warning = record.printWarning {
                        Label(warning, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                    }
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 10) {
                Toggle("Enabled", isOn: Binding(
                    get: { record.isEnabled },
                    set: { value in update(record.id) { $0.isEnabled = value } }
                ))
                .labelsHidden()
                .accessibilityLabel("\(record.name) enabled")
                Button(role: .destructive) {
                    pendingDeletion = record
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Delete \(record.name)")
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: Actions

    private func reload() {
        records = store?.records() ?? []
    }

    private func update(_ id: UUID, _ change: @escaping (inout CustomStickerRecord) -> Void) {
        perform { try $0.update(id, change) }
    }

    private func perform(_ operation: (StickerCatalogStore) throws -> Void) {
        guard let store else {
            message = "The sticker library is unavailable."
            return
        }
        do {
            try operation(store)
            NotificationCenter.default.post(name: StickerCatalogStore.didChangeNotification, object: nil)
        } catch {
            message = error.localizedDescription
        }
        reload()
    }

    private func importFiles(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result else {
            message = "Import cancelled."
            return
        }
        let category = importCategory
        message = "Importing…"
        Task {
            let outcome = await Task.detached(priority: .userInitiated) { () -> (Int, [String]) in
                guard let store = try? StickerCatalogStore() else { return (0, ["The sticker library is unavailable."]) }
                var imported = 0
                var failures: [String] = []
                for url in urls {
                    do {
                        _ = try store.importFile(at: url, category: category)
                        imported += 1
                    } catch {
                        failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
                    }
                }
                return (imported, failures)
            }.value
            message = (["Imported \(outcome.0) sticker\(outcome.0 == 1 ? "" : "s")."] + outcome.1).joined(separator: "\n")
            NotificationCenter.default.post(name: StickerCatalogStore.didChangeNotification, object: nil)
            reload()
        }
    }

    private func loadThumbnail(_ record: CustomStickerRecord) async {
        guard thumbnails[record.id] == nil else { return }
        let image = await Task.detached(priority: .utility) { () -> UIImage? in
            guard let store = try? StickerCatalogStore() else { return nil }
            return store.image(for: record, frameIndex: record.frameCount > 1 ? record.frameCount / 2 : 0, maximumPixelDimension: 160)
                .map { UIImage(cgImage: $0) }
        }.value
        thumbnails[record.id] = image
    }
}
