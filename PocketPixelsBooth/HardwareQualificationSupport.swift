//
//  HardwareQualificationSupport.swift
//  PocketPixelsBooth
//
//  Diagnostic photographs, fingerprints and resource sampling for hardware qualification.
//

import CryptoKit
import Darwin
import Foundation
import UIKit

/// Synthetic photographs for Modes A and B. Every frame is unmistakably diagnostic (watermark,
/// run and session codes) and carries orientation markers so a wrong rotation, mirror or crop
/// is visible on paper. Mode C never uses these.
nonisolated enum QualificationDiagnosticPhoto {
    static let cameraFrame = CGSize(width: 1_200, height: 1_600)

    static func make(runCode: String, session: Int, photoIndex: Int, photoCount: Int, label: String) -> UIImage {
        let size = cameraFrame
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cg = context.cgContext
            // Session-specific tone so consecutive sessions never produce identical rasters.
            let tone = 0.55 + CGFloat((session * 37 + photoIndex * 11) % 30) / 100
            UIColor(white: tone, alpha: 1).setFill()
            cg.fill(CGRect(origin: .zero, size: size))

            // Corner markers: dark top-left block, mid bottom-right block, up arrow at top.
            UIColor.black.setFill()
            cg.fill(CGRect(x: 0, y: 0, width: 160, height: 160))
            UIColor(white: 0.25, alpha: 1).setFill()
            cg.fill(CGRect(x: size.width - 160, y: size.height - 160, width: 160, height: 160))
            let arrow = UIBezierPath()
            arrow.move(to: CGPoint(x: size.width / 2, y: 40))
            arrow.addLine(to: CGPoint(x: size.width / 2 + 90, y: 180))
            arrow.addLine(to: CGPoint(x: size.width / 2 - 90, y: 180))
            arrow.close()
            UIColor.black.setFill()
            arrow.fill()

            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            func draw(_ text: String, y: CGFloat, size fontSize: CGFloat, weight: UIFont.Weight = .bold) {
                text.draw(
                    in: CGRect(x: 60, y: y, width: size.width - 120, height: fontSize * 2.6),
                    withAttributes: [
                        .font: UIFont.monospacedSystemFont(ofSize: fontSize, weight: weight),
                        .foregroundColor: UIColor.black,
                        .paragraphStyle: paragraph
                    ]
                )
            }
            draw("DIAGNOSTIC", y: 380, size: 96)
            draw("NOT A CUSTOMER PHOTO", y: 520, size: 52)
            draw(label, y: 640, size: 48, weight: .semibold)
            draw("RUN \(runCode)", y: 820, size: 72)
            draw("SESSION \(String(format: "%03d", session))", y: 960, size: 84)
            draw("PHOTO \(photoIndex + 1) / \(photoCount)", y: 1_110, size: 72)
            draw("TOP", y: 200, size: 40, weight: .regular)
            ("TL" as NSString).draw(at: CGPoint(x: 176, y: 20), withAttributes: [.font: UIFont.systemFont(ofSize: 44, weight: .bold)])
            ("BR" as NSString).draw(at: CGPoint(x: size.width - 240, y: size.height - 80), withAttributes: [.font: UIFont.systemFont(ofSize: 44, weight: .bold)])
        }
    }

    /// The same normalization a real capture of this format receives before storage.
    static func storedCapture(_ image: UIImage, format: BoothFormat) -> UIImage {
        format == .passport
            ? PassportPhotoProcessor.normalizedSource(from: image)
            : BoothPhotoProcessor.normalizedPortraitPhoto(from: image)
    }
}

nonisolated enum QualificationFingerprint {
    /// Exact pixel fingerprint. Two live camera captures are never pixel-identical, so a repeat
    /// means a stale or substituted photograph.
    static func photo(_ image: UIImage) -> String {
        guard let cgImage = image.cgImage, let data = cgImage.dataProvider?.data as Data? else {
            return "unreadable-\(UUID().uuidString.prefix(8))"
        }
        var hasher = SHA256()
        hasher.update(data: data)
        withUnsafeBytes(of: cgImage.width) { hasher.update(bufferPointer: $0) }
        withUnsafeBytes(of: cgImage.height) { hasher.update(bufferPointer: $0) }
        return hasher.finalize().prefix(10).map { String(format: "%02X", $0) }.joined()
    }

    /// Whether the stored capture, once framed by the shared geometry, has the expected shape.
    static func orientationIsConsistent(stored: UIImage, format: BoothFormat, photoIndex: Int) -> Bool {
        let geometry = PhotoPresentationGeometry.resolve(format: format, photoIndex: photoIndex)
        let upright = ThermalPhotoProcessor.pixelSize(of: geometry.uprightPhoto(from: stored))
        guard upright.width > 0, upright.height > 0 else { return false }
        let confirmation = CapturePhotoPresentation.resolve(format: format, photoIndex: photoIndex)
            .confirmationPhoto(from: stored, format: format, photoIndex: photoIndex, maximumDimension: 240)
        let confirmationRatio = confirmation.size.width / max(1, confirmation.size.height)
        return abs(upright.width / upright.height - geometry.aspectRatio) < 0.02
            && abs(confirmationRatio - geometry.aspectRatio) < 0.03
    }
}

nonisolated enum QualificationResourceMonitor {
    /// The app's physical memory footprint (what iPadOS uses for memory pressure decisions).
    static func memoryFootprintMegabytes() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Int(info.phys_footprint / 1_048_576)
    }

    static func freeStorageBytes() -> Int64? {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}
