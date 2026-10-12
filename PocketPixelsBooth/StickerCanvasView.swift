//
//  StickerCanvasView.swift
//  PocketPixelsBooth
//
//  The guest's live editing canvas: the real undecorated receipt with stickers drawn through
//  the same StickerGeometry transform the printer uses, clipped to the same safe regions.
//  Gestures act on the canvas (not on individual stickers) so even a tiny sticker can be
//  pinched or rotated, and drag/pinch/twist work together without fighting a scroll view.
//

import SwiftUI
import UIKit

struct StickerCanvasView: View {
    let session: StickerStudioSession
    /// Points per printer dot.
    let displayScale: CGFloat
    let onActivity: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var activeID: UUID?
    @State private var translation: CGSize = .zero
    @State private var magnification: CGFloat = 1
    @State private var rotation: Double = 0
    @State private var isDragging = false
    @State private var isMagnifying = false
    @State private var isRotating = false

    private var canvasSize: CGSize {
        guard let layout = session.layout else { return .zero }
        return CGSize(width: CGFloat(layout.canvasWidth) * displayScale, height: CGFloat(layout.editorVisibleHeight) * displayScale)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let image = session.canvasImage {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: canvasSize.width, height: canvasSize.height)
                    .accessibilityLabel("Your receipt photos")
            }

            if let selected = displayed(session.selectedPlacement),
               let region = session.layout?.region(for: selected.target) {
                regionOutline(region)
            }

            ForEach(session.placements.sorted { $0.zOrder < $1.zOrder }) { placement in
                stickerLayer(displayed(placement) ?? placement)
            }

