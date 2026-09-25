import Testing
import Foundation
@testable import ClaudeBar

struct SessionActivityTrackerTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let settle = SessionActivityTracker.settle

    private func session(
        _ status: String,
        waitingFor: String? = nil,
        at time: Date,
        pid: Int = 101,
        parkedJobId: String? = nil
    ) -> ClaudeSession {
        ClaudeSession(
            pid: pid,
            sessionId: "session-\(pid)",
            cwd: "/Users/me/Projects/ClaudeBar",
            startedAt: nil,
            version: "2.1.282",
            kind: "interactive",
            entrypoint: "cli",
            status: status,
            waitingFor: waitingFor,
            statusUpdatedAt: time.timeIntervalSince1970 * 1000,
            updatedAt: nil,
            name: nil,
            nameSource: nil,
            parkedJobId: parkedJobId
        )
    }

    private func at(_ seconds: TimeInterval) -> Date {
        start.addingTimeInterval(seconds)
    }

    /// Launching ClaudeBar next to a session that is already waiting counts
    /// it, but doesn't announce something that was already true.
    @Test func countsButDoesNotAnnounceASessionFoundWaiting() {
        var tracker = SessionActivityTracker()
        let update = tracker.update(with: [session("waiting", waitingFor: "permission prompt", at: start)], now: at(60))
        #expect(update.notices.isEmpty)
        #expect(update.needingInput == 1)
    }

    @Test func announcesAPromptOnceItHasSettled() {
        var tracker = SessionActivityTracker()
        _ = tracker.update(with: [session("busy", at: start)], now: start)
        let prompt = session("waiting", waitingFor: "permission prompt", at: at(10))

        let early = tracker.update(with: [prompt], now: at(11))
        #expect(early.notices.isEmpty)
        #expect(early.needingInput == 0)
        #expect(early.nextDeadline == at(10 + settle))

        let settled = tracker.update(with: [prompt], now: at(10 + settle))
        #expect(settled.notices.map(\.kind) == [.needsInput(reason: "permission prompt")])
        #expect(settled.needingInput == 1)
    }

    @Test func staysQuietAboutAPromptThatResolvesWithinTheSettle() {
        var tracker = SessionActivityTracker()
        _ = tracker.update(with: [session("busy", at: start)], now: start)
        _ = tracker.update(with: [session("waiting", waitingFor: "permission prompt", at: at(10))], now: at(10))
        let resumed = tracker.update(with: [session("busy", at: at(11))], now: at(11))
        let later = tracker.update(with: [session("busy", at: at(11))], now: at(30))
        #expect(resumed.notices.isEmpty)
        #expect(later.notices.isEmpty)
    }

    /// A state can settle before ClaudeBar sees it, say after a missed file
    /// event and the next poll. Its own timestamp says it's due, so it is
    /// announced straight away rather than after another settle.
    @Test func announcesAStateThatSettledBeforeItWasSeen() {
        var tracker = SessionActivityTracker()
        _ = tracker.update(with: [session("busy", at: start)], now: start)
        let update = tracker.update(with: [session("idle", at: at(120))], now: at(150))
        #expect(update.notices.map(\.kind) == [.finished(workedFor: 120)])
    }

    @Test func announcesTheEndOfALongStretchOfWork() {
        var tracker = SessionActivityTracker()
        _ = tracker.update(with: [session("busy", at: start)], now: start)
        let done = session("idle", at: at(300))

        let early = tracker.update(with: [done], now: at(300))
        #expect(early.notices.isEmpty)
        #expect(early.nextDeadline == at(300 + settle))

        let settled = tracker.update(with: [done], now: at(300 + settle))
        #expect(settled.notices.map(\.kind) == [.finished(workedFor: 300)])
    }

    @Test func staysQuietAfterAShortTurn() {
        var tracker = SessionActivityTracker()
        _ = tracker.update(with: [session("busy", at: start)], now: start)
        _ = tracker.update(with: [session("idle", at: at(20))], now: at(20))
        let settled = tracker.update(with: [session("idle", at: at(20))], now: at(20 + settle))
        #expect(settled.notices.isEmpty)
        #expect(settled.nextDeadline == nil)
    }

    /// A turn that ends and immediately picks up a queued message is one
    /// stretch of work: the second half alone would be too short to announce.
    @Test func countsAQuickDropToIdleAsOneStretchOfWork() {
        var tracker = SessionActivityTracker()
        _ = tracker.update(with: [session("busy", at: start)], now: start)
        _ = tracker.update(with: [session("idle", at: at(50))], now: at(50))
        _ = tracker.update(with: [session("busy", at: at(51))], now: at(51))
        _ = tracker.update(with: [session("idle", at: at(80))], now: at(80))
        let settled = tracker.update(with: [session("idle", at: at(80))], now: at(80 + settle))
        #expect(settled.notices.map(\.kind) == [.finished(workedFor: 80)])
    }

    /// Answering a prompt means someone is there, so the minute starts over:
    /// a turn that ends soon after needs no announcement.
    @Test func timesWorkFromTheLastAnswer() {
        var tracker = SessionActivityTracker()
        _ = tracker.update(with: [session("busy", at: start)], now: start)
        _ = tracker.update(with: [session("waiting", waitingFor: "permission prompt", at: at(240))], now: at(240))
        _ = tracker.update(with: [session("busy", at: at(250))], now: at(250))
        _ = tracker.update(with: [session("idle", at: at(280))], now: at(280))
        let settled = tracker.update(with: [session("idle", at: at(280))], now: at(280 + settle))
        #expect(settled.notices.isEmpty)
    }

    @Test func withdrawsAPromptOnceItIsAnswered() {
        var tracker = SessionActivityTracker()
        _ = tracker.update(with: [session("busy", at: start)], now: start)
        _ = tracker.update(with: [session("waiting", waitingFor: "input needed", at: at(10))], now: at(10 + settle))
        let answered = tracker.update(with: [session("busy", at: at(40))], now: at(40))
        #expect(answered.withdrawn == [101])
        #expect(answered.needingInput == 0)
    }

    @Test func withdrawsAFinishWhenTheNextPromptIsSent() {
        var tracker = SessionActivityTracker()
        _ = tracker.update(with: [session("busy", at: start)], now: start)
        _ = tracker.update(with: [session("idle", at: at(120))], now: at(120 + settle))
        let resumed = tracker.update(with: [session("busy", at: at(200))], now: at(200))
        #expect(resumed.withdrawn == [101])
    }

    @Test func withdrawsANoticeWhenTheSessionExits() {
        var tracker = SessionActivityTracker()
        _ = tracker.update(with: [session("busy", at: start)], now: start)
        _ = tracker.update(with: [session("waiting", waitingFor: "permission prompt", at: at(10))], now: at(10 + settle))
        let exited = tracker.update(with: [], now: at(60))
        #expect(exited.withdrawn == [101])
        #expect(exited.needingInput == 0)
    }

    @Test func withdrawsNothingForASessionThatWasNeverAnnounced() {
        var tracker = SessionActivityTracker()
        _ = tracker.update(with: [session("busy", at: start)], now: start)
        let exited = tracker.update(with: [], now: at(60))
        #expect(exited.withdrawn.isEmpty)
    }

    @Test func ignoresADialogTheUserOpened() {
        var tracker = SessionActivityTracker()
        _ = tracker.update(with: [session("busy", at: start)], now: start)
        let update = tracker.update(with: [session("waiting", waitingFor: "dialog open", at: at(10))], now: at(10 + settle))
        #expect(update.notices.isEmpty)
        #expect(update.needingInput == 0)
    }

    @Test func ignoresARecordParkedForABackgroundJob() {
        var tracker = SessionActivityTracker()
        let parked = session("waiting", waitingFor: "permission prompt", at: start, parkedJobId: "e8ffc5fc")
        let update = tracker.update(with: [parked], now: at(60))
        #expect(update.needingInput == 0)
    }

    @Test func tracksEachSessionOnItsOwn() {
        var tracker = SessionActivityTracker()
        _ = tracker.update(with: [session("busy", at: start, pid: 1), session("busy", at: start, pid: 2)], now: start)
        let update = tracker.update(
            with: [
                session("idle", at: at(90), pid: 1),
                session("waiting", waitingFor: "permission prompt", at: at(90), pid: 2)
            ],
            now: at(90 + settle)
        )
        #expect(update.notices.map(\.session.pid) == [1, 2])
        #expect(update.notices.map(\.kind) == [.finished(workedFor: 90), .needsInput(reason: "permission prompt")])
    }
}
