import Foundation

/// A calendar period's tokens beside the period before it.
///
/// The week compares like with like — a Monday morning's work set against all
/// of last week is a red arrow every Monday, which says nothing about how the
/// week is going, so a Wednesday puts Mon–Wed against last week's Mon–Wed.
///
/// The month compares against the whole of the month before, because half of
/// August is not a thing anybody has a feel for, while August is. The cost is
/// that the arrow leans red early in the month and climbs through it, which a
/// month-long period is slow enough to make legible rather than misleading —
/// the caption names what it measured either way.
struct PeriodTrend: Equatable {
    /// Tokens over the period so far.
    let total: Int
    /// Tokens over the period this one is measured against.
    let previous: Int
    /// The first and last day `previous` covers — what a caption names.
    let previousStart: Date
    let previousEnd: Date
    /// False when a day in the period recorded activity but no token figure:
    /// its transcripts were pruned before ClaudeBar ever saw them, and the
    /// stats cache counts a different number. The total is then short by an
    /// unknown amount, which is not the same as being small — see
    /// `ActivityHistory`.
    let complete: Bool
    let previousComplete: Bool

    /// The change against the period before, as a signed fraction — nil when
    /// there is nothing honest to compare: a short figure on either side, or a
    /// baseline of nothing at all.
    var change: Double? {
        guard complete, previousComplete, previous > 0 else { return nil }
        return (Double(total) - Double(previous)) / Double(previous)
    }
}

enum PeriodTotals {
    /// This calendar week so far, against the same days of last week. Weeks
    /// start on Monday — the way the heatmap draws them, rather than the way
    /// the region setting would have it, so that the two agree on screen.
    static func week(tokens: [String: Int], active: Set<String>, today: Date) -> PeriodTrend {
        let cal = calendar
        let today = cal.startOfDay(for: today)
        let elapsed = (cal.component(.weekday, from: today) + 5) % 7
        let start = cal.date(byAdding: .day, value: -elapsed, to: today) ?? today
        let previousStart = cal.date(byAdding: .day, value: -7, to: start) ?? start
        let previousEnd = cal.date(byAdding: .day, value: elapsed, to: previousStart) ?? previousStart
        return trend(
            current: start...today,
            previous: previousStart...previousEnd,
            tokens: tokens,
            active: active
        )
    }

    /// This calendar month so far, against the whole of the month before.
    static func month(tokens: [String: Int], active: Set<String>, today: Date) -> PeriodTrend {
        let cal = calendar
        let today = cal.startOfDay(for: today)
        let start = cal.date(from: cal.dateComponents([.year, .month], from: today)) ?? today
        let previousStart = cal.date(byAdding: .month, value: -1, to: start) ?? start
        let previousEnd = cal.date(byAdding: .day, value: -1, to: start) ?? start
        return trend(
            current: start...today,
            previous: previousStart...previousEnd,
            tokens: tokens,
            active: active
        )
    }

    private static var calendar: Calendar { Calendar(identifier: .gregorian) }

    private static func trend(
        current: ClosedRange<Date>,
        previous: ClosedRange<Date>,
        tokens: [String: Int],
        active: Set<String>
    ) -> PeriodTrend {
        let now = sum(over: current, tokens: tokens, active: active)
        let before = sum(over: previous, tokens: tokens, active: active)
        return PeriodTrend(
            total: now.tokens,
            previous: before.tokens,
            previousStart: previous.lowerBound,
            previousEnd: previous.upperBound,
            complete: now.complete,
            previousComplete: before.complete
        )
    }

    private static func sum(
        over range: ClosedRange<Date>,
        tokens: [String: Int],
        active: Set<String>
    ) -> (tokens: Int, complete: Bool) {
        let cal = calendar
        let formatter = DateFormatter()
        formatter.calendar = cal
        formatter.dateFormat = "yyyy-MM-dd"

        var total = 0
        var complete = true
        var cursor = range.lowerBound
        while cursor <= range.upperBound {
            let day = formatter.string(from: cursor)
            if let recorded = tokens[day] {
                total += recorded
            } else if active.contains(day) {
                // Worked on, but the figure is gone.
                complete = false
            }
            guard let next = cal.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return (total, complete)
    }
}
