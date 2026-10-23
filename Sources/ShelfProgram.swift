import AppKit

/// A text view that only displays; clicks and keys go to the reader around it.
final class PageTextView: NSTextView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The page-turning reader: a single page, or a two-page spread on wide screens.
final class BookReaderView: NSView {
    let book: Book
    private let raw: String
    private let storage = NSTextStorage()
    private let lm = NSLayoutManager()
    private var containers: [NSTextContainer] = []
    private var views: [Int: PageTextView] = [:]
    private var chapters: [(String, Int)] = []
    private var finished = false
    private var pageSize = NSSize.zero
    private var spread = false
    private var first = 0
    private var anchor: Int
    private var swipe: CGFloat = 0
    private let header = NSTextField(labelWithString: "")
    private let footer = NSTextField(labelWithString: "")
    private var prefs = ReaderPrefs.load()
    private var corner: [MonoButton] = []

    var onExit: (() -> Void)?
    var onPosition: ((Int, Int) -> Void)?

    init(book: Book, text: String, position: Int) {
        self.book = book
        raw = text
        anchor = position
        super.init(frame: .zero)
        wantsLayer = true
        storage.addLayoutManager(lm)
        for l in [header, footer] {
            l.font = .systemFont(ofSize: 12)
            l.alignment = .center
            l.lineBreakMode = .byTruncatingTail
            addSubview(l)
        }
        // Reading controls in the top right corner, as on an e-reader.
        corner = [
            MonoButton("", symbol: "list.bullet", help: "Contents") { [weak self] _ in self?.showContents() },
            MonoButton("", symbol: "book", help: "One page or two") { [weak self] _ in self?.togglePages() },
            MonoButton("Aa", help: "Text and page settings") { [weak self] b in self?.showOptions(b) },
        ]
        corner.forEach(addSubview)
        typeset()
        NotificationCenter.default.addObserver(self, selector: #selector(restyle), name: .minimaliaAppearance, object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    private func typeset() {
        let c = prefs.colours
        let (text, ch) = BookFormatter.format(raw, book: book, prefs: prefs, ink: c.ink, dim: c.dim)
        storage.setAttributedString(text)
        chapters = ch
        resetPages()
        restyle()
    }

    @objc private func restyle() {
        let c = prefs.colours
        layer?.backgroundColor = c.bg.cgColor
        header.textColor = c.dim
        footer.textColor = c.dim
        let light = c.bg.usingColorSpace(.sRGB).map { $0.redComponent > 0.5 } ?? false
        for b in corner {
            b.inkOverride = c.dim
            b.hoverOverride = light ? NSColor(white: 0, alpha: 0.08) : NSColor(white: 1, alpha: 0.08)
        }
    }

    /// Re-sets the book after a change of settings, keeping the reader's place.
    private func apply(_ change: (inout ReaderPrefs) -> Void) {
        let keep = containers.isEmpty ? anchor : charStart(ofPage: first)
        change(&prefs)
        prefs.save()
        anchor = keep
        let c = prefs.colours
        let (text, ch) = BookFormatter.format(raw, book: book, prefs: prefs, ink: c.ink, dim: c.dim)
        storage.setAttributedString(text)
        chapters = ch
        restyle()
        pageSize = .zero
        needsLayout = true
    }

    private func togglePages() {
        apply { $0.pages = spread ? 1 : 2 }
    }

    private func showOptions(_ b: MonoButton) {
        let m = NSMenu()
        m.appearance = MonoPalette.current.appearance
        func item(_ title: String, _ on: Bool, _ action: @escaping () -> Void) -> NSMenuItem {
            let i = ClosureMenuItem(title: title, action: action)
            i.state = on ? .on : .off
            return i
        }
        func sub(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let s = NSMenu(title: title)
            items.forEach(s.addItem)
            i.submenu = s
            return i
        }
        let available = Set(NSFontManager.shared.availableFontFamilies)
        m.addItem(sub("Typeface", ReaderPrefs.fonts.filter { $0 == "New York" || available.contains($0) }.map { f in
            item(f, prefs.font == f) { [weak self] in self?.apply { $0.font = f } }
        }))
        m.addItem(item("Larger Text", false) { [weak self] in self?.resize(by: 1) })
        m.addItem(item("Smaller Text", false) { [weak self] in self?.resize(by: -1) })
        m.addItem(.separator())
        m.addItem(sub("Line Spacing", [("Compact", 1.15), ("Normal", 1.32), ("Relaxed", 1.6)].map { t, v in
            item(t, abs(prefs.spacing - v) < 0.01) { [weak self] in self?.apply { $0.spacing = v } }
        }))
        m.addItem(sub("Margins", [("Narrow", 0), ("Normal", 1), ("Wide", 2)].map { t, v in
            item(t, prefs.margin == v) { [weak self] in self?.apply { $0.margin = v } }
        }))
        m.addItem(item("Justified", prefs.justify) { [weak self] in self?.apply { $0.justify.toggle() } })
        m.addItem(.separator())
        m.addItem(sub("Pages", [("Automatic", 0), ("One Page", 1), ("Two Pages", 2)].map { t, v in
            item(t, prefs.pages == v) { [weak self] in self?.apply { $0.pages = v } }
        }))
        m.addItem(sub("Page Colour", ReaderPrefs.pageColours.map { name in
            item(name, prefs.page == name) { [weak self] in self?.apply { $0.page = name } }
        }))
        m.popUp(positioning: nil, at: NSPoint(x: b.frame.maxX - 200, y: b.frame.maxY + 6), in: self)
    }

    // MARK: Pages

    private func resetPages() {
        views.values.forEach { $0.removeFromSuperview() }
        views.removeAll()
        while !lm.textContainers.isEmpty { lm.removeTextContainer(at: 0) }
        containers.removeAll()
        finished = false
    }

    private func addPage() -> Bool {
        guard !finished, pageSize.width > 0 else { return false }
        let tc = NSTextContainer(size: pageSize)
        tc.lineFragmentPadding = 0
        lm.addTextContainer(tc)
        containers.append(tc)
        let g = lm.glyphRange(for: tc)
        if NSMaxRange(g) >= lm.numberOfGlyphs || g.length == 0 && containers.count > 1 { finished = true }
        return true
    }

    private func ensure(page: Int) {
        while containers.count <= page && addPage() {}
    }

    private func page(forChar c: Int) -> Int {
        let target = min(c, max(0, storage.length - 1))
        var i = 0
        while true {
            ensure(page: i)
            guard i < containers.count else { return max(0, containers.count - 1) }
            let chars = lm.characterRange(forGlyphRange: lm.glyphRange(for: containers[i]), actualGlyphRange: nil)
            if NSMaxRange(chars) > target || finished && i == containers.count - 1 { return i }
            i += 1
        }
    }

    private func charStart(ofPage i: Int) -> Int {
        guard i < containers.count else { return storage.length }
        return lm.characterRange(forGlyphRange: lm.glyphRange(for: containers[i]), actualGlyphRange: nil).location
    }

    override func layout() {
        super.layout()
        let size = prefs.size
        let topMargin: CGFloat = max(56, bounds.height * 0.07)
        let height = max(200, bounds.height - topMargin * 2)
        let measure: CGFloat = [38, 32, 27][max(0, min(2, prefs.margin))]
        let width = min(size * measure, bounds.width - 120)
        let fitsTwo = bounds.width >= width * 2 + 200
        let twoUp = prefs.pages == 1 ? false : (prefs.pages == 2 ? fitsTwo || bounds.width >= width * 1.6 : fitsTwo)
        let newSize = NSSize(width: floor(width), height: floor(height))
        if newSize != pageSize || twoUp != spread {
            let keep = containers.isEmpty ? anchor : charStart(ofPage: first)
            pageSize = newSize
            spread = twoUp
            resetPages()
            anchor = keep
            first = page(forChar: keep)
            if spread && first % 2 == 1 { first -= 1 }
        }
        let hf = NSRect(x: 40, y: topMargin * 0.35, width: bounds.width - 80, height: 18)
        let ff = NSRect(x: 40, y: bounds.height - topMargin * 0.35 - 18, width: bounds.width - 80, height: 18)
        if header.frame != hf { header.frame = hf }
        if footer.frame != ff { footer.frame = ff }
        var x = bounds.width - 24
        for b in corner.reversed() {
            let w = b.intrinsicContentSize.width
            x -= w
            let f = NSRect(x: x, y: topMargin * 0.35 - 5, width: w, height: 26)
            if b.frame != f { b.frame = f }
            x -= 4
        }
        DispatchQueue.main.async { [weak self] in self?.show() }
    }

    private func show() {
        let topMargin = max(56, bounds.height * 0.07)
        let pages = spread ? [first, first + 1] : [first]
        for (i, v) in views where !pages.contains(i) && v.superview != nil { v.removeFromSuperview() }
        let gutter: CGFloat = 96
        let total = spread ? pageSize.width * 2 + gutter : pageSize.width
        var x = floor((bounds.width - total) / 2)
        for i in pages {
            ensure(page: i)
            if i < containers.count {
                let v = views[i] ?? {
                    let tv = PageTextView(frame: .zero, textContainer: containers[i])
                    tv.isEditable = false
                    tv.isSelectable = false
                    tv.drawsBackground = false
                    tv.textContainerInset = .zero
                    views[i] = tv
                    return tv
                }()
                let frame = NSRect(x: x, y: topMargin, width: pageSize.width, height: pageSize.height)
                if v.frame != frame { v.frame = frame }
                if v.superview !== self { addSubview(v) }
            }
            x += pageSize.width + gutter
        }
        updateLabels()
    }

    private func updateLabels() {
        let start = charStart(ofPage: first)
        let chapter = chapters.last { $0.1 <= start }?.0
        header.stringValue = [book.title, chapter].compactMap { $0 }.joined(separator: "   \u{00B7}   ")
        let pct = storage.length > 0 ? Int((Double(start) / Double(storage.length) * 100).rounded()) : 0
        let pageText = spread ? "pages \(first + 1)\u{2013}\(first + 2)" : "page \(first + 1)"
        footer.stringValue = "\(pageText)   \u{00B7}   \(pct)%"
        onPosition?(start, storage.length)
    }

    func next() {
        let step = spread ? 2 : 1
        ensure(page: first + step)
        guard first + step < containers.count else { return }
        first += step
        show()
    }

    func previous() {
        let step = spread ? 2 : 1
        guard first > 0 else { return }
        first = max(0, first - step)
        show()
    }

    /// Opens at a passage: the first place `start` appears after the heading `reference`.
    func open(at passage: Passage) {
        let text = storage.string as NSString
        let head = text.range(of: passage.reference + "\n")
        let from = head.location == NSNotFound ? 0 : head.location
        let r = text.range(of: passage.start, range: NSRange(location: from, length: text.length - from))
        if r.location != NSNotFound { anchor = r.location } else if head.location != NSNotFound { anchor = head.location }
    }

    func go(toChar c: Int) {
        first = page(forChar: c)
        if spread && first % 2 == 1 { first -= 1 }
        show()
    }

    func resize(by delta: CGFloat) {
        apply { $0.size = min(40, max(14, $0.size + delta)) }
    }

    func showContents() {
        let m = NSMenu()
        m.appearance = MonoPalette.current.appearance
        if chapters.isEmpty {
            m.addItem(NSMenuItem(title: "No chapters found", action: nil, keyEquivalent: ""))
        }
        for (i, c) in chapters.prefix(300).enumerated() {
            let item = NSMenuItem(title: c.0, action: #selector(jump(_:)), keyEquivalent: "")
            item.target = self
            item.tag = i
            m.addItem(item)
        }
        m.popUp(positioning: nil, at: NSPoint(x: header.frame.midX - 120, y: header.frame.maxY + 4), in: self)
    }

    @objc private func jump(_ sender: NSMenuItem) {
        guard sender.tag < chapters.count else { return }
        go(toChar: chapters[sender.tag].1)
    }

    // MARK: Input

    override func keyDown(with e: NSEvent) {
        NSCursor.setHiddenUntilMouseMoves(true)
        let flags = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) { super.keyDown(with: e); return }
        switch e.keyCode {
        case 124, 125, 49, 121: next()
        case 123, 126, 116: previous()
        case 53: onExit?()
        case 115: go(toChar: 0)
        default:
            switch e.charactersIgnoringModifiers?.lowercased() ?? "" {
            case "=", "+": resize(by: 1)
            case "-": resize(by: -1)
            case "t", "c": showContents()
            default: break
            }
        }
    }

    override func mouseUp(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        if p.y < bounds.height * 0.07 { showContents(); return }
        if p.x > bounds.width * 0.4 { next() } else { previous() }
    }

    override func scrollWheel(with e: NSEvent) {
        if e.phase == .began { swipe = 0 }
        swipe += e.scrollingDeltaX
        if e.phase == .ended || e.momentumPhase == .ended || (e.phase == [] && e.momentumPhase == []) {
            if swipe < -30 { next() } else if swipe > 30 { previous() }
            swipe = 0
        }
    }
}

/// Minimalia Shelf: Project Gutenberg's free library, organised into shelves, read a page at a time.
@MainActor
final class ShelfProgram: NSObject, MinimaliaProgram, NSTableViewDataSource, NSTableViewDelegate {
    let screen = NSView()
    private let topBar = MonoBar()
    private let statusBar = MonoBar(lineAtBottom: false)
    private let search = AddressField()
    private let sidebar = NSStackView()
    private let table = ShelfTable()
    private let tableScroll = NSScrollView()
    private var statusLabel: NSTextField!
    private var languageButton: MonoButton!
    private var sectionButtons: [MonoButton] = []
    private var reader: BookReaderView?

