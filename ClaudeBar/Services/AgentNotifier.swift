import AppKit
import IOKit
import UserNotifications

@MainActor
@Observable
final class AgentNotifier {
    private(set) var isEnabled: Bool
    private(set) var soundMode: AgentSoundMode
    /// macOS has notifications for ClaudeBar switched off, so the toggle alone
    /// won't bring them back.
    private(set) var isBlockedBySystem = false
    private(set) var needingInputCount = 0

    @ObservationIgnored private let sessions: SessionsStore
    @ObservationIgnored private var tracker = SessionActivityTracker()
    @ObservationIgnored private var sounds = AgentSoundPolicy()
    @ObservationIgnored private var delivered: [Int: SessionNotice] = [:]
    @ObservationIgnored private var timer: DispatchSourceTimer?
    @ObservationIgnored private var timerDeadline: Date?
    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private var authRequested = false

    private static let enabledKey = "ClaudeBar.agentNotifications.enabled.v1"
    private static let soundModeKey = "ClaudeBar.agentNotifications.soundMode.v1"
    private static let identifierPrefix = "claudebar.agent."

    init(sessions: SessionsStore) {
        self.sessions = sessions
        let defaults = UserDefaults.standard
        isEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        soundMode = defaults.string(forKey: Self.soundModeKey).flatMap(AgentSoundMode.init(rawValue:)) ?? .whenAway
        removeLeftoverNotices()
        observer = NotificationCenter.default.addObserver(
            forName: SessionsStore.didUpdate,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.evaluate() }
        }
        evaluate()
        if isEnabled {
            requestAuthorizationIfNeeded()
        }
        refreshAuthorization()
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
        if enabled {
            requestAuthorizationIfNeeded()
            refreshAuthorization()
        } else {
            // Switching off clears what is already up, not only what's to come.
            for pid in Array(delivered.keys) {
                withdraw(pid)
            }
            sounds = AgentSoundPolicy()
        }
    }

    func setSoundMode(_ mode: AgentSoundMode) {
        soundMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: Self.soundModeKey)
    }

    func refreshAuthorization() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            let blocked = settings.authorizationStatus == .denied
            Task { @MainActor in
                guard let self, self.isBlockedBySystem != blocked else { return }
                self.isBlockedBySystem = blocked
            }
        }
    }

    func openNotificationSettings() {
        let bundleId = Bundle.main.bundleIdentifier ?? ""
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(bundleId)") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func evaluate() {
        let now = Date()
        let update = tracker.update(with: sessions.sessions, now: now)
        for pid in update.withdrawn {
            withdraw(pid)
        }
        if needingInputCount != update.needingInput {
            needingInputCount = update.needingInput
        }
        let lateRingDue = (sounds.nextDeadline ?? .distantFuture) <= now
        if isEnabled, !update.notices.isEmpty || lateRingDue {
            let idleFor = Self.secondsSinceUserInput()
            for notice in update.notices {
                let ringing = sounds.shouldRing(
                    notice.kind.tone,
                    for: notice.session.pid,
                    mode: soundMode,
                    idleFor: idleFor,
                    now: now
                )
                post(notice, ringing: ringing)
            }
            if let pid = sounds.dueLateRing(mode: soundMode, idleFor: idleFor, now: now), let notice = delivered[pid] {
                post(notice, ringing: true)
            }
        }
        schedule(at: [update.nextDeadline, sounds.nextDeadline].compactMap { $0 }.min())
    }

    private func post(_ notice: SessionNotice, ringing: Bool) {
        requestAuthorizationIfNeeded()
        let content = UNMutableNotificationContent()
        content.title = AgentNotificationText.title(for: notice)
        content.subtitle = AgentNotificationText.subtitle(for: notice)
        content.body = AgentNotificationText.body(for: notice)
        content.threadIdentifier = "claudebar.agents"
        if ringing {
            content.sound = notice.kind.sound
        }
        // One identifier per session, so a newer notice replaces the older one
        // and withdrawing it needs nothing but the pid.
        let request = UNNotificationRequest(
            identifier: Self.identifier(for: notice.session.pid),
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
        delivered[notice.session.pid] = notice
    }

    private func withdraw(_ pid: Int) {
        sounds.forget(pid)
        guard delivered.removeValue(forKey: pid) != nil else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.identifier(for: pid)])
    }

    /// Notices posted before a relaunch can't be withdrawn by this run, which
    /// never saw them go up, so they'd sit in Notification Center for good.
    private func removeLeftoverNotices() {
        let prefix = Self.identifierPrefix
        UNUserNotificationCenter.current().getDeliveredNotifications { notifications in
            let leftovers = notifications.map(\.request.identifier).filter { $0.hasPrefix(prefix) }
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: leftovers)
        }
    }

    private func requestAuthorizationIfNeeded() {
        guard !authRequested else { return }
        authRequested = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] _, _ in
            Task { @MainActor in self?.refreshAuthorization() }
        }
    }

    /// Settling states and late rings come due with no file write to mark
    /// them, so wake for the earliest one.
    private func schedule(at deadline: Date?) {
        guard deadline != timerDeadline else { return }
        timer?.cancel()
        timer = nil
        timerDeadline = deadline
        guard let deadline else { return }

        let timer = DispatchSource.makeTimerSource(queue: .main)
        // A beat past the deadline, so whatever it wakes for is unambiguously
        // due by the time the handler runs.
        timer.schedule(wallDeadline: .now() + max(deadline.timeIntervalSinceNow, 0) + 0.1)
        timer.setEventHandler { [weak self] in
            self?.timer = nil
            self?.timerDeadline = nil
            self?.evaluate()
        }
        timer.resume()
        self.timer = timer
    }

    private static func identifier(for pid: Int) -> String {
        "\(identifierPrefix)\(pid)"
    }

    /// Seconds since the last keyboard, mouse or trackpad event, read from the
    /// HID system's idle counter: a registry property any process may read,
    /// unlike event-level APIs that can put up an Input Monitoring prompt.
    /// Unreadable counts as present, which only ever costs a sound.
    private static func secondsSinceUserInput() -> TimeInterval {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
        guard service != IO_OBJECT_NULL else { return 0 }
        defer { IOObjectRelease(service) }
        guard let property = IORegistryEntryCreateCFProperty(service, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue(),
            let nanoseconds = (property as? NSNumber)?.uint64Value
        else { return 0 }
        return TimeInterval(nanoseconds) / 1_000_000_000
    }
}

