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
            isShowingAdmin = true
        })
        .fullScreenCover(isPresented: $isShowingAdmin) {
            OperatorAuthenticationView { PocketPixelsAdminView() }
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

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(MadeToKeepBrand.operatorHeaderTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Operator")
                        .font(.title3.bold())
                }

                Spacer()

                Button("Done") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(operations.isPreflightRunning || printer.isWorking)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background(.bar)

            Divider()

            NavigationStack {
                OperatorDashboardView()
            }

        }
    }
}

nonisolated private func debugLog(_ message: String) {
#if DEBUG
    print("[ContentView] \(message)")
#endif
}
