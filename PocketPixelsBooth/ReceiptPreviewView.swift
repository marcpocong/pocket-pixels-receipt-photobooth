//
//  ReceiptPreviewView.swift
//  PocketPixelsBooth
//
//  Created by marc on 8/30/26.
//

import SwiftUI
import UIKit

struct ReceiptPreviewView: View {
    let title: String
    let image: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.white)

            ScrollView([.vertical]) {
                if let image {
                    let previewSize = previewDisplaySize(for: image, maxWidth: 300)
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: previewSize.width, height: previewSize.height)
                        .overlay {
                            Rectangle()
                                .stroke(Color.white.opacity(0.22), lineWidth: 1)
                        }
                } else {
                    Text("Not ready")
                        .foregroundStyle(.white.opacity(0.62))
                        .frame(maxWidth: .infinity, minHeight: 260)
                }
            }
            .frame(maxWidth: 300, maxHeight: 560)
        }
    }

    private func previewDisplaySize(for image: UIImage, maxWidth: CGFloat) -> CGSize {
        guard image.size.width > 0, image.size.height > 0 else {
            return CGSize(width: maxWidth, height: maxWidth)
        }

        let scale = maxWidth / image.size.width
        return CGSize(width: image.size.width * scale, height: image.size.height * scale)
    }
}
