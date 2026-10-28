import SwiftUI

struct SessionCleanupRequest: Identifiable {
    let id = UUID()
    let candidates: [RecentSessionArchiveSummary]
}

/// One local deletion confirmation. Dependencies are checked again at the mutation boundary.
struct SessionCleanupReview: View {
    let candidates: [RecentSessionArchiveSummary]
    @ObservedObject var model: RecentSessionsViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var decisions: [String: RecordCleanupDecision] = [:]
    @State private var results: [String: String] = [:]
    @State private var working = false

    private var eligibleCount: Int { decisions.values.filter { $0.category == .eligible }.count }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("\(candidates.count) sessions selected").font(.headline)
                    Text("Delete local photos, receipts and reprint files? Published online galleries, transactions and print history remain.")
                }
                if decisions.count != candidates.count { ProgressView("Checking sessions…") }
                ForEach(candidates.filter { decisions[$0.archiveID]?.category != .eligible }) { summary in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(summary.eventName ?? "Regular Booth").font(.headline)
                        Text(results[summary.archiveID] ?? decisions[summary.archiveID]?.reason ?? "Checking…").font(.callout)
                    }
                }
                if !results.isEmpty {
                    Section {
                        ForEach(candidates.filter { results[$0.archiveID] != "Deleted local media." }) { summary in
                            Text(results[summary.archiveID] ?? "Retained").font(.callout)
                        }
                    }
                }
                Section {
                    Button(eligibleCount == candidates.count ? (candidates.count == 1 ? "Delete Session" : "Delete Selected") : "Delete \(eligibleCount) Eligible Sessions", role: .destructive) {
                        working = true
                        Task {
                            results = await model.deleteSelected(candidates)
                            working = false
                            if candidates.allSatisfy({ results[$0.archiveID] == "Deleted local media." }) { dismiss() }
                        }
                    }.disabled(working || eligibleCount == 0 || decisions.count != candidates.count)
                    Button("Hide Selected Instead") {
                        model.setHidden(Set(candidates.map(\.archiveID)), hidden: true); dismiss()
                    }.disabled(working)
                    if working { ProgressView("Deleting local media…") }
                }
            }
            .navigationTitle(candidates.count == 1 ? "Delete Session?" : "Delete Sessions?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(working) } }
            .interactiveDismissDisabled(working)
            .task { for summary in candidates { decisions[summary.archiveID] = model.deletionDecision(summary) } }
        }
    }
}
