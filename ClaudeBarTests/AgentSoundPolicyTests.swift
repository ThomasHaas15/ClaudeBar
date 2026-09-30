import Testing
import Foundation
@testable import ClaudeBar

struct AgentSoundPolicyTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let atTheKeyboard: TimeInterval = 2
    private let away = AgentSoundPolicy.awayAfter + 5

    private func later(_ seconds: TimeInterval) -> Date {
        now.addingTimeInterval(seconds)
    }

    @Test func neverMakesASound() {
        var policy = AgentSoundPolicy()
        let rang = policy.shouldRing(.needsInput, for: 1, mode: .never, idleFor: away, now: now)
        #expect(!rang)
    }

    @Test func alwaysRingsOncePerCooldown() {
        var policy = AgentSoundPolicy()
        let first = policy.shouldRing(.finished, for: 1, mode: .always, idleFor: atTheKeyboard, now: now)
        let second = policy.shouldRing(.finished, for: 2, mode: .always, idleFor: atTheKeyboard, now: later(10))
        let third = policy.shouldRing(.finished, for: 3, mode: .always, idleFor: atTheKeyboard, now: later(AgentSoundPolicy.cooldown))
        #expect(first)
        #expect(!second)
        #expect(third)
    }

    /// A prompt blocks the session and a finish doesn't, so a prompt still
    /// rings inside a finish's cooldown.
    @Test func aPromptRingsRightAfterAFinish() {
        var policy = AgentSoundPolicy()
        _ = policy.shouldRing(.finished, for: 1, mode: .always, idleFor: away, now: now)
        let rang = policy.shouldRing(.needsInput, for: 2, mode: .always, idleFor: away, now: later(5))
        #expect(rang)
    }

    @Test func aFinishStaysSilentRightAfterAPrompt() {
        var policy = AgentSoundPolicy()
        _ = policy.shouldRing(.needsInput, for: 1, mode: .always, idleFor: away, now: now)
        let rang = policy.shouldRing(.finished, for: 2, mode: .always, idleFor: away, now: later(5))
        #expect(!rang)
    }

    @Test func aPromptStaysSilentRightAfterAnotherPrompt() {
        var policy = AgentSoundPolicy()
        _ = policy.shouldRing(.needsInput, for: 1, mode: .always, idleFor: away, now: now)
        let rang = policy.shouldRing(.needsInput, for: 2, mode: .always, idleFor: away, now: later(5))
        #expect(!rang)
    }

    @Test func whenAwayStaysSilentForSomeoneAtTheKeyboard() {
        var policy = AgentSoundPolicy()
        let finish = policy.shouldRing(.finished, for: 1, mode: .whenAway, idleFor: atTheKeyboard, now: now)
        let prompt = policy.shouldRing(.needsInput, for: 2, mode: .whenAway, idleFor: atTheKeyboard, now: now)
        #expect(!finish)
        #expect(!prompt)
    }

    @Test func whenAwayRingsForSomeoneWhoIsAway() {
        var policy = AgentSoundPolicy()
        let rang = policy.shouldRing(.finished, for: 1, mode: .whenAway, idleFor: away, now: now)
        #expect(rang)
    }

    /// A prompt that lands just after someone walks away finds them still at
    /// the keyboard, so it rings once they've been gone long enough to count.
    @Test func ringsLateForAPromptLeftUnansweredAfterWalkingAway() {
        var policy = AgentSoundPolicy()
        _ = policy.shouldRing(.needsInput, for: 7, mode: .whenAway, idleFor: atTheKeyboard, now: now)
        let due = later(AgentSoundPolicy.awayAfter)
        #expect(policy.nextDeadline == due)

        let ringing = policy.dueLateRing(mode: .whenAway, idleFor: AgentSoundPolicy.awayAfter + atTheKeyboard, now: due)
        #expect(ringing == 7)
        #expect(policy.nextDeadline == nil)
    }

    @Test func skipsTheLateRingIfSomeoneTouchedTheMac() {
        var policy = AgentSoundPolicy()
        _ = policy.shouldRing(.needsInput, for: 7, mode: .whenAway, idleFor: atTheKeyboard, now: now)
        let ringing = policy.dueLateRing(mode: .whenAway, idleFor: 4, now: later(AgentSoundPolicy.awayAfter))
        #expect(ringing == nil)
        #expect(policy.nextDeadline == nil)
    }

    @Test func skipsTheLateRingForAPromptAlreadyAnswered() {
        var policy = AgentSoundPolicy()
        _ = policy.shouldRing(.needsInput, for: 7, mode: .whenAway, idleFor: atTheKeyboard, now: now)
        policy.forget(7)
        #expect(policy.nextDeadline == nil)

        let ringing = policy.dueLateRing(mode: .whenAway, idleFor: away, now: later(AgentSoundPolicy.awayAfter))
        #expect(ringing == nil)
    }

    @Test func skipsTheLateRingOnceTheModeChanges() {
        var policy = AgentSoundPolicy()
        _ = policy.shouldRing(.needsInput, for: 7, mode: .whenAway, idleFor: atTheKeyboard, now: now)
        let ringing = policy.dueLateRing(mode: .never, idleFor: away, now: later(AgentSoundPolicy.awayAfter))
        #expect(ringing == nil)
    }

    @Test func neverRingsLateForAFinish() {
        var policy = AgentSoundPolicy()
        _ = policy.shouldRing(.finished, for: 7, mode: .whenAway, idleFor: atTheKeyboard, now: now)
        #expect(policy.nextDeadline == nil)
    }
}
