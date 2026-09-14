import Testing
import Foundation
@testable import ClaudeBar

struct LiveStatsScannerTests {
    private func makeProjectsDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeBarTests-\(UUID().uuidString)/projects", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func assistantLine(
        model: String,
        input: Int,
        output: Int,
        cacheRead: Int = 0,
        cacheCreation: Int = 0,
        timestamp: String,
        isSidechain: Bool = false,
        toolCalls: Int = 0,
        padding: Int = 0
    ) -> String {
        let filler = String(repeating: "x", count: padding)
        let content = (0..<toolCalls)
            .map { #"{"type":"tool_use","id":"t\#($0)"}"# }
            .joined(separator: ",")
        return """
        {"isSidechain":\(isSidechain),"message":{"model":"\(model)","content":[\(content)],\
        "usage":{"input_tokens":\(input),"output_tokens":\(output),\
        "cache_read_input_tokens":\(cacheRead),"cache_creation_input_tokens":\(cacheCreation)},\
        "filler":"\(filler)"},"type":"assistant","timestamp":"\(timestamp)"}
        """
    }

    private func userLine(timestamp: String, text: String = "hello") -> String {
        #"{"isSidechain":false,"message":{"role":"user","content":"\#(text)"},"type":"user","timestamp":"\#(timestamp)"}"#
    }

    private func write(_ lines: [String], to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func append(_ lines: [String], to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8))
    }

    /// The day a local timestamp falls on, the way the scanner buckets it.
    private func localDay(_ timestamp: String) -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = iso.date(from: timestamp) ?? {
            iso.formatOptions = [.withInternetDateTime]
            return iso.date(from: timestamp)!
        }()
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    @Test func sumsUsagePerDayAndModel() async throws {
        let dir = try makeProjectsDir()
        try write(
            [
                userLine(timestamp: "2026-08-10T12:00:00.000Z"),
                assistantLine(
                    model: "claude-opus-5",
                    input: 100, output: 900, cacheRead: 5_000, cacheCreation: 50,
                    timestamp: "2026-08-10T12:00:01.000Z", toolCalls: 2
                ),
                assistantLine(model: "claude-haiku-4-5", input: 10, output: 40, timestamp: "2026-08-10T13:00:00Z"),
                #"{"type":"mode","mode":"auto"}"#
            ],
            to: dir.appendingPathComponent("project/a.jsonl")
        )

        let stats = await LiveStatsScanner(projectsDir: dir).scan(after: nil)
        let day = localDay("2026-08-10T12:00:01.000Z")

        // The untimestamped bookkeeping line is not a message, the same way
        // Claude Code's own stats skip it.
        #expect(stats.messageCount == 3)
        #expect(stats.sessionCount == 1)
        #expect(stats.modelUsage["claude-opus-5"] == TokenUsage(input: 100, output: 900, cacheRead: 5_000, cacheCreation: 50))
        #expect(stats.modelUsage["claude-haiku-4-5"] == TokenUsage(input: 10, output: 40))
        #expect(stats.days[day]?.messages == 3)
        #expect(stats.days[day]?.sessions == 1)
        #expect(stats.days[day]?.toolCalls == 2)
        // Tokens are the billable columns only; cache reads are kept apart.
        #expect(stats.days[day]?.tokens == 1050)
    }

    /// The day counts are what the heatmap draws, so they have to land on the
    /// day the work happened rather than on whichever day the file was last
    /// touched.
    @Test func bucketsEachEntryOnItsOwnDay() async throws {
        let dir = try makeProjectsDir()
        try write(
            [
                assistantLine(model: "opus", input: 1, output: 1, timestamp: "2026-08-10T12:00:00Z"),
                assistantLine(model: "opus", input: 2, output: 2, timestamp: "2026-08-11T12:00:00Z"),
                assistantLine(model: "opus", input: 3, output: 3, timestamp: "2026-08-11T18:00:00Z")
            ],
            to: dir.appendingPathComponent("project/a.jsonl")
        )

        let stats = await LiveStatsScanner(projectsDir: dir).scan(after: nil)
        #expect(stats.days[localDay("2026-08-10T12:00:00Z")]?.messages == 1)
        #expect(stats.days[localDay("2026-08-11T12:00:00Z")]?.messages == 2)
        // One session, on the day its first entry was written.
        #expect(stats.sessionCount == 1)
        #expect(stats.days[localDay("2026-08-10T12:00:00Z")]?.sessions == 1)
        #expect(stats.days[localDay("2026-08-11T12:00:00Z")]?.sessions == 0)
    }

    /// The stats cache covers whole days, and a session log can straddle the
    /// boundary — a log resumed after the cache was computed still holds the
    /// entries that went into it.
    @Test func countsOnlyWhatTheCacheDoesNotCover() async throws {
        let dir = try makeProjectsDir()
        try write(
            [
                assistantLine(model: "opus", input: 1_000, output: 1_000, timestamp: "2026-08-09T12:00:00Z"),
                assistantLine(model: "opus", input: 5, output: 7, timestamp: "2026-08-11T12:00:00Z")
            ],
            to: dir.appendingPathComponent("project/a.jsonl")
        )

        let stats = await LiveStatsScanner(projectsDir: dir).scan(after: "2026-08-10")
        #expect(stats.modelUsage["opus"] == TokenUsage(input: 5, output: 7))
        #expect(stats.messageCount == 1)
        // The session started before the cutoff, so the cache already counted
        // it; counting it again would inflate the session total every scan.
        #expect(stats.sessionCount == 0)
    }

    /// Moving the cutoff invalidates the per-file tallies, which were filtered
    /// by the old one.
    @Test func reappliesAChangedCutoff() async throws {
        let dir = try makeProjectsDir()
        try write(
            [
                assistantLine(model: "opus", input: 1, output: 1, timestamp: "2026-08-09T12:00:00Z"),
                assistantLine(model: "opus", input: 2, output: 2, timestamp: "2026-08-11T12:00:00Z")
            ],
            to: dir.appendingPathComponent("project/a.jsonl")
        )

        let scanner = LiveStatsScanner(projectsDir: dir)
        #expect(await scanner.scan(after: nil).modelUsage["opus"] == TokenUsage(input: 3, output: 3))
        #expect(await scanner.scan(after: "2026-08-10").modelUsage["opus"] == TokenUsage(input: 2, output: 2))
        #expect(await scanner.scan(after: nil).modelUsage["opus"] == TokenUsage(input: 3, output: 3))
    }

    /// A subagent's tokens are the user's, but its transcript is not a session
    /// the user started and its turns are not messages in one — a fan-out of
    /// ten agents is not ten sessions.
    @Test func countsSubagentTokensButNotSubagentSessions() async throws {
        let dir = try makeProjectsDir()
        try write(
            [assistantLine(model: "opus", input: 1, output: 1, timestamp: "2026-08-10T12:00:00Z")],
            to: dir.appendingPathComponent("project/a.jsonl")
        )
        try write(
            [assistantLine(model: "opus", input: 20, output: 30, timestamp: "2026-08-10T12:05:00Z")],
            to: dir.appendingPathComponent("project/a/subagents/agent-1.jsonl")
        )

        let stats = await LiveStatsScanner(projectsDir: dir).scan(after: nil)
        #expect(stats.modelUsage["opus"] == TokenUsage(input: 21, output: 31))
        #expect(stats.sessionCount == 1)
        #expect(stats.messageCount == 1)
    }

    /// A sidechain entry is a subagent turn copied into the parent transcript;
    /// counting it as well as the subagent's own log counts the work twice.
    @Test func skipsSidechainEntries() async throws {
        let dir = try makeProjectsDir()
        try write(
            [
                assistantLine(model: "opus", input: 1, output: 1, timestamp: "2026-08-10T12:00:00Z"),
                assistantLine(
                    model: "opus", input: 500, output: 500,
                    timestamp: "2026-08-10T12:01:00Z", isSidechain: true
                )
            ],
            to: dir.appendingPathComponent("project/a.jsonl")
        )

        let stats = await LiveStatsScanner(projectsDir: dir).scan(after: nil)
        #expect(stats.modelUsage["opus"] == TokenUsage(input: 1, output: 1))
        #expect(stats.messageCount == 1)
    }

    /// Records carry quoted JSON in their bodies — a tool result, a pasted
    /// file — so the timestamp that dates a record is the record's own, not the
    /// first one that appears in its bytes.
    @Test func readsTheRecordsOwnTimestamp() async throws {
        let dir = try makeProjectsDir()
        let quoted = #"{\"timestamp\":\"2019-01-01T00:00:00.000Z\"}"#
        try write(
            [
                #"{"isSidechain":false,"message":{"role":"user","content":"\#(quoted)"},"type":"user","timestamp":"2026-08-10T12:00:00.000Z"}"#
            ],
            to: dir.appendingPathComponent("project/a.jsonl")
        )

        let stats = await LiveStatsScanner(projectsDir: dir).scan(after: nil)
        #expect(stats.days[localDay("2026-08-10T12:00:00.000Z")]?.messages == 1)
        #expect(stats.days["2019-01-01"] == nil)
    }

    /// The cutoff is a UTC day, so an entry is dated by the instant it records
    /// and not by the digits its timestamp happens to start with: these two
    /// share a wall-clock hour but fall on different UTC days.
    @Test func datesEntriesByTheInstantNotTheSpelling() async throws {
        let dir = try makeProjectsDir()
        try write(
            [
                // 2026-08-10 in UTC: the cache already covers it.
                assistantLine(model: "opus", input: 1, output: 1, timestamp: "2026-08-10T23:00:00Z"),
                // The same wall clock ten hours west — 2026-08-11 in UTC.
                assistantLine(model: "opus", input: 20, output: 30, timestamp: "2026-08-10T23:00:00-10:00")
            ],
            to: dir.appendingPathComponent("project/a.jsonl")
        )

        let stats = await LiveStatsScanner(projectsDir: dir).scan(after: "2026-08-10")
        #expect(stats.modelUsage["opus"] == TokenUsage(input: 20, output: 30))
        #expect(stats.messageCount == 1)
        #expect(stats.days[localDay("2026-08-10T23:00:00-10:00")]?.messages == 1)
    }

    /// The scan resumes an append-only log from where it stopped, so a rescan
    /// must add the new lines without recounting the old ones.
    @Test func appendedLinesAreCountedExactlyOnce() async throws {
        let dir = try makeProjectsDir()
        let file = dir.appendingPathComponent("project/a.jsonl")
        try write(
            [assistantLine(model: "opus", input: 1, output: 2, timestamp: "2026-08-10T12:00:00Z")],
            to: file
        )

        let scanner = LiveStatsScanner(projectsDir: dir)
        let first = await scanner.scan(after: nil)
        #expect(first.modelUsage["opus"] == TokenUsage(input: 1, output: 2))

        try append(
            [assistantLine(model: "opus", input: 10, output: 20, timestamp: "2026-08-10T12:00:01Z")],
            to: file
        )
        let second = await scanner.scan(after: nil)
        #expect(second.modelUsage["opus"] == TokenUsage(input: 11, output: 22))
        #expect(second.messageCount == 2)
        #expect(second.sessionCount == 1)
    }

    /// An unchanged file must read back the same totals from its cached tally.
    @Test func rescanWithoutChangesIsStable() async throws {
        let dir = try makeProjectsDir()
        try write(
            [assistantLine(model: "opus", input: 5, output: 7, timestamp: "2026-08-10T12:00:00Z")],
            to: dir.appendingPathComponent("project/a.jsonl")
        )

        let scanner = LiveStatsScanner(projectsDir: dir)
        let first = await scanner.scan(after: nil)
        let second = await scanner.scan(after: nil)
        #expect(first == second)
    }

    /// A line longer than the read buffer has to be reassembled across chunks.
    @Test func countsLinesLongerThanTheReadBuffer() async throws {
        let dir = try makeProjectsDir()
        try write(
            [
                assistantLine(
                    model: "opus",
                    input: 3,
                    output: 4,
                    timestamp: "2026-08-10T12:00:00Z",
                    padding: 900_000
                ),
                assistantLine(model: "opus", input: 1, output: 1, timestamp: "2026-08-10T12:00:01Z")
            ],
            to: dir.appendingPathComponent("project/a.jsonl")
        )

        let stats = await LiveStatsScanner(projectsDir: dir).scan(after: nil)
        #expect(stats.messageCount == 2)
        #expect(stats.modelUsage["opus"] == TokenUsage(input: 4, output: 5))
    }

    /// A file rewritten shorter is not an append, so it is re-read whole rather
    /// than resumed from an offset past its new end.
    @Test func truncatedFileIsRereadFromTheStart() async throws {
        let dir = try makeProjectsDir()
        let file = dir.appendingPathComponent("project/a.jsonl")
        try write(
            (0..<20).map {
                assistantLine(model: "opus", input: 1, output: 1, timestamp: "2026-08-10T12:00:\(String(format: "%02d", $0))Z")
            },
            to: file
        )

        let scanner = LiveStatsScanner(projectsDir: dir)
        let first = await scanner.scan(after: nil)
        #expect(first.messageCount == 20)

        try write(
            [assistantLine(model: "opus", input: 1, output: 1, timestamp: "2026-08-10T12:00:00Z")],
            to: file
        )
        let second = await scanner.scan(after: nil)
        #expect(second.messageCount == 1)
        #expect(second.modelUsage["opus"] == TokenUsage(input: 1, output: 1))
    }

    /// Files the JSON stats cache already covers are skipped without being read.
    @Test func skipsFilesUntouchedSinceTheCutoff() async throws {
        let dir = try makeProjectsDir()
        let file = dir.appendingPathComponent("project/a.jsonl")
        try write(
            [assistantLine(model: "opus", input: 1, output: 2, timestamp: "2026-08-10T12:00:00Z")],
            to: file
        )
        try FileManager.default.setAttributes(
            [.modificationDate: ISO8601DateFormatter().date(from: "2026-08-10T12:00:05Z")!],
            ofItemAtPath: file.path
        )

        let scanner = LiveStatsScanner(projectsDir: dir)
        #expect(await scanner.scan(after: "2026-08-10") == LiveStats())
        #expect(await scanner.scan(after: "2026-08-09").messageCount == 1)
    }

    /// A record still being written has no terminating newline yet; it must be
    /// counted when it completes and not before, and never twice.
    @Test func partialTrailingLineIsCountedOnceItCompletes() async throws {
        let dir = try makeProjectsDir()
        let file = dir.appendingPathComponent("project/a.jsonl")
        let line = assistantLine(model: "opus", input: 6, output: 9, timestamp: "2026-08-10T12:00:00Z")
        let split = line.index(line.startIndex, offsetBy: 40)
        try write([], to: file)
        try String(line[..<split]).write(to: file, atomically: true, encoding: .utf8)

        let scanner = LiveStatsScanner(projectsDir: dir)
        let partial = await scanner.scan(after: nil)
        #expect(partial.messageCount == 0)

        try append([String(line[split...])], to: file)
        let complete = await scanner.scan(after: nil)
        #expect(complete.messageCount == 1)
        #expect(complete.modelUsage["opus"] == TokenUsage(input: 6, output: 9))
    }
}

