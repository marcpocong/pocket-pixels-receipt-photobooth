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
            .onAppear {
                setIdleTimerDisabled(true)
                operationalState.start()
                // Settles any print left in flight by a crash and reconciles interrupted checkouts.
                PaymentRecoveryCoordinator.shared.launch()
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
            debugLog("[Admin] presentation state = true")
            workspace.open()
            isShowingAdmin = true
        })
        .overlay(alignment: .topTrailing) {
            if workspace.hasPendingSetup && !isShowingAdmin && !operationalState.customerSessionActive {
                Button("Resume Operator Setup") { workspace.open(); isShowingAdmin = true }
                    .buttonStyle(.bordered)
                    .padding()
            }
        }
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
    @State private var confirmExit = false

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
                    if workspace.hasUnsavedDrafts { confirmExit = true }
                    else { workspace.finish(keepingDrafts: false); dismiss() }
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
        .confirmationDialog("Keep your unsaved setup?", isPresented: $confirmExit, titleVisibility: .visible) {
            Button("Keep Drafts & Return to Booth") { workspace.finish(keepingDrafts: true); dismiss() }
            Button("Discard Setup Drafts & Return", role: .destructive) {
                guard OperatorAccessPermit.shared.isAuthorized else { return }
                workspace.finish(keepingDrafts: false); dismiss()
            }
            Button("Continue Editing", role: .cancel) {}
        } message: { Text("Keeping drafts saves them only on this iPad. Nothing is published or activated.") }
        .onChange(of: scenePhase) { _, phase in if phase != .active { confirmExit = false } }
    }
}

nonisolated private func debugLog(_ message: String) {
#if DEBUG
    print("[ContentView] \(message)")
#endif
}
