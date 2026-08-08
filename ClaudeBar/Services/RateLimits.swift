import Foundation

struct RateLimits: Codable, Equatable {
    let fiveHour: Limit?
    let sevenDay: Limit?
    let sevenDayOpus: Limit?
    let sevenDaySonnet: Limit?

    struct Limit: Codable, Equatable {
        let usedPercentage: Double
        let resetsAt: Date

        enum CodingKeys: String, CodingKey {
            case usedPercentage = "used_percentage"
            case utilization
            case resetsAt = "resets_at"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            if let p = try? c.decode(Double.self, forKey: .usedPercentage) {
                self.usedPercentage = p
            } else if let u = try? c.decode(Double.self, forKey: .utilization) {
                self.usedPercentage = u <= 1.0 ? u * 100 : u
            } else {
                throw DecodingError.dataCorruptedError(
                    forKey: .usedPercentage,
                    in: c,
                    debugDescription: "Expected used_percentage or utilization"
                )
            }
            if let secs = try? c.decode(Double.self, forKey: .resetsAt) {
                self.resetsAt = Date(timeIntervalSince1970: secs)
            } else {
                let s = try c.decode(String.self, forKey: .resetsAt)
                let iso = ISO8601DateFormatter()
                iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let d = iso.date(from: s) {
                    self.resetsAt = d
                } else {
                    iso.formatOptions = [.withInternetDateTime]
                    self.resetsAt = iso.date(from: s) ?? Date()
                }
            }
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(usedPercentage, forKey: .usedPercentage)
            try c.encode(resetsAt.timeIntervalSince1970, forKey: .resetsAt)
        }

        init(usedPercentage: Double, resetsAt: Date) {
            self.usedPercentage = usedPercentage
            self.resetsAt = resetsAt
        }

        var ratio: Double { min(max(usedPercentage / 100.0, 0), 1.5) }
        var percent: Int { Int(usedPercentage.rounded(.down)) }
    }

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayOpus = "seven_day_opus"
        case sevenDaySonnet = "seven_day_sonnet"
    }

    var hasAny: Bool {
        fiveHour != nil || sevenDay != nil || sevenDayOpus != nil || sevenDaySonnet != nil
    }

    var maxRatio: Double {
        [fiveHour, sevenDay, sevenDayOpus, sevenDaySonnet]
            .compactMap { $0?.ratio }
            .max() ?? 0
    }

    func limit(for kind: LimitKind) -> Limit? {
        switch kind {
        case .fiveHour:       return fiveHour
        case .sevenDay:       return sevenDay
        case .sevenDaySonnet: return sevenDaySonnet
        case .sevenDayOpus:   return sevenDayOpus
        }
    }

    /// The earliest reset still ahead of `now` — the next moment the display
    /// changes on its own, with no file write to trigger it.
    func nextReset(after now: Date = Date()) -> Date? {
        [fiveHour, sevenDay, sevenDayOpus, sevenDaySonnet]
            .compactMap { $0?.resetsAt }
            .filter { $0 > now }
            .min()
    }

    static func load(from url: URL = ClaudePaths.rateLimits) -> RateLimits? {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        return try? JSONDecoder().decode(RateLimits.self, from: data)
    }

    /// Fall back to `cache` for any limit the fresh load is missing. Claude Code
    /// drops a window's key from `~/.claude/rate-limits.json` when it expires
    /// and only re-adds it on the next request — without this fallback the row
    /// would disappear during that gap. The view keys "Resets after next
    /// request" off `resetsAt` being in the past, so a stale cached entry
    /// renders correctly on its own.
    func merging(cache: RateLimits?) -> RateLimits {
        RateLimits(
            fiveHour:       fiveHour       ?? cache?.fiveHour,
            sevenDay:       sevenDay       ?? cache?.sevenDay,
            sevenDayOpus:   sevenDayOpus   ?? cache?.sevenDayOpus,
            sevenDaySonnet: sevenDaySonnet ?? cache?.sevenDaySonnet
        )
    }

    static let week: TimeInterval = 7 * 24 * 60 * 60

    /// Roll any window whose reset has already passed into the one that
    /// replaced it. `~/.claude/rate-limits.json` is only rewritten when Claude
    /// Code makes a request, so between requests it keeps reporting a window
    /// that already ended — this reconstructs the current one locally, with no
    /// network call, because a rolled-over window is empty by definition.
    ///
    /// The two window types roll differently:
    ///
    /// - Weekly windows reset on a fixed 7-day cadence, so the next reset time
    ///   is known — advance it a whole number of weeks and show it.
    /// - A session window only begins when the next request is made, so its
    ///   reset time is genuinely unknown. Leave it in the past, which is what
    ///   the Usage tab keys "Resets after next request" off.
    func rolledOver(now: Date = Date()) -> RateLimits {
        RateLimits(
            fiveHour:       Self.rollSession(fiveHour, now: now),
            sevenDay:       Self.rollWeekly(sevenDay, now: now),
            sevenDayOpus:   Self.rollWeekly(sevenDayOpus, now: now),
            sevenDaySonnet: Self.rollWeekly(sevenDaySonnet, now: now)
        )
    }

    private static func rollSession(_ limit: Limit?, now: Date) -> Limit? {
        guard let limit, limit.resetsAt <= now else { return limit }
        return Limit(usedPercentage: 0, resetsAt: limit.resetsAt)
    }

    private static func rollWeekly(_ limit: Limit?, now: Date) -> Limit? {
        guard let limit, limit.resetsAt <= now else { return limit }
        // Whole weeks elapsed since the stale reset, plus the one in progress.
        // Fixed 604800 s steps rather than calendar days: the cadence is a UTC
        // instant, so it must not drift an hour across a DST change.
        let weeks = (now.timeIntervalSince(limit.resetsAt) / week).rounded(.down) + 1
        return Limit(usedPercentage: 0, resetsAt: limit.resetsAt.addingTimeInterval(weeks * week))
    }
}

