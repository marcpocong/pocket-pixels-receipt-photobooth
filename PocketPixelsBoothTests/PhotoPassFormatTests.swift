import CoreImage
import Foundation
import UIKit
import XCTest
@testable import PocketPixelsBooth

/// Photo Pass is the v2 design of the `.passport` format. Legacy Passport behaviour stays
/// covered by PassportFormatTests.
@MainActor
final class PhotoPassFormatTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_788_692_040)
    private let token = String(repeating: "e", count: 64)

    // MARK: A. Format

    func testCustomerFacingNameIsPhotoPassButStoredIdentityStaysPassport() throws {
        XCTAssertEqual(BoothFormat.passport.displayName, "Photo Pass")
        XCTAssertEqual(BoothFormat.passport.shortDescription, "Two-photo event keepsake")
        XCTAssertEqual(BoothFormat.passport.reviewSummary, "PHOTO PASS · 2 PHOTOS")
        XCTAssertEqual(BoothFormat.passport.rawValue, "passport")
        XCTAssertEqual(BoothFormat.passport.photoCount, 2)
        XCTAssertEqual(String(data: try JSONEncoder().encode(BoothFormat.passport), encoding: .utf8), "\"passport\"")
        XCTAssertThrowsError(try ReceiptComposer.compose(photos: [photo(seed: 1, landscape: false)], sessionIdentifier: "PP-ONE", date: date, format: .passport, passport: .photoPassDebugFixture))
    }

    // MARK: B. Flow

    func testPhotoPassFlowKeepsPhotosNameNoteAndSignatureWhenGoingBack() throws {
        let model = BoothSessionViewModel()
        model.selectedBoothFormat = .passport
        model.isCameraUnavailable = true
        model.state = .cameraReady
        XCTAssertEqual(model.passportDraft.designVersion, .photoPassV2, "New sessions use the Photo Pass design")

        model.addSamplePhoto(photo(seed: 1, landscape: false))
        model.addSamplePhoto(photo(seed: 2, landscape: true))
        XCTAssertEqual(model.state, .review)
        let captured = model.capturedPhotos
        XCTAssertFalse(model.canContinueToReceipt, "Review never commits a Photo Pass directly")
        model.continueToReceipt()
        XCTAssertEqual(model.state, .passportDetails)

        model.passportDraft.name = "Karynne Jaca"
        model.passportDraft.notes = "Keep this little moment."
        model.continueFromPassportDetails()
        XCTAssertEqual(model.state, .passportSignature)
        model.updatePassportSignature(.debugFixture)
        model.continueFromPassportSignature()
        XCTAssertEqual(model.state, .passportPreview)

        model.backToPassportDetails()
        XCTAssertEqual(model.state, .passportDetails)
        XCTAssertEqual(model.passportDraft.name, "Karynne Jaca")
        XCTAssertEqual(model.passportDraft.notes, "Keep this little moment.")
        XCTAssertEqual(model.passportDraft.signature, PassportSignature.debugFixture.normalized())

        model.backToReview()
        XCTAssertEqual(model.state, .review)
        XCTAssertEqual(model.capturedPhotos.count, 2)
        XCTAssertTrue(zip(model.capturedPhotos, captured).allSatisfy { $0 === $1 }, "Going back keeps both photos")
        XCTAssertEqual(model.passportDraft.notes, "Keep this little moment.")

        model.retakePhoto(at: 0)
        XCTAssertTrue(model.capturedPhotos[1] === captured[1], "Retaking Photo 1 leaves the hero photo alone")
        XCTAssertEqual(model.passportDraft.name, "Karynne Jaca")
        model.cancelSession()
    }

    // MARK: C. Session data

    func testNotesAndDesignVersionCodableRoundTripAndLegacyDefaults() throws {
        let value = PassportSessionData.photoPassDebugFixture
        let decoded = try JSONDecoder().decode(PassportSessionData.self, from: JSONEncoder().encode(value))
        XCTAssertEqual(decoded, value)
        XCTAssertEqual(decoded.notes, "Keep this little moment.")
        XCTAssertEqual(decoded.designVersion, .photoPassV2)

        // A session archived before Photo Pass existed: no notes, no design version.
        let legacyJSON = #"{"name":"Ana","nationality":"Filipino","profession":"Guest","birthplace":"","signature":{"strokes":[]},"configuration":{"theme":"stars","titleSource":"automatic","title":"POCKET PASSPORT","subtitle":"","eventLabel":""},"frozenAge":30}"#
        let legacy = try JSONDecoder().decode(PassportSessionData.self, from: Data(legacyJSON.utf8))
        XCTAssertEqual(legacy.designVersion, .legacyPassport, "Old archives keep the legacy design")
        XCTAssertEqual(legacy.notes, "")
        XCTAssertEqual(legacy.name, "Ana")
        XCTAssertEqual(legacy.configuration.theme, .stars)

        let unknownVersion = try JSONDecoder().decode(PassportSessionData.self, from: Data(#"{"name":"Ana","designVersion":"photoPassV9","notes":7}"#.utf8))
        XCTAssertEqual(unknownVersion.designVersion, .legacyPassport, "Unreadable new fields fall back safely")
        XCTAssertEqual(unknownVersion.notes, "")

        XCTAssertEqual(PassportSessionData().designVersion, .photoPassV2)
        XCTAssertEqual(PassportSessionData.empty.designVersion, .photoPassV2)
    }

    func testNotesNormalizationLimitAndHasAnyDetails() {
        var data = PassportSessionData(notes: "  Keep\n this \t little moment\u{0007} " + String(repeating: "x", count: 90))
        XCTAssertTrue(data.hasAnyDetails)
        data = data.normalized(referenceDate: date)
        XCTAssertTrue(data.notes.hasPrefix("Keep this little moment x"))
        XCTAssertEqual(data.notes.count, PassportSessionData.notesLimit)
        XCTAssertFalse(data.notes.contains("\u{0007}"))
        XCTAssertEqual(data.designVersion, .photoPassV2, "Normalizing keeps the design version")

        let committed = PassportSessionData.photoPassDebugFixture.committed(at: date)
        XCTAssertEqual(committed.notes, "Keep this little moment.")
        XCTAssertEqual(committed.designVersion, .photoPassV2)
        XCTAssertFalse(PassportSessionData.empty.hasAnyDetails)
    }

    func testCustomerResetClearsNameNotesAndSignature() {
        let model = BoothSessionViewModel()
        model.selectedBoothFormat = .passport
        model.capturedPhotos = photos(seed: 3)
        model.passportDraft = .photoPassDebugFixture
        model.state = .thankYou
        model.resetAfterDone()
        XCTAssertEqual(model.passportDraft, .empty)
        XCTAssertEqual(model.passportDraft.notes, "")
        XCTAssertTrue(model.passportDraft.signature.isEmpty)
        XCTAssertTrue(model.capturedPhotos.isEmpty)

        // Session B never sees session A's note.
        model.selectedBoothFormat = .passport
        model.passportDraft.name = "Guest B"
        let sessionB = model.passportDraft.committed(at: date)
        XCTAssertEqual(sessionB.notes, "")
        XCTAssertTrue(sessionB.signature.isEmpty)
        model.cancelSession()
    }

    // MARK: D. Event data

    func testEventProfileFillsDateEventAndLocation() throws {
        let eventDate = Date(timeIntervalSince1970: 1_791_000_000) // 2026-10-03 in Manila
        let profile = eventProfile(eventDate: eventDate)
        let content = try XCTUnwrap(try plan(eventProfile: profile).photoPassContent)
        XCTAssertEqual(content.event, "MADE TO KEEP LAUNCH")
        XCTAssertEqual(content.location, "CEBU CITY")
        XCTAssertEqual(content.date, PassportText.photoPassDate(eventDate))
        XCTAssertEqual(content.date, "OCT 3, 2026")
        XCTAssertEqual(content.name, "KARYNNE JACA")
        XCTAssertEqual(content.notes, "KEEP THIS LITTLE MOMENT.")

        // No configured event date: the session date is used.
        var noDate = profile
        noDate.includeEventDate = false
        XCTAssertEqual(try XCTUnwrap(try plan(eventProfile: noDate).photoPassContent).date, PassportText.photoPassDate(date))

        // Standard mode: session date, blank event and location.
        let standard = try XCTUnwrap(try plan(eventProfile: nil).photoPassContent)
        XCTAssertEqual(standard.date, "SEP 6, 2026", "Session date in Manila")
        XCTAssertEqual(standard.event, "")
        XCTAssertEqual(standard.location, "")

        var disabled = profile
        disabled.isEnabled = false
        XCTAssertEqual(try XCTUnwrap(try plan(eventProfile: disabled).photoPassContent).event, "")
    }

    // MARK: E. Rendering

    func testTemplateGeometryIsDeterministicAndInsideTheCards() throws {
        let plan = try plan(eventProfile: eventProfile())
        let layout = try XCTUnwrap(plan.photoPassLayout)
        let template = layout.template
        XCTAssertNil(plan.passportLayout, "Photo Pass never uses the legacy layout")
        XCTAssertEqual(plan.width, 576)
        XCTAssertEqual(template.upperCardRect.minY, 14)
        XCTAssertEqual(template, PhotoPassTemplateLayout.make(top: 14), "Geometry does not depend on content")
        XCTAssertEqual(template.heroPhotoRect.width * 3, template.heroPhotoRect.height * 4, "Hero opening is exactly 4:3")
        XCTAssertEqual(template.portraitPhotoRect.width * 4, template.portraitPhotoRect.height * 3, "Portrait opening is exactly 3:4")
        XCTAssertEqual(plan.photoFrames.first { $0.photoIndex == 0 }?.rect, template.portraitPhotoRect)
        XCTAssertEqual(plan.photoFrames.first { $0.photoIndex == 1 }?.rect, template.heroPhotoRect)
        XCTAssertEqual(plan.contentBottom, layout.bottom)
        XCTAssertGreaterThan(plan.height, plan.contentBottom + 200, "Shared QR footer follows the cards")
        XCTAssertEqual(template.fields.map(\.kind), PhotoPassTemplateLayout.FieldKind.allCases)
        assertValid(layout)

        for card in template.cards {
            let stars = PhotoPassTemplateLayout.borderStarCenters(for: card)
            XCTAssertGreaterThan(stars.count, 60)
            let metrics = PhotoPassTemplateLayout.Metrics.self
            let band = card.insetBy(dx: metrics.outerBorderWidth + metrics.borderStarRadius, dy: metrics.outerBorderWidth + metrics.borderStarRadius)
            let content = card.insetBy(dx: metrics.contentInset - metrics.borderStarRadius, dy: metrics.contentInset - metrics.borderStarRadius)
            for star in stars {
                XCTAssertTrue(band.contains(star), "Border stars never touch the outer border")
                XCTAssertFalse(content.contains(star), "Border stars stay out of the content area")
            }
            XCTAssertEqual(Set(stars.map { "\($0.x),\($0.y)" }).count, stars.count, "No doubled corner stars")
        }
    }

    func testLongValuesFitTheirFieldsWithoutOverlap() throws {
        var profile = eventProfile()
        profile.eventName = String(repeating: "W", count: EventProfile.eventNameLimit)
        profile.location = String(repeating: "W", count: EventProfile.locationLimit)
        let passport = PassportSessionData(
            name: String(repeating: "W", count: PassportSessionData.nameLimit),
            notes: String(repeating: "W", count: PassportSessionData.notesLimit),
            signature: .debugFixture
        )
        let realistic = PassportSessionData(
            name: "Maria Concepcion Villanueva-Santos",
            notes: "Thank you for the best night ever, see you at the next one!",
            signature: .debugFixture
        )
        var realisticProfile = eventProfile()
        realisticProfile.eventName = "Pocket Pixels Grand Anniversary Celebration 2026"
        realisticProfile.location = "Radisson Blu Hotel Grand Ballroom, Cebu City"

        for (passport, profile, isWorstCase) in [(passport, profile, true), (realistic, realisticProfile, false)] {
            let plan = try plan(eventProfile: profile, passport: passport)
            let layout = try XCTUnwrap(plan.photoPassLayout)
            assertValid(layout)
            if isWorstCase {
                // All-"W" strings at the limit: name and notes still fit; the half-width event and
                // location cells may tail-truncate, but never leave their cells.
                let allowed: Set<PassportTextBlock.Role> = [PhotoPassReceiptLayout.valueRole(.event), PhotoPassReceiptLayout.valueRole(.location)]
                XCTAssertTrue(Set(layout.truncatedRoles).isSubset(of: allowed), "\(layout.truncatedRoles)")
            } else {
                XCTAssertEqual(layout.truncatedRoles, [], "Realistic long values fit without truncation")
            }
            for kind in [PhotoPassTemplateLayout.FieldKind.name, .event, .location, .notes] {
                let block = try XCTUnwrap(layout.valueBlock(kind))
                XCTAssertTrue(layout.template.field(kind).valueRect.contains(block.rect), "\(kind)")
                XCTAssertGreaterThanOrEqual(block.font.size, 9, "\(kind) stays readable")
            }
            XCTAssertLessThanOrEqual(try XCTUnwrap(layout.valueBlock(.notes)).maximumLines, 3)
            let receipt = try ReceiptComposer.compose(photos: photos(seed: 9), sessionIdentifier: "PP-PHOTOPASS-LONG", date: date, galleryURL: galleryURL, format: .passport, eventProfile: profile, passport: passport)
            XCTAssertEqual(receipt.height, plan.height)
            XCTAssertLessThanOrEqual(receipt.height, BoothConfiguration.receiptMaximumHeight)
        }
    }

    func testSignatureInkStaysInsideTheSignatureBox() throws {
        let plan = try plan(eventProfile: nil)
        let layout = try XCTUnwrap(plan.photoPassLayout)
        // A signature that touches every edge of the pad.
        let edges = PassportSignature(strokes: [.init(coordinates: [0, 0, 1_000, 0, 1_000, 1_000, 0, 1_000, 0, 0])])
        let receipt = try ReceiptComposer.compose(photos: [solid(0.97), solid(0.97)], sessionIdentifier: "PP-SIG", date: date, format: .passport, passport: PassportSessionData(signature: edges))
        let image = try XCTUnwrap(UIImage(data: receipt.imagePNGData))
        let field = layout.template.field(.signature)
        let box = field.valueRect
        XCTAssertGreaterThan(try darkPixels(in: image, rect: layout.template.signatureRect), 100)
        // Between the box and the cell frame nothing is inked: strokes are clipped to the box.
        let line = PhotoPassTemplateLayout.Metrics.lineWidth
        let inside = field.cellRect.insetBy(dx: line, dy: line)
        XCTAssertEqual(try darkPixels(in: image, rect: CGRect(x: box.minX, y: box.maxY, width: box.width, height: inside.maxY - box.maxY)), 0)
        XCTAssertEqual(try darkPixels(in: image, rect: CGRect(x: box.minX, y: inside.minY, width: box.width, height: box.minY - inside.minY)), 0)
        XCTAssertEqual(try darkPixels(in: image, rect: CGRect(x: field.labelRect.maxX + 1, y: box.minY, width: box.minX - field.labelRect.maxX - 1, height: box.height)), 0)
    }

    func testPhotoOneFillsThePortraitAndPhotoTwoTheHero() throws {
        let layout = try XCTUnwrap(try plan(eventProfile: nil).photoPassLayout).template
        let receipt = try ReceiptComposer.compose(photos: [solid(0.05), solid(0.97)], sessionIdentifier: "PP-ROLES", date: date, format: .passport, passport: .empty)
        let image = try XCTUnwrap(UIImage(data: receipt.imagePNGData))
        XCTAssertLessThan(try luminance(in: image, at: CGPoint(x: layout.portraitPhotoRect.midX, y: layout.portraitPhotoRect.midY)), 0.3)
        XCTAssertGreaterThan(try luminance(in: image, at: CGPoint(x: layout.heroPhotoRect.midX, y: layout.heroPhotoRect.midY)), 0.8)
    }

    // MARK: F. Privacy

    func testGalleryCopyHasNoNameNotesOrSignature() throws {
        let passport = PassportSessionData(name: "Zebulon Quixote", notes: "Secret dragon note", signature: .debugFixture).committed(at: date)
        let committed = CommittedGallerySession(sessionIdentifier: "PP-PHOTOPASS-GALLERY", createdAt: date, galleryToken: token, galleryURL: galleryURL, photos: photos(seed: 4), format: .passport, eventProfile: eventProfile().activeReceiptSnapshot, passport: passport)
        let printed = try compose(committed)
        let printedImage = try XCTUnwrap(UIImage(data: printed.imagePNGData))
        let galleryImage = try BoothSessionViewModel.galleryReceiptImage(for: committed, printedReceiptImage: printedImage, photoQualityProfile: .customerPrintDefault)

        let redacted = passport.redactedForGallery()
        XCTAssertEqual(redacted.name, "")
        XCTAssertEqual(redacted.notes, "")
        XCTAssertTrue(redacted.signature.isEmpty)
        XCTAssertEqual(redacted.designVersion, .photoPassV2, "Gallery copy keeps the same design")

        let galleryPlan = try ReceiptComposer.makeLayoutPlan(format: .passport, eventProfile: committed.eventProfile, passport: redacted, date: date)
        let galleryLayout = try XCTUnwrap(galleryPlan.photoPassLayout)
        let galleryContent = try XCTUnwrap(galleryPlan.photoPassContent)
        XCTAssertEqual(galleryContent.name, "")
        XCTAssertEqual(galleryContent.notes, "")
        XCTAssertTrue(galleryContent.signature.isEmpty)
        XCTAssertEqual(galleryContent.event, "MADE TO KEEP LAUNCH", "Public event details stay")
        XCTAssertNil(galleryLayout.valueBlock(.name))
        XCTAssertNil(galleryLayout.valueBlock(.notes))
        XCTAssertEqual(Int(galleryImage.size.height), galleryPlan.height)

        let template = galleryLayout.template
        for rect in [template.nameRect, template.notesRect, template.signatureBoxRect] {
            XCTAssertGreaterThan(try darkPixels(in: printedImage, rect: rect), 20)
            XCTAssertEqual(try darkPixels(in: galleryImage, rect: rect), 0, "Customer field must be blank in the gallery copy")
        }
        XCTAssertGreaterThan(try darkPixels(in: galleryImage, rect: template.eventRect), 20)
        XCTAssertTrue(decodedQRMessages(in: galleryImage).contains(galleryURL.absoluteString))
        attach(galleryImage, name: "PhotoPass-gallery-redacted")
        writeArtifact(galleryImage, name: "photo-pass-gallery-redacted.png")

        let payload = try GoogleDriveGalleryUploadService.preparePayload(photos: committed.photos, composedReceipt: galleryImage, sessionID: committed.sessionIdentifier, createdAt: date, galleryToken: token, customerGalleryBaseURL: URL(string: "https://example.com/")!)
        let body = try JSONEncoder().encode(GoogleDriveGalleryUploadService.makeRequestBody(payload: payload, deviceToken: String(repeating: "x", count: 32)))
        let bodyObject = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertNil(bodyObject["receipt"], "Schema v2 must not duplicate the color receipt")
        XCTAssertNotNil(bodyObject["colorReceipt"])
        let json = try XCTUnwrap(String(data: body, encoding: .utf8))
        for secret in ["Zebulon", "Quixote", "dragon note", "notes", "signature"] {
            XCTAssertFalse(json.localizedCaseInsensitiveContains(secret), "Upload request must not contain \(secret)")
        }
    }

    // MARK: G. Legacy

    func testLegacyArchivedSessionStillRendersTheLegacyDesign() throws {
        let legacyJSON = #"{"name":"Sarah","birthday":{"month":4,"day":20},"nationality":"Brazilian","profession":"Model","birthplace":"","signature":{"strokes":[]},"configuration":{"theme":"classic","titleSource":"automatic","title":"POCKET PASSPORT","subtitle":"","eventLabel":""},"frozenAge":28}"#
        let archived = try JSONDecoder().decode(PassportSessionData.self, from: Data(legacyJSON.utf8))
        let plan = try ReceiptComposer.makeLayoutPlan(format: .passport, passport: archived, date: date)
        XCTAssertNotNil(plan.passportLayout)
        XCTAssertNil(plan.photoPassLayout)
        XCTAssertEqual(plan.passportContent?.name.value, "SARAH")
        XCTAssertEqual(plan.passportContent?.nationality.value, "BRAZILIAN")

        let legacyFixture = try ReceiptComposer.makeLayoutPlan(format: .passport, passport: .debugFixture, date: date)
        XCTAssertNotNil(legacyFixture.passportLayout)

        // Archived legacy sessions reprint identically and differently from Photo Pass.
        let first = try ReceiptComposer.compose(photos: photos(seed: 5), sessionIdentifier: "PP-LEGACY", date: date, galleryURL: galleryURL, format: .passport, passport: archived)
        let second = try ReceiptComposer.compose(photos: photos(seed: 5), sessionIdentifier: "PP-LEGACY", date: date, galleryURL: galleryURL, format: .passport, passport: try JSONDecoder().decode(PassportSessionData.self, from: JSONEncoder().encode(archived)))
        XCTAssertEqual(first.imagePNGData, second.imagePNGData)
        var asPhotoPass = archived
        asPhotoPass.designVersion = .photoPassV2
        let photoPass = try ReceiptComposer.compose(photos: photos(seed: 5), sessionIdentifier: "PP-LEGACY", date: date, galleryURL: galleryURL, format: .passport, passport: asPhotoPass)
        XCTAssertNotEqual(first.imagePNGData, photoPass.imagePNGData)
    }

    func testArchiveRoundTripKeepsPhotoPassAndReprintIsIdentical() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try RecentSessionArchiveStore(directoryURL: directory)
        let passport = PassportSessionData.photoPassDebugFixture.committed(at: date)
        let committed = CommittedGallerySession(sessionIdentifier: "PP-PHOTOPASS-ARCHIVE", createdAt: date, galleryToken: token, galleryURL: galleryURL, photos: photos(seed: 6), format: .passport, eventProfile: eventProfile().activeReceiptSnapshot, passport: passport)
        let receipt = try compose(committed)
        let raster = try ThermalImageRasterizer.rasterize(XCTUnwrap(UIImage(data: receipt.imagePNGData)), purpose: .completeReceipt)
        try store.save(RecentSessionArchivePayload(committedSession: committed, composedReceipt: receipt, receiptPreviewPNGData: receipt.imagePNGData, thermalPreviewPNGData: raster.previewPNGData, rasterizedImage: raster, photoThumbnailData: [Data([1]), Data([2])]))

        let loaded = try RecentSessionArchiveStore(directoryURL: directory).load(archiveID: token)
        XCTAssertEqual(loaded.passport, passport)
        XCTAssertEqual(loaded.passport?.designVersion, .photoPassV2)
        XCTAssertEqual(loaded.passport?.notes, "Keep this little moment.")
        XCTAssertEqual(loaded.rasterizedImage.rasterCommand, raster.rasterCommand)
        let recomposed = try ReceiptComposer.compose(photos: committed.photos, sessionIdentifier: committed.sessionIdentifier, date: date, galleryURL: galleryURL, format: .passport, eventProfile: committed.eventProfile, passport: loaded.passport)
        XCTAssertEqual(recomposed.imagePNGData, receipt.imagePNGData)
    }

    // MARK: H. Thermal and visual artifacts

    func testThermalRasterQRAndDebugArtifacts() throws {
        let profile = eventProfile()
        let passport = PassportSessionData.photoPassDebugFixture
        let receipt = try ReceiptComposer.compose(photos: [photo(seed: 1, landscape: false), photo(seed: 2, landscape: true)], sessionIdentifier: "PP-20261007-172800", date: date, galleryURL: galleryURL, format: .passport, eventProfile: profile, passport: passport)
        let image = try XCTUnwrap(UIImage(data: receipt.imagePNGData))
        let first = try ThermalImageRasterizer.rasterize(image, purpose: .completeReceipt)
        let second = try ThermalImageRasterizer.rasterize(image, purpose: .completeReceipt)
        XCTAssertEqual(first.rasterData, second.rasterData)
        XCTAssertEqual(first.width, 576)
        XCTAssertEqual(first.height, receipt.height)
        XCTAssertGreaterThan(first.height, 0)
        XCTAssertLessThanOrEqual(first.height, BoothConfiguration.receiptMaximumHeight)
        XCTAssertTrue(first.sanitizationReport.finalSafetyScanPassed)
        try ThermalImageRasterizer.validateRasterCommand(first.rasterCommand, imageWidth: first.width, imageHeight: first.height, bytesPerRow: first.widthBytes, rasterDataCount: first.rasterData.count)
        let thermal = try XCTUnwrap(UIImage(data: first.previewPNGData))
        for preview in [image, thermal] {
            XCTAssertTrue(decodedQRMessages(in: preview).contains(galleryURL.absoluteString))
        }

        // The border stars and wordmarks survive the 1-bit conversion.
        let layout = try XCTUnwrap(try plan(eventProfile: profile, passport: passport).photoPassLayout)
        for center in PhotoPassTemplateLayout.borderStarCenters(for: layout.template.upperCardRect).prefix(12) {
            XCTAssertGreaterThan(try darkPixels(in: thermal, rect: CGRect(x: center.x - 3, y: center.y - 3, width: 6, height: 6)), 12, "Border star at \(center) survives")
        }
        XCTAssertGreaterThan(try darkPixels(in: thermal, rect: layout.template.heroBrandingRect), 600)
        XCTAssertGreaterThan(try darkPixels(in: thermal, rect: layout.template.portraitBrandingRect), 150)

        print("PHOTO_PASS_DIMENSIONS \(receipt.width)x\(receipt.height) mm=\(String(format: "%.2f", Double(receipt.height) / 8))")
        attach(image, name: "PhotoPass-full")
        attach(thermal, name: "PhotoPass-thermal-1bit")
        writeArtifact(image, name: "photo-pass-full.png")
        writeArtifact(thermal, name: "photo-pass-thermal-1bit.png")

        let standard = try ReceiptComposer.compose(photos: [photo(seed: 3, landscape: false), photo(seed: 4, landscape: false)], sessionIdentifier: "PP-20261007-172801", date: date, galleryURL: galleryURL, format: .passport, passport: .empty)
        let standardImage = try XCTUnwrap(UIImage(data: standard.imagePNGData))
        writeArtifact(standardImage, name: "photo-pass-standard-blank.png")
        writeArtifact(try XCTUnwrap(UIImage(data: ThermalImageRasterizer.rasterize(standardImage, purpose: .completeReceipt).previewPNGData)), name: "photo-pass-standard-blank-thermal-1bit.png")
    }

    // MARK: - Helpers

    private var galleryURL: URL { URL(string: "https://example.com/?g=\(token)")! }

    private func eventProfile(eventDate: Date? = nil) -> EventProfile {
        EventProfile(isEnabled: true, eventName: "Made to Keep Launch", subtitle: "", includeEventDate: true, eventDate: eventDate ?? date, location: "Cebu City", shortMessage: "")
    }

    private func plan(eventProfile: EventProfile?, passport: PassportSessionData = .photoPassDebugFixture) throws -> ReceiptLayoutPlan {
        try ReceiptComposer.makeLayoutPlan(format: .passport, eventProfile: eventProfile, passport: passport, date: date)
    }

    private func compose(_ session: CommittedGallerySession) throws -> ComposedReceipt {
        try ReceiptComposer.compose(photos: session.photos, sessionIdentifier: session.sessionIdentifier, date: session.createdAt, galleryURL: session.galleryURL, format: session.format, eventProfile: session.eventProfile, passport: session.passport)
    }

    private func assertValid(_ layout: PhotoPassReceiptLayout, file: StaticString = #filePath, line: UInt = #line) {
        let template = layout.template
        XCTAssertFalse(template.upperCardRect.intersects(template.lowerCardRect), file: file, line: line)
        XCTAssertTrue(template.upperCardRect.contains(template.heroPhotoRect), file: file, line: line)
        XCTAssertTrue(template.lowerCardRect.contains(template.portraitPhotoRect), file: file, line: line)
        for card in template.cards {
            XCTAssertGreaterThanOrEqual(card.minX, CGFloat(BoothConfiguration.receiptHorizontalMargin), file: file, line: line)
            XCTAssertLessThanOrEqual(card.maxX, CGFloat(576 - BoothConfiguration.receiptHorizontalMargin), file: file, line: line)
        }
        for (index, field) in template.fields.enumerated() {
            XCTAssertTrue(template.lowerCardRect.contains(field.valueRect), "\(field.kind)", file: file, line: line)
            XCTAssertFalse(field.valueRect.intersects(field.labelRect), "\(field.kind)", file: file, line: line)
            for other in template.fields.dropFirst(index + 1) {
                XCTAssertFalse(field.valueRect.intersects(other.valueRect), "\(field.kind) overlaps \(other.kind)", file: file, line: line)
                XCTAssertFalse(field.labelRect.intersects(other.labelRect), file: file, line: line)
            }
        }
        for block in layout.valueTexts {
            let field = template.fields.first { PhotoPassReceiptLayout.valueRole($0.kind) == block.role }
            XCTAssertTrue(field?.valueRect.contains(block.rect) ?? false, "\(block.role)", file: file, line: line)
        }
        for field in template.fields {
            XCTAssertTrue(field.cellRect.contains(field.labelRect), "\(field.kind) label", file: file, line: line)
            XCTAssertTrue(template.gridRect.contains(field.cellRect), "\(field.kind) cell", file: file, line: line)
        }
        for wordmark in layout.wordmarks {
            XCTAssertFalse(wordmark.isTruncated, file: file, line: line)
            XCTAssertFalse(wordmark.rect.intersects(template.heroPhotoRect), file: file, line: line)
            XCTAssertFalse(wordmark.rect.intersects(template.portraitPhotoRect), file: file, line: line)
            XCTAssertFalse(wordmark.rect.intersects(template.gridRect), file: file, line: line)
        }
        for block in layout.allTexts {
            XCTAssertFalse(block.rect.intersects(template.heroPhotoRect), "\(block.role)", file: file, line: line)
            XCTAssertFalse(block.rect.intersects(template.portraitPhotoRect), "\(block.role)", file: file, line: line)
        }
        XCTAssertTrue(template.signatureBoxRect.contains(template.signatureRect), file: file, line: line)
    }

    private func photos(seed: Int) -> [UIImage] {
        [photo(seed: seed, landscape: false), photo(seed: seed + 1, landscape: false)]
    }

    /// Synthetic "person" so face clarity can be judged in the debug renders.
    private func photo(seed: Int, landscape: Bool) -> UIImage {
        let size = landscape ? CGSize(width: 800, height: 600) : CGSize(width: 600, height: 800)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cg = context.cgContext
            let colors = [UIColor(hue: CGFloat(seed % 7) / 7, saturation: 0.35, brightness: 0.95, alpha: 1).cgColor, UIColor(white: 0.55, alpha: 1).cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                cg.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
            }
            let faceWidth = min(size.width, size.height) * 0.36
            let face = CGRect(x: size.width / 2 - faceWidth / 2, y: size.height * 0.2, width: faceWidth, height: faceWidth * 1.25)
            UIColor(white: 0.25, alpha: 1).setFill()
            cg.fillEllipse(in: CGRect(x: size.width / 2 - faceWidth * 1.1, y: face.maxY - faceWidth * 0.05, width: faceWidth * 2.2, height: faceWidth * 1.6))
            UIColor(white: 0.12, alpha: 1).setFill()
            cg.fillEllipse(in: face.insetBy(dx: -faceWidth * 0.08, dy: -faceWidth * 0.06).offsetBy(dx: 0, dy: -faceWidth * 0.08))
            UIColor(red: 0.93, green: 0.80, blue: 0.70, alpha: 1).setFill()
            cg.fillEllipse(in: face)
            UIColor(white: 0.1, alpha: 1).setFill()
            for dx in [-0.2, 0.2] {
                cg.fillEllipse(in: CGRect(x: face.midX + faceWidth * dx - faceWidth * 0.06, y: face.minY + face.height * 0.4, width: faceWidth * 0.12, height: faceWidth * 0.1))
            }
            cg.setStrokeColor(UIColor(red: 0.5, green: 0.15, blue: 0.15, alpha: 1).cgColor)
            cg.setLineWidth(faceWidth * 0.04)
            cg.addArc(center: CGPoint(x: face.midX, y: face.minY + face.height * 0.6), radius: faceWidth * 0.18, startAngle: 0.3, endAngle: .pi - 0.3, clockwise: false)
            cg.strokePath()
        }
    }

    private func solid(_ white: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: 300, height: 400), format: format).image { context in
            UIColor(white: white, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 300, height: 400))
        }
    }

    private func rgba(_ image: UIImage) throws -> (pixels: [UInt8], width: Int, height: Int) {
        let cgImage = try XCTUnwrap(image.cgImage)
        var pixels = [UInt8](repeating: 0, count: cgImage.width * cgImage.height * 4)
        let context = try XCTUnwrap(CGContext(data: &pixels, width: cgImage.width, height: cgImage.height, bitsPerComponent: 8, bytesPerRow: cgImage.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        return (pixels, cgImage.width, cgImage.height)
    }

    private func luminance(in image: UIImage, at point: CGPoint) throws -> Double {
        let data = try rgba(image)
        let offset = (Int(point.y) * data.width + Int(point.x)) * 4
        return (0.2126 * Double(data.pixels[offset]) + 0.7152 * Double(data.pixels[offset + 1]) + 0.0722 * Double(data.pixels[offset + 2])) / 255
    }

    private func darkPixels(in image: UIImage, rect: CGRect) throws -> Int {
        let data = try rgba(image)
        var count = 0
        for y in max(0, Int(rect.minY))..<min(data.height, Int(rect.maxY)) {
            for x in max(0, Int(rect.minX))..<min(data.width, Int(rect.maxX)) {
                let offset = (y * data.width + x) * 4
                if Int(data.pixels[offset]) + Int(data.pixels[offset + 1]) + Int(data.pixels[offset + 2]) < 300 {
                    count += 1
                }
            }
        }
        return count
    }

    private func decodedQRMessages(in image: UIImage) -> [String] {
        guard let cgImage = image.cgImage,
              let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]) else {
            return []
        }
        return detector.features(in: CIImage(cgImage: cgImage)).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
    }

    private func attach(_ image: UIImage, name: String) {
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Same opt-in hook as PassportFormatTests: set PASSPORT_ARTIFACT_DIR for the test run.
    private func writeArtifact(_ image: UIImage, name: String) {
        guard let directory = ProcessInfo.processInfo.environment["PASSPORT_ARTIFACT_DIR"], !directory.isEmpty else { return }
        let url = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try? image.pngData()?.write(to: url.appendingPathComponent(name))
    }
}
