//
//  SamplePrintStudioModel.swift
//  PocketPixelsBooth
//
//  Sample Print Studio: display receipts made from the operator's own photos with the production
//  compositor and rasterizer. The thermal raster shown in the preview is retained and is the exact
//  data sent to the printer; any change to photos, order, format, branding or Photo Pass details
//  discards it. Samples never start a guest session, take payment, consume an entitlement, create
//  a gallery, upload anything or change event settings. They are traceable in the print audit as
//  `PrintJobSource.operatorSample` only.
//

import Combine
import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// One photo imported from the iPad's library, decoded once at a print-safe size.
struct SamplePrintPhoto: Identifiable, @unchecked Sendable {
    let id: UUID
    let image: UIImage
    let thumbnail: UIImage
}

nonisolated enum SamplePrintBranding: String, CaseIterable, Identifiable, Sendable {
    /// The standard Made to Keep Studios receipt.
    case standard
    /// Applied guest branding, or an explicit preview snapshot when opened from a design.
    case savedEvent

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .standard: "Made to Keep Studios"
        case .savedEvent: "Saved Event Branding"
        }
    }
}

/// Editable Photo Pass details for a display sample.
nonisolated struct SamplePhotoPassDetails: Equatable, Sendable {
    var name = "Alex Rivera"
    var note = "Best night of the year."
    var includesSignature = true

    func sessionData(configuration: PassportConfiguration) -> PassportSessionData {
        let example = PassportSessionData.operatorPreviewSample(configuration: configuration)
        return PassportSessionData(
            name: name,
            notes: note,
            signature: includesSignature ? example.signature : .empty,
            configuration: configuration,
            designVersion: .current
        ).normalized()
    }
}

/// Everything that determines the printed sample. A prepared raster is only printable while its
/// request equals the studio's current request.
nonisolated struct SamplePrintRequest: Equatable, Sendable {
    let format: BoothFormat
    /// One entry per receipt slot, in print order. `nil` is an empty slot.
    let slotPhotoIDs: [UUID?]
    let branding: SamplePrintBranding
    let eventProfile: EventProfile?
    let photoPass: SamplePhotoPassDetails?

    var isComplete: Bool {
        slotPhotoIDs.count == format.photoCount && slotPhotoIDs.allSatisfy { $0 != nil }
    }
}

struct PreparedSamplePrint: @unchecked Sendable {
    let request: SamplePrintRequest
    let receipt: ComposedReceipt
    let raster: ThermalRasterizedImage
    let previewImage: UIImage
}

nonisolated enum SamplePrintPolicy {
    static let maximumCopies = 5
    static let maximumImportedPhotos = 12
    /// Longest edge kept for imported photos: well above the 576-dot receipt, bounded for memory.
    static let importMaximumPixelSize = 2_000
    /// Internal print-audit identifier. It is never printed on the receipt.
    static let auditSessionIdentifier = "operator-sample"

    static func canStart(
        hasPreview: Bool,
        printerBusy: Bool,
        recoveryLocked: Bool,
        unresolvedPrint: Bool,
        operationActive: Bool,
        guestSessionActive: Bool
    ) -> Bool {
        hasPreview && !printerBusy && !recoveryLocked && !unresolvedPrint && !operationActive && !guestSessionActive
    }

    static func clampedCopies(_ copies: Int) -> Int {
        min(max(copies, 1), maximumCopies)
    }
}

