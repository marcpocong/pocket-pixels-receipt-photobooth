//
//  OperatorStatusSummary.swift
//  PocketPixelsBooth
//

import Foundation

/// Translates the existing `EventReadinessReport` into short, operator-facing wording.
///
/// This is a presentation layer only: readiness is still decided by
/// `EventReadinessReport.readiness`, and no check is added, removed, or relaxed here.
struct OperatorStatusSummary: Equatable {
    enum ComponentState: Equatable {
        case ready
        case attention(String)
        case offline(String)

        var isReady: Bool { self == .ready }

        var label: String {
            switch self {
            case .ready: "Ready"
            case .attention(let text), .offline(let text): text
            }
        }
    }

    enum Destination: Equatable {
        case recovery
        case boothCheck
        case printerSetup
        case gallerySetup
        case waitingGalleries
        case storage
        case eventSetup
    }

    struct AttentionItem: Identifiable, Equatable {
        let id: String
        let message: String
        let actionTitle: String
        let destination: Destination
    }

    let readiness: EventReadinessReport.Readiness
    let headline: String
    let summary: String
    let camera: ComponentState
    let printer: ComponentState
    let gallery: ComponentState
    let internet: ComponentState
    let attentionItems: [AttentionItem]

    var allSystemsReady: Bool {
        camera.isReady && printer.isReady && gallery.isReady && internet.isReady
    }

    init(
        report: EventReadinessReport,
        hasUnresolvedPrint: Bool,
        printerRequiresRecovery: Bool,
        pendingUploadCount: Int,
        galleryStorageError: Bool
    ) {
        func failing(_ title: String) -> Bool {
            report.checks.contains { $0.title == title && $0.status != .pass }
        }

        let printNeedsConfirmation = hasUnresolvedPrint || failing("Unsafe Print State")
        let printerLocked = printerRequiresRecovery || failing("Printer Recovery")
        let cameraNotAuthorized = failing("Camera Authorization")
        let cameraUnchecked = failing("Camera Initialization")
        let storageProblem = failing("Archive Storage") || failing("Recovery Storage") || failing("Free Disk Space")
        let galleryQueueProblem = galleryStorageError || failing("Pending Gallery Storage")
        let galleryNeedsSetup = failing("Gallery Credentials")
        let offline = failing("Internet")

        readiness = report.readiness
        headline = switch report.readiness {
        case .ready: "READY FOR GUESTS"
        case .attention: "NEEDS ATTENTION"
        case .notReady: "NOT READY"
        }

        if report.checks.isEmpty {
            camera = .attention("Not checked")
        } else if cameraNotAuthorized {
            camera = .attention("Access needed")
        } else if cameraUnchecked {
            camera = .attention("Check needed")
        } else {
            camera = .ready
        }

        if report.checks.isEmpty {
            printer = .attention("Not checked")
        } else if printNeedsConfirmation || printerLocked {
            printer = .attention("Check previous receipt")
        } else if failing("Print Queue") {
            printer = .attention("Printing")
        } else if failing("Printer") {
            printer = .offline("Not connected")
        } else {
            printer = .ready
        }

        if report.checks.isEmpty {
            gallery = .attention("Not checked")
        } else if galleryQueueProblem {
            gallery = .attention("Needs review")
        } else if galleryNeedsSetup {
            gallery = .attention("Setup needed")
        } else if pendingUploadCount > 0 {
            gallery = .attention("\(pendingUploadCount) waiting")
        } else {
            gallery = .ready
        }

        internet = report.checks.isEmpty ? .attention("Not checked") : (offline ? .offline("Offline") : .ready)

        if report.checks.isEmpty {
            summary = "Run Booth Check before welcoming guests."
        } else if printNeedsConfirmation {
            summary = "Previous print result needs confirmation before continuing."
        } else if printerLocked {
            summary = "Check the previous receipt before continuing."
        } else if failing("Print Queue") {
            summary = "Printer is busy. Wait for the current receipt."
        } else if failing("Printer") {
            summary = "Connect the selected printer in Printer Setup."
        } else if cameraNotAuthorized {
            summary = "Camera access is needed before starting."
        } else if cameraUnchecked {
            summary = "Run Booth Check to confirm the camera."
        } else if storageProblem || galleryQueueProblem {
            summary = "iPad storage needs attention before starting."
        } else if galleryNeedsSetup {
            summary = "Gallery setup is needed. Photos stay saved on this iPad."
        } else if offline || pendingUploadCount > 0 {
            summary = "Ready to print. Galleries will upload when internet is available."
        } else if report.readiness == .ready {
            summary = "Camera, printer and gallery are ready."
        } else {
            summary = "Review Booth Check for details."
        }

        var items: [AttentionItem] = []
        if printNeedsConfirmation {
            items.append(AttentionItem(
                id: "print-confirmation",
                message: "Previous print result needs confirmation",
                actionTitle: "Open Recovery",
                destination: .recovery
            ))
        } else if printerLocked {
            items.append(AttentionItem(
                id: "printer-recovery",
                message: "Printer needs attention",
                actionTitle: "Fix Printer",
                destination: .recovery
            ))
        } else if failing("Printer") {
            items.append(AttentionItem(
                id: "printer-connection",
                message: "Printer is not connected",
                actionTitle: "Printer Setup",
                destination: .printerSetup
            ))
        }
        if cameraNotAuthorized {
            items.append(AttentionItem(
                id: "camera-access",
                message: "Camera access is not allowed",
                actionTitle: "Booth Check",
                destination: .boothCheck
            ))
        }
        if storageProblem {
            items.append(AttentionItem(
                id: "storage",
                message: "iPad storage needs attention",
                actionTitle: "Review",
                destination: .storage
            ))
        }
        if galleryQueueProblem {
            items.append(AttentionItem(
                id: "gallery-storage",
                message: "Gallery storage needs review",
                actionTitle: "Review",
                destination: .waitingGalleries
            ))
        } else if pendingUploadCount > 0 {
            items.append(AttentionItem(
                id: "waiting-galleries",
                message: pendingUploadCount == 1
                    ? "1 gallery waiting to upload"
                    : "\(pendingUploadCount) galleries waiting to upload",
                actionTitle: "Review",
                destination: .waitingGalleries
            ))
        }
        if galleryNeedsSetup {
            items.append(AttentionItem(
                id: "gallery-setup",
                message: "Gallery setup is incomplete",
                actionTitle: "Gallery Setup",
                destination: .gallerySetup
            ))
        }
        if failing("Event Profile") {
            items.append(AttentionItem(
                id: "event-profile",
                message: "Event setup needs review",
                actionTitle: "Event Setup",
                destination: .eventSetup
            ))
        }
        attentionItems = items
    }

    /// Operator-facing name for a readiness check shown in Booth Check.
    static func displayName(forCheckTitle title: String) -> String {
        switch title {
        case "Camera Initialization": "Camera"
        case "Camera Authorization": "Camera Access"
        case "Pending Gallery Storage": "Gallery Storage"
        case "Print Queue": "Printing"
        case "Printer Recovery": "Printer Recovery"
        case "Unsafe Print State": "Previous Print Result"
        case "Archive Storage": "Session Storage"
        case "Pending Uploads": "Waiting Galleries"
        case "Gallery Credentials": "Gallery Setup"
        case "Event Profile": "Event Setup"
        default: title
        }
    }
}
