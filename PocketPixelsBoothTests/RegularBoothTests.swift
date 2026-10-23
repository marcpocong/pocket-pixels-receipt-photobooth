import XCTest
@testable import PocketPixelsBooth

@MainActor final class RegularBoothTests: XCTestCase {
    func testFreshInstallBootstrapsWithoutEventOrPaymentContact() throws {
        let booth = Booth(); defer { booth.cleanup() }
        try RegularBoothMode.bootstrapIfSafe(acceptance: booth.acceptance, runs: booth.runs, source: booth.source, local: booth.local, library: booth.library, recoveryReason: { nil })
        XCTAssertTrue(RegularBoothMode.isEnabled(acceptance: booth.acceptance, runs: booth.runs))
        XCTAssertFalse(booth.acceptance.state.blocked)
        XCTAssertNil(booth.runs.current)
        XCTAssertTrue(booth.server.calls.isEmpty)
        booth.relaunch()
        XCTAssertTrue(RegularBoothMode.isEnabled(acceptance: booth.acceptance, runs: booth.runs))
    }

    func testPaidBindingsPausesHistoryAndRecoveryNeverAutoBecomeFree() throws {
        for obstacle in 0..<5 {
            let booth = Booth(); defer { booth.cleanup() }
            switch obstacle {
            case 0: booth.source = .serverManaged
            case 1: try booth.acceptance.save(.init(blocked: true))
            case 2: try booth.acceptance.save(.init(eventID: "paid", serverBinding: "live"))
            case 3: _ = try booth.runs.startNewRun(context: booth.appliedContext)
            default: break
            }
            try RegularBoothMode.bootstrapIfSafe(acceptance: booth.acceptance, runs: booth.runs, source: booth.source, local: booth.local, library: booth.library, recoveryReason: { obstacle == 4 ? "Uncertain print" : nil })
            XCTAssertFalse(RegularBoothMode.isEnabled(acceptance: booth.acceptance, runs: booth.runs))
        }
    }

    func testEndFreeEventDetachesAndRetainsHistoryAndDrafts() async throws {
        let booth = Booth(); defer { booth.cleanup() }
        let setup = booth.setup(); await setup.createEvent(name: "Wedding", venue: "Garden")
        let started = await setup.startAccepting(); XCTAssertTrue(started, setup.message)
        let original = try XCTUnwrap(booth.runs.current)
        _ = try await booth.admitGuest(session: "original-guest")
        let ended = await booth.lifecycle().end(scope: .thisBooth); XCTAssertTrue(ended)
        XCTAssertNil(booth.runs.current)
        XCTAssertEqual(booth.runs.runs.first?.status, .completed)
        XCTAssertEqual(try EventRunStore.loadSessions(directory: booth.runs.directory).first?.runID, original.id)
        XCTAssertTrue(RegularBoothMode.isEnabled(acceptance: booth.acceptance, runs: booth.runs))
        XCTAssertEqual(booth.lifecycle().status, .regular)
        XCTAssertNil(booth.library.library.appliedEventID)
        XCTAssertFalse(booth.profile.isEnabled)
        XCTAssertFalse(booth.library.library.events.isEmpty)
        XCTAssertTrue(booth.server.calls.isEmpty)
    }

    func testCrashAfterManifestDetachFinishesSameTransition() async throws {
        let booth = Booth(); defer { booth.cleanup() }
        let setup = booth.setup(); await setup.createEvent(name: "Wedding", venue: "")
        let started = await setup.startAccepting(); XCTAssertTrue(started)
        let run = try XCTUnwrap(booth.runs.current)
        let intent = EventTransitionIntent(id: "one-ending", kind: .returnToRegular, runID: run.id, commercialEventID: "", serverBinding: booth.binding, createdAt: Date(), returnsToRegular: true, serverConfirmed: true)
        try booth.acceptance.save(.init(blocked: true, mode: .localPrepaid, boothMode: .event))
        try booth.runs.beginTransition(intent)
        try booth.runs.completeAndDetachForRegular(intentID: intent.id)
        booth.relaunch()
        XCTAssertNil(booth.runs.current)
        XCTAssertNotNil(booth.runs.pendingTransition)
        await booth.lifecycle().refresh()
        XCTAssertNil(booth.runs.pendingTransition)
        XCTAssertFalse(booth.acceptance.state.blocked)
        XCTAssertEqual(booth.runs.runs.count, 1)
        XCTAssertTrue(RegularBoothMode.isEnabled(acceptance: booth.acceptance, runs: booth.runs))
        await booth.lifecycle().refresh()
        XCTAssertEqual(booth.runs.runs.count, 1)
    }

