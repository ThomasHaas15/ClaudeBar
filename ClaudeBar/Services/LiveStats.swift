import Foundation

struct TokenPair: Equatable, Sendable {
    var input: Int
    var output: Int
}

struct LiveStats: Equatable, Sendable {
    var tokensByDate: [String: Int] = [:]
    var tokensByModelByDate: [String: [String: Int]] = [:]
    var modelInputOutput: [String: TokenPair] = [:]
    var sessionDates: Set<String> = []
    var sessionCount: Int = 0
    var messageCount: Int = 0
}

/// Rolls up the token usage Claude Code appends to `~/.claude/projects/**.jsonl`
/// over the span the on-disk stats cache does not cover yet.
///
/// Session logs are append-only, so a rescan reads only what was added since the
/// last one: each file's tally is kept alongside the size and mtime it was
/// computed at, and a file that merely grew resumes from the byte offset the
/// previous scan stopped on. Re-parsing the whole span instead costs well over a
/// gigabyte of JSON per scan once the cache is a few weeks stale.
///
/// An actor rather than free functions because that state has to be serialised:
/// the watcher can ask for a rescan far faster than one completes.
actor LiveStatsScanner {
    static let shared = LiveStatsScanner(
        projectsDir: ClaudePaths.home.appendingPathComponent("projects", isDirectory: true)
    )

    /// Large enough that a megabyte-class line still spans only a handful of
    /// reads, small enough that the buffer is not itself a memory problem.
    private static let chunkSize = 256 * 1024

    private static let usageKey = Data(#""usage""#.utf8)

    private let projectsDir: URL
    private let dayFormatter: DateFormatter
    private let isoFractional: ISO8601DateFormatter
    private let iso: ISO8601DateFormatter

    private var scanned: [String: ScannedFile] = [:]

    init(projectsDir: URL) {
        self.projectsDir = projectsDir

        dayFormatter = DateFormatter()
        dayFormatter.calendar = Calendar(identifier: .gregorian)
        dayFormatter.dateFormat = "yyyy-MM-dd"
        dayFormatter.timeZone = TimeZone.current

        isoFractional = ISO8601DateFormatter()
        isoFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
    }

    func scan(modifiedAfter cutoff: Date?) -> LiveStats {
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

            // Everything at or before the cutoff is already counted in the JSON
            // stats cache this overlays.
            if let cutoff, modified <= cutoff { continue }

            let path = url.path
            seen.insert(path)
            stats.sessionCount += 1
            merge(tally(for: url, path: path, size: Int64(size), modified: modified), into: &stats)
        }

        // Files below the cutoff, deleted projects, and cleared history would
        // otherwise keep their tally alive for the lifetime of the app.
        scanned = scanned.filter { seen.contains($0.key) }
        return stats
    }

    private func tally(for url: URL, path: String, size: Int64, modified: Date) -> Tally {
        if let cached = scanned[path] {
            if cached.size == size, cached.modified == modified { return cached.tally }

            // Grew: fold in the appended bytes only. Anything else — truncated,
            // or rewritten without changing length — is not an append, so the
            // file is re-read from the start.
            if size > cached.size {
                var entry = cached
                entry.consumed = fold(url, from: cached.consumed, into: &entry.tally)
                entry.size = size
                entry.modified = modified
                scanned[path] = entry
                return entry.tally
            }
        }

        var entry = ScannedFile(size: size, modified: modified, consumed: 0, tally: Tally())
        entry.consumed = fold(url, from: 0, into: &entry.tally)
        scanned[path] = entry
        return entry.tally
    }

    /// Folds every complete line from `offset` onward into `tally`, returning the
    /// offset one past the last newline it consumed.
    private func fold(_ url: URL, from offset: Int64, into tally: inout Tally) -> Int64 {
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
                        fold(line: chunk[start..<newline], into: &tally)
                    } else {
                        carry.append(chunk[start..<newline])
                        fold(line: carry, into: &tally)
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

    private func fold(line: Data, into tally: inout Tally) {
        // Only assistant messages carry a usage block, and the bulk of a session
        // log is tool results and pasted content. Rejecting those on a byte
        // search beats handing a megabyte to JSONSerialization.
        guard line.range(of: Self.usageKey) != nil else { return }

        // JSONSerialization returns autoreleased Foundation objects and a Swift
        // task drains no pool of its own, so without this a scan holds every
        // object graph it parsed until it returns.
        autoreleasepool {
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  (obj["type"] as? String) == "assistant",
                  let message = obj["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any]
            else { return }

            let model = (message["model"] as? String) ?? "unknown"
            let input = (usage["input_tokens"] as? Int) ?? 0
            let output = (usage["output_tokens"] as? Int) ?? 0
            let total = input + output

            if let timestamp = obj["timestamp"] as? String,
               let parsed = isoFractional.date(from: timestamp) ?? iso.date(from: timestamp) {
                let day = dayFormatter.string(from: parsed)
                tally.tokensByDate[day, default: 0] += total
                tally.tokensByModelByDate[day, default: [:]][model, default: 0] += total
                tally.dates.insert(day)
            }

            let prior = tally.modelInputOutput[model] ?? TokenPair(input: 0, output: 0)
            tally.modelInputOutput[model] = TokenPair(
                input: prior.input + input,
                output: prior.output + output
            )
            tally.messageCount += 1
        }
    }

    private func merge(_ tally: Tally, into stats: inout LiveStats) {
        for (day, tokens) in tally.tokensByDate {
            stats.tokensByDate[day, default: 0] += tokens
        }
        for (day, byModel) in tally.tokensByModelByDate {
            for (model, tokens) in byModel {
                stats.tokensByModelByDate[day, default: [:]][model, default: 0] += tokens
            }
        }
        for (model, pair) in tally.modelInputOutput {
            let prior = stats.modelInputOutput[model] ?? TokenPair(input: 0, output: 0)
            stats.modelInputOutput[model] = TokenPair(
                input: prior.input + pair.input,
                output: prior.output + pair.output
            )
        }
        stats.sessionDates.formUnion(tally.dates)
        stats.messageCount += tally.messageCount
    }

    private struct Tally {
        var tokensByDate: [String: Int] = [:]
        var tokensByModelByDate: [String: [String: Int]] = [:]
        var modelInputOutput: [String: TokenPair] = [:]
        var dates: Set<String> = []
        var messageCount: Int = 0
    }

    private struct ScannedFile {
        var size: Int64
        var modified: Date
        /// Offset one past the last newline folded into `tally`.
        var consumed: Int64
        var tally: Tally
    }
}
