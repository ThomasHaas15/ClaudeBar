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
}

@MainActor
@Observable
final class RateLimitsStore {
    private(set) var limits: RateLimits?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let cacheKey = "ClaudeBar.lastKnownRateLimits.v1"
    @ObservationIgnored private var observer: NSObjectProtocol?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.limits = loadCache()
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
        let merged = fresh?.merging(cache: limits) ?? limits
        limits = merged
        saveCache(merged)
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
