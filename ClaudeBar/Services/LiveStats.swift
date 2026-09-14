import Foundation

struct TokenUsage: Equatable, Sendable {
    var input: Int = 0
    var output: Int = 0
    var cacheRead: Int = 0
    var cacheCreation: Int = 0

    /// What the app calls "tokens". Cache reads and writes are excluded
    /// deliberately: they dwarf the rest by two orders of magnitude — a single
    /// message re-reads the whole conversation — so including them would turn
    /// every figure in the UI into a measure of context size rather than of
    /// work done. The cache columns stay available for the Models tab, which
    /// labels them.
    var billable: Int { input + output }

    static func + (lhs: Self, rhs: Self) -> Self {
        TokenUsage(
            input: lhs.input + rhs.input,
            output: lhs.output + rhs.output,
            cacheRead: lhs.cacheRead + rhs.cacheRead,
            cacheCreation: lhs.cacheCreation + rhs.cacheCreation
        )
    }
}

/// One day's worth of what the on-disk stats cache calls `dailyActivity`,
/// counted the way Claude Code counts it so the two can be added together.
struct DayActivity: Equatable, Sendable {
    var messages: Int = 0
    var sessions: Int = 0
    var toolCalls: Int = 0
    var tokens: Int = 0

    static func + (lhs: Self, rhs: Self) -> Self {
        DayActivity(
            messages: lhs.messages + rhs.messages,
            sessions: lhs.sessions + rhs.sessions,
            toolCalls: lhs.toolCalls + rhs.toolCalls,
            tokens: lhs.tokens + rhs.tokens
        )
    }
}

struct LiveStats: Equatable, Sendable {
    var days: [String: DayActivity] = [:]
    var modelUsage: [String: TokenUsage] = [:]

    var messageCount: Int { days.values.reduce(0) { $0 + $1.messages } }
    var sessionCount: Int { days.values.reduce(0) { $0 + $1.sessions } }
    var activeDates: Set<String> { Set(days.keys) }
}

