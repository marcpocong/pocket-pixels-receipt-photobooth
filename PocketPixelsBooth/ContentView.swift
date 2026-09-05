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
        .fullScreenCover(isPresented: $isShowingAdmin) {
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
        VStack(spacing: 0) {
            HStack {
                Text("Pocket Pixels Admin")
                    .font(.headline)

                Spacer()

                Button("Done") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background(.bar)

            Divider()

            TabView {
                NavigationStack {
                    EventSetupView()
                }
                .tabItem {
                    Label("Event Setup", systemImage: "calendar.badge.clock")
                }

                BoothSessionView(showsReceiptDebugTools: true)
                    .tabItem {
                        Label("Booth Debug", systemImage: "rectangle.stack.person.crop")
                    }

                CameraTestView()
                    .tabItem {
                        Label("Camera Test", systemImage: "camera")
                    }

                PrinterTestView()
                    .tabItem {
                        Label("Printer Test", systemImage: "printer")
                    }

                GalleryUploadTestView()
                    .tabItem {
                        Label("Cloud Test", systemImage: "icloud.and.arrow.up")
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
