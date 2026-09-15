import Testing
import Foundation
@testable import ClaudeBar

struct AppVersionTests {
    @Test(arguments: [
        ("0.1.0", [0, 1, 0]),
        ("v0.2.0", [0, 2, 0]),
        ("V1.2.3", [1, 2, 3]),
        ("1.2", [1, 2]),
        ("12", [12]),
        (" 0.4.1\n", [0, 4, 1])
    ])
    func parsesNumbers(_ raw: String, _ expected: [Int]) {
        #expect(AppVersion(raw)?.numbers == expected)
    }

    @Test(arguments: ["", "v", "beta", "1.x.0", "1..0", "-1.0"])
    func rejectsUnparseable(_ raw: String) {
        #expect(AppVersion(raw) == nil)
    }

    @Test func comparesComponentwiseNotLexically() {
        // The bug this rules out: "0.10.0" < "0.9.0" as strings.
        #expect(AppVersion("0.9.0")! < AppVersion("0.10.0")!)
        #expect(AppVersion("1.0.0")! > AppVersion("0.99.99")!)
        #expect(AppVersion("0.2.1")! > AppVersion("0.2.0")!)
    }

    @Test func padsMissingComponentsWithZero() {
        #expect(AppVersion("1.2")! == AppVersion("1.2.0")!)
        #expect(AppVersion("1")! == AppVersion("1.0.0")!)
        #expect(AppVersion("1.2.1")! > AppVersion("1.2")!)
    }

    @Test func prereleaseSortsBelowItsRelease() {
        #expect(AppVersion("0.3.0-rc.1")! < AppVersion("0.3.0")!)
        #expect(AppVersion("0.3.0-rc.1")! < AppVersion("0.3.0-rc.2")!)
        #expect(AppVersion("0.3.0-rc.1")! != AppVersion("0.3.0")!)
        #expect(AppVersion("0.3.0-rc.1")! > AppVersion("0.2.9")!)
    }

    @Test func roundTripsThroughDescription() {
        #expect(AppVersion("v1.2.3")!.description == "1.2.3")
        #expect(AppVersion("0.3.0-rc.1")!.description == "0.3.0-rc.1")
    }
}

