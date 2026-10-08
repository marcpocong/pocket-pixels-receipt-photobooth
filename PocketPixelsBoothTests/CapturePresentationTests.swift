import Testing
import UIKit
@testable import PocketPixelsBooth

struct CapturePresentationTests {
    @Test("Camera composition is centered below a fixed top bar without changing viewport state")
    func stableCameraCompositionGeometry() {
        let available = CGSize(width: 786, height: 1_032)
        let ready = CameraScreenLayout(available: available, maximumContentWidth: 620, aspectRatio: 4.0 / 3.0)
        let countdown = CameraScreenLayout(available: available, maximumContentWidth: 620, aspectRatio: 4.0 / 3.0)

        #expect(ready == countdown)
        #expect(ready.viewportSize == CGSize(width: 580, height: 435))
        #expect(ready.compositionHeight <= available.height)
        let topSpace = (available.height - ready.compositionHeight) / 2
        #expect(topSpace > 150)
    }

    @Test("Camera geometry respects every role aspect and supported iPad height")
    func cameraAspectGeometry() {
        let available = CGSize(width: 786, height: 1_032)
        for format in BoothFormat.allCases {
            for photoIndex in 0..<format.photoCount {
                let presentation = CapturePhotoPresentation.resolve(format: format, photoIndex: photoIndex)
                let layout = CameraScreenLayout(
                    available: available,
                    maximumContentWidth: 620,
                    aspectRatio: presentation.aspectRatio
                )
                #expect(abs(layout.viewportSize.width / layout.viewportSize.height - presentation.aspectRatio) < 0.01)
                #expect(layout.compositionHeight <= available.height)
            }
        }
    }

    @Test("Every format resolves the required camera framing")
    func formatFramingMatrix() {
        #expect(CapturePhotoPresentation.resolve(format: .solo, photoIndex: 0) == .portrait)
        #expect(CapturePhotoPresentation.resolve(format: .duo, photoIndex: 0) == .landscape)
        #expect(CapturePhotoPresentation.resolve(format: .duo, photoIndex: 1) == .landscape)
        #expect(CapturePhotoPresentation.resolve(format: .grid, photoIndex: 3) == .portrait)
        #expect(CapturePhotoPresentation.resolve(format: .strip, photoIndex: 2) == .landscape)
        #expect(CapturePhotoPresentation.resolve(format: .gridSix, photoIndex: 5) == .portrait)
        #expect(CapturePhotoPresentation.resolve(format: .passport, photoIndex: 0) == .portrait)
        #expect(CapturePhotoPresentation.resolve(format: .passport, photoIndex: 1) == .landscape)
    }

    @Test("Confirmation photos use the framing aspect and preserve the source")
    func confirmationCropGeometry() {
        let sourceSize = CGSize(width: 900, height: 1_600)
        let renderer = UIGraphicsImageRenderer(size: sourceSize)
        let source = renderer.image { context in
            UIColor.systemPink.setFill()
            context.fill(CGRect(origin: .zero, size: sourceSize))
        }

        let duo = CapturePhotoPresentation.landscape.confirmationPhoto(
            from: source,
            format: .duo,
            photoIndex: 0
        )
        let solo = CapturePhotoPresentation.portrait.confirmationPhoto(
            from: source,
            format: .solo,
            photoIndex: 0
        )
        let photoPassPortrait = CapturePhotoPresentation.portrait.confirmationPhoto(
            from: source,
            format: .passport,
            photoIndex: 0
        )
        let photoPassHero = CapturePhotoPresentation.landscape.confirmationPhoto(
            from: source,
            format: .passport,
            photoIndex: 1
        )

        #expect(abs((duo.size.width / duo.size.height) - (4.0 / 3.0)) < 0.01)
        #expect(abs((solo.size.width / solo.size.height) - (3.0 / 4.0)) < 0.01)
        #expect(abs((photoPassPortrait.size.width / photoPassPortrait.size.height) - (3.0 / 4.0)) < 0.01)
        #expect(abs((photoPassHero.size.width / photoPassHero.size.height) - (4.0 / 3.0)) < 0.01)
        #expect(source.size == sourceSize)
    }

    @Test("Display confirmation images are bounded without upscaling")
    func confirmationImageSizing() {
        let sourceSize = CGSize(width: 3_000, height: 4_000)
        let source = UIGraphicsImageRenderer(size: sourceSize).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: sourceSize))
        }

        let confirmation = CapturePhotoPresentation.portrait.confirmationPhoto(
            from: source,
            format: .gridSix,
            photoIndex: 5,
            maximumDimension: 720
        )

        #expect(max(confirmation.size.width, confirmation.size.height) == 720)
        #expect(max(source.size.width, source.size.height) == 4_000)
    }
}
