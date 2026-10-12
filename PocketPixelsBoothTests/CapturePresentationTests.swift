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

    /// Composition areas below the fixed camera top bar on the 11-inch iPad Pro, after status-bar
    /// and home-indicator safe areas: upright portrait and the supported landscape-right mount.
    static let supportedCameraCompositionAreas = [
        CGSize(width: 834, height: 1_194 - 24 - 20 - CameraScreenLayout.topBarHeight),
        CGSize(width: 1_194, height: 834 - 24 - 20 - CameraScreenLayout.topBarHeight)
    ]

    @Test("Camera aperture stays inside every supported viewport and never jumps between photos")
    func cameraViewportRegression() {
        for available in Self.supportedCameraCompositionAreas {
            let contentWidth = min(available.width - 48, 620)
            for format in BoothFormat.allCases {
                let layouts = (0..<format.photoCount).map { index in
                    CameraScreenLayout(
                        available: available,
                        maximumContentWidth: contentWidth,
                        aspectRatio: CapturePhotoPresentation.resolve(format: format, photoIndex: index).aspectRatio
                    )
                }
                for layout in layouts {
                    #expect(layout.viewportSize.width <= contentWidth)
                    #expect(layout.compositionHeight <= available.height, "\(format) camera overflows \(available)")
                    // A usable aperture: never shrunk to a thumbnail on the booth mount.
                    #expect(min(layout.viewportSize.width, layout.viewportSize.height) >= 300, "\(format) aperture too small in \(available)")
                }
                // Each format frames every photo the same way, so the aperture never resizes
                // between photos (Photo Pass previously switched portrait -> landscape).
                #expect(Set(layouts.map(\.viewportSize.width)).count == 1, "\(format) aperture jumps between photos")
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
        // The Photo Pass hero prints as an upright 3:4 portrait on the sideways upper card, so the
        // guest frames and approves a portrait (it was previously shown as a 4:3 landscape).
        #expect(CapturePhotoPresentation.resolve(format: .passport, photoIndex: 1) == .portrait)
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
        let photoPassHero = CapturePhotoPresentation.portrait.confirmationPhoto(
            from: source,
            format: .passport,
            photoIndex: 1
        )

        #expect(abs((duo.size.width / duo.size.height) - (4.0 / 3.0)) < 0.01)
        #expect(abs((solo.size.width / solo.size.height) - (3.0 / 4.0)) < 0.01)
        #expect(abs((photoPassPortrait.size.width / photoPassPortrait.size.height) - (3.0 / 4.0)) < 0.01)
        #expect(abs((photoPassHero.size.width / photoPassHero.size.height) - (3.0 / 4.0)) < 0.01)
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
