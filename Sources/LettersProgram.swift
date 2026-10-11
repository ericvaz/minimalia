import AppKit

/// A text field drawn in Minimalia's greys, inside a thin rounded frame.
@MainActor
func monoField(_ placeholder: String, secure: Bool = false) -> (NSView, NSTextField) {
    let p = MonoPalette.current
    let f: NSTextField = secure ? NSSecureTextField() : NSTextField()
    f.placeholderString = placeholder
    f.isBordered = false
    f.isBezeled = false
    f.drawsBackground = true
    f.backgroundColor = p.page
    f.textColor = p.ink
    f.font = .systemFont(ofSize: 15)
    f.focusRingType = .none
    f.usesSingleLineMode = true
    f.lineBreakMode = .byTruncatingTail
    let box = NSView()
    box.wantsLayer = true
    box.layer?.backgroundColor = p.page.cgColor
    box.layer?.borderColor = p.edge.cgColor
    box.layer?.borderWidth = 1
    box.layer?.cornerRadius = 5
    f.translatesAutoresizingMaskIntoConstraints = false
    box.addSubview(f)
    NSLayoutConstraint.activate([
        f.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 10),
        f.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -10),
        f.centerYAnchor.constraint(equalTo: box.centerYAnchor),
        box.heightAnchor.constraint(equalToConstant: 34),
    ])
    return (box, f)
}

final class MailTable: NSTableView {
    var onKey: ((String) -> Bool)?
    var onEscape: (() -> Void)?

    override func keyDown(with e: NSEvent) {
        if e.keyCode == 53 { onEscape?(); return }
        if e.modifierFlags.intersection([.command, .control, .option]).isEmpty,
           let s = e.charactersIgnoringModifiers, let handle = onKey, handle(s) { return }
        super.keyDown(with: e)
    }
}

final class MailCell: NSTableCellView {
    let sender = NSTextField(labelWithString: "")
    let date = NSTextField(labelWithString: "")
    let subject = NSTextField(labelWithString: "")
    let preview = NSTextField(labelWithString: "")
    let dot = NSView()

    init() {
        super.init(frame: .zero)
        identifier = .init("mail")
        sender.font = .systemFont(ofSize: 14, weight: .semibold)
        date.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        date.alignment = .right
        subject.font = .systemFont(ofSize: 14)
        preview.font = .systemFont(ofSize: 13)
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3.5
        for v in [sender, date, subject, preview, dot] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        for l in [sender, subject, preview] { l.lineBreakMode = .byTruncatingTail }
        date.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 7), dot.heightAnchor.constraint(equalToConstant: 7),
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            dot.centerYAnchor.constraint(equalTo: sender.centerYAnchor),
            sender.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 30),
            sender.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            sender.trailingAnchor.constraint(lessThanOrEqualTo: date.leadingAnchor, constant: -10),
            date.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            date.centerYAnchor.constraint(equalTo: sender.centerYAnchor),
            subject.leadingAnchor.constraint(equalTo: sender.leadingAnchor),
            subject.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -18),
            subject.topAnchor.constraint(equalTo: sender.bottomAnchor, constant: 3),
            preview.leadingAnchor.constraint(equalTo: sender.leadingAnchor),
            preview.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -18),
            preview.topAnchor.constraint(equalTo: subject.bottomAnchor, constant: 3),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// Minimalia Letters: your mail as a quiet stack of letters, one at a time.
@MainActor
final class LettersProgram: NSObject, MinimaliaProgram, NSTableViewDataSource, NSTableViewDelegate, NSTextViewDelegate {
    let screen = NSView()
    private let topBar = MonoBar()
    private let statusBar = MonoBar(lineAtBottom: false)
    private let table = MailTable()
    private let listScroll = NSScrollView()
    private let reading = NSTextView()
    private let readingScroll = NSScrollView()
    private var statusLabel: NSTextField!
    private var boxButtons: [String: MonoButton] = [:]
    private var setupView: NSView?
    private var composer: NSView?
    private var composerFields: (to: NSTextField, cc: NSTextField, subject: NSTextField, body: NSTextView)?
    private var pendingReply: (inReplyTo: String?, references: String?)?
    private var browse: BrowseProgram?

