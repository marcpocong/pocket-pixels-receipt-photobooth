//
//  SessionMotionPreview.swift
//  PocketPixelsBooth
//
//  "Your moments in motion": the guest's own photos played in session order on the iPad, using
//  the same frame interval and uncropped ivory canvas as the downloadable session GIF. It is a
//  lightweight timed sequence of small, pre-scaled frames; no GIF is encoded for the preview.
//  Solo sessions have no motion, matching the gallery (which never receives a one-frame GIF).
//

import SwiftUI
import UIKit

nonisolated enum SessionMotionPreview {
    /// Frames shorter than this are not worth animating: Solo shows its still photo.
    static let minimumFrameCount = 2
    static var frameInterval: TimeInterval { SessionGIFRenderer.frameDelay }
    /// Preview frames are small: they only fill a modest on-screen tile.
    static let frameLongestSide: CGFloat = 640

    static func isAvailable(format: BoothFormat?, photoCount: Int) -> Bool {
        guard let format, format.photoCount >= minimumFrameCount else { return false }
        return photoCount == format.photoCount
    }

    /// The frame shown at `date` for a sequence that started at `start`.
    static func frameIndex(at date: Date, start: Date, frameCount: Int) -> Int {
        guard frameCount > 0 else { return 0 }
        let elapsed = max(0, date.timeIntervalSince(start))
        return Int(elapsed / frameInterval) % frameCount
    }

    /// Square, aspect-fit frames on the GIF's ivory canvas, in the original photo order. Mixed
    /// portrait and landscape photos share one coherent frame without cropping faces.
    static func makeFrames(from photos: [UIImage], side: CGFloat = frameLongestSide) -> [UIImage] {
        let size = CGSize(width: side, height: side)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return photos.compactMap { photo in
            guard photo.size.width > 0, photo.size.height > 0 else { return nil }
            let scale = min(side / photo.size.width, side / photo.size.height)
            let drawSize = CGSize(width: floor(photo.size.width * scale), height: floor(photo.size.height * scale))
            let rect = CGRect(x: floor((side - drawSize.width) / 2), y: floor((side - drawSize.height) / 2), width: drawSize.width, height: drawSize.height)
            return renderer.image { context in
                SessionGIFRenderer.canvasBackgroundColor.setFill()
                context.fill(CGRect(origin: .zero, size: size))
                photo.draw(in: rect)
            }
        }
    }
}

/// Plays prepared frames while on screen. Reduce Motion shows the first frame with a Play button
/// instead of autoplaying. Frames are rebuilt only when the session identity changes, so a
/// previous guest's photos can never appear.
struct SessionMotionPreviewView: View {
    /// Changes with every session (and with retakes) so stale frames are discarded.
    let identity: String
    let photos: [UIImage]
    var cornerRadius: CGFloat = 2

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var frames: [UIImage] = []
    @State private var framesIdentity: String?
    @State private var start = Date()
    @State private var isVisible = false
    @State private var userStartedPlayback = false

    private func frameImage(_ image: UIImage) -> some View {
        Image(uiImage: image)
            .resizable()
            .interpolation(.medium)
            .scaledToFit()
            .accessibilityHidden(true)
    }

    private var isPlaying: Bool { isVisible && frames.count >= SessionMotionPreview.minimumFrameCount && (!reduceMotion || userStartedPlayback) }

    var body: some View {
        ZStack {
            MadeToKeepTheme.ColorPalette.ivoryLight
            if framesIdentity == identity, !frames.isEmpty {
                if isPlaying {
                    // Ticks only while visible and playing; paused previews draw one still frame.
                    TimelineView(.periodic(from: start, by: SessionMotionPreview.frameInterval / 2)) { context in
                        frameImage(frames[SessionMotionPreview.frameIndex(at: context.date, start: start, frameCount: frames.count)])
                    }
                } else {
                    frameImage(frames[0])
                }
            } else {
                ProgressView()
            }
            if reduceMotion, !userStartedPlayback, frames.count >= SessionMotionPreview.minimumFrameCount {
                Button {
                    start = Date()
                    userStartedPlayback = true
                } label: {
                    Label("Play", systemImage: "play.fill")
                        .font(MadeToKeepTheme.Typography.sans(size: 15, weight: .semibold))
                        .padding(.horizontal, 16)
                        .frame(minHeight: 44)
                        .background(Capsule().fill(MadeToKeepTheme.ColorPalette.ivoryLight.opacity(0.92)))
                        .foregroundStyle(MadeToKeepTheme.ColorPalette.burgundy)
                }
                .buttonStyle(.plain)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .overlay { RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(MadeToKeepTheme.ColorPalette.hairline) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Your \(photos.count) photos in motion")
        .onAppear { isVisible = true; start = Date() }
        .onDisappear { isVisible = false; userStartedPlayback = false }
        .task(id: identity) {
            frames = []
            framesIdentity = nil
            let photos = photos
            let prepared = await Task.detached(priority: .utility) { SessionMotionPreview.makeFrames(from: photos) }.value
            guard !Task.isCancelled else { return }
            frames = prepared
            framesIdentity = identity
            start = Date()
        }
    }
}
