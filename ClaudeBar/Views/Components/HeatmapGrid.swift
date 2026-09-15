import SwiftUI

struct HeatmapGrid: View {
    let dailyActivity: [StatsCache.DailyActivity]
    let dailyTokens: [String: Int]
    var days: Int = 30

    /// The hovered day, held as its `yyyy-MM-dd` key rather than as the day
    /// itself: the grid is rebuilt on every refresh, and a stored copy would go
    /// on showing the counts the day had when the pointer arrived.
    @State private var hovered: String?

    private static let cellSize: CGFloat = 13
    private static let cellSpacing: CGFloat = 3

    var body: some View {
        let grid = buildGrid()
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                rowLabels
                VStack(alignment: .leading, spacing: 4) {
                    monthLabels(grid: grid)
                    cells(grid: grid)
                }
            }
            readout(grid: grid)
        }
    }

    private var rowLabels: some View {
        VStack(alignment: .trailing, spacing: Self.cellSpacing) {
            ForEach(0..<7, id: \.self) { i in
                Text(rowLabel(weekday: i))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(width: 26, height: Self.cellSize, alignment: .trailing)
            }
        }
        .padding(.top, 14)
    }

    private func cells(grid: Grid) -> some View {
        VStack(alignment: .leading, spacing: Self.cellSpacing) {
            ForEach(0..<7, id: \.self) { row in
                HStack(spacing: Self.cellSpacing) {
                    ForEach(0..<grid.columns, id: \.self) { col in
                        cell(grid.cells[row][col], max: grid.maxValue)
                    }
                }
            }
        }
    }

    /// A nil day is a cell outside the window — the padding either side of a
    /// 30-day span that does not start on a Monday. It looks like an idle day
    /// but answers no hover.
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
        // Nothing recorded is not the same as nothing spent: the stats cache
        // carries no daily token counts for days older than its last rebuild.
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

    private func rowLabel(weekday: Int) -> String {
        switch weekday {
        case 0: return "Mon"
        case 2: return "Wed"
        case 4: return "Fri"
        default: return ""
        }
    }

    private func monthDay(_ date: Date, weekday: Bool = false) -> String {
        let f = DateFormatter()
        f.dateFormat = weekday ? "EEE MMM d" : "MMM d"
        return f.string(from: date)
    }

    private func monthLabels(grid: Grid) -> some View {
        HStack(spacing: 0) {
            if let first = grid.firstDate, let last = grid.lastDate {
                Text(monthDay(first))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("—")
                    .font(.caption2)
                    .foregroundStyle(.secondary.opacity(0.5))
                Spacer()
                Text(monthDay(last))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(height: 12)
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
        var cells: [[Day?]]
        var columns: Int
        var maxValue: Int
        var firstDate: Date?
        var lastDate: Date?

        func day(for key: String?) -> Day? {
            guard let key else { return nil }
            return cells.lazy.flatMap { $0 }.first { $0?.key == key } ?? nil
        }
    }

    private func buildGrid() -> Grid {
        let cal = Calendar(identifier: .gregorian)
        let f = DateFormatter()
        f.calendar = cal
        f.dateFormat = "yyyy-MM-dd"
        let lookup = Dictionary(uniqueKeysWithValues: dailyActivity.map { ($0.date, $0.messageCount) })

        let today = cal.startOfDay(for: Date())
        let start = cal.date(byAdding: .day, value: -(days - 1), to: today) ?? today

        var startWeekday = cal.component(.weekday, from: start)
        startWeekday = (startWeekday + 5) % 7

        let leadingPad = startWeekday
        let totalCells = leadingPad + days
        let columns = Int(ceil(Double(totalCells) / 7.0))

        var cells: [[Day?]] = Array(repeating: Array(repeating: nil, count: columns), count: 7)
        var maxValue = 0

        for i in 0..<days {
            guard let date = cal.date(byAdding: .day, value: i, to: start) else { continue }
            let key = f.string(from: date)
            let count = lookup[key] ?? 0
            let cellIndex = leadingPad + i
            cells[cellIndex % 7][cellIndex / 7] = Day(
                key: key,
                date: date,
                messages: count,
                tokens: dailyTokens[key]
            )
            maxValue = max(maxValue, count)
        }
        return Grid(cells: cells, columns: columns, maxValue: maxValue, firstDate: start, lastDate: today)
    }
}
