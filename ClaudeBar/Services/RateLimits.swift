import Foundation

struct RateLimits: Decodable, Equatable {
    let fiveHour: Limit?
    let sevenDay: Limit?
    let sevenDayOpus: Limit?
    let sevenDaySonnet: Limit?

    struct Limit: Decodable, Equatable {
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
        return (try? JSONDecoder().decode(RateLimits.self, from: data))?.zeroingExpired()
    }

    /// The file at ~/.claude/rate-limits.json is only rewritten when Claude Code
    /// makes a request. If `resets_at` is in the past the window has rolled over
    /// but no new request has been made yet — show 0 % so the bar is visible and
    /// correct, keeping the known reset time until the file is refreshed.
    func zeroingExpired(now: Date = Date()) -> RateLimits {
        func zeroed(_ l: Limit?) -> Limit? {
            guard let l else { return nil }
            return l.resetsAt > now ? l : Limit(usedPercentage: 0, resetsAt: l.resetsAt)
        }
        return RateLimits(
            fiveHour: zeroed(fiveHour),
            sevenDay: zeroed(sevenDay),
            sevenDayOpus: zeroed(sevenDayOpus),
            sevenDaySonnet: zeroed(sevenDaySonnet)
        )
    }
}

@MainActor
@Observable
final class RateLimitsStore {
    private(set) var limits: RateLimits?
    @ObservationIgnored private var observer: NSObjectProtocol?

    init() {
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
        limits = RateLimits.load()
    }
}
