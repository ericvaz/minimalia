import AppKit

enum WordStyles {
    struct Body {
        var family: String
        var size: CGFloat
    }

    static let defaultBody = Body(family: "Times New Roman", size: 12)

    enum Kind: String, CaseIterable {
        case normal = "Normal"
        case title = "Title"
        case heading1 = "Heading 1"
        case heading2 = "Heading 2"
        case heading3 = "Heading 3"
        case quote = "Quote"
    }

    /// The font used most in a document is its body text.
    static func body(of text: NSAttributedString) -> Body {
        var weights: [String: Int] = [:]
        text.enumerateAttribute(.font, in: NSRange(location: 0, length: text.length)) { v, r, _ in
            if let f = v as? NSFont { weights["\(f.familyName ?? defaultBody.family)|\(f.pointSize)", default: 0] += r.length }
        }
        guard let top = weights.max(by: { $0.value < $1.value })?.key else { return defaultBody }
        let parts = top.split(separator: "|")
        return Body(family: String(parts[0]), size: CGFloat(Double(parts.last ?? "12") ?? 12))
    }

    static func font(_ kind: Kind, _ body: Body) -> NSFont {
        let fm = NSFontManager.shared
        let size: CGFloat
        switch kind {
        case .normal, .quote: size = body.size
        case .title: size = round(body.size * 2.2)
        case .heading1: size = round(body.size * 1.5)
        case .heading2: size = round(body.size * 1.25)
        case .heading3: size = round(body.size * 1.1)
        }
        var f = fm.font(withFamily: body.family, traits: [], weight: 5, size: size)
            ?? NSFont(name: "Times New Roman", size: size) ?? NSFont.systemFont(ofSize: size)
        switch kind {
        case .heading1, .heading2, .heading3: f = fm.convert(f, toHaveTrait: .boldFontMask)
        case .quote: f = fm.convert(f, toHaveTrait: .italicFontMask)
        default: break
        }
        return f
    }

    static func paragraph(_ kind: Kind, _ body: Body, base: NSParagraphStyle?) -> NSParagraphStyle {
        let p = (base?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
        p.lineHeightMultiple = 1.15
        p.paragraphSpacing = 8
        p.paragraphSpacingBefore = 0
        p.headIndent = 0
        p.firstLineHeadIndent = 0
        p.tailIndent = 0
        switch kind {
        case .title: p.paragraphSpacing = 12
        case .heading1: p.paragraphSpacingBefore = 18; p.paragraphSpacing = 6
        case .heading2, .heading3: p.paragraphSpacingBefore = 12; p.paragraphSpacing = 4
        case .quote: p.headIndent = 36; p.firstLineHeadIndent = 36; p.tailIndent = -36
        case .normal: break
        }
        return p
    }

    static func normalAttributes(_ body: Body) -> [NSAttributedString.Key: Any] {
        [.font: font(.normal, body), .paragraphStyle: paragraph(.normal, body, base: nil), .foregroundColor: NSColor.black]
    }

    static func detect(_ font: NSFont?, _ para: NSParagraphStyle?, _ body: Body) -> Kind {
        guard let font else { return .normal }
        let bold = NSFontManager.shared.traits(of: font).contains(.boldFontMask)
        let ratio = font.pointSize / max(1, body.size)
        if ratio >= 1.9 { return .title }
        if ratio >= 1.4 && bold { return .heading1 }
        if ratio >= 1.2 && bold { return .heading2 }
        if ratio >= 1.08 && bold { return .heading3 }
        if let p = para, p.headIndent >= 30, p.firstLineHeadIndent >= 30 { return .quote }
        return .normal
    }
}

/// A white US Letter page with one-inch margins, on a grey desk.
final class PageTextView: NSTextView {
    static let pageWidth: CGFloat = 612
    static let margin: CGFloat = 72
    static let gap: CGFloat = 28

    func updateInsets() {
        let x = max(Self.margin + 12, floor((bounds.width - Self.pageWidth) / 2) + Self.margin)
        let inset = NSSize(width: x, height: Self.margin + Self.gap)
        if textContainerInset != inset { textContainerInset = inset }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateInsets()
    }

