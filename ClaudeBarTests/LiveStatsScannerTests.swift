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
        timestamp: String,
        padding: Int = 0
    ) -> String {
        let filler = String(repeating: "x", count: padding)
        return """
        {"type":"assistant","timestamp":"\(timestamp)","message":{"model":"\(model)",\
        "usage":{"input_tokens":\(input),"output_tokens":\(output)},"filler":"\(filler)"}}
        """
    }

    private func write(_ lines: [String], to url: URL) throws {
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func append(_ lines: [String], to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8))
    }

    @Test func sumsAssistantUsagePerDayAndModel() async throws {
        let dir = try makeProjectsDir()
        try write(
            [
                assistantLine(model: "claude-opus-4-7", input: 100, output: 900, timestamp: "2026-08-10T12:00:00.000Z"),
                assistantLine(model: "claude-haiku-4-5", input: 10, output: 40, timestamp: "2026-08-10T13:00:00Z"),
                #"{"type":"user","message":{"content":"no usage here"}}"#
            ],
            to: dir.appendingPathComponent("a.jsonl")
        )

        let stats = await LiveStatsScanner(projectsDir: dir).scan(modifiedAfter: nil)

        #expect(stats.messageCount == 2)
        #expect(stats.sessionCount == 1)
        #expect(stats.modelInputOutput["claude-opus-4-7"] == TokenPair(input: 100, output: 900))
        #expect(stats.modelInputOutput["claude-haiku-4-5"] == TokenPair(input: 10, output: 40))
        #expect(stats.tokensByDate.values.reduce(0, +) == 1050)
    }

    /// The scan resumes an append-only log from where it stopped, so a rescan
    /// must add the new lines without recounting the old ones.
    @Test func appendedLinesAreCountedExactlyOnce() async throws {
        let dir = try makeProjectsDir()
        let file = dir.appendingPathComponent("a.jsonl")
        try write(
            [assistantLine(model: "opus", input: 1, output: 2, timestamp: "2026-08-10T12:00:00Z")],
            to: file
        )

        let scanner = LiveStatsScanner(projectsDir: dir)
        let first = await scanner.scan(modifiedAfter: nil)
        #expect(first.modelInputOutput["opus"] == TokenPair(input: 1, output: 2))

        try append(
            [assistantLine(model: "opus", input: 10, output: 20, timestamp: "2026-08-10T12:00:01Z")],
            to: file
        )
        let second = await scanner.scan(modifiedAfter: nil)
        #expect(second.modelInputOutput["opus"] == TokenPair(input: 11, output: 22))
        #expect(second.messageCount == 2)
    }

    /// An unchanged file must read back the same totals from its cached tally.
    @Test func rescanWithoutChangesIsStable() async throws {
        let dir = try makeProjectsDir()
        try write(
            [assistantLine(model: "opus", input: 5, output: 7, timestamp: "2026-08-10T12:00:00Z")],
            to: dir.appendingPathComponent("a.jsonl")
        )

        let scanner = LiveStatsScanner(projectsDir: dir)
        let first = await scanner.scan(modifiedAfter: nil)
        let second = await scanner.scan(modifiedAfter: nil)
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
            to: dir.appendingPathComponent("a.jsonl")
        )

        let stats = await LiveStatsScanner(projectsDir: dir).scan(modifiedAfter: nil)
        #expect(stats.messageCount == 2)
        #expect(stats.modelInputOutput["opus"] == TokenPair(input: 4, output: 5))
    }

    /// A file rewritten shorter is not an append, so it is re-read whole rather
    /// than resumed from an offset past its new end.
    @Test func truncatedFileIsRereadFromTheStart() async throws {
        let dir = try makeProjectsDir()
        let file = dir.appendingPathComponent("a.jsonl")
        try write(
            (0..<20).map {
                assistantLine(model: "opus", input: 1, output: 1, timestamp: "2026-08-10T12:00:\(String(format: "%02d", $0))Z")
            },
            to: file
        )

        let scanner = LiveStatsScanner(projectsDir: dir)
        let first = await scanner.scan(modifiedAfter: nil)
        #expect(first.messageCount == 20)

        try write(
            [assistantLine(model: "opus", input: 1, output: 1, timestamp: "2026-08-10T12:00:00Z")],
            to: file
        )
        let second = await scanner.scan(modifiedAfter: nil)
        #expect(second.messageCount == 1)
        #expect(second.modelInputOutput["opus"] == TokenPair(input: 1, output: 1))
    }

    /// Files the JSON stats cache already covers are skipped entirely.
    @Test func skipsFilesAtOrBeforeTheCutoff() async throws {
        let dir = try makeProjectsDir()
        let file = dir.appendingPathComponent("a.jsonl")
        try write(
            [assistantLine(model: "opus", input: 1, output: 2, timestamp: "2026-08-10T12:00:00Z")],
            to: file
        )

        let scanner = LiveStatsScanner(projectsDir: dir)
        let future = Date().addingTimeInterval(60)
        let skipped = await scanner.scan(modifiedAfter: future)
        #expect(skipped == LiveStats())

        let past = Date().addingTimeInterval(-60)
        let counted = await scanner.scan(modifiedAfter: past)
        #expect(counted.messageCount == 1)
    }

    /// A record still being written has no terminating newline yet; it must be
    /// counted when it completes and not before, and never twice.
    @Test func partialTrailingLineIsCountedOnceItCompletes() async throws {
        let dir = try makeProjectsDir()
        let file = dir.appendingPathComponent("a.jsonl")
        let line = assistantLine(model: "opus", input: 6, output: 9, timestamp: "2026-08-10T12:00:00Z")
        let split = line.index(line.startIndex, offsetBy: 40)
        try String(line[..<split]).write(to: file, atomically: true, encoding: .utf8)

        let scanner = LiveStatsScanner(projectsDir: dir)
        let partial = await scanner.scan(modifiedAfter: nil)
        #expect(partial.messageCount == 0)

        try append([String(line[split...])], to: file)
        let complete = await scanner.scan(modifiedAfter: nil)
        #expect(complete.messageCount == 1)
        #expect(complete.modelInputOutput["opus"] == TokenPair(input: 6, output: 9))
    }
}
