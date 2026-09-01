//
//  ContentView.swift
//  PocketPixelsBooth
//
//  Created by marc on 8/30/26.
//

import SwiftUI

struct ContentView: View {
    var body: some View {
#if DEBUG
        TabView {
            BoothSessionView()
                .tabItem {
                    Label("Booth Session", systemImage: "rectangle.stack.person.crop")
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
#else
        BoothSessionView()
#endif
    }
}
