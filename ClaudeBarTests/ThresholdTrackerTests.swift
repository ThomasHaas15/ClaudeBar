import Testing
import Foundation
@testable import ClaudeBar

struct ThresholdTrackerTests {
    private func defaults() -> UserDefaults {
        let d = UserDefaults(suiteName: "ClaudeBarTests.\(UUID().uuidString)")!
        d.removePersistentDomain(forName: "ClaudeBarTests")
        return d
    }

    private func limits(fiveHour: Double?, sevenDay: Double? = nil, resetsAt: Date = Date(timeIntervalSince1970: 1_800_000_000)) -> RateLimits {
        RateLimits(
            fiveHour: fiveHour.map { .init(usedPercentage: $0, resetsAt: resetsAt) },
            sevenDay: sevenDay.map { .init(usedPercentage: $0, resetsAt: resetsAt) },
            sevenDayOpus: nil,
            sevenDaySonnet: nil
        )
    }

    @Test func firesWarnOnCrossing80() {
        let tracker = ThresholdTracker(defaults: defaults())
        let prev = limits(fiveHour: 70)
        let cur = limits(fiveHour: 85)
        let events = tracker.crossings(previous: prev, current: cur)
        #expect(events.count == 1)
        #expect(events.first?.level == .warn)
        #expect(events.first?.kind == .fiveHour)
    }

    @Test func doesNotRefireSameLevelSameWindow() {
        let tracker = ThresholdTracker(defaults: defaults())
        let prev = limits(fiveHour: 70)
        let cur = limits(fiveHour: 85)
        _ = tracker.crossings(previous: prev, current: cur)
        let next = limits(fiveHour: 90)
        let events = tracker.crossings(previous: cur, current: next)
        #expect(events.isEmpty)
    }

    @Test func firesCriticalOnReaching100() {
        let tracker = ThresholdTracker(defaults: defaults())
        let prev = limits(fiveHour: 90)
        let cur = limits(fiveHour: 100)
        let events = tracker.crossings(previous: prev, current: cur)
        #expect(events.count == 1)
        #expect(events.first?.level == .critical)
    }

    @Test func reArmsAfterReset() {
        let d = defaults()
        let tracker = ThresholdTracker(defaults: d)
        let firstReset = Date(timeIntervalSince1970: 1_800_000_000)
        let secondReset = Date(timeIntervalSince1970: 1_800_018_000)
        let prev = limits(fiveHour: 70, resetsAt: firstReset)
        let cur = limits(fiveHour: 85, resetsAt: firstReset)
        _ = tracker.crossings(previous: prev, current: cur)

        let nextWindowPrev = limits(fiveHour: 10, resetsAt: secondReset)
        let nextWindowCur = limits(fiveHour: 90, resetsAt: secondReset)
        let events = tracker.crossings(previous: nextWindowPrev, current: nextWindowCur)
        #expect(events.contains { $0.level == .warn })
    }

    @Test func firesOnFirstObservationAlreadyAboveThreshold() {
        let tracker = ThresholdTracker(defaults: defaults())
        let cur = limits(fiveHour: 92)
        let events = tracker.crossings(previous: nil, current: cur)
        #expect(events.count == 1)
        #expect(events.first?.level == .warn)
    }
}
