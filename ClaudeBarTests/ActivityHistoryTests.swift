import Testing
import Foundation
@testable import ClaudeBar

@MainActor
struct ActivityHistoryTests {
    private func makeURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeBarTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("daily-activity.json")
    }

    private func stored(at url: URL) -> [String: DayActivity] {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let days = object["days"] as? [String: [String: Int]]
        else { return [:] }
        return days.mapValues {
            DayActivity(
                messages: $0["messages"] ?? 0,
                sessions: $0["sessions"] ?? 0,
                toolCalls: $0["toolCalls"] ?? 0,
                tokens: $0["tokens"] ?? 0
            )
        }
    }

    /// A day still being worked on scans higher every time. A day whose
    /// transcripts are half pruned scans lower than it really was. Only the
    /// first of those is news, and it is news field by field.
    @Test func aDayOnlyEverGrows() {
        let history = ActivityHistory(url: makeURL())
        history.record(["2026-09-14": DayActivity(messages: 10, sessions: 1, toolCalls: 4, tokens: 1_000)])
        history.record(["2026-09-14": DayActivity(messages: 40, sessions: 2, toolCalls: 9, tokens: 4_000)])
        #expect(history.days["2026-09-14"] == DayActivity(messages: 40, sessions: 2, toolCalls: 9, tokens: 4_000))

        history.record(["2026-09-14": DayActivity(messages: 1, sessions: 1, toolCalls: 0, tokens: 12)])
        #expect(history.days["2026-09-14"] == DayActivity(messages: 40, sessions: 2, toolCalls: 9, tokens: 4_000))
    }

    /// Fields move independently: a rescan that finds more messages but no new
    /// tool calls must not pull the tool calls down with it.
    @Test func fieldsGrowOneByOne() {
        let history = ActivityHistory(url: makeURL())
        history.record(["2026-09-14": DayActivity(messages: 5, toolCalls: 9)])
        history.record(["2026-09-14": DayActivity(messages: 8, toolCalls: 2)])
        #expect(history.days["2026-09-14"] == DayActivity(messages: 8, toolCalls: 9))
    }

    /// "Looked, and there was nothing" is a figure — the one thing it must not
    /// read as later is "gone".
    @Test func aDayScannedEmptyIsStillRecorded() {
        let history = ActivityHistory(url: makeURL())
        history.record(["2026-09-14": DayActivity()])
        #expect(history.days["2026-09-14"] == DayActivity())
    }

    @Test func survivesTheAppBeingRestarted() {
        let url = makeURL()
        ActivityHistory(url: url).record([
            "2026-09-13": DayActivity(messages: 9, tokens: 900),
            "2026-09-14": DayActivity(messages: 10, tokens: 1_000)
        ])
        let reopened = ActivityHistory(url: url)
        #expect(reopened.days["2026-09-13"] == DayActivity(messages: 9, tokens: 900))
        #expect(reopened.days["2026-09-14"] == DayActivity(messages: 10, tokens: 1_000))
    }

    /// Today's figures move with every message and the scan runs every second
    /// or two, so the writes are throttled. What the throttle holds back is
    /// carried by the next write, not lost — a day still on disk is re-derived
    /// from scratch on every scan.
    @Test func writesAreThrottledButNeverDropped() {
        let url = makeURL()
        let start = Date()
        let history = ActivityHistory(url: url)

        history.record(["2026-09-14": DayActivity(tokens: 1_000)], now: start)
        #expect(stored(at: url)["2026-09-14"]?.tokens == 1_000)

        history.record(["2026-09-14": DayActivity(tokens: 2_000)], now: start.addingTimeInterval(5))
        #expect(history.days["2026-09-14"]?.tokens == 2_000)
        #expect(stored(at: url)["2026-09-14"]?.tokens == 1_000)

        history.record(["2026-09-14": DayActivity(tokens: 3_000)], now: start.addingTimeInterval(61))
        #expect(stored(at: url)["2026-09-14"]?.tokens == 3_000)
    }

    /// A record written before a field existed still has to read, or one added
    /// field throws away every day ever recorded.
    @Test func aRecordMissingFieldsStillReads() throws {
        let url = makeURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(#"{"version":1,"days":{"2026-09-14":{"tokens":4200}}}"#.utf8).write(to: url)

        #expect(ActivityHistory(url: url).days["2026-09-14"] == DayActivity(tokens: 4_200))
    }

    /// The same way every other file this app reads behaves: unreadable is no
    /// history, not a crash.
    @Test func anUnreadableFileReadsAsNoHistory() throws {
        let url = makeURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not json".utf8).write(to: url)

        #expect(ActivityHistory(url: url).days.isEmpty)
        #expect(ActivityHistory(url: makeURL()).days.isEmpty)
    }
}
