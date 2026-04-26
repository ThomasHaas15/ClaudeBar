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
}
