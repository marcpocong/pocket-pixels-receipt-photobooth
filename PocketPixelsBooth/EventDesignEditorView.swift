import SwiftUI

/// Uses the setup coordinator's existing staged design and checkpoint lifecycle.
struct EventDesignEditorView: View {
    @ObservedObject var setup: SessionSetupCoordinator
    @ObservedObject private var workspace: OperatorWorkspace
    @Environment(\.dismiss) private var dismiss
    @State private var persistenceAlert = false
    @State private var finishing = false

    init(setup: SessionSetupCoordinator) {
        self.setup = setup
        _workspace = ObservedObject(wrappedValue: setup.workspaceForEditing)
    }

    var body: some View {
        Group {
            if let design = Binding($setup.design) {
                ReceiptStudioView(design: design, profile: design.wrappedValue.appliedProfile(), studioProfile: setup.studioDefaultsForPresentation.profile)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let error = workspace.persistenceError {
                Label(error, systemImage: "exclamationmark.triangle").font(.footnote).padding().background(.bar)
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                NavigationLink("Print Sample") { SamplePrintStudioView(previewProfile: setup.design?.appliedProfile() ?? setup.effectiveProfile) }
                    .accessibilityIdentifier("receipt-studio-print-sample")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    finishing = true
                    Task {
                        await workspace.flush()
                        finishing = false
                        if workspace.persistenceError != nil { persistenceAlert = true } else { dismiss() }
                    }
                }.disabled(finishing).accessibilityIdentifier("receipt-studio-done")
            }
        }
        .onDisappear { workspace.checkpoint() }
        .alert("Draft needs attention", isPresented: $persistenceAlert) {
            Button("Keep Editing", role: .cancel) { }
            Button("Return with Staged Changes") { dismiss() }
        } message: { Text(workspace.persistenceError ?? "The changes remain staged in this event.") }
    }
}

/// Digital appearance is edited only in Gallery & QR; printed footer belongs to Receipt Studio.
struct EventGalleryPresentationControls: View {
    @ObservedObject var setup: SessionSetupCoordinator
    var body: some View {
        if let design = Binding($setup.design) {
            LabeledContent("Digital Gallery Appearance") {
                Picker("Gallery Appearance", selection: Binding(get: {
                    design.wrappedValue.profile.galleryReceiptStyleOverride ?? GalleryReceiptSettingsStore.load()
                }, set: { design.wrappedValue.profile.galleryReceiptStyleOverride = $0 })) {
                    ForEach(GalleryReceiptStyle.allCases) { Text($0.title).tag($0) }
                }.labelsHidden().frame(minHeight: 44)
            }
            Text("Controls the digital customer gallery. Printed QR and footer options are in Receipt Studio.").font(.footnote).foregroundStyle(.secondary)
            Button("Reset Gallery to Studio") {
                design.wrappedValue.profile.galleryReceiptStyleOverride = setup.studioDefaultsForPresentation.profile.galleryReceiptStyleOverride ?? GalleryReceiptSettingsStore.load()
            }.font(.callout).frame(minHeight: 44)
        }
    }
}

struct EventDesignRouteView: View {
    @StateObject private var setup = SessionSetupCoordinator()
    var body: some View {
        Group {
            if setup.design != nil { EventDesignEditorView(setup: setup) }
            else { RegularBoothSettingsView() }
        }.onAppear { setup.reloadDesignFromStorage() }
    }
}
