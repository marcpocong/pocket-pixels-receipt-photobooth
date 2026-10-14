import Foundation
import SwiftUI
import Testing
import UIKit
@testable import PocketPixelsBooth

@Suite("Operator workspace recovery", .serialized)
@MainActor struct OperatorWorkspaceTests {
    private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("operator-\(UUID())") }

    @Test func browsingAndReturningFromRecoveryWithoutEditsNeverCreatesPendingSetup() throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = OperatorWorkspace(directory: root)
        workspace.open()
        workspace.path = [.payments]
        workspace.finish(keepingDrafts: true)
        #expect(!workspace.hasPendingSetup)
        let restored = OperatorWorkspace(directory: root)
        #expect(restored.path == [.payments])
        #expect(!restored.hasPendingSetup)
        // Legacy navigation-only resume flags must not show a draft shortcut either.
        var legacy = restored.snapshot
        legacy.resumeSetup = true
        try JSONEncoder().encode(legacy).write(to: root.appendingPathComponent("OperatorWorkspaceV1/setup.json"))
        #expect(!OperatorWorkspace(directory: root).hasPendingSetup)
    }

    @Test func realDesignEditsRemainPendingUntilSavedOrDiscarded() {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = OperatorWorkspace(directory: root)
        let design = SavedEventDesign.new(name: "Unfinished sample", venue: "")
        workspace.saveDesignDraft(design, id: design.id)
        workspace.finish(keepingDrafts: true)
        let restored = OperatorWorkspace(directory: root)
        #expect(restored.hasPendingSetup)
        #expect(restored.designDraft(id: design.id) == design)
        restored.saveDesignDraft(nil, id: design.id)
        #expect(!restored.hasPendingSetup)
    }

    @Test func relaunchRestoresDestinationAndUnsavedPolicyWithoutPublishing() throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = OperatorWorkspace(directory: root)
        workspace.open()
        workspace.path = [.manageEvent, .payments, .serverEvent("event-1")]
        var policy = ServerPolicyDraft()
        policy.priceText = "2.00"; policy.maxCopies = 5; policy.defaultCopies = 2
        policy.supportedFormats = ["solo", "strip"]
        let draft = OperatorServerSetupDraft(eventID: "event-1", serverBinding: workspace.serverBinding,
            baseVersion: 2, name: "Local event name", venue: "Local venue", policy: policy)
        workspace.saveServerDraft(draft)
        let relaunched = OperatorWorkspace(directory: root)
        #expect(relaunched.path == workspace.path)
        #expect(relaunched.serverDraft(eventID: "event-1") == draft)
        #expect(relaunched.hasPendingSetup && relaunched.hasUnsavedDrafts)
        #expect(relaunched.serverDraft(eventID: "event-1")?.conflicts(with: 3) == true)
        #expect(relaunched.serverDraft(eventID: "event-1")?.baseVersion == 2)
        let bytes = try Data(contentsOf: root.appendingPathComponent("OperatorWorkspaceV1/setup.json"))
        let text = String(decoding: bytes, as: UTF8.self)
        for forbidden in ["Bearer", "credential", "secretKey", "isUnlocked", "photoJPEG", "entitlement"] {
            #expect(!text.contains(forbidden))
        }
    }

    @Test func keepDraftsExitAndExplicitDiscardHaveDifferentRecoveryResults() {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = OperatorWorkspace(directory: root)
        workspace.open(); workspace.path = [.manageEvent, .payments]
        workspace.saveNewEvent(name: "Unfinished event", venue: "Venue")
        workspace.finish(keepingDrafts: true)
        let resumed = OperatorWorkspace(directory: root)
        #expect(resumed.hasPendingSetup && resumed.hasUnsavedDrafts)
        #expect(resumed.path == [.manageEvent, .payments])
        resumed.finish(keepingDrafts: false)
        let finished = OperatorWorkspace(directory: root)
        #expect(!finished.hasPendingSetup && !finished.hasUnsavedDrafts)
        #expect(finished.path.isEmpty)
    }

    @Test func diskFailureRetainsLastDurableSnapshotAndReportsUnsavedMemory() {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        var failing = false
        let workspace = OperatorWorkspace(directory: root, write: { data, url in
            if failing { throw CocoaError(.fileWriteOutOfSpace) }
            try DurableFileWriter.write(data, to: url)
        })
        workspace.open(); workspace.path = [.manageEvent]
        failing = true
        workspace.path = [.manageEvent, .payments]
        #expect(workspace.persistenceError != nil)
        #expect(workspace.path.count == 2)
        #expect(OperatorWorkspace(directory: root).path == [.manageEvent])
    }

    @Test func corruptSavedSetupIsPreservedAndCannotOverwriteItself() throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("OperatorWorkspaceV1/setup.json")
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data("incomplete saved setup".utf8)
        try original.write(to: path)
        let workspace = OperatorWorkspace(directory: root)
        #expect(workspace.persistenceError != nil)
        workspace.open(); workspace.path = [.payments]
        #expect(try Data(contentsOf: path) == original)
    }

    @Test func draftsCannotRestoreAcrossAnotherServerBinding() {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = OperatorWorkspace(directory: root)
        workspace.saveServerDraft(OperatorServerSetupDraft(eventID: "event-1", serverBinding: "another-environment",
            baseVersion: 1, name: "Other", venue: "", policy: ServerPolicyDraft()))
        #expect(workspace.serverDraft(eventID: "event-1") == nil)
    }

    @Test func disabledOfflineDateDoesNotCreateFalseUnsavedChanges() {
        var initial = ServerPolicyDraft(), latest = ServerPolicyDraft()
        initial.offlineValidUntil = Date(timeIntervalSince1970: 1)
        latest.offlineValidUntil = Date(timeIntervalSince1970: 100)
        #expect(initial.matchesForEditing(latest))
        latest.priceText = "2.00"
        #expect(!initial.matchesForEditing(latest))
    }

    @Test func lockBlocksNewPrivilegedMutationDespiteRetainedWorkspace() async throws {
        let permit = OperatorAccessPermit()
        let configuration = PaymentsConfiguration(baseURL: URL(string: "https://\(UUID()).example.test")!, environment: "test")
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [WorkspaceHTTPProtocol.self]
        let credentials = PaymentOperatorCredentialStore(configuration: configuration,
            testFallback: PaymentPairingCredential(token: "operator-fixture"), permit: permit)
        let api = PaymentsAPIClient(configuration: configuration, operatorCredentialStore: credentials,
            session: URLSession(configuration: sessionConfiguration))
        WorkspaceHTTPProtocol.requests = 0
        permit.authorize()
        _ = try await api.listEvents()
        permit.revoke()
        var draft = ServerPolicyDraft(); draft.priceText = "1.00"
        await #expect(throws: PaymentsAPIError.unauthorized) {
            _ = try await api.saveDraft(eventID: "event-1", expectedVersion: 2, name: "Preserved", venue: "", policy: draft.requestBody()!)
        }
        #expect(WorkspaceHTTPProtocol.requests == 1)
    }
}

