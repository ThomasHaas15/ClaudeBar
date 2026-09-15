import SwiftUI

/// A contribution graph: a row per weekday, a column per week, months named
/// across the top.
///
/// The span is chosen by the width rather than the other way round. Seven rows
/// is the height whatever the window covers, so lengthening the history costs
/// nothing but columns — and the popover is a fixed 360pt, so there is an exact
/// number of columns that fills it and no reason to draw fewer. `fittedWeeks`
/// works that number out, which is around twenty: some four and a half months
/// of weekday rhythm, where thirty days was five columns and most of the width
/// going spare.
struct HeatmapGrid: View {
    let dailyActivity: [StatsCache.DailyActivity]
    let dailyTokens: [String: Int]
    var weeks: Int = HeatmapGrid.fittedWeeks

    /// The hovered day, held as its `yyyy-MM-dd` key rather than as the day
    /// itself: the grid is rebuilt on every refresh, and a stored copy would go
    /// on showing the counts the day had when the pointer arrived.
    @State private var hovered: String?

    private static let cellSize: CGFloat = 12
    private static let cellSpacing: CGFloat = 3
    private static let headerHeight: CGFloat = 12
    private static let weekdayLabelWidth: CGFloat = 26
    /// Between the weekday labels and the first column.
    private static let labelGap: CGFloat = 8

    /// How many week columns fit across the popover. Derived rather than
    /// written down, so that a change to the popover's width or padding moves
    /// the history with it instead of overflowing it.
    static var fittedWeeks: Int {
        let available = Theme.popoverWidth
            - 2 * Theme.outerPadding
            - weekdayLabelWidth
            - labelGap
        return Int((available + cellSpacing) / (cellSize + cellSpacing))
    }

    /// The span the grid covers: whole Monday-first weeks, ending with the one
    /// in progress. The Stats tab labels the same window, so it is worked out
    /// here once.
    static func window(weeks: Int = fittedWeeks, endingOn today: Date) -> (start: Date, days: Int) {
        let cal = Calendar(identifier: .gregorian)
        let today = cal.startOfDay(for: today)
        let weekday = (cal.component(.weekday, from: today) + 5) % 7
        let monday = cal.date(byAdding: .day, value: -weekday, to: today) ?? today
        let start = cal.date(byAdding: .day, value: -7 * (weeks - 1), to: monday) ?? monday
        let days = (cal.dateComponents([.day], from: start, to: today).day ?? 0) + 1
        return (start, days)
    }

