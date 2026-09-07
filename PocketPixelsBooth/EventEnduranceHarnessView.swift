//
//  EventEnduranceHarnessView.swift
//  PocketPixelsBooth
//

#if DEBUG
import Darwin
import Combine
import SwiftUI
import UIKit

@MainActor
final class EventEnduranceHarnessViewModel: ObservableObject {
    enum LayoutMode: String, CaseIterable, Identifiable {
        case alternating
        case random

        var id: String { rawValue }
        var displayName: String { rawValue.capitalized }
    }

    @Published var sessionCount = 10
    @Published var layoutMode = LayoutMode.alternating
    @Published var randomCopyCount = false
    @Published var persistUploads = false
    @Published var physicalPrinting = false
    @Published private(set) var isRunning = false
    @Published private(set) var completedSessions = 0
    @Published private(set) var printJobs = 0
    @Published private(set) var uploadJobs = 0
    @Published private(set) var failures = 0
    @Published private(set) var currentMemoryMB = 0
    @Published private(set) var peakMemoryMB = 0
    @Published private(set) var lastSessionDuration = 0.0
    @Published private(set) var averageSessionDuration = 0.0
    @Published private(set) var statusMessage = "Ready."

    private let uploadService = GoogleDriveGalleryUploadService()
    private let recoveryStore = try? AppRecoveryStore()
    private let archiveStore = try? RecentSessionArchiveStore()
    private let printerCoordinator = PrinterCoordinator.shared
    private var shouldStop = false

    let supportedSessionCounts = [10, 25, 50, 100, 250]

    func stopAfterCurrentSession() {
        shouldStop = true
    }

    func run(printerIP: String, printerPort: UInt16?) {
        guard !isRunning else { return }

        isRunning = true
        shouldStop = false
        completedSessions = 0
        printJobs = 0
        uploadJobs = 0
        failures = 0
        currentMemoryMB = Self.currentMemoryFootprintMB()
        peakMemoryMB = currentMemoryMB
        lastSessionDuration = 0
        averageSessionDuration = 0
        statusMessage = "Starting endurance run..."

        Task {
            var totalDuration = 0.0
            let baseDate = Date()

            for index in 1...sessionCount {
                guard !shouldStop else { break }
                let started = Date()
                do {
                    try await runSession(index: index, baseDate: baseDate, printerIP: printerIP, printerPort: printerPort)
                    completedSessions += 1
                    lastSessionDuration = Date().timeIntervalSince(started)
                    totalDuration += lastSessionDuration
                    averageSessionDuration = totalDuration / Double(max(1, completedSessions))
                    currentMemoryMB = Self.currentMemoryFootprintMB()
                    peakMemoryMB = max(peakMemoryMB, currentMemoryMB)
                    statusMessage = "Session \(completedSessions) / \(sessionCount) completed."
                } catch {
                    failures += 1
                    statusMessage = error.localizedDescription
                    break
                }
            }

            isRunning = false
            shouldStop = false
        }
    }

    private func runSession(index: Int, baseDate: Date, printerIP: String, printerPort: UInt16?) async throws {
        let date = baseDate.addingTimeInterval(Double(index))
        let format = selectedFormat(index: index)
        let sessionID = "\(ReceiptComposer.makeSessionIdentifier(date: date))-\(String(format: "%03d", index))"
        let galleryToken = try GalleryTokenGenerator.makeGalleryToken()
        let galleryURL = try GalleryURLBuilder.makeGalleryURL(
            customerGalleryBaseURL: CustomerGalleryConfiguration.load().baseURL,
            galleryToken: galleryToken
        )
        let photos = Self.makeSamplePhotos(count: format.photoCount, index: index)
        let eventSnapshot = EventProfileStore.load().activeReceiptSnapshot
        let worker = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let receipt = try ReceiptComposer.compose(
                photos: photos,
                sessionIdentifier: sessionID,
                date: date,
                galleryURL: galleryURL,
                format: format,
                eventProfile: eventSnapshot,
                photoQualityProfile: .customerPrintDefault
            )
            guard let receiptImage = UIImage(data: receipt.imagePNGData) else {
                throw ReceiptComposerError.renderFailed
            }
            try Task.checkCancellation()
            let rasterized = try ThermalImageRasterizer.rasterize(receiptImage, purpose: .completeReceipt)
            return (receipt, receiptImage, rasterized)
        }
        let (receipt, receiptImage, rasterized) = try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
        let committedSession = CommittedGallerySession(
            sessionIdentifier: sessionID,
            createdAt: date,
            galleryToken: galleryToken,
            galleryURL: galleryURL,
            photos: photos,
            format: format,
            eventProfile: eventSnapshot
        )
        let thumbnails = photos.compactMap { AppRecoveryStore.photoData(from: $0) }
        try archiveStore?.save(
            RecentSessionArchivePayload(
                committedSession: committedSession,
                composedReceipt: receipt,
                receiptPreviewPNGData: receipt.imagePNGData,
                thermalPreviewPNGData: rasterized.previewPNGData,
                rasterizedImage: rasterized,
                photoThumbnailData: thumbnails
            )
        )

        if persistUploads {
            _ = try await uploadService.prepareAndPersistGallery(
                photos: photos,
                composedReceipt: receiptImage,
                sessionID: sessionID,
                createdAt: date,
                galleryToken: galleryToken
            )
            uploadJobs += 1
        }

