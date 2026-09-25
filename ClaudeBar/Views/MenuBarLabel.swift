import AppKit
import SwiftUI

struct MenuBarLabel: View {
    @Environment(RateLimitsStore.self) private var rateLimits
    @Environment(AgentNotifier.self) private var agentNotifier

    var body: some View {
        Image(nsImage: MenuBarIcon.image(needingInput: agentNotifier.needingInputCount, limitDot: dotColor))
    }

    private var dotColor: NSColor? {
        guard let limits = rateLimits.limits, limits.hasAny else { return nil }
        let r = limits.maxRatio
        if r >= Theme.Limit.critical { return .systemRed }
        if r >= Theme.Limit.warn     { return .systemYellow }
        return nil
    }
}

/// The status item shows one image, not a SwiftUI view: `MenuBarExtra` copies
/// the label's first `Image` onto its button, and a `Text` into its title, and
/// drops everything else, colored shapes included. Anything colored therefore
/// has to be drawn into that one image, which then can't be a template.
@MainActor
private enum MenuBarIcon {
    static func image(needingInput count: Int, limitDot: NSColor?) -> NSImage {
        guard count > 0 || limitDot != nil else { return ClaudeMark.templateImage }

        let mark = ClaudeMark.image(size: 16)
        let spacing: CGFloat = 4
        let badgeHeight: CGFloat = 14
        let badgeText = count > 9 ? "9+" : "\(count)"
        let badgeWidth = badgeText.count > 1 ? badgeHeight + 6 : badgeHeight
        let dotSize: CGFloat = 6
        var width = mark.size.width
        if count > 0 { width += spacing + badgeWidth }
        if limitDot != nil { width += spacing + dotSize }

        // AppKit may call the handler on any thread it draws on, so it
        // captures plain values only.
        let image = NSImage(size: NSSize(width: width, height: mark.size.height), flipped: false) { rect in
            // The mark in the ink a template would get. The handler runs at
            // draw time, so labelColor resolves against the menu bar's
            // appearance, light or dark.
            let markRect = NSRect(origin: .zero, size: mark.size)
            mark.draw(in: markRect)
            NSColor.labelColor.set()
            markRect.fill(using: .sourceAtop)

            var x = markRect.maxX
            if count > 0 {
                x += spacing
                let badgeRect = NSRect(x: x, y: (rect.height - badgeHeight) / 2, width: badgeWidth, height: badgeHeight)
                NSColor.systemOrange.setFill()
                NSBezierPath(roundedRect: badgeRect, xRadius: badgeHeight / 2, yRadius: badgeHeight / 2).fill()
                let label = NSAttributedString(
                    string: badgeText,
                    attributes: [
                        .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .bold),
                        .foregroundColor: NSColor.white
                    ]
                )
                let size = label.size()
                label.draw(at: NSPoint(x: badgeRect.midX - size.width / 2, y: badgeRect.midY - size.height / 2))
                x += badgeWidth
            }
            if let limitDot {
                x += spacing
                limitDot.setFill()
                NSBezierPath(ovalIn: NSRect(x: x, y: (rect.height - dotSize) / 2, width: dotSize, height: dotSize)).fill()
            }
            return true
        }
        // Redraw on every display rather than keep a bitmap, so the mark
        // follows the menu bar when it switches between light and dark.
        image.cacheMode = .never
        image.isTemplate = false
        return image
    }
}
