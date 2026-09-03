//
//  CameraService.swift
//  PocketPixelsBooth
//
//  Created by marc on 8/30/26.
//

@preconcurrency import AVFoundation
import Foundation
import UIKit

enum CameraServiceError: Error, LocalizedError {
    case cameraUnavailable
    case permissionDenied
    case permissionRestricted
    case configurationFailed(String)
    case captureInProgress
    case captureFailed(String)

    var errorDescription: String? {
        switch self {
        case .cameraUnavailable:
            "The iPad camera must be tested on a physical device."
        case .permissionDenied:
            "Camera permission is denied. Enable camera access in Settings to test capture."
        case .permissionRestricted:
            "Camera permission is restricted on this iPad."
        case .configurationFailed(let details):
            "The camera could not be configured. \(details)"
        case .captureInProgress:
            "A photo capture is already in progress."
        case .captureFailed(let details):
            "The photo could not be captured. \(details)"
        }
    }
}

final class CameraService: NSObject {
    typealias Completion = (Result<Void, CameraServiceError>) -> Void
    typealias PhotoCompletion = (Result<UIImage, CameraServiceError>) -> Void
    typealias MessageHandler = (String) -> Void

    let session = AVCaptureSession()

    private let sessionQueue = DispatchQueue(label: "com.pocketpixels.camera-session")
    private let photoOutput = AVCapturePhotoOutput()
    private var videoDevice: AVCaptureDevice?
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var currentPreviewRotationAngle: CGFloat = 0
    private weak var previewLayer: AVCaptureVideoPreviewLayer?
    private var isConfigured = false
    private var isConfiguring = false
    private var isCaptureInProgress = false
    private var activePhotoDelegate: PhotoCaptureDelegate?
    private var notificationTokens: [NSObjectProtocol] = []

    var onSessionMessage: MessageHandler?

    override init() {
        super.init()
        observeSessionNotifications()
    }

    deinit {
        for token in notificationTokens {
            NotificationCenter.default.removeObserver(token)
        }
        stopSession()
    }