    private var account: MailAccount?
    private var password: String?
    private var client: IMAPClient?
    private var boxes: [String: String] = ["inbox": "INBOX"]
    private var box = "inbox"
    private var messages: [MailMessage] = []
    private var queue: Task<Void, Never>?
    private let demo = ProcessInfo.processInfo.environment["MINIMALIA_MAIL_DEMO"] != nil

    var onExit: (() -> Void)?
    var focusView: NSView { setupView == nil ? table : (setupView?.subviews.compactMap { $0 as? NSView }.first ?? table) }

    override init() {
        super.init()
        build()
        if demo {
            loadDemo()
        } else if let a = MailAccount.saved, let pw = MailKeychain.get(a.email) {
            account = a
            password = pw
            connect()
        } else {
            showSetup()
        }
    }

    // MARK: Layout

    private func build() {
        let p = MonoPalette.current
        screen.wantsLayer = true
        screen.layer?.backgroundColor = p.desk.cgColor
        screen.appearance = p.appearance

        let title = topBar.label("Letters")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        topBar.add(title)
        let gap = NSView()
        gap.widthAnchor.constraint(equalToConstant: 24).isActive = true
        topBar.add(gap)
        for (role, name) in [("inbox", "Inbox"), ("flagged", "Starred"), ("sent", "Sent")] {
            let b = MonoButton(name) { [weak self] _ in self?.open(role) }
            boxButtons[role] = b
            topBar.add(b)
        }
        topBar.addSpacer()
        topBar.add(MonoButton("", symbol: "arrow.clockwise", help: "Check for new letters") { [weak self] _ in self?.refresh(nil) })
        topBar.add(MonoButton("Write", symbol: "square.and.pencil", help: "Write a letter (c)") { [weak self] _ in self?.compose(nil) })

        let col = NSTableColumn(identifier: .init("mail"))
        table.addTableColumn(col)
        table.headerView = nil
        table.rowHeight = 76
        table.intercellSpacing = .zero
        table.backgroundColor = p.desk
        table.dataSource = self
        table.delegate = self
        table.onEscape = { [weak self] in self?.exit() }
        table.onKey = { [weak self] k in self?.key(k) ?? false }
        listScroll.documentView = table
        listScroll.hasVerticalScroller = true
        listScroll.autohidesScrollers = true
        listScroll.scrollerStyle = .overlay
        listScroll.drawsBackground = true
        listScroll.backgroundColor = p.desk

        reading.isEditable = false
        reading.isSelectable = true
        reading.drawsBackground = true
        reading.backgroundColor = p.desk
        reading.textContainerInset = NSSize(width: 48, height: 36)
        reading.isVerticallyResizable = true
        reading.autoresizingMask = [.width]
        reading.delegate = self
        reading.linkTextAttributes = [.foregroundColor: p.ink, .underlineStyle: NSUnderlineStyle.single.rawValue,
                                      .cursor: NSCursor.pointingHand]
        reading.selectedTextAttributes = [.backgroundColor: p.selection]
        readingScroll.documentView = reading
        readingScroll.hasVerticalScroller = true
        readingScroll.autohidesScrollers = true
        readingScroll.scrollerStyle = .overlay
        readingScroll.drawsBackground = true
        readingScroll.backgroundColor = p.desk

        statusLabel = statusBar.label()
        statusBar.add(statusLabel)
        statusBar.addSpacer()
        let hint = statusBar.label("c write   r reply   a reply all   f forward   e archive   s star   Esc returns to the prompt")
        hint.textColor = p.dim
        statusBar.add(hint)

        let divider = MonoDivider()
        for v in [topBar, listScroll, divider, readingScroll, statusBar] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            screen.addSubview(v)
        }
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: screen.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: screen.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: screen.trailingAnchor),
            topBar.heightAnchor.constraint(equalToConstant: 44),
            listScroll.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            listScroll.leadingAnchor.constraint(equalTo: screen.leadingAnchor),
            listScroll.widthAnchor.constraint(equalTo: screen.widthAnchor, multiplier: 0.36),
            listScroll.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            divider.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: listScroll.trailingAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
            divider.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            readingScroll.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            readingScroll.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            readingScroll.trailingAnchor.constraint(equalTo: screen.trailingAnchor),
            readingScroll.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            statusBar.leadingAnchor.constraint(equalTo: screen.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: screen.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: screen.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: 28),
        ])
        boxButtons["inbox"]?.isOn = true
    }

    private func status(_ s: String) { statusLabel.stringValue = s }

    /// Runs mail-server work one step at a time, so commands never overlap on the connection.
    private func enqueue(_ op: @escaping @MainActor () async -> Void) {
        let previous = queue
        queue = Task { @MainActor in
            await previous?.value
            await op()
        }
    }

    // MARK: Setup

    private func showSetup(error: String? = nil) {
        setupView?.removeFromSuperview()
        let p = MonoPalette.current
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = p.desk.cgColor
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        func label(_ s: String, size: CGFloat = 14, dim: Bool = false, weight: NSFont.Weight = .regular) -> NSTextField {
            let l = NSTextField(wrappingLabelWithString: s)
            l.font = .systemFont(ofSize: size, weight: weight)
            l.textColor = dim ? p.dim : p.ink
            l.preferredMaxLayoutWidth = 520
            return l
        }
        stack.addArrangedSubview(label("Letters", size: 26, weight: .semibold))
        stack.addArrangedSubview(label("Your mail, one letter at a time. Connect your account once; the password is kept in the macOS Keychain.", dim: true))
        let (nameBox, name) = monoField("Your name")
        let (emailBox, email) = monoField("Email address")
        let (pwBox, pw) = monoField("App password", secure: true)
        name.stringValue = account?.name ?? NSFullUserName()
        email.stringValue = account?.email ?? ""
        for b in [nameBox, emailBox, pwBox] {
            b.widthAnchor.constraint(equalToConstant: 420).isActive = true
            stack.addArrangedSubview(b)
        }
        stack.addArrangedSubview(label("For Gmail: turn on 2-Step Verification, then create an app password at myaccount.google.com/apppasswords and paste it above. Other providers: use your mail password, or an app password if they offer one.", size: 13, dim: true))
        if let error { stack.addArrangedSubview(label(error, size: 13)) }
        let connect = MonoButton("Connect", symbol: "envelope") { [weak self] _ in
            self?.saveSetup(name: name.stringValue, email: email.stringValue, password: pw.stringValue)
        }
        connect.isOn = true
        stack.addArrangedSubview(connect)
        pw.target = self
        pw.action = #selector(setupReturn(_:))
        stack.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: v.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: v.centerYAnchor, constant: -40),
            stack.widthAnchor.constraint(equalToConstant: 520),
        ])
        v.translatesAutoresizingMaskIntoConstraints = false
        screen.addSubview(v)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            v.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            v.leadingAnchor.constraint(equalTo: screen.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: screen.trailingAnchor),
        ])
        setupView = v
        setupFields = (name, email, pw)
        DispatchQueue.main.async { [weak self] in
            self?.screen.window?.makeFirstResponder(email.stringValue.isEmpty ? email : pw)
        }
        status("Not connected")
    }

    private var setupFields: (NSTextField, NSTextField, NSTextField)?

    @objc private func setupReturn(_ sender: Any?) {
        guard let (n, e, p) = setupFields else { return }
        saveSetup(name: n.stringValue, email: e.stringValue, password: p.stringValue)
    }

    private func saveSetup(name: String, email: String, password pw: String) {
        let e = email.trimmingCharacters(in: .whitespaces)
        let pass = pw.replacingOccurrences(of: " ", with: "")
        guard e.contains("@"), !pass.isEmpty else { showSetup(error: "Please fill in the address and the password."); return }
        let a = MailAccount.preset(name: name.trimmingCharacters(in: .whitespaces), email: e)
        account = a
        password = pass
        connect(saving: true)
    }

    // MARK: Connecting and fetching

    private func connect(saving: Bool = false) {
        guard let a = account, let pw = password else { showSetup(); return }
        status("Connecting to \(a.imapHost)\u{2026}")
        enqueue { [weak self] in
            guard let self else { return }
            do {
                let c = try await IMAPClient.connect(a, password: pw)
                self.client = c
                self.boxes = (try? await c.specialMailboxes()) ?? ["inbox": "INBOX"]
                if saving {
                    MailAccount.saved = a
                    MailKeychain.set(pw, for: a.email)
                }
                self.setupView?.removeFromSuperview()
                self.setupView = nil
                self.screen.window?.makeFirstResponder(self.table)
                await self.fetch()
            } catch {
                self.client = nil
                self.showSetup(error: "Could not connect: \(error.localizedDescription)")
            }
        }
    }

    private func fetch() async {
        guard let c = client, let name = boxes[box] else {
            messages = []
            table.reloadData()
            status(box == "inbox" ? "Not connected" : "This mailbox is not available")
            return
        }
        status("Checking \(boxTitle)\u{2026}")
        do {
            let list = try await c.recent(name)
            let keep = selected?.uid
            messages = list
            table.reloadData()
            let row = messages.firstIndex { $0.uid == keep } ?? 0
            if !messages.isEmpty { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) } else { showEmpty() }
            let unread = messages.filter { !$0.seen }.count
            status("\(boxTitle)   \u{00B7}   \(messages.count) letters" + (unread > 0 ? ", \(unread) unread" : ""))
        } catch {
            status("Could not check mail: \(error.localizedDescription)")
        }
    }

    private var boxTitle: String { ["inbox": "Inbox", "flagged": "Starred", "sent": "Sent"][box] ?? box }

    private func open(_ role: String) {
        box = role
        for (r, b) in boxButtons { b.isOn = r == role }
        if demo { status("Demo mailbox"); return }
        enqueue { [weak self] in await self?.fetch() }
        screen.window?.makeFirstResponder(table)
    }

    @objc func refresh(_ sender: Any?) {
        if demo { return }
        if client == nil { connect(); return }
        enqueue { [weak self] in await self?.fetch() }
    }

    // MARK: List

    private var selected: MailMessage? {
        let r = table.selectedRow
        return r >= 0 && r < messages.count ? messages[r] : nil
    }

    func numberOfRows(in tableView: NSTableView) -> Int { messages.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { ShelfRowView() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let p = MonoPalette.current
        let cell = (tableView.makeView(withIdentifier: .init("mail"), owner: self) as? MailCell) ?? MailCell()
        let m = messages[row]
        let who = box == "sent" ? (m.to.first?.display ?? "") : m.from.display
        cell.sender.stringValue = who.isEmpty ? "(no sender)" : who
        cell.sender.font = .systemFont(ofSize: 14, weight: m.seen ? .regular : .semibold)
        cell.sender.textColor = p.ink
        cell.subject.stringValue = (m.flagged ? "\u{2605} " : "") + (m.subject.isEmpty ? "(no subject)" : m.subject)
        cell.subject.textColor = p.ink
        cell.preview.stringValue = m.preview
        cell.preview.textColor = p.dim
        cell.date.stringValue = shortDate(m.date)
        cell.date.textColor = p.dim
        cell.dot.layer?.backgroundColor = m.seen ? NSColor.clear.cgColor : p.ink.cgColor
        return cell
    }

    private func shortDate(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale.current
        if Calendar.current.isDateInToday(d) { f.dateFormat = "HH:mm" }
        else if Calendar.current.isDate(d, equalTo: Date(), toGranularity: .year) { f.dateFormat = "d MMM" }
        else { f.dateFormat = "d MMM yyyy" }
        return f.string(from: d)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let m = selected else { return }
        show(m)
        if m.body == nil, !demo, let c = client {
            let uid = m.uid
            enqueue { [weak self] in
                guard let self else { return }
                guard let (text, files) = try? await c.body(uid: uid),
                      let i = self.messages.firstIndex(where: { $0.uid == uid }) else { return }
                self.messages[i].body = text
                self.messages[i].attachments = files
                self.messages[i].seen = true
                self.table.reloadData(forRowIndexes: IndexSet(integer: i), columnIndexes: IndexSet(integer: 0))
                if self.selected?.uid == uid { self.show(self.messages[i]) }
            }
        }
    }

    // MARK: Reading

    private func readingFont(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        if let d = base.fontDescriptor.withDesign(.serif), let f = NSFont(descriptor: d, size: size) { return f }
        return base
    }

    private func show(_ m: MailMessage) {
        let p = MonoPalette.current
        let out = NSMutableAttributedString()
        let para = NSMutableParagraphStyle()
        para.lineHeightMultiple = 1.4
        para.paragraphSpacing = 6
        out.append(NSAttributedString(string: (m.subject.isEmpty ? "(no subject)" : m.subject) + "\n", attributes: [
            .font: readingFont(24, weight: .semibold), .foregroundColor: p.ink, .paragraphStyle: para]))
        let meta = NSMutableParagraphStyle()
        meta.paragraphSpacing = 2
        out.append(NSAttributedString(string: m.from.display, attributes: [.font: NSFont.systemFont(ofSize: 14, weight: .semibold), .foregroundColor: p.ink, .paragraphStyle: meta]))
        if !m.from.name.isEmpty {
            out.append(NSAttributedString(string: "  <\(m.from.email)>", attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: p.dim, .paragraphStyle: meta]))
        }
        let df = DateFormatter()
        df.dateStyle = .full
        df.timeStyle = .short
        var lines = ["\n" + df.string(from: m.date)]
        if !m.to.isEmpty { lines.append("To: " + m.to.map(\.display).joined(separator: ", ")) }
        if !m.cc.isEmpty { lines.append("Cc: " + m.cc.map(\.display).joined(separator: ", ")) }
        out.append(NSAttributedString(string: lines.joined(separator: "\n") + "\n\n", attributes: [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: p.dim, .paragraphStyle: meta]))

        let body = m.body ?? (m.preview.isEmpty ? "" : m.preview + "\u{2026}")
        let bodyFont = readingFont(18)
        var inSignature = false
        for line in body.components(separatedBy: "\n") {
            if line == "-- " || line == "--" { inSignature = true }
            let quoted = line.hasPrefix(">")
            out.append(NSAttributedString(string: line + "\n", attributes: [
                .font: bodyFont, .foregroundColor: (quoted || inSignature) ? p.dim : p.ink, .paragraphStyle: para]))
        }
        if !m.attachments.isEmpty {
            out.append(NSAttributedString(string: "\nAttachments: " + m.attachments.joined(separator: ", ") + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: 13), .foregroundColor: p.dim, .paragraphStyle: meta]))
        }
        // Make web addresses clickable; they open in Minimalia Browse.
        if let det = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            for r in det.matches(in: out.string, range: NSRange(location: 0, length: out.length)) {
                if let u = r.url, u.scheme?.hasPrefix("http") == true { out.addAttribute(.link, value: u, range: r.range) }
            }
        }
        reading.textStorage?.setAttributedString(out)
        reading.scrollToBeginningOfDocument(nil)
        let w = readingScroll.contentSize.width
        reading.textContainerInset = NSSize(width: max(48, (w - 720) / 2), height: 36)
    }

    private func showEmpty() {
        reading.textStorage?.setAttributedString(NSAttributedString(string: "No letters here.", attributes: [
            .font: readingFont(18), .foregroundColor: MonoPalette.current.dim]))
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let u = link as? URL else { return false }
        let b = BrowseProgram(start: u)
        b.onExit = { [weak self] in
            self?.browse?.screen.removeFromSuperview()
            self?.browse = nil
            self?.screen.window?.makeFirstResponder(self?.table)
        }
        browse = b
        b.screen.translatesAutoresizingMaskIntoConstraints = false
        screen.addSubview(b.screen)
        NSLayoutConstraint.activate([
            b.screen.topAnchor.constraint(equalTo: screen.topAnchor),
            b.screen.bottomAnchor.constraint(equalTo: screen.bottomAnchor),
            b.screen.leadingAnchor.constraint(equalTo: screen.leadingAnchor),
            b.screen.trailingAnchor.constraint(equalTo: screen.trailingAnchor),
        ])
        screen.window?.makeFirstResponder(b.web)
        return true
    }

    // MARK: Keys

    private func key(_ k: String) -> Bool {
        switch k {
        case "c": compose(nil)
        case "r": reply(nil)
        case "a": replyAll(nil)
        case "f": forward(nil)
        case "e": archive(nil)
        case "s": star(nil)
        case "j": move(1)
        case "k": move(-1)
        case "\r": screen.window?.makeFirstResponder(reading)
        default: return false
        }
        return true
    }

    private func move(_ d: Int) {
        let r = max(0, min(messages.count - 1, table.selectedRow + d))
        table.selectRowIndexes(IndexSet(integer: r), byExtendingSelection: false)
        table.scrollRowToVisible(r)
    }

    @objc func archive(_ sender: Any?) {
        guard let m = selected, box == "inbox" else { return }
        let row = table.selectedRow
        messages.remove(at: row)
        table.removeRows(at: IndexSet(integer: row), withAnimation: [])
        if !messages.isEmpty { table.selectRowIndexes(IndexSet(integer: min(row, messages.count - 1)), byExtendingSelection: false) }
        status("Archived \u{201C}\(m.subject)\u{201D}")
        guard !demo, let c = client, let target = boxes["all"] ?? boxes["archive"] else { return }
        enqueue { [weak self] in
            do { try await c.archive(uid: m.uid, to: target) } catch { self?.status("Could not archive: \(error.localizedDescription)") }
        }
    }

    @objc func star(_ sender: Any?) {
        guard let m = selected, let i = messages.firstIndex(where: { $0.uid == m.uid }) else { return }
        messages[i].flagged.toggle()
        let on = messages[i].flagged
        table.reloadData(forRowIndexes: IndexSet(integer: i), columnIndexes: IndexSet(integer: 0))
        guard !demo, let c = client else { return }
        enqueue { try? await c.setFlag(uid: m.uid, "\\Flagged", on: on) }
    }

    // MARK: Writing

    @objc func compose(_ sender: Any?) { openComposer(to: "", cc: "", subject: "", body: "", reply: nil) }

    @objc func reply(_ sender: Any?) {
        guard let m = selected else { return }
        let to = (m.replyTo.first ?? m.from).full
        openComposer(to: to, cc: "", subject: prefixed("Re:", m.subject), body: quote(m), reply: m)
    }

    @objc func replyAll(_ sender: Any?) {
        guard let m = selected else { return }
        let me = account?.email.lowercased() ?? ""
        let to = (m.replyTo.isEmpty ? [m.from] : m.replyTo)
        let others = (m.to + m.cc).filter { $0.email.lowercased() != me && !to.contains($0) }
        openComposer(to: to.map(\.full).joined(separator: ", "), cc: others.map(\.full).joined(separator: ", "),
                     subject: prefixed("Re:", m.subject), body: quote(m), reply: m)
    }

    @objc func forward(_ sender: Any?) {
        guard let m = selected else { return }
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        let body = "\n\n---------- Forwarded message ----------\nFrom: \(m.from.full)\nDate: \(df.string(from: m.date))\nSubject: \(m.subject)\nTo: \(m.to.map(\.full).joined(separator: ", "))\n\n\(m.body ?? m.preview)"
        openComposer(to: "", cc: "", subject: prefixed("Fwd:", m.subject), body: body, reply: nil)
    }

    private func prefixed(_ p: String, _ s: String) -> String {
        s.lowercased().hasPrefix(p.lowercased()) ? s : "\(p) \(s)"
    }

    private func quote(_ m: MailMessage) -> String {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        let quoted = (m.body ?? m.preview).components(separatedBy: "\n").map { "> " + $0 }.joined(separator: "\n")
        return "\n\nOn \(df.string(from: m.date)), \(m.from.display) wrote:\n\(quoted)"
    }

    private func openComposer(to: String, cc: String, subject: String, body: String, reply: MailMessage?) {
        closeComposer()
        let p = MonoPalette.current
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = p.desk.cgColor
        let (toBox, toField) = monoField("To")
        let (ccBox, ccField) = monoField("Cc")
        let (subjectBox, subjectField) = monoField("Subject")
        toField.stringValue = to
        ccField.stringValue = cc
        subjectField.stringValue = subject
        let text = NSTextView()
        text.isRichText = false
        text.allowsUndo = true
        text.font = readingFont(18)
        text.textColor = p.ink
        text.insertionPointColor = p.ink
        text.drawsBackground = true
        text.backgroundColor = p.page
        text.textContainerInset = NSSize(width: 18, height: 16)
        text.isContinuousSpellCheckingEnabled = false
        let para = NSMutableParagraphStyle()
        para.lineHeightMultiple = 1.4
        text.defaultParagraphStyle = para
        text.typingAttributes = [.font: readingFont(18), .foregroundColor: p.ink, .paragraphStyle: para]
        text.string = body
        text.textStorage?.addAttributes([.font: readingFont(18), .foregroundColor: p.ink, .paragraphStyle: para],
                                        range: NSRange(location: 0, length: (body as NSString).length))
        text.setSelectedRange(NSRange(location: 0, length: 0))
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        let scroll = NSScrollView()
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = p.page
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 5
        scroll.layer?.borderColor = p.edge.cgColor
        scroll.layer?.borderWidth = 1

        let buttons = NSStackView()
        let send = MonoButton("Send", symbol: "paperplane") { [weak self] _ in self?.send(nil) }
        send.isOn = true
        buttons.addArrangedSubview(send)
        buttons.addArrangedSubview(MonoButton("Discard") { [weak self] _ in self?.discard(nil) })
        let hint = NSTextField(labelWithString: "\u{2318}Return sends   Esc discards")
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = p.dim
        buttons.addArrangedSubview(hint)
        buttons.spacing = 10

        let stack = NSStackView(views: [toBox, ccBox, subjectBox, scroll, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        for b in [toBox, ccBox, subjectBox, scroll] { b.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        stack.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: v.topAnchor, constant: 28),
            stack.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -20),
            stack.centerXAnchor.constraint(equalTo: v.centerXAnchor),
            stack.widthAnchor.constraint(equalTo: v.widthAnchor, multiplier: 0.86),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 820),
        ])
        v.translatesAutoresizingMaskIntoConstraints = false
        screen.addSubview(v)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: readingScroll.topAnchor),
            v.bottomAnchor.constraint(equalTo: readingScroll.bottomAnchor),
            v.leadingAnchor.constraint(equalTo: readingScroll.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: readingScroll.trailingAnchor),
        ])
        composer = v
        composerFields = (toField, ccField, subjectField, text)
        pendingReply = reply.map { ($0.messageID, ($0.references + " " + $0.messageID).trimmingCharacters(in: .whitespaces)) }
        screen.window?.makeFirstResponder(to.isEmpty ? toField : text)
    }

    private func closeComposer() {
        composer?.removeFromSuperview()
        composer = nil
        composerFields = nil
        pendingReply = nil
    }

    @objc func discard(_ sender: Any?) {
        closeComposer()
        screen.window?.makeFirstResponder(table)
        status("Letter discarded")
    }

    @objc func send(_ sender: Any?) {
        guard let f = composerFields, let a = account, let pw = password ?? (demo ? "" : nil) else { return }
        let to = MailAddress.parseList(f.to.stringValue)
        guard !to.isEmpty, to.allSatisfy({ $0.email.contains("@") }) else { status("Please add who the letter is for."); return }
        let out = SMTP.Outgoing(to: to, cc: MailAddress.parseList(f.cc.stringValue), subject: f.subject.stringValue,
                                body: f.body.string, inReplyTo: pendingReply?.inReplyTo, references: pendingReply?.references)
        status("Sending\u{2026}")
        Task { @MainActor in
            do {
                try await SMTP.send(out, account: a, password: pw)
                self.closeComposer()
                self.screen.window?.makeFirstResponder(self.table)
                self.status("Sent to \(to.map(\.display).joined(separator: ", "))")
            } catch {
                self.status("Could not send: \(error.localizedDescription)")
            }
        }
    }

    @objc func signOut(_ sender: Any?) {
        if let a = account { MailKeychain.remove(a.email) }
        MailAccount.saved = nil
        let c = client
        client = nil
        password = nil
        messages = []
        table.reloadData()
        showEmpty()
        Task { await c?.logout() }
        showSetup()
    }

    @objc func closeLetters(_ sender: Any?) {
        if browse != nil { browse?.closeBrowser(nil); return }
        if composer != nil { discard(nil); return }
        exit()
    }

    private func exit() {
        let c = client
        client = nil
        Task { await c?.logout() }
        let done = onExit
        onExit = nil
        done?()
    }

    func makeMenus() -> [NSMenu] {
        let me: AnyObject = self
        let m = NSMenu(title: "Letters")
        [NSMenuItem.mono("Write", #selector(compose(_:)), "n", target: me),
         .mono("Reply", #selector(reply(_:)), "r", target: me),
         .mono("Reply All", #selector(replyAll(_:)), "r", [.command, .shift], target: me),
         .mono("Forward", #selector(forward(_:)), "f", [.command, .shift], target: me),
         .mono("Send", #selector(send(_:)), "\r", target: me),
         .separator(),
         .mono("Archive", #selector(archive(_:)), "e", target: me),
         .mono("Star", #selector(star(_:)), "l", [.command, .shift], target: me),
         .mono("Check for New Letters", #selector(refresh(_:)), "n", [.command, .shift], target: me),
         .separator(),
         .mono("Sign Out", #selector(signOut(_:)), "", target: me),
         .mono("Close", #selector(closeLetters(_:)), "w", target: me)].forEach(m.addItem)
        m.appearance = MonoPalette.current.appearance
        let edit = NSMenu(title: "Edit")
        [NSMenuItem.mono("Undo", Selector(("undo:")), "z"), .mono("Redo", Selector(("redo:")), "z", [.command, .shift]),
         .separator(), .mono("Cut", #selector(NSText.cut(_:)), "x"), .mono("Copy", #selector(NSText.copy(_:)), "c"),
         .mono("Paste", #selector(NSText.paste(_:)), "v"), .mono("Select All", #selector(NSText.selectAll(_:)), "a")].forEach(edit.addItem)
        edit.appearance = MonoPalette.current.appearance
        return [m, edit]
    }

    // MARK: Demo

    /// Sample letters for trying the screens without an account (MINIMALIA_MAIL_DEMO=1).
    private func loadDemo() {
        account = MailAccount.preset(name: "Demo", email: "demo@example.com")
        let raw = """
        From: Ada Lovelace <ada@example.com>\r
        Subject: =?UTF-8?Q?Notes_on_the_Analytical_Engine_=E2=80=94_draft?=\r
        Content-Type: multipart/alternative; boundary="b1"\r
        \r
        --b1\r
        Content-Type: text/plain; charset=utf-8\r
        Content-Transfer-Encoding: quoted-printable\r
        \r
        Dear Eric,=0D=0A=0D=0AI have finished the notes on the engine. The machine might compose elaborate pieces of music of any degree of complexity.=0D=0A=0D=0AMore at https://en.wikipedia.org/wiki/Analytical_engine=0D=0A=0D=0AWarmly,=0D=0AAda=0D=0A=0D=0A> Earlier: could you send the notes by Friday?\r
        --b1\r
        Content-Type: text/html; charset=utf-8\r
        \r
        <p>Dear Eric,</p><p>I have finished the notes.</p>\r
        --b1--\r
        """
        let (body, _) = MIME.readable(Data(raw.utf8))
        let subject = MIME.decodeWords("=?UTF-8?Q?Notes_on_the_Analytical_Engine_=E2=80=94_draft?=")
        let now = Date()
        messages = [
            MailMessage(uid: 1, from: MailAddress(name: "Ada Lovelace", email: "ada@example.com"), to: [MailAddress(name: "Eric", email: "demo@example.com")],
                        cc: [], replyTo: [], subject: subject, date: now.addingTimeInterval(-3600), seen: false, flagged: false,
                        messageID: "<1@example.com>", references: "", preview: String(body.replacingOccurrences(of: "\n", with: " ").prefix(150)), body: body),
            MailMessage(uid: 2, from: MailAddress(name: "Project Gutenberg", email: "news@example.org"), to: [], cc: [], replyTo: [],
                        subject: "New books this week", date: now.addingTimeInterval(-86_400), seen: true, flagged: true,
                        messageID: "<2@example.org>", references: "", preview: "Fifty new titles, including a fresh edition of Middlemarch.", body: nil),
            MailMessage(uid: 3, from: MailAddress(name: "", email: "registrar@example.edu"), to: [], cc: [], replyTo: [],
                        subject: "Room change for Thursday", date: now.addingTimeInterval(-400_000), seen: true, flagged: false,
                        messageID: "<3@example.edu>", references: "", preview: "The seminar moves to the library reading room.", body: nil),
        ]
        table.reloadData()
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        status("Demo mailbox")
    }
}
