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

            if let image {
                // Whole receipt at Fit; pinch or presets to inspect individual dots.
                OperatorZoomableReceiptView(image: image, rendering: .exactRaster, accessibilityLabel: title)
                    .frame(maxWidth: 300)
                    .frame(height: 560)
            } else {
                Text("Not ready")
                    .foregroundStyle(.white.opacity(0.62))
                    .frame(maxWidth: 300, minHeight: 260)
            }
        }
    }

}
