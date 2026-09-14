import Testing
import Foundation
@testable import ClaudeBar

@MainActor
struct StatuslineInstallerTests {
    private func makeScript(_ body: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeBarTests-\(UUID().uuidString)")
            .appendingPathComponent("claudebar-statusline.sh")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try body.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// A relay installed by an older ClaudeBar keeps running against every
    /// Claude Code that ships after it. The v1 relay read a field current
    /// versions no longer send, so it printed `5h:0%` forever.
    @Test func replacesARelayLeftByAnOlderVersion() throws {
        let url = try makeScript("#!/bin/sh\n# old relay\nexit 0\n")

        #expect(StatuslineInstaller.shared.upgradeScriptIfStale(at: url))
        #expect(try String(contentsOf: url, encoding: .utf8) == StatuslineInstaller.scriptBody)

        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        #expect(mode?.int16Value == 0o755)
    }

    @Test func leavesTheCurrentRelayAlone() throws {
        let url = try makeScript(StatuslineInstaller.scriptBody)
        #expect(!StatuslineInstaller.shared.upgradeScriptIfStale(at: url))
    }

    @Test func doesNotCreateARelayThatIsNotThere() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeBarTests-\(UUID().uuidString)/absent.sh")
        #expect(!StatuslineInstaller.shared.upgradeScriptIfStale(at: url))
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    /// The relay is the app's only source of rate-limit data, so run it the way
    /// Claude Code does — against the payload Claude Code actually sends — and
    /// check both of its jobs: the file it writes and the line it prints.
    @Test func relayRecordsThePayloadClaudeCodeSends() throws {
        let script = try makeScript(StatuslineInstaller.scriptBody)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let configDir = script.deletingLastPathComponent()

        let payload = """
        {"model":{"id":"claude-opus-5","display_name":"Opus 5"},\
        "rate_limits":{"five_hour":{"used_percentage":24.5,"resets_at":1789425600},\
        "seven_day":{"used_percentage":22,"resets_at":1789826400}}}
        """

        let output = try run(script, input: payload, configDir: configDir.path)
        #expect(output == "5h:24% 7d:22%")

        let written = try Data(contentsOf: configDir.appendingPathComponent("rate-limits.json"))
        let limits = try JSONDecoder().decode(RateLimits.self, from: written)
        #expect(limits.fiveHour?.percent == 24)
        #expect(limits.sevenDay?.percent == 22)
        #expect(limits.fiveHour?.resetsAt.timeIntervalSince1970 == 1789425600)
    }

    /// Older Claude Code versions sent a fraction under a different name; the
    /// relay still has to read those, since the app is not the thing being
    /// upgraded here.
    @Test func relayReadsTheOlderPayloadShape() throws {
        let script = try makeScript(StatuslineInstaller.scriptBody)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let configDir = script.deletingLastPathComponent()

        let payload = #"{"rate_limits":{"five_hour":{"utilization":0.42,"resets_at":1789425600}}}"#
        #expect(try run(script, input: payload, configDir: configDir.path) == "5h:42%")
    }

    @Test func relaySurvivesAPayloadWithNoLimits() throws {
        let script = try makeScript(StatuslineInstaller.scriptBody)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let configDir = script.deletingLastPathComponent()

        #expect(try run(script, input: #"{"model":{"id":"claude-opus-5"}}"#, configDir: configDir.path) == "")
        #expect(try run(script, input: "not json at all", configDir: configDir.path) == "")
    }

    private func run(_ script: URL, input: String, configDir: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path]
        var environment = ProcessInfo.processInfo.environment
        environment["CLAUDE_CONFIG_DIR"] = configDir
        process.environment = environment

        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        try process.run()
        stdin.fileHandleForWriting.write(Data(input.utf8))
        try stdin.fileHandleForWriting.close()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
