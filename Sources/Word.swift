import AppKit

extension NSAttributedString.Key {
    static let mBold = NSAttributedString.Key("minimaliaBold")
    static let mItalic = NSAttributedString.Key("minimaliaItalic")
    static let mHeading = NSAttributedString.Key("minimaliaHeading")
    static let mAlign = NSAttributedString.Key("minimaliaAlign")
}

/// Translates between a real Word document and the retro screen.
/// The text keeps only logical formatting (bold, italic, underline, heading level, alignment);
/// fonts and colours are worked out for the screen when shown and for the page when saved.
enum WordFormat {
    struct Body {
        var family = "Times New Roman"
        var size: CGFloat = 12
    }

    static func displayAttributes(_ a: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
        let s = Settings.shared
        let t = s.theme
        let bold = a[.mBold] as? Bool ?? false
        let italic = a[.mItalic] as? Bool ?? false
        let heading = a[.mHeading] as? Int ?? 0
        let align = a[.mAlign] as? Int ?? NSTextAlignment.natural.rawValue
        let fm = NSFontManager.shared

        var size = s.fontSize
        switch heading {
        case 1: size = round(size * 1.5)
        case 2: size = round(size * 1.25)
        case 3: size = round(size * 1.1)
        default: break
        }
        var font = NSFont(descriptor: s.font.fontDescriptor, size: size) ?? s.font
        if bold || heading > 0 { font = fm.convert(font, toHaveTrait: .boldFontMask) }
        var oblique: CGFloat = 0
        if italic {
            let it = fm.convert(font, toHaveTrait: .italicFontMask)
            if fm.traits(of: it).contains(.italicFontMask) { font = it } else { oblique = 0.2 }
        }

        let para = NSMutableParagraphStyle()
        para.lineSpacing = s.paragraphStyle.lineSpacing
        para.paragraphSpacing = round(s.fontSize * 0.6)
        if heading > 0 { para.paragraphSpacingBefore = round(s.fontSize * 0.8) }
        para.alignment = NSTextAlignment(rawValue: align) ?? .natural

        var out: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: (bold || heading > 0) ? t.bright : t.fg,
            .paragraphStyle: para,
        ]
        if oblique != 0 { out[.obliqueness] = oblique }
        return out
    }

    static func restyle(_ ts: NSTextStorage, _ range: NSRange) {
        guard range.length > 0 else { return }
        ts.beginEditing()
        ts.enumerateAttributes(in: range) { a, r, _ in
            ts.removeAttribute(.obliqueness, range: r)
            ts.addAttributes(displayAttributes(a), range: r)
        }
        ts.endEditing()
    }

    /// Reads formatting out of a Word, RTF or ODT document.
    static func fromDocument(_ src: NSAttributedString) -> (NSMutableAttributedString, Body) {
        let full = NSRange(location: 0, length: src.length)
        let fm = NSFontManager.shared

        var weights: [String: Int] = [:]
        src.enumerateAttribute(.font, in: full) { v, r, _ in
            if let f = v as? NSFont { weights["\(f.familyName ?? "Times New Roman")|\(f.pointSize)", default: 0] += r.length }
        }
        var body = Body()
        if let top = weights.max(by: { $0.value < $1.value })?.key {
            let parts = top.split(separator: "|")
            body.family = String(parts[0])
            body.size = CGFloat(Double(parts.last ?? "12") ?? 12)
        }

        let out = NSMutableAttributedString(string: src.string)
        src.enumerateAttributes(in: full) { a, r, _ in
            var m: [NSAttributedString.Key: Any] = [:]
            if let f = a[.font] as? NSFont {
                let tr = fm.traits(of: f)
                if tr.contains(.boldFontMask) { m[.mBold] = true }
                if tr.contains(.italicFontMask) { m[.mItalic] = true }
            }
            if let u = a[.underlineStyle] as? Int, u != 0 { m[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            if !m.isEmpty { out.addAttributes(m, range: r) }
        }

        let ns = src.string as NSString
        var loc = 0
        while loc < ns.length {
            let pr = ns.paragraphRange(for: NSRange(location: loc, length: 0))
            let text = ns.substring(with: pr).trimmingCharacters(in: .whitespacesAndNewlines)
            var maxSize: CGFloat = 0
            var allBold = true
            src.enumerateAttribute(.font, in: pr) { v, r, _ in
                guard let f = v as? NSFont else { return }
                let chunk = ns.substring(with: r).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !chunk.isEmpty else { return }
                maxSize = max(maxSize, f.pointSize)
                if !fm.traits(of: f).contains(.boldFontMask) { allBold = false }
            }
            var heading = 0
            if !text.isEmpty && text.count < 200 {
                if maxSize >= body.size * 1.4 { heading = 1 }
                else if maxSize >= body.size * 1.2 { heading = 2 }
                else if maxSize >= body.size * 1.08 && allBold { heading = 3 }
            }
            if heading > 0 {
                out.addAttribute(.mHeading, value: heading, range: pr)
                out.removeAttribute(.mBold, range: pr)
            }
            if let ps = src.attribute(.paragraphStyle, at: pr.location, effectiveRange: nil) as? NSParagraphStyle,
               [.center, .right, .justified].contains(ps.alignment) {
                out.addAttribute(.mAlign, value: ps.alignment.rawValue, range: pr)
            }
            loc = NSMaxRange(pr)
        }
        return (out, body)
    }

    /// Builds the printed page: the document's own body font in black, headings scaled from it.
    static func toDocument(_ text: NSAttributedString, body: Body) -> NSAttributedString {
        let out = NSMutableAttributedString(string: text.string)
        let fm = NSFontManager.shared
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { a, r, _ in
            let heading = a[.mHeading] as? Int ?? 0
            let size: CGFloat
            switch heading {
            case 1: size = round(body.size * 1.5)
            case 2: size = round(body.size * 1.25)
            case 3: size = round(body.size * 1.1)
            default: size = body.size
            }
            var font = fm.font(withFamily: body.family, traits: [], weight: 5, size: size)
                ?? NSFont(name: "Times New Roman", size: size) ?? NSFont.systemFont(ofSize: size)
            if (a[.mBold] as? Bool ?? false) || heading > 0 { font = fm.convert(font, toHaveTrait: .boldFontMask) }
            if a[.mItalic] as? Bool ?? false { font = fm.convert(font, toHaveTrait: .italicFontMask) }
            let para = NSMutableParagraphStyle()
            para.alignment = NSTextAlignment(rawValue: a[.mAlign] as? Int ?? 0) ?? .natural
            para.paragraphSpacing = round(size * 0.5)
            if heading > 0 { para.paragraphSpacingBefore = round(size * 0.8) }
            var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black, .paragraphStyle: para]
            if let u = a[.underlineStyle] as? Int, u != 0 { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            out.addAttributes(attrs, range: r)
        }
        return out
    }
}

final class WordTextView: RetroTextView {
    override func setup() {
        super.setup()
        isRichText = true
        allowsUndo = true
        usesFindBar = true
        isIncrementalSearchingEnabled = true
    }

    override func applyTheme() {
        super.applyTheme()
        guard let ts = textStorage else { return }
        WordFormat.restyle(ts, NSRange(location: 0, length: ts.length))
        typingAttributes = typingAttributes.merging(WordFormat.displayAttributes(typingAttributes)) { $1 }
    }

    // Pasted text arrives plain and takes the formatting where it lands.
    override func paste(_ sender: Any?) {
        pasteAsPlainText(sender)
    }
}

/// A small word processor in the spirit of 1980s word processors: the text, and only the formatting you ask for.
@MainActor
final class WordController: NSObject, NSTextViewDelegate, DocumentController {
    let tv = WordTextView()
    let screen: ScreenView
    private(set) var url: URL
    private var doc: LoadedDoc
    private var body: WordFormat.Body
    private let existing: Bool
    private(set) var dirty = false
    var onClose: (() -> Void)?

    private var question: ((String) -> Void)?
    private var message: String?
    private var confirmed = false
    private var words = 0
    private var countTimer: Timer?

    init(url: URL, content: NSAttributedString, doc: LoadedDoc, existing: Bool) {
        self.url = url
        self.doc = doc
        self.existing = existing
        screen = ScreenView(textView: tv, top: true, bottom: true)
        let (text, body) = doc.kind.isRich ? WordFormat.fromDocument(content) : (NSMutableAttributedString(string: content.string), WordFormat.Body())
        self.body = body
        super.init()
        tv.textStorage?.setAttributedString(text)
        tv.applyTheme()
        tv.typingAttributes = WordFormat.displayAttributes([:])
        tv.undoManager?.removeAllActions()
        tv.delegate = self
        tv.maxColumns = 76
        tv.keyInterceptor = { [weak self] e in self?.handle(e) ?? false }
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        NotificationCenter.default.addObserver(self, selector: #selector(updateBars), name: .minimaliaAppearance, object: nil)
        countWords()
        if !doc.kind.isRich {
            message = "Plain text file: formatting shows here but is not saved. Use a .docx name to keep it."
        }
        updateBars()
    }

    var name: String { url.lastPathComponent }

    // MARK: Keys

    private func handle(_ e: NSEvent) -> Bool {
        if let q = question {
            q(e.keyCode == 53 ? "esc" : (e.charactersIgnoringModifiers?.lowercased() ?? ""))
            return true
        }
        if e.keyCode == 53 {
            requestClose()
            return true
        }
        let flags = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let ctrl = flags.contains(.control)
        let cmd = flags.contains(.command)
        guard ctrl || cmd else { return false }
        switch e.charactersIgnoringModifiers?.lowercased() ?? "" {
        case "b": toggle(.mBold)
        case "i": toggle(.mItalic)
        case "u": toggleUnderline()
        case "1" where ctrl: setParagraph(.mHeading, 1)
        case "2" where ctrl: setParagraph(.mHeading, 2)
        case "3" where ctrl: setParagraph(.mHeading, 3)
        case "0" where ctrl: setParagraph(.mHeading, nil)
        case "e" where ctrl: setParagraph(.mAlign, NSTextAlignment.center.rawValue)
        case "r" where ctrl: setParagraph(.mAlign, NSTextAlignment.right.rawValue)
        case "j" where ctrl: setParagraph(.mAlign, NSTextAlignment.justified.rawValue)
        case "l" where ctrl: setParagraph(.mAlign, nil)
        case "8" where ctrl: toggleBullets()
        case "s" where ctrl: save()
        case "p" where ctrl: printDocument()
        default: return false
        }
        return true
    }

    // MARK: Formatting

    private var storage: NSTextStorage { tv.textStorage! }

    private func change(_ r: NSRange, _ edit: () -> Void) {
        guard r.length > 0, tv.shouldChangeText(in: r, replacementString: nil) else { return }
        storage.beginEditing()
        edit()
        storage.endEditing()
        WordFormat.restyle(storage, r)
        tv.didChangeText()
    }

    private func setTyping(_ key: NSAttributedString.Key, _ value: Any?) {
        var t = tv.typingAttributes
        t[key] = value
        t.removeValue(forKey: .obliqueness)
        tv.typingAttributes = t.merging(WordFormat.displayAttributes(t)) { $1 }
        updateBars()
    }

    private func toggle(_ key: NSAttributedString.Key) {
        let r = tv.selectedRange()
        if r.length == 0 {
            setTyping(key, (tv.typingAttributes[key] as? Bool ?? false) ? nil : true)
            return
        }
        var allOn = true
        storage.enumerateAttribute(key, in: r) { v, _, stop in
            if !(v as? Bool ?? false) { allOn = false; stop.pointee = true }
        }
        change(r) {
            if allOn { storage.removeAttribute(key, range: r) } else { storage.addAttribute(key, value: true, range: r) }
        }
        updateBars()
    }

    private func toggleUnderline() {
        let r = tv.selectedRange()
        if r.length == 0 {
            let on = (tv.typingAttributes[.underlineStyle] as? Int ?? 0) != 0
            setTyping(.underlineStyle, on ? nil : NSUnderlineStyle.single.rawValue)
            return
        }
        var allOn = true
        storage.enumerateAttribute(.underlineStyle, in: r) { v, _, stop in
            if (v as? Int ?? 0) == 0 { allOn = false; stop.pointee = true }
        }
        change(r) {
            if allOn { storage.removeAttribute(.underlineStyle, range: r) }
            else { storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: r) }
        }
        updateBars()
    }

    private func setParagraph(_ key: NSAttributedString.Key, _ value: Int?) {
        let ns = tv.string as NSString
        let pr = ns.paragraphRange(for: tv.selectedRange())
        let current = tv.typingAttributes[key] as? Int
        let newValue = (key == .mHeading && value != nil && current == value) ? nil : value
        if pr.length > 0 {
            change(pr) {
                if let v = newValue { storage.addAttribute(key, value: v, range: pr) } else { storage.removeAttribute(key, range: pr) }
                if key == .mHeading && newValue != nil { storage.removeAttribute(.mBold, range: pr) }
            }
        }
        setTyping(key, newValue)
    }

    private func toggleBullets() {
        let ns = tv.string as NSString
        let all = ns.paragraphRange(for: tv.selectedRange())
        var starts: [Int] = []
        var loc = all.location
        repeat {
            let pr = ns.paragraphRange(for: NSRange(location: loc, length: 0))
            starts.append(pr.location)
            loc = NSMaxRange(pr)
        } while loc < NSMaxRange(all)
        let removing = starts.allSatisfy { ns.length >= $0 + 2 && ns.substring(with: NSRange(location: $0, length: 2)) == "\u{2022} " }
        for s in starts.reversed() {
            if removing {
                let r = NSRange(location: s, length: 2)
                if tv.shouldChangeText(in: r, replacementString: "") {
                    storage.replaceCharacters(in: r, with: "")
                    tv.didChangeText()
                }
            } else if !(ns.length >= s + 2 && ns.substring(with: NSRange(location: s, length: 2)) == "\u{2022} ") {
                let r = NSRange(location: s, length: 0)
                let attrs = s < storage.length ? storage.attributes(at: s, effectiveRange: nil) : tv.typingAttributes
                if tv.shouldChangeText(in: r, replacementString: "\u{2022} ") {
                    storage.replaceCharacters(in: r, with: NSAttributedString(string: "\u{2022} ", attributes: attrs))
                    tv.didChangeText()
                }
            }
        }
    }

    // MARK: Delegate

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
        let ns = tv.string as NSString
        let loc = tv.selectedRange().location
        let pr = ns.paragraphRange(for: NSRange(location: loc, length: 0))
        let para = ns.substring(with: pr).trimmingCharacters(in: .newlines)
        let bullet = para.hasPrefix("\u{2022} ")
        if bullet && para.trimmingCharacters(in: .whitespaces) == "\u{2022}" {
            let r = NSRange(location: pr.location, length: (para as NSString).length)
            if tv.shouldChangeText(in: r, replacementString: "") {
                storage.replaceCharacters(in: r, with: "")
                tv.didChangeText()
            }
            return true
        }
        let heading = tv.typingAttributes[.mHeading] as? Int ?? 0
        tv.insertNewline(nil)
        if heading > 0 {
            var t = tv.typingAttributes
            t.removeValue(forKey: .mHeading)
            t.removeValue(forKey: .mBold)
            setTypingAll(t)
        }
        if bullet { tv.insertText("\u{2022} ", replacementRange: tv.selectedRange()) }
        return true
    }

    private func setTypingAll(_ t: [NSAttributedString.Key: Any]) {
        var t = t
        t.removeValue(forKey: .obliqueness)
        tv.typingAttributes = t.merging(WordFormat.displayAttributes(t)) { $1 }
    }

    func textDidChange(_ notification: Notification) {
        if !dirty { dirty = true }
        countTimer?.invalidate()
        countTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.countWords() }
        }
        updateBars()
    }

    func textViewDidChangeSelection(_ notification: Notification) { updateBars() }

    private func countWords() {
        words = tv.string.split(whereSeparator: { $0.isWhitespace || $0 == "\u{2022}" }).count
        updateBars()
    }

    // MARK: Questions and messages

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
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.question == nil, self.message == text else { return }
            self.message = nil
            self.updateBars()
        }
    }

    // MARK: Saving and printing

    func saveFromMenu() { save() }

    func save(_ done: ((Bool) -> Void)? = nil) {
        if existing && doc.kind.isRich && !confirmed {
            ask("Saving keeps text, headings, bold, italic, underline and alignment, and drops the rest. Y save  C save a copy  Esc cancel") { [weak self] key in
                guard let self else { return true }
                switch key {
                case "y":
                    self.confirmed = true
                    let ok = self.writeNow()
                    done?(ok)
                    return true
                case "c":
                    self.url = self.copyURL()
                    self.confirmed = true
                    let ok = self.writeNow()
                    done?(ok)
                    return true
                case "esc", "n":
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
        do {
            switch doc.kind {
            case .rich(let type):
                try DocumentIO.writeAttributed(WordFormat.toDocument(storage, body: body), to: url, type: type, meta: doc.meta)
            default:
                try DocumentIO.write(tv.string, to: url, doc: doc)
            }
            dirty = false
            flash("Saved \(name).")
            return true
        } catch {
            flash("Could not save: \(error.localizedDescription)")
            return false
        }
    }

    func printDocument() {
        guard let window = tv.window else { return }
        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        info.topMargin = 72
        info.bottomMargin = 72
        info.leftMargin = 72
        info.rightMargin = 72
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        let width = info.paperSize.width - info.leftMargin - info.rightMargin
        let page = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
        page.textStorage?.setAttributedString(WordFormat.toDocument(storage, body: body))
        page.backgroundColor = .white
        page.isVerticallyResizable = true
        if let lm = page.layoutManager, let tc = page.textContainer {
            lm.ensureLayout(for: tc)
            page.setFrameSize(NSSize(width: width, height: ceil(lm.usedRect(for: tc).height) + 20))
        }
        let op = NSPrintOperation(view: page, printInfo: info)
        op.jobTitle = url.deletingPathExtension().lastPathComponent
        op.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    func requestClose() {
        guard dirty else { close(); return }
        ask("Save changes to \(name)? (Y/N, Esc to keep writing)") { [weak self] key in
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
        let c = onClose
        onClose = nil
        c?()
    }

    // MARK: Bars

    @objc func updateBars() {
        let ns = tv.string as NSString
        let loc = min(tv.selectedRange().location, ns.length)
        var para = 1
        var i = 0
        while i < loc {
            let r = ns.range(of: "\n", options: [], range: NSRange(location: i, length: loc - i))
            if r.location == NSNotFound { break }
            para += 1
            i = r.location + 1
        }
        let pos = loc - ns.paragraphRange(for: NSRange(location: loc, length: 0)).location + 1

        let t = tv.typingAttributes
        var fmt: [String] = []
        if let h = t[.mHeading] as? Int, h > 0 { fmt.append("Heading \(h)") }
        if t[.mBold] as? Bool ?? false { fmt.append("Bold") }
        if t[.mItalic] as? Bool ?? false { fmt.append("Italic") }
        if (t[.underlineStyle] as? Int ?? 0) != 0 { fmt.append("Underline") }
        switch NSTextAlignment(rawValue: t[.mAlign] as? Int ?? 0) {
        case .center: fmt.append("Centred")
        case .right: fmt.append("Right")
        case .justified: fmt.append("Justified")
        default: break
        }
        let wordText = NumberFormatter.localizedString(from: NSNumber(value: words), number: .decimal) + (words == 1 ? " word" : " words")

        screen.top?.left.stringValue = "MINIMALIA PAD"
        screen.top?.right.stringValue = name + (dirty ? " *" : "")
        screen.bottom?.left.stringValue = message
            ?? "^B Bold  ^I Italic  ^U Underline  ^1-3 Heading  ^0 Text  ^E Centre  ^L Left  ^8 Bullets  ^P Print  ^S Save  Esc Exit"
        screen.bottom?.right.stringValue = (fmt.isEmpty ? "" : fmt.joined(separator: " ") + "    ") + "Para \(para) Pos \(pos)    \(wordText)"
    }
}
