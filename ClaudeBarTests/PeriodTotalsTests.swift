import Testing
import Foundation
@testable import ClaudeBar

struct PeriodTotalsTests {
    private func date(_ s: String) -> Date {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s)!
    }

    private func day(_ trend: PeriodTrend, _ keyPath: KeyPath<PeriodTrend, Date>) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: trend[keyPath: keyPath])
    }

    /// The window ends today and counts today as one of its days, so seven
    /// days back from a Wednesday reaches the Thursday before — not the
    /// Monday a calendar week would have started on.
    @Test func theWindowEndsTodayAndCountsIt() {
        let tokens = [
            "2026-09-09": 500,      // the day before the window opens
            "2026-09-10": 100,      // its first day
            "2026-09-14": 200,
            "2026-09-16": 300       // today
        ]
        let week = PeriodTotals.trailing(
            days: 7,
            tokens: tokens,
            active: Set(tokens.keys),
            today: date("2026-09-16")
        )
        #expect(week.total == 600)
        #expect(day(week, \.previousEnd) == "2026-09-09")
    }

    /// Against the seven days before those, never against a calendar week: the
    /// two windows are the same length on every day of the week, so a Monday
    /// morning is not set beside a whole week's work.
    @Test func theWindowComparesTheSameNumberOfDaysBefore() {
        let tokens = [
            "2026-09-02": 900,      // before the baseline opens
            "2026-09-03": 50,       // its first day
            "2026-09-07": 50,
            "2026-09-09": 100,      // its last day
            "2026-09-10": 300,      // the window itself
            "2026-09-16": 300
        ]
        let week = PeriodTotals.trailing(
            days: 7,
            tokens: tokens,
            active: Set(tokens.keys),
            today: date("2026-09-16")
        )
        #expect(week.previous == 200)
        #expect(day(week, \.previousStart) == "2026-09-03")
        #expect(day(week, \.previousEnd) == "2026-09-09")
        #expect(week.change == 2.0)     // 600 against 200
    }

    /// Thirty days works the same way, and neither window cares where a month
    /// begins or ends.
    @Test func thirtyDaysRollsStraightThroughMonthBoundaries() {
        let tokens = [
            "2026-07-18": 900,      // before the baseline opens
            "2026-07-19": 100,      // its first day
            "2026-08-01": 5_000,
            "2026-08-17": 900,      // its last day
            "2026-08-18": 50,       // the window itself
            "2026-09-16": 100
        ]
        let month = PeriodTotals.trailing(
            days: 30,
            tokens: tokens,
            active: Set(tokens.keys),
            today: date("2026-09-16")
        )
        #expect(month.total == 150)
        #expect(month.previous == 6_000)
        #expect(day(month, \.previousStart) == "2026-07-19")
        #expect(day(month, \.previousEnd) == "2026-08-17")
    }

    /// Whatever the length of the months it crosses, each window is exactly as
    /// many days as it was asked for.
    @Test func bothWindowsAreExactlyAsLongAsAsked() {
        let cal = Calendar(identifier: .gregorian)
        for days in [7, 30] {
            for today in ["2026-03-01", "2026-03-31", "2026-01-01"] {
                let trend = PeriodTotals.trailing(days: days, tokens: [:], active: [], today: date(today))
                let span = cal.dateComponents(
                    [.day],
                    from: trend.previousStart,
                    to: trend.previousEnd
                ).day
                #expect(span == days - 1)
                let gap = cal.dateComponents([.day], from: trend.previousEnd, to: date(today)).day
                #expect(gap == days)
            }
        }
    }

    /// A day that recorded no work at all is worth zero, and zero is a figure —
    /// it must not make the span read as unknown.
    @Test func quietDaysAreZeroRatherThanMissing() {
        let week = PeriodTotals.trailing(
            days: 7,
            tokens: ["2026-09-14": 400, "2026-09-07": 100],
            active: ["2026-09-14", "2026-09-07"],
            today: date("2026-09-16")
        )
        #expect(week.complete)
        #expect(week.previousComplete)
        #expect(week.total == 400)
        #expect(week.change == 3.0)
    }

    /// A day that *did* work but has no figure left is the other case entirely:
    /// the total is short by an unknown amount, so there is nothing to compare.
    @Test func aWorkedDayWithNoFigureBreaksTheComparison() {
        let tokens = ["2026-09-07": 100, "2026-09-14": 400]
        let active: Set<String> = ["2026-09-07", "2026-09-08", "2026-09-14"]

        let week = PeriodTotals.trailing(days: 7, tokens: tokens, active: active, today: date("2026-09-16"))
        #expect(week.complete)
        #expect(!week.previousComplete)
        #expect(week.change == nil)
        // The total it can account for is still worth showing.
        #expect(week.total == 400)
        #expect(week.previous == 100)
    }

    @Test func aGapInTheCurrentSpanBreaksItTheSameWay() {
        let week = PeriodTotals.trailing(
            days: 7,
            tokens: ["2026-09-07": 100, "2026-09-14": 400],
            active: ["2026-09-07", "2026-09-14", "2026-09-15"],
            today: date("2026-09-16")
        )
        #expect(!week.complete)
        #expect(week.change == nil)
    }

    /// Nothing to divide by. A first week is not an infinite improvement.
    @Test func anEmptyBaselineHasNoChange() {
        let week = PeriodTotals.trailing(
            days: 7,
            tokens: ["2026-09-14": 400],
            active: ["2026-09-14"],
            today: date("2026-09-16")
        )
        #expect(week.previous == 0)
        #expect(week.previousComplete)
        #expect(week.change == nil)
    }
}
