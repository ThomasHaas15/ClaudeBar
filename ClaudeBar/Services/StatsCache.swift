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

    var todayTokens: Int { tokens(forDay: StatsCache.todayString()) }

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
    var merged: MergedStats { MergedStats(cache: cache, live: live) }

    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init() {
        reload()
        let nc = NotificationCenter.default
        observers = [
            nc.addObserver(forName: ClaudeFileWatcher.statsChanged, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.reload() }
            },
            nc.addObserver(forName: ClaudeFileWatcher.rateLimitsChanged, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.rescanLive() }
            },
            nc.addObserver(forName: ClaudeFileWatcher.sessionsChanged, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.rescanLive() }
            }
        ]
    }


    func reload() {
        cache = StatsCache.load()
        rescanLive()
    }

    private func rescanLive() {
        let cutoff = cacheMTime()
        Task.detached(priority: .utility) { [weak self] in
            let result = LiveStatsScanner.scan(modifiedAfter: cutoff)
            await self?.applyLive(result)
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
