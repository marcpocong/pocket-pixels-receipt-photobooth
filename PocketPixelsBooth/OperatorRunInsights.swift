import SwiftUI
import Charts

/// Exact journal scope, shared by Home and Reports. No retained audit or launch counters.
nonisolated struct OperatorRunInsights: Equatable, Sendable {
    nonisolated struct Hour: Identifiable, Equatable, Sendable {
        let date: Date
        let count: Int
        var id: Date { date }
    }
    let sessions: [EventRunSession]
    let statistics: EventRunStatistics
    let hours: [Hour]

    init(runID: String, sessions: [EventRunSession], calendar: Calendar = .current) {
        var seen = Set<String>()
        self.sessions = sessions.filter { $0.runID == runID && seen.insert($0.sessionID).inserted }
        statistics = EventRunStatistics(sessions: self.sessions)
        let completed = self.sessions.compactMap(\.completedAt)
        hours = Dictionary(grouping: completed) { calendar.dateInterval(of: .hour, for: $0)?.start ?? $0 }
            .map { Hour(date: $0.key, count: $0.value.count) }.sorted { $0.date < $1.date }
    }
}

struct OperatorRunMetricsView: View {
    let statistics: EventRunStatistics?
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        OperatorMetricLayout(minimumCardWidth: typeSize.isAccessibilitySize ? 260 : 210) {
            metric("Completed sessions", value: statistics?.completed, symbol: "person.crop.square")
            metric("Copies sent to printer", value: statistics?.delivered, symbol: "printer")
            metric("Verified galleries", value: statistics?.galleriesVerified, symbol: "checkmark.icloud")
            metric("Waiting galleries", value: statistics?.galleriesAwaitingVerification, symbol: "clock")
        }.frame(maxWidth: 940, alignment: .leading)
    }
    private func metric(_ title: String, value: Int?, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(value.map(String.init) ?? "—").font(.system(.title, design: .rounded).weight(.semibold)).monospacedDigit()
            Text(title).font(.callout).foregroundStyle(OperatorPalette.secondaryText).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .topLeading)
        .padding(14).background(OperatorPalette.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).stroke(OperatorPalette.border) }
        .accessibilityElement(children: .combine)
    }
}

/// Always two or four columns, with row heights measured from the actual Dynamic Type size.
private struct OperatorMetricLayout: Layout {
    let minimumCardWidth: CGFloat
    private let spacing: CGFloat = 12
    private func measurements(width: CGFloat, subviews: Subviews) -> (Int, CGFloat, [CGFloat]) {
        let columns = width >= minimumCardWidth * 4 + spacing * 3 ? 4 : 2
        let cardWidth = max(1, (width - spacing * CGFloat(columns - 1)) / CGFloat(columns))
        var rows: [CGFloat] = []
        for index in stride(from: 0, to: subviews.count, by: columns) {
            rows.append((index..<min(index + columns, subviews.count)).map {
                subviews[$0].sizeThatFits(ProposedViewSize(width: cardWidth, height: nil)).height
            }.max() ?? 0)
        }
        return (columns, cardWidth, rows)
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 940
        let (_, _, rows) = measurements(width: width, subviews: subviews)
        return CGSize(width: width, height: rows.reduce(0, +) + CGFloat(max(0, rows.count - 1)) * spacing)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (columns, width, rows) = measurements(width: bounds.width, subviews: subviews)
        var y = bounds.minY
        for (row, height) in rows.enumerated() {
            for column in 0..<columns {
                let index = row * columns + column
                guard index < subviews.count else { continue }
                subviews[index].place(at: CGPoint(x: bounds.minX + CGFloat(column) * (width + spacing), y: y),
                    anchor: .topLeading, proposal: ProposedViewSize(width: width, height: height))
            }
            y += height + spacing
        }
    }
}

