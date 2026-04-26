import Testing
import Foundation
@testable import ClaudeBar

struct StatsCacheTests {
    @Test func decodesAndSumsTokens() throws {
        let json = """
        {
          "version": 3,
          "lastComputedDate": "2026-04-25",
          "dailyActivity": [
            {"date":"2026-04-25","messageCount":10,"sessionCount":1,"toolCallCount":2}
          ],
          "dailyModelTokens": [
            {"date":"2026-04-25","tokensByModel":{"claude-opus-4-7": 1000, "claude-haiku-4-5": 500}}
          ],
          "modelUsage": {
            "claude-opus-4-7": {
              "inputTokens": 100, "outputTokens": 900,
              "cacheReadInputTokens": 0, "cacheCreationInputTokens": 0,
              "webSearchRequests": 0
            }
          },
          "totalSessions": 5,
          "totalMessages": 50,
          "longestSession": {"sessionId":"abc","duration":3600000,"messageCount":7,"timestamp":"2026-04-25T12:00:00Z"},
          "firstSessionDate": "2026-04-01T00:00:00Z",
          "hourCounts": {"12": 4}
        }
        """
        let data = json.data(using: .utf8)!
        let cache = try JSONDecoder().decode(StatsCache.self, from: data)
        #expect(cache.totalSessions == 5)
        #expect(cache.dailyActivity.first?.messageCount == 10)
        let merged = MergedStats(cache: cache, live: LiveStats())
        #expect(merged.totalTokens == 1000) // 100 + 900
        #expect(merged.tokens(forDay: "2026-04-25") == 1500)
    }

    @Test func mergedStatsAddsLiveOverlay() {
        let cache: StatsCache? = nil
        var live = LiveStats()
        live.tokensByDate["2026-04-27"] = 5000
        live.modelInputOutput["claude-opus-4-7"] = TokenPair(input: 1000, output: 4000)
        live.sessionDates.insert("2026-04-27")
        live.sessionCount = 2
        let merged = MergedStats(cache: cache, live: live)
        #expect(merged.totalTokens == 5000)
        #expect(merged.todayTokens == merged.tokens(forDay: StatsCache.todayString()))
        #expect(merged.allActiveDates.contains("2026-04-27"))
        #expect(merged.totalSessions == 2)
    }
}
