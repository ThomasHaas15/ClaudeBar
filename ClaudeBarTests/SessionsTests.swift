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
}
