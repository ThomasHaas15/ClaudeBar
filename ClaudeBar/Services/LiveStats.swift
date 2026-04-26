import Foundation

struct TokenPair: Equatable {
    var input: Int
    var output: Int
}

struct LiveStats: Equatable {
    var tokensByDate: [String: Int] = [:]
    var tokensByModelByDate: [String: [String: Int]] = [:]
    var modelInputOutput: [String: TokenPair] = [:]
    var sessionDates: Set<String> = []
    var sessionCount: Int = 0
    var messageCount: Int = 0
}

enum LiveStatsScanner {
    static func scan(modifiedAfter cutoff: Date?) -> LiveStats {
        let projectsDir = ClaudePaths.home.appendingPathComponent("projects", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: projectsDir,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return LiveStats() }

        var stats = LiveStats()
        let dayFormatter = DateFormatter()
        dayFormatter.calendar = Calendar(identifier: .gregorian)
        dayFormatter.dateFormat = "yyyy-MM-dd"
        dayFormatter.timeZone = TimeZone.current

        let isoFractional = ISO8601DateFormatter()
        isoFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]

        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            if let cutoff,
               let mtime = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               mtime <= cutoff {
                continue
            }
            stats.sessionCount += 1
            scanFile(url, into: &stats, dayFormatter: dayFormatter, isoFractional: isoFractional, iso: iso)
        }
        return stats
    }

    private static func scanFile(
        _ url: URL,
        into stats: inout LiveStats,
        dayFormatter: DateFormatter,
        isoFractional: ISO8601DateFormatter,
        iso: ISO8601DateFormatter
    ) {
        guard let stream = InputStream(url: url) else { return }
        stream.open()
        defer { stream.close() }

        var fileDates: Set<String> = []
        var buffer = Data()
        let chunkSize = 64 * 1024
        var chunk = [UInt8](repeating: 0, count: chunkSize)
        while stream.hasBytesAvailable {
            let n = stream.read(&chunk, maxLength: chunkSize)
            if n <= 0 { break }
            buffer.append(chunk, count: n)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer.prefix(upTo: nl)
                buffer.removeSubrange(0...nl)
                processLine(
                    lineData,
                    into: &stats,
                    fileDates: &fileDates,
                    dayFormatter: dayFormatter,
                    isoFractional: isoFractional,
                    iso: iso
                )
            }
        }
        if !buffer.isEmpty {
            processLine(
                buffer,
                into: &stats,
                fileDates: &fileDates,
                dayFormatter: dayFormatter,
                isoFractional: isoFractional,
                iso: iso
            )
        }
        stats.sessionDates.formUnion(fileDates)
    }

    private static func processLine(
        _ data: Data,
        into stats: inout LiveStats,
        fileDates: inout Set<String>,
        dayFormatter: DateFormatter,
        isoFractional: ISO8601DateFormatter,
        iso: ISO8601DateFormatter
    ) {
        guard !data.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        guard (obj["type"] as? String) == "assistant" else { return }
        guard let message = obj["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any] else { return }
        let model = (message["model"] as? String) ?? "unknown"
        let input = (usage["input_tokens"] as? Int) ?? 0
        let output = (usage["output_tokens"] as? Int) ?? 0
        let total = input + output

        var date: String?
        if let ts = obj["timestamp"] as? String {
            let parsed = isoFractional.date(from: ts) ?? iso.date(from: ts)
            if let parsed { date = dayFormatter.string(from: parsed) }
        }

        if let d = date {
            stats.tokensByDate[d, default: 0] += total
            stats.tokensByModelByDate[d, default: [:]][model, default: 0] += total
            fileDates.insert(d)
        }

        let prior = stats.modelInputOutput[model] ?? TokenPair(input: 0, output: 0)
        stats.modelInputOutput[model] = TokenPair(input: prior.input + input, output: prior.output + output)
        stats.messageCount += 1
    }
}
