import SwiftUI
import AppKit

struct PopoverRoot: View {
    @Environment(StatsStore.self) private var stats
    @Environment(RateLimitsStore.self) private var rateLimits
    @Environment(SessionsStore.self) private var sessions

    @State private var tab: PopoverTab = .usage

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
            PopoverHeader(
                todayTokens: stats.merged.todayTokens,
                streakDays: StreakCalculator.current(from: stats.merged.allActiveDates)
            )
            TabBar(selection: $tab)
            tabContent
                .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            FooterRow()
        }
        .padding(Theme.outerPadding)
        .frame(width: Theme.popoverWidth)
        .onAppear {
            stats.reload()
            rateLimits.reload()
            sessions.reload()
            StatuslineInstaller.shared.refresh()
            LoginItem.shared.refresh()
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch tab {
        case .usage:  UsageTab()
        case .stats:  StatsTab()
        case .models: ModelsTab()
        case .status: StatusTab()
        }
    }
}

private struct FooterRow: View {
    var body: some View {
        HStack {
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
                .keyboardShortcut("q")
                .pointingHandCursor()
        }
    }
}
