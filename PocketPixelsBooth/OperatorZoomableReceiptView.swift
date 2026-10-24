//
//  OperatorZoomableReceiptView.swift
//  PocketPixelsBooth
//
//  Display-only receipt inspector for operator screens. The whole receipt fits the viewport by
//  default (top and bottom visible together, aspect preserved, no crop); pinch, pan, double-tap
//  and accessibility adjustments inspect details. Zoom is relative to
//  the Fit scale, so they behave the same for a short Solo and a very long Grid Six.
//
//  Zooming only changes a UIScrollView transform. It never re-renders, recomposes, rasterizes,
//  archives or prints anything, and it never touches the image bytes.
//

import Combine
import SwiftUI
import UIKit

struct OperatorZoomableReceiptView: View {
    /// How the receipt pixels are magnified.
    enum Rendering {
        /// The exact 1-bit printer raster: nearest-neighbour, so every dot stays a crisp square.
        case exactRaster
        /// A smooth digital receipt preview: high-quality interpolation.
        case smooth
    }

    let image: UIImage
    var rendering: Rendering = .smooth
    var accessibilityLabel: String = "Receipt preview"

    @StateObject private var controller = ZoomController()

    static let maximumZoom: CGFloat = 4

    var body: some View {
        VStack(spacing: 8) {
            ZoomableImageScrollView(image: image, rendering: rendering, controller: controller)
                .background(Color(white: 0.93))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay { RoundedRectangle(cornerRadius: 10).stroke(MadeToKeepTheme.ColorPalette.hairline) }
                .accessibilityElement()
                .accessibilityLabel(accessibilityLabel)
                .accessibilityIdentifier("operator-receipt-preview")
                .accessibilityValue("Zoom \(controller.percentText)")
                .accessibilityHint("Pinch or double-tap to zoom. Swipe up or down with one finger to change zoom.")
                .accessibilityAction(named: "Fit whole receipt") { controller.zoom(to: 1) }
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: controller.zoom(to: min(Self.maximumZoom, controller.relativeZoom + 0.5))
                    case .decrement: controller.zoom(to: max(1, controller.relativeZoom - 0.5))
                    @unknown default: break
                    }
                }
        }
    }

}

/// Bridges accessibility zoom adjustments to the scroll view. Zoom is reported relative to the Fit scale.
@MainActor
final class ZoomController: ObservableObject {
    @Published private(set) var relativeZoom: CGFloat = 1
    weak var scrollView: ReceiptZoomScrollView?

    var percentText: String { "\(Int((relativeZoom * 100).rounded()))%" }

    func zoom(to relative: CGFloat, animated: Bool = true) {
        scrollView?.zoom(toRelative: relative, animated: animated)
    }

    fileprivate func report(_ relative: CGFloat) {
        let rounded = (relative * 100).rounded() / 100
        if abs(rounded - relativeZoom) > 0.001 { relativeZoom = rounded }
    }
}

private struct ZoomableImageScrollView: UIViewRepresentable {
    let image: UIImage
    let rendering: OperatorZoomableReceiptView.Rendering
    let controller: ZoomController

    func makeUIView(context: Context) -> ReceiptZoomScrollView {
        let view = ReceiptZoomScrollView()
        view.onZoomChange = { [weak controller] relative in controller?.report(relative) }
        controller.scrollView = view
        view.display(image, rendering: rendering)
        return view
    }

    func updateUIView(_ view: ReceiptZoomScrollView, context: Context) {
        controller.scrollView = view
        if view.imageView.image !== image || view.rendering != rendering {
            view.display(image, rendering: rendering)
        }
    }
}

