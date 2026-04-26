import SwiftUI

struct HeatmapGrid: View {
    let dailyActivity: [StatsCache.DailyActivity]
    var days: Int = 30

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
                        let value = grid.values[row][col]
                        RoundedRectangle(cornerRadius: 2)
                            .fill(color(for: value, max: grid.maxValue))
                            .frame(width: Self.cellSize, height: Self.cellSize)
                    }
                }
            }
        }
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

    private func monthDay(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f.string(from: date)
    }

    private struct Grid {
        var values: [[Int]]
        var columns: Int
        var maxValue: Int
        var firstDate: Date?
        var lastDate: Date?
    }

    private func buildGrid() -> Grid {
        let cal = Calendar(identifier: .gregorian)
        let f = DateFormatter()
        f.calendar = cal
        f.dateFormat = "yyyy-MM-dd"
        let lookup = Dictionary(uniqueKeysWithValues: dailyActivity.map { ($0.date, $0.messageCount) })

        let today = cal.startOfDay(for: Date())
        let start = cal.date(byAdding: .day, value: -(days - 1), to: today) ?? today

        var todayWeekday = cal.component(.weekday, from: today)
        var startWeekday = cal.component(.weekday, from: start)
        todayWeekday = (todayWeekday + 5) % 7
        startWeekday = (startWeekday + 5) % 7

        let leadingPad = startWeekday
        let totalCells = leadingPad + days
        let columns = Int(ceil(Double(totalCells) / 7.0))

        var values: [[Int]] = Array(repeating: Array(repeating: -1, count: columns), count: 7)
        var maxValue = 0

        for i in 0..<days {
            guard let d = cal.date(byAdding: .day, value: i, to: start) else { continue }
            let key = f.string(from: d)
            let count = lookup[key] ?? 0
            let cellIndex = leadingPad + i
            let row = cellIndex % 7
            let col = cellIndex / 7
            values[row][col] = count
            maxValue = max(maxValue, count)
        }
        for row in 0..<7 {
            for col in 0..<columns {
                if values[row][col] == -1 { values[row][col] = 0 }
            }
        }
        return Grid(values: values, columns: columns, maxValue: maxValue, firstDate: start, lastDate: today)
    }
}
