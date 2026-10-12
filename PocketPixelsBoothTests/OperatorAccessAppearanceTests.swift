import XCTest
import SwiftUI
@testable import PocketPixelsBooth

@MainActor final class OperatorAccessAppearanceTests: XCTestCase {
    func testRenderAccessCardInPortraitAndLandscape() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        for size in [CGSize(width: 834, height: 1194), CGSize(width: 1194, height: 834)] {
            let screen = OperatorAccessScreen(unlock: {}, passcode: {}, back: {})
            let controller = UIHostingController(rootView: screen)
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(origin: .zero, size: size)
            window.overrideUserInterfaceStyle = .light
            window.rootViewController = controller
            window.makeKeyAndVisible()
            try await Task.sleep(for: .milliseconds(300))
            controller.view.frame = window.bounds; controller.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(size: size).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            XCTAssertGreaterThan(image.pngData()?.count ?? 0, 30_000, "A blank image cannot validate the layout")
            let attachment = XCTAttachment(image: image)
            attachment.name = size.width < size.height ? "operator-access-portrait" : "operator-access-landscape"
            attachment.lifetime = .keepAlways; add(attachment)
            window.isHidden = true
        }
    }
}
