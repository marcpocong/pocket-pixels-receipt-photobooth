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
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                        .background(Color.white)
                } else {
                    Text("Not ready")
                        .foregroundStyle(.white.opacity(0.62))
                        .frame(maxWidth: .infinity, minHeight: 260)
                }
            }
            .frame(maxWidth: 360, minHeight: 360, maxHeight: 560)
            .background(Color.white.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}
