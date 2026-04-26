import AppKit

enum ClaudeMark {
    static func image(size: CGFloat = 16) -> NSImage {
        let img = (NSImage(named: "ClaudeMark")?.copy() as? NSImage)
            ?? NSImage(size: NSSize(width: size, height: size))
        img.size = NSSize(width: size, height: size)
        img.isTemplate = true
        return img
    }

    static let templateImage: NSImage = image(size: 16)
}
