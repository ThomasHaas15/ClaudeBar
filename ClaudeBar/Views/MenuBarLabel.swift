import SwiftUI

struct MenuBarLabel: View {
    @Environment(RateLimitsStore.self) private var rateLimits

    var body: some View {
        HStack(spacing: 4) {
            Image(nsImage: ClaudeMark.templateImage)
            if let dotColor {
                Circle()
                    .fill(dotColor)
                    .frame(width: 6, height: 6)
            }
        }
    }

    private var dotColor: Color? {
        guard let limits = rateLimits.limits, limits.hasAny else { return nil }
        let r = limits.maxRatio
        if r >= Theme.Limit.critical { return .red }
        if r >= Theme.Limit.warn     { return .yellow }
        return nil
    }
}
