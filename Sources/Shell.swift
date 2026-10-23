import AppKit

struct FileEntry: Sendable {
    let url: URL
    let isDir: Bool
    let isPackage: Bool
    let size: Int64
    let date: Date?
}

/// The command interpreter. C:\ is your home folder.
@MainActor
final class Shell {
    enum ListItem {
        case file(URL)
        case link(URL, String)
    }

    let console: ConsoleTextView
    unowned let app: AppController
    let fm = FileManager.default
    let home = Paths.home
    var cwd: URL
    var lastList: [ListItem] = []
    var lastPage: TextPage?
    var lastBrowsed: URL?
    private var currentTask: Task<Void, Never>?
    private var bootSkip = false

    static let commands = ["AI", "ASK", "BOOT", "CD", "CLS", "COLOR", "COPY", "DATE", "DEL", "DIR", "DOCS", "ECHO",
                           "EDIT", "EXIT", "FONT", "GO", "HELP", "LIBRARY", "MD", "MEM", "MORE", "MOVE", "NOTE",
                           "NOTES", "OPEN", "RD", "READ", "REN", "RSS", "SAVE", "SEARCH", "SUMMARIZE", "TIME",
                           "TYPE", "VER", "VIEW", "WEB", "WIKI", "WINDOW", "FOCUS", "FOLIO", "BROWSE", "SHELF", "PAD", "WRITE", "NEWS", "PROGRAMS", "CURSOR", "CHIME"]
                           + extraCommands

    #if MINIMALIA_EXTRAS
    static let extraCommands = ["GAMES", "BLOCKS", "LETTERS", "FILM"]
    #else
    static let extraCommands: [String] = []
    #endif

    static let logo = [
        "  \u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}",
        "  \u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}",
        String(repeating: "\u{2588}", count: 28),
        "\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}      \u{2588}\u{2588}\u{2588}\u{2588}      \u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}",
        "\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}      \u{2588}\u{2588}\u{2588}\u{2588}      \u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}",
        "\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}      \u{2588}\u{2588}\u{2588}\u{2588}      \u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}",
        "\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}      \u{2588}\u{2588}\u{2588}\u{2588}      \u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}",
    ]

    init(console: ConsoleTextView, app: AppController) {
        self.console = console
        self.app = app
        cwd = Paths.home
        console.onInterrupt = { [weak self] in self?.interrupt() }
        console.completer = { [weak self] token, first in self?.complete(token, first: first) ?? [] }
    }

    /// The mark, then the folder inside home (nothing at home), then the caret.
    var prompt: String {
        let p = mPath(cwd)
        let folder = p == "m:\\" ? "" : (p.hasPrefix("m:\\") ? String(p.dropFirst(3)) : p)
        return ConsoleTextView.logoToken + folder
    }

    // MARK: Main loop

    func start() async {
        await boot()
        while true {
            let line = await console.readLine(prompt: prompt)
            let before = console.length
            let task = Task { @MainActor in await self.execute(line) }
            currentTask = task
            await task.value
            currentTask = nil
            if console.length > before {
                if !console.endsWithNewline { console.write("\n") }
                console.write("\n")
            }
        }
    }

    private func interrupt() {
        guard let t = currentTask, !t.isCancelled else { return }
        t.cancel()
        console.write("^C\n")
    }

