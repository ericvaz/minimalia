import AppKit

final class EditorTextView: RetroTextView {
    override func setup() {
        super.setup()
        isRichText = false
        allowsUndo = true
        usesFindBar = true
        isIncrementalSearchingEnabled = true
    }

    override func applyTheme() {
        super.applyTheme()
        let s = Settings.shared
        let attrs: [NSAttributedString.Key: Any] = [.font: s.font, .foregroundColor: s.theme.fg, .paragraphStyle: s.paragraphStyle]
        font = s.font
        textColor = s.theme.fg
        defaultParagraphStyle = s.paragraphStyle
        if let ts = textStorage, ts.length > 0 {
            ts.addAttributes(attrs, range: NSRange(location: 0, length: ts.length))
        }
        typingAttributes = attrs
    }
}

/// Full-screen editor in the spirit of the editors of the 1980s. WRITE mode keeps the line you are typing centred.
@MainActor
final class EditorController: NSObject, NSTextViewDelegate, DocumentController {
    let tv = EditorTextView()
    let screen: ScreenView
    let url: URL
    var doc: LoadedDoc
    let typewriter: Bool
    private(set) var dirty = false
    var onClose: (() -> Void)?

    private var question: ((String) -> Void)?
    private var message: String?
    private var messageTimer: Timer?
    private var richConfirmed = false
    private var words = 0
    private var countTimer: Timer?

    init(url: URL, doc: LoadedDoc, typewriter: Bool, atEnd: Bool) {
        self.url = url
        self.doc = doc
        self.typewriter = typewriter
        screen = ScreenView(textView: tv, top: !typewriter, bottom: true)
        super.init()
        tv.string = doc.text
        tv.applyTheme()
        tv.undoManager?.removeAllActions()
        tv.delegate = self
        tv.maxColumns = typewriter ? 68 : 96
        tv.keyInterceptor = { [weak self] e in self?.handle(e) ?? false }
        let start = atEnd ? (tv.string as NSString).length : 0
        tv.setSelectedRange(NSRange(location: start, length: 0))
        screen.onLayout = { [weak self] in self?.layoutChanged() }
        NotificationCenter.default.addObserver(self, selector: #selector(updateBars), name: .minimaliaAppearance, object: nil)
        countWords()
        updateBars()
    }

    var name: String { url.lastPathComponent }

    private func layoutChanged() {
        guard typewriter else { return }
        let half = floor(screen.scroll.contentSize.height / 2)
        if abs(tv.verticalInset - half) > 1 { tv.verticalInset = half }
        DispatchQueue.main.async { [weak self] in self?.centerCaret() }
    }

    func focusAtStart() {
        tv.scrollRangeToVisible(tv.selectedRange())
        if typewriter { DispatchQueue.main.async { [weak self] in self?.centerCaret() } }
    }

    // MARK: Keys

    private func handle(_ e: NSEvent) -> Bool {
        if let q = question {
            let key = e.keyCode == 53 ? "esc" : (e.charactersIgnoringModifiers?.lowercased() ?? "")
            q(key)
            return true
        }
        let flags = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = e.charactersIgnoringModifiers?.lowercased() ?? ""
        if e.keyCode == 53 {
            requestClose()
            return true
        }
        if flags.contains(.control) && key == "s" {
            save()
            return true
        }
        return false
    }

    private func ask(_ prompt: String, _ handler: @escaping (String) -> Bool) {
        message = prompt
        question = { [weak self] key in
            guard let self else { return }
            let saved = self.question
            self.question = nil
            self.message = nil
            if !handler(key) {
                self.question = saved
                self.message = prompt
            }
            self.updateBars()
        }
        updateBars()
    }

    private func flash(_ text: String) {
        message = text
        updateBars()
        messageTimer?.invalidate()
        messageTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.question == nil else { return }
                self.message = nil
                self.updateBars()
            }
        }
    }

    // MARK: Saving

    func saveFromMenu() { save() }

    func save(_ done: ((Bool) -> Void)? = nil) {
        if doc.kind.isRich && !richConfirmed {
            ask("Word formatting will be simplified to plain paragraphs. Save? (Y/N)") { [weak self] key in
                guard let self else { return true }
                switch key {
                case "y":
                    self.richConfirmed = true
                    self.save(done)
                    return true
                case "n", "esc":
                    done?(false)
                    return true
                default:
                    return false
                }
            }
            return
        }
        let ok = writeNow()
        done?(ok)
    }

    @discardableResult
    func writeNow() -> Bool {
        do {
            try DocumentIO.write(tv.string, to: url, doc: doc)
            dirty = false
            flash(" Saved \(name).")
            return true
        } catch {
            flash(" Could not save: \(error.localizedDescription)")
            return false
        }
    }

    func requestClose() {
        guard dirty else { close(); return }
        ask("Save changes to \(name)? (Y/N, Esc to keep editing)") { [weak self] key in
            guard let self else { return true }
            switch key {
            case "y":
                self.save { ok in if ok { self.close() } }
                return true
            case "n":
                self.close()
                return true
            case "esc":
                return true
            default:
                return false
            }
        }
    }

    private func close() {
        countTimer?.invalidate()
        messageTimer?.invalidate()
        let c = onClose
        onClose = nil
        c?()
    }

    // MARK: Delegate

    func textDidChange(_ notification: Notification) {
        if !dirty { dirty = true }
        countTimer?.invalidate()
        countTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.countWords() }
        }
        updateBars()
        if typewriter { DispatchQueue.main.async { [weak self] in self?.centerCaret() } }
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        updateBars()
        if typewriter { DispatchQueue.main.async { [weak self] in self?.centerCaret() } }
    }

    private func countWords() {
        words = tv.string.split(whereSeparator: { $0.isWhitespace }).count
        updateBars()
    }

    private func centerCaret() {
        guard typewriter, let r = tv.caretRect() else { return }
        let clip = screen.scroll.contentView
        let h = clip.bounds.height
        let maxY = max(0, tv.frame.height - h)
        let y = min(max(0, r.midY - h / 2), maxY)
        if abs(clip.bounds.origin.y - y) > 0.5 {
            clip.setBoundsOrigin(NSPoint(x: 0, y: y))
            screen.scroll.reflectScrolledClipView(clip)
        }
    }

    @objc func updateBars() {
        let ns = tv.string as NSString
        let loc = min(tv.selectedRange().location, ns.length)
        var line = 1
        var i = 0
        while i < loc {
            let r = ns.range(of: "\n", options: [], range: NSRange(location: i, length: loc - i))
            if r.location == NSNotFound { break }
            line += 1
            i = r.location + 1
        }
        let col = loc - ns.lineRange(for: NSRange(location: loc, length: 0)).location + 1
        let wordText = NumberFormatter.localizedString(from: NSNumber(value: words), number: .decimal) + (words == 1 ? " word" : " words")
        let mark = dirty ? " *" : ""

        if typewriter {
            screen.bottom?.left.stringValue = message ?? "WRITE  \(name)\(mark)    Ctrl+S Save   Esc Exit"
            screen.bottom?.right.stringValue = wordText
        } else {
            screen.top?.left.stringValue = "MINIMALIA EDIT"
            screen.top?.right.stringValue = name.uppercased() + mark
            screen.bottom?.left.stringValue = message ?? "Ctrl+S Save   Esc Exit   \u{2318}F Find"
            screen.bottom?.right.stringValue = "Ln \(line)  Col \(col)    \(wordText)"
        }
    }
}
