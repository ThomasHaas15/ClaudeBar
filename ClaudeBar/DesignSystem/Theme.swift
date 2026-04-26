import SwiftUI

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

    static func forUtilization(_ ratio: Double) -> Color {
        if ratio >= Theme.Limit.critical { return .limitRed }
        if ratio >= Theme.Limit.warn { return .limitYellow }
        return .limitBlue
    }
}
