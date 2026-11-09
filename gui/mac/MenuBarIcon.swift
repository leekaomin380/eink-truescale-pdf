import AppKit
import CoreText

/// A lowercase reading mark: serif bowl, open counter and a distinct descender.
/// Draw the font outline at the requested backing scale, never enlarge a bitmap.
enum MenuBarIcon {
    static let image: NSImage = {
        let font = NSFont(name: "Charter-Roman", size: 32)
            ?? NSFont(name: "Georgia", size: 32)
            ?? NSFont.systemFont(ofSize: 32)
        let ctFont = CTFontCreateWithName(font.fontName as CFString, 32, nil)
        var character: UniChar = 0x71 // lowercase q
        var glyph: CGGlyph = 0
        CTFontGetGlyphsForCharacters(ctFont, &character, &glyph, 1)
        guard let path = CTFontCreatePathForGlyph(ctFont, glyph, nil) else {
            return NSImage(systemSymbolName: "text.book.closed", accessibilityDescription: nil)!
        }
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let bounds = path.boundingBoxOfPath
            let scale = min((rect.width - 5) / bounds.width, (rect.height - 3) / bounds.height)
            context.saveGState()
            context.setShouldAntialias(true)
            context.translateBy(x: rect.midX - bounds.midX * scale,
                                y: rect.midY - bounds.midY * scale)
            context.scaleBy(x: scale, y: scale)
            context.setFillColor(NSColor.black.cgColor)
            context.addPath(path)
            context.fillPath()
            context.restoreGState()
            return true
        }
        image.isTemplate = true
        return image
    }()
}
