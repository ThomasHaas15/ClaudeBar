import Testing
import Foundation
@testable import ClaudeBar

struct SessionsTests {
    private func session(
        pid: Int = 1,
        kind: String? = "interactive",
        status: String? = nil
    ) throws -> ClaudeSession {
        let json = """
        {"pid":\(pid),"sessionId":"s-\(pid)-\(status ?? "none")","cwd":"/tmp","startedAt":1789418218920,
         "procStart":"Mon Sep 14 20:36:55 2026","version":"2.1.270","peerProtocol":1,
         "peerFeatures":["notify_idle"],\(kind.map { "\"kind\":\"\($0)\"," } ?? "")"entrypoint":"cli",
         "pidDomain":"darwin","name":"claudebar-b9","nameSource":"derived",
         \(status.map { "\"status\":\"\($0)\"," } ?? "")"updatedAt":1789418279353,"statusUpdatedAt":1789418279353}
        """
        return try JSONDecoder().decode(ClaudeSession.self, from: Data(json.utf8))
    }

    private func session(cwd: String?, name: String? = nil, nameSource: String? = nil) throws -> ClaudeSession {
        var fields = [#""pid":1"#, #""sessionId":"s-1""#]
        if let cwd { fields.append("\"cwd\":\"\(cwd)\"") }
        if let name { fields.append("\"name\":\"\(name)\"") }
        if let nameSource { fields.append("\"nameSource\":\"\(nameSource)\"") }
        return try JSONDecoder().decode(ClaudeSession.self, from: Data("{\(fields.joined(separator: ","))}".utf8))
    }

    /// Claude Code writes four states where it once wrote two. A session
    /// shelling out to a build is working, not idle.
    @Test func readsEveryStatusClaudeCodeWrites() throws {
        #expect(try session(status: "busy").activity == .working)
        #expect(try session(status: "shell").activity == .working)
        #expect(try session(status: "waiting").activity == .waiting)
        #expect(try session(status: "idle").activity == .idle)
        // Absent, or a state added after this build shipped.
        #expect(try session(status: nil).activity == .idle)
        #expect(try session(status: "compacting").activity == .idle)
    }

    /// Claude Code's own background services keep a registry entry each.
    @Test func ignoresClaudeCodesOwnServices() throws {
        #expect(try session(kind: "interactive").isUserSession)
        #expect(try session(kind: "bg").isUserSession)
        #expect(try session(kind: nil).isUserSession)
        #expect(try !session(kind: "daemon").isUserSession)
        #expect(try !session(kind: "daemon-worker").isUserSession)
    }

    /// A session killed outright leaves its registry file behind; Claude Code
    /// checks the pid before trusting an entry, and so must this.
    @Test func ignoresEntriesWhoseProcessIsGone() throws {
        #expect(try session(pid: Int(ProcessInfo.processInfo.processIdentifier)).isRunning)
        #expect(try !session(pid: 0x7FFF_FFF0).isRunning)
        #expect(try !session(pid: 0).isRunning)
    }

    @Test func summarisesWhatTheSessionsAreDoing() throws {
        #expect(SessionSummary.text(for: []) == "Not running")
        #expect(try SessionSummary.text(for: [session(status: "busy")]) == "Working")
        #expect(try SessionSummary.text(for: [session(status: "waiting")]) == "Waiting for you")
        #expect(try SessionSummary.text(for: [session(status: "idle")]) == "Idle")
        #expect(
            try SessionSummary.text(for: [
                session(pid: 1, status: "busy"),
                session(pid: 2, status: "shell"),
                session(pid: 3, status: "waiting"),
                session(pid: 4, status: "idle")
            ]) == "2 working, 1 waiting, 1 idle"
        )
        #expect(
            try SessionSummary.text(for: [session(pid: 1, status: "idle"), session(pid: 2, status: "idle")]) == "2 idle"
        )
    }

    /// While a session waits, Claude Code says on what: a permission prompt,
    /// a question, a dialog someone opened.
    @Test func readsWhatAWaitingSessionIsWaitingFor() throws {
        let json = """
        {"pid":53903,"sessionId":"9e087588","cwd":"/Users/me/Projects/RP3-App","kind":"interactive",
         "status":"waiting","waitingFor":"permission prompt","statusUpdatedAt":1790336128826,
         "name":"rp3-app-4f","nameSource":"derived"}
        """
        let waiting = try JSONDecoder().decode(ClaudeSession.self, from: Data(json.utf8))
        #expect(waiting.activity == .waiting)
        #expect(waiting.waitingFor == "permission prompt")
        #expect(waiting.statusDate == Date(timeIntervalSince1970: 1_790_336_128.826))
    }

    @Test func namesTheProjectAfterItsFolder() throws {
        #expect(try session(cwd: "/Users/me/Projects/ClaudeBar").projectName == "ClaudeBar")
    }

    @Test func fallsBackToClaudeCodeWithoutAFolder() throws {
        #expect(try session(cwd: nil).projectName == "Claude Code")
    }

    @Test func namesAWorktreeAfterItsRepositoryAndBranch() throws {
        let worktree = try session(cwd: "/Users/me/Projects/RP3-App/.claude/worktrees/phone-graph-axis-labels")
        #expect(worktree.projectName == "RP3-App › phone-graph-axis-labels")
    }

    /// Claude Code names a session after its folder plus a random suffix,
    /// which says nothing the project name doesn't.
    @Test func dropsTheNameClaudeCodeDerivesFromTheFolder() throws {
        #expect(try session(cwd: "/tmp", name: "claudebar-4e", nameSource: "derived").descriptiveName == nil)
    }

    @Test func keepsANameSomeoneOrTheTaskChose() throws {
        #expect(try session(cwd: "/tmp", name: "Fix axis labels", nameSource: "user").descriptiveName == "Fix axis labels")
        #expect(
            try session(cwd: "/tmp", name: "GetPremiumViewController SwiftUI conversion", nameSource: "auto").descriptiveName
                == "GetPremiumViewController SwiftUI conversion"
        )
    }
}