struct TranscriptHeadTests {
    private func head(_ line: String) -> TranscriptHead {
        TranscriptHead(line: Data(line.utf8))
    }

    @Test func readsTopLevelScalars() {
        let h = head(#"{"isSidechain":true,"message":{"model":"opus"},"type":"assistant","timestamp":"2026-08-10T12:00:00Z"}"#)
        #expect(h.type == "assistant")
        #expect(h.timestamp == "2026-08-10T12:00:00Z")
        #expect(h.isSidechain)
    }

    /// Keys inside the message body belong to the body, whatever they are
    /// called.
    @Test func ignoresKeysNestedInTheBody() {
        let h = head(#"{"message":{"type":"tool_result","timestamp":"2019-01-01T00:00:00Z","isSidechain":true},"type":"user","timestamp":"2026-08-10T12:00:00Z"}"#)
        #expect(h.type == "user")
        #expect(h.timestamp == "2026-08-10T12:00:00Z")
        #expect(!h.isSidechain)
    }

    /// Including when the body quotes them as text, escapes and all.
    @Test func ignoresKeysQuotedInsideStrings() {
        let h = head(#"{"message":{"content":"{\"timestamp\":\"2019-01-01T00:00:00Z\"} and a brace } here"},"type":"user","timestamp":"2026-08-10T12:00:00Z"}"#)
        #expect(h.timestamp == "2026-08-10T12:00:00Z")
        #expect(h.type == "user")
    }

    @Test func toleratesRecordsItCannotRead() {
        #expect(head("not json").timestamp == nil)
        #expect(head("").timestamp == nil)
        #expect(head("{}").timestamp == nil)
        #expect(head(#"{"type":"user"}"#).timestamp == nil)
    }
}
