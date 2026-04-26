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
    let updatedAt: Double?

    var id: String { sessionId }

    var startDate: Date? {
        guard let ms = startedAt else { return nil }
        return Date(timeIntervalSince1970: ms / 1000)
    }
}

@Observable
final class SessionsStore {
    private(set) var sessions: [ClaudeSession] = []
    @ObservationIgnored private var observer: NSObjectProtocol?

    init() {
        reload()
        observer = NotificationCenter.default.addObserver(
            forName: ClaudeFileWatcher.sessionsChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.reload() }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func reload() {
        let dir = ClaudePaths.sessionsDir
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            sessions = []
            return
        }
        var out: [ClaudeSession] = []
        let decoder = JSONDecoder()
        for url in entries where url.pathExtension == "json" {
            if let data = try? Data(contentsOf: url),
               let s = try? decoder.decode(ClaudeSession.self, from: data) {
                out.append(s)
            }
        }
        sessions = out.sorted { ($0.startedAt ?? 0) > ($1.startedAt ?? 0) }
    }

    var activeCount: Int { sessions.count }
    var mostRecent: ClaudeSession? { sessions.first }
    var version: String? { sessions.first?.version }
}
