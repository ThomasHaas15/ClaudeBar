import Foundation
import UserNotifications

@MainActor
@Observable
final class NotificationCoordinator {
    @ObservationIgnored private let tracker = ThresholdTracker()
    @ObservationIgnored private let weekly = WeeklyResetTracker()
    @ObservationIgnored private let store: RateLimitsStore
    @ObservationIgnored private var previous: RateLimits?
    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private var authRequested = false

    /// Reads the store rather than the file: the store's value is merged with
    /// the cache and rolled over, so a window that reset while Claude Code was
    /// idle is seen at the reset instead of at the next request.
    init(store: RateLimitsStore) {
        self.store = store
        previous = store.limits
        observer = NotificationCenter.default.addObserver(
            forName: RateLimitsStore.didUpdate,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.evaluate() }
        }
        // Catch a rollover that happened while the app wasn't running — the
        // store publishes before this object exists, so waiting for the next
        // change would miss it.
        evaluate()
    }

    private func requestAuthorizationIfNeeded() {
        guard !authRequested else { return }
        authRequested = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func evaluate() {
        // The store's value is rolled over, so a window that has reset drops
        // the baseline back to 0 %. Comparing raw file values across a reset
        // would suppress the next window's warning: yesterday's 88 % is never
        // crossed again by today's.
        let current = store.limits
        let crossings = tracker.crossings(previous: previous, current: current)
        let resets = weekly.resets(in: current)
        previous = current
        for event in crossings { fire(event) }
        for reset in resets { fire(reset) }
    }

    private func fire(_ event: ThresholdEvent) {
        requestAuthorizationIfNeeded()
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

    private func fire(_ reset: WeeklyReset) {
        requestAuthorizationIfNeeded()
        let content = UNMutableNotificationContent()
        content.title = "\(reset.kind.label) limit reset"
        content.body = "Was \(reset.previousPercent)% · next reset \(DurationFormat.resetDateTime(reset.resetsAt))"
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "claudebar.\(reset.kind.rawValue).reset.\(Int(reset.resetsAt.timeIntervalSince1970))",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
}
