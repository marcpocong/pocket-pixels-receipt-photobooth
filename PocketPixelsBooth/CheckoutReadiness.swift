import AVFoundation
import Foundation

/// Bounded pre-payment equipment check. It does not capture, print, claim an entitlement or
/// mutate a commercial event. A successful check is a point-in-time observation, not a print guarantee.
@MainActor final class CheckoutReadiness {
    private let camera = CameraService()
    private var continuation: CheckedContinuation<Void, Error>?
    func check() async throws {
        guard EventOperationalState.shared.networkPathStatus == "Online" else { throw SetupFailure("Internet is unavailable. No payment QR was issued.") }
        guard !PrinterCoordinator.shared.requiresRecovery, !EventOperationalState.shared.hasUnresolvedPrint else {
            throw SetupFailure("The printer needs a paper check in Operator → Recovery. No payment QR was issued.")
        }
        guard PrinterCoordinator.shared.preferredMode != .wifi else {
            throw SetupFailure("Select Bluetooth or Auto in Operator → Printer Setup for Bluetooth checkout. No payment QR was issued.")
        }
        guard try await PrinterBluetoothService.shared.waitUntilReady() else {
            throw SetupFailure("\(PrinterBluetoothService.shared.readinessMessage) Open Operator → Printer Setup or Recovery. No payment QR was issued.")
        }
        guard camera.authorizationStatus() == .authorized else { throw SetupFailure("Camera permission needs operator attention. No payment QR was issued.") }
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            camera.configureAndStart { [weak self] result in
                Task { @MainActor in
                    switch result {
                    case .success: self?.finish(nil)
                    case .failure(let error): self?.finish(error)
                    }
                }
            }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(8))
                self?.finish(SetupFailure("Camera readiness timed out. No payment QR was issued."))
            }
        }
    }
    private func finish(_ error: Error?) {
        camera.stopSession()
        guard let continuation else { return }
        self.continuation = nil
        if let error { continuation.resume(throwing: error) }
        else { continuation.resume() }
    }
}
