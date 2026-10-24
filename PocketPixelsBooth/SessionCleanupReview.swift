import SwiftUI

struct SessionCleanupRequest: Identifiable {
    let id = UUID()
    let candidates: [RecentSessionArchiveSummary]
}

struct SessionCleanupReview: View {
    let candidates: [RecentSessionArchiveSummary]
    @ObservedObject var model: RecentSessionsViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var decisions: [String: RecordCleanupDecision] = [:]
    @State private var sizes: [String: Int] = [:]
    @State private var results: [String: String] = [:]
    @State private var working = false

    var body: some View {
        NavigationStack {
            List {
                Section("Delete Local Sessions") {
                    Text("\(candidates.count) sessions · approximately \(ByteCountFormatter.string(fromByteCount: Int64(sizes.values.reduce(0, +)), countStyle: .file))")
                    Text("Saved receipts, thermal previews, original photo files, thumbnails and reprint data in the selected local archives will be removed. Local reprinting will become unavailable.")
                    Text("Public galleries, payment records, event statistics, print audits and separately protected recovery copies remain. Copies already saved to Photos remain in Photos.")
                }
                Section("Dependency Review") {
                    ForEach(candidates) { summary in
                        VStack(alignment: .leading, spacing: 6) {
                            Text("\(summary.eventName ?? "Regular Booth") · \(summary.createdAt.formatted())").font(.headline)
                            Text(results[summary.archiveID] ?? decisions[summary.archiveID]?.reason ?? "Checking…").font(.callout)
                        }
                    }
                }
                Section {
                    if results.isEmpty {
                        Button("Delete Eligible Sessions", role: .destructive) {
                            working = true
                            Task { results = await model.deleteSelected(candidates); working = false }
                        }.disabled(working || decisions.values.allSatisfy { $0.category != .eligible } || decisions.count != candidates.count)
                        Button("Hide Selected Instead") { model.setHidden(Set(candidates.map(\.archiveID)), hidden: true); dismiss() }.disabled(working)
                    } else {
                        Text("\(results.values.filter { $0 == "Deleted local media." }.count) deleted · \(candidates.count - results.values.filter { $0 == "Deleted local media." }.count) retained or unfinished")
                    }
                    if working { ProgressView("Removing eligible local media…") }
                }
            }.navigationTitle("Review Local Deletion").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.disabled(working) } }
                .interactiveDismissDisabled(working)
                .task {
                    for summary in candidates {
                        decisions[summary.archiveID] = model.deletionDecision(summary)
                        sizes[summary.archiveID] = await model.deletionSize(summary.archiveID)
                    }
                }
        }
    }
}
