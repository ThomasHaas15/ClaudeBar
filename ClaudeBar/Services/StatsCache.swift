import Foundation

/// `~/.claude/stats-cache.json`, the cache behind Claude Code's `/usage` stats
/// screen.
///
/// Read defensively: it is that dialog's private cache, recomputed only when
/// someone opens the dialog, and its shape has changed several times (it is on
/// version 5 at the time of writing). Every field this app needs has survived
/// every version so far, and unknown fields are ignored, so a future bump
/// should degrade to "no cache" at worst — `LiveStatsScanner` covers whatever
/// the cache does not.
struct StatsCache: Decodable, Equatable {
    let version: Int
    let lastComputedDate: String?
    let dailyActivity: [DailyActivity]
    /// Per-day tokens by model, in the app's own measure but by UTC date —
    /// read through `dailyTokens`, and only where nothing else has a figure
    /// (see `MergedStats.dailyTokens`).
    let dailyModelTokens: [DailyModelTokens]
    /// The counting `dailyModelTokens` was made with. Claude Code rebuilds the
    /// column from the transcripts still on disk whenever it bumps this, so a
    /// version other than the one checked here may count something else.
    let dailyModelTokensVersion: Int?
    let modelUsage: [String: ModelUsage]
    let totalSessions: Int
    let totalMessages: Int
    let longestSession: LongestSession?
    let firstSessionDate: String?
    let hourCounts: [String: Int]

    struct DailyActivity: Decodable, Equatable {
        let date: String
        let messageCount: Int
        let sessionCount: Int
        let toolCallCount: Int
    }

    struct DailyModelTokens: Decodable, Equatable {
        let date: String
        let tokensByModel: [String: Int]
    }

    struct ModelUsage: Decodable, Equatable {
        let inputTokens: Int
        let outputTokens: Int
        let cacheReadInputTokens: Int
        let cacheCreationInputTokens: Int
        let webSearchRequests: Int

        var usage: TokenUsage {
            TokenUsage(
                input: inputTokens,
                output: outputTokens,
                cacheRead: cacheReadInputTokens,
                cacheCreation: cacheCreationInputTokens
            )
        }
    }

    struct LongestSession: Decodable, Equatable {
        let sessionId: String
        let duration: Int
        let messageCount: Int
        let timestamp: String
    }

    /// The `dailyModelTokensVersion` checked against the scan: all four token
    /// columns, subagents included, bucketed by UTC day. It matched a scan of
    /// the same transcripts to the token.
    static let checkedDailyModelTokensVersion = 5

    /// `dailyModelTokens` per day, across models — or nothing when the column
    /// is a version nobody has checked. Better a day with no figure than one
    /// counted some other way.
    var dailyTokens: [String: Int] {
        guard dailyModelTokensVersion == Self.checkedDailyModelTokensVersion else { return [:] }
        var byDate: [String: Int] = [:]
        for day in dailyModelTokens {
            byDate[day.date, default: 0] += day.tokensByModel.values.reduce(0, +)
        }
        return byDate
    }

    /// The last day the cache accounts for, inclusive — everything after it has
    /// to come from the session logs. Nil unless it is a plain `yyyy-MM-dd`,
    /// since the scanner compares it as a string.
    var coveredThrough: String? {
        guard let lastComputedDate, lastComputedDate.count == 10 else { return nil }
        let parts = lastComputedDate.split(separator: "-")
        guard parts.count == 3, parts.allSatisfy({ $0.allSatisfy(\.isNumber) }) else { return nil }
        return lastComputedDate
    }

    static func load(from url: URL = ClaudePaths.statsCache) -> StatsCache? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        return try? decoder.decode(StatsCache.self, from: data)
    }

    static func todayString(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}

struct MergedStats: Equatable {
    let cache: StatsCache?
    let live: LiveStats

    /// What ClaudeBar recorded on earlier runs, for the days whose transcripts
    /// Claude Code has since pruned.
    let history: [String: DayActivity]

    /// Start of the local day "today" refers to. Passed in rather than read
    /// off the clock so that it changes only when `StatsStore` says it does —
    /// see the note on `StatsStore.today`.
    let today: Date

    init(
        cache: StatsCache?,
        live: LiveStats,
        history: [String: DayActivity] = [:],
        today: Date = Calendar.current.startOfDay(for: Date())
    ) {
        self.cache = cache
        self.live = live
        self.history = history
        self.today = today
    }

