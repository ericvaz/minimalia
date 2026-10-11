import AppKit

// Draws the Minimalia logo (the stepped block m) as an app icon into an .iconset folder.
// Usage: swift make_icon.swift <out.iconset> [os|word]
let out = CommandLine.arguments[1]
let variant = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "os"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

// The logo, measured from the artwork: x, y (from the top), width, height, in a 605 x 468 box.
let logo: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
    (58, 0, 220, 105),     // roof
    (278, 60, 54, 45),     // step
    (0, 104, 605, 66),     // bar
    (0, 170, 124, 298),    // left leg
    (242, 170, 122, 298),  // middle leg
    (481, 170, 124, 298),  // right leg
]

func draw(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px) / 1024
    let rect = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let shape = NSBezierPath(roundedRect: rect, xRadius: 185 * s, yRadius: 185 * s)

    let ink: NSColor
    if variant == "word" {
        NSColor(srgbRed: 0.97, green: 0.965, blue: 0.95, alpha: 1).setFill()
        shape.fill()
        NSColor(white: 0, alpha: 0.12).setStroke()
        shape.lineWidth = max(1, 6 * s)
        shape.stroke()
        ink = NSColor(srgbRed: 0.09, green: 0.16, blue: 0.42, alpha: 1)
    } else {
        NSColor(srgbRed: 0.035, green: 0.035, blue: 0.04, alpha: 1).setFill()
        shape.fill()
        NSColor(white: 1, alpha: 0.10).setStroke()
        shape.lineWidth = max(1, 6 * s)
        shape.stroke()
        ink = NSColor(white: 0.97, alpha: 1)
    }

    let scale = 0.62 * rect.width / 605
    let w = 605 * scale
    let h = 468 * scale
    let ox = rect.midX - w / 2
    let oy = rect.midY - h / 2 - 8 * s
    ink.setFill()
    let mark = NSBezierPath()
    mark.windingRule = .nonZero
    for (x, y, rw, rh) in logo {
        // Flip y: the artwork is measured from the top. A hair of overlap avoids seams.
        mark.appendRect(NSRect(x: ox + x * scale - 0.5, y: oy + (468 - y - rh) * scale - 0.5,
                               width: rw * scale + 1, height: rh * scale + 1))
    }
    mark.fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                   ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! draw(px).write(to: URL(fileURLWithPath: "\(out)/icon_\(name).png"))
}
