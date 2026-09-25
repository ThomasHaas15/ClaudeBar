import SwiftUI
import AppKit

extension View {
    func monoDigits() -> some View {
        self.monospacedDigit()
    }

    func pointingHandCursor() -> some View {
        self.onHover { hovering in
            if hovering { NSCursor.pointingHand.push() }
            else        { NSCursor.pop() }
        }
    }

    func sectionHeaderStyle() -> some View {
        self.font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .tracking(0.6)
    }
}

enum TokenFormat {
    static func compact(_ tokens: Int) -> String {
        let n = Double(tokens)
        switch tokens {
        case ..<1_000:                        return "\(tokens)"
        case 1_000..<1_000_000:               return String(format: "%.0fk", n / 1_000)
        case 1_000_000..<10_000_000:          return String(format: "%.1fM", n / 1_000_000)
        case 10_000_000..<1_000_000_000:      return String(format: "%.0fM", n / 1_000_000)
        // Cache reads reach this range within weeks; "4980M" is not a number
        // anyone reads at a glance.
        case 1_000_000_000..<10_000_000_000:  return String(format: "%.1fB", n / 1_000_000_000)
        default:                              return String(format: "%.0fB", n / 1_000_000_000)
        }
    }
}

enum DurationFormat {
    static func dh(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        if days > 0 { return "\(days)d \(hours)h" }
        let minutes = (total % 3_600) / 60
        return "\(hours)h \(minutes)m"
    }

    /// "1m", "42m", "1h 5m", rounded to the nearest minute and never below 1m.
    static func hm(_ interval: TimeInterval) -> String {
        let minutes = max(1, Int((interval / 60).rounded()))
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }

    static func resetClock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mma"
        formatter.amSymbol = "am"
        formatter.pmSymbol = "pm"
        return formatter.string(from: date).lowercased()
    }

    static func resetDateTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE MMM d · h:mma"
        formatter.amSymbol = "am"
        formatter.pmSymbol = "pm"
        return formatter.string(from: date)
    }
}
