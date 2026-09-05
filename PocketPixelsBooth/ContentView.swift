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

    var body: some View {
        customerExperience
            .onAppear {
                setIdleTimerDisabled(true)
            }
            .onDisappear {
                setIdleTimerDisabled(false)
            }
            .onChange(of: scenePhase) { _, newPhase in
                setIdleTimerDisabled(newPhase == .active)
            }
    }

    @ViewBuilder
    private var customerExperience: some View {
        BoothSessionView(onAdminAccessRequested: {
            debugLog("[Admin] presentation state = true")
            isShowingAdmin = true
        })
        .sheet(isPresented: $isShowingAdmin) {
            PocketPixelsAdminView()
        }
    }

    private func setIdleTimerDisabled(_ disabled: Bool) {
        UIApplication.shared.isIdleTimerDisabled = disabled
    }
}

private struct PocketPixelsAdminView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        TabView {
            NavigationStack {
                EventSetupView()
                    .adminDismissToolbar(dismiss)
            }
            .tabItem {
                Label("Event Setup", systemImage: "calendar.badge.clock")
            }

            BoothSessionView(showsReceiptDebugTools: true)
                .adminDismissToolbar(dismiss)
                .tabItem {
                    Label("Booth Debug", systemImage: "rectangle.stack.person.crop")
                }

            CameraTestView()
                .adminDismissToolbar(dismiss)
                .tabItem {
                    Label("Camera Test", systemImage: "camera")
                }

            PrinterTestView()
                .adminDismissToolbar(dismiss)
                .tabItem {
                    Label("Printer Test", systemImage: "printer")
                }

            GalleryUploadTestView()
                .adminDismissToolbar(dismiss)
                .tabItem {
                    Label("Cloud Test", systemImage: "icloud.and.arrow.up")
                }
        }
    }
}

private extension View {
    func adminDismissToolbar(_ dismiss: DismissAction) -> some View {
        toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") {
                    dismiss()
                }
            }
        }
    }
}

nonisolated private func debugLog(_ message: String) {
#if DEBUG
    print("[ContentView] \(message)")
#endif
}
