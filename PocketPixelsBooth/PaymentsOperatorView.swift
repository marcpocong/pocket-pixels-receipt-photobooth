import SwiftUI

struct PaymentsOperatorView: View {
    @State private var events: [OperatorEventSummary] = []
    @State private var selection: OperatorEventSummary?
    @State private var summary: OperatorSalesSummary?
    @State private var eventName = ""
    @State private var venue = ""
    @State private var countedCentavos = 0
    @State private var countReason = "End-of-event physical count"
    @State private var exportURL: URL?
    @State private var status = "Connect and pair this iPad to load server events."

    private var client: PaymentsAPIClient? { PaymentsConfiguration.bundled.map { PaymentsAPIClient(configuration: $0) } }

    var body: some View {
        List {
            Section("Worker Status") {
                LabeledContent("Environment", value: PaymentsConfiguration.bundled?.environment.uppercased() ?? "NOT CONFIGURED")
                Text(status).font(.footnote).foregroundStyle(.secondary)
                Button("Refresh Events") { Task { await refresh() } }
            }
            Section("Create Draft Event") {
                TextField("Event name", text: $eventName).textContentType(.organizationName)
                TextField("Venue", text: $venue)
                Button("Create Draft") { Task { await createEvent() } }.disabled(eventName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Section("Server Events") {
                ForEach(events) { event in
                    Button { selection = event; Task { await loadSummary(event.id) } } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(event.name).font(.headline)
                            Text("\(event.lifecycle) · revision \(event.activePolicyRevisionId ?? "not published")")
                                .font(.caption).foregroundStyle(.secondary)
                        }.frame(minHeight: 44, alignment: .leading)
                    }.accessibilityLabel("\(event.name), \(event.lifecycle)")
                }
            }
            if let event = selection {
                Section("Lifecycle — \(event.name)") {
                    HStack {
                        Button("Pause") { Task { await transition(event, "pause") } }
                        Button("Resume") { Task { await transition(event, "resume") } }
                        Button("End", role: .destructive) { Task { await transition(event, "end") } }
                    }
                    Text("Existing paid entitlements remain recoverable after pause or end.").font(.footnote).foregroundStyle(.secondary)
                }
                if let summary { sales(summary, event: event) }
            }
        }
        .navigationTitle("Commercial Events & Sales")
        .task { await refresh() }
    }

    @ViewBuilder private func sales(_ value: OperatorSalesSummary, event: OperatorEventSummary) -> some View {
        Section("Sales Provenance") {
            LabeledContent("QR Ph Verified (live)", value: PHPPriceFormatter.string(centavos: value.verifiedQRPhLiveCentavos))
            LabeledContent("QR Ph TEST (excluded)", value: PHPPriceFormatter.string(centavos: value.verifiedQRPhTestCentavos))
            LabeledContent("Cash Self-Reported", value: PHPPriceFormatter.string(centavos: value.cashSelfReportedCentavos))
            if let physical = value.physicalCashCount {
                LabeledContent("Cash Physically Counted", value: PHPPriceFormatter.string(centavos: physical.countedCentavos))
                LabeledContent("Cash Variance", value: PHPPriceFormatter.string(centavos: physical.varianceCentavos))
                if physical.provisional { Label("Provisional: offline sync is incomplete", systemImage: "exclamationmark.triangle") }
            } else { Text("Cash reconciliation: NOT RECONCILED").foregroundStyle(.secondary) }
            Text("Provider fees and bank settlement are not reported because no authoritative payout data is available.").font(.footnote)
        }
        Section("Print Utilization") {
            LabeledContent("Purchased", value: "\(value.printUtilization.purchased)")
            LabeledContent("Confirmed", value: "\(value.printUtilization.confirmed)")
            LabeledContent("Uncertain", value: "\(value.printUtilization.uncertain)")
            LabeledContent("Failed", value: "\(value.printUtilization.failed)")
        }
        Section("End-of-Event Cash Count") {
            TextField("Counted centavos", value: $countedCentavos, format: .number).keyboardType(.numberPad)
            TextField("Reason", text: $countReason)
            Button("Save New Count") { Task { await saveCount(event.id) } }.disabled(countedCentavos < 0 || countReason.isEmpty)
            Text("Corrections append a new audited count; they never overwrite guest-declared cash.").font(.footnote).foregroundStyle(.secondary)
        }
        Section("Export") {
            Button("Prepare Event CSV") { Task { await export(event) } }
            if let exportURL { ShareLink(item: exportURL) { Label("Share CSV", systemImage: "square.and.arrow.up") } }
        }
    }

    private func refresh() async { guard let client else { status = "Payments API is not configured."; return }; do { events = try await client.listEvents(); status = "Loaded \(events.count) server events." } catch { status = error.localizedDescription } }
    private func createEvent() async { guard let client else { return }; do { _ = try await client.createEvent(name:eventName,venue:venue); eventName=""; venue=""; await refresh() } catch { status=error.localizedDescription } }
    private func transition(_ event: OperatorEventSummary, _ action: String) async { guard let client else { return }; do { _ = try await client.transitionEvent(id:event.id,action:action); await refresh(); await loadSummary(event.id) } catch { status=error.localizedDescription } }
    private func loadSummary(_ id: String) async { guard let client else { return }; do { summary = try await client.eventSummary(id:id) } catch { status=error.localizedDescription } }
    private func saveCount(_ id: String) async { guard let client else { return }; do { _ = try await client.recordCashCount(eventID:id,countedCentavos:countedCentavos,reason:countReason); await loadSummary(id) } catch { status=error.localizedDescription } }
    private func export(_ event: OperatorEventSummary) async { guard let client else { return }; do { let data=try await client.exportCSV(eventID:event.id); let url=FileManager.default.temporaryDirectory.appending(path:"\(event.id)-sales.csv"); try data.write(to:url,options:.atomic); exportURL=url } catch { status=error.localizedDescription } }
}
