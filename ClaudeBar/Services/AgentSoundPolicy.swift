import Foundation

enum AgentSoundMode: String, CaseIterable, Identifiable {
    case whenAway
    case always
    case never

    var id: String { rawValue }

    var title: String {
        switch self {
        case .whenAway: return "When away"
        case .always:   return "Always"
        case .never:    return "Never"
        }
    }
}

/// Decides which agent notifications make a sound.
///
/// Someone using the Mac sees the banner, so `.whenAway` saves the sound for
/// someone who isn't: no keyboard or mouse input for `awayAfter`. Every mode
/// shares one budget of a sound per `cooldown`, so sessions finishing in a
/// burst ring once.
struct AgentSoundPolicy {
    enum Tone: Equatable {
        case needsInput
        case finished
    }

    static let cooldown: TimeInterval = 30
    static let awayAfter: TimeInterval = 30

    private var lastRing: (tone: Tone, at: Date)?
    /// Prompts that arrived while someone was at the keyboard, and when to ring
    /// for them if nobody has touched the Mac since.
    private var lateRings: [Int: Date] = [:]

    var nextDeadline: Date? { lateRings.values.min() }

    mutating func shouldRing(
        _ tone: Tone,
        for pid: Int,
        mode: AgentSoundMode,
        idleFor: TimeInterval,
        now: Date
    ) -> Bool {
        switch mode {
        case .never:
            return false
        case .always:
            return ring(tone, at: now)
        case .whenAway:
            if idleFor >= Self.awayAfter {
                return ring(tone, at: now)
            }
            // A prompt that lands just after someone walks away still finds
            // them "at the keyboard" and would never ring. Look again once
            // they have been gone long enough to count as away.
            if tone == .needsInput {
                lateRings[pid] = now.addingTimeInterval(Self.awayAfter)
            }
            return false
        }
    }

    /// The session whose prompt should ring now, if one is due: still
    /// unanswered, and nobody has touched the Mac since it arrived. One ring
    /// covers every prompt due together.
    mutating func dueLateRing(mode: AgentSoundMode, idleFor: TimeInterval, now: Date) -> Int? {
        let due = lateRings.filter { $0.value <= now }.sorted { $0.value < $1.value }.map(\.key)
        for pid in due {
            lateRings.removeValue(forKey: pid)
        }
        guard mode == .whenAway, idleFor >= Self.awayAfter, let oldest = due.first, ring(.needsInput, at: now) else {
            return nil
        }
        return oldest
    }

    mutating func forget(_ pid: Int) {
        lateRings.removeValue(forKey: pid)
    }

    /// A prompt still rings right after a finish, because it blocks the
    /// session and a finish doesn't. Anything else inside the cooldown is
    /// silent.
    private mutating func ring(_ tone: Tone, at now: Date) -> Bool {
        if let lastRing,
           now.timeIntervalSince(lastRing.at) < Self.cooldown,
           !(tone == .needsInput && lastRing.tone == .finished) {
            return false
        }
        lastRing = (tone, now)
        return true
    }
}
