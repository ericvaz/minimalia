import AppKit

/// Greyscale palette shared by every Minimalia program. Dark unless the PAPER colour scheme is chosen.
struct MonoPalette {
    let desk: NSColor
    let page: NSColor
    let edge: NSColor
    let ink: NSColor
    let dim: NSColor
    let bar: NSColor
    let barInk: NSColor
    let hover: NSColor
    let onBg: NSColor
    let onInk: NSColor
    let selection: NSColor
    let highlight: NSColor
    let isDark: Bool

    static let dark = MonoPalette(
        desk: NSColor(white: 0.0, alpha: 1), page: NSColor(white: 0.06, alpha: 1), edge: NSColor(white: 0.2, alpha: 1),
        ink: NSColor(white: 0.9, alpha: 1), dim: NSColor(white: 0.55, alpha: 1),
        bar: NSColor(white: 0.1, alpha: 1), barInk: NSColor(white: 0.85, alpha: 1), hover: NSColor(white: 0.2, alpha: 1),
        onBg: NSColor(white: 0.88, alpha: 1), onInk: NSColor(white: 0.0, alpha: 1),
        selection: NSColor(white: 0.32, alpha: 1), highlight: NSColor(white: 0.24, alpha: 1), isDark: true)

    static let light = MonoPalette(
        desk: NSColor(white: 0.84, alpha: 1), page: NSColor(white: 1.0, alpha: 1), edge: NSColor(white: 0.72, alpha: 1),
        ink: NSColor(white: 0.07, alpha: 1), dim: NSColor(white: 0.4, alpha: 1),
        bar: NSColor(white: 0.93, alpha: 1), barInk: NSColor(white: 0.08, alpha: 1), hover: NSColor(white: 0.85, alpha: 1),
        onBg: NSColor(white: 0.1, alpha: 1), onInk: NSColor(white: 1.0, alpha: 1),
        selection: NSColor(white: 0.78, alpha: 1), highlight: NSColor(white: 0.86, alpha: 1), isDark: false)

    static let calm = MonoPalette(
        desk: NSColor(hex: 0x1D1E20), page: NSColor(hex: 0x26272A), edge: NSColor(hex: 0x3A3C40),
        ink: NSColor(hex: 0xCFCAC1), dim: NSColor(hex: 0x8D8A84),
        bar: NSColor(hex: 0x232427), barInk: NSColor(hex: 0xCFCAC1), hover: NSColor(hex: 0x313337),
        onBg: NSColor(hex: 0xCFCAC1), onInk: NSColor(hex: 0x1D1E20),
        selection: NSColor(hex: 0x45474C), highlight: NSColor(hex: 0x36383C), isDark: true)

    static let paper = MonoPalette(
        desk: NSColor(hex: 0xE0DBD0), page: NSColor(hex: 0xF4F1EA), edge: NSColor(hex: 0xC9C3B6),
        ink: NSColor(hex: 0x33312E), dim: NSColor(hex: 0x6A665F),
        bar: NSColor(hex: 0xE8E4DA), barInk: NSColor(hex: 0x33312E), hover: NSColor(hex: 0xD8D2C6),
        onBg: NSColor(hex: 0x33312E), onInk: NSColor(hex: 0xF4F1EA),
        selection: NSColor(hex: 0xCFC8BA), highlight: NSColor(hex: 0xDDD7CB), isDark: false)

    static var current: MonoPalette {
        switch Settings.shared.theme.name {
        case "CALM": return calm
        case "PAPER": return paper
        default: return Settings.shared.theme.isDark ? dark : light
        }
    }

    var appearance: NSAppearance? { NSAppearance(named: isDark ? .darkAqua : .aqua) }

    /// Shows any document colour as a grey of matching weight, so dark ink reads on a dark page.
    func grey(for color: NSColor?) -> NSColor {
        let c = (color ?? .black).usingColorSpace(.sRGB) ?? .black
        let lum = 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
        // Dark ink becomes the palette's ink; lighter or coloured ink fades toward the dim tone.
        let t = isDark ? min(1, lum * 1.6) : min(1, (1 - lum) < 0.2 ? 1 : lum * 1.2)
        let a = ink.usingColorSpace(.sRGB) ?? ink
        let b = dim.usingColorSpace(.sRGB) ?? dim
        return NSColor(srgbRed: a.redComponent + (b.redComponent - a.redComponent) * t,
                       green: a.greenComponent + (b.greenComponent - a.greenComponent) * t,
                       blue: a.blueComponent + (b.blueComponent - a.blueComponent) * t, alpha: 1)
    }

    static var uiFont: NSFont { NSFont.systemFont(ofSize: 13) }
}

