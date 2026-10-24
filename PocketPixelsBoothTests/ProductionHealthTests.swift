import XCTest
import SwiftUI
@testable import PocketPixelsBooth

/// Targeted health diagnostics: truthful levels, cached equipment never shown as healthy, and a
/// support export that carries no secrets.
@MainActor final class ProductionHealthTests: XCTestCase {
    private func inputs(_ change: (inout ProductionHealthReport.Inputs) -> Void = { _ in }) -> ProductionHealthReport.Inputs {
        var value = ProductionHealthReport.Inputs(
            admissionOpen: true, eventStatus: .accepting, runID: "0123456789abcdef", runStatus: .active, paid: true, commercialEventID: "29b114e3-036c-4144-b482-1dae2cf58a9a",
            commercial: .confirmed(.init(eventID: "29b114e3-036c-4144-b482-1dae2cf58a9a", lifecycle: .active, isAccountActiveEvent: true, checkedAt: Date())),
            lastEventCheck: Date(), paymentsConfigured: true, environment: "live", printerRequiresRecovery: false, unresolvedPrint: false,
            printerLastReported: "Connected", printAccountingConflicts: 0, printAccountingPending: 0, checkoutsNeedingAttention: 0, checkoutIntegrityFault: false,
            lastRecoveryCheck: Date(), pendingGalleries: 0, galleryStorageProblem: false, storageErrors: [], pendingCreation: false)
        change(&value)
        return value
    }
    private func level(_ report: ProductionHealthReport, _ id: String) -> ProductionHealthReport.Level? { report.items.first { $0.id == id }?.level }

    func testHealthyBoothStillDoesNotClaimTheCachedPrinterIsHealthy() {
        let report = ProductionHealthReport(inputs())
        XCTAssertEqual(level(report, "admission"), .ready)
        XCTAssertEqual(level(report, "event"), .ready)
        XCTAssertEqual(level(report, "backend"), .ready)
        XCTAssertEqual(level(report, "printer"), .unavailable, "A cached printer state is not a live check")
        XCTAssertEqual(report.overall, .unavailable)
    }

    func testRegularBoothAndBackgroundReportsDoNotInventPrinterProblems() {
        let normal = ProductionHealthReport(inputs { $0.eventStatus = .regular; $0.paid = false; $0.commercialEventID = nil })
        XCTAssertEqual(level(normal, "event"), .ready)
        XCTAssertEqual(level(normal, "admission"), .ready)
        let pending = ProductionHealthReport(inputs { $0.printAccountingPending = 3 })
        XCTAssertEqual(level(pending, "printer"), .unavailable, "A sync queue says nothing about the physical printer")
        XCTAssertEqual(level(pending, "print-reports"), .ready)
        XCTAssertEqual(pending.overall, .unavailable)
        let conflict = ProductionHealthReport(inputs { $0.printAccountingConflicts = 1 })
        XCTAssertEqual(level(conflict, "printer"), .unavailable)
        XCTAssertEqual(level(conflict, "print-reports"), .review, "Financial report review remains visible in its own context")
        let physical = ProductionHealthReport(inputs { $0.unresolvedPrint = true; $0.printAccountingPending = 3 })
        XCTAssertEqual(level(physical, "printer"), .review, "A current unknown physical result still needs a receipt check")
    }

    func testProblemsAreClassifiedAsWarningUnavailableOrNeedsReview() {
        XCTAssertEqual(level(ProductionHealthReport(inputs { $0.admissionOpen = false; $0.eventStatus = .pausedOnBooth }), "admission"), .warning)
        XCTAssertEqual(level(ProductionHealthReport(inputs { $0.eventStatus = .needsReview("x") }), "admission"), .review, "Open admission without an accepting status")
        XCTAssertEqual(level(ProductionHealthReport(inputs { $0.commercial = .unavailable("offline") }), "backend"), .unavailable)
        XCTAssertEqual(level(ProductionHealthReport(inputs { $0.commercial = .notFound(eventID: "e") }), "backend"), .review)
        XCTAssertEqual(level(ProductionHealthReport(inputs { $0.printerRequiresRecovery = true }), "printer"), .review)
        XCTAssertEqual(level(ProductionHealthReport(inputs { $0.checkoutsNeedingAttention = 2 }), "payments"), .review)
        XCTAssertEqual(level(ProductionHealthReport(inputs { $0.lastRecoveryCheck = nil }), "payments"), .unavailable)
        XCTAssertEqual(level(ProductionHealthReport(inputs { $0.pendingGalleries = 3 }), "galleries"), .warning)
        XCTAssertEqual(level(ProductionHealthReport(inputs { $0.storageErrors = ["Event-run history could not be read."] }), "storage"), .review)
        XCTAssertEqual(level(ProductionHealthReport(inputs { $0.pendingCreation = true }), "creation"), .review)
        XCTAssertEqual(ProductionHealthReport(inputs { $0.pendingCreation = true }).overall, .review)
        XCTAssertEqual(level(ProductionHealthReport(inputs { $0.paid = false; $0.commercialEventID = nil; $0.commercial = .notNeeded }), "backend"), .ready, "Prepaid needs no server")
    }

    func testSupportExportContainsNoSecretsURLsOrFullIdentifiers() {
        let report = ProductionHealthReport(inputs {
            $0.commercial = .unavailable("Could not reach https://payments.example.workers.dev/v1/admin/events with Bearer abcdefghijklmnopqrstuvwxyz0123456789")
            $0.storageErrors = ["The file at /private/var/mobile/Containers/Data/Application/ABC/Library/Application Support/EventRunsV1/runs.json couldn't be read."]
        })
        let text = report.exportText(appVersion: "1.0 (1)")
        for forbidden in ["https://", "workers.dev", "Bearer", "abcdefghijklmnopqrstuvwxyz0123456789", "/private/var", "29b114e3-036c-4144-b482-1dae2cf58a9a", "0123456789abcdef"] {
            XCTAssertFalse(text.contains(forbidden), "export leaked \(forbidden)")
        }
        XCTAssertTrue(text.contains("29b114e3"), "Shortened identifiers stay for support")
        XCTAssertTrue(text.contains("Overall: Needs Operator Review"))
    }

    func testHealthSheetRendersInPortraitAndLandscapeWithoutRemoteCalls() async throws {
        let booth = Booth(); defer { booth.cleanup() }
        let lifecycle = booth.lifecycle()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        for size in [CGSize(width: 834, height: 1194), CGSize(width: 1194, height: 834)] {
            let host = UIHostingController(rootView: ProductionHealthSheet(lifecycle: lifecycle, isPresented: .constant(true), loadsRemote: false))
            let window = UIWindow(windowScene: scene); window.frame = CGRect(origin: .zero, size: size)
            window.rootViewController = host; window.makeKeyAndVisible()
            try await Task.sleep(for: .milliseconds(300))
            host.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(size: size).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
            XCTAssertGreaterThan(image.pngData()?.count ?? 0, 15_000)
            window.isHidden = true
        }
        XCTAssertTrue(booth.server.calls.isEmpty, "Diagnostics are observational")
    }
}