    var hasData: Bool { cache != nil || !live.days.isEmpty || !history.isEmpty }

    /// Every model's columns added up, lifetime. Its `total` is the figure
    /// Claude Code's own stats show as "Total tokens".
    var totalUsage: TokenUsage {
        modelTotals.values.reduce(TokenUsage(), +)
    }

    var totalSessions: Int {
        (cache?.totalSessions ?? 0) + live.newSessions
    }

    var totalMessages: Int {
        (cache?.totalMessages ?? 0) + live.newMessages
    }

    /// Every day any of the three sources knows about, each field taken from
    /// whichever source recorded the most of it.
    ///
    /// Not a sum. All three are partial observations of the same days rather
    /// than slices of different ones: the scan sees whatever transcripts are
    /// still on disk, the app's own record holds what the scan saw on earlier
    /// runs, and the cache holds whatever Claude Code last computed. Adding
    /// them would count a day two or three times over; taking the largest gives
    /// the fullest account anything has of that day, and a day scanned short
    /// because half its logs were pruned cannot erase what was seen while they
    /// were whole.
    var dailyRecords: [String: DayActivity] {
        var byDate: [String: DayActivity] = [:]
        for day in cache?.dailyActivity ?? [] {
            byDate[day.date] = DayActivity(
                messages: day.messageCount,
                sessions: day.sessionCount,
                toolCalls: day.toolCallCount
            )
        }
        for (date, recorded) in history {
            byDate[date] = DayActivity.max(byDate[date] ?? DayActivity(), rhs: recorded)
        }
        for (date, scanned) in live.days {
            byDate[date] = DayActivity.max(byDate[date] ?? DayActivity(), rhs: scanned)
        }
        return byDate
    }

    /// `dailyRecords` in the shape the cache writes, for the heatmap.
    var dailyActivity: [StatsCache.DailyActivity] {
        dailyRecords
            .map { date, day in
                StatsCache.DailyActivity(
                    date: date,
                    messageCount: day.messages,
                    sessionCount: day.sessions,
                    toolCallCount: day.toolCalls
                )
            }
            .sorted { $0.date < $1.date }
    }

    /// Per-day token totals, in the app's measure (`TokenUsage.total`): what
    /// the scan can still see, over what ClaudeBar recorded while it could, and
    /// the stats cache only where neither of those has anything nearby.
    ///
    /// Kept apart from `dailyRecords` because the cache cannot merge the way it
    /// does there. Its days are UTC dates and these are local, so a night's
    /// work past midnight is filed under a different day in each, and taking
    /// the larger figure per day counts that work twice — enough to read a week
    /// several percent high. Nor is a date missing here a gap the cache can
    /// fill on its own: a UTC day runs into the local day to one side of it,
    /// and a figure on that day may already hold some of the same hours. No
    /// zone is offset by a whole day, so a UTC day never reaches past the
    /// local days either side of its date; a cache day fills in only when
    /// none of those three has a figure, and then none of its work is counted
    /// anywhere else.
    ///
    /// Which means a day is *absent* rather than zero when no figure survives
    /// for it — a day pruned before ClaudeBar counted it this way, and dropped
    /// from the cache when Claude Code last rebuilt the column. Callers showing
    /// a number per day have to tell those apart: see `HeatmapGrid` and
    /// `PeriodTrend.complete`.
    var dailyTokens: [String: Int] {
        var byDate: [String: Int] = [:]
        for (date, recorded) in history {
            if let tokens = recorded.tokens { byDate[date] = tokens }
        }
        for (date, scanned) in live.days {
            if let tokens = scanned.tokens { byDate[date] = max(byDate[date] ?? 0, tokens) }
        }

        let counted = byDate
        // Only for stepping between dates: UTC has no day that is not 24 hours.
        let utc = DateFormatter()
        utc.calendar = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)
        utc.dateFormat = "yyyy-MM-dd"
        for (date, tokens) in cache?.dailyTokens ?? [:] {
            guard let day = utc.date(from: date) else { continue }
            let reach = [-1, 0, 1].map { utc.string(from: day.addingTimeInterval(TimeInterval($0) * 86_400)) }
            if reach.allSatisfy({ counted[$0] == nil }) { byDate[date] = tokens }
        }
        return byDate
    }

    func tokens(forDay date: String) -> Int { dailyTokens[date] ?? 0 }

    var todayTokens: Int { tokens(forDay: StatsCache.todayString(today)) }

    /// Days that did some work, whichever side recorded them. A day in here
    /// with no entry in `dailyTokens` is a day whose token figure is simply
    /// gone, which is what makes a total over a span unreliable rather than
    /// small.
    var daysWithActivity: Set<String> {
        Set(dailyRecords.filter { !$0.value.isEmpty }.keys)
    }

    /// Days the user was at it, for the streaks and the active-day count. Not
    /// every day with a record: a subagent that runs on past midnight leaves
    /// its tokens on a day nobody sent a message, and Claude Code's own streaks
    /// do not count that day either.
    var allActiveDates: [String] {
        dailyRecords.filter { $0.value.messages > 0 || $0.value.sessions > 0 }.keys.sorted()
    }

    var modelTotals: [String: TokenUsage] {
        var out: [String: TokenUsage] = [:]
        if let usage = cache?.modelUsage {
            for (model, value) in usage { out[model] = value.usage }
        }
        for (model, value) in live.modelUsage {
            out[model] = (out[model] ?? TokenUsage()) + value
        }
        return out
    }
}

