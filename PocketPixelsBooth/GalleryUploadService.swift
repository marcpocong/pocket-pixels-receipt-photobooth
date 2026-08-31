//
//  GalleryUploadService.swift
//  PocketPixelsBooth
//
//  Created by marc on 8/30/26.
//

import Foundation
import UIKit

@MainActor
protocol GalleryUploadService: AnyObject {
    func uploadGallery(
        photos: [UIImage],
        composedReceipt: UIImage,
        sessionID: String,
        createdAt: Date,
        galleryToken: String,
        deviceToken: String
    ) async throws -> GalleryUploadResult

    func cancel()
}