        if physicalPrinting {
            guard let printerPort else {
                throw PrinterNetworkError.invalidPort
            }
            let copies = randomCopyCount ? [1, 2, 3, 5].randomElement() ?? 1 : 1
            let batchID = UUID()
            for copy in 1...copies {
                try await printCopy(
                    rasterizedImage: rasterized,
                    sessionID: sessionID,
                    batchID: batchID,
                    copy: copy,
                    copies: copies,
                    printerIP: printerIP,
                    printerPort: printerPort
                )
                printJobs += 1
            }
        }

        recoveryStore?.clear(sessionIdentifier: sessionID)
    }

    private func printCopy(
        rasterizedImage: ThermalRasterizedImage,
        sessionID: String,
        batchID: UUID,
        copy: Int,
        copies: Int,
        printerIP: String,
        printerPort: UInt16
    ) async throws {
        try await withCheckedThrowingContinuation { continuation in
            printerCoordinator.printReceipt(
                rasterizedImage: rasterizedImage,
                wifiHost: printerIP,
                wifiPort: printerPort,
                sessionIdentifier: sessionID,
                source: .diagnostic,
                copyIndex: copy,
                copyCount: copies,
                batchID: batchID,
                transportPolicy: .safeIntegrity
            ) { _ in
            } completion: { result in
                continuation.resume(with: result)
            }
        }
    }

    private func selectedFormat(index: Int) -> BoothFormat {
        switch layoutMode {
        case .alternating:
            BoothFormat.allCases[(index - 1) % BoothFormat.allCases.count]
        case .random:
            BoothFormat.allCases.randomElement() ?? .solo
        }
    }

    private static func makeSamplePhotos(count: Int, index: Int) -> [UIImage] {
        (0..<count).map { photoIndex in
            let size = CGSize(width: 900, height: 1200)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            return UIGraphicsImageRenderer(size: size, format: format).image { context in
                UIColor.white.setFill()
                context.fill(CGRect(origin: .zero, size: size))
                UIColor(
                    hue: CGFloat((index * 17 + photoIndex * 31) % 255) / 255.0,
                    saturation: 0.42,
                    brightness: 0.92,
                    alpha: 1
                ).setFill()
                context.fill(CGRect(x: 0, y: 0, width: size.width, height: size.height))
                let text = "SESSION \(String(format: "%03d", index))\nPHOTO \(photoIndex + 1)"
                let paragraph = NSMutableParagraphStyle()
                paragraph.alignment = .center
                text.draw(
                    in: CGRect(x: 60, y: 470, width: size.width - 120, height: 180),
                    withAttributes: [
                        .font: UIFont.monospacedSystemFont(ofSize: 66, weight: .bold),
                        .foregroundColor: UIColor.black,
                        .paragraphStyle: paragraph
                    ]
                )
            }
        }
    }

    private static func currentMemoryFootprintMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }

        guard result == KERN_SUCCESS else {
            return 0
        }
        return Int(info.phys_footprint / 1_048_576)
    }
}

struct EventEnduranceHarnessView: View {
    @AppStorage("printerIP") private var printerIP = BoothConfiguration.defaultPrinterIP
    @AppStorage("printerPort") private var printerPort = BoothConfiguration.defaultPrinterPort
    @StateObject private var viewModel = EventEnduranceHarnessViewModel()

    var body: some View {
        Form {
            Section("Run") {
                Picker("Sessions", selection: $viewModel.sessionCount) {
                    ForEach(viewModel.supportedSessionCounts, id: \.self) { count in
                        Text("\(count)").tag(count)
                    }
                }

                Picker("Layouts", selection: $viewModel.layoutMode) {
                    ForEach(EventEnduranceHarnessViewModel.LayoutMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }

                Toggle("Random Copy Count", isOn: $viewModel.randomCopyCount)
                Toggle("Persist Upload Queue Items", isOn: $viewModel.persistUploads)
                Toggle("Physical Printing", isOn: $viewModel.physicalPrinting)

                Button("Start Endurance Run") {
                    viewModel.run(printerIP: printerIP, printerPort: parsedPort)
                }
                .disabled(viewModel.isRunning)

                Button("Stop After Current Session") {
                    viewModel.stopAfterCurrentSession()
                }
                .disabled(!viewModel.isRunning)
            }

            Section("Progress") {
                row("Sessions", "\(viewModel.completedSessions) / \(viewModel.sessionCount)")
                row("Memory", "\(viewModel.currentMemoryMB) MB")
                row("Peak Memory", "\(viewModel.peakMemoryMB) MB")
                row("Last Session", String(format: "%.2fs", viewModel.lastSessionDuration))
                row("Average Session", String(format: "%.2fs", viewModel.averageSessionDuration))
                row("Print Jobs", "\(viewModel.printJobs)")
                row("Upload Jobs", "\(viewModel.uploadJobs)")
                row("Failures", "\(viewModel.failures)")
                Text(viewModel.statusMessage)
                    .foregroundStyle(viewModel.failures == 0 ? Color.secondary : Color.red)
            }
        }
        .navigationTitle("Endurance Harness")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var parsedPort: UInt16? {
        UInt16(printerPort.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
        }
    }
}
#endif
