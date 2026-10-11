import AppKit

/// Draws the Minimalia mark (the stepped m) as a single character, so it can stand in for C:\\> as the prompt.
final class LogoGlyphCell: NSTextAttachmentCell {
    // The logo, measured from the artwork, in a 605 x 468 box (y from the top).
    static let rects: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
        (58, 0, 220, 105), (278, 60, 54, 45), (0, 104, 605, 66),
        (0, 170, 124, 298), (242, 170, 122, 298), (481, 170, 124, 298),
    ]

    private var textFont: NSFont { Settings.shared.font }

    override func cellSize() -> NSSize {
        let h = ceil(textFont.capHeight * 1.08)
        return NSSize(width: ceil(h * 605 / 468) + 2, height: h)
    }

    override func cellBaselineOffset() -> NSPoint { .zero }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        let size = cellSize()
        let scale = (size.width - 2) / 605
        let flipped = controlView?.isFlipped ?? true
        Settings.shared.theme.bright.setFill()
        let path = NSBezierPath()
        for (x, y, w, h) in Self.rects {
            let top = flipped ? cellFrame.minY + y * scale : cellFrame.maxY - (y + h) * scale
            path.appendRect(NSRect(x: cellFrame.minX + 1 + x * scale - 0.25, y: top - 0.25, width: w * scale + 0.5, height: h * scale + 0.5))
        }
        path.fill()
    }

    static func string(attributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let attachment = NSTextAttachment()
        let cell = LogoGlyphCell()
        cell.setAccessibilityLabel("Minimalia prompt")
        attachment.attachmentCell = cell
        let s = NSMutableAttributedString(attachment: attachment)
        s.addAttributes(attributes, range: NSRange(location: 0, length: s.length))
        return s
    }
}