/// Composition shared by Sample Print Studio and the read-only branding previews.
nonisolated enum SamplePrintComposer {
    static func compose(
        photos: [UIImage],
        format: BoothFormat,
        eventProfile: EventProfile?,
        photoPass: SamplePhotoPassDetails?,
        date: Date,
        photoQualityProfile: PocketPixelsThermalPhotoProfile
    ) throws -> ComposedReceipt {
        try ReceiptComposer.compose(
            photos: photos,
            sessionIdentifier: SamplePrintPolicy.auditSessionIdentifier,
            date: date,
            // No gallery exists for a sample, so no QR is ever printed.
            galleryURL: nil,
            format: format,
            eventProfile: eventProfile,
            passport: format == .passport
                ? (photoPass ?? SamplePhotoPassDetails()).sessionData(configuration: PassportConfiguration.effective(for: eventProfile))
                : nil,
            photoQualityProfile: photoQualityProfile,
            printsSessionIdentifier: false
        )
    }

    /// Composes and rasterizes once; the returned raster is what prints.
    static func prepare(
        request: SamplePrintRequest,
        photos: [UIImage],
        date: Date,
        photoQualityProfile: PocketPixelsThermalPhotoProfile
    ) throws -> PreparedSamplePrint {
        let receipt = try compose(
            photos: photos,
            format: request.format,
            eventProfile: request.branding == .savedEvent ? request.eventProfile : nil,
            photoPass: request.photoPass,
            date: date,
            photoQualityProfile: photoQualityProfile
        )
        try Task.checkCancellation()
        guard let image = UIImage(data: receipt.imagePNGData) else { throw ReceiptComposerError.renderFailed }
        let raster = try ThermalImageRasterizer.rasterize(image, purpose: .completeReceipt)
        guard let preview = UIImage(data: raster.previewPNGData) else { throw ThermalImageRasterizerError.renderFailed }
        return PreparedSamplePrint(request: request, receipt: receipt, raster: raster, previewImage: preview)
    }

    /// Neutral numbered frame shown for an empty slot. Only ever previewed: an incomplete sample
    /// cannot be printed.
    static func placeholderPhoto(slot: Int) -> UIImage {
        let size = CGSize(width: 900, height: 1200)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor(white: 0.93, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor(white: 0.55, alpha: 1).setStroke()
            context.cgContext.setLineWidth(10)
            context.cgContext.setLineDash(phase: 0, lengths: [36, 24])
            context.cgContext.stroke(CGRect(origin: .zero, size: size).insetBy(dx: 60, dy: 60))
            let label = "PHOTO \(slot + 1)" as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 84, weight: .semibold),
                .foregroundColor: UIColor(white: 0.45, alpha: 1),
                .kern: 8
            ]
            let labelSize = label.size(withAttributes: attributes)
            label.draw(at: CGPoint(x: (size.width - labelSize.width) / 2, y: (size.height - labelSize.height) / 2), withAttributes: attributes)
        }
    }
}

/// Memory-safe import: ImageIO decodes straight to a bounded size and applies EXIF orientation,
/// so a 48 MP library photo never decodes at full resolution.
nonisolated enum SamplePhotoDecoder {
    static func decode(_ data: Data, maximumPixelSize: Int = SamplePrintPolicy.importMaximumPixelSize) -> SamplePrintPhoto? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = thumbnail(source, maximumPixelSize: maximumPixelSize),
              let thumbnail = thumbnail(source, maximumPixelSize: 320) else { return nil }
        return SamplePrintPhoto(id: UUID(), image: UIImage(cgImage: image), thumbnail: UIImage(cgImage: thumbnail))
    }

    private static func thumbnail(_ source: CGImageSource, maximumPixelSize: Int) -> CGImage? {
        CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize
        ] as CFDictionary)
    }
}

@MainActor
final class SamplePrintStudioModel: ObservableObject {
    enum PreviewState: Equatable {
        case idle
        case rendering
        case ready
        case failed(String)
    }

    @Published private(set) var format: BoothFormat = .duo
    @Published private(set) var slots: [UUID?] = Array(repeating: nil, count: BoothFormat.duo.photoCount)
    @Published private(set) var library: [SamplePrintPhoto] = []
    @Published var branding: SamplePrintBranding = .standard { didSet { if branding != oldValue { invalidate() } } }
    @Published var photoPass = SamplePhotoPassDetails() { didSet { if photoPass != oldValue { invalidate() } } }
    @Published var copies = 1 { didSet { if copies != SamplePrintPolicy.clampedCopies(copies) { copies = SamplePrintPolicy.clampedCopies(copies) } } }
    @Published private(set) var savedEventProfile: EventProfile?
    @Published private(set) var prepared: PreparedSamplePrint?
    @Published private(set) var previewImage: UIImage?
    @Published private(set) var previewState: PreviewState = .idle
    @Published private(set) var isImporting = false
    @Published private(set) var isPrinting = false
    @Published private(set) var status: String?

    private var renderTask: Task<Void, Never>?
    private var generation = 0
    private let loadProfile: () -> EventProfile
    private let photoQualityProfile: () -> PocketPixelsThermalPhotoProfile

