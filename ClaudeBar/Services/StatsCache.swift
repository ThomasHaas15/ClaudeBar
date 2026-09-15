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
    /// Decoded to document the file, not to be believed: these totals count
    /// cache reads and writes alongside input and output, which is two orders
    /// of magnitude above what this app calls tokens. Per-day figures come from
    /// `LiveStats.dayTokens` and `TokenHistory` instead — see `dailyTokens`.
    let dailyModelTokens: [DailyModelTokens]
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

    var totalTokens: Int {
        let cached = cache?.modelUsage.values.reduce(0) { $0 + $1.inputTokens + $1.outputTokens } ?? 0
        return cached + live.modelUsage.values.reduce(0) { $0 + $1.billable }
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

    /// Per-day token totals, in the app's measure: input + output, counted from
    /// the transcripts. Two sources, both of them that measure — what the scan
    /// can still see, over what ClaudeBar recorded while it could.
    ///
    /// Kept apart from `dailyRecords` because the stats cache must not
    /// contribute here at all. Its `dailyModelTokens` counts cache reads and
    /// writes too, so a day taken from it beside a day taken from the scan is
    /// not a comparison; better a day with no figure than one that reads a
    /// hundred times too big.
    ///
    /// Which means a day is *absent* rather than zero when no figure survives
    /// for it — a day worked on before ClaudeBar was installed, or before it was
    /// last run for long enough to matter. Callers showing a number per day have
    /// to tell those apart: see `HeatmapGrid` and `PeriodTrend.complete`.
    var dailyTokens: [String: Int] {
        var byDate: [String: Int] = [:]
        for (date, recorded) in history { byDate[date] = recorded.tokens }
        for (date, scanned) in live.days {
            byDate[date] = max(byDate[date] ?? 0, scanned.tokens)
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

    var allActiveDates: [String] {
        dailyRecords.keys.sorted()
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
