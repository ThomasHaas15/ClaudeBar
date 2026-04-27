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
                LimitRow(title: "Session", limit: l, resetPrefix: "Resets")
            }
            if let l = limits.sevenDay {
                LimitRow(title: "Week (all models)", limit: l, resetPrefix: "Resets")
            }
            if let l = limits.sevenDaySonnet {
                LimitRow(title: "Week (Sonnet only)", limit: l, resetPrefix: "Resets")
            }
            if let l = limits.sevenDayOpus, limits.sevenDaySonnet == nil {
                LimitRow(title: "Week (Opus only)", limit: l, resetPrefix: "Resets")
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
    let resetPrefix: String

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
            Text("\(resetPrefix) \(resetText)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var resetText: String {
        guard limit.resetsAt > Date() else {
            return "after next request"
        }
        let cal = Calendar.current
        if cal.isDateInToday(limit.resetsAt) || cal.isDateInTomorrow(limit.resetsAt) {
            let tz = TimeZone.current.identifier
            return "\(DurationFormat.resetClock(limit.resetsAt)) · \(tz)"
        }
        return DurationFormat.resetDateTime(limit.resetsAt)
    }
}
