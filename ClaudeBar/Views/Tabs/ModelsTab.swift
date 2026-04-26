import SwiftUI

struct ModelsTab: View {
    @Environment(StatsStore.self) private var stats

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
            SectionHeader(title: "Token Share · All Time")
            if stats.cache != nil || !stats.live.modelInputOutput.isEmpty {
                let entries = makeEntries(stats.merged.modelTotals)
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
                                inputTokens: entry.input,
                                outputTokens: entry.output,
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
        let input: Int
        let output: Int
        let percent: Double
        let color: Color
    }

    private func makeEntries(_ usage: [String: TokenPair]) -> [Entry] {
        let filtered = usage.filter { ModelNames.isUserFacing(id: $0.key) }
        let totalOutput = filtered.values.reduce(0) { $0 + $1.output }
        let palette: [Color] = [.blue, .green, .orange, .gray, .purple, .pink, .yellow, .red]
        let sorted = filtered.sorted { $0.value.output > $1.value.output }
        return sorted.enumerated().map { idx, kv in
            let pct = totalOutput > 0 ? Double(kv.value.output) / Double(totalOutput) * 100 : 0
            return Entry(
                id: kv.key,
                displayName: ModelNames.display(for: kv.key),
                input: kv.value.input,
                output: kv.value.output,
                percent: pct,
                color: palette[idx % palette.count]
            )
        }
    }
}

enum ModelNames {
    static func isUserFacing(id: String) -> Bool {
        let lowered = id.lowercased()
        if lowered == "<synthetic>" || lowered.contains("synthetic") { return false }
        return true
    }

    static func display(for id: String) -> String {
        let lowered = id.lowercased()
        if lowered.contains("opus-4-7") { return "Opus 4.7" }
        if lowered.contains("opus-4-6") { return "Opus 4.6" }
        if lowered.contains("opus-4-1") { return "Opus 4.1" }
        if lowered.contains("opus") { return "Opus" }
        if lowered.contains("sonnet-4-6") { return "Sonnet 4.6" }
        if lowered.contains("sonnet") { return "Sonnet" }
        if lowered.contains("haiku-4-5") { return "Haiku 4.5" }
        if lowered.contains("haiku") { return "Haiku" }
        return id
    }
}
