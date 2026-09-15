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
        // The cache's own per-day figure is a different number and is not read.
        #expect(merged.tokens(forDay: "2026-04-25") == 0)
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
        live.newMessages = 8
        live.newSessions = 2
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
        live.days["2026-04-26"] = DayActivity(messages: 40, sessions: 3, toolCalls: 9)
        live.days["2026-04-27"] = DayActivity(messages: 12, sessions: 1, toolCalls: 2)


        let activity = MergedStats(cache: cache, live: live).dailyActivity
        #expect(activity.map(\.date) == ["2026-04-25", "2026-04-26", "2026-04-27"])
        #expect(activity[0].messageCount == 10)
        #expect(activity[1].messageCount == 40)
        #expect(activity[1].sessionCount == 3)
        #expect(activity[2].toolCallCount == 2)
    }

    /// The scan and the cache both cover the days either side of the watermark
    /// now, so they are two partial views of one day rather than two halves of
    /// it. Adding them would count the same work twice; the fuller view wins,
    /// field by field.
    @Test func overlappingDaysTakeTheFullerViewNotTheSum() throws {
        let cache = try JSONDecoder().decode(StatsCache.self, from: Data(cacheJSON().utf8))
        var live = LiveStats()
        // The cache holds 10 messages, 1 session, 2 tool calls for this day.
        live.days["2026-04-25"] = DayActivity(messages: 12, sessions: 1, toolCalls: 1)

        let activity = MergedStats(cache: cache, live: live).dailyActivity
        #expect(activity.count == 1)
        #expect(activity[0].messageCount == 12)     // the scan saw more
        #expect(activity[0].sessionCount == 1)
        #expect(activity[0].toolCallCount == 2)     // the cache saw more
    }

    /// A day whose transcripts were half pruned scans lower than the day really
    /// was, and must not drag down what was recorded while they were whole.
    @Test func aShortScanCannotEraseWhatWasRecorded() {
        var live = LiveStats()
        live.days["2026-04-27"] = DayActivity(messages: 2, sessions: 1, toolCalls: 0, tokens: 400)

        let merged = MergedStats(
            cache: nil,
            live: live,
            history: ["2026-04-27": DayActivity(messages: 40, sessions: 3, toolCalls: 9, tokens: 8_000)]
        )
        let day = merged.dailyRecords["2026-04-27"]
        #expect(day == DayActivity(messages: 40, sessions: 3, toolCalls: 9, tokens: 8_000))
        #expect(merged.tokens(forDay: "2026-04-27") == 8_000)
    }

    /// What the heatmap reads on hover, and what a period total is summed from.
    /// A day nothing survives for has to stay *absent* rather than come back as
    /// zero — and the stats cache cannot fill the gap, because its per-day
    /// figure counts cache reads and writes and so is a different number
    /// entirely.
    @Test func dailyTokensLeaveOutDaysNothingRecorded() throws {
        let cache = try JSONDecoder().decode(StatsCache.self, from: Data(cacheJSON().utf8))
        var live = LiveStats()
        live.days["2026-04-27"] = DayActivity(messages: 12, tokens: 7_000)
        live.days["2026-04-28"] = DayActivity(messages: 4, tokens: 0)

        let tokens = MergedStats(cache: cache, live: live).dailyTokens
        #expect(tokens["2026-04-27"] == 7_000)
        // Scanned and genuinely empty — that *is* a figure, and zero is it.
        #expect(tokens["2026-04-28"] == 0)
        // Worked on, but the cache's figure for it is not this measure.
        #expect(cache.dailyActivity.contains { $0.date == "2026-04-25" })
        #expect(cache.dailyModelTokens.contains { $0.date == "2026-04-25" })
        #expect(tokens["2026-04-25"] == nil)
    }

    /// Once transcripts are pruned the scan sees nothing, so what ClaudeBar
    /// recorded earlier is all that is left — and a day half pruned scans low,
    /// so a smaller scan never overwrites a larger record.
    @Test func recordedHistoryFillsInWhatTheScanCanNoLongerSee() {
        var live = LiveStats()
        live.days["2026-04-28"] = DayActivity(messages: 9, tokens: 9_000)   // today, still growing

        let merged = MergedStats(
            cache: nil,
            live: live,
            history: [
                // Pruned months ago; only the record remembers it.
                "2026-03-01": DayActivity(messages: 30, tokens: 12_000),
                "2026-04-28": DayActivity(messages: 4, tokens: 6_000)
            ]
        )
        #expect(merged.tokens(forDay: "2026-03-01") == 12_000)
        #expect(merged.tokens(forDay: "2026-04-28") == 9_000)
        #expect(merged.dailyRecords["2026-03-01"]?.messages == 30)
    }

    /// A day that did work but has no token figure left is what makes a span
    /// unreliable rather than quiet, so the two have to be told apart.
    @Test func daysWithActivityCoverBothSides() throws {
        let cache = try JSONDecoder().decode(StatsCache.self, from: Data(cacheJSON().utf8))
        var live = LiveStats()
        live.days["2026-04-27"] = DayActivity(messages: 12)

        let active = MergedStats(cache: cache, live: live).daysWithActivity
        #expect(active == ["2026-04-25", "2026-04-27"])
        // A recorded-but-empty day is not activity.
        let padded = MergedStats(cache: cache, live: live, history: ["2026-04-20": DayActivity()])
        #expect(!padded.daysWithActivity.contains("2026-04-20"))
    }

    @Test func hasDataFollowsEitherSource() throws {
        let cache = try JSONDecoder().decode(StatsCache.self, from: Data(cacheJSON().utf8))
        var live = LiveStats()
        live.days["2026-04-27"] = DayActivity(messages: 1)

        #expect(!MergedStats(cache: nil, live: LiveStats()).hasData)
        #expect(MergedStats(
            cache: nil, live: LiveStats(), history: ["2026-04-27": DayActivity(messages: 5)]
        ).hasData)
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