/// Rolls up the usage Claude Code appends to `~/.claude/projects/**.jsonl` over
/// the span the on-disk stats cache does not cover yet.
///
/// That span is usually months, not minutes. `~/.claude/stats-cache.json` is
/// recomputed only when someone opens `/usage` in Claude Code — it is that
/// dialog's cache, not a running log — and even then it stops at *yesterday*,
/// because the dialog always recomputes today from the transcripts. So this
/// scanner, not the cache, is what makes the app's numbers move: everything
/// after the cache's `lastComputedDate` comes from here.
///
/// Session logs are append-only, so a rescan reads only what was added since
/// the last one: each file's tally is kept alongside the size and mtime it was
/// computed at, and a file that merely grew resumes from the byte offset the
/// previous scan stopped on. Re-parsing the whole span instead costs well over
/// a gigabyte of JSON per scan once the cache is a few weeks stale.
///
/// An actor rather than free functions because that state has to be serialised:
/// the watcher can ask for a rescan far faster than one completes.
actor LiveStatsScanner {
    static let shared = LiveStatsScanner(projectsDir: ClaudePaths.projectsDir)

    /// Large enough that a megabyte-class line still spans only a handful of
    /// reads, small enough that the buffer is not itself a memory problem.
    private static let chunkSize = 256 * 1024

    private let projectsDir: URL
    private let localDay: DateFormatter
    private let utcDay: DateFormatter
    private let isoFractional: ISO8601DateFormatter
    private let iso: ISO8601DateFormatter

    private var scanned: [String: ScannedFile] = [:]
    private var scannedCutoff: String??

    /// Memo for the days a timestamp falls on, keyed by the timestamp truncated
    /// to the hour. A day boundary is an hour boundary in every time zone, so
    /// the hour determines the day — and a session's thousands of entries
    /// collapse onto a handful of date conversions.
    private var dayByHour: [String: Days] = [:]

    private struct Days {
        let utc: String
        let local: String
    }

    init(projectsDir: URL) {
        self.projectsDir = projectsDir

        localDay = DateFormatter()
        localDay.calendar = Calendar(identifier: .gregorian)
        localDay.dateFormat = "yyyy-MM-dd"
        localDay.timeZone = TimeZone.current

        utcDay = DateFormatter()
        utcDay.calendar = Calendar(identifier: .gregorian)
        utcDay.dateFormat = "yyyy-MM-dd"
        utcDay.timeZone = TimeZone(secondsFromGMT: 0)

        isoFractional = ISO8601DateFormatter()
        isoFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
    }

    /// Counts everything recorded after `cutoff`, a `yyyy-MM-dd` day in UTC —
    /// the stats cache's `lastComputedDate`, which covers every day up to and
    /// including itself. Nil counts everything.
    ///
    /// The cutoff is compared in UTC because that is how Claude Code buckets
    /// the days it wrote into the cache, while the days this returns are local,
    /// because they are what the header and the heatmap show. The two disagree
    /// only about the hours either side of midnight UTC on the cutoff day
    /// itself, which is months in the past by the time anything reads it.
    func scan(after cutoff: String?) -> LiveStats {
        // A tally was filtered by the cutoff that was in force when it was
        // computed, so a moved cutoff invalidates every one of them.
        if scannedCutoff != .some(cutoff) {
            scanned.removeAll()
            scannedCutoff = .some(cutoff)
        }

        guard let enumerator = FileManager.default.enumerator(
            at: projectsDir,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return LiveStats() }

        var stats = LiveStats()
        var seen: Set<String> = []

        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            guard let values = try? url.resourceValues(
                forKeys: [.contentModificationDateKey, .fileSizeKey]
            ),
                let modified = values.contentModificationDate,
                let size = values.fileSize
            else { continue }

            // A file untouched since the cutoff day ended can hold nothing the
            // cache has not already counted.
            if let cutoff, utcDay.string(from: modified) <= cutoff { continue }

            let path = url.path
            seen.insert(path)
            // Claude Code's own stats count a subagent transcript's tokens but
            // not its messages or its session — the parent session is the one
            // the user started. Matching that keeps a fan-out of agents from
            // reading as a day of thirty sessions.
            let isSubagent = isSubagentTranscript(url)
            let tally = tally(
                for: url,
                path: path,
                size: Int64(size),
                modified: modified,
                isSubagent: isSubagent,
                cutoff: cutoff
            )
            merge(tally, into: &stats, cutoff: cutoff, isSubagent: isSubagent)
        }

        // Files below the cutoff, deleted projects, and cleared history would
        // otherwise keep their tally alive for the lifetime of the app.
        scanned = scanned.filter { seen.contains($0.key) }
        return stats
    }

    private func isSubagentTranscript(_ url: URL) -> Bool {
        url.deletingLastPathComponent().lastPathComponent == "subagents"
    }

    private func tally(
        for url: URL,
        path: String,
        size: Int64,
        modified: Date,
        isSubagent: Bool,
        cutoff: String?
    ) -> Tally {
        if let cached = scanned[path] {
            if cached.size == size, cached.modified == modified { return cached.tally }

            // Grew: fold in the appended bytes only. Anything else — truncated,
            // or rewritten without changing length — is not an append, so the
            // file is re-read from the start.
            if size > cached.size {
                var entry = cached
                entry.consumed = fold(
                    url,
                    from: cached.consumed,
                    into: &entry.tally,
                    isSubagent: isSubagent,
                    cutoff: cutoff
                )
                entry.size = size
                entry.modified = modified
                scanned[path] = entry
                return entry.tally
            }
        }

        var entry = ScannedFile(size: size, modified: modified, consumed: 0, tally: Tally())
        entry.consumed = fold(url, from: 0, into: &entry.tally, isSubagent: isSubagent, cutoff: cutoff)
        scanned[path] = entry
        return entry.tally
    }

    /// Folds every complete line from `offset` onward into `tally`, returning the
    /// offset one past the last newline it consumed.
    private func fold(
        _ url: URL,
        from offset: Int64,
        into tally: inout Tally,
        isSubagent: Bool,
        cutoff: String?
    ) -> Int64 {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return offset }
        defer { try? handle.close() }
        if offset > 0 {
            do { try handle.seek(toOffset: UInt64(offset)) } catch { return offset }
        }

        var carry = Data()
        var read: Int64 = 0
        var reading = true
        while reading {
            // Every chunk arrives as an autoreleased bridge, so without a pool
            // per read they all survive until the scan returns — a gigabyte of
            // logs stays a gigabyte of resident memory.
            autoreleasepool {
                guard let chunk = try? handle.read(upToCount: Self.chunkSize), !chunk.isEmpty else {
                    reading = false
                    return
                }
                read += Int64(chunk.count)
                var start = chunk.startIndex
                // Search within the chunk, never across the carried-over
                // remainder: rescanning the accumulated buffer for each newline
                // is quadratic in line length, and a single session line runs
                // past a megabyte.
                while let newline = chunk[start...].firstIndex(of: 0x0A) {
                    if carry.isEmpty {
                        fold(line: chunk[start..<newline], into: &tally, isSubagent: isSubagent, cutoff: cutoff)
                    } else {
                        carry.append(chunk[start..<newline])
                        fold(line: carry, into: &tally, isSubagent: isSubagent, cutoff: cutoff)
                        carry.removeAll(keepingCapacity: true)
                    }
                    start = chunk.index(after: newline)
                }
                carry.append(chunk[start...])
            }
        }

        // A trailing line with no newline yet is a write in progress: leave it
        // unconsumed so the scan that sees it terminated counts it once.
        return offset + read - Int64(carry.count)
    }

    private func fold(line: Data, into tally: inout Tally, isSubagent: Bool, cutoff: String?) {
        // One pass over the record's own keys, stepping over the message body
        // rather than through it. Claude Code writes `timestamp` after
        // `message`, and a tool result that quotes JSON carries keys of the
        // same name, so a plain byte search for `"timestamp"` finds the wrong
        // one often enough to misfile a day's work.
        let head = TranscriptHead(line: line)
        guard let timestamp = head.timestamp, let stamp = parse(timestamp) else { return }

        // The first entry dates the session, and dates it whether or not the
        // cache already covers it — a resumed month-old log must not read as a
        // session started today.
        if tally.firstDayUTC == nil { tally.firstDayUTC = stamp.utc }
        if tally.firstDayLocal == nil { tally.firstDayLocal = stamp.local }

        if let cutoff, stamp.utc <= cutoff { return }

        // A sidechain entry is a subagent's turn copied into its parent's
        // transcript; Claude Code drops those rather than count the same work
        // twice.
        if head.isSidechain { return }

        if !isSubagent { tally.days[stamp.local, default: DayActivity()].messages += 1 }
        guard head.type == "assistant" else { return }

        // JSONSerialization returns autoreleased Foundation objects and a Swift
        // task drains no pool of its own, so without this a scan holds every
        // object graph it parsed until it returns.
        autoreleasepool {
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let message = obj["message"] as? [String: Any]
            else { return }

            if !isSubagent, let content = message["content"] as? [[String: Any]] {
                let calls = content.reduce(0) { $0 + (($1["type"] as? String) == "tool_use" ? 1 : 0) }
                if calls > 0 { tally.days[stamp.local, default: DayActivity()].toolCalls += calls }
            }

            guard let usage = message["usage"] as? [String: Any] else { return }
            let model = (message["model"] as? String) ?? "unknown"
            let counted = TokenUsage(
                input: (usage["input_tokens"] as? Int) ?? 0,
                output: (usage["output_tokens"] as? Int) ?? 0,
                cacheRead: (usage["cache_read_input_tokens"] as? Int) ?? 0,
                cacheCreation: (usage["cache_creation_input_tokens"] as? Int) ?? 0
            )
            tally.modelUsage[model] = (tally.modelUsage[model] ?? TokenUsage()) + counted
            tally.days[stamp.local, default: DayActivity()].tokens += counted.billable
        }
    }

    /// The day a transcript timestamp falls on, in UTC (for the cache cutoff)
    /// and locally (for everything the app displays).
    private func parse(_ timestamp: String) -> Days? {
        // Only UTC stamps are memoised. Claude Code writes `toISOString()`, so
        // that is all of them in practice — and two stamps sharing an hour but
        // not a zone do not share a day, which a key of the hour alone cannot
        // tell apart.
        let memoKey = timestamp.hasSuffix("Z") ? String(timestamp.prefix(13)) : nil
        if let memoKey, memoKey.count == 13, let known = dayByHour[memoKey] { return known }
        guard let date = isoFractional.date(from: timestamp) ?? iso.date(from: timestamp) else { return nil }
        let days = Days(utc: utcDay.string(from: date), local: localDay.string(from: date))
        if let memoKey, memoKey.count == 13 { dayByHour[memoKey] = days }
        return days
    }

    private func merge(_ tally: Tally, into stats: inout LiveStats, cutoff: String?, isSubagent: Bool) {
        for (day, activity) in tally.days {
            stats.days[day] = (stats.days[day] ?? DayActivity()) + activity
        }
        for (model, usage) in tally.modelUsage {
            stats.modelUsage[model] = (stats.modelUsage[model] ?? TokenUsage()) + usage
        }
        // The session belongs to the day it started on, and only counts at all
        // if that day is past the cutoff — a log resumed today after a month
        // idle was counted as a session when it began.
        guard !isSubagent else { return }
        guard let started = tally.firstDayLocal, let startedUTC = tally.firstDayUTC else { return }
        if let cutoff, startedUTC <= cutoff { return }
        stats.days[started, default: DayActivity()].sessions += 1
    }

    private struct Tally {
        var days: [String: DayActivity] = [:]
        var modelUsage: [String: TokenUsage] = [:]
        var firstDayUTC: String?
        var firstDayLocal: String?
    }

    private struct ScannedFile {
        var size: Int64
        var modified: Date
        /// Offset one past the last newline folded into `tally`.
        var consumed: Int64
        var tally: Tally
    }
}

