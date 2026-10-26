import SwiftUI

struct CheckoutCleanupRequest: Identifiable {
    let id = UUID()
    let ids: [String]
    var forceLocal = false
}

struct CheckoutCleanupReview: View {
    let ids: [String]
    var forceLocal = false
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
                    if forceLocal {
                        Text("Deletes the workspace checkpoints and retains their original payment identities in Financial Follow-up. Server payments, entitlements, cash journals, photos and print audits remain. Returning guests need operator-assisted recovery; no copy is resent.")
                    } else {
                    LabeledContent("Eligible for permanent deletion", value: "\(count(.eligible))")
                    LabeledContent("Requires archiving instead", value: "\(count(.archiveInstead))")
                    LabeledContent("Currently active or blocked", value: "\(count(.blocked))")
                    LabeledContent("Cannot inspect safely", value: "\(count(.cannotInspect))")
                    Text("Only eligible local checkpoints are removed. Original payments, cash journals, entitlement evidence and print audits remain. Eligibility is checked again for each deletion.").font(.footnote)
                    }
                }
                Section("Selected Checkouts") {
                    ForEach(ids, id: \.self) { id in
                        VStack(alignment: .leading, spacing: 6) {
                            if let checkpoint = recovery.managementStore?.checkpoint(id: id) {
                                Text("\(checkpoint.format) · \(checkpoint.createdAt.formatted())").font(.headline)
                                Text(checkpoint.recoveryReference ?? checkpoint.id).font(.caption.monospaced())
                                Text("\(checkpoint.lastServerState ?? checkpoint.phase.rawValue) · \(PHPPriceFormatter.string(centavos: checkpoint.unitPriceCentavos * checkpoint.copies))")
                            }
                            Text(results[id] ?? decisions[id]?.reason ?? "Checking original records…")
                        }
                    }
                }
                Section {
                    if results.isEmpty {
                        Button(forceLocal ? "Force Delete Local Selected" : "Delete Eligible Selected", role: .destructive) {
                            working = true
                            Task {
                                for id in ids {
                                    do {
                                        if forceLocal { try await recovery.forceDeleteLocalCheckout(id: id) }
                                        else { try await recovery.deleteEligibleCheckout(id: id) }
                                        results[id] = "Deleted local checkpoint."
                                    }
                                    catch { results[id] = error.localizedDescription }
                                }
                                working = false
                            }
                        }.disabled(working || (!forceLocal && (decisions.count != ids.count || count(.eligible) == 0)))
                    } else {
                        Text("\(results.values.filter { $0 == "Deleted local checkpoint." }.count) deleted · \(results.count - results.values.filter { $0 == "Deleted local checkpoint." }.count) retained")
                    }
                    if working { ProgressView("Checking and cleaning up…") }
                }
            }.navigationTitle("Review Checkout Deletion").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.disabled(working) } }
                .interactiveDismissDisabled(working)
                .task {
                    if !forceLocal { for id in ids { decisions[id] = await recovery.checkoutDeletionDecision(id: id) } }
                }
        }
    }
}