private extension SessionNotice.Kind {
    var tone: AgentSoundPolicy.Tone {
        switch self {
        case .needsInput: return .needsInput
        case .finished:   return .finished
        }
    }

    var sound: UNNotificationSound {
        switch self {
        case .needsInput: return UNNotificationSound(named: UNNotificationSoundName("Submarine"))
        case .finished:   return UNNotificationSound(named: UNNotificationSoundName("Glass"))
        }
    }
}

enum AgentNotificationText {
    /// Names the agent, not the project: macOS heads every banner with
    /// "ClaudeBar", so a title that opened with the project read as the app
    /// itself having finished. The project goes on the line below.
    static func title(for notice: SessionNotice) -> String {
        switch notice.kind {
        case .finished:
            return "Claude Agent Finished"
        case .needsInput(let reason):
            switch reason {
            case "permission prompt": return "Claude Agent Needs Your Permission"
            case "input needed":      return "Claude Agent Has a Question"
            case "sandbox request":   return "Claude Agent Wants Network Access"
            case "worker request":    return "Claude Agent Needs Your Approval"
            case "goal proposal":     return "Claude Agent Proposed a Goal"
            default:                  return "Claude Agent Needs Your Input"
            }
        }
    }

    static func subtitle(for notice: SessionNotice) -> String {
        let project = notice.session.projectName
        guard let name = notice.session.descriptiveName else { return project }
        return "\(project) · \(name)"
    }

    static func body(for notice: SessionNotice) -> String {
        switch notice.kind {
        case .finished(let workedFor):
            return "Worked \(DurationFormat.hm(workedFor))"
        case .needsInput(let reason):
            switch reason {
            case "permission prompt", "sandbox request", "worker request": return "Waiting for your approval"
            case "input needed":                                          return "Waiting for your answer"
            case "goal proposal":                                         return "Waiting for your review"
            default:                                                      return "Waiting for you"
            }
        }
    }
}
