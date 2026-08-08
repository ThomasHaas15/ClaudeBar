import Testing
import Foundation
@testable import ClaudeBar

struct WeeklyResetTrackerTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "ClaudeBarTests.\(UUID().uuidString)")!
    }

    private func weekly(_ percent: Double, resetsAt: Date) -> RateLimits {
        RateLimits(
            fiveHour: nil,
            sevenDay: .init(usedPercentage: percent, resetsAt: resetsAt),
            sevenDayOpus: nil,
            sevenDaySonnet: nil
        )
    }

    @Test func staysQuietOnFirstObservation() {
        let tracker = WeeklyResetTracker(defaults: defaults())
        let events = tracker.resets(in: weekly(88, resetsAt: now.addingTimeInterval(3600)), now: now)
        #expect(events.isEmpty)
    }

    @Test func announcesRolloverOfABusyWeek() {
        let tracker = WeeklyResetTracker(defaults: defaults())
        let firstReset = now.addingTimeInterval(60)
        _ = tracker.resets(in: weekly(88, resetsAt: firstReset), now: now)

        // The reset lands: `rolledOver` has already zeroed the percentage and
        // advanced the boundary a week, which is what the tracker sees.
        let after = now.addingTimeInterval(120)
        let events = tracker.resets(
            in: weekly(0, resetsAt: firstReset.addingTimeInterval(RateLimits.week)),
            now: after
        )
        #expect(events.count == 1)
        #expect(events.first?.kind == .sevenDay)
        #expect(events.first?.previousPercent == 88)
        #expect(events.first?.resetsAt == firstReset.addingTimeInterval(RateLimits.week))
    }

    @Test func reportsThePeakNotTheZeroedReading() {
        let tracker = WeeklyResetTracker(defaults: defaults())
        let firstReset = now.addingTimeInterval(60)
        _ = tracker.resets(in: weekly(81, resetsAt: firstReset), now: now)
        _ = tracker.resets(in: weekly(94, resetsAt: firstReset), now: now.addingTimeInterval(30))

        let events = tracker.resets(
            in: weekly(0, resetsAt: firstReset.addingTimeInterval(RateLimits.week)),
            now: now.addingTimeInterval(120)
        )
        #expect(events.first?.previousPercent == 94)
    }

    @Test func staysQuietForAWeekThatWasBarelyUsed() {
        let tracker = WeeklyResetTracker(defaults: defaults())
        let firstReset = now.addingTimeInterval(60)
        _ = tracker.resets(in: weekly(12, resetsAt: firstReset), now: now)

        let events = tracker.resets(
            in: weekly(0, resetsAt: firstReset.addingTimeInterval(RateLimits.week)),
            now: now.addingTimeInterval(120)
        )
        #expect(events.isEmpty)
    }

    @Test func announcesOnlyOncePerWindow() {
        let tracker = WeeklyResetTracker(defaults: defaults())
        let firstReset = now.addingTimeInterval(60)
        _ = tracker.resets(in: weekly(88, resetsAt: firstReset), now: now)
        let rolled = weekly(0, resetsAt: firstReset.addingTimeInterval(RateLimits.week))

        #expect(tracker.resets(in: rolled, now: now.addingTimeInterval(120)).count == 1)
        #expect(tracker.resets(in: rolled, now: now.addingTimeInterval(180)).isEmpty)
    }

    @Test func staysQuietAboutARolloverDiscoveredLongAfterTheFact() {
        let tracker = WeeklyResetTracker(defaults: defaults())
        let firstReset = now.addingTimeInterval(60)
        _ = tracker.resets(in: weekly(88, resetsAt: firstReset), now: now)

        // Relaunched a day later: the reset is old news, not an announcement.
        let events = tracker.resets(
            in: weekly(0, resetsAt: firstReset.addingTimeInterval(RateLimits.week)),
            now: firstReset.addingTimeInterval(WeeklyResetTracker.freshness + 60)
        )
        #expect(events.isEmpty)
    }

    /// If Anthropic moves a weekly boundary, a later `resets_at` can show up
    /// while the one we were tracking is still ahead of us. Nothing has ended,
    /// so nothing should be announced.
    @Test func staysQuietWhenTheBoundaryMovesBeforeTheWindowHasEnded() {
        let tracker = WeeklyResetTracker(defaults: defaults())
        let firstReset = now.addingTimeInterval(3600)
        _ = tracker.resets(in: weekly(88, resetsAt: firstReset), now: now)

        let events = tracker.resets(
            in: weekly(88, resetsAt: firstReset.addingTimeInterval(RateLimits.week)),
            now: now.addingTimeInterval(60)
        )
        #expect(events.isEmpty)
    }

    @Test func ignoresSessionWindows() {
        let tracker = WeeklyResetTracker(defaults: defaults())
        func session(_ percent: Double, resetsAt: Date) -> RateLimits {
            RateLimits(
                fiveHour: .init(usedPercentage: percent, resetsAt: resetsAt),
                sevenDay: nil,
                sevenDayOpus: nil,
                sevenDaySonnet: nil
            )
        }
        let firstReset = now.addingTimeInterval(60)
        _ = tracker.resets(in: session(96, resetsAt: firstReset), now: now)
        let events = tracker.resets(
            in: session(0, resetsAt: firstReset.addingTimeInterval(5 * 3600)),
            now: now.addingTimeInterval(120)
        )
        #expect(events.isEmpty)
    }

    @Test func tracksSonnetAndOpusWindowsIndependently() {
        let tracker = WeeklyResetTracker(defaults: defaults())
        let firstReset = now.addingTimeInterval(60)
        let before = RateLimits(
            fiveHour: nil,
            sevenDay: .init(usedPercentage: 90, resetsAt: firstReset),
            sevenDayOpus: nil,
            sevenDaySonnet: .init(usedPercentage: 30, resetsAt: firstReset)
        )
        _ = tracker.resets(in: before, now: now)

        let rolled = RateLimits(
            fiveHour: nil,
            sevenDay: .init(usedPercentage: 0, resetsAt: firstReset.addingTimeInterval(RateLimits.week)),
            sevenDayOpus: nil,
            sevenDaySonnet: .init(usedPercentage: 0, resetsAt: firstReset.addingTimeInterval(RateLimits.week))
        )
        let events = tracker.resets(in: rolled, now: now.addingTimeInterval(120))
        #expect(events.map(\.kind) == [.sevenDay])
    }
}