@MainActor
@Observable
final class StatsStore {
    /// Floor between live rescans. A scan walks every session log to stat it, so
    /// this — not the work itself — is what bounds the cost of a busy session.
    private static let rescanInterval: Duration = .milliseconds(1500)

    private(set) var cache: StatsCache?
    private(set) var live: LiveStats = LiveStats()

    /// Everything `ActivityHistory` holds, mirrored here so that a view rereads
    /// when a scan adds to it.
    private(set) var history: [String: DayActivity] = [:]

    /// The local day "tokens today" counts, as a start-of-day instant. Held as
    /// observed state rather than read off the clock at render time: SwiftUI
    /// only re-runs `body` when observed state changes, and a Mac left alone
    /// past midnight changes nothing else — Claude Code writes to `~/.claude`
    /// only when it makes a request. Without this the header would keep
    /// yesterday's total until the next prompt.
    private(set) var today: Date = Calendar.current.startOfDay(for: Date())

    var merged: MergedStats {
        MergedStats(cache: cache, live: live, history: history, today: today)
    }

    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var rescanRequested = false

    init() {
        history = ActivityHistory.shared.days
        reload()
        let nc = NotificationCenter.default
        observers = [
            nc.addObserver(forName: ClaudeFileWatcher.statsChanged, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.reload() }
            },
            nc.addObserver(forName: ClaudeFileWatcher.rateLimitsChanged, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            },
            nc.addObserver(forName: ClaudeFileWatcher.sessionsChanged, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            },
            nc.addObserver(forName: ClaudeFileWatcher.dayChanged, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshToday() }
            }
        ]
    }


    func reload() {
        cache = StatsCache.load()
        refresh()
    }

    private func refresh() {
        refreshToday()
        rescanLive()
    }

    /// Move `today` on once the clock has passed midnight. Cheap enough to run
    /// on every refresh; the day timer in `ClaudeFileWatcher` only makes it
    /// prompt rather than up to one poll late.
    private func refreshToday(now: Date = Date()) {
        let start = Calendar.current.startOfDay(for: now)
        if today != start { today = start }
    }

    /// Requests a rescan, collapsing a burst of them into one.
    ///
    /// Claude Code appends to a session log on every message and the watcher
    /// fires per write, so requests arrive far faster than a scan retires.
    /// Starting one per request lets them overlap without bound, which costs a
    /// core per scan still in flight. At most one runs here, and requests raised
    /// while it works earn exactly one more pass.
    private func rescanLive() {
        rescanRequested = true
        guard scanTask == nil else { return }
        scanTask = Task(priority: .utility) { [weak self] in
            while let self, self.rescanRequested {
                // Every pass waits, not just the first: while a session is
                // active the next request lands before the current scan ends,
                // so without a floor between passes this loop scans a directory
                // of thousands of logs back to back for as long as the writing
                // continues. Clearing the flag after the wait folds everything
                // that arrived during it into the pass about to run.
                try? await Task.sleep(for: Self.rescanInterval)
                self.rescanRequested = false
                let result = await LiveStatsScanner.shared.scan(after: self.cache?.coveredThrough)
                self.applyLive(result)
            }
            self?.scanTask = nil
        }
    }

    private func applyLive(_ result: LiveStats) {
        if live != result { live = result }
        let recorded = ActivityHistory.shared.record(result.days)
        if history != recorded { history = recorded }
    }
}