@MainActor
@Observable
final class RateLimitsStore {
    /// Posted after `limits` changes, so anything reacting to rate limits reads
    /// the same merged, rolled-over value the UI does instead of racing the
    /// store to re-read the file itself.
    nonisolated static let didUpdate = Notification.Name("ClaudeBar.rateLimitsDidUpdate")

    /// What the UI shows: last-known data with expired windows rolled over.
    private(set) var limits: RateLimits?

    /// Last-known data exactly as Claude Code wrote it. Kept unrolled so it can
    /// stay the merge base and the persisted cache across window resets.
    @ObservationIgnored private var lastKnown: RateLimits?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let cacheKey = "ClaudeBar.lastKnownRateLimits.v1"
    @ObservationIgnored private var observer: NSObjectProtocol?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.lastKnown = loadCache()
        reload()
        observer = NotificationCenter.default.addObserver(
            forName: ClaudeFileWatcher.rateLimitsChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
    }

    func reload() {
        let fresh = RateLimits.load()
        let merged = fresh?.merging(cache: lastKnown) ?? lastKnown
        lastKnown = merged
        saveCache(merged)
        publish()
    }

    /// Re-derive the display value from data already in memory. Windows expire
    /// on a clock, not on a file write, so this has to run on a timer too —
    /// see `ClaudeFileWatcher`. No I/O, no network.
    private func publish() {
        let rolled = lastKnown?.rolledOver()
        // Assigning an equal value would still fire @Observable and churn the
        // menu bar every tick, so only publish real changes.
        if rolled != limits {
            limits = rolled
            NotificationCenter.default.post(name: Self.didUpdate, object: nil)
        }
        ClaudeFileWatcher.shared.scheduleResetBoundary(rolled?.nextReset())
    }

    private func loadCache() -> RateLimits? {
        guard let data = defaults.data(forKey: cacheKey) else { return nil }
        return try? JSONDecoder().decode(RateLimits.self, from: data)
    }

    private func saveCache(_ value: RateLimits?) {
        guard let value, let data = try? JSONEncoder().encode(value) else {
            defaults.removeObject(forKey: cacheKey)
            return
        }
        defaults.set(data, forKey: cacheKey)
    }
}
