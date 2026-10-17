//
//  SamplePrintStudioView.swift
//  PocketPixelsBooth
//
//  Operator Home → Print Display Samples. One screen: choose format, import photos, arrange the
//  slots, preview the exact thermal raster and print it.
//

import PhotosUI
import SwiftUI

struct SamplePrintStudioView: View {
    @StateObject private var model: SamplePrintStudioModel
    private let usesPreviewDesign: Bool
    @StateObject private var printer = PrinterCoordinator.shared
    @StateObject private var operations = EventOperationalState.shared
    @AppStorage("printerIP") private var printerIP = BoothConfiguration.defaultPrinterIP
    @AppStorage("printerPort") private var printerPort = BoothConfiguration.defaultPrinterPort
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var selectedSlot: Int?

    init(previewProfile: EventProfile? = nil) {
        usesPreviewDesign = previewProfile != nil
        _model = StateObject(wrappedValue: SamplePrintStudioModel(previewProfile: previewProfile))
    }

    private var gate: SamplePrintStudioModel.PrinterGate {
        .init(
            printerBusy: printer.isWorking,
            recoveryLocked: printer.requiresRecovery,
            unresolvedPrint: operations.hasUnresolvedPrint,
            guestSessionActive: operations.customerSessionActive
        )
    }

    var body: some View {
        GeometryReader { proxy in
            let wide = proxy.size.width >= 900
            ScrollView {
                Group {
                    if wide {
                        HStack(alignment: .top, spacing: 24) {
                            controls.frame(maxWidth: .infinity)
                            previewColumn.frame(width: min(420, proxy.size.width * 0.4))
                        }
                    } else {
                        VStack(spacing: 20) {
                            controls
                            previewColumn
                        }
                    }
                }
                .padding(24)
                .frame(maxWidth: 1180)
                .frame(maxWidth: .infinity)
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("Print Display Samples")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: pickerItems) { _, items in importPhotos(items) }
        .onChange(of: model.format) { _, _ in selectedSlot = nil }
        .onReceive(NotificationCenter.default.publisher(for: EventProfileStore.didChangeNotification)) { _ in
            model.reloadSavedBranding()
        }
        .task { operations.refresh() }
        .sheet(item: Binding(get: { selectedSlot.map(SlotSelection.init) }, set: { selectedSlot = $0?.index })) { selection in
            SamplePhotoChooser(model: model, slot: selection.index) { selectedSlot = nil }
        }
    }

    // MARK: Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 20) {
            StudioStep(number: 1, title: "Choose Format") {
                Picker("Format", selection: Binding(get: { model.format }, set: { model.setFormat($0) })) {
                    ForEach(BoothFormat.allCases) { format in
                        Text(format.displayName).tag(format)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(model.isPrinting)
                Text("\(model.format.displayName) prints \(model.format.photoCountLabel).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            StudioStep(number: 2, title: "Import & Arrange Photos") {
                HStack {
                    PhotosPicker(
                        selection: $pickerItems,
                        maxSelectionCount: max(1, SamplePrintPolicy.maximumImportedPhotos - model.library.count),
                        selectionBehavior: .ordered,
                        matching: .images
                    ) {
                        Label(model.isImporting ? "Importing…" : "Import from Photos", systemImage: "photo.on.rectangle.angled")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isPrinting || model.isImporting || model.library.count >= SamplePrintPolicy.maximumImportedPhotos)
                    if model.isImporting { ProgressView().padding(.leading, 6) }
                    Spacer()
                    if !model.library.isEmpty {
                        Button("Remove All", role: .destructive) { model.removeAllPhotos() }
                            .disabled(model.isPrinting)
                    }
                }
                Text("Photos fill the slots in the order you pick them. Tap a slot to replace it or to use the same photo again.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                    ForEach(model.slots.indices, id: \.self) { index in
                        SampleSlotCard(model: model, index: index) { selectedSlot = index }
                    }
                }

                if !model.library.isEmpty {
                    Text("Photo tray (\(model.library.count) of \(SamplePrintPolicy.maximumImportedPhotos))")
                        .font(.subheadline.weight(.semibold))
                        .padding(.top, 4)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(model.library) { photo in
                                SampleTrayThumbnail(photo: photo, uses: model.usageCount(of: photo.id)) {
                                    model.removeFromLibrary(photo.id)
                                }
                                .disabled(model.isPrinting)
                            }
                        }
                    }
                }
            }

            StudioStep(number: 3, title: "Design") {
                Picker("Gallery Code Style", selection: $model.footerStyle) {
                    ForEach(ReceiptFooterStyle.allCases) { style in Text(style.displayName).tag(style) }
                }
                Text("Samples show a non-scannable placeholder. No customer gallery is created.").font(.footnote).foregroundStyle(.secondary)
                Picker("Branding", selection: $model.branding) {
                    ForEach(SamplePrintBranding.allCases) { branding in
                        Text(usesPreviewDesign && branding == .savedEvent ? "Preview Design" : branding.displayName).tag(branding)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(model.isPrinting || !model.hasSavedEventBranding)
                Text(usesPreviewDesign
                     ? "Samples use the design from the receipt preview. Guest branding and event acceptance are unchanged."
                     : model.hasSavedEventBranding
                     ? "Saved Event Branding uses the design guests currently receive. Unsaved edits are never used."
                     : "No event branding is saved, so samples use the Made to Keep Studios design.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if model.format == .passport {
                    VStack(alignment: .leading, spacing: 10) {
                        TextField("Name", text: Binding(
                            get: { model.photoPass.name },
                            set: { model.photoPass.name = String($0.prefix(PassportSessionData.nameLimit)) }
                        ))
                        TextField("Note (optional)", text: Binding(
                            get: { model.photoPass.note },
                            set: { model.photoPass.note = String($0.prefix(PassportSessionData.notesLimit)) }
                        ))
                        Toggle("Example signature", isOn: $model.photoPass.includesSignature)
                    }
                    .textFieldStyle(.roundedBorder)
                    .disabled(model.isPrinting)
                    .padding(.top, 4)
                }
            }
        }
    }

    // MARK: Preview and print

    private var previewColumn: some View {
        StudioStep(number: 4, title: "Preview & Print") {
            ZStack {
                if let image = model.previewImage {
                    Image(uiImage: image)
                        .resizable()
                        .interpolation(.none)
                        .scaledToFit()
                        .opacity(model.previewState == .rendering ? 0.45 : 1)
                        .overlay { Rectangle().stroke(Color.secondary.opacity(0.25)) }
                        .accessibilityLabel("Exact printer raster, diagnostic")
                }
                switch model.previewState {
                case .rendering, .idle:
                    ProgressView("Preparing receipt…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                case .failed(let message):
                    Text(message).font(.footnote).foregroundStyle(.secondary).padding()
                case .ready:
                    EmptyView()
                }
            }
            .frame(maxWidth: .infinity, minHeight: 320)
            .padding(12)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 12))

            if let receipt = model.printableSample?.receipt {
                Text("Exact printer raster · diagnostic · \(String(format: "%.0f", receipt.estimatedLengthMillimeters)) mm long · no QR or session ID")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Stepper(value: $model.copies, in: 1...SamplePrintPolicy.maximumCopies) {
                Text(model.copies == 1 ? "1 copy" : "\(model.copies) copies").font(.headline)
            }
            .disabled(model.isPrinting)

            Button {
                model.print(gate: gate) { raster, copy, copies, batchID in
                    await sendCopy(raster: raster, copy: copy, copies: copies, batchID: batchID)
                }
            } label: {
                Label(model.isPrinting ? "Printing…" : (model.copies == 1 ? "Print Sample" : "Print \(model.copies) Samples"), systemImage: "printer.fill")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canPrint(gate))

            if let reason = model.blockedReason(gate) {
                Label(reason, systemImage: "info.circle").font(.footnote).foregroundStyle(.secondary)
            }
            if let status = model.status {
                Text(status).font(.footnote.weight(.medium))
            }
            Text("Samples do not start a guest session, take payment, create a gallery or upload photos.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func sendCopy(raster: ThermalRasterizedImage, copy: Int, copies: Int, batchID: UUID) async -> Result<Void, Error> {
        await withCheckedContinuation { continuation in
            printer.printReceipt(
                rasterizedImage: raster,
                wifiHost: printerIP,
                wifiPort: UInt16(printerPort.trimmingCharacters(in: .whitespacesAndNewlines)),
                sessionIdentifier: SamplePrintPolicy.auditSessionIdentifier,
                source: .operatorSample,
                copyIndex: copy,
                copyCount: copies,
                batchID: batchID,
                transportPolicy: printer.productionReceiptTransportPolicy
            ) { result in
                continuation.resume(returning: result)
            }
        }
    }

    private func importPhotos(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        pickerItems = []
        model.beginImport()
        Task {
            var decoded: [SamplePrintPhoto] = []
            for item in items {
                guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
                let photo = await Task.detached(priority: .userInitiated) { SamplePhotoDecoder.decode(data) }.value
                if let photo { decoded.append(photo) }
            }
            model.finishImport(decoded: decoded, requested: items.count)
        }
    }
}

private struct SlotSelection: Identifiable {
    let index: Int
    var id: Int { index }
}

private struct StudioStep<Content: View>: View {
    let number: Int
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text("\(number)")
                    .font(.subheadline.bold())
                    .frame(width: 28, height: 28)
                    .background(Color.primary.opacity(0.08), in: Circle())
                Text(title).font(.title3.weight(.semibold))
            }
            content
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 18))
        .overlay { RoundedRectangle(cornerRadius: 18).stroke(.separator.opacity(0.5)) }
    }
}