/// The top-level scalars of one transcript record, read without parsing the
/// message body that makes up nearly all of its bytes.
///
/// Worth the hand-rolled walk rather than `JSONSerialization` on every line:
/// the body is where the cost is (a pasted file or a tool result runs past a
/// megabyte), and stepping over it is the difference between a scan that keeps
/// up with a busy session and one that does not. Keys are compared as bytes and
/// nothing is allocated until a value is actually wanted.
struct TranscriptHead {
    var type: String?
    var timestamp: String?
    var isSidechain = false

    private static let typeKey = Array("type".utf8)
    private static let timestampKey = Array("timestamp".utf8)
    private static let sidechainKey = Array("isSidechain".utf8)

    init(line: Data) {
        var parsed = Self()
        line.withUnsafeBytes { raw in parsed.parse(raw) }
        self = parsed
    }

    private init() {}

    private mutating func parse(_ bytes: UnsafeRawBufferPointer) {
        var i = 0
        let end = bytes.count
        func skipWhitespace() {
            while i < end, bytes[i] == 0x20 || bytes[i] == 0x09 || bytes[i] == 0x0A || bytes[i] == 0x0D {
                i += 1
            }
        }
        /// The byte range of a JSON string's contents, starting at its opening
        /// quote and leaving `i` just past its closing one.
        func readString() -> Range<Int>? {
            guard i < end, bytes[i] == 0x22 else { return nil }
            i += 1
            let start = i
            while i < end {
                let b = bytes[i]
                if b == 0x5C { i += 2; continue }        // an escape, kept verbatim
                if b == 0x22 { defer { i += 1 }; return start..<i }
                i += 1
            }
            return nil
        }
        /// Steps over one value of any type, leaving `i` just past it.
        func skipValue() {
            skipWhitespace()
            guard i < end else { return }
            let b = bytes[i]
            if b == 0x22 { _ = readString(); return }
            if b == 0x7B || b == 0x5B {                 // { or [
                var depth = 0
                var inString = false
                while i < end {
                    let c = bytes[i]
                    i += 1
                    if inString {
                        if c == 0x5C { i += 1 } else if c == 0x22 { inString = false }
                        continue
                    }
                    switch c {
                    case 0x22: inString = true
                    case 0x7B, 0x5B: depth += 1
                    case 0x7D, 0x5D:
                        depth -= 1
                        if depth == 0 { return }
                    default: break
                    }
                }
                return
            }
            while i < end, bytes[i] != 0x2C, bytes[i] != 0x7D, bytes[i] != 0x5D { i += 1 }
        }
        func matches(_ range: Range<Int>, _ key: [UInt8]) -> Bool {
            guard range.count == key.count else { return false }
            for (offset, byte) in key.enumerated() where bytes[range.lowerBound + offset] != byte {
                return false
            }
            return true
        }
        func string(_ range: Range<Int>) -> String {
            String(decoding: UnsafeRawBufferPointer(rebasing: bytes[range]), as: UTF8.self)
        }

        skipWhitespace()
        guard i < end, bytes[i] == 0x7B else { return }
        i += 1
        while true {
            skipWhitespace()
            guard i < end, bytes[i] != 0x7D else { return }
            guard let key = readString() else { return }
            skipWhitespace()
            guard i < end, bytes[i] == 0x3A else { return }     // :
            i += 1
            skipWhitespace()
            if matches(key, Self.typeKey) {
                if let value = readString() { type = string(value) } else { skipValue() }
            } else if matches(key, Self.timestampKey) {
                if let value = readString() { timestamp = string(value) } else { skipValue() }
            } else if matches(key, Self.sidechainKey) {
                isSidechain = i < end && bytes[i] == 0x74                // t, for true
                skipValue()
            } else {
                skipValue()
            }
            skipWhitespace()
            guard i < end, bytes[i] == 0x2C else { return }      // ,
            i += 1
        }
    }
}
