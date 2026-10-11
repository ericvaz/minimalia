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

    static let favouriteFonts = ["Times New Roman", "Georgia", "Garamond", "Baskerville", "Palatino",
                                 "Helvetica Neue", "Arial", "Avenir Next", "Gill Sans", "Courier New", "Menlo"]

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

    static func paragraph(_ kind: Kind, base: NSParagraphStyle?) -> NSParagraphStyle {
        let p = (base?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
        if p.lineHeightMultiple == 0 { p.lineHeightMultiple = 1.15 }
        p.paragraphSpacing = 8
        p.paragraphSpacingBefore = 0
        if p.textLists.isEmpty {
            p.headIndent = 0
            p.firstLineHeadIndent = 0
        }
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

    static func detect(_ font: NSFont?, _ para: NSParagraphStyle?, _ body: Body) -> Kind {
        guard let font else { return .normal }
        let bold = NSFontManager.shared.traits(of: font).contains(.boldFontMask)
        let ratio = font.pointSize / max(1, body.size)
        if ratio >= 1.9 { return .title }
        if ratio >= 1.4 && bold { return .heading1 }
        if ratio >= 1.2 && bold { return .heading2 }
        if ratio >= 1.08 && bold { return .heading3 }
        if let p = para, p.headIndent >= 30, p.firstLineHeadIndent >= 30, p.textLists.isEmpty { return .quote }
        return .normal
    }
}

/// A Letter-size page with one-inch margins, drawn in greys on the Minimalia desk.
final class MonoPageView: NSTextView {
    static let pageWidth: CGFloat = 612
    static let margin: CGFloat = 72
    static let gap: CGFloat = 28
    var keyInterceptor: ((NSEvent) -> Bool)?

    func updateInsets() {
        let x = max(Self.margin + 12, floor((bounds.width - Self.pageWidth) / 2) + Self.margin)
        let inset = NSSize(width: x, height: Self.margin + Self.gap)
        if textContainerInset != inset { textContainerInset = inset }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateInsets()
    }

    override func keyDown(with event: NSEvent) {
        if let k = keyInterceptor, k(event) { return }
        super.keyDown(with: event)
    }

    override func drawBackground(in rect: NSRect) {
        let p = MonoPalette.current
        p.desk.setFill()
        rect.fill()
        let page = NSRect(x: textContainerInset.width - Self.margin, y: Self.gap,
                          width: Self.pageWidth, height: max(bounds.height - Self.gap * 2, 792))
        p.page.setFill()
        page.fill()
        p.edge.setFill()
        page.frame(withWidth: 1)
    }
}

/// Minimalia Folio: a greyscale word processor that runs inside the Minimalia screen.
/// The document keeps its real fonts and colours; only the display is turned to greys.
@MainActor
final class WordProgram: NSObject, MinimaliaProgram, DocumentController, NSTextViewDelegate, NSTextStorageDelegate {
    let screen = NSView()
    let textView: MonoPageView
    private let scroll = NSScrollView()
    private let menuBar = MonoBar()
    private let toolBar = MonoBar()
    private let statusBar = MonoBar(lineAtBottom: false)
    private var nameLabel: NSTextField!
    private var statusLabel: NSTextField!
    private var zoomLabel: NSTextField!

    private var url: URL
    private var type: NSAttributedString.DocumentType?
    private var meta: [NSAttributedString.DocumentAttributeKey: Any]
    private let existing: Bool
    private var confirmedOverwrite = false
    private var body = WordStyles.defaultBody
    private(set) var dirty = false { didSet { updateTitle() } }
    var onExit: (() -> Void)?

    private var pending: NSRange?
    private var words = 0
    private var countTimer: Timer?
    private var message: String?

    private var styleButton: MonoButton!
    private var fontButton: MonoButton!
    private var sizeButton: MonoButton!
    private var traitButtons: [MonoButton] = []
    private var alignButtons: [MonoButton] = []
    private var listButtons: [MonoButton] = []

    var name: String { url.lastPathComponent }
    var focusView: NSView { textView }

    init(url: URL, content: NSAttributedString, doc: LoadedDoc, existing: Bool) {
        self.url = url
        self.existing = existing
        meta = doc.meta
        if case .rich(let t) = doc.kind { type = t } else { type = nil }

        let storage = NSTextStorage()
        let lm = NSLayoutManager()
        storage.addLayoutManager(lm)
        let tc = NSTextContainer(size: NSSize(width: MonoPageView.pageWidth - MonoPageView.margin * 2, height: .greatestFiniteMagnitude))
        tc.widthTracksTextView = false
        lm.addTextContainer(tc)
        textView = MonoPageView(frame: NSRect(x: 0, y: 0, width: 900, height: 900), textContainer: tc)
        super.init()
        storageRef = storage

        buildScreen()
        load(content, plain: type == nil)
        NotificationCenter.default.addObserver(self, selector: #selector(restyle), name: .minimaliaAppearance, object: nil)
    }

    private var storageRef: NSTextStorage?

    // MARK: Building

    private func buildScreen() {
        screen.wantsLayer = true

        let tv = textView
        tv.isRichText = true
        tv.importsGraphics = true
        tv.allowsUndo = true
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.usesFontPanel = false
        tv.usesRuler = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.isAutomaticQuoteSubstitutionEnabled = true
        tv.isAutomaticDashSubstitutionEnabled = true
        tv.isAutomaticLinkDetectionEnabled = false
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = []
        tv.minSize = NSSize(width: 0, height: 792 + MonoPageView.gap * 2)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.drawsBackground = true
        tv.delegate = self
        tv.keyInterceptor = { [weak self] e in self?.handleKey(e) ?? false }
        tv.textStorage?.delegate = self

        scroll.documentView = tv
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.5
        scroll.maxMagnification = 4
        tv.frame = NSRect(origin: .zero, size: scroll.contentSize)
        scroll.contentView.postsFrameChangedNotifications = true
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(fitWidth), name: NSView.frameDidChangeNotification, object: scroll.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(fitWidth), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(fitWidth), name: NSScrollView.didEndLiveMagnifyNotification, object: scroll)

        // Menu row, as in the editors of the 1980s, plus the document name.
        for m in makeMenus() {
            let b = MonoButton(m.title, dropdown: false)
            b.action = { [weak self] btn in
                guard let self else { return }
                let fresh = self.makeMenus().first { $0.title == m.title } ?? m
                btn.popUp(fresh)
            }
            menuBar.add(b)
        }
        menuBar.addSpacer()
        nameLabel = menuBar.label()
        menuBar.add(nameLabel)

        // Formatting row.
        styleButton = MonoButton("Normal", dropdown: true, help: "Paragraph style") { [weak self] b in self?.popStyles(b) }
        styleButton.minWidth = 118
        fontButton = MonoButton("Times New Roman", dropdown: true, help: "Font") { [weak self] b in self?.popFonts(b) }
        fontButton.minWidth = 170
        sizeButton = MonoButton("12", dropdown: true, help: "Size") { [weak self] b in self?.popSizes(b) }
        sizeButton.minWidth = 54
        toolBar.add(styleButton)
        toolBar.add(fontButton)
        toolBar.add(sizeButton)
        toolBar.addDivider()
        traitButtons = [
            MonoButton("", symbol: "bold", help: "Bold") { [weak self] _ in self?.toggleBold(nil) },
            MonoButton("", symbol: "italic", help: "Italic") { [weak self] _ in self?.toggleItalic(nil) },
            MonoButton("", symbol: "underline", help: "Underline") { [weak self] _ in self?.toggleUnderline(nil) },
        ]
        traitButtons.forEach(toolBar.add)
        toolBar.addDivider()
        alignButtons = [
            MonoButton("", symbol: "text.alignleft", help: "Align left") { [weak self] _ in self?.align(.left) },
            MonoButton("", symbol: "text.aligncenter", help: "Centre") { [weak self] _ in self?.align(.center) },
            MonoButton("", symbol: "text.alignright", help: "Align right") { [weak self] _ in self?.align(.right) },
            MonoButton("", symbol: "text.justify", help: "Justify") { [weak self] _ in self?.align(.justified) },
        ]
        alignButtons.forEach(toolBar.add)
        toolBar.addDivider()
        listButtons = [
            MonoButton("", symbol: "list.bullet", help: "Bulleted list") { [weak self] _ in self?.toggleList(.disc) },
            MonoButton("", symbol: "list.number", help: "Numbered list") { [weak self] _ in self?.toggleList(.decimal) },
        ]
        listButtons.forEach(toolBar.add)
        toolBar.addSpacer()

        // Status row.
        statusLabel = statusBar.label()
        statusBar.add(statusLabel)
        statusBar.addSpacer()
        let hint = statusBar.label("Esc returns to the prompt")
        hint.textColor = MonoPalette.current.dim
        statusBar.add(hint)
        statusBar.addDivider()
        zoomLabel = statusBar.label("100%")
        statusBar.add(MonoButton("", symbol: "minus.magnifyingglass", help: "Zoom out") { [weak self] _ in self?.zoomOut(nil) })
        statusBar.add(zoomLabel)
        statusBar.add(MonoButton("", symbol: "plus.magnifyingglass", help: "Zoom in") { [weak self] _ in self?.zoomIn(nil) })

        for v in [menuBar, toolBar, scroll, statusBar] {
            v.translatesAutoresizingMaskIntoConstraints = false
            screen.addSubview(v)
        }
        NSLayoutConstraint.activate([
            menuBar.topAnchor.constraint(equalTo: screen.topAnchor),
            menuBar.leadingAnchor.constraint(equalTo: screen.leadingAnchor),
            menuBar.trailingAnchor.constraint(equalTo: screen.trailingAnchor),
            menuBar.heightAnchor.constraint(equalToConstant: 32),
            toolBar.topAnchor.constraint(equalTo: menuBar.bottomAnchor),
            toolBar.leadingAnchor.constraint(equalTo: screen.leadingAnchor),
            toolBar.trailingAnchor.constraint(equalTo: screen.trailingAnchor),
            toolBar.heightAnchor.constraint(equalToConstant: 38),
            scroll.topAnchor.constraint(equalTo: toolBar.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: screen.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: screen.trailingAnchor),
            statusBar.topAnchor.constraint(equalTo: scroll.bottomAnchor),
            statusBar.leadingAnchor.constraint(equalTo: screen.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: screen.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: screen.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: 28),
        ])
        restyle()
    }

    private func load(_ content: NSAttributedString, plain: Bool) {
        let ts = textView.textStorage!
        if plain {
            let attrs = baseAttributes(.normal)
            ts.setAttributedString(NSAttributedString(string: content.string, attributes: attrs))
        } else {
            ts.setAttributedString(content)
            if content.length > 0 { body = WordStyles.body(of: content) }
        }
        textView.typingAttributes = ts.length > 0 ? ts.attributes(at: 0, effectiveRange: nil) : baseAttributes(.normal)
        textView.typingAttributes[.foregroundColor] = NSColor.black
        textView.defaultParagraphStyle = WordStyles.paragraph(.normal, base: nil)
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.undoManager?.removeAllActions()
        pending = nil
        dirty = false
        recolour(NSRange(location: 0, length: ts.length))
        countWords()
        refreshToolbar()
    }

    private func baseAttributes(_ kind: WordStyles.Kind) -> [NSAttributedString.Key: Any] {
        [.font: WordStyles.font(kind, body), .paragraphStyle: WordStyles.paragraph(kind, base: nil), .foregroundColor: NSColor.black]
    }

    @objc private func restyle() {
        let p = MonoPalette.current
        screen.layer?.backgroundColor = p.desk.cgColor
        screen.appearance = p.appearance
        scroll.backgroundColor = p.desk
        scroll.scrollerKnobStyle = p.isDark ? .light : .dark
        textView.insertionPointColor = p.ink
        textView.selectedTextAttributes = [.backgroundColor: p.selection]
        textView.linkTextAttributes = [.underlineStyle: NSUnderlineStyle.single.rawValue, .cursor: NSCursor.pointingHand]
        for l in [nameLabel, statusLabel, zoomLabel] { l?.textColor = p.barInk }
        [menuBar, toolBar, statusBar].forEach { bar in
            bar.needsDisplay = true
            bar.stack.arrangedSubviews.forEach { $0.needsDisplay = true }
        }
        recolour(NSRange(location: 0, length: textView.textStorage?.length ?? 0))
        textView.needsDisplay = true
    }

    // MARK: Greyscale display

    /// Paints the document's colours as greys without touching the colours that get saved.
    private func recolour(_ range: NSRange) {
        guard let lm = textView.layoutManager, let ts = textView.textStorage, ts.length > 0 else { return }
        let ns = ts.string as NSString
        let r = ns.paragraphRange(for: NSIntersectionRange(range, NSRange(location: 0, length: ts.length)))
        guard r.length > 0 else { return }
        let p = MonoPalette.current
        lm.removeTemporaryAttribute(.foregroundColor, forCharacterRange: r)
        lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: r)
        ts.enumerateAttribute(.foregroundColor, in: r) { v, sub, _ in
            lm.addTemporaryAttribute(.foregroundColor, value: p.grey(for: v as? NSColor), forCharacterRange: sub)
        }
        ts.enumerateAttribute(.backgroundColor, in: r) { v, sub, _ in
            if v != nil { lm.addTemporaryAttribute(.backgroundColor, value: p.highlight, forCharacterRange: sub) }
        }
    }

    nonisolated func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                                 range editedRange: NSRange, changeInLength delta: Int) {
        MainActor.assumeIsolated {
            pending = pending.map { NSUnionRange($0, editedRange) } ?? editedRange
            DispatchQueue.main.async { [weak self] in
                guard let self, let r = self.pending else { return }
                self.pending = nil
                self.recolour(r)
            }
        }
    }

    // MARK: Text view delegate

    func textDidChange(_ notification: Notification) {
        if !dirty { dirty = true }
        countTimer?.invalidate()
        countTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.countWords() }
        }
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        refreshToolbar()
        updateStatus()
    }

    func textView(_ textView: NSTextView, shouldChangeTypingAttributes old: [String: Any], toAttributes new: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
        var a = new
        if a[.foregroundColor] == nil { a[.foregroundColor] = NSColor.black }
        return a
    }

    private func handleKey(_ e: NSEvent) -> Bool {
        if e.keyCode == 53 {
            closeDocument(nil)
            return true
        }
        return false
    }

    // MARK: Toolbar state

    private var currentAttributes: [NSAttributedString.Key: Any] {
        let r = textView.selectedRange()
        if r.length > 0, let ts = textView.textStorage, r.location < ts.length {
            return ts.attributes(at: r.location, effectiveRange: nil)
        }
        return textView.typingAttributes
    }

    private func refreshToolbar() {
        let a = currentAttributes
        let font = a[.font] as? NSFont
        let para = a[.paragraphStyle] as? NSParagraphStyle
        fontButton.title = font?.familyName ?? body.family
        if let s = font?.pointSize { sizeButton.title = s.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(s))" : String(format: "%.1f", s) }
        styleButton.title = WordStyles.detect(font, para, body).rawValue
        let tr = font.map { NSFontManager.shared.traits(of: $0) } ?? []
        traitButtons[0].isOn = tr.contains(.boldFontMask)
        traitButtons[1].isOn = tr.contains(.italicFontMask)
        traitButtons[2].isOn = (a[.underlineStyle] as? Int ?? 0) != 0
        let al = para?.alignment ?? .natural
        let index: Int
        switch al {
        case .center: index = 1
        case .right: index = 2
        case .justified: index = 3
        default: index = 0
        }
        for (i, b) in alignButtons.enumerated() { b.isOn = i == index }
        let list = para?.textLists.first
        listButtons[0].isOn = list != nil && list?.markerFormat != .decimal
        listButtons[1].isOn = list?.markerFormat == .decimal
    }

    private func countWords() {
        var n = 0
        let ns = textView.string as NSString
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byWords, .substringNotRequired]) { _, _, _, _ in n += 1 }
        words = n
        updateStatus()
    }

    private func updateStatus() {
        let perPage = 792 - MonoPageView.margin * 2
        var pages = 1
        var page = 1
        if let lm = textView.layoutManager, let tc = textView.textContainer {
            pages = max(1, Int(ceil(lm.usedRect(for: tc).height / perPage)))
            let len = (textView.string as NSString).length
            if len > 0 {
                let g = lm.glyphIndexForCharacter(at: min(textView.selectedRange().location, len - 1))
                page = min(pages, Int(lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil).minY / perPage) + 1)
            }
        }
        let w = NumberFormatter.localizedString(from: NSNumber(value: words), number: .decimal)
        statusLabel.stringValue = message ?? "Page \(page) of \(pages)     \(w) \(words == 1 ? "word" : "words")"
    }

    private func updateTitle() {
        nameLabel?.stringValue = name + (dirty ? "  *" : "")
    }

    private func flash(_ text: String) {
        message = text
        updateStatus()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.message == text else { return }
            self.message = nil
            self.updateStatus()
        }
    }

    // MARK: Formatting

    private func editFonts(_ transform: (NSFont) -> NSFont) {
        let tv = textView
        let ranges = tv.rangesForUserCharacterAttributeChange?.map(\.rangeValue).filter { $0.length > 0 } ?? []
        if ranges.isEmpty {
            tv.typingAttributes[.font] = transform(tv.typingAttributes[.font] as? NSFont ?? WordStyles.font(.normal, body))
        } else if let ts = tv.textStorage, tv.shouldChangeText(inRanges: ranges.map { NSValue(range: $0) }, replacementStrings: nil) {
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
        screen.window?.makeFirstResponder(tv)
    }

    private func editParagraphs(_ change: (NSMutableParagraphStyle) -> Void) {
        let tv = textView
        guard let ts = tv.textStorage else { return }
        let ns = ts.string as NSString
        let all = ns.paragraphRange(for: tv.selectedRange())
        if all.length > 0, tv.shouldChangeText(in: all, replacementString: nil) {
            ts.beginEditing()
            var loc = all.location
            while loc < NSMaxRange(all) {
                let pr = ns.paragraphRange(for: NSRange(location: loc, length: 0))
                let p = ((ts.attribute(.paragraphStyle, at: pr.location, effectiveRange: nil) as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle)
                    ?? NSMutableParagraphStyle()
                change(p)
                ts.addAttribute(.paragraphStyle, value: p, range: pr)
                loc = NSMaxRange(pr)
            }
            ts.endEditing()
            tv.didChangeText()
        }
        let p = ((tv.typingAttributes[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
        change(p)
        tv.typingAttributes[.paragraphStyle] = p
        refreshToolbar()
        screen.window?.makeFirstResponder(tv)
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

    @objc func toggleUnderline(_ sender: Any?) {
        textView.underline(nil)
        refreshToolbar()
        screen.window?.makeFirstResponder(textView)
    }

    @objc func biggerFont(_ sender: Any?) { editFonts { NSFontManager.shared.convert($0, toSize: $0.pointSize + 1) } }
    @objc func smallerFont(_ sender: Any?) { editFonts { NSFontManager.shared.convert($0, toSize: max(4, $0.pointSize - 1)) } }

    private func align(_ a: NSTextAlignment) {
        editParagraphs { $0.alignment = a }
    }

    @objc func alignLeftMenu(_ sender: Any?) { align(.left) }
    @objc func alignCentreMenu(_ sender: Any?) { align(.center) }
    @objc func alignRightMenu(_ sender: Any?) { align(.right) }
    @objc func justifyMenu(_ sender: Any?) { align(.justified) }

    @objc func setSpacing(_ sender: NSMenuItem) {
        let m = CGFloat(sender.tag) / 100
        editParagraphs { $0.lineHeightMultiple = m }
    }

    @objc func applyStyle(_ sender: Any?) {
        let title = (sender as? NSMenuItem)?.title ?? "Normal"
        guard let kind = WordStyles.Kind(rawValue: title), let ts = textView.textStorage else { return }
        let ns = ts.string as NSString
        let pr = ns.paragraphRange(for: textView.selectedRange())
        let font = WordStyles.font(kind, body)
        if pr.length > 0, textView.shouldChangeText(in: pr, replacementString: nil) {
            ts.beginEditing()
            ts.addAttribute(.font, value: font, range: pr)
            var loc = pr.location
            while loc < NSMaxRange(pr) {
                let p = ns.paragraphRange(for: NSRange(location: loc, length: 0))
                let base = ts.attribute(.paragraphStyle, at: p.location, effectiveRange: nil) as? NSParagraphStyle
                ts.addAttribute(.paragraphStyle, value: WordStyles.paragraph(kind, base: base), range: p)
                loc = NSMaxRange(p)
            }
            ts.endEditing()
            textView.didChangeText()
        }
        textView.typingAttributes[.font] = font
        textView.typingAttributes[.paragraphStyle] = WordStyles.paragraph(kind, base: textView.typingAttributes[.paragraphStyle] as? NSParagraphStyle)
        refreshToolbar()
        screen.window?.makeFirstResponder(textView)
    }

    @objc func pickFont(_ sender: NSMenuItem) {
        let family = sender.title
        editFonts { NSFontManager.shared.convert($0, toFamily: family) }
    }

    @objc func pickSize(_ sender: NSMenuItem) {
        let size = CGFloat(Double(sender.title) ?? 12)
        editFonts { NSFontManager.shared.convert($0, toSize: size) }
    }

    @objc func bulletList(_ sender: Any?) { toggleList(.disc) }
    @objc func numberedList(_ sender: Any?) { toggleList(.decimal) }

    /// Turns the selected paragraphs into a list, or back into plain paragraphs.
    private func toggleList(_ format: NSTextList.MarkerFormat) {
        let tv = textView
        guard let ts = tv.textStorage else { return }
        var ns = ts.string as NSString
        let all = ns.paragraphRange(for: tv.selectedRange())
        var paras: [NSRange] = []
        var loc = all.location
        repeat {
            let pr = ns.paragraphRange(for: NSRange(location: loc, length: 0))
            paras.append(pr)
            loc = NSMaxRange(pr)
        } while loc < NSMaxRange(all)

        let existing = paras.compactMap { pr -> NSTextList? in
            guard pr.location < ts.length else { return nil }
            return (ts.attribute(.paragraphStyle, at: pr.location, effectiveRange: nil) as? NSParagraphStyle)?.textLists.first
        }
        let removing = existing.count == paras.count && existing.allSatisfy { $0.markerFormat == format }
        let list = NSTextList(markerFormat: format, options: 0)

        guard tv.shouldChangeText(in: all, replacementString: nil) else { return }
        ts.beginEditing()
        for (i, pr0) in paras.enumerated().reversed() {
            ns = ts.string as NSString
            var pr = pr0
            // Strip an old marker ("\t•\t" or "\t1.\t").
            if pr.length > 0, ns.character(at: pr.location) == 9 {
                let second = ns.range(of: "\t", options: [], range: NSRange(location: pr.location + 1, length: min(12, pr.length - 1)))
                if second.location != NSNotFound {
                    let cut = NSRange(location: pr.location, length: second.location + 1 - pr.location)
                    ts.deleteCharacters(in: cut)
                    pr.length -= cut.length
                }
            }
            let base = pr.location < ts.length ? ts.attribute(.paragraphStyle, at: pr.location, effectiveRange: nil) as? NSParagraphStyle : nil
            let p = (base?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
            if removing {
                p.textLists = []
                p.headIndent = 0
                p.firstLineHeadIndent = 0
                p.tabStops = []
            } else {
                p.textLists = [list]
                p.headIndent = 36
                p.firstLineHeadIndent = 0
                p.tabStops = [NSTextTab(textAlignment: .left, location: 18), NSTextTab(textAlignment: .left, location: 36)]
                let marker = "\t" + list.marker(forItemNumber: i + 1) + "\t"
                let attrs = pr.location < ts.length ? ts.attributes(at: pr.location, effectiveRange: nil) : tv.typingAttributes
                ts.insert(NSAttributedString(string: marker, attributes: attrs), at: pr.location)
                pr.length += (marker as NSString).length
            }
            if pr.length > 0 { ts.addAttribute(.paragraphStyle, value: p, range: pr) }
            if i == paras.count - 1 { tv.typingAttributes[.paragraphStyle] = p }
        }
        ts.endEditing()
        tv.didChangeText()
        refreshToolbar()
        screen.window?.makeFirstResponder(tv)
    }

    private func popStyles(_ b: MonoButton) {
        let m = NSMenu()
        for k in WordStyles.Kind.allCases { m.addItem(.mono(k.rawValue, #selector(applyStyle(_:)), "", [], target: self)) }
        b.popUp(m)
    }

    private func popFonts(_ b: MonoButton) { b.popUp(fontMenu()) }

    private func fontMenu() -> NSMenu {
        let m = NSMenu(title: "Font")
        let available = Set(NSFontManager.shared.availableFontFamilies)
        for f in WordStyles.favouriteFonts where available.contains(f) {
            m.addItem(.mono(f, #selector(pickFont(_:)), "", [], target: self))
        }
        m.addItem(.separator())
        let all = NSFontManager.shared.availableFontFamilies.filter { !$0.hasPrefix(".") }.sorted()
        m.addItem(.submenu("All Fonts", all.map { NSMenuItem.mono($0, #selector(pickFont(_:)), "", [], target: self) }))
        return m
    }

    private func popSizes(_ b: MonoButton) { b.popUp(sizeMenu()) }

    private func sizeMenu() -> NSMenu {
        let m = NSMenu(title: "Size")
        for s in ["8", "9", "10", "11", "12", "14", "16", "18", "20", "24", "28", "36", "48", "72"] {
            m.addItem(.mono(s, #selector(pickSize(_:)), "", [], target: self))
        }
        return m
    }

    // MARK: Zoom

    static let zoomSteps: [CGFloat] = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2, 2.5, 3, 4]

    /// Keeps the page as wide as the visible area at the current zoom, so it stays centred.
    @objc private func fitWidth() {
        let w = max(scroll.contentView.bounds.width, MonoPageView.pageWidth + 24)
        if abs(textView.frame.width - w) > 0.5 {
            textView.setFrameSize(NSSize(width: w, height: textView.frame.height))
            textView.updateInsets()
            textView.needsDisplay = true
        }
    }

    private func setZoom(_ z: CGFloat) {
        let z = min(4, max(0.5, z))
        let top = scroll.contentView.bounds.minY
        scroll.magnification = z
        fitWidth()
        scroll.contentView.scroll(to: NSPoint(x: 0, y: top))
        scroll.reflectScrolledClipView(scroll.contentView)
        zoomLabel.stringValue = "\(Int((z * 100).rounded()))%"
        UserDefaults.standard.set(Double(z), forKey: "wordZoom")
    }

    @objc func zoomIn(_ sender: Any?) {
        setZoom(Self.zoomSteps.first { $0 > scroll.magnification + 0.01 } ?? 4)
    }

    @objc func zoomOut(_ sender: Any?) {
        setZoom(Self.zoomSteps.last { $0 < scroll.magnification - 0.01 } ?? 0.5)
    }

    @objc func actualSize(_ sender: Any?) { setZoom(1.5) }

    /// Called once the screen is on display, so the zoom is applied to the real window size.
    func applyStartZoom() {
        let saved = UserDefaults.standard.double(forKey: "wordZoom")
        setZoom(saved > 0 ? CGFloat(saved) : 1.5)
        textView.scrollRangeToVisible(textView.selectedRange())
    }

    // MARK: Files

    func saveFromMenu() { saveDocument(nil) }

    @objc func saveDocument(_ sender: Any?) {
        save(then: nil)
    }

    private func save(then done: ((Bool) -> Void)?) {
        guard existing, type != nil, !confirmedOverwrite, let window = screen.window else {
            let ok = writeNow()
            done?(ok)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Save over \(name)?"
        alert.informativeText = "Text, fonts, styles, lists and tables are kept. Comments and tracked changes from Word are not."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Save a Copy")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] r in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch r {
                case .alertFirstButtonReturn:
                    self.confirmedOverwrite = true
                    let ok = self.writeNow()
                    done?(ok)
                case .alertSecondButtonReturn:
                    self.url = self.copyURL()
                    self.confirmedOverwrite = true
                    let ok = self.writeNow()
                    done?(ok)
                default:
                    done?(false)
                }
            }
        }
    }

    private func copyURL() -> URL {
        let dir = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var n = 1
        var candidate = dir.appendingPathComponent("\(base) (Minimalia).\(ext)")
        while FileManager.default.fileExists(atPath: candidate.path) {
            n += 1
            candidate = dir.appendingPathComponent("\(base) (Minimalia \(n)).\(ext)")
        }
        return candidate
    }

    @discardableResult
    func writeNow() -> Bool {
        guard let ts = textView.textStorage else { return false }
        do {
            let content = NSAttributedString(attributedString: ts)
            if let type {
                try DocumentIO.writeAttributed(content, to: url, type: type, meta: meta)
            } else {
                try Data(content.string.utf8).write(to: url, options: .atomic)
            }
            dirty = false
            flash("Saved \(name)")
            return true
        } catch {
            flash("Could not save: \(error.localizedDescription)")
            return false
        }
    }

    @objc func saveDocumentAs(_ sender: Any?) {
        guard let window = screen.window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "docx")!, .init(filenameExtension: "doc")!,
                                     .init(filenameExtension: "odt")!, .rtf, .plainText]
        panel.nameFieldStringValue = name
        panel.directoryURL = url.deletingLastPathComponent()
        panel.beginSheetModal(for: window) { [weak self] r in
            MainActor.assumeIsolated {
                guard let self, r == .OK, let u = panel.url else { return }
                self.url = u
                switch u.pathExtension.lowercased() {
                case "docx": self.type = .officeOpenXML
                case "doc": self.type = .docFormat
                case "odt": self.type = .openDocument
                case "rtf": self.type = .rtf
                default: self.type = nil
                }
                self.confirmedOverwrite = true
                self.writeNow()
            }
        }
    }

    private func pageView(_ info: NSPrintInfo) -> NSTextView {
        let width = info.paperSize.width - info.leftMargin - info.rightMargin
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
        view.textStorage?.setAttributedString(NSAttributedString(attributedString: textView.textStorage!))
        view.backgroundColor = .white
        view.appearance = NSAppearance(named: .aqua)
        if let lm = view.layoutManager, let tc = view.textContainer {
            tc.size = NSSize(width: width, height: .greatestFiniteMagnitude)
            lm.ensureLayout(for: tc)
            view.setFrameSize(NSSize(width: width, height: ceil(lm.usedRect(for: tc).height) + 20))
        }
        return view
    }

    private func printInfo() -> NSPrintInfo {
        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        info.topMargin = 72
        info.bottomMargin = 72
        info.leftMargin = 72
        info.rightMargin = 72
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        return info
    }

    @objc func printDocument(_ sender: Any?) {
        guard let window = screen.window else { return }
        let info = printInfo()
        let op = NSPrintOperation(view: pageView(info), printInfo: info)
        op.jobTitle = url.deletingPathExtension().lastPathComponent
        op.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    @objc func exportPDF(_ sender: Any?) {
        guard let window = screen.window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = url.deletingPathExtension().lastPathComponent + ".pdf"
        panel.directoryURL = url.deletingLastPathComponent()
        panel.beginSheetModal(for: window) { [weak self] r in
            MainActor.assumeIsolated {
                guard let self, r == .OK, let out = panel.url else { return }
                let info = self.printInfo()
                info.jobDisposition = .save
                info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = out
                let op = NSPrintOperation(view: self.pageView(info), printInfo: info)
                op.showsPrintPanel = false
                op.showsProgressPanel = false
                op.run()
                self.flash("Exported \(out.lastPathComponent)")
            }
        }
    }

    @objc func closeDocument(_ sender: Any?) {
        guard dirty, let window = screen.window else { exit(); return }
        let alert = NSAlert()
        alert.messageText = "Save changes to \(name)?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] r in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch r {
                case .alertFirstButtonReturn: self.save { ok in if ok { self.exit() } }
                case .alertSecondButtonReturn: self.exit()
                default: break
                }
            }
        }
    }

    @objc func toggleSpelling(_ sender: Any?) {
        textView.isContinuousSpellCheckingEnabled.toggle()
        flash(textView.isContinuousSpellCheckingEnabled ? "Spelling is checked as you type" : "Spelling check off")
    }

    private func exit() {
        countTimer?.invalidate()
        let c = onExit
        onExit = nil
        c?()
    }

    // MARK: Menus

    func makeMenus() -> [NSMenu] {
        func menu(_ title: String, _ items: [NSMenuItem]) -> NSMenu {
            let m = NSMenu(title: title)
            items.forEach(m.addItem)
            m.appearance = MonoPalette.current.appearance
            return m
        }
        let me: AnyObject = self
        let file = menu("File", [
            .mono("Save", #selector(saveDocument(_:)), "s", target: me),
            .mono("Save As\u{2026}", #selector(saveDocumentAs(_:)), "s", [.command, .shift], target: me),
            .mono("Export as PDF\u{2026}", #selector(exportPDF(_:)), "e", [.command, .shift], target: me),
            .mono("Print\u{2026}", #selector(printDocument(_:)), "p", target: me),
            .separator(),
            .mono("Close Document", #selector(closeDocument(_:)), "w", target: me),
        ])
        let edit = menu("Edit", [
            .mono("Undo", Selector(("undo:")), "z"),
            .mono("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            .mono("Cut", #selector(NSText.cut(_:)), "x"),
            .mono("Copy", #selector(NSText.copy(_:)), "c"),
            .mono("Paste", #selector(NSText.paste(_:)), "v"),
            .mono("Paste and Match Style", #selector(NSTextView.pasteAsPlainText(_:)), "v", [.command, .option, .shift]),
            .mono("Select All", #selector(NSText.selectAll(_:)), "a"),
            .separator(),
            .mono("Find\u{2026}", #selector(NSTextView.performFindPanelAction(_:)), "f", tag: 1),
            .mono("Find and Replace\u{2026}", #selector(NSTextView.performFindPanelAction(_:)), "f", [.command, .option], tag: 12),
            .mono("Find Next", #selector(NSTextView.performFindPanelAction(_:)), "g", tag: 2),
            .separator(),
            .mono("Check Spelling While Typing", #selector(toggleSpelling(_:)), "", target: me),
            .mono("Check Document Now", #selector(NSText.checkSpelling(_:)), ";"),
        ])
        let styleItems = WordStyles.Kind.allCases.enumerated().map { i, k in
            NSMenuItem.mono(k.rawValue, #selector(applyStyle(_:)), "\(i)", [.command, .option], target: me)
        }
        let spacing = [("Single", 100), ("1.15", 115), ("1.5", 150), ("Double", 200)].map { t, v in
            NSMenuItem.mono(t, #selector(setSpacing(_:)), "", [], tag: v, target: me)
        }
        let format = menu("Format", [
            .mono("Bold", #selector(toggleBold(_:)), "b", target: me),
            .mono("Italic", #selector(toggleItalic(_:)), "i", target: me),
            .mono("Underline", #selector(toggleUnderline(_:)), "u", target: me),
            .separator(),
            .submenu("Style", styleItems),
            .submenu("Font", fontMenu().items.map { $0.copy() as! NSMenuItem }),
            .submenu("Size", sizeMenu().items.map { $0.copy() as! NSMenuItem }),
            .mono("Bigger", #selector(biggerFont(_:)), "]", target: me),
            .mono("Smaller", #selector(smallerFont(_:)), "[", target: me),
            .separator(),
            .mono("Align Left", #selector(alignLeftMenu(_:)), "{", target: me),
            .mono("Centre", #selector(alignCentreMenu(_:)), "|", target: me),
            .mono("Align Right", #selector(alignRightMenu(_:)), "}", target: me),
            .mono("Justify", #selector(justifyMenu(_:)), "", target: me),
            .separator(),
            .mono("Bulleted List", #selector(bulletList(_:)), "l", [.command, .shift], target: me),
            .mono("Numbered List", #selector(numberedList(_:)), "", target: me),
            .submenu("Line Spacing", spacing),
        ])
        let view = menu("View", [
            .mono("Zoom In", #selector(zoomIn(_:)), "=", target: me),
            .mono("Zoom Out", #selector(zoomOut(_:)), "-", target: me),
            .mono("Reading Size (150%)", #selector(actualSize(_:)), "0", target: me),
        ])
        return [file, edit, format, view]
    }
}