    init(
        previewProfile: EventProfile? = nil,
        loadProfile: @escaping () -> EventProfile = { EventProfileStore.load() },
        photoQualityProfile: @escaping () -> PocketPixelsThermalPhotoProfile = { CustomerReceiptPhotoToneStore.load().profile }
    ) {
        // A design preview supplies a value snapshot. Printing it never publishes/applies it,
        // and later saved-branding notifications cannot replace it with the guest profile.
        if let previewProfile { self.loadProfile = { previewProfile } }
        else { self.loadProfile = loadProfile }
        self.photoQualityProfile = photoQualityProfile
        reloadSavedBranding()
        branding = savedEventProfile == nil ? .standard : .savedEvent
    }

    deinit { renderTask?.cancel() }

    // MARK: Request

    var request: SamplePrintRequest {
        SamplePrintRequest(
            format: format,
            slotPhotoIDs: slots,
            branding: branding,
            eventProfile: branding == .savedEvent ? savedEventProfile : nil,
            photoPass: format == .passport ? photoPass : nil
        )
    }

    var filledSlotCount: Int { slots.compactMap { $0 }.count }
    var missingSlotCount: Int { slots.count - filledSlotCount }
    var hasSavedEventBranding: Bool { savedEventProfile != nil }

    /// Only a raster prepared for exactly the current, complete request is printable.
    var printableSample: PreparedSamplePrint? {
        guard let prepared, prepared.request == request, request.isComplete else { return nil }
        return prepared
    }

    func photo(for id: UUID?) -> SamplePrintPhoto? {
        guard let id else { return nil }
        return library.first { $0.id == id }
    }

    func slotTitle(_ index: Int) -> String {
        guard format == .passport else { return "Photo \(index + 1)" }
        return index == PhotoPassReceiptLayout.portraitPhotoIndex ? "Portrait" : "Main Photo"
    }

    func usageCount(of id: UUID) -> Int { slots.filter { $0 == id }.count }

    // MARK: Editing

    func setFormat(_ newFormat: BoothFormat) {
        guard newFormat != format, !isPrinting else { return }
        format = newFormat
        var resized = Array(slots.prefix(newFormat.photoCount))
        resized += Array(repeating: nil, count: max(0, newFormat.photoCount - resized.count))
        slots = resized
        fillEmptySlotsWithUnusedPhotos()
        invalidate()
    }

    func addImported(_ photos: [SamplePrintPhoto]) {
        let room = SamplePrintPolicy.maximumImportedPhotos - library.count
        guard room > 0 else {
            status = "The photo tray holds \(SamplePrintPolicy.maximumImportedPhotos) photos. Remove one to import more."
            return
        }
        library += photos.prefix(room)
        if photos.count > room {
            status = "Imported \(room) of \(photos.count). The photo tray holds \(SamplePrintPolicy.maximumImportedPhotos) photos."
        }
        fillEmptySlotsWithUnusedPhotos()
        invalidate()
    }

    /// Places a photo in a slot. Choosing a photo that is already used elsewhere is the explicit
    /// way to duplicate it.
    func assign(_ photoID: UUID, to slot: Int) {
        guard slots.indices.contains(slot), library.contains(where: { $0.id == photoID }), !isPrinting else { return }
        slots[slot] = photoID
        invalidate()
    }

    func clearSlot(_ slot: Int) {
        guard slots.indices.contains(slot), !isPrinting else { return }
        slots[slot] = nil
        invalidate()
    }

    /// Copies a slot's photo into the next empty slot.
    func duplicateIntoNextEmptySlot(_ slot: Int) {
        guard slots.indices.contains(slot), let id = slots[slot], let empty = slots.firstIndex(where: { $0 == nil }), !isPrinting else { return }
        slots[empty] = id
        invalidate()
    }

    func moveSlot(_ slot: Int, by offset: Int) {
        let target = slot + offset
        guard slots.indices.contains(slot), slots.indices.contains(target), !isPrinting else { return }
        slots.swapAt(slot, target)
        invalidate()
    }

    func removeFromLibrary(_ photoID: UUID) {
        guard !isPrinting else { return }
        library.removeAll { $0.id == photoID }
        slots = slots.map { $0 == photoID ? nil : $0 }
        invalidate()
    }

    func removeAllPhotos() {
        guard !isPrinting else { return }
        library = []
        slots = Array(repeating: nil, count: format.photoCount)
        invalidate()
    }

    func reloadSavedBranding() {
        let profile = loadProfile().normalized()
        let saved = profile.activeReceiptSnapshot == nil ? nil : profile
        guard saved != savedEventProfile else { return }
        savedEventProfile = saved
        if saved == nil, branding == .savedEvent { branding = .standard }
        invalidate()
    }

