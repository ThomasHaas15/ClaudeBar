import Foundation

enum LimitKind: String, CaseIterable {
    case fiveHour
    case sevenDay
    case sevenDaySonnet
    case sevenDayOpus

    var label: String {
        switch self {
        case .fiveHour:       return "Session"
        case .sevenDay:       return "Weekly"
        case .sevenDaySonnet: return "Weekly (Sonnet)"
        case .sevenDayOpus:   return "Weekly (Opus)"
        }
    }
}

enum ThresholdLevel: Int {
    case warn = 80
    case critical = 100
}

struct ThresholdEvent: Equatable {
    let kind: LimitKind
    let level: ThresholdLevel
    let resetsAt: Date
    let percent: Int
}

final class ThresholdTracker {
    private let defaults: UserDefaults
    private let key = "ClaudeBar.firedThresholds.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func crossings(previous: RateLimits?, current: RateLimits?) -> [ThresholdEvent] {
        guard let current else { return [] }
        var events: [ThresholdEvent] = []
        for kind in LimitKind.allCases {
            let cur = current.limit(for: kind)
            let prev = previous?.limit(for: kind)
            guard let cur else { continue }
            for level in [ThresholdLevel.warn, .critical] {
                let crossed = (prev?.usedPercentage ?? 0) < Double(level.rawValue) && cur.usedPercentage >= Double(level.rawValue)
                let firstSeenAtOrAbove = prev == nil && cur.usedPercentage >= Double(level.rawValue)
                guard crossed || firstSeenAtOrAbove else { continue }
                if hasFired(kind: kind, level: level, resetsAt: cur.resetsAt) { continue }
                events.append(ThresholdEvent(
                    kind: kind,
                    level: level,
                    resetsAt: cur.resetsAt,
                    percent: Int(cur.usedPercentage.rounded(.down))
                ))
                markFired(kind: kind, level: level, resetsAt: cur.resetsAt)
            }
        }
        prune(current: current)
        return events
    }

    private func storage() -> [String: Double] {
        (defaults.dictionary(forKey: key) as? [String: Double]) ?? [:]
    }

    private func hasFired(kind: LimitKind, level: ThresholdLevel, resetsAt: Date) -> Bool {
        let key = storageKey(kind: kind, level: level)
        guard let stored = storage()[key] else { return false }
        return abs(stored - resetsAt.timeIntervalSince1970) < 1.0
    }

    private func markFired(kind: LimitKind, level: ThresholdLevel, resetsAt: Date) {
        var s = storage()
        s[storageKey(kind: kind, level: level)] = resetsAt.timeIntervalSince1970
        defaults.set(s, forKey: key)
    }

    private func prune(current: RateLimits) {
        let now = Date().timeIntervalSince1970
        var s = storage()
        for k in s.keys {
            if let stored = s[k], stored < now - 60 {
                s.removeValue(forKey: k)
            }
        }
        defaults.set(s, forKey: key)
    }

    private func storageKey(kind: LimitKind, level: ThresholdLevel) -> String {
        "\(kind.rawValue).\(level.rawValue)"
    }
}
