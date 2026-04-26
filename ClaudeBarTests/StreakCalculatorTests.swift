import Testing
import Foundation
@testable import ClaudeBar

struct StreakCalculatorTests {
    private func date(_ s: String) -> Date {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s)!
    }

    @Test func currentStreakIncludesToday() {
        let today = date("2026-04-26")
        let days = ["2026-04-24", "2026-04-25", "2026-04-26"]
        #expect(StreakCalculator.current(from: days, today: today) == 3)
    }

    @Test func currentStreakAllowsTodayMissing() {
        let today = date("2026-04-26")
        let days = ["2026-04-24", "2026-04-25"]
        #expect(StreakCalculator.current(from: days, today: today) == 2)
    }

    @Test func currentStreakZeroWhenGap() {
        let today = date("2026-04-26")
        let days = ["2026-04-20", "2026-04-21"]
        #expect(StreakCalculator.current(from: days, today: today) == 0)
    }

    @Test func longestStreakAcrossGaps() {
        let days = ["2026-04-01","2026-04-02","2026-04-03","2026-04-10","2026-04-11"]
        #expect(StreakCalculator.longest(from: days) == 3)
    }
}
