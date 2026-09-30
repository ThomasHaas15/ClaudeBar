import Foundation

struct SessionNotice: Equatable {
    enum Kind: Equatable {
        case needsInput(reason: String?)
        case finished(workedFor: TimeInterval)
    }

    let session: ClaudeSession
    let kind: Kind
}

/// Turns the status Claude Code writes for each session into the moments worth
/// a notification: a session blocked on the user, and one that finished a
/// stretch of work the user may have walked away from.
///
/// A session already running when tracking starts is adopted as it is, never
/// announced. A relaunch would otherwise report every prompt and finished turn
/// it merely found.
struct SessionActivityTracker {
    struct Update {
        var notices: [SessionNotice] = []
        /// Sessions whose notice no longer holds: they moved on, or exited.
        var withdrawn: [Int] = []
        /// Sessions that have been blocked on the user for at least `settle`.
        var needingInput = 0
        /// When the next state settles. No file write marks that moment, so
        /// the caller has to call again then.
        var nextDeadline: Date?
    }

    /// How long a state has to hold before it counts. Long enough to swallow a
    /// prompt that resolves itself or a turn that picks up a queued message
    /// straight away, short enough that nobody is left waiting on it.
    static let settle: TimeInterval = 3

    /// A turn shorter than this finishes without a word. Work is timed from
    /// the session's last status change, which is when someone last sent a
    /// prompt or answered one, so this asks whether the session has been left
    /// alone for a minute.
    static let minimumWork: TimeInterval = 60

    private var tracked: [Int: Tracked] = [:]

    mutating func update(with sessions: [ClaudeSession], now: Date) -> Update {
        var update = Update()
        var seen: Set<Int> = []

        for session in sessions where !session.isParked {
            let state = State(session)
            seen.insert(session.pid)
            let changedAt = min(session.statusDate ?? now, now)

            var entry = tracked[session.pid] ?? Tracked(
                state: state,
                since: changedAt,
                workStart: state == .working ? changedAt : nil
            )
            if state != entry.state {
                if entry.isAnnounced {
                    update.withdrawn.append(session.pid)
                }
                entry.move(to: state, at: changedAt)
            }

            let settlesAt = entry.since.addingTimeInterval(Self.settle)
            if settlesAt <= now {
                if let pending = entry.pending {
                    update.notices.append(SessionNotice(session: session, kind: pending))
                    entry.isAnnounced = true
                }
                entry.pending = nil
                if state.isNeedsInput {
                    update.needingInput += 1
                }
            } else if entry.pending != nil || state.isNeedsInput {
                update.nextDeadline = min(update.nextDeadline ?? settlesAt, settlesAt)
            }
            tracked[session.pid] = entry
        }

        for pid in tracked.keys.filter({ !seen.contains($0) }) {
            if tracked.removeValue(forKey: pid)?.isAnnounced == true {
                update.withdrawn.append(pid)
            }
        }
        return update
    }

    private enum State: Equatable {
        case working
        case idle
        case needsInput(reason: String?)
        /// Waiting, but on a slash-command dialog the user opened themselves,
        /// `/config` and the like: on a person who is already there.
        case dialogOpen

        init(_ session: ClaudeSession) {
            switch session.activity {
            case .working: self = .working
            case .idle:    self = .idle
            case .waiting: self = session.waitingFor == "dialog open" ? .dialogOpen : .needsInput(reason: session.waitingFor)
            }
        }

        var isNeedsInput: Bool {
            if case .needsInput = self { return true }
            return false
        }
    }

    private struct Tracked {
        var state: State
        var since: Date
        /// When the current stretch of work began. Kept through a drop to idle
        /// shorter than `settle`: that is one stretch of work, not two.
        var workStart: Date?
        var pending: SessionNotice.Kind?
        var isAnnounced = false

        mutating func move(to next: State, at time: Date) {
            let flicker = state == .idle && time.timeIntervalSince(since) < SessionActivityTracker.settle
            let workedFrom = state == .working ? workStart : nil
            state = next
            since = time
            pending = nil
            isAnnounced = false

            switch next {
            case .working:
                if workStart == nil || !flicker {
                    workStart = time
                }
            case .idle:
                if let workedFrom, time.timeIntervalSince(workedFrom) >= SessionActivityTracker.minimumWork {
                    pending = .finished(workedFor: time.timeIntervalSince(workedFrom))
                }
            case .needsInput(let reason):
                pending = .needsInput(reason: reason)
                workStart = nil
            case .dialogOpen:
                workStart = nil
            }
        }
    }
}