struct SampleSlotCard: View {
    @ObservedObject var model: SamplePrintStudioModel
    let index: Int
    let choose: () -> Void

    var body: some View {
        let photo = model.photo(for: model.photoID(at: index))
        VStack(spacing: 8) {
            Button(action: choose) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05))
                    if let photo {
                        Image(uiImage: photo.thumbnail)
                            .resizable()
                            .scaledToFill()
                            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                            .clipped()
                    } else {
                        VStack(spacing: 6) {
                            Image(systemName: "plus.circle").font(.title2)
                            Text("Choose photo").font(.caption)
                        }
                        .foregroundStyle(.secondary)
                    }
                }
                .aspectRatio(3 / 4, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(photo == nil ? Color.orange.opacity(0.6) : Color.secondary.opacity(0.25), style: StrokeStyle(lineWidth: 1.5, dash: photo == nil ? [6, 4] : []))
                }
            }
            .buttonStyle(.plain)
            .disabled(model.library.isEmpty || model.isPrinting || !model.slots.indices.contains(index))
            .accessibilityLabel("\(model.slotTitle(index)), \(photo == nil ? "empty" : "filled")")

            HStack(spacing: 4) {
                Text(model.slotTitle(index)).font(.caption.weight(.semibold))
                Spacer(minLength: 0)
                Menu {
                    Button("Replace…", systemImage: "photo") { choose() }
                        .disabled(model.library.isEmpty)
                    Button("Copy to Next Empty Slot", systemImage: "plus.square.on.square") { model.duplicateIntoNextEmptySlot(index) }
                        .disabled(photo == nil || model.missingSlotCount == 0)
                    Button("Move Earlier", systemImage: "arrow.left") { model.moveSlot(index, by: -1) }
                        .disabled(index == 0)
                    Button("Move Later", systemImage: "arrow.right") { model.moveSlot(index, by: 1) }
                        .disabled(index == model.slots.count - 1)
                    Button("Clear Slot", systemImage: "xmark", role: .destructive) { model.clearSlot(index) }
                        .disabled(photo == nil)
                } label: {
                    Image(systemName: "ellipsis.circle").font(.title3).frame(minWidth: 44, minHeight: 32)
                }
                .disabled(model.isPrinting)
                .accessibilityLabel("\(model.slotTitle(index)) options")
            }
        }
    }
}