    func testUnverifiedIntentCannotDetachOrGrantRegularAdmission() throws {
        let booth = Booth(); defer { booth.cleanup() }
        let run = try booth.runs.startNewRun(context: booth.appliedContext)
        let intent = EventTransitionIntent(id: "ambiguous", kind: .endCommercialEvent, runID: run.id, commercialEventID: "paid", serverBinding: booth.binding, createdAt: Date(), returnsToRegular: true)
        try booth.runs.beginTransition(intent)
        XCTAssertThrowsError(try booth.runs.completeAndDetachForRegular(intentID: intent.id))
        XCTAssertEqual(booth.runs.current?.id, run.id)
        XCTAssertFalse(RegularBoothMode.isEnabled(acceptance: booth.acceptance, runs: booth.runs))
    }

    func testSimultaneousAndRepeatedClockValuesCannotReuseCheckoutOwnership() {
        let environment = BoothSessionEnvironment.customer, date = Date(timeIntervalSince1970: 1_800_000_000)
        let ids = (0..<100).map { _ in environment.makeSessionIdentifier(date) }
        XCTAssertEqual(Set(ids).count, 100)
        XCTAssertTrue(ids.allSatisfy { $0.count <= 100 && $0.hasPrefix("PP-") })
    }

    func testInterruptedPaidStartCannotReturnFreeWhileOriginalServerIsUnknown() async throws {
        let booth = Booth(); defer { booth.cleanup() }
        try booth.acceptance.save(.init(blocked: true, mode: .localPrepaid, startingEventID: "pending-paid", startingBinding: booth.binding))
        try RegularBoothMode.bootstrapIfSafe(acceptance: booth.acceptance, runs: booth.runs, source: .localPrepaid, local: booth.local, library: booth.library, recoveryReason: { nil })
        XCTAssertFalse(RegularBoothMode.isEnabled(acceptance: booth.acceptance, runs: booth.runs))
        if case .recoveryRequired = booth.lifecycle().status {} else { XCTFail("Interrupted paid Start must need explicit review") }
        booth.server.detailUnreachableOnce = true
        let returned = await booth.lifecycle().returnToRegular()
        XCTAssertFalse(returned)
        booth.relaunch()
        await booth.lifecycle().refresh()
        XCTAssertTrue(booth.acceptance.state.blocked)
        XCTAssertNotNil(booth.runs.pendingTransition)
        XCTAssertFalse(RegularBoothMode.isEnabled(acceptance: booth.acceptance, runs: booth.runs))
    }

