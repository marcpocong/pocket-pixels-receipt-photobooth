//
//  ESCPOSTestReceipt.swift
//  PocketPixelsBooth
//
//  Created by marc on 8/30/26.
//

import Foundation
import UIKit

enum ESCPOSTestReceipt {
    static func payload(printerIP: String, port: UInt16, date: Date = Date()) -> Data {
        var data = Data()

        data.append(contentsOf: [0x1B, 0x40])
        data.append(contentsOf: [0x1B, 0x61, 0x01])
        data.append(contentsOf: [0x1B, 0x45, 0x01])
        data.appendASCII("MADE TO KEEP STUDIOS\n")
        data.append(contentsOf: [0x1B, 0x45, 0x00])
        data.appendASCII("Receipt Photobooth\n\n")

        data.append(contentsOf: [0x1B, 0x61, 0x00])
        data.appendASCII("Wi-Fi printer test\n")
        data.appendASCII("Printer: VOZY G80\n")
        data.appendASCII("IP: \(printerIP)\n")
        data.appendASCII("Port: \(port)\n")
        data.appendASCII("Date: \(Self.dateFormatter.string(from: date))\n\n")
        data.appendASCII("Connection successful\n")
        data.appendASCII("\n\n\n")
        data.append(contentsOf: [0x1D, 0x56, 0x42, 0x00])

        return data
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()
}

/// No event or guest data. Production heading/finishing commands remain unchanged.
enum QuickPrinterTest {
    static let content = "MADE TO KEEP\nPRINTER TEST\n\nPAPER CHECK\n\nTEST ONLY"
    static func raster() throws -> ThermalRasterizedImage {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let image = UIGraphicsImageRenderer(size: CGSize(width: 576, height: 220), format: format).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 576, height: 220))
            let style = NSMutableParagraphStyle(); style.alignment = .center
            (content as NSString).draw(in: CGRect(x: 16, y: 8, width: 544, height: 204), withAttributes: [
                .font: UIFont.monospacedSystemFont(ofSize: 24, weight: .bold), .foregroundColor: UIColor.black, .paragraphStyle: style])
        }
        return try ThermalImageRasterizer.rasterize(image)
    }
}