struct GitHubReleaseTests {
    /// Trimmed to the fields the updater reads, with the shape GitHub's
    /// `releases/latest` actually returns.
    private func payload(
        tag: String = "v0.2.0",
        assets: String = #"""
        [
          {"name": "ClaudeBar-0.2.0.zip",
           "browser_download_url": "https://github.com/ThomasHaas15/ClaudeBar/releases/download/v0.2.0/ClaudeBar-0.2.0.zip"}
        ]
        """#
    ) -> Data {
        Data("""
        {
          "tag_name": "\(tag)",
          "name": "\(tag)",
          "html_url": "https://github.com/ThomasHaas15/ClaudeBar/releases/tag/\(tag)",
          "draft": false,
          "prerelease": false,
          "assets": \(assets)
        }
        """.utf8)
    }

    @Test func readsVersionAndAsset() throws {
        let release = try GitHubRelease.parse(payload())
        #expect(release.version == AppVersion("0.2.0")!)
        #expect(release.asset.lastPathComponent == "ClaudeBar-0.2.0.zip")
        #expect(release.page.absoluteString.hasSuffix("/releases/tag/v0.2.0"))
    }

    @Test func picksTheZipPastOtherAssets() throws {
        let release = try GitHubRelease.parse(payload(assets: #"""
        [
          {"name": "ClaudeBar-0.2.0.dmg", "browser_download_url": "https://example.com/a.dmg"},
          {"name": "ClaudeBar-0.2.0.zip", "browser_download_url": "https://example.com/b.zip"}
        ]
        """#))
        #expect(release.asset.absoluteString == "https://example.com/b.zip")
    }

    @Test func rejectsAReleaseWithNothingToInstall() {
        #expect(throws: UpdateError.noArchive(tag: "v0.2.0")) {
            try GitHubRelease.parse(payload(assets: "[]"))
        }
    }

    @Test func rejectsATagThatIsNotAVersion() {
        #expect(throws: UpdateError.unreadableRelease) {
            try GitHubRelease.parse(payload(tag: "nightly"))
        }
    }

    @Test func rejectsGarbage() {
        #expect(throws: UpdateError.unreadableRelease) {
            try GitHubRelease.parse(Data("not json".utf8))
        }
    }
}

@MainActor
struct UpdaterPreferenceTests {
    private func defaults() -> UserDefaults {
        let suite = "ClaudeBarTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    @Test func automaticIsOnUntilTurnedOff() {
        let d = defaults()
        #expect(Updater(defaults: d).automatic)

        let updater = Updater(defaults: d)
        updater.automatic = false
        #expect(!Updater(defaults: d).automatic)
    }

    @Test func startsIdle() {
        #expect(Updater(defaults: defaults()).state == .idle)
    }
}

struct SwapScriptTests {
    /// The script runs after the app is gone, so a syntax error in it is a
    /// failure nobody is around to see. `sh -n` parses without running.
    @Test func parsesAsAShellScript() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("swap-\(UUID().uuidString).sh")
        try Updater.swapScript.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-n", url.path]
        let pipe = Pipe()
        process.standardError = pipe
        try process.run()
        let complaints = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        #expect(process.terminationStatus == 0, "\(String(decoding: complaints, as: UTF8.self))")
    }

    @Test func restoresTheOldAppIfTheNewOneWillNotCopy() throws {
        // The failure that matters: a swap that dies halfway leaves the Mac
        // with no ClaudeBar at all. Point the script at a source that cannot
        // be copied and the installed bundle has to come back.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("swap-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let installed = root.appendingPathComponent("ClaudeBar.app", isDirectory: true)
        try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: installed.appendingPathComponent("marker"))

        let stage = root.appendingPathComponent("stage", isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        let script = stage.appendingPathComponent("swap.sh")
        try Updater.swapScript.write(to: script, atomically: true, encoding: .utf8)

        // A pid that has already been reaped, so the script's wait-for-exit
        // loop falls straight through instead of sitting out its timeout.
        let departed = Process()
        departed.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try departed.run()
        departed.waitUntilExit()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            script.path,
            String(departed.processIdentifier),
            root.appendingPathComponent("missing.app").path,  // nothing to copy from
            installed.path,
            stage.path
        ]
        process.environment = ProcessInfo.processInfo.environment
            .merging(["CLAUDEBAR_OPEN": "/usr/bin/true"]) { _, new in new }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        let marker = installed.appendingPathComponent("marker")
        #expect(FileManager.default.fileExists(atPath: marker.path))
        #expect(try String(contentsOf: marker, encoding: .utf8) == "old")
    }
}

struct ReleaseStatusTests {
    private let body = Data(#"""
    {"tag_name": "v0.2.0",
     "html_url": "https://github.com/ThomasHaas15/ClaudeBar/releases/tag/v0.2.0",
     "assets": [{"name": "ClaudeBar-0.2.0.zip", "browser_download_url": "https://example.com/a.zip"}]}
    """#.utf8)

    @Test func aRepoWithNoReleasesIsNotAFailure() throws {
        // What GitHub answers before the first release is cut, which is a state
        // every fresh checkout passes through — it must not read as an error.
        #expect(try GitHubRelease.parse(status: 404, body: Data()) == nil)
    }

    @Test func readsAReleaseFrom200() throws {
        let release = try GitHubRelease.parse(status: 200, body: body)
        #expect(release?.version == AppVersion("0.2.0")!)
    }

    @Test(arguments: [403, 429, 500, 503])
    func surfacesOtherStatuses(_ status: Int) {
        #expect(throws: UpdateError.server(status: status)) {
            try GitHubRelease.parse(status: status, body: self.body)
        }
    }
}

extension SwapScriptTests {
    /// The strip this replaced (`xattr -dr`) exited 64 and removed nothing, so
    /// it is worth proving that what arrives in place is actually unquarantined:
    /// Gatekeeper refuses an ad-hoc signed bundle carrying the flag.
    @Test func stripsQuarantineFromWhatItInstalls() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("swap-quarantine-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let installed = root.appendingPathComponent("ClaudeBar.app", isDirectory: true)
        try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)

        let stage = root.appendingPathComponent("stage", isDirectory: true)
        let incoming = stage.appendingPathComponent("ClaudeBar.app/Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        let nested = incoming.appendingPathComponent("Info.plist")
        try Data("new".utf8).write(to: nested)

        let quarantined = stage.appendingPathComponent("ClaudeBar.app")
        for target in [quarantined, nested] {
            try Self.shell("/usr/bin/xattr", ["-w", "com.apple.quarantine", "0081;0;test;", target.path])
        }

        let script = stage.appendingPathComponent("swap.sh")
        try Updater.swapScript.write(to: script, atomically: true, encoding: .utf8)

        let departed = Process()
        departed.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try departed.run()
        departed.waitUntilExit()

        try Self.shell("/bin/sh", [
            script.path,
            String(departed.processIdentifier),
            quarantined.path,
            installed.path,
            stage.path
        ], environment: ["CLAUDEBAR_OPEN": "/usr/bin/true"], ignoringFailure: true)

        let root_ = try Self.shell("/usr/bin/xattr", [installed.path])
        let leaf = try Self.shell("/usr/bin/xattr", [installed.appendingPathComponent("Contents/Info.plist").path])
        #expect(!root_.contains("com.apple.quarantine"), "bundle root kept the flag")
        #expect(!leaf.contains("com.apple.quarantine"), "a nested file kept the flag")
    }

    @discardableResult
    static func shell(
        _ tool: String,
        _ arguments: [String],
        environment: [String: String] = [:],
        ignoringFailure: Bool = false
    ) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment
                .merging(environment) { _, new in new }
        }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if !ignoringFailure && process.terminationStatus != 0 {
            throw UpdateError.commandFailed(tool: tool, status: process.terminationStatus)
        }
        return String(decoding: output, as: UTF8.self)
    }
}
