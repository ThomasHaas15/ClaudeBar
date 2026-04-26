import Foundation

/// Tracks daily snapshots of `seven_day.used_percentage` so we can derive
/// "today contributed +N% of the weekly limit". Persists the previous day's
/// last-observed percentage as today's baseline.
@MainActor
final class WeeklyDeltaTracker {
    private let defaults: UserDefaults
    private let storageKey = "ClaudeBar.weeklyDelta.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private struct Storage: Codable {
        var dailyLast: [String: Double] = [:]
        var baseline: Double? = nil
        var baselineDate: String? = nil
    }

    func ingest(currentPercent: Double, today: Date = Date()) {
        let day = Self.ymd(today)
        var s = load()
        if s.baselineDate != day {
            let priorDate = s.dailyLast.keys.filter { $0 < day }.max()
            if let priorDate, let last = s.dailyLast[priorDate] {
                s.baseline = last
            } else {
                s.baseline = currentPercent
            }
            s.baselineDate = day
        }
        s.dailyLast[day] = currentPercent
        prune(&s, today: today)
        save(s)
    }

    func deltaPercent(currentPercent: Double, today: Date = Date()) -> Double? {
        let day = Self.ymd(today)
        let s = load()
        guard s.baselineDate == day, let baseline = s.baseline else { return nil }
        return max(0, currentPercent - baseline)
    }

    private func load() -> Storage {
        guard let data = defaults.data(forKey: storageKey),
              let s = try? JSONDecoder().decode(Storage.self, from: data)
        else { return Storage() }
        return s
    }

    private func save(_ s: Storage) {
        guard let data = try? JSONEncoder().encode(s) else { return }
        defaults.set(data, forKey: storageKey)
    }

    private func prune(_ s: inout Storage, today: Date) {
        let cal = Calendar(identifier: .gregorian)
        guard let cutoff = cal.date(byAdding: .day, value: -14, to: today) else { return }
        let cutoffYmd = Self.ymd(cutoff)
        s.dailyLast = s.dailyLast.filter { $0.key >= cutoffYmd }
    }

    private static func ymd(_ date: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}