    override func drawBackground(in rect: NSRect) {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        (dark ? NSColor(white: 0.17, alpha: 1) : NSColor(srgbRed: 0.91, green: 0.91, blue: 0.92, alpha: 1)).setFill()
        rect.fill()
        let page = NSRect(x: textContainerInset.width - Self.margin, y: Self.gap,
                          width: Self.pageWidth, height: max(bounds.height - Self.gap * 2, 792))
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(white: 0, alpha: dark ? 0.6 : 0.18)
        shadow.shadowBlurRadius = 6
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.set()
        NSColor.white.setFill()
        page.fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}

final class WordWindowController: NSWindowController, NSTextViewDelegate, NSWindowDelegate {
    let textView: PageTextView
    let scroll = NSScrollView()
    private var body = WordStyles.defaultBody

    private let stylePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let fontPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let sizeBox = NSComboBox()
    private let traits = NSSegmentedControl()
    private let colorWell = NSColorWell(style: .minimal)
    private let status = NSTextField(labelWithString: "")
    private let zoomLabel = NSTextField(labelWithString: "100%")
    private let zoomSlider = NSSlider(value: 100, minValue: 50, maxValue: 200, target: nil, action: nil)
    private var countTimer: Timer?
    private var words = 0

    init(document: WordDocument) {
        let storage = NSTextStorage()
        let lm = NSLayoutManager()
        storage.addLayoutManager(lm)
        let tc = NSTextContainer(size: NSSize(width: PageTextView.pageWidth - PageTextView.margin * 2, height: .greatestFiniteMagnitude))
        tc.widthTracksTextView = false
        lm.addTextContainer(tc)
        textView = PageTextView(frame: NSRect(x: 0, y: 0, width: 900, height: 900), textContainer: tc)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 820),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.minSize = NSSize(width: 720, height: 420)
        super.init(window: window)
        window.delegate = self
        window.setFrameAutosaveName("MinimaliaWordWindow")
        if window.frame.origin == .zero { window.center() }
        buildViews(storage: storage)
        load(document)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Layout

