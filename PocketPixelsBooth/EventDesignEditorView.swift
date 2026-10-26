import SwiftUI

/// Deeper design options for the selected event: printed event details, caption, typography and
/// Photo Pass wording. Edits the same design draft as Session Setup; Save Design keeps it for the
/// event and Start Accepting Guests applies it.
struct EventDesignEditorView: View {
    @ObservedObject var setup: SessionSetupCoordinator

    var body: some View {
        Form {
            if let design = Binding($setup.design) {
                Section {
                    Toggle("Print event details below the footer", isOn: design.profile.showEventTextBlock)
                    if design.wrappedValue.profile.showEventTextBlock {
                        TextField("Subtitle / Host", text: limited(design.profile.subtitle, EventProfile.subtitleLimit))
                        Toggle("Show date", isOn: design.profile.includeEventDate)
                        if design.wrappedValue.profile.includeEventDate {
                            DatePicker("Date", selection: design.profile.eventDate, displayedComponents: .date)
                        }
                        TextField("Location", text: limited(design.profile.location, EventProfile.locationLimit))
                        TextField("Optional message", text: limited(design.profile.shortMessage, EventProfile.shortMessageLimit))
                    }
                } header: { Text("Event Details") } footer: {
                    Text("Prints the event name (\(design.wrappedValue.displayName)) and these details in small type below the receipt footer. Off by default, like the Co-Branded reference.")
                }

                Section {
                    TextField("Event caption", text: Binding(
                        get: { design.wrappedValue.profile.receiptDesign.editorialCaption },
                        set: { design.wrappedValue.profile.receiptDesign.editorialCaption = String($0.prefix(ReceiptEditorialCaption.inputLimit)) }
                    ), axis: .vertical)
                    .lineLimit(2)
                } header: { Text("Caption") } footer: {
                    Text("Optional, up to two short lines printed below the footer.")
                }

                EventTypographySection(typography: design.profile.receiptDesign.typography)

                Section {
                    Text("Photo Pass prints the event name and location from this event when its receipt is personalized. Guests add their name, a note and a signature.")
                        .font(.callout).foregroundStyle(.secondary)
                } header: { Text("Photo Pass") }

                Section {
                    EventReceiptComposerPreview(profile: design.wrappedValue.appliedProfile(), printOptions: ReceiptPrintSettingsStore.load(), showsSamplePrintLink: false)
                } header: { Text("Preview") } footer: {
                    Text(design.wrappedValue.personalizeReceipt
                         ? "Preview only. Nothing is printed, saved or applied."
                         : "Personalize Receipt is off, so receipts use the standard Made to Keep design.")
                }

                if setup.designDirty && !setup.editingLiveEvent {
                    Section {
                        Button("Save Design") { setup.saveDesign() }.font(.headline)
                        Button("Cancel Changes", role: .destructive) { setup.discardDesignChanges() }
                        if !setup.message.isEmpty { Text(setup.message).font(.footnote).foregroundStyle(.secondary) }
                    }
                }
            } else {
                Section {
                    Text("Turn on Event Mode and choose an event in Session Setup to customize its receipt.")
                    NavigationLink("Open Session Setup", value: OperatorWorkspaceRoute.sessionSetup)
                }
            }
        }
        .navigationTitle(setup.design.map { "\($0.displayName) — Design" } ?? "Event Design")
        .navigationBarTitleDisplayMode(.inline)
        .tint(OperatorPalette.ink)
    }

    private func limited(_ text: Binding<String>, _ limit: Int) -> Binding<String> {
        Binding(get: { text.wrappedValue }, set: { text.wrappedValue = String($0.prefix(limit)) })
    }
}

/// Destination for the older Branding routes (Custom Event Design, Receipt Design & Branding).
/// It edits the selected event's design draft through the same coordinator model as Session
/// Setup, so there is only one place that decides what the next guest receives.
struct EventDesignRouteView: View {
    @StateObject private var setup = SessionSetupCoordinator()

    var body: some View {
        Group {
            if setup.eventModeEnabled, let design = Binding($setup.design) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        Text("Changes here are saved to \(design.wrappedValue.displayName). Guests receive them after you review and start in Session Setup.")
                            .font(.callout).foregroundStyle(.secondary)
                        EventReceiptDesignPanel(design: design, isDirty: setup.designDirty, save: { setup.saveDesign() }, discard: { setup.discardDesignChanges() })
                            .padding(22)
                            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
                        NavigationLink {
                            EventDesignEditorView(setup: setup)
                        } label: {
                            Label("More Design Options", systemImage: "paintbrush").frame(maxWidth: .infinity, minHeight: 48)
                        }
                        .buttonStyle(.bordered)
                        EventReceiptComposerPreview(profile: setup.effectiveProfile, printOptions: ReceiptPrintSettingsStore.load(), showsSamplePrintLink: false)
                        NavigationLink(value: OperatorWorkspaceRoute.sessionSetup) {
                            Label("Review & Start in Session Setup", systemImage: "checklist").frame(maxWidth: .infinity, minHeight: 48)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: 820)
                    .padding(24)
                    .frame(maxWidth: .infinity)
                }
                .background(OperatorPalette.canvas)
            } else {
                ContentUnavailableView {
                    Label("Event Receipt Design", systemImage: "paintpalette")
                } description: {
                    Text("Regular sessions use the Made to Keep receipt. Turn on Event Mode in Session Setup and choose an event to add its logo.")
                } actions: {
                    NavigationLink("Open Session Setup", value: OperatorWorkspaceRoute.sessionSetup).buttonStyle(.borderedProminent)
                }
            }
        }
        .navigationTitle("Event Receipt Design")
        .navigationBarTitleDisplayMode(.inline)
        .tint(OperatorPalette.ink)
        .onAppear { setup.reloadDesignFromStorage() }
    }
}