/// A flat button drawn in greys only: text or an SF Symbol, optional dropdown arrow, on/off state.
final class MonoButton: NSView {
    var title: String { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    var symbol: String?
    var isOn = false { didSet { needsDisplay = true } }
    var isDropdown = false
    var minWidth: CGFloat = 0
    /// Colours for buttons that sit on something other than a bar, such as a book page.
    var inkOverride: NSColor? { didSet { needsDisplay = true } }
    var hoverOverride: NSColor?
    var action: ((MonoButton) -> Void)?
    private var hovering = false { didSet { needsDisplay = true } }
    private var pressed = false { didSet { needsDisplay = true } }

    init(_ title: String, symbol: String? = nil, dropdown: Bool = false, help: String? = nil, action: ((MonoButton) -> Void)? = nil) {
        self.title = title
        self.symbol = symbol
        self.isDropdown = dropdown
        self.action = action
        super.init(frame: .zero)
        toolTip = help
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(help ?? title)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        var w: CGFloat = 16
        if symbol != nil { w += 16 }
        if !title.isEmpty { w += (title as NSString).size(withAttributes: [.font: MonoPalette.uiFont]).width + (symbol != nil ? 4 : 0) }
        if isDropdown { w += 14 }
        return NSSize(width: max(minWidth, ceil(w)), height: 26)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) { pressed = true }

    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        pressed = false
        if inside { action?(self) }
    }

    override func accessibilityPerformPress() -> Bool {
        action?(self)
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        let p = MonoPalette.current
        let r = bounds.insetBy(dx: 1, dy: 1)
        if isOn {
            p.onBg.setFill()
            NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3).fill()
        } else if pressed || hovering {
            (hoverOverride ?? p.hover).setFill()
            NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3).fill()
        }
        let ink = isOn ? p.onInk : (inkOverride ?? p.barInk)
        var x: CGFloat = 8
        if let symbol, let img = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .medium).applying(.init(paletteColors: [ink]))) {
            let s = img.size
            img.draw(in: NSRect(x: x, y: (bounds.height - s.height) / 2, width: s.width, height: s.height))
            x += 16 + 4
        }
        if !title.isEmpty {
            let attrs: [NSAttributedString.Key: Any] = [.font: MonoPalette.uiFont, .foregroundColor: ink]
            let size = (title as NSString).size(withAttributes: attrs)
            let available = bounds.width - x - (isDropdown ? 18 : 8)
            let rect = NSRect(x: x, y: (bounds.height - size.height) / 2, width: max(0, available), height: size.height)
            let para = NSMutableParagraphStyle()
            para.lineBreakMode = .byTruncatingTail
            (title as NSString).draw(in: rect, withAttributes: attrs.merging([.paragraphStyle: para]) { $1 })
        }
        if isDropdown {
            let ax = bounds.width - 13
            let ay = bounds.height / 2 - 1.5
            let tri = NSBezierPath()
            tri.move(to: NSPoint(x: ax, y: ay))
            tri.line(to: NSPoint(x: ax + 7, y: ay))
            tri.line(to: NSPoint(x: ax + 3.5, y: ay + 4))
            tri.close()
            (isOn ? p.onInk : p.dim).setFill()
            tri.fill()
        }
    }

    /// Opens a menu just below the button.
    func popUp(_ menu: NSMenu) {
        menu.appearance = MonoPalette.current.appearance
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 2), in: self)
    }
}

/// A row of controls on the bar colour, with a hairline below or above.
final class MonoBar: NSView {
    let stack = NSStackView()
    private let lineAtBottom: Bool

    init(lineAtBottom: Bool = true) {
        self.lineAtBottom = lineAtBottom
        super.init(frame: .zero)
        wantsLayer = true
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let p = MonoPalette.current
        p.bar.setFill()
        bounds.fill()
        p.edge.setFill()
        NSRect(x: 0, y: lineAtBottom ? 0 : bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    func add(_ v: NSView) { stack.addArrangedSubview(v) }

    func addSpacer() {
        let s = NSView()
        s.setContentHuggingPriority(.init(1), for: .horizontal)
        stack.addArrangedSubview(s)
    }

    func addDivider() {
        let d = MonoDivider()
        d.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([d.widthAnchor.constraint(equalToConstant: 13), d.heightAnchor.constraint(equalToConstant: 20)])
        stack.addArrangedSubview(d)
    }

    func label(_ text: String = "") -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        l.textColor = MonoPalette.current.barInk
        l.lineBreakMode = .byTruncatingTail
        return l
    }
}

final class MonoDivider: NSView {
    override func draw(_ dirtyRect: NSRect) {
        MonoPalette.current.edge.setFill()
        NSRect(x: floor(bounds.midX), y: 2, width: 1, height: bounds.height - 4).fill()
    }
}

extension NSMenuItem {
    static func mono(_ title: String, _ action: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = [.command],
                     tag: Int = 0, target: AnyObject? = nil) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.keyEquivalentModifierMask = mods
        i.tag = tag
        i.target = target
        return i
    }

    static func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let m = NSMenu(title: title)
        items.forEach(m.addItem)
        i.submenu = m
        return i
    }
}

/// A menu item that runs a closure when chosen.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, action handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func run() { handler() }
}
