import Foundation

struct StatsCache: Decodable, Equatable {
    let version: Int
    let lastComputedDate: String?
    let dailyActivity: [DailyActivity]
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
    }

    struct LongestSession: Decodable, Equatable {
        let sessionId: String
        let duration: Int
        let messageCount: Int
        let timestamp: String
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

    /// Start of the local day "today" refers to. Passed in rather than read
    /// off the clock so that it changes only when `StatsStore` says it does —
    /// see the note on `StatsStore.today`.
    let today: Date

    init(cache: StatsCache?, live: LiveStats, today: Date = Calendar.current.startOfDay(for: Date())) {
        self.cache = cache
        self.live = live
        self.today = today
    }

    var totalTokens: Int {
        let cached = cache?.modelUsage.values.reduce(0) { $0 + $1.inputTokens + $1.outputTokens } ?? 0
        let extra = live.modelInputOutput.values.reduce(0) { $0 + $1.input + $1.output }
        return cached + extra
    }

    var totalSessions: Int {
        (cache?.totalSessions ?? 0) + live.sessionCount
    }

    var totalMessages: Int {
        (cache?.totalMessages ?? 0) + live.messageCount
    }

    func tokens(forDay date: String) -> Int {
        let cached = cache?.dailyModelTokens.first(where: { $0.date == date })?.tokensByModel.values.reduce(0, +) ?? 0
        return cached + (live.tokensByDate[date] ?? 0)
    }

    var todayTokens: Int { tokens(forDay: StatsCache.todayString(today)) }

    var allActiveDates: [String] {
        var set = Set(cache?.dailyActivity.map(\.date) ?? [])
        set.formUnion(live.sessionDates)
        return set.sorted()
    }

    var modelTotals: [String: TokenPair] {
        var out: [String: TokenPair] = [:]
        if let usage = cache?.modelUsage {
            for (k, v) in usage { out[k] = TokenPair(input: v.inputTokens, output: v.outputTokens) }
        }
        for (k, v) in live.modelInputOutput {
            let prior = out[k] ?? TokenPair(input: 0, output: 0)
            out[k] = TokenPair(input: prior.input + v.input, output: prior.output + v.output)
        }
        return out
    }
}

@MainActor
@Observable
final class StatsStore {
    private(set) var cache: StatsCache?
    private(set) var live: LiveStats = LiveStats()

    /// The local day "tokens today" counts, as a start-of-day instant. Held as
    /// observed state rather than read off the clock at render time: SwiftUI
    /// only re-runs `body` when observed state changes, and a Mac left alone
    /// past midnight changes nothing else — Claude Code writes to `~/.claude`
    /// only when it makes a request. Without this the header would keep
    /// yesterday's total until the next prompt.
    private(set) var today: Date = Calendar.current.startOfDay(for: Date())

    var merged: MergedStats { MergedStats(cache: cache, live: live, today: today) }

    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var rescanRequested = false

    init() {
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
            // Let a burst settle before paying for a scan at all.
            try? await Task.sleep(for: .milliseconds(400))
            while let self, self.rescanRequested {
                self.rescanRequested = false
                let result = await LiveStatsScanner.shared.scan(modifiedAfter: self.cacheMTime())
                self.applyLive(result)
            }
            self?.scanTask = nil
        }
    }

    private func applyLive(_ result: LiveStats) {
        if live != result { live = result }
    }

    private func cacheMTime() -> Date? {
        let url = ClaudePaths.statsCache
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return attrs[.modificationDate] as? Date
    }
}
