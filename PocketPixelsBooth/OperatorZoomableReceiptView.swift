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

nonisolated enum ReceiptPreviewFocus: String, CaseIterable, Identifiable {
    case header = "Header", full = "Full Receipt", footer = "Footer"
    var id: Self { self }
}

struct OperatorZoomableReceiptView: View {
    /// How the receipt pixels are magnified.
    enum Rendering {
        /// The exact 1-bit printer raster: nearest-neighbour, so every dot stays a crisp square.
        case exactRaster
        /// A smooth digital receipt preview: high-quality interpolation.
        case smooth
    }

    enum Sizing { case wholeReceipt, fitWidth }

    let image: UIImage
    var sizing: Sizing = .wholeReceipt
    var focus: ReceiptPreviewFocus = .full
    var elementFrames: [CoBrandedHeaderTarget: CGRect] = [:]
    var selectedElement: CoBrandedHeaderTarget = .whole
    var onSelectElement: ((CoBrandedHeaderTarget) -> Void)? = nil
    var rendering: Rendering = .smooth
    var accessibilityLabel: String = "Receipt preview"

    @StateObject private var controller = ZoomController()

    static let maximumZoom: CGFloat = 4

    var body: some View {
        VStack(spacing: 8) {
            ZoomableImageScrollView(image: image, rendering: rendering, controller: controller, sizing: sizing, focus: focus, elementFrames: elementFrames, selectedElement: selectedElement, onSelectElement: onSelectElement)
                .background(Color(white: 0.93))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay { RoundedRectangle(cornerRadius: 10).stroke(MadeToKeepTheme.ColorPalette.hairline) }
                .accessibilityElement()
                .accessibilityLabel(accessibilityLabel)
                .accessibilityIdentifier("operator-receipt-preview")
                .accessibilityValue("Zoom \(controller.percentText)")
                .accessibilityHint("Pinch or double-tap to zoom. Swipe up or down with one finger to change zoom.")
                .accessibilityAction(named: sizing == .fitWidth ? "Fit receipt width" : "Fit whole receipt") { controller.zoom(to: 1) }
                .accessibilityAction(named: "Scroll receipt down") { controller.scroll(pages: 1) }
                .accessibilityAction(named: "Scroll receipt up") { controller.scroll(pages: -1) }
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

    func scroll(pages: CGFloat) {
        guard let view = scrollView else { return }
        let y = min(max(0, view.contentOffset.y + view.bounds.height * 0.8 * pages), max(0, view.contentSize.height - view.bounds.height))
        view.setContentOffset(CGPoint(x: view.contentOffset.x, y: y), animated: true)
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
    let sizing: OperatorZoomableReceiptView.Sizing
    let focus: ReceiptPreviewFocus
    let elementFrames: [CoBrandedHeaderTarget: CGRect]
    let selectedElement: CoBrandedHeaderTarget
    let onSelectElement: ((CoBrandedHeaderTarget) -> Void)?

    func makeUIView(context: Context) -> ReceiptZoomScrollView {
        let view = ReceiptZoomScrollView()
        view.onZoomChange = { [weak controller] relative in controller?.report(relative) }
        controller.scrollView = view
        updateUIView(view, context: context)
        return view
    }

    func updateUIView(_ view: ReceiptZoomScrollView, context: Context) {
        controller.scrollView = view
        view.sizing = sizing
        view.elementFrames = elementFrames
        view.selectedElement = selectedElement
        view.onSelectElement = onSelectElement
        if view.imageView.image !== image || view.rendering != rendering {
            view.display(image, rendering: rendering)
        }
        view.setFocus(focus)
    }
}

/// UIScrollView owns pinch and pan natively. Fit-width editors always allow vertical pan;
/// fit-whole inspectors defer to surrounding navigation until zoomed in.
final class ReceiptZoomScrollView: UIScrollView, UIScrollViewDelegate {
    let imageView = UIImageView()
    var sizing: OperatorZoomableReceiptView.Sizing = .wholeReceipt
    var elementFrames: [CoBrandedHeaderTarget: CGRect] = [:] { didSet { setNeedsLayout() } }
    var selectedElement: CoBrandedHeaderTarget = .whole { didSet { setNeedsLayout() } }
    var onSelectElement: ((CoBrandedHeaderTarget) -> Void)? { didSet { setNeedsLayout() } }
    private let selectionOutline = CAShapeLayer()
    private var focus: ReceiptPreviewFocus = .full
    private var needsFocus = true
    private var restoreOffset: CGPoint?

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
        let select = UITapGestureRecognizer(target: self, action: #selector(handleSelect(_:)))
        select.require(toFail: doubleTap)
        addGestureRecognizer(select)
        selectionOutline.fillColor = UIColor.clear.cgColor
        selectionOutline.strokeColor = UIColor.systemBlue.withAlphaComponent(0.7).cgColor
        selectionOutline.lineWidth = 2
        imageView.layer.addSublayer(selectionOutline)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func display(_ image: UIImage, rendering: OperatorZoomableReceiptView.Rendering) {
        let relative = sizing == .fitWidth ? zoomScale / max(fitScale, 0.0001) : 1
        let previousOffset = contentOffset
        self.rendering = rendering
        // Restore a neutral UIKit zoom coordinate system before replacing image dimensions.
        // The previous receipt may have had a maximum scale below 1 (a very long receipt).
        let callback = onZoomChange
        onZoomChange = nil
        maximumZoomScale = max(1, maximumZoomScale)
        minimumZoomScale = 1
        setZoomScale(1, animated: false)
        imageView.transform = .identity
        imageView.image = image
        imageView.layer.magnificationFilter = rendering == .exactRaster ? .nearest : .linear
        imageView.layer.minificationFilter = rendering == .exactRaster && sizing == .fitWidth ? .nearest : .trilinear
        imageView.frame = CGRect(origin: .zero, size: image.size)
        contentSize = image.size
        lastBoundsSize = .zero
        pendingRelative = max(1, relative)
        if sizing == .fitWidth { restoreOffset = previousOffset }
        onZoomChange = callback
        setNeedsLayout()
        // SwiftUI may be updating this representable. Publish the actual resulting zoom after
        // that update rather than changing observable state from inside updateUIView.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onZoomChange?(self.zoomScale / max(self.fitScale, 0.0001))
        }
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
            fitScale = sizing == .fitWidth ? bounds.width / image.size.width
                : min(bounds.width / image.size.width, bounds.height / image.size.height)
            minimumZoomScale = fitScale
            maximumZoomScale = fitScale * OperatorZoomableReceiptView.maximumZoom
            zoomScale = fitScale * min(max(1, relative), OperatorZoomableReceiptView.maximumZoom)
            if relative <= 1.001 { contentOffset = .zero }
        }
        centerContent()
        updatePanAvailability()
        if needsFocus && sizing == .fitWidth {
            needsFocus = false
            let bottom = max(0, contentSize.height - bounds.height)
            contentOffset = CGPoint(x: 0, y: focus == .footer ? bottom : 0)
        }
        if let offset = restoreOffset {
            restoreOffset = nil
            if !needsFocus && focus != .footer {
                contentOffset = CGPoint(x: min(max(0, offset.x), max(0, contentSize.width - bounds.width)),
                    y: min(max(0, offset.y), max(0, contentSize.height - bounds.height)))
            } else if focus == .footer { contentOffset.y = max(0, contentSize.height - bounds.height) }
        }
        updateSelection()
    }

    func setFocus(_ value: ReceiptPreviewFocus) {
        guard focus != value else { return }
        focus = value
        needsFocus = true
        if sizing == .fitWidth { zoom(toRelative: 1, animated: false) }
        setNeedsLayout()
    }

    private func updateSelection() {
        guard onSelectElement != nil, selectedElement != .whole, let rect = elementFrames[selectedElement] else {
            selectionOutline.path = nil; return
        }
        selectionOutline.path = UIBezierPath(roundedRect: rect.insetBy(dx: -3, dy: -3), cornerRadius: 3).cgPath
        selectionOutline.lineWidth = 1.5 / max(zoomScale, 0.001)
    }

    @objc private func handleSelect(_ recognizer: UITapGestureRecognizer) {
        let point = recognizer.location(in: imageView)
        if let target = CoBrandedHeaderTarget.allCases.first(where: { $0 != .whole && elementFrames[$0]?.contains(point) == true }) {
            onSelectElement?(target)
        }
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
        let vertical = sizing == .fitWidth ? 0 : max(0, (bounds.height - contentSize.height) / 2)
        imageView.center = CGPoint(x: contentSize.width / 2 + horizontal, y: contentSize.height / 2 + vertical)
    }

    private func updatePanAvailability() {
        panGestureRecognizer.isEnabled = sizing == .fitWidth || zoomScale > fitScale * 1.01
    }
}
