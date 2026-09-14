import Foundation

enum ClaudePaths {
    /// Claude Code's config directory. It honours `CLAUDE_CONFIG_DIR` over
    /// `~/.claude`, so mirror that — a launchd-started menu bar app inherits no
    /// shell environment, but one launched from a terminal that exports it
    /// would otherwise read a directory Claude Code is not writing.
    static var home: URL {
        let env = ProcessInfo.processInfo.environment
        if let configured = env["CLAUDE_CONFIG_DIR"], !configured.isEmpty {
            return URL(fileURLWithPath: (configured as NSString).expandingTildeInPath, isDirectory: true)
        }
        if let h = env["HOME"] {
            return URL(fileURLWithPath: h).appendingPathComponent(".claude", isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
    }

    static var statsCache: URL { home.appendingPathComponent("stats-cache.json") }
    static var rateLimits: URL { home.appendingPathComponent("rate-limits.json") }
    static var settings: URL { home.appendingPathComponent("settings.json") }
    static var sessionsDir: URL { home.appendingPathComponent("sessions", isDirectory: true) }
    static var projectsDir: URL { home.appendingPathComponent("projects", isDirectory: true) }
    static var statuslineScript: URL { home.appendingPathComponent("claudebar-statusline.sh") }
}
