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
        case 0..<1_000:           return "\(tokens)"
        case 1_000..<1_000_000:   return String(format: "%.0fk", n / 1_000)
        case 1_000_000..<10_000_000:  return String(format: "%.1fM", n / 1_000_000)
        default:                  return String(format: "%.0fM", n / 1_000_000)
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
