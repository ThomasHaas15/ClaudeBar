import Testing
import Foundation
@testable import ClaudeBar

struct RateLimitsTests {
    @Test func decodesUsedPercentageEpochResetsAt() throws {
        let json = """
        {"five_hour":{"used_percentage":40,"resets_at":1777250400},
         "seven_day":{"used_percentage":39,"resets_at":1777775940}}
        """
        let limits = try JSONDecoder().decode(RateLimits.self, from: json.data(using: .utf8)!)
        #expect(limits.fiveHour?.percent == 40)
        #expect(limits.sevenDay?.percent == 39)
        #expect(limits.fiveHour?.resetsAt.timeIntervalSince1970 == 1777250400)
    }

    @Test func decodesIsoResetsAt() throws {
        let json = """
        {"five_hour":{"used_percentage":80,"resets_at":"2026-04-26T22:00:00.000Z"}}
        """
        let limits = try JSONDecoder().decode(RateLimits.self, from: json.data(using: .utf8)!)
        #expect(limits.fiveHour?.percent == 80)
        #expect(limits.fiveHour?.ratio == 0.8)
    }

    @Test func acceptsLegacyUtilizationField() throws {
        let json = """
        {"five_hour":{"utilization":62,"resets_at":1777250400}}
        """
        let limits = try JSONDecoder().decode(RateLimits.self, from: json.data(using: .utf8)!)
        #expect(limits.fiveHour?.percent == 62)
    }

    @Test func maxRatioPicksHighest() {
        let limits = RateLimits(
            fiveHour: .init(usedPercentage: 30, resetsAt: Date()),
            sevenDay: .init(usedPercentage: 92, resetsAt: Date()),
            sevenDayOpus: nil,
            sevenDaySonnet: .init(usedPercentage: 50, resetsAt: Date())
        )
        #expect(limits.maxRatio == 0.92)
    }