    private var all: [Book] = []
    private var rank: [Int: Int] = [:]
    private var rows: [Book] = []
    private var section = "Reading now"
    private var initialQuery: String?
    private var initialPassage: Passage?

    var onExit: (() -> Void)?
    var focusView: NSView { table }

    static let categories: [(String, [String])] = [
        ("Classics", ["Classics of Literature"]),
        ("Novels", ["Novels"]),
        ("Adventure", ["Adventure"]),
        ("Crime and mystery", ["Crime, Thrillers and Mystery"]),
        ("Science fiction", ["Science-Fiction & Fantasy"]),
        ("Romance", ["Romance"]),
        ("Historical novels", ["Historical Novels"]),
        ("Short stories", ["Short Stories"]),
        ("Poetry", ["Poetry"]),
        ("Plays", ["Plays/Films/Dramas"]),
        ("Children and young adults", ["Children & Young Adult Reading"]),
        ("Humour", ["Humour"]),
        ("Biographies", ["Biographies"]),
        ("History", ["History - "]),
        ("Philosophy", ["Philosophy & Ethics"]),
        ("Religion and spirituality", ["Religion/Spirituality"]),
        ("Essays and letters", ["Essays, Letters & Speeches"]),
        ("Travel", ["Travel Writing"]),
        ("Myths and folklore", ["Mythology, Legends & Folklore"]),
        ("Nature", ["Nature/Gardening/Animals"]),
        ("Science", ["Science - "]),
        ("Art", ["Art"]),
    ]

