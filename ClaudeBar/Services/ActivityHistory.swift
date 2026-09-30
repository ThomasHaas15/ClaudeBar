import Foundation

/// ClaudeBar's own day-by-day record of the work it has seen.
///
/// Nothing else keeps one that lasts. Claude Code prunes transcripts after
/// `cleanupPeriodDays` — thirty days by default — so a day's real figures live
/// exactly as long as its logs do. Its stats cache is not the fallback it looks
/// like: `dailyActivity` moves only when someone opens `/usage`,
/// `dailyModelTokens` is rebuilt from whatever transcripts are left whenever
/// Claude Code changes how it counts, and both file their days by UTC date
/// where the app shows local ones.
///
/// So the app writes down what it sees. That is what lets the heatmap reach
/// back sixty days, and month-on-month reach back sixty more, without either
/// depending on whether Claude Code happened to recompute anything. It only
/// ever grows; a year of days is a few kilobytes.
@MainActor
final class ActivityHistory {
    static let shared = ActivityHistory(url: ActivityHistory.defaultURL)

    /// Bumped if the shape, or what a field counts, ever changes. An unreadable
    /// file is treated as no history rather than as an error, the way every
    /// other file this app reads is.
    ///
    /// 1 counted tokens as input + output, and missed every subagent. 2 counts
    /// them the way Claude Code does — see `TokenUsage.total`.
    private static let currentVersion = 2

    /// Floor between writes. Today's figures move with every message, and a day
    /// still on disk is re-derived from scratch on every scan, so anything a
    /// throttled write holds back is carried by the next one. Only a day pruned
    /// inside this window could be lost, and pruning takes a month.
    private static let writeInterval: TimeInterval = 60

    static var defaultURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return support
            .appendingPathComponent("ClaudeBar", isDirectory: true)
            .appendingPathComponent("daily-activity.json")
    }

    /// Keyed by `yyyy-MM-dd` local day. Tokens are the app's measure,
    /// `TokenUsage.total`.
    private(set) var days: [String: DayActivity]

    private let url: URL
    private var lastWrite: Date = .distantPast

    init(url: URL) {
        self.url = url
        days = Self.load(from: url)
    }

    /// Folds a scan's per-day figures in, and hands back the record as it now
    /// stands.
    ///
    /// Every field takes the larger of the two. A day's numbers only ever grow
    /// as more of it is recorded, so a figure already held gives way only to a
    /// bigger one: a day whose transcripts were half pruned scans lower than
    /// the day really was, and must not overwrite what was seen while they were
    /// whole. A day *absent* from the record is written whatever it scans at,
    /// zero included — "looked, and there was nothing" is a figure, and the one
    /// thing it must not read as is "gone".
    @discardableResult
    func record(_ scanned: [String: DayActivity], now: Date = Date()) -> [String: DayActivity] {
        var changed = false
        for (day, activity) in scanned {
            guard let known = days[day] else {
                days[day] = activity
                changed = true
                continue
            }
            let merged = DayActivity.max(known, rhs: activity)
            if merged != known {
                days[day] = merged
                changed = true
            }
        }
        if changed, now.timeIntervalSince(lastWrite) >= Self.writeInterval {
            lastWrite = now
            persist()
        }
        return days
    }

    private func persist() {
        let stored = Stored(version: Self.currentVersion, days: days)
        guard let data = try? JSONEncoder().encode(stored) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
    }

    private static func load(from url: URL) -> [String: DayActivity] {
        guard let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode(Stored.self, from: data)
        else { return [:] }
        // A version 1 token figure is hundreds of times smaller than the same
        // day counted now. On a day still on disk the next scan would replace
        // it, but a day already pruned has nothing to replace it with, and
        // would read as a collapse beside its neighbours. So every one is
        // dropped: the scan counts again what it can still see, and a day it
        // cannot reads as not recorded — which the stats cache can still fill.
        // Nothing else has changed what it counts.
        guard stored.version >= 2 else {
            return stored.days.mapValues {
                DayActivity(
                    messages: $0.messages,
                    sessions: $0.sessions,
                    toolCalls: $0.toolCalls,
                    tokens: nil
                )
            }
        }
        return stored.days
    }

    private struct Stored: Codable {
        let version: Int
        let days: [String: DayActivity]
    }
}
