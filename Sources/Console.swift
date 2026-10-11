import AppKit

/// The C:\> prompt. Output is appended at the end; only the text after the prompt can be edited.
final class ConsoleTextView: RetroTextView {
    enum Style: String { case normal, bright, dim, error, input, logo, glyph }
    /// A prompt that starts with this token is drawn with the Minimalia mark.
    static let logoToken = "\u{1}m"
    static let styleKey = NSAttributedString.Key("minimaliaStyle")

    private(set) var inputStart = 0
    private(set) var acceptingInput = false
    private var recordHistory = true
    private var lastPrompt = ""
    private var lineContinuation: CheckedContinuation<String, Never>?
    var history: [String] = []
    private var historyIndex = 0
    private var completion: (head: String, items: [String], index: Int)?

    var onInterrupt: (() -> Void)?
    /// Given the token being completed and whether it is the first word, returns replacements.
    var completer: ((String, Bool) -> [String])?

    override func setup() {
        super.setup()
        isRichText = true
        sideMargin = 0.05
        allowsUndo = false
        isEditable = true
        isSelectable = true
        typingAttributes = attributes(.input)
    }

    func attributes(_ style: Style) -> [NSAttributedString.Key: Any] {
        let s = Settings.shared
        let t = s.theme
        let color: NSColor
        switch style {
        case .normal, .input: color = t.fg
        case .bright, .logo, .glyph: color = t.bright
        case .dim: color = t.dim
        case .error: color = t.error
        }
        var para = s.paragraphStyle
        if style == .logo {
            let p = NSMutableParagraphStyle()
            let h = ceil(s.font.ascender - s.font.descender)
            p.minimumLineHeight = h
            p.maximumLineHeight = h
            para = p
        }
        return [.font: s.font, .foregroundColor: color, .paragraphStyle: para, Self.styleKey: style.rawValue]
    }

    override func applyTheme() {
        super.applyTheme()
        guard let ts = textStorage else { return }
        ts.beginEditing()
        ts.enumerateAttribute(Self.styleKey, in: NSRange(location: 0, length: ts.length)) { value, range, _ in
            let style = Style(rawValue: value as? String ?? "") ?? .normal
            if style == .glyph {
                ts.addAttributes(attributes(style), range: range)
            } else {
                ts.setAttributes(attributes(style), range: range)
            }
        }
        ts.endEditing()
        typingAttributes = attributes(.input)
    }

    // MARK: Output

    var length: Int { textStorage?.length ?? 0 }

    var endsWithNewline: Bool {
        guard let ts = textStorage, ts.length > 0 else { return true }
        return ts.mutableString.character(at: ts.length - 1) == 10
    }

    var columns: Int {
        let w = (enclosingScrollView?.contentSize.width ?? bounds.width) - textContainerInset.width * 2 - 10
        return max(40, Int(w / max(1, charWidth)))
    }

    func write(_ s: String, _ style: Style = .normal) {
        guard let ts = textStorage, !s.isEmpty else { return }
        ts.append(NSAttributedString(string: s, attributes: attributes(style)))
        trimScrollback()
        moveToEnd()
    }

    func writeLine(_ s: String = "", _ style: Style = .normal) {
        write(s + "\n", style)
    }

    func replaceLastLine(_ s: String, _ style: Style = .normal) {
        guard let ts = textStorage else { return }
        let ns = ts.mutableString
        let r = ns.range(of: "\n", options: .backwards)
        let start = r.location == NSNotFound ? 0 : r.location + 1
        ts.replaceCharacters(in: NSRange(location: start, length: ns.length - start),
                             with: NSAttributedString(string: s, attributes: attributes(style)))
        moveToEnd()
    }

    func clearScreen() {
        textStorage?.setAttributedString(NSAttributedString())
        inputStart = 0
        moveToEnd()
    }

    func moveToEnd() {
        let n = length
        setSelectedRange(NSRange(location: n, length: 0))
        scrollRangeToVisible(NSRange(location: n, length: 0))
        scheduleCaretUpdate()
    }

    private func trimScrollback() {
        guard !acceptingInput, let ts = textStorage, ts.length > 400_000 else { return }
        let ns = ts.mutableString
        let target = ts.length - 300_000
        let nl = ns.range(of: "\n", options: [], range: NSRange(location: target, length: ns.length - target))
        let cut = nl.location == NSNotFound ? target : nl.location + 1
        ts.deleteCharacters(in: NSRange(location: 0, length: cut))
        inputStart = max(0, inputStart - cut)
    }

    // MARK: Input

    /// The program prompt: the Minimalia mark, then the folder (if any) and a caret.
    func writePrompt(_ folder: String) {
        textStorage?.append(LogoGlyphCell.string(attributes: attributes(.glyph)))
        write(folder.isEmpty ? ">" : " " + folder + ">")
    }

