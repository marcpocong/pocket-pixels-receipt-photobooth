//
//  CameraPreview.swift
//  PocketPixelsBooth
//
//  Created by marc on 8/30/26.
//

import AVFoundation
import SwiftUI
import UIKit

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let cameraService: CameraService

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.backgroundColor = .black
        view.previewLayer.videoGravity = .resizeAspectFill
        view.previewLayer.session = session
        view.onLayout = { layer in
            cameraService.attachPreviewLayer(layer)
        }
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.previewLayer.session = session
        uiView.previewLayer.videoGravity = .resizeAspectFill
        uiView.onLayout = { layer in
            cameraService.attachPreviewLayer(layer)
        }
        cameraService.attachPreviewLayer(uiView.previewLayer)
    }

    final class PreviewView: UIView {
        var onLayout: ((AVCaptureVideoPreviewLayer) -> Void)?

        override class var layerClass: AnyClass {
            AVCaptureVideoPreviewLayer.self
        }

        var previewLayer: AVCaptureVideoPreviewLayer {
            layer as! AVCaptureVideoPreviewLayer
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            onLayout?(previewLayer)
        }
    }
}
