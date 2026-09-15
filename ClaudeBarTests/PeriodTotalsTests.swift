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

    /// Weeks start on Monday, the way the heatmap draws them — the Sunday
    /// before belongs to the week that just ended.
    @Test func weekRunsFromMondayToToday() {
        let tokens = [
            "2026-09-13": 500,      // Sunday, the week before
            "2026-09-14": 100,      // Monday
            "2026-09-15": 200,
            "2026-09-16": 300       // today, a Wednesday
        ]
        let week = PeriodTotals.week(tokens: tokens, active: Set(tokens.keys), today: date("2026-09-16"))
        #expect(week.total == 600)
    }

    /// Against the same days of last week, not against all of it: a Monday's
    /// two hours set beside a whole week is a red arrow every Monday.
    @Test func weekComparesTheSameDaysOfLastWeek() {
        let tokens = [
            "2026-09-07": 50,       // Mon
            "2026-09-08": 50,       // Tue
            "2026-09-09": 100,      // Wed — as far as this week has come
            "2026-09-10": 900,      // Thu, deliberately large and out of scope
            "2026-09-11": 900,
            "2026-09-14": 300,
            "2026-09-15": 300,
            "2026-09-16": 0
        ]
        let week = PeriodTotals.week(tokens: tokens, active: Set(tokens.keys), today: date("2026-09-16"))
        #expect(week.previous == 200)
        #expect(day(week, \.previousStart) == "2026-09-07")
        #expect(day(week, \.previousEnd) == "2026-09-09")
        #expect(week.change == 2.0)     // 600 against 200
    }

    /// The month is measured against the whole of the one before, not against
    /// the same days of it: half of August is not a quantity anyone has a feel
    /// for, while August is.
    @Test func monthComparesAgainstTheWholeMonthBefore() {
        let tokens = [
            "2026-08-01": 100,
            "2026-08-03": 100,
            "2026-08-20": 5_000,    // later in August than this month has reached
            "2026-08-31": 800,      // and its very last day
            "2026-09-01": 50,
            "2026-09-03": 100
        ]
        let month = PeriodTotals.month(tokens: tokens, active: Set(tokens.keys), today: date("2026-09-03"))
        #expect(month.total == 150)
        #expect(month.previous == 6_000)
        #expect(day(month, \.previousStart) == "2026-08-01")
        #expect(day(month, \.previousEnd) == "2026-08-31")
    }

    /// Whatever the length of the month before, the span is all of it.
    @Test func previousMonthRunsToItsOwnLastDay() {
        let february = PeriodTotals.month(tokens: [:], active: [], today: date("2026-03-31"))
        #expect(day(february, \.previousStart) == "2026-02-01")
        #expect(day(february, \.previousEnd) == "2026-02-28")

        let january = PeriodTotals.month(tokens: [:], active: [], today: date("2026-02-01"))
        #expect(day(january, \.previousStart) == "2026-01-01")
        #expect(day(january, \.previousEnd) == "2026-01-31")
    }

    /// A day that recorded no work at all is worth zero, and zero is a figure —
    /// it must not make the span read as unknown.
    @Test func quietDaysAreZeroRatherThanMissing() {
        let week = PeriodTotals.week(
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

        let week = PeriodTotals.week(tokens: tokens, active: active, today: date("2026-09-16"))
        #expect(week.complete)
        #expect(!week.previousComplete)
        #expect(week.change == nil)
        // The total it can account for is still worth showing.
        #expect(week.total == 400)
        #expect(week.previous == 100)
    }

    @Test func aGapInTheCurrentSpanBreaksItTheSameWay() {
        let week = PeriodTotals.week(
            tokens: ["2026-09-07": 100, "2026-09-14": 400],
            active: ["2026-09-07", "2026-09-14", "2026-09-15"],
            today: date("2026-09-16")
        )
        #expect(!week.complete)
        #expect(week.change == nil)
    }

    /// Nothing to divide by. A first week is not an infinite improvement.
    @Test func anEmptyBaselineHasNoChange() {
        let week = PeriodTotals.week(
            tokens: ["2026-09-14": 400],
            active: ["2026-09-14"],
            today: date("2026-09-16")
        )
        #expect(week.previous == 0)
        #expect(week.previousComplete)
        #expect(week.change == nil)
    }
}
