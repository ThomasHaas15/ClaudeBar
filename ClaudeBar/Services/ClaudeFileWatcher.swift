import Foundation

@MainActor
final class ClaudeFileWatcher {
    static let shared = ClaudeFileWatcher()

    nonisolated static let statsChanged = Notification.Name("ClaudeBar.statsChanged")
    nonisolated static let rateLimitsChanged = Notification.Name("ClaudeBar.rateLimitsChanged")
    nonisolated static let sessionsChanged = Notification.Name("ClaudeBar.sessionsChanged")

    private var sources: [DispatchSourceFileSystemObject] = []
    private var pollTimer: DispatchSourceTimer?

    private init() {}

    func start() {
        guard sources.isEmpty else { return }
        watchPath(ClaudePaths.statsCache, name: ClaudeFileWatcher.statsChanged)
        watchPath(ClaudePaths.rateLimits, name: ClaudeFileWatcher.rateLimitsChanged)
        watchDirectory(ClaudePaths.sessionsDir, name: ClaudeFileWatcher.sessionsChanged)

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler {
            NotificationCenter.default.post(name: ClaudeFileWatcher.rateLimitsChanged, object: nil)
            NotificationCenter.default.post(name: ClaudeFileWatcher.sessionsChanged, object: nil)
        }
        timer.resume()
        pollTimer = timer
    }

    private func watchPath(_ url: URL, name: Notification.Name) {
        ensureExists(url)
        let fd = open(url.path, O_EVTONLY)
        guard fd != -1 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename],
            queue: .main
        )
        src.setEventHandler { [weak self] in
            NotificationCenter.default.post(name: name, object: nil)
            let mask = src.data
            if mask.contains(.delete) || mask.contains(.rename) {
                src.cancel()
                self?.sources.removeAll { $0 === src }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self?.watchPath(url, name: name)
                }
            }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        sources.append(src)
    }

    private func watchDirectory(_ url: URL, name: Notification.Name) {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
        let fd = open(url.path, O_EVTONLY)
        guard fd != -1 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename],
            queue: .main
        )
        src.setEventHandler {
            NotificationCenter.default.post(name: name, object: nil)
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        sources.append(src)
    }

    private func ensureExists(_ url: URL) {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
    }
}
