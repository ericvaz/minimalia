import AppKit

/// A text view with an underscore cursor in the 1980s style and theme support.
/// Built on TextKit 1 so the cursor position can be computed from the layout manager.
class RetroTextView: NSTextView {
    private var keepStorage: NSTextStorage?
    let caretView = NSView()
    private var blinkTimer: Timer?
    private var caretPending = false

    var showsCaret = true { didSet { scheduleCaretUpdate() } }
    var maxColumns: Int? { didSet { updateInsets() } }
    /// Left-anchored layout: a side margin as a share of the width, instead of a centred column.
    var sideMargin: CGFloat? { didSet { updateInsets() } }
    var verticalInset: CGFloat = 22 { didSet { updateInsets() } }
    var keyInterceptor: ((NSEvent) -> Bool)?

    convenience init() {
        let storage = NSTextStorage()
        let lm = NSLayoutManager()
        storage.addLayoutManager(lm)
        let tc = NSTextContainer(size: NSSize(width: 800, height: CGFloat.greatestFiniteMagnitude))
        tc.widthTracksTextView = true
        lm.addTextContainer(tc)
        self.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600), textContainer: tc)
        keepStorage = storage
        setup()
    }

    func setup() {
        drawsBackground = true
        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = [.width]
        minSize = .zero
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        importsGraphics = false
        allowsImageEditing = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false
        isAutomaticLinkDetectionEnabled = false
        isAutomaticDataDetectionEnabled = false
        isAutomaticTextCompletionEnabled = false
        inlinePredictionType = .no
        writingToolsBehavior = .none
        smartInsertDeleteEnabled = false
        usesFontPanel = false
        usesRuler = false
        insertionPointColor = .clear

        caretView.wantsLayer = true
        caretView.isHidden = true
        addSubview(caretView)

        NotificationCenter.default.addObserver(self, selector: #selector(appearanceChanged),
                                               name: .minimaliaAppearance, object: nil)
        applyTheme()
        blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.53, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.blink() }
        }
    }

    @objc func appearanceChanged() {
        applyTheme()
        updateInsets()
        scheduleCaretUpdate()
    }

    func applyTheme() {
        let t = Settings.shared.theme
        backgroundColor = t.bg
        caretView.layer?.backgroundColor = t.fg.cgColor
        selectedTextAttributes = [.backgroundColor: t.fg, .foregroundColor: t.bg]
        linkTextAttributes = [.foregroundColor: t.dim, .cursor: NSCursor.pointingHand]
    }

    var charWidth: CGFloat {
        ("0" as NSString).size(withAttributes: [.font: Settings.shared.font]).width
    }

    func updateInsets() {
        var w: CGFloat = 28
        if let f = sideMargin {
            w = max(28, floor(bounds.width * f))
        } else if let cols = maxColumns, let tc = textContainer {
            let textW = CGFloat(cols) * charWidth + tc.lineFragmentPadding * 2
            w = max(28, floor((bounds.width - textW) / 2))
        }
        let inset = NSSize(width: w, height: verticalInset)
        if textContainerInset != inset { textContainerInset = inset }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateInsets()
        scheduleCaretUpdate()
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        scheduleCaretUpdate()
    }

    override func didChangeText() {
        super.didChangeText()
        scheduleCaretUpdate()
    }

    override func keyDown(with event: NSEvent) {
        NSCursor.setHiddenUntilMouseMoves(true)
        if let k = keyInterceptor, k(event) { return }
        handleKey(event)
    }

    func handleKey(_ event: NSEvent) {
        super.keyDown(with: event)
    }

    // MARK: Cursor

    func scheduleCaretUpdate() {
        if caretPending { return }
        caretPending = true
        DispatchQueue.main.async { [weak self] in
            self?.caretPending = false
            self?.updateCaret()
        }
    }

    func updateCaret() {
        guard showsCaret, selectedRange().length == 0, let r = caretRect() else {
            caretView.isHidden = true
            return
        }
        caretView.frame = r
        caretView.isHidden = false
        blinkTimer?.fireDate = Date().addingTimeInterval(0.53)
    }

    private func blink() {
        guard showsCaret, selectedRange().length == 0 else {
            caretView.isHidden = true
            return
        }
        if Settings.shared.cursorBlink { caretView.isHidden.toggle() } else { caretView.isHidden = false }
    }

    func caretRect() -> NSRect? {
        guard let lm = layoutManager, let tc = textContainer, let storage = textStorage else { return nil }
        let font = Settings.shared.font
        let len = storage.length
        let idx = min(selectedRange().location, len)
        let origin = textContainerOrigin
        let height = max(2, round(font.pointSize / 7))
        var x: CGFloat
        var baseline: CGFloat

        if len > 0 {
            let from = max(0, idx - 1)
            lm.ensureLayout(forCharacterRange: NSRange(location: from, length: min(2, len - from)))
        }

        if len == 0 {
            x = tc.lineFragmentPadding
            baseline = font.ascender
        } else if idx == len && lm.extraLineFragmentRect.height > 0 {
            let r = lm.extraLineFragmentRect
            x = r.minX + tc.lineFragmentPadding
            baseline = r.minY + font.ascender
        } else if idx == len {
            let g = lm.glyphIndexForCharacter(at: idx - 1)
            let line = lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
            let b = lm.boundingRect(forGlyphRange: NSRange(location: g, length: 1), in: tc)
            x = b.maxX
            baseline = line.minY + lm.location(forGlyphAt: g).y
        } else {
            let g = lm.glyphIndexForCharacter(at: idx)
            let line = lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
            let loc = lm.location(forGlyphAt: g)
            x = line.minX + loc.x
            baseline = line.minY + loc.y
        }
        return NSRect(x: origin.x + x, y: origin.y + baseline + 2, width: charWidth, height: height)
    }
}

