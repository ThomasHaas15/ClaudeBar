import SwiftUI

struct StatsTab: View {
    @Environment(StatsStore.self) private var stats

    var body: some View {
        let merged = stats.merged
        // Both the cards and the grid want this, and it is rebuilt from two
        // dictionaries every time it is asked for.
        let dailyTokens = merged.dailyTokens
        VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
            cards(merged, dailyTokens: dailyTokens)
            // Driven by the merged view, not the stats cache: that file is
            // rewritten only when someone opens `/usage` in Claude Code, so a
            // heatmap fed from it alone stops moving the day you stop opening
            // the dialog — and never starts for anyone who never has.
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "Activity · Last \(HeatmapGrid.fittedWeeks) weeks")
                if merged.hasData {
                    HeatmapGrid(dailyActivity: merged.dailyActivity, dailyTokens: dailyTokens)
                } else {
                    Text("No activity recorded yet.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func cards(_ merged: MergedStats, dailyTokens: [String: Int]) -> some View {
        let totalSessions = merged.totalSessions
        let totalTokens = merged.totalTokens
        let dates = merged.allActiveDates
        let currentStreak = StreakCalculator.current(from: dates, today: stats.today)
        let longestStreak = StreakCalculator.longest(from: dates)
        let longest = stats.cache?.longestSession
        // The same span the heatmap draws, so the two cannot disagree about
        // what "recently" means.
        let window = HeatmapGrid.window(endingOn: stats.today)
        let activeInWindow = activeDays(since: window.start, from: dates)

        let active = merged.daysWithActivity
        let last7Days = PeriodTotals.trailing(days: 7, tokens: dailyTokens, active: active, today: stats.today)
        let last30Days = PeriodTotals.trailing(days: 30, tokens: dailyTokens, active: active, today: stats.today)

        // Ordered by the span each one covers, shortest first: the last week,
        // the last month, the streak running now, the longest session ever,
        // then the lifetime totals. Reading down the tab widens the window.
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                trendCard(days: 7, last7Days)
                trendCard(days: 30, last30Days)
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
            HStack(spacing: 10) {
                StatCard(
                    title: "Total sessions",
                    value: "\(totalSessions)",
                    subtitle: "\(activeInWindow)/\(window.days) active days"
                )
                StatCard(
                    title: "Total tokens",
                    value: TokenFormat.compact(totalTokens),
                    subtitle: "Input + output"
                )
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func trendCard(days: Int, _ trend: PeriodTrend) -> some View {
        StatCard(
            title: "Last \(days) days",
            value: TokenFormat.compact(trend.total),
            subtitle: trendSubtitle(trend),
            delta: trend.change.map { StatCard.Delta(change: $0) }
        )
        .help(trendHelp(trend, basis: "the \(days) days before those"))
    }

    /// What the arrow is measured against, in the space of one line — named as
    /// a span rather than as "the week before", so it is never a guess which
    /// days went into it.
    private func trendSubtitle(_ trend: PeriodTrend) -> String {
        guard trend.complete else { return "Some days not recorded" }
        let span = spanLabel(trend)
        guard trend.previousComplete else { return "\(span) not recorded" }
        guard trend.previous > 0 else { return "No tokens · \(span)" }
        return "vs \(TokenFormat.compact(trend.previous)) · \(span)"
    }

    private func trendHelp(_ trend: PeriodTrend, basis: String) -> String {
        let measured = "\(spanLabel(trend)) — \(basis)"
        guard trend.complete else {
            return """
            Days in this period were worked on but have no token figure left: \
            Claude Code had already pruned their transcripts when ClaudeBar \
            first looked. The total is short by an unknown amount, so there is \
            nothing to compare.
            """
        }
        guard trend.previousComplete else {
            return """
            Measured against \(measured) — but those days were worked on and \
            have no token figure left, so there is nothing to compare against \
            yet. ClaudeBar records every day it sees from now on.
            """
        }
        guard trend.previous > 0 else {
            return "Nothing was spent over \(measured)."
        }
        return "\(TokenFormat.compact(trend.previous)) tokens over \(measured)."
    }

    /// The days themselves: "Sep 7", "Sep 7–9", or "Aug 30 – Sep 2" across a
    /// month boundary. Never a month's name, however neatly a window happens
    /// to land on one — both windows roll, and "September" would read as a
    /// calendar month the card does not measure.
    private func spanLabel(_ trend: PeriodTrend) -> String {
        let cal = Calendar(identifier: .gregorian)
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        let start = f.string(from: trend.previousStart)
        if cal.isDate(trend.previousStart, inSameDayAs: trend.previousEnd) { return start }
        if cal.isDate(trend.previousStart, equalTo: trend.previousEnd, toGranularity: .month) {
            f.dateFormat = "d"
            return "\(start)–\(f.string(from: trend.previousEnd))"
        }
        return "\(start) – \(f.string(from: trend.previousEnd))"
    }

    private func activeDays(since start: Date, from dates: [String]) -> Int {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"
        let from = f.string(from: start)
        let to = f.string(from: stats.today)
        return dates.count { $0 >= from && $0 <= to }
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
