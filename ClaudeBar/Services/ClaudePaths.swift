import Foundation

enum ClaudePaths {
    static var home: URL {
        let fm = FileManager.default
        if let h = ProcessInfo.processInfo.environment["HOME"] {
            return URL(fileURLWithPath: h).appendingPathComponent(".claude", isDirectory: true)
        }
        return fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true)
    }

    static var statsCache: URL { home.appendingPathComponent("stats-cache.json") }
    static var rateLimits: URL { home.appendingPathComponent("rate-limits.json") }
    static var settings: URL { home.appendingPathComponent("settings.json") }
    static var sessionsDir: URL { home.appendingPathComponent("sessions", isDirectory: true) }
    static var statuslineScript: URL { home.appendingPathComponent("claudebar-statusline.sh") }
}