private struct SampleTrayThumbnail: View {
    let photo: SamplePrintPhoto
    let uses: Int
    let remove: () -> Void

    var body: some View {
        Image(uiImage: photo.thumbnail)
            .resizable()
            .scaledToFill()
            .frame(width: 76, height: 76)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .bottomLeading) {
                if uses > 0 {
                    Text(uses == 1 ? "In use" : "×\(uses)")
                        .font(.caption2.bold())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.thinMaterial, in: Capsule())
                        .padding(4)
                }
            }
            .overlay(alignment: .topTrailing) {
                Button(action: remove) {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.6))
                        .font(.title3)
                }
                .padding(2)
                .accessibilityLabel("Remove photo from tray")
            }
    }
}

struct SamplePhotoChooser: View {
    @ObservedObject var model: SamplePrintStudioModel
    let slot: Int
    let dismiss: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 12)], spacing: 12) {
                    ForEach(model.library) { photo in
                        Button {
                            model.assign(photo.id, to: slot)
                            dismiss()
                        } label: {
                            Image(uiImage: photo.thumbnail)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 120, height: 120)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .overlay {
                                    if model.photoID(at: slot) == photo.id {
                                        RoundedRectangle(cornerRadius: 10).stroke(Color.accentColor, lineWidth: 4)
                                    }
                                }
                                .overlay(alignment: .bottomLeading) {
                                    let uses = model.usageCount(of: photo.id)
                                    if uses > 0 && model.photoID(at: slot) != photo.id {
                                        Text("Used · tap to duplicate").font(.caption2.bold())
                                            .padding(4).background(.thinMaterial, in: Capsule()).padding(4)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding()
            }
            .navigationTitle("Choose \(model.slotTitle(slot))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: dismiss) }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