    static let languages: [(String, String)] = [
        ("English", "en"), ("French", "fr"), ("German", "de"), ("Spanish", "es"), ("Portuguese", "pt"),
        ("Italian", "it"), ("Dutch", "nl"), ("Finnish", "fi"), ("All languages", ""),
    ]

    private var language: String {
        get { UserDefaults.standard.string(forKey: "shelfLanguage") ?? "en" }
        set { UserDefaults.standard.set(newValue, forKey: "shelfLanguage") }
    }

    init(query: String?, passage: Passage? = nil) {
        initialQuery = query
        initialPassage = passage
        super.init()
        build()
        Task { @MainActor in
            // A passage from FIND opens straight away; the library loads behind it.
            if let p = self.initialPassage {
                self.all = Scripture.books
                self.select(p.scripture)
                self.openExcerpt(p)
            } else {
                self.status("Opening the library\u{2026}")
            }
            self.all = Scripture.books + (await Gutenberg.catalog())
            let top = await Gutenberg.topIDs()
            for (i, id) in top.enumerated() { self.rank[id] = i }
            if self.initialPassage != nil {
                return
            } else if let q = self.initialQuery, !q.isEmpty {
                self.search.stringValue = q
                self.runSearch(q)
            } else {
                self.select(ShelfStore.shared.reading.isEmpty ? "Most read" : "Reading now")
            }
        }
    }

