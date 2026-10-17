import SwiftUI

struct RegularBoothSettingsView: View {
    @State private var settings = RegularBoothSettings.load()
    @State private var message = ""
    var body: some View {
        Form {
            Section("Regular Booth") {
                Text("Local, no-payment sessions with standard Made to Keep branding. Changes apply to the next guest and do not change event settings.")
                Stepper("Default copies: \(settings.defaultCopies)", value: $settings.defaultCopies, in: 1...settings.maxCopies)
                Stepper("Maximum copies: \(settings.maxCopies)", value: $settings.maxCopies, in: settings.defaultCopies...10)
                Toggle("Let guests choose additional copies", isOn: $settings.guestCopyChoice)
            }
            Section("Available formats") {
                ForEach(BoothFormat.allCases, id: \.rawValue) { format in
                    Toggle(format.rawValue, isOn: Binding(get: { settings.formats.contains(format.rawValue) }, set: { enabled in
                        if enabled { settings.formats.append(format.rawValue) }
                        else { settings.formats.removeAll { $0 == format.rawValue } }
                    }))
                }
            }
            Section {
                Button("Save Regular Booth Defaults") {
                    guard OperatorAccessPermit.shared.isAuthorized else { message = "Unlock Operator again before saving."; return }
                    do { try RegularBoothSettings.save(settings); message = "Saved for the next Regular Booth guest." }
                    catch { message = error.localizedDescription }
                }.disabled(settings.formats.isEmpty)
                if !message.isEmpty { Text(message) }
            }
        }.navigationTitle("Regular Booth Defaults")
    }
}
