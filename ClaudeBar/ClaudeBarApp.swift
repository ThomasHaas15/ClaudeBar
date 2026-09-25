import SwiftUI

@main
struct ClaudeBarApp: App {
    @State private var stats = StatsStore()
    @State private var sessions: SessionsStore
    @State private var rateLimits: RateLimitsStore
    @State private var notifications: NotificationCoordinator
    @State private var agentNotifier: AgentNotifier

    init() {
        ClaudeFileWatcher.shared.start()
        Updater.shared.start()
        let limits = RateLimitsStore()
        let sessions = SessionsStore()
        _rateLimits = State(initialValue: limits)
        _sessions = State(initialValue: sessions)
        _notifications = State(initialValue: NotificationCoordinator(store: limits))
        _agentNotifier = State(initialValue: AgentNotifier(sessions: sessions))
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverRoot()
                .environment(stats)
                .environment(rateLimits)
                .environment(sessions)
                .environment(agentNotifier)
        } label: {
            MenuBarLabel()
                .environment(rateLimits)
                .environment(agentNotifier)
        }
        .menuBarExtraStyle(.window)
    }
}
