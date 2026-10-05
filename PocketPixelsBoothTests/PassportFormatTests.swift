import CoreImage
import Foundation
import SwiftUI
import UIKit
import XCTest
@testable import PocketPixelsBooth

@MainActor
final class PassportFormatTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_788_692_040)
    private let token = String(repeating: "c", count: 64)

    // MARK: A. Format identity

    func testPassportFormatIdentityAndCodableValue() throws {
        XCTAssertEqual(BoothFormat.passport.photoCount, 2)
        XCTAssertEqual(BoothFormat.passport.displayName, "Passport")
        XCTAssertEqual(BoothFormat.passport.shortDescription, "Two-photo passport keepsake")
        XCTAssertEqual(BoothFormat.passport.photoCountLabel, "2 photos")
        XCTAssertEqual(BoothFormat.passport.reviewSummary, "PASSPORT · 2 PHOTOS")
        XCTAssertTrue(BoothFormat.passport.usesPassportFlow)
        XCTAssertEqual(BoothFormat.allCases.filter(\.usesPassportFlow), [.passport])
        XCTAssertEqual(BoothFormat.allCases.last, .passport)
        XCTAssertEqual(BoothConfiguration.maximumPhotosPerSession, 6)
        XCTAssertEqual(try JSONDecoder().decode(BoothFormat.self, from: Data("\"passport\"".utf8)), .passport)
        XCTAssertEqual(String(data: try JSONEncoder().encode(BoothFormat.passport), encoding: .utf8), "\"passport\"")
    }

    // MARK: B. Capture flow

    func testPassportRequiresExactlyTwoPhotosAndFollowsDetailsSignaturePreviewFlow() throws {
        let model = BoothSessionViewModel()
        model.selectedBoothFormat = .passport
        model.isCameraUnavailable = true
        model.state = .cameraReady

        let landscapeSource = syntheticPhoto(width: 400, height: 300, seed: 1)
        model.addSamplePhoto(landscapeSource)
        XCTAssertEqual(model.state, .cameraReady)
        XCTAssertFalse(model.canContinueFromReview)
        model.addSamplePhoto(syntheticPhoto(width: 300, height: 400, seed: 2))
        XCTAssertEqual(model.state, .review)
        model.addSamplePhoto(syntheticPhoto(width: 300, height: 400, seed: 3))
        XCTAssertEqual(model.capturedPhotos.count, 2, "A third photo must be rejected")

        // Passport keeps the full frame; the card crops are applied during composition.
        XCTAssertEqual(model.capturedPhotos[0].size, CGSize(width: 400, height: 300))

        XCTAssertTrue(model.canContinueFromReview)
        XCTAssertFalse(model.canContinueToReceipt, "Passport cannot commit straight from review")
        model.continueToReceipt()
        XCTAssertEqual(model.state, .passportDetails, "Composing from review is redirected to details")

        model.passportDraft.name = "Sarah Aragão"
        model.continueFromPassportDetails()
        XCTAssertEqual(model.state, .passportSignature)

        let stroke = try XCTUnwrap(PassportSignature.stroke(from: [CGPoint(x: 10, y: 10), CGPoint(x: 80, y: 20)], canvasSize: CGSize(width: 400, height: 100)))
        model.updatePassportSignature(PassportSignature.empty.appending(stroke))
        XCTAssertFalse(model.passportDraft.signature.isEmpty)

        model.continueFromPassportSignature()
        XCTAssertEqual(model.state, .passportPreview)
        XCTAssertTrue(model.canContinueToReceipt)

        model.backToPassportDetails()
        XCTAssertEqual(model.state, .passportDetails)
        XCTAssertEqual(model.passportDraft.name, "Sarah Aragão", "Going back must not lose details")

        model.redoPassportSignature()
        XCTAssertEqual(model.state, .passportSignature)
        XCTAssertTrue(model.passportDraft.signature.isEmpty)
        XCTAssertEqual(model.passportDraft.name, "Sarah Aragão")

        model.backToReview()
        XCTAssertEqual(model.state, .review)
        XCTAssertEqual(model.capturedPhotos.count, 2)
        model.cancelSession()
    }

    func testRetakeTargetsOnlyTheRequestedPassportPhoto() {
        let model = BoothSessionViewModel()
        model.selectedBoothFormat = .passport
        let first = syntheticPhoto(width: 300, height: 400, seed: 11)
        let second = syntheticPhoto(width: 300, height: 400, seed: 12)
        model.capturedPhotos = [first, second]
        model.passportDraft.name = "Keep Me"
        model.state = .review
        model.retakePhoto(at: 1)
        // The simulator has no camera permission, so the retake may stop at an error state;
        // either way the other photo and the Passport details must be untouched.
        XCTAssertEqual(model.capturedPhotos.count, 2)
        XCTAssertTrue(model.capturedPhotos[0] === first, "Retaking Photo 2 must not touch Photo 1")
        XCTAssertEqual(model.passportDraft.name, "Keep Me")
        model.cancelSession()
    }

    // MARK: C. Session data

    func testPassportSessionDataCodableRoundTripAndOptionalFields() throws {
        let full = PassportSessionData.debugFixture
        XCTAssertEqual(try roundTrip(full), full)

        let empty = PassportSessionData.empty
        XCTAssertEqual(try roundTrip(empty), empty)
        XCTAssertFalse(empty.hasAnyDetails)
        XCTAssertNil(empty.birthday)

        // Older or partial payloads decode with safe defaults.
        let partial = try JSONDecoder().decode(PassportSessionData.self, from: Data(#"{"name":"Ana"}"#.utf8))
        XCTAssertEqual(partial.name, "Ana")
        XCTAssertEqual(partial.configuration, .default)
        XCTAssertTrue(partial.signature.isEmpty)

        let legacyProfile = try JSONDecoder().decode(EventProfile.self, from: JSONEncoder().encode(EventProfile.pocketPixelsDefault))
        XCTAssertEqual(legacyProfile.passport, .default)
    }

    func testTextLimitsWhitespaceAndUnicodeNormalization() {
        var data = PassportSessionData(
            name: "  Sarah \n\t Aragão\u{0007}  " + String(repeating: "x", count: 80),
            nationality: String(repeating: "N", count: 60),
            profession: "👩‍🚀 Astronaut",
            birthplace: String(repeating: "B", count: 60)
        )
        data = data.normalized(referenceDate: date)
        XCTAssertTrue(data.name.hasPrefix("Sarah Aragão x"))
        XCTAssertEqual(data.name.count, PassportSessionData.nameLimit)
        XCTAssertFalse(data.name.contains("\u{0007}"))
        XCTAssertEqual(data.nationality.count, PassportSessionData.nationalityLimit)
        XCTAssertEqual(data.birthplace.count, PassportSessionData.birthplaceLimit)
        XCTAssertEqual(data.profession, "👩‍🚀 Astronaut", "Emoji ZWJ sequences must survive normalization")

        let limited = PassportText.limitedInput("👨‍👩‍👧‍👦" + String(repeating: "a", count: 40), limit: 5)
        XCTAssertEqual(limited.count, 5)
        XCTAssertTrue(limited.hasPrefix("👨‍👩‍👧‍👦"))

        var config = PassportConfiguration(title: "   ", subtitle: String(repeating: "S", count: 90), eventLabel: String(repeating: "L", count: 90))
        config = config.normalized()
        XCTAssertEqual(config.title, PassportConfiguration.defaultTitle)
        XCTAssertEqual(config.subtitle.count, PassportConfiguration.subtitleLimit)
        XCTAssertEqual(config.eventLabel.count, PassportConfiguration.eventLabelLimit)
    }

    func testBirthdayValidationAgeAndCommitDropsYear() {
        XCTAssertEqual(PassportBirthday(month: 2, day: 31).normalized(referenceDate: date)?.day, 29)
        XCTAssertEqual(PassportBirthday(month: 2, day: 29, year: 2023).normalized(referenceDate: date)?.day, 28)
        XCTAssertNil(PassportBirthday(month: 13, day: 1).normalized(referenceDate: date))
        XCTAssertNil(PassportBirthday(month: 1, day: 1, year: 3000).normalized(referenceDate: date)?.year)
        XCTAssertEqual(PassportBirthday(month: 4, day: 20).displayText, "APR 20")

        // Reference date is 2026-09-06 18:54 in Manila.
        XCTAssertEqual(PassportBirthday(month: 4, day: 20, year: 1998).age(on: date), 28)
        XCTAssertEqual(PassportBirthday(month: 12, day: 25, year: 1998).age(on: date), 27)
        XCTAssertNil(PassportBirthday(month: 4, day: 20).age(on: date))

        let committed = PassportSessionData.debugFixture.committed(at: date)
        XCTAssertNil(committed.birthday?.year, "Birth year is not retained after commit")
        XCTAssertEqual(committed.birthday?.displayText, "APR 20")
        XCTAssertEqual(committed.frozenAge, 28)
        XCTAssertEqual(committed.displayAge(referenceDate: date.addingTimeInterval(400 * 24 * 3600)), 28, "Age is frozen")
    }

    // MARK: D. Signature

    func testSignatureIsResolutionIndependentAndRoundTrips() throws {
        let points = [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 25), CGPoint(x: 400, y: 100)]
        let small = try XCTUnwrap(PassportSignature.stroke(from: points, canvasSize: CGSize(width: 400, height: 100)))
        let scaled = try XCTUnwrap(PassportSignature.stroke(from: points.map { CGPoint(x: $0.x * 2.5, y: $0.y * 2.5) }, canvasSize: CGSize(width: 1_000, height: 250)))
        XCTAssertEqual(small, scaled, "Same gesture on different screen sizes must store identical data")
        XCTAssertEqual(small.coordinates, [0, 0, 250, 250, 1_000, 1_000])

        let signature = PassportSignature.empty.appending(small)
        XCTAssertEqual(try roundTrip(signature), signature)
        XCTAssertEqual(try roundTrip(PassportSignature.debugFixture), PassportSignature.debugFixture)
        XCTAssertTrue(PassportSignature.empty.isEmpty)
        XCTAssertTrue(try roundTrip(PassportSignature.empty).isEmpty)
        XCTAssertTrue(signature.removingLastStroke().isEmpty)

        // Points outside the pad are clamped; oversized input is bounded.
        let clamped = try XCTUnwrap(PassportSignature.stroke(from: [CGPoint(x: -50, y: 900)], canvasSize: CGSize(width: 400, height: 100)))
        XCTAssertEqual(clamped.coordinates, [0, 1_000])
        let huge = PassportSignature(strokes: Array(repeating: PassportSignature.Stroke(coordinates: Array(repeating: 500, count: 2_000)), count: 200)).normalized()
        XCTAssertLessThanOrEqual(huge.strokes.count, PassportSignature.maximumStrokes)
        XCTAssertLessThanOrEqual(huge.totalPointCount, PassportSignature.maximumTotalPoints)
        XCTAssertTrue(huge.strokes.allSatisfy { $0.pointCount <= PassportSignature.maximumPointsPerStroke })

        let fitted = PassportSignature.fittedRect(in: CGRect(x: 0, y: 0, width: 400, height: 50), alignment: 0)
        XCTAssertEqual(fitted, CGRect(x: 0, y: 0, width: 200, height: 50))
    }

    // MARK: E/F. Reset and isolation

    func testCustomerResetClearsAllPassportData() {
        for reset in [false, true] {
            let model = BoothSessionViewModel()
            model.selectedBoothFormat = .passport
            model.capturedPhotos = passportPhotos(seed: 20)
            model.passportDraft = .debugFixture
            model.state = reset ? .thankYou : .passportPreview
            if reset {
                model.resetAfterDone()
            } else {
                model.cancelSession()
            }
            XCTAssertEqual(model.state, .welcome)
            XCTAssertEqual(model.passportDraft, .empty)
            XCTAssertTrue(model.passportDraft.signature.isEmpty)
            XCTAssertNil(model.passportPreviewImage)
            XCTAssertFalse(model.passportPreviewFailed)
            XCTAssertTrue(model.capturedPhotos.isEmpty)
            XCTAssertNil(model.selectedBoothFormat)
            XCTAssertNil(model.galleryToken)
        }
    }

    func testPassportDataFromSessionACannotAppearInSessionB() throws {
        let model = BoothSessionViewModel()
        model.selectedBoothFormat = .passport
        model.passportDraft = .debugFixture
        let committedA = committedSession(id: "PP-PASSPORT-A", token: String(repeating: "a", count: 64), passport: model.passportDraft.committed(at: date))
        model.state = .thankYou
        model.resetAfterDone()

        model.selectedBoothFormat = .passport
        XCTAssertEqual(model.passportDraft, .empty, "Session B starts with no Passport details")
        model.passportDraft.name = "Guest B"
        let committedB = committedSession(id: "PP-PASSPORT-B", token: String(repeating: "b", count: 64), passport: model.passportDraft.committed(at: date))

        XCTAssertEqual(committedA.passport?.name, "Sarah Aragão")
        XCTAssertEqual(committedB.passport?.name, "Guest B")
        XCTAssertTrue(committedB.passport?.signature.isEmpty ?? false)
        XCTAssertNil(committedB.passport?.frozenAge)

        let receiptA = try compose(committedA)
        let receiptB = try compose(committedB)
        XCTAssertNotEqual(receiptA.imagePNGData, receiptB.imagePNGData)
        model.cancelSession()
    }

    // MARK: G/H/I/K. Layout

    func testPassportLayoutHasTwoLandscapeCardsAboveFooterInsideCanvas() throws {
        let plan = try ReceiptComposer.makeLayoutPlan(format: .passport, passport: .debugFixture, date: date)
        let layout = try XCTUnwrap(plan.passportLayout)
        try assertValidPassportPlan(plan)

        XCTAssertEqual(plan.width, 576)
        XCTAssertEqual(layout.upperCard.minY, 14, "Nothing is stacked above the Passport cards")
        XCTAssertGreaterThan(layout.upperCard.width, layout.upperCard.height)
        XCTAssertGreaterThan(layout.lowerCard.width, layout.lowerCard.height)
        XCTAssertLessThanOrEqual(layout.upperCard.maxY, layout.lowerCard.minY)
        XCTAssertFalse(layout.upperCard.intersects(layout.lowerCard))
        XCTAssertEqual(plan.contentBottom, layout.bottom)
        XCTAssertGreaterThan(plan.height, plan.contentBottom + 200, "Shared QR footer follows the cards")
        XCTAssertEqual(plan.previewContentHeight, plan.contentBottom + 12)
        XCTAssertEqual(plan.qrSize, ReceiptComposer.receiptQRCodeSize)
    }

    func testMaximumLengthFieldsFitWithoutOverflowForEveryTheme() throws {
        for theme in PassportTheme.allCases {
            let passport = maximumPassport(theme: theme)
            let plan = try ReceiptComposer.makeLayoutPlan(format: .passport, passport: passport, date: date)
            try assertValidPassportPlan(plan)
            let layout = try XCTUnwrap(plan.passportLayout)
            let truncatedFields = layout.truncatedRoles.filter {
                if case .fieldValue = $0 { return true }
                return false
            }
            XCTAssertEqual(truncatedFields, [], "\(theme) truncated a maximum-length field")
            XCTAssertTrue(layout.allTexts.contains { $0.role == .fieldValue("BIRTHPLACE") })
            XCTAssertTrue(layout.allTexts.contains { $0.role == .fieldValue("AGE") })
            let receipt = try ReceiptComposer.compose(photos: passportPhotos(seed: 30), sessionIdentifier: "PP-MAX-\(theme.rawValue)", date: date, galleryURL: galleryURL, format: .passport, passport: passport)
            XCTAssertEqual(receipt.height, plan.height)
            XCTAssertLessThanOrEqual(receipt.height, BoothConfiguration.receiptMaximumHeight)
        }
    }

    func testMissingOptionalFieldsStillProduceCompleteCards() throws {
        let plan = try ReceiptComposer.makeLayoutPlan(format: .passport, passport: .empty, date: date)
        try assertValidPassportPlan(plan)
        let layout = try XCTUnwrap(plan.passportLayout)
        XCTAssertEqual(layout.underlines.count, 5, "Name, birthday, nationality, profession and signature lines stay visible")
        XCTAssertFalse(layout.allTexts.contains { $0.role == .fieldValue("AGE") })
        XCTAssertFalse(layout.allTexts.contains { $0.role == .fieldValue("BIRTHPLACE") })
        XCTAssertTrue(layout.allTexts.contains { $0.role == .title && $0.text == "POCKET PASSPORT" })
        XCTAssertEqual(layout.truncatedRoles, [])
        let receipt = try ReceiptComposer.compose(photos: passportPhotos(seed: 31), sessionIdentifier: "PP-EMPTY", date: date, format: .passport, passport: .empty)
        XCTAssertEqual(receipt.height, try ReceiptComposer.makeLayoutPlan(format: .passport, includesGalleryQRCode: false, passport: .empty, date: date).height)
    }

    func testEveryThemeProducesValidDistinctLayouts() throws {
        var images: [PassportTheme: Data] = [:]
        for theme in PassportTheme.allCases {
            var passport = PassportSessionData.debugFixture
            passport.configuration.theme = theme
            let plan = try ReceiptComposer.makeLayoutPlan(format: .passport, passport: passport, date: date)
            try assertValidPassportPlan(plan)
            let layout = try XCTUnwrap(plan.passportLayout)
            switch theme {
            case .classic, .event:
                XCTAssertNotNil(layout.stampRect)
            case .stars:
                XCTAssertNotNil(layout.starBandRect)
            case .minimal:
                XCTAssertNil(layout.stampRect)
                XCTAssertNil(layout.starBandRect)
            }
            let receipt = try ReceiptComposer.compose(photos: passportPhotos(seed: 32), sessionIdentifier: "PP-THEME", date: date, galleryURL: galleryURL, format: .passport, passport: passport)
            images[theme] = receipt.imagePNGData
        }
        XCTAssertEqual(Set(images.values).count, PassportTheme.allCases.count, "Themes must render visibly differently")
    }

    // MARK: J. Defaults

    func testDefaultThemeAndConfigurationAreDeterministic() throws {
        XCTAssertEqual(PassportConfiguration.default.theme, .classic)
        XCTAssertEqual(PassportConfiguration.default.titleSource, .automatic)
        XCTAssertEqual(PassportConfiguration.default.title, "POCKET PASSPORT")
        XCTAssertEqual(PassportConfiguration.effective(for: nil), .default)

        var disabledEvent = eventProfile()
        disabledEvent.isEnabled = false
        disabledEvent.passport.theme = .stars
        XCTAssertEqual(PassportConfiguration.effective(for: disabledEvent), .default, "Standard mode ignores event Passport settings")
        var enabledEvent = eventProfile()
        enabledEvent.passport.theme = .stars
        XCTAssertEqual(PassportConfiguration.effective(for: enabledEvent).theme, .stars)

        let first = try ReceiptComposer.compose(photos: passportPhotos(seed: 40), sessionIdentifier: "PP-DEFAULT", date: date, galleryURL: galleryURL, format: .passport)
        let second = try ReceiptComposer.compose(photos: passportPhotos(seed: 40), sessionIdentifier: "PP-DEFAULT", date: date, galleryURL: galleryURL, format: .passport)
        XCTAssertEqual(first.imagePNGData, second.imagePNGData)
    }

    // MARK: L. Event Mode

    func testEventModeTitleIntegrationWithoutStackedHeaders() throws {
        let profile = eventProfile()
        let content = try passportContent(eventProfile: profile)
        XCTAssertEqual(content.titleMode, .eventText)
        XCTAssertEqual(content.title, "ANNA & MARK")
        XCTAssertEqual(content.label, "WEDDING PASSPORT")
        XCTAssertEqual(content.subtitle, "OUR WEDDING DAY")
        XCTAssertTrue(content.metadata.contains("CEBU CITY"))
        XCTAssertEqual(content.message, "THANK YOU FOR CELEBRATING")

        let plan = try ReceiptComposer.makeLayoutPlan(format: .passport, eventProfile: profile, passport: .debugFixture, date: date)
        try assertValidPassportPlan(plan)
        let layout = try XCTUnwrap(plan.passportLayout)
        XCTAssertEqual(layout.upperCard.minY, 14, "Event text is integrated, not stacked above the cards")
        XCTAssertNotNil(layout.message)
        XCTAssertTrue(plan.showsEventTextBlock)

        var pocketPixelsBranding = profile
        pocketPixelsBranding.passport.titleSource = .pocketPixels
        pocketPixelsBranding.passport.title = "Memory Pass"
        let branded = try passportContent(eventProfile: pocketPixelsBranding)
        XCTAssertEqual(branded.titleMode, .pocketPixels)
        XCTAssertEqual(branded.title, "MEMORY PASS")

        var hiddenText = profile
        hiddenText.showEventTextBlock = false
        XCTAssertEqual(try passportContent(eventProfile: hiddenText).titleMode, .pocketPixels)
        XCTAssertEqual(try passportContent(eventProfile: hiddenText).message, "")

        var explicitEvent = hiddenText
        explicitEvent.passport.titleSource = .eventText
        XCTAssertEqual(try passportContent(eventProfile: explicitEvent).titleMode, .eventText)

        var disabled = profile
        disabled.isEnabled = false
        XCTAssertEqual(try passportContent(eventProfile: disabled).titleMode, .pocketPixels)
    }

    func testCustomHeaderGraphicAndEventTextCombinations() throws {
        let headerImage = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 200)).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 600, height: 200))
            UIColor.black.setFill()
            context.fill(CGRect(x: 40, y: 40, width: 520, height: 120))
        }
        let identifier = try EventHeaderAssetStore().importImageData(XCTUnwrap(headerImage.pngData()))
        for mode in [ReceiptHeaderMode.pocketPixelsDefault, .none, .customEventHeader] {
            for shown in [false, true] {
                for source in PassportTitleSource.allCases {
                    for qr in [false, true] {
                        var profile = eventProfile()
                        profile.receiptHeader.mode = mode
                        profile.receiptHeader.assetIdentifier = identifier
                        profile.showEventTextBlock = shown
                        profile.passport.titleSource = source
                        var passport = PassportSessionData.debugFixture
                        passport.configuration = PassportConfiguration.effective(for: profile)
                        let plan = try ReceiptComposer.makeLayoutPlan(format: .passport, includesGalleryQRCode: qr, eventProfile: profile, passport: passport, date: date)
                        try assertValidPassportPlan(plan)
                        let layout = try XCTUnwrap(plan.passportLayout)
                        let content = try XCTUnwrap(plan.passportContent)
                        let usesGraphic = mode == .customEventHeader && (source == .automatic || source == .eventHeaderGraphic)
                        XCTAssertEqual(content.titleMode == .headerGraphic, usesGraphic, "\(mode) \(shown) \(source)")
                        XCTAssertEqual(layout.headerGraphicRect != nil, usesGraphic)
                        if let graphic = layout.headerGraphicRect {
                            XCTAssertTrue(layout.titleColumn.contains(graphic))
                            XCTAssertEqual(plan.customHeaderFrame, graphic)
                        }
                        XCTAssertEqual(layout.upperCard.minY, 14)
                        let receipt = try ReceiptComposer.compose(photos: passportPhotos(seed: 50), sessionIdentifier: "PP-EVENT", date: date, galleryURL: qr ? galleryURL : nil, format: .passport, eventProfile: profile, passport: passport)
                        XCTAssertEqual(receipt.height, plan.height)
                    }
                }
            }
        }
    }

    // MARK: M/R. QR footer and raster

    func testPassportReceiptQRDecodesAndRasterIsDeterministic() throws {
        let receipt = try ReceiptComposer.compose(photos: passportPhotos(seed: 60), sessionIdentifier: "PP-PASSPORT-QR", date: date, galleryURL: galleryURL, format: .passport, passport: .debugFixture)
        let image = try XCTUnwrap(UIImage(data: receipt.imagePNGData))
        let first = try ThermalImageRasterizer.rasterize(image, purpose: .completeReceipt)
        let second = try ThermalImageRasterizer.rasterize(image, purpose: .completeReceipt)
        XCTAssertEqual(first.rasterData, second.rasterData)
        XCTAssertEqual(first.rasterCommand, second.rasterCommand)
        XCTAssertEqual(first.width, 576)
        XCTAssertEqual(first.height, receipt.height)
        XCTAssertLessThanOrEqual(first.height, BoothConfiguration.receiptMaximumHeight)
        XCTAssertTrue(first.sanitizationReport.finalSafetyScanPassed)
        for preview in [image, try XCTUnwrap(UIImage(data: first.previewPNGData))] {
            XCTAssertTrue(decodedQRMessages(in: preview).contains(galleryURL.absoluteString))
        }
        attach(image, name: "Passport-full-receipt")
        attach(try XCTUnwrap(UIImage(data: first.previewPNGData)), name: "Passport-full-receipt-thermal")
    }

    // MARK: N. Photo roles

    func testPhotoOneIsLowerPortraitAndPhotoTwoIsUpperHero() throws {
        let dark = solidPhoto(white: 0.05)
        let bright = solidPhoto(white: 0.97)
        let plan = try ReceiptComposer.makeLayoutPlan(format: .passport, passport: .empty, date: date)
        let layout = try XCTUnwrap(plan.passportLayout)
        XCTAssertEqual(plan.photoFrames.first { $0.photoIndex == 0 }?.rect, layout.portraitPhotoRect)
        XCTAssertEqual(plan.photoFrames.first { $0.photoIndex == 1 }?.rect, layout.heroPhotoRect)
        XCTAssertTrue(layout.lowerCard.contains(layout.portraitPhotoRect))
        XCTAssertTrue(layout.upperCard.contains(layout.heroPhotoRect))
        XCTAssertEqual(layout.heroPhotoRect.width * 3, layout.heroPhotoRect.height * 4, "Hero is a 4:3 landscape crop")
        XCTAssertEqual(layout.portraitPhotoRect.width * 4, layout.portraitPhotoRect.height * 3, "Portrait is a 3:4 crop")
        XCTAssertGreaterThan(layout.heroPhotoRect.width * layout.heroPhotoRect.height, layout.portraitPhotoRect.width * layout.portraitPhotoRect.height * 2)

        let receipt = try ReceiptComposer.compose(photos: [dark, bright], sessionIdentifier: "PP-ROLES", date: date, format: .passport, passport: .empty)
        let image = try XCTUnwrap(UIImage(data: receipt.imagePNGData))
        XCTAssertLessThan(try luminance(in: image, at: CGPoint(x: layout.portraitPhotoRect.midX, y: layout.portraitPhotoRect.midY)), 0.3)
        XCTAssertGreaterThan(try luminance(in: image, at: CGPoint(x: layout.heroPhotoRect.midX, y: layout.heroPhotoRect.midY)), 0.8)

        // Review/preview crops match the receipt roles.
        let source = syntheticPhoto(width: 300, height: 400, seed: 70)
        XCTAssertEqual(PassportPhotoProcessor.presentationPhoto(from: source, role: .hero).size, CGSize(width: 300, height: 225))
        XCTAssertEqual(PassportPhotoProcessor.presentationPhoto(from: source, role: .portrait).size, CGSize(width: 300, height: 400))
        XCTAssertEqual(PassportPhotoProcessor.cropRect(sourceSize: CGSize(width: 300, height: 400), role: .hero).minY, 70, "Hero crop sits slightly high to keep faces")
    }

    // MARK: O/P. Archive and reprint

    func testArchivePersistsPassportAndReprintKeepsFrozenReceipt() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try RecentSessionArchiveStore(directoryURL: directory)

        var eventA = eventProfile()
        eventA.passport.theme = .classic
        let passportA = PassportSessionData(
            name: "Sarah",
            birthday: PassportBirthday(month: 4, day: 20, year: 1998),
            nationality: "Brazilian",
            profession: "Model",
            signature: .debugFixture,
            configuration: PassportConfiguration.effective(for: eventA)
        ).committed(at: date)
        let committedA = committedSession(id: "PP-ARCHIVE-A", token: token, passport: passportA, eventProfile: eventA.activeReceiptSnapshot)
        let receiptA = try compose(committedA)
        let rasterA = try ThermalImageRasterizer.rasterize(XCTUnwrap(UIImage(data: receiptA.imagePNGData)), purpose: .completeReceipt)
        try store.save(RecentSessionArchivePayload(committedSession: committedA, composedReceipt: receiptA, receiptPreviewPNGData: receiptA.imagePNGData, thermalPreviewPNGData: rasterA.previewPNGData, rasterizedImage: rasterA, photoThumbnailData: [Data([1]), Data([2])]))

        // The operator later changes the active event and Passport theme.
        var eventLater = eventProfile()
        eventLater.eventName = "Cebu Tech Night"
        eventLater.passport.theme = .stars
        eventLater.passport.eventLabel = "Event Passport"
        let laterReceipt = try compose(committedSession(id: "PP-ARCHIVE-B", token: String(repeating: "d", count: 64), passport: PassportSessionData(configuration: PassportConfiguration.effective(for: eventLater)), eventProfile: eventLater.activeReceiptSnapshot))
        XCTAssertNotEqual(laterReceipt.imagePNGData, receiptA.imagePNGData)

        let loaded = try RecentSessionArchiveStore(directoryURL: directory).load(archiveID: token)
        XCTAssertEqual(loaded.summary.format, .passport)
        XCTAssertEqual(loaded.summary.photoCount, 2)
        XCTAssertEqual(loaded.passport, passportA)
        XCTAssertEqual(loaded.passport?.configuration.theme, .classic)
        XCTAssertEqual(loaded.passport?.signature, .debugFixture)
        XCTAssertEqual(loaded.rasterizedImage.rasterCommand, rasterA.rasterCommand, "Reprint uses the frozen raster")
        XCTAssertEqual(loaded.receiptPreviewPNGData, receiptA.imagePNGData)

        // Recomposing the frozen session later is identical too (age and config are frozen).
        let recomposed = try ReceiptComposer.compose(photos: committedA.photos, sessionIdentifier: committedA.sessionIdentifier, date: committedA.createdAt, galleryURL: committedA.galleryURL, format: .passport, eventProfile: committedA.eventProfile, passport: loaded.passport)
        XCTAssertEqual(recomposed.imagePNGData, receiptA.imagePNGData)

        try RecentSessionArchiveStore(directoryURL: directory).markReprinted(archiveID: token, copies: 2)
        XCTAssertEqual(try RecentSessionArchiveStore(directoryURL: directory).load(archiveID: token).passport, passportA)
    }

    func testRecoverySnapshotRoundTripsCommittedPassportOnlyForItsSession() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try AppRecoveryStore(directoryURL: directory)
        let passport = PassportSessionData.debugFixture.committed(at: date)
        store.save(AppRecoverySnapshot(schemaVersion: 1, sessionIdentifier: "PP-PASSPORT-REC", createdAt: date, format: .passport, eventProfile: nil, galleryToken: token, galleryURL: galleryURL, photoJPEGData: [], receiptPreviewPNGData: nil, thermalPreviewPNGData: nil, rasterFingerprint: nil, stage: .receiptComposed, updatedAt: date, passport: passport))
        XCTAssertEqual(store.load()?.passport, passport)
        store.clear(sessionIdentifier: "PP-SOMEONE-ELSE")
        XCTAssertNotNil(store.load())
        store.clear(sessionIdentifier: "PP-PASSPORT-REC")
        XCTAssertNil(store.load())

        // Snapshots written before Passport existed still decode.
        store.save(AppRecoverySnapshot(schemaVersion: 1, sessionIdentifier: "PP-LEGACY", createdAt: date, format: .duo, eventProfile: nil, galleryToken: nil, galleryURL: nil, photoJPEGData: [], receiptPreviewPNGData: nil, thermalPreviewPNGData: nil, rasterFingerprint: nil, stage: .formatSelected, updatedAt: date))
        XCTAssertNil(store.load()?.passport)
        XCTAssertEqual(store.load()?.format, .duo)
    }

    // MARK: Q. Gallery privacy

    func testGalleryUploadsTwoPhotosAndNoPassportPersonalDetails() throws {
        let passport = PassportSessionData(
            name: "Zebulon Quixote",
            birthday: PassportBirthday(month: 4, day: 20, year: 1998),
            nationality: "Narnian",
            profession: "Dragon Tamer",
            birthplace: "Atlantis",
            signature: .debugFixture
        ).committed(at: date)
        let committed = committedSession(id: "PP-20260907-GALLERY", token: token, passport: passport)
        let printed = try compose(committed)
        let printedImage = try XCTUnwrap(UIImage(data: printed.imagePNGData))
        let galleryImage = try BoothSessionViewModel.galleryReceiptImage(for: committed, printedReceiptImage: printedImage, photoQualityProfile: .customerPrintDefault)
        XCTAssertNotEqual(galleryImage.pngData(), printedImage.pngData(), "Gallery receipt must be the redacted copy")
        XCTAssertEqual(galleryImage.size.width, printedImage.size.width)
        XCTAssertTrue(decodedQRMessages(in: galleryImage).contains(committed.galleryURL.absoluteString))

        // The signature and name areas carry ink on the printed copy only.
        let printedLayout = try XCTUnwrap(ReceiptComposer.makeLayoutPlan(format: .passport, passport: passport, date: date).passportLayout)
        let galleryLayout = try XCTUnwrap(ReceiptComposer.makeLayoutPlan(format: .passport, passport: passport.redactedForGallery(), date: date).passportLayout)
        XCTAssertEqual(Int(galleryImage.size.height), try ReceiptComposer.makeLayoutPlan(format: .passport, passport: passport.redactedForGallery(), date: date).height)
        XCTAssertGreaterThan(try darkPixelCount(in: printedImage, rect: printedLayout.signatureRect), 40)
        XCTAssertEqual(try darkPixelCount(in: galleryImage, rect: galleryLayout.signatureRect), 0)
        let printedName = try XCTUnwrap(printedLayout.allTexts.first { $0.role == .fieldValue("NAME") })
        let galleryName = try XCTUnwrap(galleryLayout.allTexts.first { $0.role == .fieldValue("NAME") })
        XCTAssertGreaterThan(try darkPixelCount(in: printedImage, rect: printedName.rect), 20)
        XCTAssertEqual(try darkPixelCount(in: galleryImage, rect: galleryName.rect), 0)
        XCTAssertTrue(galleryLayout.allTexts.filter {
            if case .fieldValue = $0.role { return true }
            return false
        }.allSatisfy { $0.text.isEmpty })

        let payload = try GoogleDriveGalleryUploadService.preparePayload(photos: committed.photos, composedReceipt: galleryImage, sessionID: committed.sessionIdentifier, createdAt: date, galleryToken: token, customerGalleryBaseURL: URL(string: "https://example.com/")!)
        let request = try GoogleDriveGalleryUploadService.makeRequestBody(payload: payload, deviceToken: String(repeating: "x", count: 32))
        XCTAssertEqual(request.photos.map(\.filename), ["photo-01.jpg", "photo-02.jpg"])
        // Inspect every metadata value; image bytes are blanked so random base64 cannot match.
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request))
        let json = try XCTUnwrap(String(data: JSONSerialization.data(withJSONObject: blankingImageData(in: object), options: [.sortedKeys]), encoding: .utf8))
        XCTAssertTrue(json.contains("photo-02.jpg"))
        for secret in ["Zebulon", "Quixote", "Narnian", "Dragon", "Tamer", "Atlantis", "1998", "APR 20", "signature", "nationality", "profession", "birthday"] {
            XCTAssertFalse(json.localizedCaseInsensitiveContains(secret), "Upload request must not contain \(secret)")
        }
        attach(galleryImage, name: "Passport-gallery-redacted")

        // Non-Passport formats keep uploading the printed receipt unchanged.
        let duo = CommittedGallerySession(sessionIdentifier: "PP-DUO", createdAt: date, galleryToken: token, galleryURL: galleryURL, photos: passportPhotos(seed: 80), format: .duo, eventProfile: nil)
        XCTAssertTrue(try BoothSessionViewModel.galleryReceiptImage(for: duo, printedReceiptImage: printedImage, photoQualityProfile: .customerPrintDefault) === printedImage)
    }

    // MARK: Dimensions

    func testPassportPhysicalDimensions() throws {
        let headerImage = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 2_000)).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 100, height: 2_000))
        }
        let identifier = try EventHeaderAssetStore().importImageData(XCTUnwrap(headerImage.pngData()))

        var worstProfile = maximumEventProfile()
        worstProfile.receiptHeader.mode = .customEventHeader
        worstProfile.receiptHeader.assetIdentifier = identifier
        worstProfile.receiptHeader.scale = ReceiptHeaderConfiguration.maximumScale
        worstProfile.receiptHeader.topSpacing = ReceiptHeaderConfiguration.maximumSpacing
        worstProfile.receiptHeader.bottomSpacing = ReceiptHeaderConfiguration.maximumSpacing
        var worstEventText = maximumEventProfile()
        worstEventText.passport.titleSource = .eventText

        let cases: [(String, EventProfile?, PassportSessionData)] = [
            ("default", nil, .debugFixture),
            ("defaultNoDetails", nil, .empty),
            ("maximumText", nil, maximumPassport(theme: .classic)),
            ("eventMode", eventProfile(), .debugFixture),
            ("worstCustomHeaderEvent", worstProfile, maximumPassport(theme: .event, configuration: PassportConfiguration.effective(for: worstProfile))),
            ("worstEventText", worstEventText, maximumPassport(theme: .event, configuration: PassportConfiguration.effective(for: worstEventText)))
        ]
        for (name, profile, passport) in cases {
            for qr in [true, false] {
                let plan = try ReceiptComposer.makeLayoutPlan(format: .passport, includesGalleryQRCode: qr, eventProfile: profile, passport: passport, date: date)
                try assertValidPassportPlan(plan)
                let receipt = try ReceiptComposer.compose(photos: passportPhotos(seed: 90), sessionIdentifier: "PP-20260907-161400", date: date, galleryURL: qr ? galleryURL : nil, format: .passport, eventProfile: profile, passport: passport)
                XCTAssertEqual(receipt.height, plan.height)
                XCTAssertLessThanOrEqual(receipt.height, BoothConfiguration.receiptMaximumHeight)
                let millimeters = Double(receipt.height) / 8
                print("PASSPORT_DIMENSIONS \(name)\(qr ? "QR" : "NoQR")=\(receipt.width)x\(receipt.height) mm=\(String(format: "%.3f", millimeters)) cm=\(String(format: "%.4f", millimeters / 10))")
                if qr {
                    let image = try XCTUnwrap(UIImage(data: receipt.imagePNGData))
                    attach(image, name: "Passport-\(name)")
                    writeArtifact(image, name: "receipt-\(name).png")
                    let thermal = try XCTUnwrap(UIImage(data: ThermalImageRasterizer.rasterize(image, purpose: .completeReceipt).previewPNGData))
                    writeArtifact(thermal, name: "receipt-\(name)-thermal.png")
                }
            }
        }
        for theme in PassportTheme.allCases {
            var passport = PassportSessionData.debugFixture
            passport.configuration.theme = theme
            let receipt = try ReceiptComposer.compose(photos: passportPhotos(seed: 91), sessionIdentifier: "PP-20260907-161400", date: date, galleryURL: galleryURL, format: .passport, passport: passport)
            let image = try XCTUnwrap(UIImage(data: receipt.imagePNGData))
            writeArtifact(try XCTUnwrap(UIImage(data: ThermalImageRasterizer.rasterize(image, purpose: .completeReceipt).previewPNGData)), name: "theme-\(theme.rawValue)-thermal.png")
        }
    }

    // MARK: Customer screens

    func testPassportCustomerScreensOnElevenInchIPad() async throws {
        let states: [BoothSessionState] = [.choosingFormat, .review, .passportDetails, .passportSignature, .passportPreview]
        for size in [CGSize(width: 834, height: 1194), CGSize(width: 1194, height: 834)] {
            for state in states {
                let model = BoothSessionViewModel()
                if state != .choosingFormat {
                    model.selectedBoothFormat = .passport
                    model.capturedPhotos = [syntheticPhoto(width: 300, height: 400, seed: 1), syntheticPhoto(width: 300, height: 400, seed: 2)]
                    model.passportDraft = .debugFixture
                }
                model.state = state == .passportPreview ? .passportSignature : state
                if state == .passportPreview {
                    model.continueFromPassportSignature()
                }
                let controller = UIHostingController(rootView: BoothSessionView(viewModel: model))
                let window = UIWindow(frame: CGRect(origin: .zero, size: size))
                window.rootViewController = controller
                window.makeKeyAndVisible()
                controller.view.frame = window.bounds
                controller.view.layoutIfNeeded()
                try await Task.sleep(for: .seconds(state == .passportPreview ? 2.5 : 1))
                controller.view.layoutIfNeeded()
                let image = UIGraphicsImageRenderer(size: size).image { _ in
                    controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
                }
                let name = "Passport-screen-\(state.title.replacingOccurrences(of: " ", with: ""))-\(Int(size.width))x\(Int(size.height))"
                attach(image, name: name)
                writeArtifact(image, name: "\(name).png")
                if state == .passportPreview {
                    XCTAssertNotNil(model.passportPreviewImage, "Preview renders the real Passport cards")
                }
                window.isHidden = true
                model.cancelSession()
            }
        }
    }

    // MARK: - Helpers

    private var galleryURL: URL {
        URL(string: "https://example.com/?g=\(token)")!
    }

    private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
    }

    private func passportContent(eventProfile: EventProfile?) throws -> PassportReceiptContent {
        var passport = PassportSessionData.debugFixture
        passport.configuration = PassportConfiguration.effective(for: eventProfile)
        let plan = try ReceiptComposer.makeLayoutPlan(format: .passport, eventProfile: eventProfile, passport: passport, date: date)
        try assertValidPassportPlan(plan)
        return try XCTUnwrap(plan.passportContent)
    }

    private func eventProfile() -> EventProfile {
        var profile = EventProfile(
            isEnabled: true,
            eventName: "Anna & Mark",
            subtitle: "Our Wedding Day",
            includeEventDate: true,
            eventDate: date,
            location: "Cebu City",
            shortMessage: "Thank you for celebrating"
        )
        profile.passport.eventLabel = "Wedding Passport"
        return profile
    }

    private func maximumEventProfile() -> EventProfile {
        var profile = EventProfile(
            isEnabled: true,
            eventName: String(repeating: "W", count: EventProfile.eventNameLimit),
            subtitle: String(repeating: "W", count: EventProfile.subtitleLimit),
            includeEventDate: true,
            eventDate: date,
            location: String(repeating: "W", count: EventProfile.locationLimit),
            shortMessage: String(repeating: "W", count: EventProfile.shortMessageLimit)
        )
        profile.passport = PassportConfiguration(
            theme: .event,
            titleSource: .automatic,
            title: String(repeating: "W", count: PassportConfiguration.titleLimit),
            subtitle: String(repeating: "W", count: PassportConfiguration.subtitleLimit),
            eventLabel: String(repeating: "W", count: PassportConfiguration.eventLabelLimit)
        )
        return profile
    }

    private func maximumPassport(theme: PassportTheme, configuration: PassportConfiguration? = nil) -> PassportSessionData {
        var config = configuration ?? PassportConfiguration(
            title: String(repeating: "W", count: PassportConfiguration.titleLimit),
            subtitle: String(repeating: "W", count: PassportConfiguration.subtitleLimit),
            eventLabel: String(repeating: "W", count: PassportConfiguration.eventLabelLimit)
        )
        config.theme = theme
        return PassportSessionData(
            name: String(repeating: "W", count: PassportSessionData.nameLimit),
            birthday: PassportBirthday(month: 9, day: 30, year: 1926),
            nationality: String(repeating: "W", count: PassportSessionData.nationalityLimit),
            profession: String(repeating: "W", count: PassportSessionData.professionLimit),
            birthplace: String(repeating: "W", count: PassportSessionData.birthplaceLimit),
            signature: .debugFixture,
            configuration: config
        )
    }

    private func committedSession(id: String, token: String, passport: PassportSessionData?, eventProfile: EventProfile? = nil) -> CommittedGallerySession {
        CommittedGallerySession(
            sessionIdentifier: id,
            createdAt: date,
            galleryToken: token,
            galleryURL: URL(string: "https://example.com/?g=\(token)")!,
            photos: passportPhotos(seed: id.count),
            format: .passport,
            eventProfile: eventProfile,
            passport: passport
        )
    }

    private func compose(_ session: CommittedGallerySession) throws -> ComposedReceipt {
        try ReceiptComposer.compose(
            photos: session.photos,
            sessionIdentifier: session.sessionIdentifier,
            date: session.createdAt,
            galleryURL: session.galleryURL,
            format: session.format,
            eventProfile: session.eventProfile,
            passport: session.passport
        )
    }

    private func assertValidPassportPlan(_ plan: ReceiptLayoutPlan, file: StaticString = #filePath, line: UInt = #line) throws {
        let layout = try XCTUnwrap(plan.passportLayout, file: file, line: line)
        let canvas = CGRect(x: 0, y: 0, width: plan.width, height: plan.height)
        XCTAssertEqual(plan.width, BoothConfiguration.receiptWidth, file: file, line: line)
        XCTAssertLessThanOrEqual(plan.height, BoothConfiguration.receiptMaximumHeight, file: file, line: line)
        XCTAssertEqual(plan.displayedPhotoIndexes, [0, 1], file: file, line: line)
        XCTAssertEqual(plan.photoFrames.count, 2, file: file, line: line)
        for card in [layout.upperCard, layout.lowerCard] {
            XCTAssertTrue(canvas.contains(card), file: file, line: line)
            XCTAssertGreaterThanOrEqual(card.minX, CGFloat(BoothConfiguration.receiptHorizontalMargin), file: file, line: line)
            XCTAssertLessThanOrEqual(card.maxX, CGFloat(576 - BoothConfiguration.receiptHorizontalMargin), file: file, line: line)
        }
        XCTAssertFalse(layout.heroPhotoRect.intersects(layout.portraitPhotoRect), file: file, line: line)
        for block in layout.upperTexts {
            XCTAssertTrue(layout.upperCard.contains(block.rect), "\(block.role) outside upper card", file: file, line: line)
            XCTAssertFalse(block.rect.intersects(layout.heroPhotoRect), "\(block.role) overlaps hero", file: file, line: line)
        }
        for block in layout.lowerTexts {
            XCTAssertTrue(layout.lowerCard.contains(block.rect), "\(block.role) outside lower card", file: file, line: line)
            XCTAssertFalse(block.rect.intersects(layout.portraitPhotoRect), "\(block.role) overlaps portrait", file: file, line: line)
        }
        let fieldBlocks = layout.lowerTexts.filter {
            if case .fieldValue = $0.role { return true }
            if case .fieldLabel = $0.role { return true }
            return false
        }
        for (index, block) in fieldBlocks.enumerated() {
            for other in fieldBlocks.dropFirst(index + 1) {
                XCTAssertFalse(block.rect.insetBy(dx: 0.5, dy: 0.5).intersects(other.rect), "\(block.role) overlaps \(other.role)", file: file, line: line)
            }
            XCTAssertFalse(block.rect.intersects(layout.signatureBox), file: file, line: line)
        }
        XCTAssertTrue(layout.signatureBox.contains(layout.signatureRect), file: file, line: line)
        XCTAssertGreaterThan(plan.height, layout.bottom, file: file, line: line)
    }

    private func passportPhotos(seed: Int) -> [UIImage] {
        [syntheticPhoto(width: 300, height: 400, seed: seed), syntheticPhoto(width: 300, height: 400, seed: seed + 1)]
    }

    private func syntheticPhoto(width: Int, height: Int, seed: Int) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            UIColor(hue: CGFloat((seed * 37) % 100) / 100, saturation: 0.45, brightness: 0.9, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            UIColor(white: 0.25, alpha: 1).setFill()
            context.cgContext.fillEllipse(in: CGRect(x: width / 3, y: height / 5, width: width / 3, height: width / 3))
            context.fill(CGRect(x: width / 4, y: height / 2, width: width / 2, height: height / 2))
            "P\(seed)".draw(at: CGPoint(x: 10, y: 10), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 28)])
        }
    }

    private func solidPhoto(white: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: 300, height: 400), format: format).image { context in
            UIColor(white: white, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 300, height: 400))
        }
    }

    private func rgbaPixels(of image: UIImage) throws -> (pixels: [UInt8], width: Int, height: Int) {
        let cgImage = try XCTUnwrap(image.cgImage)
        let width = cgImage.width
        let height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return (pixels, width, height)
    }

    private func luminance(in image: UIImage, at point: CGPoint) throws -> Double {
        let data = try rgbaPixels(of: image)
        let offset = (Int(point.y) * data.width + Int(point.x)) * 4
        return (0.2126 * Double(data.pixels[offset]) + 0.7152 * Double(data.pixels[offset + 1]) + 0.0722 * Double(data.pixels[offset + 2])) / 255
    }

    private func darkPixelCount(in image: UIImage, rect: CGRect) throws -> Int {
        let data = try rgbaPixels(of: image)
        var count = 0
        for y in Int(rect.minY)..<Int(rect.maxY) {
            for x in Int(rect.minX)..<Int(rect.maxX) {
                let offset = (y * data.width + x) * 4
                if Int(data.pixels[offset]) + Int(data.pixels[offset + 1]) + Int(data.pixels[offset + 2]) < 300 {
                    count += 1
                }
            }
        }
        return count
    }

    private func blankingImageData(in object: Any) -> Any {
        if let dictionary = object as? [String: Any] {
            return Dictionary(uniqueKeysWithValues: dictionary.map { key, value in
                (key, key.lowercased().contains("base64") ? "" : blankingImageData(in: value))
            })
        }
        if let array = object as? [Any] {
            return array.map(blankingImageData(in:))
        }
        return object
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

    /// Optional local artifacts for visual inspection: set PASSPORT_ARTIFACT_DIR for the test run.
    private func writeArtifact(_ image: UIImage, name: String) {
        guard let directory = ProcessInfo.processInfo.environment["PASSPORT_ARTIFACT_DIR"], !directory.isEmpty else { return }
        let url = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try? image.pngData()?.write(to: url.appendingPathComponent(name))
    }
}
