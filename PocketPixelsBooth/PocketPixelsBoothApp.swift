//
//  PocketPixelsBoothApp.swift
//  PocketPixelsBooth
//
//  Created by marc on 8/30/26.
//

import SwiftUI
import UIKit

final class PortraitApplicationDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        .portrait
    }
}

@main
struct PocketPixelsBoothApp: App {
    @UIApplicationDelegateAdaptor(PortraitApplicationDelegate.self) private var applicationDelegate
    var body: some Scene {
        WindowGroup {
#if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--event-operations-validation") {
                EventOperationsValidationView()
            } else {
#if targetEnvironment(simulator)
            if ProcessInfo.processInfo.arguments.contains("--header-pin-ui-fixture") {
                HeaderPINRefinementFixture()
            } else if ProcessInfo.processInfo.arguments.contains("--operator-v41-ui-fixture") {
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
