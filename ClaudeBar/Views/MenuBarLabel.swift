import AppKit
import SwiftUI

struct MenuBarLabel: View {
    @Environment(RateLimitsStore.self) private var rateLimits

    var body: some View {
        Image(nsImage: MenuBarIcon.image(limitDot: dotColor))
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
    static func image(limitDot: NSColor?) -> NSImage {
        guard let limitDot else { return ClaudeMark.templateImage }

        let mark = ClaudeMark.image(size: 16)
        let spacing: CGFloat = 4
        let dotSize: CGFloat = 6

        // AppKit may call the handler on any thread it draws on, so it
        // captures plain values only.
        let size = NSSize(width: mark.size.width + spacing + dotSize, height: mark.size.height)
        let image = NSImage(size: size, flipped: false) { rect in
            // The mark in the ink a template would get. The handler runs at
            // draw time, so labelColor resolves against the menu bar's
            // appearance, light or dark.
            let markRect = NSRect(origin: .zero, size: mark.size)
            mark.draw(in: markRect)
            NSColor.labelColor.set()
            markRect.fill(using: .sourceAtop)

            limitDot.setFill()
            let dotRect = NSRect(x: markRect.maxX + spacing, y: (rect.height - dotSize) / 2, width: dotSize, height: dotSize)
            NSBezierPath(ovalIn: dotRect).fill()
            return true
        }
        // Redraw on every display rather than keep a bitmap, so the mark
        // follows the menu bar when it switches between light and dark.
        image.cacheMode = .never
        image.isTemplate = false
        return image
    }
}
