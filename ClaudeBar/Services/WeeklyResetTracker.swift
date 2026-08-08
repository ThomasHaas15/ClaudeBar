import Foundation

struct WeeklyReset: Equatable {
    let kind: LimitKind
    /// How full the window was before it rolled over — the closing bracket on
    /// the warning that fired on the way up.
    let previousPercent: Int
    /// When the window that just started will itself reset.
    let resetsAt: Date
}

/// Announces a weekly limit rolling over.
///
/// Session windows are deliberately not tracked: a 5-hour window resets
/// several times a day, and its next reset time isn't knowable until the next
/// request, so an announcement would be both frequent and uninformative.
///
/// The window's peak has to be recorded as it happens — by the time a rollover
/// is observed the percentage has already been rolled to 0 — and it is
/// persisted so the notification survives a relaunch or a Mac that was asleep
/// at the boundary.
final class WeeklyResetTracker {
    static let kinds: [LimitKind] = [.sevenDay, .sevenDaySonnet, .sevenDayOpus]

    /// Windows quieter than this end without a word: finishing a week at 4 %
    /// isn't news. Matches the level that would have warned on the way up, so
    /// every reset notification closes a warning the user actually saw.
    static let minimumPeak = ThresholdLevel.warn.rawValue

    /// A rollover discovered long after it happened isn't news either —
    /// relaunching after a week away shouldn't report last Tuesday's reset.
    static let freshness: TimeInterval = 6 * 60 * 60

    private let defaults: UserDefaults
    private let key = "ClaudeBar.weeklyWindows.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Record where each weekly window stands and return the ones that rolled
    /// over since the last call. `limits` must already be rolled over, so that
    /// a window past its reset reports the *new* window's `resetsAt` rather
    /// than the stale one still sitting in the file.
    func resets(in limits: RateLimits?, now: Date = Date()) -> [WeeklyReset] {
        guard let limits else { return [] }
        var windows = storage()
        var events: [WeeklyReset] = []

        for kind in Self.kinds {
            guard let current = limits.limit(for: kind) else { continue }
            let resetsAt = current.resetsAt.timeIntervalSince1970

            guard let seen = windows[kind.rawValue], seen.count == 2 else {
                // First sighting: adopt it as the baseline without announcing,
                // otherwise a fresh install would report a reset it never saw.
                windows[kind.rawValue] = [resetsAt, current.usedPercentage]
                continue
            }

            guard resetsAt > seen[0] else {
                // Still the same window — keep the high-water mark.
                windows[kind.rawValue] = [seen[0], max(seen[1], current.usedPercentage)]
                continue
            }

            let peak = Int(max(seen[1], 0).rounded(.down))
            let startedAt = Date(timeIntervalSince1970: seen[0])
            // A negative age means the boundary we were tracking is still in
            // the future while a later one has already appeared — the window
            // hasn't ended yet, so there's nothing to announce.
            let age = now.timeIntervalSince(startedAt)
            if peak >= Self.minimumPeak, (0...Self.freshness).contains(age) {
                events.append(WeeklyReset(kind: kind, previousPercent: peak, resetsAt: current.resetsAt))
            }
            windows[kind.rawValue] = [resetsAt, current.usedPercentage]
        }

        defaults.set(windows, forKey: key)
        return events
    }

    private func storage() -> [String: [Double]] {
        (defaults.dictionary(forKey: key) as? [String: [Double]]) ?? [:]
    }
}