struct OperatorReportCharts: View {
    let insights: OperatorRunInsights
    var body: some View {
        Section("Sessions by hour") {
            if insights.hours.isEmpty {
                Text("No completed sessions in this run yet.").foregroundStyle(OperatorPalette.secondaryText)
            } else {
                Chart(insights.hours) { hour in
                    BarMark(x: .value("Hour", hour.date, unit: .hour), y: .value("Completed sessions", hour.count))
                        .foregroundStyle(OperatorPalette.accent)
                        .accessibilityLabel(hour.date.formatted(date: .abbreviated, time: .shortened))
                        .accessibilityValue("\(hour.count) completed sessions")
                }
                .chartYAxis { AxisMarks(values: .automatic(desiredCount: 4)) }
                .frame(height: 168).padding(.vertical, 8)
                Text("Completion time · this iPad · selected run only").font(.caption).foregroundStyle(OperatorPalette.secondaryText)
            }
        }
        Section("Receipt formats") {
            if insights.statistics.completedByFormat.isEmpty {
                Text("Receipt formats appear after a session completes.").foregroundStyle(OperatorPalette.secondaryText)
            } else {
                let formats = insights.statistics.completedByFormat.keys.sorted()
                Chart(formats, id: \.self) { format in
                    BarMark(x: .value("Sessions", insights.statistics.completedByFormat[format] ?? 0),
                            y: .value("Format", BoothFormat(rawValue: format)?.displayName ?? format))
                        .foregroundStyle(OperatorPalette.accent.opacity(0.75))
                        .annotation(position: .trailing) { Text(String(insights.statistics.completedByFormat[format] ?? 0)).font(.caption).monospacedDigit() }
                }
                .frame(height: CGFloat(max(1, formats.count)) * 36 + 28).padding(.vertical, 8)
            }
        }
    }
}

/// Loads every exact journal record. Corruption is explicit; stale data never becomes a zero.
struct OperatorHomeMetricsView: View {
    @ObservedObject var runs: EventRunStore
    @State private var sessions: [EventRunSession]?
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Event activity").font(.headline)
                Spacer()
                Text("THIS IPAD").font(.caption.weight(.semibold)).tracking(1).foregroundStyle(OperatorPalette.secondaryText)
            }
            Text(runs.operational.map { "\($0.context.name.isEmpty ? "Regular Booth" : $0.context.name) · since \($0.createdAt.formatted(date: .abbreviated, time: .shortened))" }
                 ?? "No current event run recorded").font(.callout).foregroundStyle(OperatorPalette.secondaryText)
            OperatorRunMetricsView(statistics: statistics)
            if let error = error ?? runs.storageError {
                Label(error, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(OperatorPalette.warning)
            } else if sessions == nil { ProgressView("Reading saved activity…").font(.footnote) }
            else if runs.operational == nil {
                Text("Statistics begin when an event run is recorded. Earlier sessions remain in Reports.").font(.footnote).foregroundStyle(OperatorPalette.secondaryText)
            } else {
                Text("Transport delivery does not confirm paper output. Reprints are separate.\(runs.operational?.recordedAfterUpgrade == true ? " This run began before recording; earlier activity is incomplete." : "")")
                    .font(.footnote).foregroundStyle(OperatorPalette.secondaryText)
            }
        }
        .task(id: runs.revision) { await reload() }
    }
    private var statistics: EventRunStatistics? {
        guard error == nil, runs.storageError == nil, let sessions, let run = runs.operational else { return nil }
        return OperatorRunInsights(runID: run.id, sessions: sessions).statistics
    }
    private func reload() async {
        let directory = runs.directory
        do {
            let loaded = try await Task.detached(priority: .utility) { try EventRunStore.loadSessions(directory: directory) }.value
            guard !Task.isCancelled else { return }
            sessions = loaded; error = nil
        } catch {
            guard !Task.isCancelled else { return }
            sessions = nil; self.error = "Event statistics unavailable. Saved records were retained for review."
        }
    }
}