            if let selected = displayed(session.selectedPlacement) {
                selectionChrome(for: selected)
            }
        }
        .frame(width: canvasSize.width, height: canvasSize.height, alignment: .topLeading)
        .background(Color.white)
        .clipped()
        .contentShape(Rectangle())
        .gesture(tapGesture)
        .simultaneousGesture(dragGesture)
        .simultaneousGesture(magnifyGesture)
        .simultaneousGesture(rotateGesture)
        .overlay {
            Rectangle().strokeBorder(MadeToKeepTheme.ColorPalette.hairline, lineWidth: 1)
        }
        .shadow(color: MadeToKeepTheme.ColorPalette.amberGlow.opacity(0.14), radius: 18, x: 0, y: 8)
    }

    // MARK: Rendering

    /// The placement as currently shown: committed state plus any live gesture.
    private func displayed(_ placement: StickerPlacement?) -> StickerPlacement? {
        guard let placement else { return nil }
        guard placement.id == activeID else { return placement }
        return session.previewPlacement(placement.id, translation: translation, magnification: magnification, rotation: rotation, displayScale: displayScale) ?? placement
    }

    private func resolvedFrame(_ placement: StickerPlacement) -> StickerResolvedFrame? {
        guard let region = session.layout?.region(for: placement.target),
              let frame = try? StickerGeometry.resolve(placement, in: region) else { return nil }
        return frame.display(scale: displayScale)
    }

    @ViewBuilder
    private func stickerLayer(_ placement: StickerPlacement) -> some View {
        if let frame = resolvedFrame(placement), let artwork = session.artwork[placement.id] {
            clippedSticker(artwork: artwork, frame: frame)
                .modifier(StickerAccessibilityActions(
                    name: placement.assetName,
                    isSelected: placement.id == session.selectedPlacementID,
                    onSelect: { session.select(placement.id) },
                    onNudge: { translation, magnification, rotation in
                        nudge(placement.id, translation: translation, magnification: magnification, rotation: rotation)
                    },
                    onDelete: { session.delete(placement.id) }
                ))
        }
    }

    private func clippedSticker(artwork: CGImage, frame: StickerResolvedFrame) -> some View {
        let clip = frame.clipRect
        return Image(uiImage: UIImage(cgImage: artwork))
            .resizable()
            .interpolation(.high)
            .frame(width: frame.size.width, height: frame.size.height)
            .rotationEffect(.radians(Double(frame.rotation)))
            .position(frame.center)
            .frame(width: canvasSize.width, height: canvasSize.height, alignment: .topLeading)
            // Same clip as the printed receipt: ink never leaves the approved region.
            .mask { Path(clip) }
            .allowsHitTesting(false)
    }

    private func regionOutline(_ region: StickerTargetRegion) -> some View {
        let clip = region.clipRect
        return Rectangle()
            .strokeBorder(MadeToKeepTheme.ColorPalette.burgundy.opacity(0.35), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
            .frame(width: clip.width * displayScale, height: clip.height * displayScale)
            .offset(x: clip.minX * displayScale, y: clip.minY * displayScale)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /// Selection border and a delete button that stays on-canvas even for tiny or edge stickers.
    @ViewBuilder
    private func selectionChrome(for placement: StickerPlacement) -> some View {
        if let frame = resolvedFrame(placement) {
            let chromeSize = CGSize(width: max(frame.size.width, 44) + 12, height: max(frame.size.height, 44) + 12)
            Rectangle()
                .strokeBorder(MadeToKeepTheme.ColorPalette.burgundy, style: StrokeStyle(lineWidth: 2.5, dash: [8, 5]))
                .frame(width: chromeSize.width, height: chromeSize.height)
                .rotationEffect(.radians(Double(frame.rotation)))
                .position(frame.center)
                .allowsHitTesting(false)
                .accessibilityHidden(true)

            Button {
                session.delete(placement.id)
                onActivity()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(MadeToKeepTheme.ColorPalette.ivoryLight)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(MadeToKeepTheme.ColorPalette.burgundy))
                    .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                    .frame(width: 52, height: 52)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .position(deleteButtonPosition(frame: frame, chromeSize: chromeSize))
            .accessibilityLabel("Delete \(placement.assetName) sticker")
        }
    }

    private func deleteButtonPosition(frame: StickerResolvedFrame, chromeSize: CGSize) -> CGPoint {
        let half = CGSize(width: chromeSize.width / 2, height: chromeSize.height / 2)
        let cosine = cos(frame.rotation), sine = sin(frame.rotation)
        let corner = CGPoint(
            x: frame.center.x + half.width * cosine + half.height * sine,
            y: frame.center.y + half.width * sine - half.height * cosine
        )
        let inset: CGFloat = 26
        return CGPoint(
            x: min(max(corner.x, inset), max(inset, canvasSize.width - inset)),
            y: min(max(corner.y, inset), max(inset, canvasSize.height - inset))
        )
    }

    // MARK: Gestures

    private var tapGesture: some Gesture {
        SpatialTapGesture()
            .onEnded { value in
                let hit = session.placement(at: value.location, displayScale: displayScale)
                if let hit {
                    session.select(hit.id)
                    session.bringToFront(hit.id)
                } else {
                    session.select(nil)
                }
                onActivity()
            }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .local)
            .onChanged { value in
                if !isDragging {
                    isDragging = true
                    // A drag that starts on a sticker picks it up; empty paper does nothing.
                    guard let hit = session.placement(at: value.startLocation, displayScale: displayScale) else {
                        return
                    }
                    beginGesture(on: hit.id)
                }
                guard activeID != nil else { return }
                translation = value.translation
                onActivity()
            }
            .onEnded { value in
                defer { isDragging = false }
                guard let id = activeID else { return }
                session.commitGesture(id, translation: value.translation, magnification: 1, rotation: 0, displayScale: displayScale)
                translation = .zero
                endGestureIfIdle()
            }
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if !isMagnifying {
                    isMagnifying = true
                    guard let id = session.placement(at: value.startLocation, displayScale: displayScale)?.id ?? session.selectedPlacementID else { return }
                    beginGesture(on: id)
                }
                guard activeID != nil else { return }
                magnification = value.magnification
                onActivity()
            }
            .onEnded { value in
                defer { isMagnifying = false }
                guard let id = activeID else { return }
                session.commitGesture(id, translation: .zero, magnification: value.magnification, rotation: 0, displayScale: displayScale)
                magnification = 1
                endGestureIfIdle()
            }
    }

    private var rotateGesture: some Gesture {
        RotateGesture()
            .onChanged { value in
                if !isRotating {
                    isRotating = true
                    guard let id = session.placement(at: value.startLocation, displayScale: displayScale)?.id ?? session.selectedPlacementID else { return }
                    beginGesture(on: id)
                }
                guard activeID != nil else { return }
                rotation = value.rotation.radians
                onActivity()
            }
            .onEnded { value in
                defer { isRotating = false }
                guard let id = activeID else { return }
                session.commitGesture(id, translation: .zero, magnification: 1, rotation: value.rotation.radians, displayScale: displayScale)
                rotation = 0
                endGestureIfIdle()
            }
    }

    private func beginGesture(on id: UUID) {
        if activeID == nil || activeID == id {
            activeID = id
            session.select(id)
        }
    }

    /// Clears the live sticker once every simultaneous gesture has ended.
    private func endGestureIfIdle() {
        let stillActive = [isDragging && translation != .zero, isMagnifying && magnification != 1, isRotating && rotation != 0]
        if !stillActive.contains(true) || (translation == .zero && magnification == 1 && rotation == 0) {
            activeID = nil
        }
    }

    private func nudge(_ id: UUID, translation: CGSize = .zero, magnification: CGFloat = 1, rotation: Double = 0) {
        session.select(id)
        session.commitGesture(id, translation: translation, magnification: magnification, rotation: rotation, displayScale: displayScale)
        onActivity()
    }
}

/// VoiceOver alternatives to drag, pinch and twist.
private struct StickerAccessibilityActions: ViewModifier {
    let name: String
    let isSelected: Bool
    let onSelect: () -> Void
    let onNudge: (CGSize, CGFloat, Double) -> Void
    let onDelete: () -> Void

    func body(content: Content) -> some View {
        content
            .accessibilityElement()
            .accessibilityLabel(Text(name + " sticker"))
            .accessibilityValue(Text(isSelected ? "Selected" : ""))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { onSelect() }
            .accessibilityAction(named: Text("Make bigger")) { onNudge(.zero, 1.15, 0) }
            .accessibilityAction(named: Text("Make smaller")) { onNudge(.zero, 0.87, 0) }
            .accessibilityAction(named: Text("Rotate")) { onNudge(.zero, 1, Double.pi / 12) }
            .accessibilityAction(named: Text("Move left")) { onNudge(CGSize(width: -20, height: 0), 1, 0) }
            .accessibilityAction(named: Text("Move right")) { onNudge(CGSize(width: 20, height: 0), 1, 0) }
            .accessibilityAction(named: Text("Move up")) { onNudge(CGSize(width: 0, height: -20), 1, 0) }
            .accessibilityAction(named: Text("Move down")) { onNudge(CGSize(width: 0, height: 20), 1, 0) }
            .accessibilityAction(named: Text("Delete")) { onDelete() }
    }
}