    func beginImport() { isImporting = true; status = nil }
    func finishImport(decoded: [SamplePrintPhoto], requested: Int) {
        isImporting = false
        if decoded.isEmpty, requested > 0 {
            status = "Those photos could not be opened. Try different photos."
            return
        }
        if decoded.count < requested {
            status = "\(requested - decoded.count) photo(s) could not be opened."
        }
        addImported(decoded)
    }

    /// Fills empty slots, in order, with library photos that are not used yet. Never repeats a
    /// photo on its own: duplicates are only made explicitly.
    private func fillEmptySlotsWithUnusedPhotos() {
        var unused = library.map(\.id).filter { !slots.contains($0) }
        for index in slots.indices where slots[index] == nil && !unused.isEmpty {
            slots[index] = unused.removeFirst()
        }
    }

    // MARK: Preparation

    /// Discards the prepared raster and schedules a new one (debounced, generation-checked).
    func invalidate() {
        prepared = nil
        renderTask?.cancel()
        generation += 1
        let generation = generation
        let request = request
        let photos = slots.enumerated().map { index, id in
            photo(for: id)?.image ?? SamplePrintComposer.placeholderPhoto(slot: index)
        }
        let profile = photoQualityProfile()
        previewState = .rendering
        renderTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled else { return }
            let worker = Task.detached(priority: .userInitiated) {
                try SamplePrintComposer.prepare(request: request, photos: photos, date: Date(), photoQualityProfile: profile)
            }
            let result = await withTaskCancellationHandler {
                await worker.result
            } onCancel: {
                worker.cancel()
            }
            guard let self, !Task.isCancelled, generation == self.generation else { return }
            switch result {
            case .success(let sample):
                self.prepared = sample
                self.previewImage = sample.previewImage
                self.previewState = .ready
            case .failure(let error):
                self.previewImage = nil
                self.previewState = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: Printing

    struct PrinterGate {
        var printerBusy: Bool
        var recoveryLocked: Bool
        var unresolvedPrint: Bool
        var guestSessionActive: Bool
    }

    func canPrint(_ gate: PrinterGate) -> Bool {
        SamplePrintPolicy.canStart(
            hasPreview: printableSample != nil,
            printerBusy: gate.printerBusy,
            recoveryLocked: gate.recoveryLocked,
            unresolvedPrint: gate.unresolvedPrint,
            operationActive: isPrinting,
            guestSessionActive: gate.guestSessionActive
        )
    }

    func blockedReason(_ gate: PrinterGate) -> String? {
        if gate.guestSessionActive { return "A guest session is in progress. Print samples between guests." }
        if gate.unresolvedPrint { return "Resolve the previous print in Fix Printer before printing samples." }
        if gate.recoveryLocked { return "Printer needs attention. Open Fix Printer first." }
        if gate.printerBusy && !isPrinting { return "Printer is busy. Wait for the current print to finish." }
        if missingSlotCount > 0 {
            return missingSlotCount == 1 ? "Fill 1 more photo slot to print." : "Fill \(missingSlotCount) more photo slots to print."
        }
        return nil
    }

    /// Sends the retained raster `copies` times, one copy at a time through the spooler. Stops at
    /// the first failure. Never recomposes.
    func print(
        gate: PrinterGate,
        send: @escaping (_ raster: ThermalRasterizedImage, _ copy: Int, _ copies: Int, _ batchID: UUID) async -> Result<Void, Error>
    ) {
        guard canPrint(gate), let sample = printableSample else {
            status = blockedReason(gate) ?? "Preparing the receipt preview."
            return
        }
        let copies = SamplePrintPolicy.clampedCopies(self.copies)
        let batchID = UUID()
        isPrinting = true
        status = copies == 1 ? "Printing sample..." : "Printing copy 1 of \(copies)..."
        Task { [weak self] in
            var completed = 0
            for copy in 1...copies {
                self?.status = copies == 1 ? "Printing sample..." : "Printing copy \(copy) of \(copies)..."
                let result = await send(sample.raster, copy, copies, batchID)
                guard case .success = result else { break }
                completed = copy
            }
            guard let self else { return }
            self.isPrinting = false
            if completed == copies {
                self.status = copies == 1 ? "Sample printed." : "\(copies) samples printed."
            } else {
                self.status = "\(completed) of \(copies) printed. Printer needs attention."
            }
        }
    }
}
