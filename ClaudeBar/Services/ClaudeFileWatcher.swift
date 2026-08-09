import AppKit
import Foundation

@MainActor
final class ClaudeFileWatcher {
    static let shared = ClaudeFileWatcher()

    nonisolated static let statsChanged = Notification.Name("ClaudeBar.statsChanged")
    nonisolated static let rateLimitsChanged = Notification.Name("ClaudeBar.rateLimitsChanged")
    nonisolated static let sessionsChanged = Notification.Name("ClaudeBar.sessionsChanged")
    nonisolated static let dayChanged = Notification.Name("ClaudeBar.dayChanged")

    private static let pollInterval: TimeInterval = 30

    private var sources: [DispatchSourceFileSystemObject] = []
    private var pollTimer: DispatchSourceTimer?
    private var boundaryTimer: DispatchSourceTimer?
    private var boundaryDeadline: Date?
    private var dayTimer: DispatchSourceTimer?
    private var observers: [NSObjectProtocol] = []

    private init() {}

    func start() {
        guard sources.isEmpty else { return }
        watchPath(ClaudePaths.statsCache, name: ClaudeFileWatcher.statsChanged)
        watchPath(ClaudePaths.rateLimits, name: ClaudeFileWatcher.rateLimitsChanged)
        watchDirectory(ClaudePaths.sessionsDir, name: ClaudeFileWatcher.sessionsChanged)

        let timer = DispatchSource.makeTimerSource(queue: .main)
        // Wall-clock, not mach time: a mach deadline stops advancing while the
        // Mac sleeps, so a machine that slept through a reset would keep
        // showing the old window for another full interval after waking.
        timer.schedule(
            wallDeadline: .now() + Self.pollInterval,
            repeating: Self.pollInterval,
            leeway: .seconds(5)
        )
        timer.setEventHandler {
            NotificationCenter.default.post(name: ClaudeFileWatcher.rateLimitsChanged, object: nil)
            NotificationCenter.default.post(name: ClaudeFileWatcher.sessionsChanged, object: nil)
        }
        timer.resume()
        pollTimer = timer

        scheduleDayBoundary()
        observeSystemEvents()
    }

    /// Fire once when the next rate-limit window rolls over, so the popover and
    /// the menu-bar dot flip at the reset itself rather than up to one poll
    /// later. Deliberately no power assertion: if the Mac is asleep at the
    /// boundary the wake handler catches up instead of waking the machine.
    func scheduleResetBoundary(_ date: Date?) {
        guard let date, date > Date() else {
            boundaryTimer?.cancel()
            boundaryTimer = nil
            boundaryDeadline = nil
            return
        }
        guard boundaryDeadline != date else { return }
        boundaryTimer?.cancel()
        boundaryDeadline = date

        let timer = DispatchSource.makeTimerSource(queue: .main)
        // A second past the deadline, so the `resetsAt <= now` comparison in
        // `rolledOver` is unambiguously true by the time the handler runs.
        timer.schedule(wallDeadline: .now() + date.timeIntervalSinceNow + 1)
        timer.setEventHandler { [weak self] in
            self?.boundaryTimer = nil
            self?.boundaryDeadline = nil
            NotificationCenter.default.post(name: ClaudeFileWatcher.rateLimitsChanged, object: nil)
        }
        timer.resume()
        boundaryTimer = timer
    }

    /// Fire at the next local midnight so "tokens today" starts a fresh day on
    /// the clock. Claude Code writes to `~/.claude` only when it makes a
    /// request, so a Mac left alone overnight produces no file event to notice
    /// the day on — the header would sit on yesterday's total until the next
    /// prompt. Re-arms itself for the following midnight.
    ///
    /// No power assertion here either: a Mac asleep at midnight catches up via
    /// the wake handler rather than being woken for a number in a menu.
    private func scheduleDayBoundary() {
        dayTimer?.cancel()
        dayTimer = nil

        let now = Date()
        // `nextDate(after:matching:)` rather than +86400: a DST change makes
        // the local day 23 or 25 hours long, and in a few zones midnight
        // itself is skipped — which `.nextTime` resolves to the hour after.
        guard let midnight = Calendar.current.nextDate(
            after: now,
            matching: DateComponents(hour: 0, minute: 0, second: 0),
            matchingPolicy: .nextTime
        ) else { return }

        let timer = DispatchSource.makeTimerSource(queue: .main)
        // Wall-clock, and a second past midnight so `startOfDay` is
        // unambiguously the new day by the time the handler runs.
        timer.schedule(wallDeadline: .now() + midnight.timeIntervalSince(now) + 1)
        timer.setEventHandler { [weak self] in
            NotificationCenter.default.post(name: ClaudeFileWatcher.dayChanged, object: nil)
            self?.scheduleDayBoundary()
        }
        timer.resume()
        dayTimer = timer
    }

    /// Waking and clock changes both invalidate whatever the timers were
    /// counting toward, so re-evaluate immediately on either.
    private func observeSystemEvents() {
        let post: @Sendable (Notification) -> Void = { [weak self] _ in
            NotificationCenter.default.post(name: ClaudeFileWatcher.rateLimitsChanged, object: nil)
            NotificationCenter.default.post(name: ClaudeFileWatcher.sessionsChanged, object: nil)
            NotificationCenter.default.post(name: ClaudeFileWatcher.dayChanged, object: nil)
            // Sleeping through midnight passes the deadline without firing it,
            // and moving time zone moves midnight itself — both leave the day
            // timer counting toward the wrong instant.
            Task { @MainActor in self?.scheduleDayBoundary() }
        }
        observers.append(
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main, using: post
            )
        )
        for name in [NSNotification.Name.NSSystemClockDidChange, .NSSystemTimeZoneDidChange] {
            observers.append(
                NotificationCenter.default.addObserver(
                    forName: name, object: nil, queue: .main, using: post
                )
            )
        }
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
