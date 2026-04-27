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

    @Test func droppingExpiredRemovesPastResets() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let limits = RateLimits(
            fiveHour: .init(usedPercentage: 83, resetsAt: now.addingTimeInterval(-3600)),
            sevenDay: .init(usedPercentage: 42, resetsAt: now.addingTimeInterval(86_400)),
            sevenDayOpus: nil,
            sevenDaySonnet: nil
        )
        let filtered = limits.droppingExpired(now: now)
        #expect(filtered.fiveHour == nil)
        #expect(filtered.sevenDay?.percent == 42)
    }

    @Test func droppingExpiredKeepsFutureResets() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let limits = RateLimits(
            fiveHour: .init(usedPercentage: 10, resetsAt: now.addingTimeInterval(60)),
            sevenDay: nil,
            sevenDayOpus: nil,
            sevenDaySonnet: nil
        )
        #expect(limits.droppingExpired(now: now).fiveHour?.percent == 10)
    }

    @Test func droppingExpiredEmptiesAllPastLimits() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let past = now.addingTimeInterval(-1)
        let limits = RateLimits(
            fiveHour: .init(usedPercentage: 50, resetsAt: past),
            sevenDay: .init(usedPercentage: 60, resetsAt: past),
            sevenDayOpus: .init(usedPercentage: 70, resetsAt: past),
            sevenDaySonnet: .init(usedPercentage: 80, resetsAt: past)
        )
        #expect(limits.droppingExpired(now: now).hasAny == false)
    }
}
