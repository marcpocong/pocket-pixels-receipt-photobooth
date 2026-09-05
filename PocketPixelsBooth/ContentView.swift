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
#if DEBUG
    @State private var isShowingAdmin = false
#endif

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
#if DEBUG
        BoothSessionView(onAdminAccessRequested: {
            isShowingAdmin = true
        })
        .sheet(isPresented: $isShowingAdmin) {
            PocketPixelsAdminView()
        }
#else
        BoothSessionView()
#endif
    }

    private func setIdleTimerDisabled(_ disabled: Bool) {
        UIApplication.shared.isIdleTimerDisabled = disabled
    }
}

#if DEBUG
private struct PocketPixelsAdminView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            TabView {
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
            .navigationTitle("Pocket Pixels Admin")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}
#endif