    func testRegularSettingsAreLocalFreeAndIndependentOfEvents() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        var settings = RegularBoothSettings(); settings.formats = [BoothFormat.solo.rawValue]; settings.defaultCopies = 3
        try RegularBoothSettings.save(settings, defaults: defaults)
        let loaded = RegularBoothSettings.load(defaults: defaults)
        XCTAssertEqual(loaded, settings)
        XCTAssertEqual(loaded.configuration.id, "")
        XCTAssertEqual(loaded.policy.unitPriceCentavos, 0)
        XCTAssertFalse(loaded.policy.qrPhEnabled)
        XCTAssertFalse(loaded.policy.cashEnabled)
        XCTAssertEqual(loaded.policy.commercialMode, .privatePrepaid)
        settings.formats = []
        XCTAssertThrowsError(try RegularBoothSettings.save(settings, defaults: defaults))
    }
    func testInvalidDefaultsStayVisibleAndCannotAdmitUntilExplicitlyRepaired() throws {
        let name = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var invalid = RegularBoothSettings()
        invalid.maxCopies = 0
        let original = try JSONEncoder().encode(invalid)
        defaults.set(original, forKey: RegularBoothSettings.storageKey)
        XCTAssertEqual(RegularBoothSettings.load(defaults: defaults).maxCopies, 0)
        XCTAssertNotNil(RegularBoothSettings.loadIssue(defaults: defaults))
        XCTAssertThrowsError(try RegularBoothSettings.loadForSession(defaults: defaults))
        XCTAssertThrowsError(try RegularBoothSettings.save(invalid, defaults: defaults))
        XCTAssertEqual(defaults.data(forKey: RegularBoothSettings.storageKey), original)
        try RegularBoothSettings.save(.init(), defaults: defaults)
        XCTAssertNil(RegularBoothSettings.loadIssue(defaults: defaults))
        XCTAssertTrue(defaults.dictionaryRepresentation().contains { $0.key.hasPrefix(RegularBoothSettings.storageKey + ".preserved.") && ($0.value as? Data) == original })
    }

    func testUnreadableDefaultsAreRetainedAndReportedRatherThanSilentlyUsed() throws {
        let name = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let bytes = Data("unreadable original".utf8)
        defaults.set(bytes, forKey: RegularBoothSettings.storageKey)
        XCTAssertNotNil(RegularBoothSettings.loadIssue(defaults: defaults))
        XCTAssertThrowsError(try RegularBoothSettings.loadForSession(defaults: defaults))
        XCTAssertEqual(defaults.data(forKey: RegularBoothSettings.storageKey), bytes)
    }

    func testRegularReceiptAndCopyDefaultsPersistWithoutMutatingFrozenValues() throws {
        let name = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var value = RegularBoothSettings()
        var profile = EventProfile.pocketPixelsDefault
        profile.isEnabled = true; profile.showEventTextBlock = false
        profile.receiptDesign.footerStyleOverride = .decorativeBarcodeOnly
        profile.receiptDesign.editorialCaption = "THANK YOU"
        value.receiptProfile = profile
        try RegularBoothSettings.save(value, defaults: defaults)
        let frozen = try RegularBoothSettings.loadForSession(defaults: defaults)
        value.defaultCopies = 2
        value.receiptProfile?.receiptDesign.editorialCaption = "SEE YOU AGAIN"
        try RegularBoothSettings.save(value, defaults: defaults)
        XCTAssertEqual(RegularBoothSettings.load(defaults: defaults), value)
        XCTAssertEqual(frozen.defaultCopies, 1)
        XCTAssertEqual(frozen.profile.receiptDesign.editorialCaption, "THANK YOU")
        XCTAssertEqual(frozen.profile.receiptDesign.footerStyleOverride, .decorativeBarcodeOnly)
    }

    func testUnknownDeviceFooterAndGalleryDefaultsAreReportedAndPreservedOnRepair() throws {
        let name = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("future-footer", forKey: ReceiptPrintSettingsStore.footerStyleKey)
        defaults.set("future-gallery", forKey: GalleryReceiptSettingsStore.key)
        XCTAssertNotNil(ReceiptPrintSettingsStore.loadIssue(defaults: defaults))
        XCTAssertNotNil(GalleryReceiptSettingsStore.loadIssue(defaults: defaults))
        ReceiptPrintSettingsStore.save(.default, defaults: defaults)
        GalleryReceiptSettingsStore.save(.shareFriendly, defaults: defaults)
        XCTAssertNil(ReceiptPrintSettingsStore.loadIssue(defaults: defaults))
        XCTAssertNil(GalleryReceiptSettingsStore.loadIssue(defaults: defaults))
        let preserved = defaults.dictionaryRepresentation().filter { $0.key.contains(".preserved.") }.values.compactMap { $0 as? String }
        XCTAssertEqual(Set(preserved), ["future-footer", "future-gallery"])
    }

}
