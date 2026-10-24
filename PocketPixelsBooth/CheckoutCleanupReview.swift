import SwiftUI

struct CheckoutCleanupReview: View {
    let ids: [String]
    @ObservedObject var recovery: PaymentRecoveryCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var decisions: [String: RecordCleanupDecision] = [:]
    @State private var results: [String: String] = [:]
    @State private var working = false

    private func count(_ category: RecordCleanupDecision.Category) -> Int { decisions.values.filter { $0.category == category }.count }
    var body: some View {
        NavigationStack {
            List {
                Section("Preflight Summary") {
                    LabeledContent("Eligible for permanent deletion", value: "\(count(.eligible))")
                    LabeledContent("Requires archiving instead", value: "\(count(.archiveInstead))")
                    LabeledContent("Currently active or blocked", value: "\(count(.blocked))")
                    LabeledContent("Cannot inspect safely", value: "\(count(.cannotInspect))")
                    Text("Only eligible local checkpoints are removed. Original payments, cash journals, entitlement evidence and print audits remain. Eligibility is checked again for each deletion.").font(.footnote)
                }
                Section("Selected Checkouts") {
                    ForEach(ids, id: \.self) { id in
                        VStack(alignment: .leading, spacing: 6) {
                            if let checkpoint = recovery.managementStore?.checkpoint(id: id) {
                                Text("\(checkpoint.format) · \(checkpoint.createdAt.formatted())").font(.headline)
                            }
                            Text(results[id] ?? decisions[id]?.reason ?? "Checking original records…")
                        }
                    }
                }
                Section {
                    if results.isEmpty {
                        Button("Delete Eligible Selected", role: .destructive) {
                            working = true
                            Task {
                                for id in ids {
                                    do { try await recovery.deleteEligibleCheckout(id: id); results[id] = "Deleted local checkpoint." }
                                    catch { results[id] = error.localizedDescription }
                                }
                                working = false
                            }
                        }.disabled(working || decisions.count != ids.count || count(.eligible) == 0)
                    } else {
                        Text("\(results.values.filter { $0 == "Deleted local checkpoint." }.count) deleted · \(results.count - results.values.filter { $0 == "Deleted local checkpoint." }.count) retained")
                    }
                    if working { ProgressView("Checking and cleaning up…") }
                }
            }.navigationTitle("Review Checkout Deletion").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.disabled(working) } }
                .interactiveDismissDisabled(working)
                .task {
                    for id in ids { decisions[id] = await recovery.checkoutDeletionDecision(id: id) }
                }
        }
    }
}