private final class WorkspaceHTTPProtocol: URLProtocol {
    nonisolated(unsafe) static var requests = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests += 1
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"events":[],"nextCursor":null}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor private final class WorkspaceLifecycleProbe {
    var appearances: [UUID] = []
    var disappearances = 0
}

private struct RetainedWorkspaceProbe: View {
    let probe: WorkspaceLifecycleProbe
    @State private var identity = UUID()
    @State private var path = [7]
    @State private var price = "2.00"
    var body: some View {
        NavigationStack(path: $path) {
            Text("Operator fixture")
                .navigationDestination(for: Int.self) { _ in TextField("Unsaved price", text: $price) }
        }
        .onAppear { probe.appearances.append(identity) }
        .onDisappear { probe.disappearances += 1 }
    }
}

@Suite("Operator retained view lifecycle", .serialized)
@MainActor struct OperatorWorkspaceLifecycleTests {
    @Test func privacyLockAndCancelledAuthenticationNeverDestroyNavigation() async throws {
        let permit = OperatorAccessPermit()
        var allowed = true
        let authentication = OperatorAuthentication(permit: permit, evaluate: { allowed })
        let probe = WorkspaceLifecycleProbe()
        let hosting = UIHostingController(rootView: OperatorAuthenticationView(authentication: authentication) {
            RetainedWorkspaceProbe(probe: probe)
        })
        let window: UIWindow
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene { window = UIWindow(windowScene: scene) }
        else { window = UIWindow(frame: UIScreen.main.bounds) }
        window.rootViewController = hosting
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        await authentication.unlock()
        try await Task.sleep(for: .milliseconds(250))
        #expect(probe.appearances.count == 1)
        authentication.lock()
        try await Task.sleep(for: .milliseconds(150))
        #expect(!permit.isAuthorized)
        #expect(probe.disappearances == 0)
        allowed = false
        await authentication.unlock()
        #expect(!authentication.isUnlocked)
        allowed = true
        await authentication.unlock()
        try await Task.sleep(for: .milliseconds(150))
        #expect(probe.appearances.count == 1)
        #expect(probe.disappearances == 0)
    }
}
