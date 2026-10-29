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
    case header = "Header", full = "Full Receipt", footer = "Footer", text = "Text"
    var id: Self { self }
}

/// Presentation metadata from the exact production plan. Never drawn into the receipt.
nonisolated enum ReceiptTextFocus: String, CaseIterable, Identifiable {
    case all = "Event Details", title = "Event Title", subtitle = "Subtitle", metadata = "Date & Location", message = "Message", caption = "Caption"
    var id: Self { self }
}

nonisolated struct ReceiptEditorGeometry: Sendable {
    var elements: [CoBrandedHeaderTarget: CGRect] = [:]
    var header: CGRect = .null
    var footer: CGRect = .null
    var footerIdentity = ""
    var text: [ReceiptTextFocus: CGRect] = [:]

    init(plan: ReceiptLayoutPlan) {
        func union(_ frames: [CGRect]) -> CGRect { frames.reduce(.null) { $0.union($1) } }
        let studio = union(plan.mastheadFrames)
        header = union(plan.mastheadFrames + [plan.customHeaderFrame, plan.coBrandSeparatorFrame].compactMap { $0 })
        if plan.coBrandSeparatorFrame != nil {
            elements = [.studio: studio, .whole: header]
            elements[.event] = plan.customHeaderFrame
            elements[.separator] = plan.coBrandSeparatorFrame
        }
        footer = union(plan.footerFrames + plan.captionFrames + plan.studioCreditFrames
            + [plan.qrRect, plan.eventSignatureFrame].compactMap { $0 } + [plan.sessionIdentifierFrame])
        footerIdentity = plan.footer.integratedQRFrame != nil ? "integrated-qr" : (plan.includesPrintedGalleryQR ? "barcode-qr" : "barcode")
        text[.all] = union(plan.eventTextFrames.map(\.rect))
        text[.caption] = union(plan.captionFrames)
        for (target, role) in [(ReceiptTextFocus.title, EventTextRole.title), (.subtitle, .subtitle), (.metadata, .metadata), (.message, .message)] {
            text[target] = union(plan.eventTextFrames.filter { $0.role == role }.map(\.rect))
        }
    }

    func region(focus: ReceiptPreviewFocus, target: CoBrandedHeaderTarget, textTarget: ReceiptTextFocus) -> CGRect? {
        var rect: CGRect
        switch focus {
        case .full: return nil
        case .footer: rect = footer.insetBy(dx: -20, dy: -24)
        case .text:
            guard let text = text[textTarget], !text.isNull else { return nil }
            rect = text.insetBy(dx: -20, dy: -32)
        case .header:
            rect = header
            // Keep the separator and enough of the neighboring identity to judge spacing.
            if let selected = elements[target], let cross = elements[.separator], target == .studio || target == .event {
                let neighbor = elements[target == .studio ? .event : .studio] ?? header
                let neighborCenter = CGRect(x: neighbor.midX - 12, y: neighbor.midY - 12, width: 24, height: 24)
                rect = selected.union(cross).union(neighborCenter).insetBy(dx: -24, dy: -16)
            } else { rect = rect.insetBy(dx: -20, dy: -16) }
            rect.size.height += 80 // beginning of the photograph
        }
        return rect.isNull || rect.isEmpty ? nil : rect
    }
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
    var focusRect: CGRect? = nil
    var focusIdentity: String = ""
    var showsSelection = true
    var showsFitControls = false
    @State private var fittedWidth = false
    var elementFrames: [CoBrandedHeaderTarget: CGRect] = [:]
    var selectedElement: CoBrandedHeaderTarget = .whole
    var onSelectElement: ((CoBrandedHeaderTarget) -> Void)? = nil
    var rendering: Rendering = .smooth
    var accessibilityLabel: String = "Receipt preview"

    @StateObject private var controller = ZoomController()

    static let maximumZoom: CGFloat = 4

    var body: some View {
        VStack(spacing: 8) {
            ZoomableImageScrollView(image: image, rendering: rendering, controller: controller, preservesViewportOnImageChange: showsFitControls, sizing: showsFitControls ? (fittedWidth ? .fitWidth : .wholeReceipt) : sizing, focus: focus, focusRect: focusRect, focusIdentity: focusIdentity, showsSelection: showsSelection, elementFrames: elementFrames, selectedElement: selectedElement, onSelectElement: onSelectElement)
                .background(Color(white: 0.93))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay { RoundedRectangle(cornerRadius: 10).stroke(MadeToKeepTheme.ColorPalette.hairline) }
                .accessibilityElement(children: .contain)
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
            if showsFitControls {
                HStack(spacing: 12) {
                    Button("Fit Full") { fittedWidth = false; controller.fit(.wholeReceipt) }
                        .accessibilityIdentifier("receipt-fit-full")
                    Button("Fit Width") { fittedWidth = true; controller.fit(.fitWidth) }
                        .accessibilityIdentifier("receipt-fit-width")
                    Spacer(minLength: 0)
                    Text(controller.percentText).monospacedDigit().foregroundStyle(.secondary)
                }.font(.callout).buttonStyle(.bordered).controlSize(.regular)
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

    func fit(_ sizing: OperatorZoomableReceiptView.Sizing) { scrollView?.fit(sizing) }

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
    let preservesViewportOnImageChange: Bool
    let sizing: OperatorZoomableReceiptView.Sizing
    let focus: ReceiptPreviewFocus
    let focusRect: CGRect?
    let focusIdentity: String
    let showsSelection: Bool
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
        view.preservesViewportOnImageChange = preservesViewportOnImageChange
        view.showsSelection = showsSelection
        view.elementFrames = elementFrames
        view.selectedElement = selectedElement
        view.onSelectElement = onSelectElement
        if view.imageView.image !== image || view.rendering != rendering {
            view.display(image, rendering: rendering)
        }
        view.setFocus(focus, rect: focusRect, identity: focusIdentity)
    }
}

/// UIScrollView owns pinch and pan natively. Fit-width editors always allow vertical pan;
/// fit-whole inspectors defer to surrounding navigation until zoomed in.
final class ReceiptZoomScrollView: UIScrollView, UIScrollViewDelegate {
    let imageView = UIImageView()
    var sizing: OperatorZoomableReceiptView.Sizing = .wholeReceipt {
        didSet { if oldValue != sizing { fit(sizing) } }
    }
    var preservesViewportOnImageChange = false
    var elementFrames: [CoBrandedHeaderTarget: CGRect] = [:] { didSet { setNeedsLayout() } }
    var selectedElement: CoBrandedHeaderTarget = .whole { didSet { setNeedsLayout() } }
    var onSelectElement: ((CoBrandedHeaderTarget) -> Void)? { didSet { setNeedsLayout() } }
    var showsSelection = true
    private let selectionOutline = CAShapeLayer()
    private var accessibleTargets: [CoBrandedHeaderTarget: ReceiptElementAccessibility] = [:]
    private var focus: ReceiptPreviewFocus = .full
    private var focusRect: CGRect?
    private var focusIdentity = ""
    private var needsFocus = true
    private var geometryChanged = false
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
        let preservesViewport = sizing == .fitWidth || preservesViewportOnImageChange
        let relative = preservesViewport && imageView.image != nil ? zoomScale / max(fitScale, 0.0001) : 1
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
        restoreOffset = preservesViewport ? previousOffset : nil
        onZoomChange = callback
        setNeedsLayout()
        // SwiftUI may be updating this representable. Publish the actual resulting zoom after
        // that update rather than changing observable state from inside updateUIView.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onZoomChange?(self.zoomScale / max(self.fitScale, 0.0001))
        }
    }

    /// Explicit operator viewport action, independent of selection and design geometry.
    func fit(_ mode: OperatorZoomableReceiptView.Sizing) {
        if sizing != mode { sizing = mode; return }
        lastBoundsSize = .zero; pendingRelative = 1; restoreOffset = nil
        needsFocus = false; geometryChanged = false
        contentOffset = .zero; setNeedsLayout()
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
            restoreOffset = nil
            if let rect = focusRect {
                let scale = min(bounds.width / rect.width, bounds.height / rect.height)
                setZoomScale(min(max(fitScale, scale), maximumZoomScale), animated: false)
                position(on: rect)
            } else {
                setZoomScale(fitScale, animated: false)
                contentOffset = CGPoint(x: 0, y: focus == .footer ? max(0, contentSize.height - bounds.height) : 0)
            }
        } else if let offset = restoreOffset {
            restoreOffset = nil
            contentOffset = clamped(offset)
        }
        if geometryChanged, sizing == .fitWidth, focus != .full, let rect = focusRect {
            geometryChanged = false
            // Ordinary edits keep the operator's zoom and pan unless the target leaves view.
            let visible = CGRect(origin: contentOffset, size: bounds.size)
            let anchor = focus == .header ? (elementFrames[selectedElement] ?? rect) : rect
            let center = CGPoint(x: anchor.midX * zoomScale, y: anchor.midY * zoomScale)
            if !visible.insetBy(dx: 16, dy: 16).contains(center) { position(on: anchor) }
        }
        updateSelection()
    }

    func setFocus(_ value: ReceiptPreviewFocus, rect: CGRect? = nil, identity: String = "") {
        if focus != value || focusIdentity != identity { needsFocus = true }
        geometryChanged = geometryChanged || focusRect != rect
        focus = value
        focusRect = rect
        focusIdentity = identity
        setNeedsLayout()
    }

    private func clamped(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(0, point.x), max(0, contentSize.width - bounds.width)),
                y: min(max(0, point.y), max(0, contentSize.height - bounds.height)))
    }

    private func position(on rect: CGRect) {
        contentOffset = clamped(CGPoint(x: rect.midX * zoomScale - bounds.width / 2,
                                       y: rect.midY * zoomScale - bounds.height / 2))
    }

    private func updateSelection() {
        var visibleTargets: [ReceiptElementAccessibility] = []
        if onSelectElement != nil {
            for target in [CoBrandedHeaderTarget.studio, .separator, .event] {
                guard let rect = elementFrames[target], !rect.isNull else { continue }
                let element = accessibleTargets[target] ?? ReceiptElementAccessibility(accessibilityContainer: self)
                accessibleTargets[target] = element
                element.accessibilityLabel = target.rawValue + " in receipt preview"
                element.accessibilityIdentifier = "receipt-preview-element-" + String(describing: target)
                element.accessibilityTraits = showsSelection && target == selectedElement ? [.button, .selected] : [.button]
                element.accessibilityFrame = UIAccessibility.convertToScreenCoordinates(rect, in: imageView)
                    .intersection(UIAccessibility.convertToScreenCoordinates(bounds, in: self))
                element.activate = { [weak self] in self?.onSelectElement?(target) }
                if imageView.convert(rect, to: self).intersects(bounds) { visibleTargets.append(element) }
            }
        }
        accessibilityElements = visibleTargets.isEmpty ? nil : visibleTargets
        guard showsSelection, onSelectElement != nil, let rect = elementFrames[selectedElement] else {
            selectionOutline.path = nil; return
        }
        selectionOutline.path = UIBezierPath(roundedRect: rect.insetBy(dx: -3, dy: -3), cornerRadius: 3).cgPath
        selectionOutline.lineWidth = 1.5 / max(zoomScale, 0.001)
    }

    @objc private func handleSelect(_ recognizer: UITapGestureRecognizer) {
        let point = recognizer.location(in: imageView)
        if let target = hitTarget(at: point) { onSelectElement?(target) }
    }

    /// UIKit converts through zoom, image transforms and scroll offset before this hit test.
    /// Exact artwork wins; expanded small targets use nearest center to resolve overlaps.
    func hitTarget(at point: CGPoint) -> CoBrandedHeaderTarget? {
        let targets = CoBrandedHeaderTarget.allCases.filter { $0 != .whole && elementFrames[$0] != nil }
        if let exact = targets.filter({ elementFrames[$0]!.contains(point) })
            .min(by: { elementFrames[$0]!.width * elementFrames[$0]!.height < elementFrames[$1]!.width * elementFrames[$1]!.height }) { return exact }
        let side = 44 / max(zoomScale, 0.001)
        return targets.filter { target in
            let rect = elementFrames[target]!
            return rect.insetBy(dx: -max(0, (side - rect.width) / 2), dy: -max(0, (side - rect.height) / 2)).contains(point)
        }.min { a, b in
            let x = elementFrames[a]!, y = elementFrames[b]!
            return hypot(point.x - x.midX, point.y - x.midY) < hypot(point.x - y.midX, point.y - y.midY)
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
        let relative = zoomScale / max(fitScale, 0.0001)
        DispatchQueue.main.async { [weak self] in self?.onZoomChange?(relative) }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) { updateSelection() }

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

private final class ReceiptElementAccessibility: UIAccessibilityElement {
    var activate: (() -> Void)?
    override func accessibilityActivate() -> Bool { activate?(); return activate != nil }
}