/// One line of inverse text along the top or bottom, as in the editors of the 1980s.
final class BarView: NSView {
    let left = NSTextField(labelWithString: "")
    let right = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for l in [left, right] {
            l.translatesAutoresizingMaskIntoConstraints = false
            l.lineBreakMode = .byTruncatingTail
            l.maximumNumberOfLines = 1
            addSubview(l)
        }
        right.alignment = .right
        right.setContentCompressionResistancePriority(.required, for: .horizontal)
        left.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            left.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            left.centerYAnchor.constraint(equalTo: centerYAnchor),
            right.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            right.centerYAnchor.constraint(equalTo: centerYAnchor),
            left.trailingAnchor.constraint(lessThanOrEqualTo: right.leadingAnchor, constant: -20),
        ])
        restyle()
    }

    required init?(coder: NSCoder) { fatalError() }

    func restyle() {
        let s = Settings.shared
        layer?.backgroundColor = s.theme.barBg.cgColor
        for l in [left, right] {
            l.textColor = s.theme.barFg
            l.font = s.font
        }
    }
}

/// A full-window screen: optional top bar, a scrolling text view, optional bottom bar.
final class ScreenView: NSView {
    let scroll = NSScrollView()
    let textView: RetroTextView
    let top: BarView?
    let bottom: BarView?
    var onLayout: (() -> Void)?

    init(textView: RetroTextView, top hasTop: Bool, bottom hasBottom: Bool) {
        self.textView = textView
        top = hasTop ? BarView(frame: .zero) : nil
        bottom = hasBottom ? BarView(frame: .zero) : nil
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        wantsLayer = true
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.documentView = textView
        textView.frame = NSRect(origin: .zero, size: scroll.contentSize)
        textView.autoresizingMask = [.width]
        addSubview(scroll)
        if let top { addSubview(top) }
        if let bottom { addSubview(bottom) }
        NotificationCenter.default.addObserver(self, selector: #selector(restyle), name: .minimaliaAppearance, object: nil)
        restyle()
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc func restyle() {
        let t = Settings.shared.theme
        layer?.backgroundColor = t.bg.cgColor
        scroll.backgroundColor = t.bg
        scroll.scrollerKnobStyle = t.isDark ? .light : .dark
        top?.restyle()
        bottom?.restyle()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let h = ceil(Settings.shared.lineHeight) + 10
        var y0: CGFloat = 0
        var y1 = bounds.height
        if let bottom {
            bottom.frame = NSRect(x: 0, y: 0, width: bounds.width, height: h)
            y0 = h
        }
        if let top {
            top.frame = NSRect(x: 0, y: bounds.height - h, width: bounds.width, height: h)
            y1 -= h
        }
        scroll.frame = NSRect(x: 0, y: y0, width: bounds.width, height: max(0, y1 - y0))
        onLayout?()
    }
}