    private func buildViews(storage: NSTextStorage) {
        guard let content = window?.contentView else { return }

        let tv = textView
        tv.isRichText = true
        tv.importsGraphics = true
        tv.allowsUndo = true
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.usesFontPanel = true
        tv.usesRuler = true
        tv.isContinuousSpellCheckingEnabled = true
        tv.isGrammarCheckingEnabled = true
        tv.isAutomaticQuoteSubstitutionEnabled = true
        tv.isAutomaticDashSubstitutionEnabled = true
        tv.isAutomaticLinkDetectionEnabled = false
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.minSize = NSSize(width: 0, height: 792 + PageTextView.gap * 2)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.drawsBackground = true
        tv.appearance = NSAppearance(named: .aqua)
        tv.insertionPointColor = .black
        tv.delegate = self

        scroll.documentView = tv
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.5
        scroll.maxMagnification = 2
        scroll.translatesAutoresizingMaskIntoConstraints = false
        tv.frame = NSRect(origin: .zero, size: scroll.contentSize)
        tv.isRulerVisible = true

        let bar = buildToolbar()
        let statusBar = buildStatusBar()
        let line1 = NSBox()
        line1.boxType = .separator
        line1.translatesAutoresizingMaskIntoConstraints = false
        let line2 = NSBox()
        line2.boxType = .separator
        line2.translatesAutoresizingMaskIntoConstraints = false
        for v in [bar, line1, scroll, line2, statusBar] { content.addSubview(v) }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: content.topAnchor),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: 42),
            line1.topAnchor.constraint(equalTo: bar.bottomAnchor),
            line1.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            line1.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: line1.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            line2.topAnchor.constraint(equalTo: scroll.bottomAnchor),
            line2.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            line2.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            statusBar.topAnchor.constraint(equalTo: line2.bottomAnchor),
            statusBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: 26),
        ])
    }

    private func buildToolbar() -> NSView {
        stylePopup.addItems(withTitles: WordStyles.Kind.allCases.map(\.rawValue))
        stylePopup.target = self
        stylePopup.action = #selector(applyStyle(_:))
        stylePopup.toolTip = "Paragraph style"

        fontPopup.addItems(withTitles: NSFontManager.shared.availableFontFamilies.filter { !$0.hasPrefix(".") }.sorted())
        fontPopup.target = self
        fontPopup.action = #selector(changeFamily(_:))
        fontPopup.toolTip = "Font"

        sizeBox.addItems(withObjectValues: [8, 9, 10, 10.5, 11, 12, 14, 16, 18, 20, 24, 28, 32, 36, 48, 72].map { NSNumber(value: $0) })
        sizeBox.numberOfVisibleItems = 12
        sizeBox.target = self
        sizeBox.action = #selector(changeSize(_:))
        sizeBox.toolTip = "Font size"

        let symbols = ["bold", "italic", "underline"]
        traits.segmentCount = 3
        traits.trackingMode = .selectAny
        for (i, s) in symbols.enumerated() {
            traits.setImage(NSImage(systemSymbolName: s, accessibilityDescription: s.capitalized), forSegment: i)
            traits.setWidth(30, forSegment: i)
        }
        traits.target = self
        traits.action = #selector(toggleTrait(_:))
        traits.toolTip = "Bold, italic, underline"

        colorWell.color = .black
        colorWell.target = self
        colorWell.action = #selector(changeColor(_:))
        colorWell.toolTip = "Text colour"

        let rulerButton = NSButton(image: NSImage(systemSymbolName: "ruler", accessibilityDescription: "Ruler")!,
                                   target: self, action: #selector(toggleRulerBar(_:)))
        rulerButton.bezelStyle = .texturedRounded
        rulerButton.toolTip = "Show or hide the ruler"

        let stack = NSStackView(views: [stylePopup, fontPopup, sizeBox, traits, colorWell, NSView(), rulerButton])
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 14)
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setHuggingPriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            stylePopup.widthAnchor.constraint(equalToConstant: 120),
            fontPopup.widthAnchor.constraint(equalToConstant: 190),
            sizeBox.widthAnchor.constraint(equalToConstant: 64),
            colorWell.widthAnchor.constraint(equalToConstant: 38),
        ])
        return stack
    }

    private func buildStatusBar() -> NSView {
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        zoomLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        zoomLabel.textColor = .secondaryLabelColor
        zoomSlider.controlSize = .small
        zoomSlider.target = self
        zoomSlider.action = #selector(zoomChanged(_:))
        let stack = NSStackView(views: [status, NSView(), zoomSlider, zoomLabel])
        stack.orientation = .horizontal
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 14)
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        zoomSlider.widthAnchor.constraint(equalToConstant: 120).isActive = true
        zoomLabel.widthAnchor.constraint(equalToConstant: 40).isActive = true
        return stack
    }

    private func load(_ document: WordDocument) {
        let content = document.loaded
        if content.length > 0 {
            textView.textStorage?.setAttributedString(content)
            body = WordStyles.body(of: content)
            textView.setSelectedRange(NSRange(location: 0, length: 0))
        }
        textView.typingAttributes = content.length > 0
            ? content.attributes(at: 0, effectiveRange: nil)
            : WordStyles.normalAttributes(body)
        textView.defaultParagraphStyle = WordStyles.paragraph(.normal, body, base: nil)
        document.textView = textView
        countWords()
        refreshToolbar()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self.textView)
            self.textView.updateInsets()
        }
    }

    // MARK: Delegate

    func undoManager(for view: NSTextView) -> UndoManager? { document?.undoManager }

    func textDidChange(_ notification: Notification) {
        countTimer?.invalidate()
        countTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.countWords() }
        }
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        refreshToolbar()
        updateStatus()
    }

    // MARK: Toolbar state

    private var currentAttributes: [NSAttributedString.Key: Any] {
        let r = textView.selectedRange()
        if r.length > 0, let ts = textView.textStorage, r.location < ts.length {
            return ts.attributes(at: r.location, effectiveRange: nil)
        }
        return textView.typingAttributes
    }

    func refreshToolbar() {
        let a = currentAttributes
        let font = a[.font] as? NSFont
        if let fam = font?.familyName { fontPopup.selectItem(withTitle: fam) }
        if let size = font?.pointSize {
            sizeBox.stringValue = size.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(size))" : "\(size)"
        }
        let tr = font.map { NSFontManager.shared.traits(of: $0) } ?? []
        traits.setSelected(tr.contains(.boldFontMask), forSegment: 0)
        traits.setSelected(tr.contains(.italicFontMask), forSegment: 1)
        traits.setSelected((a[.underlineStyle] as? Int ?? 0) != 0, forSegment: 2)
        colorWell.color = a[.foregroundColor] as? NSColor ?? .black
        stylePopup.selectItem(withTitle: WordStyles.detect(font, a[.paragraphStyle] as? NSParagraphStyle, body).rawValue)
    }

    private func countWords() {
        var n = 0
        (textView.string as NSString).enumerateSubstrings(in: NSRange(location: 0, length: (textView.string as NSString).length),
                                                          options: [.byWords, .substringNotRequired]) { _, _, _, _ in n += 1 }
        words = n
        updateStatus()
    }

    private func updateStatus() {
        let perPage = 792 - PageTextView.margin * 2
        var pages = 1
        var page = 1
        if let lm = textView.layoutManager, let tc = textView.textContainer {
            pages = max(1, Int(ceil(lm.usedRect(for: tc).height / perPage)))
            let loc = min(textView.selectedRange().location, max(0, (textView.string as NSString).length - 1))
            if (textView.string as NSString).length > 0 {
                let g = lm.glyphIndexForCharacter(at: loc)
                let y = lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil).minY
                page = min(pages, Int(y / perPage) + 1)
            }
        }
        let wordText = NumberFormatter.localizedString(from: NSNumber(value: words), number: .decimal)
        status.stringValue = "Page \(page) of \(pages)    \(wordText) \(words == 1 ? "word" : "words")"
    }

    // MARK: Formatting

    private func editFonts(_ transform: (NSFont) -> NSFont) {
        let tv = textView
        let ranges = tv.rangesForUserCharacterAttributeChange?.map(\.rangeValue).filter { $0.length > 0 } ?? []
        if ranges.isEmpty {
            var t = tv.typingAttributes
            t[.font] = transform(t[.font] as? NSFont ?? WordStyles.font(.normal, body))
            tv.typingAttributes = t
        } else if let ts = tv.textStorage,
                  tv.shouldChangeText(inRanges: ranges.map { NSValue(range: $0) }, replacementStrings: nil) {
            ts.beginEditing()
            for r in ranges {
                ts.enumerateAttribute(.font, in: r) { v, sub, _ in
                    ts.addAttribute(.font, value: transform(v as? NSFont ?? WordStyles.font(.normal, self.body)), range: sub)
                }
            }
            ts.endEditing()
            tv.didChangeText()
        }
        refreshToolbar()
        window?.makeFirstResponder(tv)
    }

    @objc func toggleTrait(_ sender: NSSegmentedControl) {
        let seg = sender.selectedSegment
        let fm = NSFontManager.shared
        let current = (currentAttributes[.font] as? NSFont).map { fm.traits(of: $0) } ?? []
        _ = current
        _ = fm
        switch seg {
        case 0:
            toggleBold(sender)
        case 1:
            toggleItalic(sender)
        default:
            textView.underline(nil)
            refreshToolbar()
            window?.makeFirstResponder(textView)
        }
    }

    @objc func toggleBold(_ sender: Any?) {
        let fm = NSFontManager.shared
        let on = !((currentAttributes[.font] as? NSFont).map { fm.traits(of: $0).contains(.boldFontMask) } ?? false)
        editFonts { on ? fm.convert($0, toHaveTrait: .boldFontMask) : fm.convert($0, toNotHaveTrait: .boldFontMask) }
    }

    @objc func toggleItalic(_ sender: Any?) {
        let fm = NSFontManager.shared
        let on = !((currentAttributes[.font] as? NSFont).map { fm.traits(of: $0).contains(.italicFontMask) } ?? false)
        editFonts { on ? fm.convert($0, toHaveTrait: .italicFontMask) : fm.convert($0, toNotHaveTrait: .italicFontMask) }
    }

    @objc func changeFamily(_ sender: NSPopUpButton) {
        guard let family = sender.titleOfSelectedItem else { return }
        editFonts { NSFontManager.shared.convert($0, toFamily: family) }
    }

    @objc func changeSize(_ sender: NSComboBox) {
        let size = CGFloat(sender.doubleValue)
        guard size >= 4, size <= 400 else { refreshToolbar(); return }
        editFonts { NSFontManager.shared.convert($0, toSize: size) }
    }

    @objc func changeColor(_ sender: NSColorWell) {
        let tv = textView
        let ranges = tv.rangesForUserCharacterAttributeChange?.map(\.rangeValue).filter { $0.length > 0 } ?? []
        if ranges.isEmpty {
            tv.typingAttributes[.foregroundColor] = sender.color
        } else if let ts = tv.textStorage,
                  tv.shouldChangeText(inRanges: ranges.map { NSValue(range: $0) }, replacementStrings: nil) {
            ts.beginEditing()
            for r in ranges { ts.addAttribute(.foregroundColor, value: sender.color, range: r) }
            ts.endEditing()
            tv.didChangeText()
        }
    }

    @objc func applyStyle(_ sender: Any?) {
        let title = (sender as? NSPopUpButton)?.titleOfSelectedItem ?? (sender as? NSMenuItem)?.title ?? "Normal"
        guard let kind = WordStyles.Kind(rawValue: title), let ts = textView.textStorage else { return }
        let ns = textView.string as NSString
        let pr = ns.paragraphRange(for: textView.selectedRange())
        let font = WordStyles.font(kind, body)
        if pr.length > 0, textView.shouldChangeText(in: pr, replacementString: nil) {
            ts.beginEditing()
            ts.addAttribute(.font, value: font, range: pr)
            var loc = pr.location
            while loc < NSMaxRange(pr) {
                let p = ns.paragraphRange(for: NSRange(location: loc, length: 0))
                let base = ts.attribute(.paragraphStyle, at: p.location, effectiveRange: nil) as? NSParagraphStyle
                ts.addAttribute(.paragraphStyle, value: WordStyles.paragraph(kind, body, base: base), range: p)
                loc = NSMaxRange(p)
            }
            ts.endEditing()
            textView.didChangeText()
        }
        var t = textView.typingAttributes
        t[.font] = font
        t[.paragraphStyle] = WordStyles.paragraph(kind, body, base: t[.paragraphStyle] as? NSParagraphStyle)
        textView.typingAttributes = t
        refreshToolbar()
        window?.makeFirstResponder(textView)
    }

    @objc func toggleRulerBar(_ sender: Any?) {
        textView.isRulerVisible.toggle()
    }

    // MARK: Zoom

    @objc func zoomChanged(_ sender: NSSlider) {
        setZoom(CGFloat(sender.doubleValue) / 100)
    }

    func setZoom(_ z: CGFloat) {
        let z = min(2, max(0.5, (z * 10).rounded() / 10))
        scroll.magnification = z
        zoomSlider.doubleValue = Double(z * 100)
        zoomLabel.stringValue = "\(Int((z * 100).rounded()))%"
    }

    @objc func zoomIn(_ sender: Any?) { setZoom(scroll.magnification + 0.1) }
    @objc func zoomOut(_ sender: Any?) { setZoom(scroll.magnification - 0.1) }
    @objc func actualSize(_ sender: Any?) { setZoom(1) }
}
