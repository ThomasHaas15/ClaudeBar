import Testing
import Foundation
@testable import ClaudeBar

struct StatsCacheTests {
    private func cacheJSON(
        version: Int = 5,
        lastComputedDate: String = "2026-04-25"
    ) -> String {
        """
        {
          "version": \(version),
          "lastComputedDate": "\(lastComputedDate)",
          "dailyActivity": [
            {"date":"2026-04-25","messageCount":10,"sessionCount":1,"toolCallCount":2}
          ],
          "dailyModelTokens": [
            {"date":"2026-04-25","tokensByModel":{"claude-opus-5": 1000, "claude-haiku-4-5": 500}}
          ],
          "modelUsage": {
            "claude-opus-5": {
              "inputTokens": 100, "outputTokens": 900,
              "cacheReadInputTokens": 40000, "cacheCreationInputTokens": 2000,
              "webSearchRequests": 0, "costUSD": 0, "contextWindow": 0, "maxOutputTokens": 0
            }
          },
          "totalSessions": 5,
          "totalMessages": 50,
          "longestSession": {"sessionId":"abc","duration":3600000,"messageCount":7,"timestamp":"2026-04-25T12:00:00Z"},
          "firstSessionDate": "2026-04-01T00:00:00Z",
          "hourCounts": {"12": 4},
          "dailyModelTokensVersion": 5,
          "shotDistribution": {"1": 3},
          "totalSpeculationTimeSavedMs": 0
        }
        """
    }

    /// The cache is Claude Code's, and it has gained fields (and a version) as
    /// the `/usage` dialog grew. Reading it must not depend on the ones this
    /// app does not use.
    @Test func decodesTheCurrentCacheFormat() throws {
        let cache = try JSONDecoder().decode(StatsCache.self, from: Data(cacheJSON().utf8))
        #expect(cache.version == 5)
        #expect(cache.totalSessions == 5)
        #expect(cache.dailyActivity.first?.messageCount == 10)
        #expect(cache.coveredThrough == "2026-04-25")

        let merged = MergedStats(cache: cache, live: LiveStats())
        #expect(merged.totalTokens == 1000) // input + output, cache columns excluded
        #expect(merged.modelTotals["claude-opus-5"]?.cacheRead == 40000)
        #expect(merged.tokens(forDay: "2026-04-25") == 1500)
    }

    /// The scanner compares the watermark as a string, so anything that is not
    /// a plain date has to read as "no cover at all" rather than as a bound.
    @Test func rejectsAnUnusableWatermark() throws {
        for value in ["\"\"", "null", "\"2026-04\"", "\"not-a-date\""] {
            let json = cacheJSON().replacingOccurrences(
                of: "\"lastComputedDate\": \"2026-04-25\"",
                with: "\"lastComputedDate\": \(value)"
            )
            let cache = try JSONDecoder().decode(StatsCache.self, from: Data(json.utf8))
            #expect(cache.coveredThrough == nil)
        }
    }

    @Test func mergedStatsAddsLiveOverlay() {
        var live = LiveStats()
        live.days["2026-04-27"] = DayActivity(messages: 8, sessions: 2, toolCalls: 3, tokens: 5000)
        live.modelUsage["claude-opus-5"] = TokenUsage(input: 1000, output: 4000, cacheRead: 9)

        let merged = MergedStats(cache: nil, live: live)
        #expect(merged.totalTokens == 5000)
        #expect(merged.totalSessions == 2)
        #expect(merged.totalMessages == 8)
        #expect(merged.todayTokens == merged.tokens(forDay: StatsCache.todayString()))
        #expect(merged.allActiveDates.contains("2026-04-27"))
    }

    /// What the heatmap draws. The cache stops at the day Claude Code last
    /// recomputed it — which is only when someone opened `/usage` — so every
    /// day after that has to come from the live scan or the grid freezes.
    @Test func dailyActivityCoversBothSides() throws {
        let cache = try JSONDecoder().decode(StatsCache.self, from: Data(cacheJSON().utf8))
        var live = LiveStats()
        live.days["2026-04-26"] = DayActivity(messages: 40, sessions: 3, toolCalls: 9, tokens: 1)
        live.days["2026-04-27"] = DayActivity(messages: 12, sessions: 1, toolCalls: 2, tokens: 1)

        let activity = MergedStats(cache: cache, live: live).dailyActivity
        #expect(activity.map(\.date) == ["2026-04-25", "2026-04-26", "2026-04-27"])
        #expect(activity[0].messageCount == 10)
        #expect(activity[1].messageCount == 40)
        #expect(activity[1].sessionCount == 3)
        #expect(activity[2].toolCallCount == 2)
    }

    /// A day either side of the watermark is never counted twice — but if the
    /// scanner ever did hand back a day the cache also holds, the two are
    /// summed rather than one silently winning.
    @Test func dailyActivityAddsOverlappingDays() throws {
        let cache = try JSONDecoder().decode(StatsCache.self, from: Data(cacheJSON().utf8))
        var live = LiveStats()
        live.days["2026-04-25"] = DayActivity(messages: 5, sessions: 1, toolCalls: 1, tokens: 0)

        let activity = MergedStats(cache: cache, live: live).dailyActivity
        #expect(activity.count == 1)
        #expect(activity[0].messageCount == 15)
        #expect(activity[0].sessionCount == 2)
    }

    @Test func hasDataFollowsEitherSource() throws {
        let cache = try JSONDecoder().decode(StatsCache.self, from: Data(cacheJSON().utf8))
        var live = LiveStats()
        live.days["2026-04-27"] = DayActivity(messages: 1)

        #expect(!MergedStats(cache: nil, live: LiveStats()).hasData)
        #expect(MergedStats(cache: cache, live: LiveStats()).hasData)
        #expect(MergedStats(cache: nil, live: live).hasData)
    }

    /// "Tokens today" counts the day the store hands over, not the day the
    /// numbers were written on — so once `StatsStore` moves `today` on at
    /// midnight the header drops to zero without needing a file to change.
    @Test func todayTokensFollowTheDayTheyAreGiven() {
        var live = LiveStats()
        live.days["2026-04-27"] = DayActivity(tokens: 241_000)
        let cal = Calendar(identifier: .gregorian)
        let f = DateFormatter()
        f.calendar = cal
        f.dateFormat = "yyyy-MM-dd"
        let day = f.date(from: "2026-04-27")!
        let nextDay = cal.date(byAdding: .day, value: 1, to: day)!

        #expect(MergedStats(cache: nil, live: live, today: day).todayTokens == 241_000)
        // Midnight, no further activity: yesterday's total is not today's.
        #expect(MergedStats(cache: nil, live: live, today: nextDay).todayTokens == 0)
        // …and the day it was earned on still reads back the same.
        #expect(MergedStats(cache: nil, live: live, today: nextDay).tokens(forDay: "2026-04-27") == 241_000)
    }
}
