import Foundation

/// A trailing window of days beside the window of the same length before it.
///
/// Both windows are rolling and equally long, so the comparison is like for
/// like on every day of the week: the last 7 days against the 7 before those,
/// the last 30 against the 30 before. A calendar period cannot manage that —
/// a Monday morning's work set against all of last week is a red arrow every
/// Monday, which says nothing about how the week is going — so neither window
/// waits for a week or a month to turn over. The caption names the days it
/// measured against either way.
struct PeriodTrend: Equatable {
    /// Tokens over the window ending today.
    let total: Int
    /// Tokens over the window this one is measured against.
    let previous: Int
    /// The first and last day `previous` covers — what a caption names.
    let previousStart: Date
    let previousEnd: Date
    /// False when a day in the window recorded activity but no token figure:
    /// its transcripts were pruned before ClaudeBar ever saw them, and the
    /// stats cache counts a different number. The total is then short by an
    /// unknown amount, which is not the same as being small — see
    /// `ActivityHistory`.
    let complete: Bool
    let previousComplete: Bool

    /// The change against the window before, as a signed fraction — nil when
    /// there is nothing honest to compare: a short figure on either side, or a
    /// baseline of nothing at all.
    var change: Double? {
        guard complete, previousComplete, previous > 0 else { return nil }
        return (Double(total) - Double(previous)) / Double(previous)
    }
}

enum PeriodTotals {
    /// The `days` days ending today, against the `days` days before those.
    /// Today counts as one of them, so `days: 7` on a Wednesday runs from last
    /// Thursday and is measured against the Thursday–Wednesday before that.
    static func trailing(
        days: Int,
        tokens: [String: Int],
        active: Set<String>,
        today: Date
    ) -> PeriodTrend {
        let cal = calendar
        let today = cal.startOfDay(for: today)
        let start = cal.date(byAdding: .day, value: -(days - 1), to: today) ?? today
        let previousEnd = cal.date(byAdding: .day, value: -1, to: start) ?? start
        let previousStart = cal.date(byAdding: .day, value: -(days - 1), to: previousEnd) ?? previousEnd
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
