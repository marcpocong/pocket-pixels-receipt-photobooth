//
//  ContentView.swift
//  PocketPixelsBooth
//
//  Created by marc on 8/30/26.
//

import SwiftUI
import UIKit

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var isShowingAdmin = false
    @StateObject private var operationalState = EventOperationalState.shared
    @StateObject private var workspace = OperatorWorkspace.shared

    var body: some View {
        customerExperience
            .statusBarHidden(true)
            .persistentSystemOverlays(.hidden)
            .onAppear {
                setIdleTimerDisabled(true)
                operationalState.start()
                // Settles any print left in flight by a crash and reconciles interrupted checkouts.
                PaymentRecoveryCoordinator.shared.launch()
                Task { await EventRunStore.shared.reconcilePrintEvidence(PrintOutcomeOutbox.shared?.entries ?? []) }
            }
            .onDisappear {
                setIdleTimerDisabled(false)
            }
            .onChange(of: scenePhase) { _, newPhase in
                setIdleTimerDisabled(newPhase == .active)
                if newPhase != .active { operationalState.invalidateCameraCheck() }
                if newPhase == .active {
                    operationalState.handleScenePhaseActive()
                    Task { await PaymentRecoveryCoordinator.shared.refresh() }
                }
            }
    }

    @ViewBuilder
    private var customerExperience: some View {
        BoothSessionView(onAdminAccessRequested: {
            guard !isShowingAdmin else { return }
            debugLog("[Admin] presentation state = true")
            workspace.open()
            isShowingAdmin = true
        })
        .fullScreenCover(isPresented: $isShowingAdmin) {
            OperatorAuthenticationView { PocketPixelsAdminView() }
                .interactiveDismissDisabled()
        }
    }

    private func setIdleTimerDisabled(_ disabled: Bool) {
        UIApplication.shared.isIdleTimerDisabled = disabled
    }
}

private struct PocketPixelsAdminView: View {
    @ObservedObject private var operations = EventOperationalState.shared
    @ObservedObject private var printer = PrinterCoordinator.shared
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var workspace = OperatorWorkspace.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(MadeToKeepBrand.operatorHeaderTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(workspace.currentSection)
                        .font(.title3.bold())
                }

                Spacer()

                Button("Return to Booth") {
                    workspace.finish(keepingDrafts: true)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(operations.isPreflightRunning || printer.isWorking)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background(.bar)

            Divider()

            if let error = workspace.persistenceError {
                Text(error).font(.footnote).foregroundStyle(.red).padding(.horizontal)
            }

            NavigationStack(path: $workspace.path) {
                OperatorDashboardView()
                    .navigationDestination(for: OperatorWorkspaceRoute.self) { $0.destination }
            }

        }
        .onReceive(NotificationCenter.default.publisher(for: OperatorWorkspace.didStartSessions)) { _ in
            workspace.finish(keepingDrafts: workspace.hasUnsavedDrafts)
            dismiss()
        }
        .onReceive(NotificationCenter.default.publisher(for: OperatorWorkspace.didResumeCheckout)) { _ in
            // The waiting guest may already have consumed the arm from this same notification.
            // The notification is posted only after the authenticated operator successfully arms it.
            workspace.finish(keepingDrafts: true)
            dismiss()
        }
    }
}

nonisolated private func debugLog(_ message: String) {
#if DEBUG
    print("[ContentView] \(message)")
#endif
}
