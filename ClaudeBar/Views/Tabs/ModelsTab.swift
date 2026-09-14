import SwiftUI

struct ModelsTab: View {
    @Environment(StatsStore.self) private var stats

    var body: some View {
        let merged = stats.merged
        VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
            SectionHeader(title: "Token Share · All Time")
            if merged.hasData {
                let entries = makeEntries(merged.modelTotals)
                if entries.isEmpty {
                    Text("No model usage recorded.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 12) {
                        ForEach(entries) { entry in
                            ModelRow(
                                displayName: entry.displayName,
                                percent: entry.percent,
                                usage: entry.usage,
                                dotColor: entry.color
                            )
                            if entry.id != entries.last?.id {
                                Divider().opacity(0.4)
                            }
                        }
                    }
                    if let favorite = entries.max(by: { $0.percent < $1.percent }) {
                        Divider().padding(.top, 4)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Favorite Model").sectionHeaderStyle()
                            HStack(spacing: 6) {
                                Text(favorite.displayName).font(.body.weight(.semibold))
                                Text("\(String(format: "%.1f", favorite.percent))% of usage")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } else {
                Text("Waiting for stats…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private struct Entry: Identifiable {
        let id: String
        let displayName: String
        let usage: TokenUsage
        let percent: Double
        let color: Color
    }

    private func makeEntries(_ usage: [String: TokenUsage]) -> [Entry] {
        let filtered = usage.filter { ModelNames.isUserFacing(id: $0.key) && $0.value.billable > 0 }
        // Share of the tokens the app counts everywhere else, so the rows add
        // up to the Stats tab's total rather than to a column of it.
        let total = filtered.values.reduce(0) { $0 + $1.billable }
        let palette: [Color] = [.blue, .green, .orange, .gray, .purple, .pink, .yellow, .red]
        let sorted = filtered.sorted { $0.value.billable > $1.value.billable }
        return sorted.enumerated().map { idx, kv in
            let pct = total > 0 ? Double(kv.value.billable) / Double(total) * 100 : 0
            return Entry(
                id: kv.key,
                displayName: ModelNames.display(for: kv.key),
                usage: kv.value,
                percent: pct,
                color: palette[idx % palette.count]
            )
        }
    }
}
