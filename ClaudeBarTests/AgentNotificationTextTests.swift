import Testing
import Foundation
@testable import ClaudeBar

struct AgentNotificationTextTests {
    private func session(name: String? = nil, nameSource: String? = nil) -> ClaudeSession {
        ClaudeSession(
            pid: 101,
            sessionId: "session-101",
            cwd: "/Users/me/Projects/RP3-App",
            startedAt: nil,
            version: "2.1.282",
            kind: "interactive",
            entrypoint: "cli",
            status: "waiting",
            waitingFor: "permission prompt",
            statusUpdatedAt: nil,
            updatedAt: nil,
            name: name,
            nameSource: nameSource,
            parkedJobId: nil
        )
    }

    @Test func describesAPermissionPrompt() {
        let notice = SessionNotice(session: session(), kind: .needsInput(reason: "permission prompt"))
        #expect(AgentNotificationText.title(for: notice) == "Claude Agent Needs Your Permission")
        #expect(AgentNotificationText.body(for: notice) == "Waiting for your approval")
    }

    @Test func describesAQuestion() {
        let notice = SessionNotice(session: session(), kind: .needsInput(reason: "input needed"))
        #expect(AgentNotificationText.title(for: notice) == "Claude Agent Has a Question")
        #expect(AgentNotificationText.body(for: notice) == "Waiting for your answer")
    }

    /// A reason newer than this build still reads as a request for input.
    @Test func describesAnUnknownReasonAsARequestForInput() {
        let notice = SessionNotice(session: session(), kind: .needsInput(reason: "something new"))
        #expect(AgentNotificationText.title(for: notice) == "Claude Agent Needs Your Input")
        #expect(AgentNotificationText.body(for: notice) == "Waiting for you")
    }

    @Test func describesAFinish() {
        let notice = SessionNotice(session: session(), kind: .finished(workedFor: 4 * 60 + 10))
        #expect(AgentNotificationText.title(for: notice) == "Claude Agent Finished")
        #expect(AgentNotificationText.body(for: notice) == "Worked 4m")
    }

    /// The title names the agent, so the line under it says which session.
    @Test func namesTheProjectUnderTheTitle() {
        let notice = SessionNotice(session: session(), kind: .finished(workedFor: 300))
        #expect(AgentNotificationText.subtitle(for: notice) == "RP3-App")
    }

    @Test func addsTheSessionsOwnNameWhenItHasOne() {
        let named = session(name: "Fix axis labels", nameSource: "user")
        let notice = SessionNotice(session: named, kind: .needsInput(reason: "permission prompt"))
        #expect(AgentNotificationText.subtitle(for: notice) == "RP3-App · Fix axis labels")
    }
}
