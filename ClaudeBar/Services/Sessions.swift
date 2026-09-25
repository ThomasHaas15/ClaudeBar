import Foundation

struct ClaudeSession: Decodable, Equatable, Identifiable {
    let pid: Int
    let sessionId: String
    let cwd: String?
    let startedAt: Double?
    let version: String?
    let kind: String?
    let entrypoint: String?
    let status: String?
    let waitingFor: String?
    let statusUpdatedAt: Double?
    let updatedAt: Double?
    let name: String?
    let nameSource: String?
    let parkedJobId: String?

    var id: String { sessionId }

    var startDate: Date? {
        guard let ms = startedAt else { return nil }
        return Date(timeIntervalSince1970: ms / 1000)
    }

    var statusDate: Date? {
        guard let ms = statusUpdatedAt else { return nil }
        return Date(timeIntervalSince1970: ms / 1000)
    }

    /// What Claude Code is doing in this session. It writes four states —
    /// `busy`, `shell`, `idle` and `waiting` — where it once wrote two, and a
    /// session shelling out to a build is working, not idle.
    enum Activity {
        case working
        case waiting
        case idle
    }

    var activity: Activity {
        switch status?.lowercased() {
        case "busy", "shell": return .working
        case "waiting":       return .waiting
        default:              return .idle
        }
    }

    /// Claude Code's own background services keep a registry entry each. They
    /// are not sessions anyone started, so counting them would report work
    /// nobody is doing.
    var isUserSession: Bool {
        switch kind?.lowercased() {
        case "daemon", "daemon-worker": return false
        default: return true
        }
    }

    /// Claude Code removes its registry file on exit, but a session killed
    /// outright leaves one behind — it checks the pid the same way before
    /// trusting an entry.
    var isRunning: Bool {
        guard pid > 1 else { return false }
        if kill(pid_t(pid), 0) == 0 { return true }
        return errno == EPERM
    }

    /// Left behind by a terminal whose conversation moved to a background job.
    /// The job's own record carries the live status; this one goes stale.
    var isParked: Bool { parkedJobId != nil }

    var projectName: String {
        guard let cwd, !cwd.isEmpty, cwd != "?" else { return "Claude Code" }
        let worktree = cwd.components(separatedBy: "/.claude/worktrees/")
        if worktree.count == 2, let branch = worktree[1].split(separator: "/").first {
            return "\(URL(fileURLWithPath: worktree[0]).lastPathComponent) › \(branch)"
        }
        return URL(fileURLWithPath: cwd).lastPathComponent
    }

    /// The session's name when it says something the project doesn't. The name
    /// Claude Code gives a session by default is the folder plus a random
    /// suffix, so only names a person, a hook or the task itself chose count.
    var descriptiveName: String? {
        guard let name, !name.isEmpty else { return nil }
        switch nameSource {
        case nil, "user", "peer", "hook", "auto":
            return name
        default:
            return nil
        }
    }
}

@MainActor
@Observable
final class SessionsStore {
    /// Posted after `sessions` changes, so anything reacting to session
    /// activity reads the same list the UI does.
    nonisolated static let didUpdate = Notification.Name("ClaudeBar.sessionsDidUpdate")

    private(set) var sessions: [ClaudeSession] = []
    @ObservationIgnored private var observer: NSObjectProtocol?

    init() {
        reload()
        observer = NotificationCenter.default.addObserver(
            forName: ClaudeFileWatcher.sessionsChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
    }

    func reload() {
        let dir = ClaudePaths.sessionsDir
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            publish([])
            return
        }
        let previous = Dictionary(sessions.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        var out: [ClaudeSession] = []
        let decoder = JSONDecoder()
        for url in entries where url.pathExtension == "json" {
            if let data = try? Data(contentsOf: url),
               let s = try? decoder.decode(ClaudeSession.self, from: data) {
                out.append(s)
            } else if let pid = Int(url.deletingPathExtension().lastPathComponent), let prior = previous[pid] {
                // Claude Code rewrites these files in place, so a read can land
                // between the truncate and the write. Keep what the file said
                // last instead of losing the session for one read.
                out.append(prior)
            }
        }
        publish(out.filter { $0.isUserSession && $0.isRunning }.sorted { ($0.startedAt ?? 0) > ($1.startedAt ?? 0) })
    }

    private func publish(_ fresh: [ClaudeSession]) {
        guard fresh != sessions else { return }
        sessions = fresh
        NotificationCenter.default.post(name: Self.didUpdate, object: nil)
    }

    var activeCount: Int { sessions.count }
    var mostRecent: ClaudeSession? { sessions.first }
    var version: String? { sessions.first?.version }
    var activitySummary: String { SessionSummary.text(for: sessions) }
}

/// The Status tab's one-line answer to "what is Claude Code doing right now".
enum SessionSummary {
    static func text(for sessions: [ClaudeSession]) -> String {
        guard !sessions.isEmpty else { return "Not running" }
        if sessions.count == 1 {
            switch sessions[0].activity {
            case .working: return "Working"
            case .waiting: return "Waiting for you"
            case .idle:    return "Idle"
            }
        }
        let working = sessions.filter { $0.activity == .working }.count
        let waiting = sessions.filter { $0.activity == .waiting }.count
        let idle = sessions.count - working - waiting
        // Only the groups that have anyone in them.
        var parts: [String] = []
        if working > 0 { parts.append("\(working) working") }
        if waiting > 0 { parts.append("\(waiting) waiting") }
        if idle > 0 { parts.append("\(idle) idle") }
        return parts.joined(separator: ", ")
    }
}
