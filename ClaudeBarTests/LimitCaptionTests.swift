import Testing
import Foundation
@testable import ClaudeBar

struct LimitCaptionTests {
    private let cal = Calendar(identifier: .gregorian)
    private var now: Date { cal.date(from: DateComponents(year: 2026, month: 4, day: 27, hour: 9))! }

    /// What the Session row says once its window has rolled over. It reads 0 %
    /// at that point, so "Resets after next request" claimed something was
    /// still pending — nothing is left to reset, the next window just hasn't
    /// begun.
    @Test func anEndedWindowSaysWhenTheNextOneBegins() {
        #expect(LimitCaption.text(resetsAt: now.addingTimeInterval(-90 * 60), now: now) == "Starts on next request")
    }

    /// The exact boundary counts as ended: `rolledOver` empties on `<=`, so the
    /// caption has to agree or a window would read 0 % and still name a reset.
    @Test func theResetInstantItselfCountsAsEnded() {
        #expect(LimitCaption.text(resetsAt: now, now: now) == "Starts on next request")
    }

    @Test func aResetLaterTodayShowsTheClockAndZone() {
        let resetsAt = now.addingTimeInterval(3600)
        #expect(
            LimitCaption.text(resetsAt: resetsAt, now: now)
                == "Resets \(DurationFormat.resetClock(resetsAt)) · \(TimeZone.current.identifier)"
        )
    }

    @Test func aResetTomorrowStillShowsJustTheClock() {
        let resetsAt = cal.date(byAdding: .hour, value: 20, to: now)!
        #expect(LimitCaption.text(resetsAt: resetsAt, now: now).contains(TimeZone.current.identifier))
    }

    /// Further out than tomorrow, the clock alone would be ambiguous.
    @Test func aResetLaterInTheWeekNamesTheDate() {
        let resetsAt = cal.date(byAdding: .day, value: 3, to: now)!
        #expect(LimitCaption.text(resetsAt: resetsAt, now: now) == "Resets \(DurationFormat.resetDateTime(resetsAt))")
    }
}