    @Test func mergingFallsBackToCacheForMissingKeys() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let cache = RateLimits(
            fiveHour: .init(usedPercentage: 83, resetsAt: now.addingTimeInterval(-3600)),
            sevenDay: .init(usedPercentage: 42, resetsAt: now.addingTimeInterval(86_400)),
            sevenDayOpus: nil,
            sevenDaySonnet: nil
        )
        let fresh = RateLimits(
            fiveHour: nil,
            sevenDay: .init(usedPercentage: 50, resetsAt: now.addingTimeInterval(86_400)),
            sevenDayOpus: nil,
            sevenDaySonnet: nil
        )
        let merged = fresh.merging(cache: cache)
        #expect(merged.fiveHour?.percent == 83)
        #expect(merged.fiveHour?.resetsAt == now.addingTimeInterval(-3600))
        #expect(merged.sevenDay?.percent == 50)
    }

    @Test func mergingPrefersFreshWhenPresent() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let cache = RateLimits(
            fiveHour: .init(usedPercentage: 90, resetsAt: now.addingTimeInterval(-60)),
            sevenDay: nil,
            sevenDayOpus: nil,
            sevenDaySonnet: nil
        )
        let fresh = RateLimits(
            fiveHour: .init(usedPercentage: 5, resetsAt: now.addingTimeInterval(3600)),
            sevenDay: nil,
            sevenDayOpus: nil,
            sevenDaySonnet: nil
        )
        let merged = fresh.merging(cache: cache)
        #expect(merged.fiveHour?.percent == 5)
        #expect(merged.fiveHour?.resetsAt == now.addingTimeInterval(3600))
    }

    @Test func mergingWithoutCacheReturnsFresh() {
        let fresh = RateLimits(
            fiveHour: .init(usedPercentage: 10, resetsAt: Date()),
            sevenDay: nil,
            sevenDayOpus: nil,
            sevenDaySonnet: nil
        )
        #expect(fresh.merging(cache: nil) == fresh)
    }

    /// The regression PR #5 hit and PR #6 reverted. #5 zeroed inside `load()`,
    /// on the raw file — but Claude Code *deletes* an expired key rather than
    /// leaving it stale, so there was nothing to zero and the row disappeared.
    /// The cache has to fill the key back in *before* the rollover empties it,
    /// which is why the store rolls over after merging rather than at load.
    @Test func aDeletedKeyComesBackAsAnEmptyWindowRatherThanVanishing() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let expired = now.addingTimeInterval(-60)
        let cache = RateLimits(
            fiveHour: .init(usedPercentage: 97, resetsAt: expired),
            sevenDay: .init(usedPercentage: 88, resetsAt: expired),
            sevenDayOpus: nil,
            sevenDaySonnet: nil
        )
        // What Claude Code leaves behind once the windows expire: keys gone.
        let fresh = RateLimits(fiveHour: nil, sevenDay: nil, sevenDayOpus: nil, sevenDaySonnet: nil)

        let shown = fresh.merging(cache: cache).rolledOver(now: now)

        #expect(shown.fiveHour?.percent == 0)
        #expect(shown.sevenDay?.percent == 0)
        #expect(shown.sevenDay?.resetsAt == expired.addingTimeInterval(RateLimits.week))
        #expect(shown.maxRatio == 0)
    }

    /// Order matters: rolling over first and merging second would let the
    /// cached percentage overwrite the emptied window and put 88 % back.
    @Test func rollingOverBeforeMergingWouldResurrectTheOldPercentage() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let expired = now.addingTimeInterval(-60)
        let cache = RateLimits(
            fiveHour: nil,
            sevenDay: .init(usedPercentage: 88, resetsAt: expired),
            sevenDayOpus: nil,
            sevenDaySonnet: nil
        )
        let fresh = RateLimits(fiveHour: nil, sevenDay: nil, sevenDayOpus: nil, sevenDaySonnet: nil)

        #expect(fresh.rolledOver(now: now).merging(cache: cache).sevenDay?.percent == 88)
        #expect(fresh.merging(cache: cache).rolledOver(now: now).sevenDay?.percent == 0)
    }

    @Test func rolledOverLeavesLiveWindowsUntouched() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let limits = RateLimits(
            fiveHour: .init(usedPercentage: 4, resetsAt: now.addingTimeInterval(3600)),
            sevenDay: .init(usedPercentage: 88, resetsAt: now.addingTimeInterval(86_400)),
            sevenDayOpus: nil,
            sevenDaySonnet: nil
        )
        #expect(limits.rolledOver(now: now) == limits)
    }

    @Test func rolledOverEmptiesExpiredSessionButKeepsResetInPast() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let expired = now.addingTimeInterval(-90 * 60)
        let limits = RateLimits(
            fiveHour: .init(usedPercentage: 97, resetsAt: expired),
            sevenDay: nil,
            sevenDayOpus: nil,
            sevenDaySonnet: nil
        )
        let rolled = limits.rolledOver(now: now)
        #expect(rolled.fiveHour?.percent == 0)
        // Left in the past on purpose: a session window only starts on the next
        // request, so the row reads "Resets after next request".
        #expect(rolled.fiveHour?.resetsAt == expired)
    }

    @Test func rolledOverAdvancesExpiredWeeklyByOneWeek() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let expired = now.addingTimeInterval(-3600)
        let limits = RateLimits(
            fiveHour: nil,
            sevenDay: .init(usedPercentage: 88, resetsAt: expired),
            sevenDayOpus: nil,
            sevenDaySonnet: nil
        )
        let rolled = limits.rolledOver(now: now)
        #expect(rolled.sevenDay?.percent == 0)
        #expect(rolled.sevenDay?.resetsAt == expired.addingTimeInterval(RateLimits.week))
    }

    @Test func rolledOverSkipsWholeWeeksThatWerePassedWhileIdle() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let expired = now.addingTimeInterval(-3 * RateLimits.week - 3600)
        let limits = RateLimits(
            fiveHour: nil,
            sevenDay: nil,
            sevenDayOpus: nil,
            sevenDaySonnet: .init(usedPercentage: 61, resetsAt: expired)
        )
        let rolled = limits.rolledOver(now: now)
        #expect(rolled.sevenDaySonnet?.percent == 0)
        #expect(rolled.sevenDaySonnet?.resetsAt == expired.addingTimeInterval(4 * RateLimits.week))
        #expect(rolled.sevenDaySonnet.map { $0.resetsAt > now } == true)
    }

    @Test func rolledOverClearsTheMenuBarDot() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let limits = RateLimits(
            fiveHour: .init(usedPercentage: 100, resetsAt: now.addingTimeInterval(-1)),
            sevenDay: .init(usedPercentage: 88, resetsAt: now.addingTimeInterval(-1)),
            sevenDayOpus: nil,
            sevenDaySonnet: nil
        )
        #expect(limits.maxRatio == 1.0)
        #expect(limits.rolledOver(now: now).maxRatio == 0)
    }

    @Test func nextResetPicksEarliestFutureBoundary() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let limits = RateLimits(
            fiveHour: .init(usedPercentage: 4, resetsAt: now.addingTimeInterval(7200)),
            sevenDay: .init(usedPercentage: 88, resetsAt: now.addingTimeInterval(3600)),
            sevenDayOpus: nil,
            sevenDaySonnet: nil
        )
        #expect(limits.nextReset(after: now) == now.addingTimeInterval(3600))
    }

    @Test func nextResetIgnoresBoundariesAlreadyPassed() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let limits = RateLimits(
            fiveHour: .init(usedPercentage: 4, resetsAt: now.addingTimeInterval(-3600)),
            sevenDay: nil,
            sevenDayOpus: nil,
            sevenDaySonnet: nil
        )
        #expect(limits.nextReset(after: now) == nil)
    }

    @Test func roundTripsThroughEncoder() throws {
        let original = RateLimits(
            fiveHour: .init(usedPercentage: 47.5, resetsAt: Date(timeIntervalSince1970: 1_777_338_000)),
            sevenDay: nil,
            sevenDayOpus: nil,
            sevenDaySonnet: nil
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RateLimits.self, from: data)
        #expect(decoded == original)
    }
}