    private func pause(_ seconds: Double) async {
        if bootSkip { return }
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private func boot() async {
        bootSkip = !Settings.shared.bootAnimation
        console.keyInterceptor = { [weak self] _ in self?.bootSkip = true; return true }
        defer { console.keyInterceptor = nil }

        Sound.chime()
        for line in Self.logo { console.writeLine("  " + line, .logo) }
        console.writeLine()
        console.writeLine("Minimalia Personal Computer", .bright)
        console.writeLine("BIOS Version 1.00", .dim)
        console.writeLine()
        await pause(0.25)
        // Count up to the memory this Mac really has, as the old machines counted to 640K.
        let totalK = Int64(ProcessInfo.processInfo.physicalMemory / 1024)
        let width = commas(totalK).count
        console.write("Memory test: " + String(repeating: " ", count: width) + "0K")
        let steps = 24
        for i in 1...steps {
            await pause(0.035)
            let k = totalK * Int64(i * i) / Int64(steps * steps)
            console.replaceLastLine("Memory test: " + pad(commas(k), width, right: true) + "K")
        }
        console.write(" OK\n")
        await pause(0.3)
        console.writeLine()
        console.writeLine("Starting Minimalia...")
        await pause(0.6)
        console.writeLine()
        console.writeLine("Minimalia  Version 1.0", .bright)
        console.writeLine("(C) Copyright Eric Vaz 2026", .dim)
        console.writeLine()
        console.writeLine("Current date is " + format("EEE MM-dd-yyyy", Date()))
        console.writeLine("Current time is " + format("HH:mm:ss", Date()))
        console.writeLine()
        console.writeLine("Type HELP for a list of commands.", .dim)
        console.writeLine()
    }

    // MARK: Parsing

    private func splitCommand(_ line: String) -> (String, String) {
        let chars = Array(line)
        var i = 0
        while i < chars.count, chars[i].isLetter || chars[i].isNumber || chars[i] == "?" { i += 1 }
        if i == 0 { return (line, "") }
        return (String(chars[0..<i]), String(chars[i...]).trimmingCharacters(in: .whitespaces))
    }

    private func tokenize(_ s: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var inQuote = false
        var quoted = false
        for ch in s {
            if ch == "\"" { inQuote.toggle(); quoted = true; continue }
            if ch == " " && !inQuote {
                if !cur.isEmpty || quoted { out.append(cur) }
                cur = ""
                quoted = false
            } else {
                cur.append(ch)
            }
        }
        if !cur.isEmpty || quoted { out.append(cur) }
        return out
    }

    private func isSwitch(_ t: String) -> Bool {
        t.hasPrefix("/") && t.count <= 4 && t.count >= 2 && t.dropFirst().allSatisfy { $0.isLetter || $0 == ":" }
    }

    /// Splits arguments into one path (spaces allowed) and a set of switches like /W.
    private func pathAndSwitches(_ rest: String) -> (String, Set<String>) {
        let toks = tokenize(rest)
        let sw = Set(toks.filter(isSwitch).map { $0.uppercased().replacingOccurrences(of: ":", with: "") })
        let path = toks.filter { !isSwitch($0) }.joined(separator: " ")
        return (path, sw)
    }

    // MARK: Paths

    /// Paths as Minimalia shows them: m:\\ is your home folder, m:\\Desktop a folder inside it.
    func mPath(_ u: URL) -> String {
        let p = u.standardizedFileURL.path
        let h = home.path
        if p == h { return "m:\\" }
        if p.hasPrefix(h + "/") {
            return "m:\\" + String(p.dropFirst(h.count + 1)).replacingOccurrences(of: "/", with: "\\")
        }
        return p
    }

    func exists(_ u: URL) -> Bool { fm.fileExists(atPath: u.path) }

    func isDir(_ u: URL) -> Bool {
        var d: ObjCBool = false
        return fm.fileExists(atPath: u.path, isDirectory: &d) && d.boolValue
    }

    func resolve(_ raw: String) -> URL {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if s.count >= 2, s.hasPrefix("\""), s.hasSuffix("\"") { s = String(s.dropFirst().dropLast()) }
        s = s.replacingOccurrences(of: "\\", with: "/")
        var base = cwd
        let upper = s.uppercased()
        let insideHome = cwd.path == home.path || cwd.path.hasPrefix(home.path + "/")
        if s.lowercased().hasPrefix("m:") {
            s = String(s.dropFirst(2))
            if s.hasPrefix("/") { s.removeFirst() }
            base = home
        } else if upper.hasPrefix("C:") {
            s = String(s.dropFirst(2))
            if s.hasPrefix("/") { s.removeFirst(); base = home } else if !insideHome { base = home }
        } else if upper.hasPrefix("Z:") {
            s = String(s.dropFirst(2))
            if s.hasPrefix("/") { s.removeFirst() }
            base = URL(fileURLWithPath: "/")
        } else if s.hasPrefix("~") {
            s.removeFirst()
            if s.hasPrefix("/") { s.removeFirst() }
            base = home
        } else if s.hasPrefix("/") {
            let rel = String(s.dropFirst())
            let inHome = fixCase(home.appendingPathComponent(rel))
            let absolute = URL(fileURLWithPath: s).standardizedFileURL
            if s == "/" || exists(inHome) || !exists(absolute) {
                s = rel
                base = home
            } else {
                return absolute
            }
        }
        if s.isEmpty { return base }
        let result = fixCase(base.appendingPathComponent(s).standardizedFileURL)
        if base.path.hasPrefix(home.path), home.path.hasPrefix(result.path + "/") || result.path == "/" {
            return home
        }
        return result
    }

    private func fixCase(_ u: URL) -> URL {
        if exists(u) { return u }
        var cur = URL(fileURLWithPath: "/")
        for comp in u.pathComponents.dropFirst() {
            let next = cur.appendingPathComponent(comp)
            if exists(next) { cur = next; continue }
            guard let items = try? fm.contentsOfDirectory(atPath: cur.path),
                  let m = items.first(where: { $0.caseInsensitiveCompare(comp) == .orderedSame }) else { return u }
            cur = cur.appendingPathComponent(m)
        }
        return cur
    }

    private func matches(_ name: String, _ pattern: String) -> Bool {
        let p = pattern == "*.*" ? "*" : pattern
        return fnmatch(p, name, FNM_CASEFOLD) == 0
    }

    private func hasWildcard(_ s: String) -> Bool { s.contains("*") || s.contains("?") }

    /// "3" or "#3" refers to item 3 of the last numbered list, unless a file by that name exists.
    private func listItem(_ arg: String) -> ListItem? {
        let a = arg.hasPrefix("#") ? String(arg.dropFirst()) : arg
        guard let n = Int(a), n >= 1, n <= lastList.count else { return nil }
        if !arg.hasPrefix("#") && exists(resolve(arg)) { return nil }
        return lastList[n - 1]
    }

    private func fileArg(_ arg: String) -> URL {
        if case .file(let u)? = listItem(arg) { return u }
        return resolve(arg)
    }

    private func complete(_ token: String, first: Bool) -> [String] {
        if first {
            return Self.commands.filter { $0.hasPrefix(token.uppercased()) }
        }
        let t = token.replacingOccurrences(of: "\"", with: "")
        let sepIdx = t.lastIndex(where: { $0 == "\\" || $0 == "/" })
        let dirPart = sepIdx.map { String(t[...$0]) } ?? ""
        let namePart = sepIdx.map { String(t[t.index(after: $0)...]) } ?? t
        let dir = dirPart.isEmpty ? cwd : resolve(dirPart)
        guard let items = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }
        let sep = dirPart.contains("/") ? "/" : "\\"
        return items
            .filter { (namePart.hasPrefix(".") || !$0.hasPrefix(".")) && $0.lowercased().hasPrefix(namePart.lowercased()) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { name in
                let full = dirPart + name + (isDir(dir.appendingPathComponent(name)) ? sep : "")
                return full.contains(" ") ? "\"\(full)\"" : full
            }
    }

    // MARK: Formatting

    private func format(_ pattern: String, _ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = pattern
        return f.string(from: d)
    }

    private func dosDate(_ d: Date?) -> String {
        guard let d else { return String(repeating: " ", count: 16) }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MM-dd-yy  hh:mma"
        f.amSymbol = "a"
        f.pmSymbol = "p"
        return f.string(from: d)
    }

    private func commas(_ n: Int64) -> String {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US")
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    private func pad(_ s: String, _ w: Int, right: Bool = false) -> String {
        if s.count >= w { return s }
        let sp = String(repeating: " ", count: w - s.count)
        return right ? sp + s : s + sp
    }

    private func fit(_ s: String, _ w: Int) -> String {
        s.count <= w ? pad(s, w) : String(s.prefix(w - 1)) + "\u{2026}"
    }

    private func error(_ s: String) { console.writeLine(s, .error) }

    // MARK: Dispatch

    func execute(_ raw: String) async {
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return }

        if line.lowercased() == "m:" || line.lowercased() == "m:\\" {
            cwd = home
            return
        }

        let (word, rest) = splitCommand(line)
        switch word.uppercased() {
        case "HELP", "?": help(rest)
        case "DIR": await dir(rest)
        case "CD", "CHDIR": cd(rest)
        case "MD", "MKDIR": md(rest)
        case "RD", "RMDIR": rd(rest)
        case "DEL", "ERASE": await del(rest)
        case "COPY": await copyMove(rest, move: false)
        case "MOVE": await copyMove(rest, move: true)
        case "REN", "RENAME": ren(rest)
        case "TYPE": typeFile(rest)
        case "VIEW", "MORE": await view(rest)
        case "EDIT": await edit(rest)
        case "WRITE": await write(rest)
        case "FOLIO", "WORD": await folio(rest)
        case "PROGRAMS", "APPS": programs()
        case "SHELF", "BOOKS": await shelf(rest)
        #if MINIMALIA_EXTRAS
        case "GAMES", "PLAY": await app.run(GamesProgram())
        case "BLOCKS": await app.run(BlocksProgram())
        case "LETTERS", "MAIL", "GMAIL": await app.run(LettersProgram())
        case "FILM", "FILMS", "MOVIES":
            let (path, _) = pathAndSwitches(rest)
            if !path.isEmpty {
                let u = resolve(path)
                guard isDir(u) else { error("Folder not found - \(path)"); return }
                FilmStore.folders = Array(Set(FilmStore.folders + [u])).sorted { $0.path < $1.path }
                console.writeLine("Film will also look in \(mPath(u)).", .dim)
            }
            await app.run(FilmProgram(home: home))
        #endif
        case "PAD", "WP": await self.word(rest)
        case "NEWS": await news(rest)
        case "DOCS": await docs(rest)
        case "NOTE": note(rest)
        case "NOTES": await openFile(Paths.notes, typewriter: false, atEnd: true)
        case "OPEN", "START": open(rest)
        case "WEB", "SEARCH", "INTERNET", "GOOGLE": await web(rest)
        case "BROWSE", "BROWSER": await go(rest)
        case "READ": await read(rest)
        case "GO", "RSS", "URL": await go(rest)
        case "WIKI": await wiki(rest)
        case "SAVE": await save()
        case "LIBRARY": library()
        case "AI", "ASK": await ai(rest)
        case "SUMMARIZE", "SUMMARISE": await summarize(rest)
        case "CLS": console.clearScreen()
        case "VER":
            console.writeLine()
            console.writeLine("Minimalia Version 1.0")
            console.writeLine("Running on macOS \(ProcessInfo.processInfo.operatingSystemVersionString)", .dim)
        case "DATE": console.writeLine("Current date is " + format("EEE MM-dd-yyyy", Date()))
        case "TIME": console.writeLine("Current time is " + format("HH:mm:ss.SS", Date()))
        case "MEM": mem()
        case "COLOR", "COLOUR": color(rest)
        case "FONT": font(rest)
        case "BOOT": boot(rest)
        case "CURSOR": cursor(rest)
        case "FOCUS": await focus(rest)
        case "CHIME":
            switch rest.uppercased() {
            case "ON": Settings.shared.chime = true; Sound.chime(); console.writeLine("Start-up chime on.", .dim)
            case "OFF": Settings.shared.chime = false; console.writeLine("Start-up chime off.", .dim)
            default: console.writeLine("CHIME is \(Settings.shared.chime ? "ON" : "OFF"). Type CHIME ON or CHIME OFF.")
            }
        case "ECHO": console.writeLine(rest.isEmpty ? "ECHO is on" : rest)
        case "WINDOW", "FULLSCREEN":
            if FocusSession.shared.active { console.writeLine("Full screen stays on during a focus session.") } else { app.window.toggleFullScreen(nil) }
        case "EXIT", "QUIT":
            if FocusSession.shared.active {
                console.writeLine("A focus session is running until \(FocusSession.shared.endsText). FOCUS END finishes it early.")
            } else {
                NSApp.terminate(nil)
            }
        default:
            error("Unknown command. Type HELP for the list.")
        }
    }

    // MARK: Help

    private struct HelpLine {
        var parts: [(String, ConsoleTextView.Style)]
        var width: Int { parts.reduce(0) { $0 + $1.0.count } }
    }

    private static let helpGroups: [(String, [(String, String)])] = [
        ("FILES", [
            ("DIR [path]", "List files. /W wide, /S subfolders, /A hidden, /OD by date"),
            ("CD [path]", "Change folder. CD.. goes up, CD\\ goes home"),
            ("TYPE file", "Print a file: text, Word, RTF, ODT or PDF"),
            ("DOCS [word]", "Find your Word documents, newest first"),
            ("NOTE text", "Add a line to your notebook. NOTES opens it"),
            ("MD RD REN COPY MOVE", "The usual. Quote names that have spaces"),
            ("DEL file", "Move files to the Trash"),
            ("OPEN file", "Hand a file to its own macOS app"),
        ]),
        ("INTERNET", [
            ("WEB words", "Search Google in Minimalia Browse"),
            ("GO address", "Open a site in Minimalia Browse"),
            ("WIKI topic", "Open a Wikipedia article"),
            ("NEWS [source]", "Headlines: CBC, NPR, BBC and more"),
            ("READ n", "Open item n from DOCS or LIBRARY"),
            ("SAVE LIBRARY", "Keep the last page; list saved pages"),
            ("SUMMARIZE [file|n]", "On-device summary of a file or the last page"),
        ]),
        ("COMFORT", [
            ("COLOR [name]", "CALM and PAPER are the low-stimulation schemes"),
            ("FONT [name|size]", "Typeface and size (also \u{2318}+ and \u{2318}-)"),
            ("FOCUS minutes", "Stay here: no switching apps until the time is up"),
            ("CURSOR STEADY|BLINK", "A steady cursor is the default"),
            ("BOOT ON|OFF", "Show or skip the start-up screen"),
            ("CHIME ON|OFF", "The start-up chime"),
            ("WINDOW", "Leave or return to full screen"),
        ]),
        ("SYSTEM", [
            ("HELP [command]", "This list, or more about one command"),
            ("PROGRAMS", "Programs installed in Minimalia"),
            ("CLS VER DATE TIME", "Clear the screen and the old favourites"),
            ("EXIT", "Return to your Mac"),
        ]),
    ]

    private var programRows: [(String, String)] {
        ProgramRegistry.installed.flatMap { $0.usage }
    }

    private func helpBlock(_ title: String, _ rows: [(String, String)], cmdWidth: Int, descWidth: Int) -> [HelpLine] {
        var out = [HelpLine(parts: [(" " + title, .bright)])]
        for (cmd, desc) in rows {
            var lines: [String] = []
            var cur = ""
            for w in desc.split(separator: " ") {
                if !cur.isEmpty && cur.count + 1 + w.count > descWidth { lines.append(cur); cur = "" }
                cur += (cur.isEmpty ? "" : " ") + w
            }
            if !cur.isEmpty { lines.append(cur) }
            for (i, l) in lines.enumerated() {
                out.append(HelpLine(parts: [("   " + pad(i == 0 ? cmd : "", cmdWidth), .normal), (l, .dim)]))
            }
        }
        out.append(HelpLine(parts: []))
        return out
    }

    private func writeHelpLine(_ line: HelpLine, padTo: Int? = nil) {
        for (t, style) in line.parts { console.write(t, style) }
        if let padTo, line.width < padTo { console.write(String(repeating: " ", count: padTo - line.width)) }
    }

    private func help(_ topic: String = "") {
        var topic = topic.trimmingCharacters(in: .whitespaces).uppercased()
        if topic == "WORD" { topic = "FOLIO" }
        if !topic.isEmpty { helpTopic(topic); return }

        let cols = console.columns
        let two = cols >= 110
        let colWidth = two ? min(84, (cols - 4) / 2) : min(cols, 100)
        let cmdWidth = 22
        let descWidth = max(20, colWidth - cmdWidth - 3)

        var blocks: [[HelpLine]] = []
        blocks.append(helpBlock("PROGRAMS", programRows, cmdWidth: cmdWidth, descWidth: descWidth))
        for (title, rows) in Self.helpGroups {
            blocks.append(helpBlock(title, rows, cmdWidth: cmdWidth, descWidth: descWidth))
        }

        console.writeLine()
        if !two {
            blocks.joined().forEach { writeHelpLine($0); console.write("\n") }
        } else {
            // Split the blocks, in order, where the two columns come out closest in length.
            let sizes = blocks.map(\.count)
            let total = sizes.reduce(0, +)
            var best = 1
            var bestDiff = Int.max
            var run = 0
            for k in 1..<blocks.count {
                run += sizes[k - 1]
                let diff = abs(total - 2 * run)
                if diff < bestDiff { bestDiff = diff; best = k }
            }
            let left = Array(blocks[..<best].joined())
            let right = Array(blocks[best...].joined())
            for i in 0..<max(left.count, right.count) {
                let l = i < left.count ? left[i] : HelpLine(parts: [])
                writeHelpLine(l, padTo: colWidth + 4)
                if i < right.count { writeHelpLine(right[i]) }
                console.write("\n")
            }
        }
        console.writeLine(" Keys: \u{2191}\u{2193} recall commands, Tab completes names, Ctrl+C stops, Esc clears the line.", .dim)
        console.writeLine(" HELP FOLIO, HELP DIR and so on explain one command.", .dim)
    }

    private func helpTopic(_ topic: String) {
        console.writeLine()
        if let p = ProgramRegistry.installed.first(where: { $0.command == topic }) {
            console.writeLine(" \(p.command)  \(p.name)", .bright)
            console.writeLine(" \(p.summary)", .dim)
            console.writeLine()
            for (c, d) in p.usage {
                console.write("   " + pad(c, 24))
                console.writeLine(d, .dim)
            }
            if !p.keys.isEmpty {
                console.writeLine()
                console.writeLine(" Inside \(p.name):", .bright)
                for k in p.keys { console.writeLine("   " + k, .dim) }
            }
            return
        }
        let rows = (Self.helpGroups.flatMap { $0.1 } + programRows).filter { row in
            row.0.split(separator: " ").contains { $0.uppercased() == topic }
        }
        guard !rows.isEmpty else { error("No help for \(topic). Type HELP for the list."); return }
        for (c, d) in rows {
            console.write("   " + pad(c, 24))
            console.writeLine(d, .dim)
        }
    }

    private func focus(_ rest: String) async {
        let f = FocusSession.shared
        let arg = rest.trimmingCharacters(in: .whitespaces).uppercased()
        if arg == "SETUP" {
            console.writeLine()
            console.writeLine(" Silencing notifications during focus", .bright)
            console.writeLine()
            console.writeLine(" macOS does not let apps turn Focus on, but a Shortcut can, and Minimalia runs it for you.")
            console.writeLine(" 1. Open the Shortcuts app and make a new shortcut named exactly: \(FocusSession.onShortcut)")
            console.writeLine("    Give it one action, Set Focus, set to turn Do Not Disturb on.")
            console.writeLine(" 2. Make a second shortcut named exactly: \(FocusSession.offShortcut)")
            console.writeLine("    with Set Focus turning Do Not Disturb off.")
            console.writeLine(" 3. That is all. Every FOCUS session will now start and end your Do Not Disturb.")
            console.writeLine()
            let ready = FocusSession.shortcutExists(FocusSession.onShortcut) && FocusSession.shortcutExists(FocusSession.offShortcut)
            console.writeLine(ready ? " Both shortcuts are in place." : " The shortcuts are not there yet.", .dim)
            console.writeLine(" Also useful: in System Settings, Focus, Do Not Disturb, add Minimalia under \u{201C}Turn on automatically\u{201D}, so Do Not Disturb starts whenever Minimalia opens.", .dim)
            return
        }
        if arg == "END" || arg == "STOP" {
            guard f.active else { console.writeLine("No focus session is running."); return }
            console.writeLine("\(f.minutesLeft) \(f.minutesLeft == 1 ? "minute" : "minutes") left. Take a breath.")
            let a = await console.readLine(prompt: "Type END to finish early, or press Return to keep going: ", history: false)
            if a.trimmingCharacters(in: .whitespaces).uppercased() == "END" {
                f.end()
                app.allowQuitDuringFocus = true
                console.writeLine("Focus session ended.", .dim)
            } else {
                console.writeLine("Carrying on until \(f.endsText).", .dim)
            }
            return
        }
        if arg.isEmpty {
            if f.active {
                console.writeLine("Focus session: \(f.minutesLeft) \(f.minutesLeft == 1 ? "minute" : "minutes") left, until \(f.endsText).")
            } else {
                console.writeLine("Type FOCUS and a number of minutes, e.g. FOCUS 45. FOCUS SETUP silences notifications too.")
            }
            return
        }
        guard let minutes = Int(arg), (5...240).contains(minutes) else {
            error("Choose between 5 and 240 minutes, e.g. FOCUS 45.")
            return
        }
        if f.active { console.writeLine("A session is already running until \(f.endsText).", .dim); return }
        app.allowQuitDuringFocus = false
        f.start(minutes: minutes)
        console.writeLine("Focus for \(minutes) minutes, until \(f.endsText). Switching apps is off until then.")
        if !FocusSession.shortcutExists(FocusSession.onShortcut) {
            console.writeLine("Notifications can still arrive. FOCUS SETUP shows how to silence them.", .dim)
        }
    }

    private func cursor(_ rest: String) {
        switch rest.uppercased() {
        case "BLINK": Settings.shared.cursorBlink = true; console.writeLine("The cursor blinks.", .dim)
        case "STEADY": Settings.shared.cursorBlink = false; console.writeLine("The cursor stays steady.", .dim)
        default: console.writeLine("The cursor is \(Settings.shared.cursorBlink ? "BLINK" : "STEADY"). Type CURSOR STEADY or CURSOR BLINK.")
        }
    }

    // MARK: Files

    private func listing(_ dir: URL, showHidden: Bool) -> [FileEntry] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey, .isSymbolicLinkKey]
        let items = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys,
                                                 options: showHidden ? [] : [.skipsHiddenFiles])) ?? []
        return items.map { u in
            var v = try? u.resourceValues(forKeys: Set(keys))
            if v?.isSymbolicLink == true, let target = try? u.resolvingSymlinksInPath().resourceValues(forKeys: Set(keys)) {
                v = target
            }
            return FileEntry(url: u, isDir: v?.isDirectory ?? false, isPackage: v?.isPackage ?? false,
                             size: Int64(v?.fileSize ?? 0), date: v?.contentModificationDate)
        }
    }

    private func dirLine(_ e: FileEntry, name: String) -> String {
        let kind: String
        if e.isPackage {
            kind = e.url.pathExtension.lowercased() == "app" ? "<APP>         " : "<DOC>         "
        } else if e.isDir {
            kind = "<DIR>         "
        } else {
            kind = pad(commas(e.size), 14, right: true)
        }
        return dosDate(e.date) + "   " + kind + "  " + name
    }

    private func freeSpace() -> (String, Int64) {
        let v = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeNameKey])
        return ((v?.volumeName ?? "MACINTOSH HD").uppercased(), v?.volumeAvailableCapacityForImportantUsage ?? 0)
    }

    private func dir(_ rest: String) async {
        let (path, sw) = pathAndSwitches(rest)
        var target = cwd
        var pattern: String?
        if !path.isEmpty {
            let u = resolve(path)
            if isDir(u) {
                target = u
            } else if hasWildcard(u.lastPathComponent) {
                target = u.deletingLastPathComponent()
                pattern = u.lastPathComponent
            } else if exists(u) {
                target = u.deletingLastPathComponent()
                pattern = u.lastPathComponent
            } else {
                console.writeLine()
                error("File not found")
                return
            }
        }
        guard isDir(target) else { error("Path not found"); return }
        if sw.contains("/S") { await dirRecursive(target, pattern: pattern ?? "*", hidden: sw.contains("/A")); return }

        var entries = listing(target, showHidden: sw.contains("/A"))
        if let p = pattern { entries = entries.filter { matches($0.url.lastPathComponent, p) } }
        if sw.contains("/OD") {
            entries.sort { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
        } else {
            entries.sort {
                let a = $0.isDir && !$0.isPackage
                let b = $1.isDir && !$1.isPackage
                if a != b { return a }
                return $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending
            }
        }

        let (vol, free) = freeSpace()
        console.writeLine()
        console.writeLine(" Volume \(vol)", .dim)
        console.writeLine(" Folder \(mPath(target))", .dim)
        console.writeLine()
        if entries.isEmpty {
            console.writeLine("File not found")
            return
        }

        if sw.contains("/W") {
            let names = entries.map { ($0.isDir && !$0.isPackage) ? "[\($0.url.lastPathComponent)]" : $0.url.lastPathComponent }
            let width = min(30, (names.map(\.count).max() ?? 12) + 3)
            let perRow = max(1, console.columns / width)
            var row = ""
            for (i, n) in names.enumerated() {
                row += fit(n, width - 1) + " "
                if (i + 1) % perRow == 0 { console.writeLine(row); row = "" }
            }
            if !row.isEmpty { console.writeLine(row) }
        } else {
            console.write(entries.map { dirLine($0, name: $0.url.lastPathComponent) + "\n" }.joined())
        }
        let files = entries.filter { !($0.isDir && !$0.isPackage) }
        let dirs = entries.count - files.count
        let bytes = files.reduce(Int64(0)) { $0 + $1.size }
        console.writeLine(pad("\(files.count)", 16, right: true) + " File(s)  " + pad(commas(bytes), 16, right: true) + " bytes", .dim)
        console.writeLine(pad("\(dirs)", 16, right: true) + " Dir(s)   " + pad(commas(free), 16, right: true) + " bytes free", .dim)
    }

    @concurrent
    nonisolated private static func findFiles(_ root: URL, pattern: String, hidden: Bool, limit: Int) async -> [FileEntry] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey]
        var opts: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
        if !hidden { opts.insert(.skipsHiddenFiles) }
        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: opts) else { return [] }
        let homeLibrary = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library").path
        let p = pattern == "*.*" ? "*" : pattern
        var out: [FileEntry] = []
        var seen = 0
        while let u = en.nextObject() as? URL {
            seen += 1
            if seen % 500 == 0 && Task.isCancelled { break }
            if !hidden && u.path == homeLibrary { en.skipDescendants(); continue }
            guard fnmatch(p, u.lastPathComponent, FNM_CASEFOLD) == 0 else { continue }
            let v = try? u.resourceValues(forKeys: Set(keys))
            out.append(FileEntry(url: u, isDir: v?.isDirectory ?? false, isPackage: v?.isPackage ?? false,
                                 size: Int64(v?.fileSize ?? 0), date: v?.contentModificationDate))
            if out.count >= limit { break }
        }
        return out
    }

    private func dirRecursive(_ root: URL, pattern: String, hidden: Bool) async {
        console.writeLine()
        console.writeLine(" Searching \(mPath(root)) for \(pattern.uppercased())...", .dim)
        let limit = 2000
        let found = await Self.findFiles(root, pattern: pattern, hidden: hidden, limit: limit)
        if Task.isCancelled { return }
        console.replaceLastLine(" Folder \(mPath(root)) and below", .dim)
        console.writeLine()
        if found.isEmpty { console.writeLine("File not found"); return }
        let prefix = root.path == "/" ? "/" : root.path + "/"
        var text = ""
        for e in found {
            let rel = e.url.path.hasPrefix(prefix) ? String(e.url.path.dropFirst(prefix.count)) : e.url.path
            text += dirLine(e, name: rel.replacingOccurrences(of: "/", with: "\\")) + "\n"
        }
        console.write(text)
        let files = found.filter { !($0.isDir && !$0.isPackage) }
        console.writeLine(pad("\(files.count)", 16, right: true) + " File(s)  " +
                          pad(commas(files.reduce(Int64(0)) { $0 + $1.size }), 16, right: true) + " bytes", .dim)
        if found.count >= limit { console.writeLine(" Stopped after \(limit) matches. Narrow the pattern to see more.", .dim) }
    }

    private func cd(_ rest: String) {
        let (path, _) = pathAndSwitches(rest)
        if path.isEmpty { console.writeLine(mPath(cwd)); return }
        let u = resolve(path)
        if isDir(u) { cwd = u } else { error("Invalid directory") }
    }

    private func md(_ rest: String) {
        let (path, _) = pathAndSwitches(rest)
        guard !path.isEmpty else { error("Required parameter missing"); return }
        do {
            try fm.createDirectory(at: resolve(path), withIntermediateDirectories: false)
        } catch {
            self.error("Unable to create directory")
        }
    }

    private func rd(_ rest: String) {
        let (path, _) = pathAndSwitches(rest)
        guard !path.isEmpty else { error("Required parameter missing"); return }
        let u = resolve(path)
        guard isDir(u) else { error("Invalid path, not directory,\nor directory not empty"); return }
        let contents = (try? fm.contentsOfDirectory(atPath: u.path))?.filter { $0 != ".DS_Store" } ?? []
        guard contents.isEmpty else { error("Invalid path, not directory,\nor directory not empty"); return }
        do { try fm.trashItem(at: u, resultingItemURL: nil) } catch { self.error("Unable to remove directory") }
    }

    private func targets(_ path: String) -> [URL] {
        let u = resolve(path)
        if hasWildcard(u.lastPathComponent) {
            let dir = u.deletingLastPathComponent()
            return listing(dir, showHidden: false)
                .filter { !($0.isDir && !$0.isPackage) && matches($0.url.lastPathComponent, u.lastPathComponent) }
                .map(\.url)
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        }
        if isDir(u) && !(u.pathExtension.count > 0) {
            return listing(u, showHidden: false).filter { !($0.isDir && !$0.isPackage) }.map(\.url)
        }
        return exists(u) ? [u] : []
    }

    private func confirm(_ question: String) async -> Bool {
        let a = await console.readLine(prompt: question + " ", history: false)
        return a.trimmingCharacters(in: .whitespaces).uppercased().hasPrefix("Y")
    }

    private func del(_ rest: String) async {
        let (path, _) = pathAndSwitches(rest)
        guard !path.isEmpty else { error("Required parameter missing"); return }
        let u = resolve(path)
        let list = targets(path)
        guard !list.isEmpty else { error("File not found"); return }
        if hasWildcard(u.lastPathComponent) && (u.lastPathComponent == "*" || u.lastPathComponent == "*.*") || isDir(u) {
            console.writeLine("All files in \(mPath(isDir(u) ? u : u.deletingLastPathComponent())) will be moved to the Trash!")
            guard await confirm("Are you sure (Y/N)?") else { return }
        }
        var n = 0
        for f in list {
            do { try fm.trashItem(at: f, resultingItemURL: nil); n += 1 } catch { self.error("Access denied - \(f.lastPathComponent)") }
        }
        console.writeLine("\(n) file(s) moved to the Trash", .dim)
    }

    private func copyMove(_ rest: String, move: Bool) async {
        let toks = tokenize(rest).filter { !isSwitch($0) }
        guard toks.count >= 1 else { error("Required parameter missing"); return }
        let sources = targets(toks[0])
        guard !sources.isEmpty else { error("File not found - \(toks[0])"); return }
        let dest = toks.count > 1 ? resolve(toks[1]) : cwd
        let destIsDir = isDir(dest) && dest.pathExtension.isEmpty
        if sources.count > 1 && !destIsDir { error("Cannot copy several files onto one file"); return }

        var done = 0
        var overwriteAll = false
        for src in sources {
            let target = destIsDir ? dest.appendingPathComponent(src.lastPathComponent) : dest
            if target.standardizedFileURL == src.standardizedFileURL {
                error("File cannot be copied onto itself")
                continue
            }
            if exists(target) {
                if !overwriteAll {
                    let a = await console.readLine(prompt: "Overwrite \(target.lastPathComponent) (Yes/No/All)? ", history: false)
                    let k = a.trimmingCharacters(in: .whitespaces).uppercased()
                    if k.hasPrefix("A") { overwriteAll = true } else if !k.hasPrefix("Y") { continue }
                }
                try? fm.trashItem(at: target, resultingItemURL: nil)
            }
            do {
                if move { try fm.moveItem(at: src, to: target) } else { try fm.copyItem(at: src, to: target) }
                done += 1
            } catch {
                self.error("Unable to \(move ? "move" : "copy") \(src.lastPathComponent)")
            }
        }
        console.writeLine(pad("\(done)", 9, right: true) + " file(s) \(move ? "moved" : "copied")")
    }

    private func ren(_ rest: String) {
        let toks = tokenize(rest)
        guard toks.count == 2 else { error("Required parameter missing. Use REN old new, quoting names with spaces."); return }
        let src = resolve(toks[0])
        let newName = toks[1].replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init) ?? toks[1]
        let dst = src.deletingLastPathComponent().appendingPathComponent(newName)
        guard exists(src) else { error("File not found"); return }
        let caseOnly = src.lastPathComponent.lowercased() == newName.lowercased()
        guard caseOnly || !exists(dst) else { error("Duplicate file name or file not found"); return }
        do { try fm.moveItem(at: src, to: dst) } catch { self.error("Duplicate file name or file not found") }
    }

    private func typeFile(_ rest: String) {
        let (path, _) = pathAndSwitches(rest)
        guard !path.isEmpty else { error("Required parameter missing"); return }
        let u = fileArg(path)
        guard exists(u), !isDir(u) || DocumentIO.richTypes[u.pathExtension.lowercased()] != nil else {
            error("File not found - \(path)"); return
        }
        do {
            let page = try DocumentIO.readableText(u)
            let body = page.plainText.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
            let lines = body.components(separatedBy: "\n")
            let limit = 3000
            console.writeLine(lines.prefix(limit).joined(separator: "\n"))
            if lines.count > limit { console.writeLine("(\(lines.count - limit) more lines. Use VIEW to read it all.)", .dim) }
        } catch {
            self.error(error.localizedDescription)
        }
    }

    private func view(_ rest: String) async {
        let (path, _) = pathAndSwitches(rest)
        guard !path.isEmpty else { error("Required parameter missing"); return }
        if case .link(let u, _)? = listItem(path) { await openWeb(u); return }
        let u = fileArg(path)
        guard exists(u) else { error("File not found - \(path)"); return }
        do {
            let page = try DocumentIO.readableText(u)
            await app.openReader(page, shell: self)
        } catch {
            self.error(error.localizedDescription)
        }
    }

    private func edit(_ rest: String) async {
        var (path, _) = pathAndSwitches(rest)
        if path.isEmpty {
            path = await console.readLine(prompt: "File name: ", history: false).trimmingCharacters(in: .whitespaces)
            if path.isEmpty { return }
        }
        await openFile(fileArg(path), typewriter: false, atEnd: false)
    }

    private func write(_ rest: String) async {
        let (path, _) = pathAndSwitches(rest)
        let u = path.isEmpty ? Paths.writing.appendingPathComponent(format("yyyy-MM-dd", Date()) + ".txt") : fileArg(path)
        await openFile(u, typewriter: true, atEnd: true)
    }

    private func openFile(_ u: URL, typewriter: Bool, atEnd: Bool) async {
        if isDir(u) && DocumentIO.richTypes[u.pathExtension.lowercased()] == nil {
            error("That is a directory. Use CD to enter it.")
            return
        }
        var doc: LoadedDoc
        if exists(u) {
            do { doc = try DocumentIO.load(u) } catch { self.error(error.localizedDescription); return }
            if case .readOnly(let what) = doc.kind {
                error("A \(what) file can only be read. Use VIEW \(u.lastPathComponent).")
                return
            }
        } else {
            guard isDir(u.deletingLastPathComponent()) else { error("Path not found"); return }
            doc = LoadedDoc(text: "", kind: DocumentIO.kindForNew(u))
        }
        if typewriter && atEnd && !doc.text.isEmpty && !doc.text.hasSuffix("\n\n") {
            doc.text += doc.text.hasSuffix("\n") ? "\n" : "\n\n"
        }
        await app.openEditor(url: u, doc: doc, typewriter: typewriter, atEnd: atEnd)
    }

    static let newsSources: [(name: String, title: String, url: String)] = [
        ("CBC", "CBC News", "https://www.cbc.ca/lite/news"),
        ("NPR", "NPR News", "https://text.npr.org"),
        ("CNN", "CNN Lite", "https://lite.cnn.com"),
        ("BBC", "BBC News", "https://feeds.bbci.co.uk/news/rss.xml"),
        ("GUARDIAN", "The Guardian, world", "https://www.theguardian.com/world/rss"),
        ("ALJAZEERA", "Al Jazeera", "https://www.aljazeera.com/xml/rss/all.xml"),
        ("HN", "Hacker News", "https://hnrss.org/frontpage"),
    ]

    private func news(_ rest: String) async {
        let arg = rest.trimmingCharacters(in: .whitespaces).uppercased()
        if arg.isEmpty {
            console.writeLine()
            console.writeLine(" NEWS SOURCES", .bright)
            console.writeLine()
            for (i, s) in Self.newsSources.enumerated() {
                console.write(pad("\(i + 1)", 4, right: true) + "  " + pad(s.name, 11))
                console.writeLine(s.title, .dim)
            }
            console.writeLine()
            console.writeLine(" Type NEWS CBC, or NEWS 1.", .dim)
            return
        }
        let source = Int(arg).flatMap { $0 >= 1 && $0 <= Self.newsSources.count ? Self.newsSources[$0 - 1] : nil }
            ?? Self.newsSources.first { $0.name == arg }
        guard let source, let url = URL(string: source.url) else { error("Unknown source. Type NEWS for the list."); return }
        await openWeb(url)
    }

    private func shelf(_ rest: String) async {
        let arg = rest.trimmingCharacters(in: .whitespaces)
        if !Gutenberg.hasCatalog || arg.uppercased() == "UPDATE" {
            if !Gutenberg.hasCatalog {
                console.writeLine("Shelf uses Project Gutenberg's free catalogue of 75,000 books (about 6 MB).")
                guard await confirm("Download it now (Y/N)?") else { return }
            }
            console.writeLine("Downloading the catalogue from gutenberg.org...", .dim)
            do {
                try await Gutenberg.downloadCatalog()
                console.replaceLastLine("Catalogue ready.", .dim)
            } catch {
                self.error("Unable to download the catalogue: \(Web.describe(error))")
                return
            }
            if arg.uppercased() == "UPDATE" { return }
        }
        await app.run(ShelfProgram(query: arg.isEmpty ? nil : arg))
    }

    private func programs() {
        console.writeLine()
        console.writeLine(" PROGRAMS INSTALLED", .bright)
        console.writeLine()
        for p in ProgramRegistry.installed {
            console.write("   " + pad(p.command, 9) + pad(p.name, 20))
            console.writeLine(p.summary, .dim)
        }
        console.writeLine()
        console.writeLine(" Type a program's name to start it, e.g. FOLIO letter", .dim)
    }

    private func folio(_ rest: String) async {
        var (path, _) = pathAndSwitches(rest)
        if path.isEmpty {
            path = await console.readLine(prompt: "Document name: ", history: false).trimmingCharacters(in: .whitespaces)
            if path.isEmpty { return }
        }
        var u = fileArg(path)
        if u.pathExtension.isEmpty && !exists(u) { u = u.appendingPathExtension("docx") }
        if isDir(u) && DocumentIO.richTypes[u.pathExtension.lowercased()] == nil {
            error("That is a directory. Use CD to enter it.")
            return
        }
        if exists(u) {
            do {
                let (content, doc) = try DocumentIO.loadAttributed(u)
                await app.run(WordProgram(url: u, content: content, doc: doc, existing: true))
            } catch {
                self.error(error.localizedDescription)
            }
        } else {
            guard isDir(u.deletingLastPathComponent()) else { error("Path not found"); return }
            let doc = LoadedDoc(text: "", kind: DocumentIO.kindForNew(u))
            await app.run(WordProgram(url: u, content: NSAttributedString(), doc: doc, existing: false))
        }
    }

    private func word(_ rest: String) async {
        var (path, _) = pathAndSwitches(rest)
        if path.isEmpty {
            path = await console.readLine(prompt: "Document name: ", history: false).trimmingCharacters(in: .whitespaces)
            if path.isEmpty { return }
        }
        var u = fileArg(path)
        if u.pathExtension.isEmpty && !exists(u) { u = u.appendingPathExtension("docx") }
        if isDir(u) && DocumentIO.richTypes[u.pathExtension.lowercased()] == nil {
            error("That is a directory. Use CD to enter it.")
            return
        }
        if exists(u) {
            do {
                let (content, doc) = try DocumentIO.loadAttributed(u)
                await app.openWord(url: u, content: content, doc: doc, existing: true)
            } catch {
                self.error(error.localizedDescription)
            }
        } else {
            guard isDir(u.deletingLastPathComponent()) else { error("Path not found"); return }
            let doc = LoadedDoc(text: "", kind: DocumentIO.kindForNew(u))
            await app.openWord(url: u, content: NSAttributedString(), doc: doc, existing: false)
        }
    }

    @concurrent
    nonisolated private static func spotlight(_ query: String, in dir: String) async -> [String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        p.arguments = ["-onlyin", dir, query]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return [] }
        return await withTaskCancellationHandler {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
        } onCancel: {
            p.terminate()
        }
    }

    private func docs(_ rest: String) async {
        let (term, sw) = pathAndSwitches(rest)
        let types = ["com.microsoft.word.doc", "org.openxmlformats.wordprocessingml.document", "public.rtf",
                     "org.oasis-open.opendocument.text", "com.apple.iwork.pages.sffpages", "com.apple.iwork.pages.pages",
                     "com.apple.rtfd", "com.microsoft.word.wordml"]
        var q = "(" + types.map { "kMDItemContentTypeTree == \"\($0)\"" }.joined(separator: " || ") + ")"
        let clean = term.replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "\\", with: "").replacingOccurrences(of: "*", with: "")
        if !clean.isEmpty {
            q += " && (kMDItemFSName == \"*\(clean)*\"cd || kMDItemTextContent == \"*\(clean)*\"cd)"
        }
        console.writeLine()
        console.writeLine(" Looking through your files for Word documents...", .dim)
        let paths = await Self.spotlight(q, in: home.path)
        if Task.isCancelled { return }
        let found = paths
            .filter { !$0.contains("/Library/") && !$0.contains("/.") && !$0.contains("/~$") }
            .map { URL(fileURLWithPath: $0) }
            .map { u -> (URL, Date) in (u, (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast) }
            .sorted { $0.1 > $1.1 }
        let show = sw.contains("/ALL") || sw.contains("/A") ? found : Array(found.prefix(40))
        console.replaceLastLine(" Word documents in m:\\" + (clean.isEmpty ? "" : " matching \"\(clean)\"") + ", newest first", .dim)
        console.writeLine()
        guard !show.isEmpty else { console.writeLine("No documents found."); return }
        lastList = show.map { .file($0.0) }
        let nameWidth = max(24, min(44, console.columns - 40))
        var text = ""
        for (i, (u, d)) in show.enumerated() {
            let folder = mPath(u.deletingLastPathComponent())
            text += pad("\(i + 1)", 4, right: true) + "  " + format("MM-dd-yy", d) + "  " + fit(u.lastPathComponent, nameWidth) + "  " + folder + "\n"
        }
        console.write(text)
        console.writeLine()
        if found.count > show.count { console.writeLine(" Showing \(show.count) of \(found.count). DOCS /ALL lists every one.", .dim) }
        console.writeLine(" FOLIO n opens one in Minimalia Folio, TYPE n prints it, SUMMARIZE n asks the AI.", .dim)
    }

    private func note(_ rest: String) {
        guard !rest.isEmpty else { error("Type NOTE followed by your note. NOTES opens the notebook."); return }
        let line = format("yyyy-MM-dd HH:mm", Date()) + "  " + rest + "\n"
        let u = Paths.notes
        if let h = try? FileHandle(forWritingTo: u) {
            h.seekToEndOfFile()
            h.write(Data(line.utf8))
            try? h.close()
        } else {
            try? line.write(to: u, atomically: true, encoding: .utf8)
        }
        console.writeLine("Noted.", .dim)
    }

    private func open(_ rest: String) {
        let (path, _) = pathAndSwitches(rest)
        guard !path.isEmpty else { error("Required parameter missing"); return }
        switch listItem(path) {
        case .link(let u, _)?:
            NSWorkspace.shared.open(u)
        case .file(let u)?:
            NSWorkspace.shared.open(u)
        case nil:
            let u = resolve(path)
            guard exists(u) else { error("File not found"); return }
            NSWorkspace.shared.open(u)
        }
    }

    // MARK: Internet

    private func web(_ rest: String) async {
        var q = rest.trimmingCharacters(in: .whitespaces)
        let upper = q.uppercased()
        if upper.hasPrefix("SEARCH ") { q = String(q.dropFirst(7)) }
        if upper.hasPrefix("READ ") { await read(String(q.dropFirst(5))); return }
        if upper.hasPrefix("GO ") { await go(String(q.dropFirst(3))); return }
        q = q.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        await browse(q.isEmpty ? nil : BrowseProgram.searchURL(q))
    }

    /// Opens Minimalia Browse at an address, a Google search, or the start page.
    private func browse(_ url: URL?) async {
        let b = BrowseProgram(start: url)
        b.onPage = { [weak self] u in
            self?.lastBrowsed = u
            self?.lastPage = nil
        }
        await app.run(b)
    }

    /// The page last open in the browser, as text, for SAVE and SUMMARIZE.
    private func lastBrowsedText() async -> TextPage? {
        guard let u = lastBrowsed else { return nil }
        console.writeLine("Fetching \(u.host ?? "the page")...", .dim)
        do {
            let p = try await Web.page(u)
            lastPage = p
            return p
        } catch {
            self.error("Unable to read page: \(Web.describe(error))")
            return nil
        }
    }

    private func read(_ rest: String) async {
        let arg = rest.trimmingCharacters(in: .whitespaces)
        guard !arg.isEmpty else {
            if let p = lastPage { await app.openReader(p, shell: self) } else { error("Type READ followed by a result number.") }
            return
        }
        switch listItem(arg) {
        case .link(let u, _)?:
            await openWeb(u)
        case .file(let u)?:
            await view(u.path)
        case nil:
            if let u = Web.address(arg), Int(arg) == nil {
                await openWeb(u)
            } else if exists(resolve(arg)) {
                await view(arg)
            } else {
                error("No result \(arg). Search with WEB first.")
            }
        }
    }

    private func go(_ rest: String) async {
        let arg = rest.trimmingCharacters(in: .whitespaces)
        if arg.isEmpty { await browse(nil); return }
        if case .link(let u, _)? = listItem(arg) { await browse(u); return }
        await browse(BrowseProgram.destination(for: arg))
    }

    private func wiki(_ rest: String) async {
        let topic = rest.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        guard !topic.isEmpty else { error("Type WIKI followed by a topic."); return }
        var c = URLComponents(string: "https://en.wikipedia.org/wiki/Special:Search")
        c?.queryItems = [URLQueryItem(name: "search", value: topic), URLQueryItem(name: "go", value: "Go")]
        await browse(c?.url)
    }

    private func openWeb(_ u: URL) async {
        await browse(u)
    }

    private func save() async {
        var page = lastPage
        if page == nil { page = await lastBrowsedText() }
        guard let p = page else { error("Nothing to save. Open a page first."); return }
        do {
            let u = try Library.save(p)
            console.writeLine("Saved to \(mPath(u))")
        } catch {
            self.error("Could not save: \(error.localizedDescription)")
        }
    }

    private func library() {
        let items = listing(Paths.library, showHidden: false)
            .filter { !$0.isDir }
            .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        console.writeLine()
        console.writeLine(" LIBRARY  \(mPath(Paths.library))", .dim)
        console.writeLine()
        guard !items.isEmpty else { console.writeLine("Your library is empty. Press S while reading a page, or type SAVE."); return }
        lastList = items.map { .file($0.url) }
        for (i, e) in items.enumerated() {
            console.writeLine(pad("\(i + 1)", 4, right: true) + "  " + format("MM-dd-yy", e.date ?? Date()) + "  " + e.url.deletingPathExtension().lastPathComponent)
        }
        console.writeLine()
        console.writeLine(" READ n opens one.", .dim)
    }

    // MARK: Intelligence

    private func ai(_ rest: String) async {
        if let reason = AIEngine.shared.unavailableReason { error(reason); return }
        if !rest.isEmpty {
            await AIEngine.shared.respond(rest, to: console)
            return
        }
        console.writeLine("Local intelligence ready. Nothing you type here leaves this Mac.", .dim)
        console.writeLine("Type EXIT to return to the prompt, NEW to start a fresh conversation.", .dim)
        while !Task.isCancelled {
            console.writeLine()
            let q = await console.readLine(prompt: "AI> ").trimmingCharacters(in: .whitespaces)
            if Task.isCancelled { return }
            switch q.uppercased() {
            case "EXIT", "QUIT", "BYE": return
            case "NEW": AIEngine.shared.reset(); console.writeLine("New conversation.", .dim); continue
            case "CLS": console.clearScreen(); continue
            case "": continue
            default: break
            }
            console.writeLine()
            await AIEngine.shared.respond(q, to: console)
        }
    }

    private func summarize(_ rest: String) async {
        if let reason = AIEngine.shared.unavailableReason { error(reason); return }
        let arg = rest.trimmingCharacters(in: .whitespaces)
        var text: String
        var label: String
        if arg.isEmpty {
            var page = lastPage
            if page == nil { page = await lastBrowsedText() }
            guard let p = page else { error("Nothing to summarize. Open a page first, or name a file."); return }
            text = p.bareText
            label = p.title
        } else if case .link(let u, let title)? = listItem(arg) {
            console.writeLine("Connecting to \(u.host ?? "")...", .dim)
            do {
                let p = try await Web.page(u)
                lastPage = p
                text = p.bareText
                label = title
            } catch {
                self.error("Unable to read page: \(Web.describe(error))")
                return
            }
        } else {
            let u = fileArg(arg)
            guard exists(u) else { error("File not found - \(arg)"); return }
            do {
                text = try DocumentIO.readableText(u).bareText
                label = u.lastPathComponent
            } catch {
                self.error(error.localizedDescription)
                return
            }
        }
        text = text.replacingOccurrences(of: "\n{2,}", with: "\n", options: .regularExpression)
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).count > 40 else { error("There is not enough text to summarize."); return }
        let clipped = text.count > 7000 ? String(text.prefix(7000)) : text
        console.writeLine("Summarizing \(label)" + (text.count > 7000 ? " (the first part)" : "") + "...", .dim)
        console.writeLine()
        let prompt = "Summarize the following text in about 120 words of plain prose. Then list its three most important points, one per line, each starting with a dash.\n\nTEXT:\n" + clipped
        await AIEngine.shared.respond(prompt, fresh: true, to: console)
    }

    // MARK: System

    private func mem() {
        let total = Int64(ProcessInfo.processInfo.physicalMemory)
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let ok = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        let page = Int64(vm_kernel_page_size)
        let free = ok == KERN_SUCCESS ? (Int64(stats.free_count) + Int64(stats.inactive_count) + Int64(stats.purgeable_count)) * page : 0
        let used = Int64(ProcessInfo.processInfo.physicalMemory) - free
        console.writeLine()
        console.writeLine(pad(commas(total), 20, right: true) + " bytes total memory")
        console.writeLine(pad(commas(max(0, used)), 20, right: true) + " bytes in use")
        console.writeLine(pad(commas(free), 20, right: true) + " bytes free")
        console.writeLine(pad("655,360", 20, right: true) + " bytes, all anyone needed in 1981", .dim)
    }

    private func color(_ rest: String) {
        let name = rest.trimmingCharacters(in: .whitespaces)
        if name.isEmpty {
            console.writeLine()
            for t in Themes.all {
                let mark = t.name == Settings.shared.theme.name ? "  (current)" : ""
                console.write("   " + pad(t.name, 8))
                console.writeLine(t.note + mark, .dim)
            }
            console.writeLine()
            console.writeLine(" Type COLOR AMBER to switch.", .dim)
            return
        }
        guard let t = Themes.named(name) else { error("Unknown colour. Type COLOR to see the choices."); return }
        Settings.shared.theme = t
        app.applyWindowTheme()
    }

    private func font(_ rest: String) {
        let arg = rest.trimmingCharacters(in: .whitespaces).uppercased()
        if arg.isEmpty {
            console.writeLine()
            for f in Fonts.all {
                let mark = f.name == Settings.shared.fontName ? "  (current)" : ""
                console.writeLine("   " + f.name + mark)
            }
            console.writeLine()
            console.writeLine(" Size is \(Int(Settings.shared.fontSize)). Type FONT COURIER or FONT 18.", .dim)
            return
        }
        if let n = Int(arg) {
            guard (9...48).contains(n) else { error("Choose a size from 9 to 48."); return }
            Settings.shared.fontSize = CGFloat(n)
        } else if Fonts.all.contains(where: { $0.name == arg }) {
            Settings.shared.fontName = arg
        } else {
            error("Unknown font. Type FONT to see the choices.")
        }
    }

    private func boot(_ rest: String) {
        switch rest.uppercased() {
        case "ON": Settings.shared.bootAnimation = true; console.writeLine("Start-up screen on.", .dim)
        case "OFF": Settings.shared.bootAnimation = false; console.writeLine("Start-up screen off.", .dim)
        default: console.writeLine("BOOT is \(Settings.shared.bootAnimation ? "ON" : "OFF"). Type BOOT ON or BOOT OFF.")
        }
    }
}
