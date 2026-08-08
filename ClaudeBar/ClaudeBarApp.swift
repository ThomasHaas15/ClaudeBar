import SwiftUI

@main
struct ClaudeBarApp: App {
    @State private var stats = StatsStore()
    @State private var sessions = SessionsStore()
    @State private var rateLimits: RateLimitsStore
    @State private var notifications: NotificationCoordinator

    init() {
        ClaudeFileWatcher.shared.start()
        let limits = RateLimitsStore()
        _rateLimits = State(initialValue: limits)
        _notifications = State(initialValue: NotificationCoordinator(store: limits))
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverRoot()
                .environment(stats)
                .environment(rateLimits)
                .environment(sessions)
        } label: {
            MenuBarLabel()
                .environment(rateLimits)
        }
        .menuBarExtraStyle(.window)
    }
}