    func authorizationStatus() -> AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .video)
    }

    func requestAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .video) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    func configureAndStart(completion: @escaping Completion) {
        sessionQueue.async {
            if self.session.isRunning {
                self.completeOnMain(.success(()), completion: completion)
                return
            }

            do {
                try self.configureSessionIfNeeded()
                self.session.startRunning()
                self.completeOnMain(.success(()), completion: completion)
            } catch let error as CameraServiceError {
                self.completeOnMain(.failure(error), completion: completion)
            } catch {
                self.completeOnMain(.failure(.configurationFailed(error.localizedDescription)), completion: completion)
            }
        }
    }

    func stopSession() {
        sessionQueue.async {
            if self.session.isRunning {
                self.session.stopRunning()
            }
        }
    }

    func capturePhoto(completion: @escaping PhotoCompletion) {
        sessionQueue.async {
            guard !self.isCaptureInProgress else {
                self.completePhotoOnMain(.failure(.captureInProgress), completion: completion)
                return
            }

            guard self.isConfigured else {
                self.completePhotoOnMain(.failure(.configurationFailed("The camera session has not started.")), completion: completion)
                return
            }

            self.isCaptureInProgress = true
            self.applyPhotoRotationAndMirroring()

            let settings = AVCapturePhotoSettings()

            DispatchQueue.main.async {
                let delegate = PhotoCaptureDelegate { result in
                    self.sessionQueue.async {
                        self.isCaptureInProgress = false

                        DispatchQueue.main.async {
                            self.activePhotoDelegate = nil
                            completion(result)
                        }
                    }
                }

                self.activePhotoDelegate = delegate
                self.photoOutput.capturePhoto(with: settings, delegate: delegate)
            }
        }
    }

    private func configureSessionIfNeeded() throws {
        guard !isConfigured else {
            return
        }

        guard !isConfiguring else {
            throw CameraServiceError.configurationFailed("Camera configuration is already in progress.")
        }

        isConfiguring = true
        defer { isConfiguring = false }

        guard let camera = Self.preferredFrontCamera() else {
            throw CameraServiceError.cameraUnavailable
        }

        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: camera)
        } catch {
            throw CameraServiceError.configurationFailed(error.localizedDescription)
        }

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        session.sessionPreset = .photo

        guard session.canAddInput(input) else {
            throw CameraServiceError.configurationFailed("The front camera input is not available.")
        }

        guard session.canAddOutput(photoOutput) else {
            throw CameraServiceError.configurationFailed("The photo output is not available.")
        }

        session.addInput(input)
        session.addOutput(photoOutput)
        photoOutput.maxPhotoQualityPrioritization = .balanced

        videoDevice = camera

        if let previewLayer {
            rotationCoordinator = AVCaptureDevice.RotationCoordinator(device: camera, previewLayer: previewLayer)
        } else {
            rotationCoordinator = AVCaptureDevice.RotationCoordinator(device: camera, previewLayer: nil)
        }

        applyPhotoRotationAndMirroring()
        isConfigured = true
    }

    private static func preferredFrontCamera() -> AVCaptureDevice? {
        if let trueDepth = AVCaptureDevice.default(.builtInTrueDepthCamera, for: .video, position: .front) {
            return trueDepth
        }

        return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
    }

    @MainActor
    private func applyPreviewRotation() {
        guard let previewLayer else {
            return
        }

        let angle = rotationCoordinator?.videoRotationAngleForHorizonLevelPreview ?? 0
        currentPreviewRotationAngle = angle

        guard let connection = previewLayer.connection else {
            return
        }

        if connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle
        }

        connection.automaticallyAdjustsVideoMirroring = false
        if connection.isVideoMirroringSupported {
            connection.isVideoMirrored = true
        }
    }

    private func applyPhotoRotationAndMirroring() {
        guard let connection = photoOutput.connection(with: .video) else {
            return
        }

        let angle = currentPreviewRotationAngle

        if connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle
        }

        connection.automaticallyAdjustsVideoMirroring = false
        if connection.isVideoMirroringSupported {
            connection.isVideoMirrored = true
        }
    }

    @MainActor
    func attachPreviewLayer(_ layer: AVCaptureVideoPreviewLayer) {
        previewLayer = layer

        if let videoDevice {
            rotationCoordinator = AVCaptureDevice.RotationCoordinator(device: videoDevice, previewLayer: layer)
        }

        applyPreviewRotation()
    }

    private func observeSessionNotifications() {
        let center = NotificationCenter.default

        notificationTokens.append(
            center.addObserver(
                forName: AVCaptureSession.wasInterruptedNotification,
                object: session,
                queue: .main
            ) { [weak self] notification in
                self?.onSessionMessage?(Self.interruptionMessage(from: notification))
            }
        )

        notificationTokens.append(
            center.addObserver(
                forName: AVCaptureSession.interruptionEndedNotification,
                object: session,
                queue: .main
            ) { [weak self] _ in
                self?.onSessionMessage?("Camera session resumed.")
            }
        )

        notificationTokens.append(
            center.addObserver(
                forName: AVCaptureSession.runtimeErrorNotification,
                object: session,
                queue: .main
            ) { [weak self] notification in
                let error = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError
                self?.onSessionMessage?("Camera session error: \(error?.localizedDescription ?? "Unknown error")")
            }
        )
    }

    private static func interruptionMessage(from notification: Notification) -> String {
        guard let reasonValue = notification.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int,
              let reason = AVCaptureSession.InterruptionReason(rawValue: reasonValue) else {
            return "Camera session was interrupted."
        }

        switch reason {
        case .videoDeviceNotAvailableInBackground:
            return "Camera paused while the app is in the background."
        case .audioDeviceInUseByAnotherClient, .videoDeviceInUseByAnotherClient:
            return "Camera is currently in use by another app."
        case .videoDeviceNotAvailableWithMultipleForegroundApps:
            return "Camera is unavailable while another app is sharing the screen."
        case .videoDeviceNotAvailableDueToSystemPressure:
            return "Camera is temporarily unavailable due to system pressure."
        default:
            return "Camera session was interrupted."
        }
    }

    private func completeOnMain(_ result: Result<Void, CameraServiceError>, completion: @escaping Completion) {
        DispatchQueue.main.async {
            completion(result)
        }
    }

    private func completePhotoOnMain(_ result: Result<UIImage, CameraServiceError>, completion: @escaping PhotoCompletion) {
        DispatchQueue.main.async {
            completion(result)
        }
    }
}

private final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    private let completion: (Result<UIImage, CameraServiceError>) -> Void

    init(completion: @escaping (Result<UIImage, CameraServiceError>) -> Void) {
        self.completion = completion
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        if let error {
            completion(.failure(.captureFailed(error.localizedDescription)))
            return
        }

        guard let data = photo.fileDataRepresentation(),
              let image = UIImage(data: data) else {
            completion(.failure(.captureFailed("The captured photo data could not be read.")))
            return
        }

        completion(.success(image))
    }
}
