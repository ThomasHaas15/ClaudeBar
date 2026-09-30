import Testing
import Foundation
@testable import ClaudeBar

struct DurationFormatTests {
    @Test func roundsToTheNearestMinute() {
        #expect(DurationFormat.hm(42 * 60 + 20) == "42m")
        #expect(DurationFormat.hm(42 * 60 + 40) == "43m")
    }

    @Test func neverShowsLessThanAMinute() {
        #expect(DurationFormat.hm(10) == "1m")
    }

    @Test func splitsHoursFromMinutes() {
        #expect(DurationFormat.hm(65 * 60) == "1h 5m")
        #expect(DurationFormat.hm(120 * 60) == "2h 0m")
    }
}
