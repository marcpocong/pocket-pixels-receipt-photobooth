//
//  ESCPOSTestReceipt.swift
//  PocketPixelsBooth
//
//  Created by marc on 8/30/26.
//

import Foundation

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
