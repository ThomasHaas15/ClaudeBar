import Foundation

enum StreakCalculator {
    static func current(from days: [String], today: Date = Date()) -> Int {
        let set = Set(days)
        var streak = 0
        var cursor = today
        let cal = Calendar(identifier: .gregorian)
        let f = DateFormatter()
        f.calendar = cal
        f.dateFormat = "yyyy-MM-dd"
        while set.contains(f.string(from: cursor)) {
            streak += 1
            guard let prev = cal.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = prev
        }
        if streak == 0 {
            guard let yesterday = cal.date(byAdding: .day, value: -1, to: today) else { return 0 }
            cursor = yesterday
            while set.contains(f.string(from: cursor)) {
                streak += 1
                guard let prev = cal.date(byAdding: .day, value: -1, to: cursor) else { break }
                cursor = prev
            }
        }
        return streak
    }

    static func longest(from days: [String]) -> Int {
        guard !days.isEmpty else { return 0 }
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"
        let dates = days.compactMap(f.date(from:)).sorted()
        var longest = 1
        var run = 1
        let cal = Calendar(identifier: .gregorian)
        for i in 1..<dates.count {
            if let next = cal.date(byAdding: .day, value: 1, to: dates[i - 1]),
               cal.isDate(next, inSameDayAs: dates[i]) {
                run += 1
            } else {
                run = 1
            }
            longest = max(longest, run)
        }
        return longest
    }
}