    func readLine(prompt: String, history record: Bool = true) async -> String {
        lastPrompt = prompt
        if prompt.hasPrefix(Self.logoToken) {
            writePrompt(String(prompt.dropFirst(Self.logoToken.count)))
        } else {
            write(prompt)
        }
        inputStart = length
        acceptingInput = true
        recordHistory = record
        historyIndex = history.count
        completion = nil
        typingAttributes = attributes(.input)
        moveToEnd()
        return await withCheckedContinuation { lineContinuation = $0 }
    }

    var currentInput: String {
        guard let ts = textStorage else { return "" }
        return ts.mutableString.substring(from: min(inputStart, ts.length))
    }

    private func finishLine(_ line: String) {
        acceptingInput = false
        write("\n")
        if recordHistory, !line.trimmingCharacters(in: .whitespaces).isEmpty, history.last != line {
            history.append(line)
        }
        let c = lineContinuation
        lineContinuation = nil
        c?.resume(returning: line)
    }

    func setInput(_ s: String) {
        guard let ts = textStorage else { return }
        ts.replaceCharacters(in: NSRange(location: inputStart, length: ts.length - inputStart),
                             with: NSAttributedString(string: s, attributes: attributes(.input)))
        moveToEnd()
    }

    override func handleKey(_ e: NSEvent) {
        let flags = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = e.charactersIgnoringModifiers?.lowercased() ?? ""

        if flags.contains(.control) && key == "c" {
            if acceptingInput {
                write("^C")
                finishLine("")
            } else {
                onInterrupt?()
            }
            return
        }
        guard acceptingInput else { return }
        if flags.contains(.control) && key == "l" {
            let input = currentInput
            clearScreen()
            if lastPrompt.hasPrefix(Self.logoToken) {
                writePrompt(String(lastPrompt.dropFirst(Self.logoToken.count)))
            } else {
                write(lastPrompt)
            }
            inputStart = length
            setInput(input)
            return
        }
        if e.keyCode != 48 { completion = nil }

        switch e.keyCode {
        case 36, 76:
            finishLine(currentInput)
            return
        case 126 where !flags.contains(.command):
            stepHistory(-1)
            return
        case 125 where !flags.contains(.command):
            stepHistory(1)
            return
        case 48:
            complete()
            return
        case 53:
            setInput("")
            return
        case 115:
            setSelectedRange(NSRange(location: inputStart, length: 0))
            return
        case 119:
            moveToEnd()
            return
        default:
            break
        }
        ensureCaretInInput()
        super.handleKey(e)
    }

    private func ensureCaretInInput() {
        if selectedRange().location < inputStart {
            setSelectedRange(NSRange(location: length, length: 0))
        }
    }

    private func clampCaret() {
        if acceptingInput && selectedRange().length == 0 && selectedRange().location < inputStart {
            setSelectedRange(NSRange(location: inputStart, length: 0))
        }
    }

    override func shouldChangeText(in range: NSRange, replacementString: String?) -> Bool {
        guard acceptingInput, range.location >= inputStart else { return false }
        return super.shouldChangeText(in: range, replacementString: replacementString)
    }

    override func moveLeft(_ sender: Any?) {
        if selectedRange().location > inputStart || selectedRange().length > 0 { super.moveLeft(sender) }
        clampCaret()
    }

    override func moveWordLeft(_ sender: Any?) {
        super.moveWordLeft(sender)
        clampCaret()
    }

    override func moveToBeginningOfLine(_ sender: Any?) {
        setSelectedRange(NSRange(location: inputStart, length: 0))
    }

    override func moveToLeftEndOfLine(_ sender: Any?) {
        setSelectedRange(NSRange(location: inputStart, length: 0))
    }

    override func moveToBeginningOfParagraph(_ sender: Any?) {
        setSelectedRange(NSRange(location: inputStart, length: 0))
    }

    override func paste(_ sender: Any?) {
        guard acceptingInput, let s = NSPasteboard.general.string(forType: .string) else { return }
        ensureCaretInInput()
        let flat = s.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ")
        insertText(flat, replacementRange: selectedRange())
    }

    private func stepHistory(_ delta: Int) {
        guard recordHistory, !history.isEmpty else { return }
        historyIndex = max(0, min(history.count, historyIndex + delta))
        setInput(historyIndex == history.count ? "" : history[historyIndex])
    }

    private func complete() {
        if var c = completion {
            c.index = (c.index + 1) % c.items.count
            completion = c
            setInput(c.head + c.items[c.index])
            return
        }
        let input = currentInput
        let head: String
        let token: String
        if input.filter({ $0 == "\"" }).count % 2 == 1, let q = input.lastIndex(of: "\"") {
            head = String(input[..<q])
            token = String(input[input.index(after: q)...])
        } else if let sp = input.lastIndex(of: " ") {
            head = String(input[...sp])
            token = String(input[input.index(after: sp)...])
        } else {
            head = ""
            token = input
        }
        let items = completer?(token, head.trimmingCharacters(in: .whitespaces).isEmpty) ?? []
        guard !items.isEmpty else { return }
        completion = (head, items, 0)
        setInput(head + items[0])
    }
}
