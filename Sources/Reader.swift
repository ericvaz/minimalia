import AppKit
import AVFoundation

final class ReaderTextView: RetroTextView {
    override func setup() {
        super.setup()
        isEditable = false
        isSelectable = true
        isRichText = true
        showsCaret = false
    }
}

/// Reads a page of text one screen at a time. Links are numbered; type the number and press Return.
@MainActor
final class ReaderController: NSObject, NSTextViewDelegate {
    let tv = ReaderTextView()
    let screen: ScreenView
    var onClose: (() -> Void)?
    var onPage: ((TextPage) -> Void)?

    private var stack: [(page: TextPage, y: CGFloat)] = []
    private var number = ""
    private var message: String?
    private var loading: Task<Void, Never>?
    private let speech = AVSpeechSynthesizer()

    init(page: TextPage) {
        screen = ScreenView(textView: tv, top: true, bottom: true)
        super.init()
        tv.delegate = self
        tv.maxColumns = 80
        tv.keyInterceptor = { [weak self] e in self?.handle(e) ?? false }
        screen.scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled),
                                               name: NSView.boundsDidChangeNotification, object: screen.scroll.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(restyle), name: .minimaliaAppearance, object: nil)
        push(page)
    }

    private var current: TextPage { stack[stack.count - 1].page }

    private func push(_ page: TextPage) {
        if !stack.isEmpty { stack[stack.count - 1].y = screen.scroll.contentView.bounds.origin.y }
        stack.append((page, 0))
        show(page, y: 0)
        onPage?(page)
    }

    private func show(_ page: TextPage, y: CGFloat) {
        tv.textStorage?.setAttributedString(render(page))
        tv.layoutManager?.ensureLayout(for: tv.textContainer!)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let clip = self.screen.scroll.contentView
            clip.setBoundsOrigin(NSPoint(x: 0, y: y))
            self.screen.scroll.reflectScrolledClipView(clip)
            self.updateBars()
        }
        updateBars()
    }

    @objc private func restyle() {
        show(current, y: screen.scroll.contentView.bounds.origin.y)
    }

    private func render(_ page: TextPage) -> NSAttributedString {
        let s = Settings.shared
        let t = s.theme
        let base: [NSAttributedString.Key: Any] = [.font: s.font, .foregroundColor: t.fg, .paragraphStyle: s.paragraphStyle]
        var heading = base
        heading[.foregroundColor] = t.bright
        let out = NSMutableAttributedString()

        let repeatsTitle = page.text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("\u{1}\(page.title)\u{2}")
        if !repeatsTitle { out.append(NSAttributedString(string: page.title + "\n", attributes: heading)) }
        if let u = page.url, !u.isFileURL {
            var dim = base
            dim[.foregroundColor] = t.dim
            out.append(NSAttributedString(string: (u.host ?? u.absoluteString) + "\n", attributes: dim))
        }
        out.append(NSAttributedString(string: "\n", attributes: base))

        var buffer = ""
        var inHeading = false
        var inLink = false
        var num = ""
        func flush() {
            guard !buffer.isEmpty else { return }
            out.append(NSAttributedString(string: buffer, attributes: inHeading ? heading : base))
            buffer = ""
        }
        for ch in page.text {
            switch ch {
            case "\u{1}":
                flush(); inHeading = true
            case "\u{2}":
                flush(); inHeading = false
            case "\u{3}":
                flush(); inLink = true; num = ""
            case "\u{4}":
                inLink = false
                var a = base
                a[.foregroundColor] = t.dim
                if let n = Int(num), n >= 1, n <= page.links.count { a[.link] = page.links[n - 1] }
                out.append(NSAttributedString(string: "[\(num)]", attributes: a))
            default:
                if inLink { num.append(ch) } else { buffer.append(ch) }
            }
        }
        flush()
        out.append(NSAttributedString(string: "\n", attributes: base))
        return out
    }

    // MARK: Keys

    private func handle(_ e: NSEvent) -> Bool {
        let flags = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) { return false }
        let ch = e.charactersIgnoringModifiers?.lowercased() ?? ""
        let line = Settings.shared.lineHeight + Settings.shared.paragraphStyle.lineSpacing
        let page = screen.scroll.contentView.bounds.height - line * 2

        switch e.keyCode {
        case 53:
            if loading != nil {
                loading?.cancel()
                loading = nil
                message = nil
                updateBars()
            } else {
                close()
            }
            return true
        case 36, 76:
            if let n = Int(number) { follow(n) }
            number = ""
            updateBars()
            return true
        case 51:
            if number.isEmpty { back() } else { number.removeLast(); updateBars() }
            return true
        case 123:
            back()
            return true
        case 49:
            scroll(by: flags.contains(.shift) ? -page : page)
            return true
        case 121:
            scroll(by: page)
            return true
        case 116:
            scroll(by: -page)
            return true
        case 125:
            scroll(by: line * 2)
            return true
        case 126:
            scroll(by: -line * 2)
            return true
        case 115:
            scroll(to: 0)
            return true
        case 119:
            scroll(to: .greatestFiniteMagnitude)
            return true
        default:
            break
        }
        if let c = ch.first, c.isNumber {
            number.append(c)
            updateBars()
            return true
        }
        switch ch {
        case "q": close()
        case "b": scroll(by: -page)
        case "s": save()
        case "r": speak()
        case "o": openOutside()
        default: break
        }
        return true
    }

    private func scroll(by dy: CGFloat) {
        scroll(to: screen.scroll.contentView.bounds.origin.y + dy)
    }

    private func scroll(to y: CGFloat) {
        let clip = screen.scroll.contentView
        let maxY = max(0, tv.frame.height - clip.bounds.height)
        clip.setBoundsOrigin(NSPoint(x: 0, y: min(max(0, y), maxY)))
        screen.scroll.reflectScrolledClipView(clip)
    }

    @objc private func scrolled() { updateBars() }

    // MARK: Actions

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        if let u = link as? URL { load(u) }
        return true
    }

    private func follow(_ n: Int) {
        guard n >= 1, n <= current.links.count else {
            flash("There is no link \(n) on this page.")
            return
        }
        load(current.links[n - 1])
    }

    private func load(_ url: URL) {
        loading?.cancel()
        message = "Connecting to \(url.host ?? url.absoluteString)...  Esc cancels"
        updateBars()
        loading = Task { [weak self] in
            do {
                let page = try await Web.page(url)
                guard let self, !Task.isCancelled else { return }
                self.loading = nil
                self.message = nil
                self.push(page)
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.loading = nil
                self.flash("Unable to read page: \(Web.describe(error))")
            }
        }
    }

    private func back() {
        guard stack.count > 1 else {
            flash("This is the first page. Esc returns to the prompt.")
            return
        }
        speech.stopSpeaking(at: .immediate)
        stack.removeLast()
        let last = stack[stack.count - 1]
        show(last.page, y: last.y)
        onPage?(last.page)
    }

    private func save() {
        do {
            let u = try Library.save(current)
            flash("Saved to LIBRARY as \(u.lastPathComponent)")
        } catch {
            flash("Could not save: \(error.localizedDescription)")
        }
    }

    private func speak() {
        if speech.isSpeaking {
            speech.stopSpeaking(at: .immediate)
            flash("Stopped reading aloud.")
            return
        }
        let utterance = AVSpeechUtterance(string: current.title + ".\n\n" + current.bareText)
        speech.speak(utterance)
        flash("Reading aloud. Press R again to stop.")
    }

    private func openOutside() {
        guard let u = current.url else { return }
        NSWorkspace.shared.open(u)
    }

    private func close() {
        loading?.cancel()
        speech.stopSpeaking(at: .immediate)
        let c = onClose
        onClose = nil
        c?()
    }

    private func flash(_ text: String) {
        message = text
        updateBars()
        let stamp = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.message == stamp else { return }
            self.message = nil
            self.updateBars()
        }
    }

    private func updateBars() {
        let page = current
        screen.top?.left.stringValue = page.title
        screen.top?.right.stringValue = page.url.map { $0.isFileURL ? "FILE" : ($0.host ?? "") } ?? ""
        let clip = screen.scroll.contentView
        let total = max(1, tv.frame.height)
        let pct = Int(min(100, ((clip.bounds.origin.y + clip.bounds.height) / total * 100).rounded()))
        let help = page.links.isEmpty
            ? "Space Next   B Back   S Save   R Read aloud   Esc Exit"
            : "Space Next   B Back   No.+Return Link   \u{2190} Prev page   S Save   R Read aloud   Esc Exit"
        if !number.isEmpty {
            screen.bottom?.left.stringValue = "Go to link \(number)_"
        } else {
            screen.bottom?.left.stringValue = message ?? help
        }
        screen.bottom?.right.stringValue = "\(pct)%"
    }
}