/// UIScrollView owns pinch and pan natively. At Fit its pan is disabled so surrounding scroll
/// views and navigation keep working; it turns on only while zoomed in.
final class ReceiptZoomScrollView: UIScrollView, UIScrollViewDelegate {
    let imageView = UIImageView()
    private(set) var rendering: OperatorZoomableReceiptView.Rendering = .smooth
    var onZoomChange: ((CGFloat) -> Void)?
    /// The scale at which the whole receipt is visible.
    private(set) var fitScale: CGFloat = 1
    private var lastBoundsSize: CGSize = .zero
    private var pendingRelative: CGFloat = 1

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        showsHorizontalScrollIndicator = true
        showsVerticalScrollIndicator = true
        bouncesZoom = true
        decelerationRate = .fast
        contentInsetAdjustmentBehavior = .never
        imageView.contentMode = .scaleToFill
        imageView.backgroundColor = .white
        imageView.layer.borderColor = UIColor(white: 0.78, alpha: 1).cgColor
        imageView.layer.borderWidth = 0.5
        addSubview(imageView)
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func display(_ image: UIImage, rendering: OperatorZoomableReceiptView.Rendering) {
        self.rendering = rendering
        setZoomScale(1, animated: false)
        imageView.transform = .identity
        imageView.image = image
        imageView.layer.magnificationFilter = rendering == .exactRaster ? .nearest : .linear
        imageView.layer.minificationFilter = .trilinear
        imageView.frame = CGRect(origin: .zero, size: image.size)
        contentSize = image.size
        lastBoundsSize = .zero
        pendingRelative = 1
        setNeedsLayout()
    }

    /// Fit = the largest scale at which the whole receipt is visible. Recomputed on rotation or
    /// resize while keeping the operator's relative zoom.
    override func layoutSubviews() {
        super.layoutSubviews()
        guard let image = imageView.image, image.size.width > 0, image.size.height > 0,
              bounds.width > 1, bounds.height > 1 else { return }
        if bounds.size != lastBoundsSize {
            let relative = lastBoundsSize == .zero ? pendingRelative : zoomScale / max(fitScale, 0.0001)
            lastBoundsSize = bounds.size
            fitScale = min(bounds.width / image.size.width, bounds.height / image.size.height)
            minimumZoomScale = fitScale
            maximumZoomScale = fitScale * OperatorZoomableReceiptView.maximumZoom
            zoomScale = fitScale * min(max(1, relative), OperatorZoomableReceiptView.maximumZoom)
            if relative <= 1.001 { contentOffset = .zero }
        }
        centerContent()
        updatePanAvailability()
    }

    func zoom(toRelative relative: CGFloat, animated: Bool, around point: CGPoint? = nil) {
        guard fitScale > 0, imageView.image != nil else {
            pendingRelative = relative
            return
        }
        let target = fitScale * min(max(1, relative), OperatorZoomableReceiptView.maximumZoom)
        if relative <= 1.001 {
            setZoomScale(fitScale, animated: animated)
            return
        }
        // Zoom around the requested point (double-tap) or the current visible centre.
        let anchor = point ?? CGPoint(
            x: (contentOffset.x + bounds.width / 2) / zoomScale,
            y: (contentOffset.y + bounds.height / 2) / zoomScale
        )
        let size = CGSize(width: bounds.width / target, height: bounds.height / target)
        zoom(to: CGRect(x: anchor.x - size.width / 2, y: anchor.y - size.height / 2, width: size.width, height: size.height), animated: animated)
    }

    @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
        if zoomScale > fitScale * 1.05 {
            zoom(toRelative: 1, animated: true)
        } else {
            zoom(toRelative: 2, animated: true, around: recognizer.location(in: imageView))
        }
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerContent()
        updatePanAvailability()
        onZoomChange?(zoomScale / max(fitScale, 0.0001))
    }

    /// Centres a receipt smaller than the viewport instead of pinning it to the top-left.
    private func centerContent() {
        let horizontal = max(0, (bounds.width - contentSize.width) / 2)
        let vertical = max(0, (bounds.height - contentSize.height) / 2)
        imageView.center = CGPoint(x: contentSize.width / 2 + horizontal, y: contentSize.height / 2 + vertical)
    }

    private func updatePanAvailability() {
        panGestureRecognizer.isEnabled = zoomScale > fitScale * 1.01
    }
}
