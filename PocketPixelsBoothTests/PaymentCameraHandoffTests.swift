import XCTest
@testable import PocketPixelsBooth

@MainActor
final class PaymentCameraHandoffTests: XCTestCase {
    func testAuthorizedPaymentRelinquishesTaskOwnershipAndStartPhotosClaimsIt() {
        let model = BoothSessionViewModel()
        model.configureAuthorizedCameraReadyForTesting()
        model.installAuthorizationTaskForTesting()

        XCTAssertTrue(model.hasActiveTaskForTesting)
        XCTAssertFalse(model.releaseAuthorizationTaskForCamera(generation: 1), "A stale callback must not release the current session task")
        XCTAssertTrue(model.hasActiveTaskForTesting)

        XCTAssertTrue(model.releaseAuthorizationTaskForCamera(generation: 0))
        XCTAssertFalse(model.hasActiveTaskForTesting)

        model.beginPhotoSequence()
        XCTAssertTrue(model.hasActiveTaskForTesting, "Camera capture must be able to claim task ownership after authorization")

        model.cancelActiveTaskForTesting()
    }
}
