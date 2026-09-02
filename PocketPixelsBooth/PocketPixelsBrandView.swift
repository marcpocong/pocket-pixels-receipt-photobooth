//
//  PocketPixelsBrandView.swift
//  PocketPixelsBooth
//

import SwiftUI
import UIKit

struct PocketPixelsBrandMark: View {
    let size: CGFloat

    var body: some View {
        Group {
            if let image = UIImage(named: "PocketPixelsMonogram") {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .accessibilityLabel("Pocket Pixels monogram")
            } else {
                fallbackMark
                    .accessibilityLabel("Pocket Pixels development monogram placeholder")
            }
        }
        .frame(width: size, height: size)
    }

    private var fallbackMark: some View {
        ZStack {
            Circle()
                .fill(PocketPixelsTheme.ColorPalette.brandBlush)
                .overlay {
                    Circle()
                        .stroke(PocketPixelsTheme.ColorPalette.brandMaroon.opacity(0.20), lineWidth: 1)
                }

            Text("PP")
                .font(.system(size: size * 0.38, weight: .black, design: .serif))
                .foregroundStyle(PocketPixelsTheme.ColorPalette.brandMaroon)
        }
    }
}

struct PocketPixelsLightboxLockup: View {
    enum Scale {
        case hero
        case medium
        case compact

        var markSize: CGFloat {
            switch self {
            case .hero:
                174
            case .medium:
                76
            case .compact:
                38
            }
        }

        var textSize: CGFloat {
            switch self {
            case .hero:
                42
            case .medium:
                22
            case .compact:
                13
            }
        }

        var spacing: CGFloat {
            switch self {
            case .hero:
                28
            case .medium:
                16
            case .compact:
                9
            }
        }
    }

    let scale: Scale
    var showGlow = false

    var body: some View {
        HStack(spacing: scale.spacing) {
            PocketPixelsBrandMark(size: scale.markSize)

            VStack(alignment: .leading, spacing: scale == .compact ? 1 : 5) {
                Text("RECEIPT")
                Text("PHOTOBOOTH")
            }
            .font(.system(size: scale.textSize, weight: .heavy))
            .tracking(scale == .compact ? 1.2 : 1.8)
            .foregroundStyle(PocketPixelsTheme.ColorPalette.brandMaroon)
            .lineLimit(1)
            .minimumScaleFactor(0.78)
        }
        .padding(.horizontal, scale == .hero ? 30 : 0)
        .padding(.vertical, scale == .hero ? 22 : 0)
        .background {
            if showGlow {
                RoundedRectangle(cornerRadius: 18)
                    .fill(PocketPixelsTheme.ColorPalette.acrylic.opacity(0.82))
                    .shadow(color: PocketPixelsTheme.ColorPalette.amberGlow.opacity(0.30), radius: 34, x: 0, y: 13)
                    .shadow(color: PocketPixelsTheme.ColorPalette.brandBlush.opacity(0.32), radius: 18, x: 0, y: 5)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
