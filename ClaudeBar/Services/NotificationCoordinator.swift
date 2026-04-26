import Foundation
import UserNotifications

@Observable
final class NotificationCoordinator {
    @ObservationIgnored private let tracker = ThresholdTracker()
    @ObservationIgnored private var previous: RateLimits?
    @ObservationIgnored private var observer: NSObjectProtocol?

    init() {
        requestAuthorization()
        previous = RateLimits.load()
        observer = NotificationCenter.default.addObserver(
            forName: ClaudeFileWatcher.rateLimitsChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.evaluate() }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    private func requestAuthorization() {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func evaluate() {
        let current = RateLimits.load()
        let events = tracker.crossings(previous: previous, current: current)
        previous = current
        for event in events { fire(event) }
    }

    private func fire(_ event: ThresholdEvent) {
        let content = UNMutableNotificationContent()
        switch event.level {
        case .critical:
            content.title = "\(event.kind.label) limit reached"
            content.body = "100% used · resets \(DurationFormat.resetClock(event.resetsAt))"
        case .warn:
            content.title = "\(event.kind.label) limit at \(event.percent)%"
            content.body = "Resets \(DurationFormat.resetClock(event.resetsAt))"
        }
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "claudebar.\(event.kind.rawValue).\(event.level.rawValue).\(Int(event.resetsAt.timeIntervalSince1970))",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
}
