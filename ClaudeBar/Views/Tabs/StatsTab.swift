import SwiftUI

struct StatsTab: View {
    @Environment(StatsStore.self) private var stats

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
            cards
            if let cache = stats.cache {
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(title: "Activity · Last 30 days")
                    HeatmapGrid(dailyActivity: cache.dailyActivity)
                }
            }
        }
    }

    @ViewBuilder
    private var cards: some View {
        let merged = stats.merged
        let totalSessions = merged.totalSessions
        let totalTokens = merged.totalTokens
        let dates = merged.allActiveDates
        let currentStreak = StreakCalculator.current(from: dates)
        let longestStreak = StreakCalculator.longest(from: dates)
        let longest = stats.cache?.longestSession
        let activeInWindow = activeDaysInLast(30, from: dates)

        VStack(spacing: 10) {
            HStack(spacing: 10) {
                StatCard(
                    title: "Total sessions",
                    value: "\(totalSessions)",
                    subtitle: "\(activeInWindow)/30 active days"
                )
                StatCard(
                    title: "Total tokens",
                    value: TokenFormat.compact(totalTokens),
                    subtitle: nil
                )
            }
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                StatCard(
                    title: "Current streak",
                    value: "\(currentStreak)d",
                    subtitle: "Best: \(longestStreak) days"
                )
                StatCard(
                    title: "Longest session",
                    value: longest.map { DurationFormat.dh(TimeInterval($0.duration) / 1000) } ?? "—",
                    subtitle: longest.flatMap(longestSubtitle)
                )
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func activeDaysInLast(_ days: Int, from dates: [String]) -> Int {
        let cal = Calendar(identifier: .gregorian)
        let f = DateFormatter()
        f.calendar = cal
        f.dateFormat = "yyyy-MM-dd"
        let today = cal.startOfDay(for: Date())
        var window: Set<String> = []
        for i in 0..<days {
            if let d = cal.date(byAdding: .day, value: -i, to: today) {
                window.insert(f.string(from: d))
            }
        }
        return Set(dates).intersection(window).count
    }

    private func longestSubtitle(_ longest: StatsCache.LongestSession) -> String? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let d = iso.date(from: longest.timestamp) ?? {
            iso.formatOptions = [.withInternetDateTime]
            return iso.date(from: longest.timestamp)
        }() else { return nil }
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return "\(f.string(from: d)) peak"
    }
}
