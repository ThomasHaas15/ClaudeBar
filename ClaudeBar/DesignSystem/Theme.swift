import SwiftUI
import AppKit

enum Theme {
    static let popoverWidth: CGFloat = 360
    static let outerPadding: CGFloat = 14
    static let sectionSpacing: CGFloat = 14
    static let rowSpacing: CGFloat = 8
    static let cardCornerRadius: CGFloat = 10
    static let progressTrackHeight: CGFloat = 4

    enum Limit {
        static let warn: Double = 0.80
        static let critical: Double = 1.00
    }
}

extension Color {
    static let limitBlue = Color.blue
    static let limitYellow = Color.yellow
    static let limitRed = Color.red

    /// Green for more, red for less. The direction a figure moved, not a
    /// judgement about whether moving that way was good.
    ///
    /// Deliberately muted against the system green and red, which are alert
    /// colours: this one is a footnote on a number, a few points tall, sitting
    /// beside secondary grey. Each appearance gets its own value rather than
    /// one colour dialled down with opacity — the popover's background is
    /// translucent, so the same alpha washes out by a different amount over
    /// light and dark.
    static let trendUp = Color(nsColor: .trendAware(
        light: NSColor(srgbRed: 0.29, green: 0.53, blue: 0.38, alpha: 1),
        dark: NSColor(srgbRed: 0.51, green: 0.73, blue: 0.58, alpha: 1)
    ))
    static let trendDown = Color(nsColor: .trendAware(
        light: NSColor(srgbRed: 0.70, green: 0.33, blue: 0.29, alpha: 1),
        dark: NSColor(srgbRed: 0.85, green: 0.55, blue: 0.50, alpha: 1)
    ))

    static func forUtilization(_ ratio: Double) -> Color {
        if ratio >= Theme.Limit.critical { return .limitRed }
        if ratio >= Theme.Limit.warn { return .limitYellow }
        return .limitBlue
    }
}

private extension NSColor {
    /// A colour that resolves itself per appearance, the way the asset catalog
    /// would if these two values were worth a catalog entry each.
    static func trendAware(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }
}