    var body: some View {
        let grid = buildGrid()
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: Self.labelGap) {
                weekdayLabels
                VStack(alignment: .leading, spacing: 4) {
                    monthHeader(grid: grid)
                    cells(grid: grid)
                }
            }
            readout(grid: grid)
        }
    }

    /// Every other row, the way every contribution graph does it: at this cell
    /// size seven stacked labels do not fit, and three are enough to orient by.
    private var weekdayLabels: some View {
        VStack(alignment: .trailing, spacing: Self.cellSpacing) {
            ForEach(0..<7, id: \.self) { weekday in
                Text(weekdayLabel(weekday))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(width: Self.weekdayLabelWidth, height: Self.cellSize, alignment: .trailing)
            }
        }
        // Clears the month header, so a label lines up with its own row.
        .padding(.top, Self.headerHeight + 4)
    }

    /// A month's name sits over the first column that month reaches. Each slot
    /// is one cell wide and the text is allowed to overrun it — laying the
    /// names out on the column grid is what keeps a name above its own weeks,
    /// and a name is always wider than the column it starts in.
    private func monthHeader(grid: Grid) -> some View {
        HStack(spacing: Self.cellSpacing) {
            ForEach(0..<grid.columns, id: \.self) { column in
                Text(grid.monthLabel(column).map(monthName) ?? "")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .frame(width: Self.cellSize, height: Self.headerHeight, alignment: .leading)
            }
        }
    }

    private func cells(grid: Grid) -> some View {
        VStack(alignment: .leading, spacing: Self.cellSpacing) {
            ForEach(0..<7, id: \.self) { weekday in
                HStack(spacing: Self.cellSpacing) {
                    ForEach(0..<grid.columns, id: \.self) { column in
                        cell(grid.cells[weekday][column], max: grid.maxValue)
                    }
                }
            }
        }
    }

    /// A nil day is a cell past today — the rest of the week in progress. It
    /// looks like an idle day but answers no hover.
    @ViewBuilder
    private func cell(_ day: Day?, max scale: Int) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(color(for: day?.messages ?? 0, max: scale))
            .overlay {
                if let day, hovered == day.key {
                    RoundedRectangle(cornerRadius: 2)
                        .strokeBorder(Color.primary.opacity(0.65), lineWidth: 1)
                }
            }
            .frame(width: Self.cellSize, height: Self.cellSize)
            .onHover { inside in
                guard let day else { return }
                // Leaving only clears the selection if nothing else has claimed
                // it: entering the next cell can land before this one's exit.
                if inside { hovered = day.key }
                else if hovered == day.key { hovered = nil }
            }
    }

    /// The line under the grid: whichever day the pointer is on, and the colour
    /// scale when it is on none. Fixed height so the popover does not resize as
    /// the pointer crosses the grid.
    private func readout(grid: Grid) -> some View {
        HStack(spacing: 0) {
            if let day = grid.day(for: hovered) {
                Text(summary(for: day))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                legend
            }
        }
        .frame(height: 12, alignment: .leading)
    }

    private var legend: some View {
        HStack(spacing: Self.cellSpacing) {
            Text("Less")
                .font(.caption2)
                .foregroundStyle(.secondary)
            // Counts chosen to land one in each bucket `color(for:max:)` draws,
            // so the swatches cannot drift from the grid they explain.
            ForEach([0, 1, 3, 6, 9], id: \.self) { count in
                RoundedRectangle(cornerRadius: 2)
                    .fill(color(for: count, max: 10))
                    .frame(width: 9, height: 9)
            }
            Text("More")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func summary(for day: Day) -> String {
        let date = monthDay(day.date, weekday: true)
        guard day.messages > 0 || (day.tokens ?? 0) > 0 else { return "\(date) · no activity" }
        var parts = [date]
        // Nothing recorded is not the same as nothing spent: no token figure
        // survives for a day whose transcripts were pruned before ClaudeBar
        // first saw them.
        parts.append(day.tokens.map { "\(TokenFormat.compact($0)) tokens" } ?? "tokens not recorded")
        parts.append("\(day.messages) message\(day.messages == 1 ? "" : "s")")
        return parts.joined(separator: " · ")
    }

    private func color(for value: Int, max: Int) -> Color {
        guard value > 0, max > 0 else { return Color.secondary.opacity(0.12) }
        let ratio = Double(value) / Double(max)
        let bucket = min(4, Int(ratio * 4) + 1)
        let opacities: [Double] = [0.18, 0.35, 0.55, 0.75, 1.0]
        return Color.blue.opacity(opacities[bucket])
    }

    private func weekdayLabel(_ weekday: Int) -> String {
        switch weekday {
        case 0: return "Mon"
        case 2: return "Wed"
        case 4: return "Fri"
        default: return ""
        }
    }

    private func monthName(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM"
        return f.string(from: date)
    }

    private func monthDay(_ date: Date, weekday: Bool = false) -> String {
        let f = DateFormatter()
        f.dateFormat = weekday ? "EEE MMM d" : "MMM d"
        return f.string(from: date)
    }

    private struct Day: Equatable {
        let key: String
        let date: Date
        let messages: Int
        /// Nil when no token figure exists for the day at all, which reads
        /// differently from zero — see `MergedStats.dailyTokens`.
        let tokens: Int?
    }

    private struct Grid {
        /// Indexed `[weekday][week]`, Monday first.
        var cells: [[Day?]]
        var columns: Int
        var maxValue: Int

        func day(for key: String?) -> Day? {
            guard let key else { return nil }
            return cells.lazy.flatMap { $0 }.first { $0?.key == key } ?? nil
        }

        /// The date to name this column by, or nil when its month was already
        /// named by a column to its left.
        func monthLabel(_ column: Int) -> Date? {
            guard let first = firstDay(inColumn: column) else { return nil }
            guard column > 0 else { return first }
            guard let previous = firstDay(inColumn: column - 1) else { return first }
            let cal = Calendar(identifier: .gregorian)
            return cal.isDate(first, equalTo: previous, toGranularity: .month) ? nil : first
        }

        private func firstDay(inColumn column: Int) -> Date? {
            (0..<7).lazy.compactMap { cells[$0][column]?.date }.first
        }
    }

    private func buildGrid() -> Grid {
        let cal = Calendar(identifier: .gregorian)
        let f = DateFormatter()
        f.calendar = cal
        f.dateFormat = "yyyy-MM-dd"
        let lookup = Dictionary(uniqueKeysWithValues: dailyActivity.map { ($0.date, $0.messageCount) })

        // The window starts on a Monday, so there is no leading padding to
        // account for: day *i* is simply the *i*th cell. Only the last column
        // is part-empty, for the rest of the week that has not happened.
        let (start, days) = Self.window(weeks: weeks, endingOn: Date())

        var cells: [[Day?]] = Array(repeating: Array(repeating: nil, count: weeks), count: 7)
        var maxValue = 0

        for i in 0..<days {
            guard let date = cal.date(byAdding: .day, value: i, to: start) else { continue }
            let key = f.string(from: date)
            let count = lookup[key] ?? 0
            cells[i % 7][i / 7] = Day(
                key: key,
                date: date,
                messages: count,
                tokens: dailyTokens[key]
            )
            maxValue = max(maxValue, count)
        }
        return Grid(cells: cells, columns: weeks, maxValue: maxValue)
    }
}