    // MARK: Building

    private func build() {
        let p = MonoPalette.current
        screen.wantsLayer = true
        screen.layer?.backgroundColor = p.desk.cgColor
        screen.appearance = p.appearance

        let title = topBar.label("Shelf")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        topBar.add(title)
        let gap = NSView()
        gap.widthAnchor.constraint(equalToConstant: 140).isActive = true
        topBar.add(gap)
        search.placeholderString = "Search 75,000 free books by title or author"
        search.isBordered = false
        search.isBezeled = false
        search.drawsBackground = true
        search.backgroundColor = p.page
        search.textColor = p.ink
        search.font = .systemFont(ofSize: 14)
        search.focusRingType = .none
        search.usesSingleLineMode = true
        search.target = self
        search.action = #selector(searchEntered(_:))
        search.onEscape = { [weak self] in
            guard let self else { return }
            self.search.stringValue = ""
            self.screen.window?.makeFirstResponder(self.table)
        }
        let field = NSView()
        field.wantsLayer = true
        field.layer?.backgroundColor = p.page.cgColor
        field.layer?.borderColor = p.edge.cgColor
        field.layer?.borderWidth = 1
        field.layer?.cornerRadius = 4
        search.translatesAutoresizingMaskIntoConstraints = false
        field.addSubview(search)
        NSLayoutConstraint.activate([
            search.leadingAnchor.constraint(equalTo: field.leadingAnchor, constant: 10),
            search.trailingAnchor.constraint(equalTo: field.trailingAnchor, constant: -10),
            search.centerYAnchor.constraint(equalTo: field.centerYAnchor),
            field.heightAnchor.constraint(equalToConstant: 28),
        ])
        field.setContentHuggingPriority(.init(1), for: .horizontal)
        topBar.add(field)
        let langName = Self.languages.first { $0.1 == language }?.0 ?? "English"
        languageButton = MonoButton(langName, dropdown: true, help: "Language") { [weak self] b in self?.popLanguages(b) }
        languageButton.minWidth = 130
        topBar.add(languageButton)

        // Shelves down the left.
        sidebar.orientation = .vertical
        sidebar.alignment = .leading
        sidebar.spacing = 1
        sidebar.edgeInsets = NSEdgeInsets(top: 14, left: 10, bottom: 14, right: 10)
        func addSection(_ name: String) {
            let b = MonoButton(name) { [weak self] _ in self?.select(name) }
            b.minWidth = 210
            sectionButtons.append(b)
            sidebar.addArrangedSubview(b)
        }
        func addHeading(_ name: String) {
            let l = NSTextField(labelWithString: name.uppercased())
            l.font = .systemFont(ofSize: 11, weight: .semibold)
            l.textColor = p.dim
            let wrap = NSView()
            l.translatesAutoresizingMaskIntoConstraints = false
            wrap.addSubview(l)
            NSLayoutConstraint.activate([
                l.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 8),
                l.bottomAnchor.constraint(equalTo: wrap.bottomAnchor, constant: -4),
                wrap.heightAnchor.constraint(equalToConstant: 30),
            ])
            sidebar.addArrangedSubview(wrap)
        }
        addSection("Reading now")
        addSection("On this Mac")
        addHeading("Library")
        addSection("Most read")
        for (name, _) in Self.categories { addSection(name) }
        if !Scripture.all.isEmpty {
            addHeading("Sacred texts")
            for s in Scripture.all { addSection(s.shelf) }
        }
        let sideScroll = NSScrollView()
        sideScroll.documentView = sidebar
        sideScroll.drawsBackground = false
        sideScroll.hasVerticalScroller = true
        sideScroll.autohidesScrollers = true
        sideScroll.scrollerStyle = .overlay
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            sidebar.topAnchor.constraint(equalTo: sideScroll.contentView.topAnchor),
            sidebar.leadingAnchor.constraint(equalTo: sideScroll.contentView.leadingAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 240),
        ])
        let flip = FlippedClip()
        flip.drawsBackground = false
        sideScroll.contentView = flip
        sideScroll.documentView = sidebar

        // The book list.
        let col = NSTableColumn(identifier: .init("book"))
        table.addTableColumn(col)
        table.headerView = nil
        table.rowHeight = 54
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.backgroundColor = p.desk
        table.selectionHighlightStyle = .regular
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openSelected(_:))
        table.onOpen = { [weak self] in self?.openSelected(nil) }
        table.onEscape = { [weak self] in self?.exit() }
        table.onType = { [weak self] s in
            guard let self else { return }
            self.screen.window?.makeFirstResponder(self.search)
            self.search.stringValue = s
            self.search.currentEditor()?.selectedRange = NSRange(location: (s as NSString).length, length: 0)
        }
        tableScroll.documentView = table
        tableScroll.drawsBackground = true
        tableScroll.backgroundColor = p.desk
        tableScroll.hasVerticalScroller = true
        tableScroll.autohidesScrollers = true
        tableScroll.scrollerStyle = .overlay
        tableScroll.scrollerKnobStyle = p.isDark ? .light : .dark

        statusLabel = statusBar.label()
        statusBar.add(statusLabel)
        statusBar.addSpacer()
        let hint = statusBar.label("\u{2191}\u{2193} choose   Return reads   Type to search   Esc returns to the prompt")
        hint.textColor = p.dim
        statusBar.add(hint)

        let divider = MonoDivider()
        for v in [topBar, sideScroll, divider, tableScroll, statusBar] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            screen.addSubview(v)
        }
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: screen.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: screen.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: screen.trailingAnchor),
            topBar.heightAnchor.constraint(equalToConstant: 46),
            sideScroll.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            sideScroll.leadingAnchor.constraint(equalTo: screen.leadingAnchor),
            sideScroll.widthAnchor.constraint(equalToConstant: 260),
            sideScroll.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            divider.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: sideScroll.trailingAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
            divider.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            tableScroll.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            tableScroll.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            tableScroll.trailingAnchor.constraint(equalTo: screen.trailingAnchor),
            tableScroll.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            statusBar.leadingAnchor.constraint(equalTo: screen.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: screen.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: screen.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: 28),
        ])
    }

    private func status(_ text: String) { statusLabel.stringValue = text }

    // MARK: Shelves

    private func inLanguage(_ b: Book) -> Bool { language.isEmpty || b.language == language }

    private func ordered(_ books: [Book]) -> [Book] {
        books.sorted { a, b in
            let ra = rank[a.id] ?? Int.max
            let rb = rank[b.id] ?? Int.max
            if ra != rb { return ra < rb }
            let ca = a.shelves.contains("Classics of Literature")
            let cb = b.shelves.contains("Classics of Literature")
            if ca != cb { return ca }
            return a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
    }

    private func select(_ name: String) {
        section = name
        for b in sectionButtons { b.isOn = b.title == name }
        switch name {
        case "Reading now":
            rows = ShelfStore.shared.reading.map(\.book)
        case "On this Mac":
            rows = ShelfStore.shared.onThisMac.map(\.book)
        case _ where Scripture.all.contains { $0.shelf == name }:
            rows = Scripture.all.first { $0.shelf == name }?.books ?? []
        case "Most read":
            let byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let top = rank.sorted { $0.value < $1.value }.compactMap { byID[$0.key] }
            rows = top.isEmpty ? ordered(all.filter { inLanguage($0) && $0.shelves.contains("Classics of Literature") }) : top
        default:
            let match = Self.categories.first { $0.0 == name }?.1 ?? []
            rows = ordered(all.filter { b in
                inLanguage(b) && b.shelves.contains { s in match.contains { m in m.hasSuffix(" - ") ? s.hasPrefix(m) : s == m } }
            })
        }
        reload()
        if rows.isEmpty {
            switch name {
            case "Reading now": status("Nothing in progress yet. Pick a book from the library on the left.")
            case "On this Mac": status("No books on this Mac yet.")
            default: status(all.isEmpty ? "The library is not available." : "No books here in this language.")
            }
        }
    }

    @objc private func searchEntered(_ sender: Any?) {
        runSearch(search.stringValue)
        screen.window?.makeFirstResponder(table)
    }

    private var searchTask: Task<Void, Never>?

    private func runSearch(_ query: String) {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { select(section); return }
        section = "Search"
        for b in sectionButtons { b.isOn = false }
        let words = q.lowercased().split(separator: " ").map(String.init)
        let opts: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        let hits = all.filter { b in
            inLanguage(b) && words.allSatisfy { w in
                b.title.range(of: w, options: opts) != nil || b.author.range(of: w, options: opts) != nil
                    || (b.subjects?.range(of: w, options: opts) != nil)
                    || b.shelves.contains { $0.range(of: w, options: opts) != nil }
            }
        }
        rows = hits.sorted { a, b in
            let ta = a.title.range(of: q, options: opts.union(.anchored)) != nil
            let tb = b.title.range(of: q, options: opts.union(.anchored)) != nil
            if ta != tb { return ta }
            return ordered([a, b]).first == a
        }
        reload()
        status("Searching Project Gutenberg for \u{201C}\(q)\u{201D}\u{2026}")

        // Then ask Gutenberg itself, which also searches descriptions, and merge.
        searchTask?.cancel()
        let catalog = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        searchTask = Task { @MainActor in
            let live = await Gutenberg.search(q, catalog: catalog)
            guard !Task.isCancelled, self.section == "Search" else { return }
            let liveIDs = Set(live.map(\.id))
            let merged = live.filter { $0.language.isEmpty || self.inLanguage($0) } + self.rows.filter { !liveIDs.contains($0.id) }
            self.rows = merged
            self.reload()
            if merged.isEmpty { self.status("No books match \u{201C}\(q)\u{201D}.") }
        }
    }

    private func reload() {
        table.reloadData()
        if !rows.isEmpty {
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            table.scrollRowToVisible(0)
        }
        let n = NumberFormatter.localizedString(from: NSNumber(value: rows.count), number: .decimal)
        status("\(section)   \u{00B7}   \(n) \(rows.count == 1 ? "book" : "books")")
    }

    private func popLanguages(_ b: MonoButton) {
        let m = NSMenu()
        for (name, code) in Self.languages {
            let item = NSMenuItem(title: name, action: #selector(pickLanguage(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = code
            item.state = code == language ? .on : .off
            m.addItem(item)
        }
        b.popUp(m)
    }

    @objc private func pickLanguage(_ sender: NSMenuItem) {
        language = sender.representedObject as? String ?? "en"
        languageButton.title = sender.title
        if section == "Search" { runSearch(search.stringValue) } else { select(section) }
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { ShelfRowView() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let p = MonoPalette.current
        let cell = (tableView.makeView(withIdentifier: .init("cell"), owner: self) as? ShelfCell) ?? ShelfCell()
        let b = rows[row]
        cell.title.stringValue = b.title
        cell.title.textColor = p.ink
        var detail = b.author.isEmpty ? "Unknown author" : b.author
        if !b.language.isEmpty && (language.isEmpty || b.language != "en") { detail += "   \u{00B7}   " + b.language.uppercased() }
        if let e = ShelfStore.shared.entries[b.id] {
            if e.position > 0 && e.length > 0 {
                detail += "   \u{00B7}   read \(min(100, Int(Double(e.position) / Double(e.length) * 100)))%"
            } else {
                detail += "   \u{00B7}   on this Mac"
            }
        }
        cell.detail.stringValue = detail
        cell.detail.textColor = p.dim
        return cell
    }

    @objc private func openSelected(_ sender: Any?) {
        let row = table.selectedRow
        guard row >= 0, row < rows.count else { return }
        open(rows[row])
    }

    private func open(_ book: Book, at passage: Passage? = nil) {
        status(Scripture.contains(book.id) ? "Opening \u{201C}\(book.title)\u{201D}\u{2026}"
               : "Fetching \u{201C}\(book.title)\u{201D} from Project Gutenberg\u{2026}")
        Task { @MainActor in
            do {
                let text = try await Gutenberg.download(book)
                ShelfStore.shared.add(book, length: text.utf16.count)
                self.read(book, text: text, at: passage)
            } catch {
                self.status("Unable to fetch the book: \(Web.describe(error))")
            }
        }
    }

    /// A passage from FIND opens in its own sutta or chapter, which typesets at once even deep in a
    /// large collection, and leaves the reader's place in the whole book as it was.
    private func openExcerpt(_ p: Passage) {
        guard let s = Scripture.all.first(where: { $0.shelf == p.scripture }), let text = s.excerpt(p) else {
            open(p.book, at: p)
            return
        }
        let b = Book(id: p.book.id, title: p.reference, author: p.book.title, language: p.book.language, shelves: [])
        read(b, text: text, at: p, remember: false)
    }

    private func read(_ book: Book, text: String, at passage: Passage? = nil, remember: Bool = true) {
        let position = remember ? ShelfStore.shared.entries[book.id]?.position ?? 0 : 0
        let r = BookReaderView(book: book, text: text, position: position)
        if let passage { r.open(at: passage) }
        if remember { r.onPosition = { pos, len in ShelfStore.shared.setPosition(book.id, pos, length: len) } }
        r.onExit = { [weak self] in self?.closeReader() }
        reader = r
        r.translatesAutoresizingMaskIntoConstraints = false
        screen.addSubview(r)
        NSLayoutConstraint.activate([
            r.topAnchor.constraint(equalTo: screen.topAnchor),
            r.bottomAnchor.constraint(equalTo: screen.bottomAnchor),
            r.leadingAnchor.constraint(equalTo: screen.leadingAnchor),
            r.trailingAnchor.constraint(equalTo: screen.trailingAnchor),
        ])
        screen.window?.makeFirstResponder(r)
    }

    private func closeReader() {
        reader?.removeFromSuperview()
        reader = nil
        if section == "Search" { runSearch(search.stringValue) } else { select(section) }
        screen.window?.makeFirstResponder(table)
    }

    private func exit() {
        let c = onExit
        onExit = nil
        c?()
    }

    @objc func bigger(_ sender: Any?) { reader?.resize(by: 1) }
    @objc func smaller(_ sender: Any?) { reader?.resize(by: -1) }
    @objc func contents(_ sender: Any?) { reader?.showContents() }
    @objc func closeBook(_ sender: Any?) { if reader != nil { closeReader() } else { exit() } }

    func makeMenus() -> [NSMenu] {
        let me: AnyObject = self
        let book = NSMenu(title: "Book")
        [NSMenuItem.mono("Contents", #selector(contents(_:)), "t", target: me),
         .mono("Larger Text", #selector(bigger(_:)), "=", target: me),
         .mono("Smaller Text", #selector(smaller(_:)), "-", target: me),
         .separator(),
         .mono("Close", #selector(closeBook(_:)), "w", target: me)].forEach(book.addItem)
        book.appearance = MonoPalette.current.appearance
        return [book]
    }
}

final class FlippedClip: NSClipView {
    override var isFlipped: Bool { true }
}

final class ShelfTable: NSTableView {
    var onOpen: (() -> Void)?
    var onEscape: (() -> Void)?
    var onType: ((String) -> Void)?

    override func keyDown(with e: NSEvent) {
        switch e.keyCode {
        case 36, 76: onOpen?()
        case 53: onEscape?()
        default:
            if let s = e.characters, s.count == 1, let c = s.first, c.isLetter || c.isNumber,
               e.modifierFlags.intersection([.command, .control, .option]).isEmpty {
                onType?(s)
            } else {
                super.keyDown(with: e)
            }
        }
    }
}

final class ShelfRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        MonoPalette.current.selection.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 10, dy: 3), xRadius: 5, yRadius: 5).fill()
    }

    override var isEmphasized: Bool { get { false } set {} }
}

final class ShelfCell: NSTableCellView {
    let title = NSTextField(labelWithString: "")
    let detail = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = .init("cell")
        title.font = .systemFont(ofSize: 15, weight: .medium)
        detail.font = .systemFont(ofSize: 12)
        for l in [title, detail] {
            l.lineBreakMode = .byTruncatingTail
            l.translatesAutoresizingMaskIntoConstraints = false
            addSubview(l)
        }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            title.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            detail.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
            detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 3),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}
