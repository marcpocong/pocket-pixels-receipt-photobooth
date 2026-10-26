//
//  PocketPixelsBoothApp.swift
//  PocketPixelsBooth
//
//  Created by marc on 8/30/26.
//

import SwiftUI

@main
struct PocketPixelsBoothApp: App {
    var body: some Scene {
        WindowGroup {
#if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--event-operations-validation") {
                EventOperationsValidationView()
            } else {
#if targetEnvironment(simulator)
            if ProcessInfo.processInfo.arguments.contains("--operator-v41-ui-fixture") {
                OperatorWorkspaceUITestFixture()
            } else {
                ContentView()
            }
#else
            ContentView()
#endif
            }
#else
            ContentView()
#endif
        }
    }
}
