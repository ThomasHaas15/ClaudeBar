import SwiftUI

struct UsageTab: View {
    @Environment(RateLimitsStore.self) private var rateLimits

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
            SectionHeader(title: "Rate Limits")
            if let limits = rateLimits.limits, limits.hasAny {
                limitRows(limits)
            } else {
                emptyState
            }
        }
    }

    @ViewBuilder
    private func limitRows(_ limits: RateLimits) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if let l = limits.fiveHour {
                LimitRow(title: "Session", limit: l)
            }
            if let l = limits.sevenDay {
                LimitRow(title: "Week (all models)", limit: l)
            }
            if let l = limits.sevenDaySonnet {
                LimitRow(title: "Week (Sonnet only)", limit: l)
            }
            if let l = limits.sevenDayOpus, limits.sevenDaySonnet == nil {
                LimitRow(title: "Week (Opus only)", limit: l)
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No rate-limit data yet")
                .font(.callout)
            Text("Run a prompt in Claude Code with the ClaudeBar statusline installed to populate this view.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.cardCornerRadius)
                .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
        )
    }
}

private struct LimitRow: View {
    let title: String
    let limit: RateLimits.Limit

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.body)
                Spacer()
                Text("\(limit.percent)%")
                    .font(.body.weight(.semibold))
                    .monoDigits()
            }
            ProgressBar(ratio: limit.ratio, color: .forUtilization(limit.ratio))
            Text(LimitCaption.text(resetsAt: limit.resetsAt))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// The line under a limit's bar. Split out of the view so it can be tested.
enum LimitCaption {
    static func text(resetsAt: Date, now: Date = Date()) -> String {
        // A window whose reset has already passed has been rolled over to
        // empty, so there is nothing left in it to reset — and the window that
        // replaces it only begins when Claude Code makes a request, so its
        // reset time is unknowable until then. "Resets …" under a 0 % bar
        // reads as if something were still pending; name what actually
        // happens next instead.
        guard resetsAt > now else { return "Starts on next request" }
        let cal = Calendar.current
        let daysAway = cal.dateComponents(
            [.day],
            from: cal.startOfDay(for: now),
            to: cal.startOfDay(for: resetsAt)
        ).day ?? 0
        // Today or tomorrow: the date carries no information the clock doesn't,
        // but the time zone does, since the boundary is a UTC instant.
        if daysAway <= 1 {
            return "Resets \(DurationFormat.resetClock(resetsAt)) · \(TimeZone.current.identifier)"
        }
        return "Resets \(DurationFormat.resetDateTime(resetsAt))"
    }
}
