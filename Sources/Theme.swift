import AppKit

extension Notification.Name {
    static let minimaliaAppearance = Notification.Name("MinimaliaAppearanceChanged")
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: 1)
    }
}

struct Theme {
    let name: String
    let note: String
    let fg: NSColor
    let bg: NSColor
    let bright: NSColor
    let dim: NSColor
    let error: NSColor
    let barFg: NSColor
    let barBg: NSColor
    var isDark: Bool { name != "PAPER" }
}

enum Themes {
    static let all: [Theme] = [
        Theme(name: "CALM", note: "soft charcoal and warm grey, low stimulation (default)",
              fg: NSColor(hex: 0xCFCAC1), bg: NSColor(hex: 0x1D1E20), bright: NSColor(hex: 0xE6E1D8),
              dim: NSColor(hex: 0x8D8A84), error: NSColor(hex: 0xC99A88),
              barFg: NSColor(hex: 0xCFCAC1), barBg: NSColor(hex: 0x2A2B2E)),
        Theme(name: "GREEN", note: "green phosphor monitor",
              fg: NSColor(hex: 0x41FF7A), bg: NSColor(hex: 0x030803), bright: NSColor(hex: 0xC8FFD8),
              dim: NSColor(hex: 0x1E8C45), error: NSColor(hex: 0xFF6B5B),
              barFg: NSColor(hex: 0x030803), barBg: NSColor(hex: 0x41FF7A)),
        Theme(name: "AMBER", note: "amber phosphor monitor",
              fg: NSColor(hex: 0xFFB43C), bg: NSColor(hex: 0x0C0700), bright: NSColor(hex: 0xFFE2A8),
              dim: NSColor(hex: 0x9C6A1A), error: NSColor(hex: 0xFF6B5B),
              barFg: NSColor(hex: 0x0C0700), barBg: NSColor(hex: 0xFFB43C)),
        Theme(name: "WHITE", note: "grey on black, as on 1980s PCs",
              fg: NSColor(hex: 0xC0C0C0), bg: NSColor(hex: 0x000000), bright: NSColor(hex: 0xFFFFFF),
              dim: NSColor(hex: 0x7A7A7A), error: NSColor(hex: 0xFF5555),
              barFg: NSColor(hex: 0x000000), barBg: NSColor(hex: 0xC0C0C0)),
        Theme(name: "BLUE", note: "white on blue, as in 1980s word processors",
              fg: NSColor(hex: 0xE6E6E6), bg: NSColor(hex: 0x0000AA), bright: NSColor(hex: 0xFFFF55),
              dim: NSColor(hex: 0x9A9AEE), error: NSColor(hex: 0xFF8080),
              barFg: NSColor(hex: 0x000000), barBg: NSColor(hex: 0xAAAAAA)),
        Theme(name: "PAPER", note: "soft ink on warm paper, low stimulation, for daylight",
              fg: NSColor(hex: 0x33312E), bg: NSColor(hex: 0xEEEAE1), bright: NSColor(hex: 0x1A1917),
              dim: NSColor(hex: 0x6A665F), error: NSColor(hex: 0x9A4A3A),
              barFg: NSColor(hex: 0x33312E), barBg: NSColor(hex: 0xE0DBD0)),
    ]

    static func named(_ n: String) -> Theme? {
        all.first { $0.name == n.uppercased() }
    }
}

enum Fonts {
    static let all: [(name: String, postscript: String?)] = [
        ("ATKINSON", nil),
        ("MENLO", "Menlo-Regular"),
        ("MONACO", "Monaco"),
        ("COURIER", "CourierNewPSMT"),
        ("ANDALE", "AndaleMono"),
        ("SFMONO", nil),
    ]
}

final class Settings {
    static let shared = Settings()
    private let d = UserDefaults.standard

    var theme: Theme {
        didSet { d.set(theme.name, forKey: "theme"); changed() }
    }
    var fontSize: CGFloat {
        didSet { d.set(Double(fontSize), forKey: "fontSize"); changed() }
    }
    var fontName: String {
        didSet { d.set(fontName, forKey: "fontName"); changed() }
    }
    var bootAnimation: Bool {
        didSet { d.set(bootAnimation, forKey: "bootAnimation") }
    }
    /// The start-up chime.
    var chime: Bool {
        didSet { d.set(chime, forKey: "chime") }
    }
    /// A steady cursor is the calmer default; blinking is optional.
    var cursorBlink: Bool {
        didSet { d.set(cursorBlink, forKey: "cursorBlink"); changed() }
    }
    var fullScreen: Bool {
        didSet { d.set(fullScreen, forKey: "fullScreen") }
    }

    private init() {
        theme = Themes.named(d.string(forKey: "theme") ?? "") ?? Themes.all[0]
        let size = d.double(forKey: "fontSize")
        fontSize = size > 0 ? CGFloat(size) : 16
        fontName = d.string(forKey: "fontName") ?? "ATKINSON"
        bootAnimation = d.object(forKey: "bootAnimation") as? Bool ?? true
        cursorBlink = d.object(forKey: "cursorBlink") as? Bool ?? false
        chime = d.object(forKey: "chime") as? Bool ?? true
        fullScreen = d.object(forKey: "fullScreen") as? Bool ?? true
    }

    var font: NSFont {
        let entry = Fonts.all.first { $0.name == fontName } ?? Fonts.all[0]
        if entry.name == "ATKINSON",
           let f = NSFontManager.shared.font(withFamily: "Atkinson Hyperlegible Mono", traits: [], weight: 5, size: fontSize) {
            return f
        }
        if let ps = entry.postscript, let f = NSFont(name: ps, size: fontSize) { return f }
        return NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
    }

    var paragraphStyle: NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = round(fontSize * 0.22)
        return p
    }

    var lineHeight: CGFloat {
        NSLayoutManager().defaultLineHeight(for: font)
    }

    private func changed() {
        NotificationCenter.default.post(name: .minimaliaAppearance, object: nil)
    }
}

enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL

    static var data: URL { folder(home.appendingPathComponent("Documents/Minimalia")) }
    static var library: URL { folder(data.appendingPathComponent("LIBRARY")) }
    static var writing: URL { folder(data.appendingPathComponent("WRITING")) }
    static var notes: URL { data.appendingPathComponent("NOTES.TXT") }

    private static func folder(_ u: URL) -> URL {
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
}
