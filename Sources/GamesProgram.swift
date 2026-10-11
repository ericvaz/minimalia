import AppKit

/// Something to play: Minimalia's own game, a DOS game for DOSBox, a console game for RetroArch, or classic Mac.
struct Game {
    enum Kind { case blocks, dos(URL), console(URL, core: String, system: String), classicMac }
    let title: String
    let detail: String
    let kind: Kind
}

enum GameLibrary {
    static var root: URL {
        let u = Paths.data.appendingPathComponent("GAMES")
        for sub in ["DOS", "CONSOLE"] {
            try? FileManager.default.createDirectory(at: u.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        return u
    }

    static var dosFolder: URL { root.appendingPathComponent("DOS") }
    static var consoleFolder: URL { root.appendingPathComponent("CONSOLE") }

    static let dosbox = URL(fileURLWithPath: "/Applications/DOSBox Staging.app/Contents/MacOS/dosbox")
    static let retroarch = URL(fileURLWithPath: "/Applications/RetroArch.app/Contents/MacOS/RetroArch")
    static var coresDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/RetroArch/cores")
    }

    /// Console game files by extension: the RetroArch core and the system's name.
    static let systems: [String: (core: String, system: String)] = [
        "md": ("genesis_plus_gx", "Mega Drive"), "gen": ("genesis_plus_gx", "Mega Drive"),
        "smd": ("genesis_plus_gx", "Mega Drive"), "bin": ("genesis_plus_gx", "Mega Drive"),
        "sms": ("genesis_plus_gx", "Master System"), "gg": ("genesis_plus_gx", "Game Gear"),
        "sfc": ("snes9x", "Super Nintendo"), "smc": ("snes9x", "Super Nintendo"),
        "nes": ("nestopia", "NES"),
        "gb": ("gambatte", "Game Boy"), "gbc": ("gambatte", "Game Boy Color"),
        "gba": ("mgba", "Game Boy Advance"),
    ]

    static func scan() -> [Game] {
        var games = [Game(title: "BLOCKS", detail: "Falling blocks, made for Minimalia", kind: .blocks)]
        let fm = FileManager.default

        // DOS: each folder is a game. A .zip dropped in is unpacked into its own folder first.
        let dosItems = (try? fm.contentsOfDirectory(at: dosFolder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        for zip in dosItems where zip.pathExtension.lowercased() == "zip" {
            let dest = dosFolder.appendingPathComponent(zip.deletingPathExtension().lastPathComponent)
            if !fm.fileExists(atPath: dest.path) { unzip(zip, to: dest) }
        }
        let dosGames = ((try? fm.contentsOfDirectory(at: dosFolder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        for folder in dosGames {
            games.append(Game(title: folder.lastPathComponent, detail: "DOS", kind: .dos(folder)))
        }

        // Consoles: game files by extension, anywhere under CONSOLE.
        if let en = fm.enumerator(at: consoleFolder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            var found: [Game] = []
            while let u = en.nextObject() as? URL {
                let ext = u.pathExtension.lowercased()
                if ext == "zip" {
                    let dest = u.deletingPathExtension()
                    if !fm.fileExists(atPath: dest.path) { unzip(u, to: dest) }
                    continue
                }
                guard let sys = systems[ext] else { continue }
                let title = u.deletingPathExtension().lastPathComponent
                    .replacingOccurrences(of: "\\s*[\\(\\[][^\\)\\]]*[\\)\\]]", with: "", options: .regularExpression)
                found.append(Game(title: title.isEmpty ? u.lastPathComponent : title, detail: sys.system,
                                  kind: .console(u, core: sys.core, system: sys.system)))
            }
            games += found.sorted { ($0.detail, $0.title) < ($1.detail, $1.title) }
        }

        games.append(Game(title: "Classic Macintosh", detail: "Infinite Mac: System 6 to Mac OS 9 with its games, in Minimalia Browse",
                          kind: .classicMac))
        return games
    }

    static func unzip(_ zip: URL, to dest: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", zip.path, dest.path]
        try? p.run()
        p.waitUntilExit()
    }

    /// The program that starts a DOS game: remembered, or the one obvious choice.
    static func executable(in folder: URL) -> [URL] {
        let remembered = folder.appendingPathComponent("minimalia-run.txt")
        if let name = try? String(contentsOf: remembered, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty, FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) {
            return [folder.appendingPathComponent(name)]
        }
        var found: [URL] = []
        if let en = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            while let u = en.nextObject() as? URL {
                if ["exe", "com", "bat"].contains(u.pathExtension.lowercased()) { found.append(u) }
            }
        }
        // Installers and setup programs are rarely what you want to play.
        let skip = ["install", "setup", "config", "setsound", "uninst", "readme", "dos4gw", "cwsdpmi"]
        let playable = found.filter { u in !skip.contains { u.lastPathComponent.lowercased().hasPrefix($0) } }
        let candidates = playable.isEmpty ? found : playable
        let name = folder.lastPathComponent.lowercased().replacingOccurrences(of: " ", with: "")
        if let match = candidates.first(where: { name.hasPrefix($0.deletingPathExtension().lastPathComponent.lowercased()) }) {
            return [match]
        }
        return candidates.sorted { $0.path.count < $1.path.count }
    }

    static func remember(_ exe: URL, in folder: URL) {
        let rel = exe.path.replacingOccurrences(of: folder.path + "/", with: "")
        try? rel.write(to: folder.appendingPathComponent("minimalia-run.txt"), atomically: true, encoding: .utf8)
    }
}

/// Minimalia Games: everything you can play, in one list.
@MainActor
final class GamesProgram: NSObject, MinimaliaProgram, NSTableViewDataSource, NSTableViewDelegate {
    let screen = NSView()
    private let topBar = MonoBar()
    private let statusBar = MonoBar(lineAtBottom: false)
    private let table = ShelfTable()
    private let scroll = NSScrollView()
    private var statusLabel: NSTextField!
    private var games: [Game] = []
    private var blocks: BlocksView?
    private var browse: BrowseProgram?
    private var running: Process?

    var onExit: (() -> Void)?
    var focusView: NSView { table }

    override init() {
        super.init()
        build()
        reload()
    }

    private func build() {
        let p = MonoPalette.current
        screen.wantsLayer = true
        screen.layer?.backgroundColor = p.desk.cgColor
        screen.appearance = p.appearance
        let title = topBar.label("Games")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        topBar.add(title)
        topBar.addSpacer()
        topBar.add(MonoButton("Add Games", symbol: "plus", help: "Copy DOS games or console game files into Minimalia") { [weak self] _ in self?.addGames() })
        topBar.add(MonoButton("", symbol: "arrow.clockwise", help: "Look again") { [weak self] _ in self?.reload() })

        table.addTableColumn(NSTableColumn(identifier: .init("game")))
        table.headerView = nil
        table.rowHeight = 54
        table.intercellSpacing = .zero
        table.backgroundColor = p.desk
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(playSelected(_:))
        table.onOpen = { [weak self] in self?.playSelected(nil) }
        table.onEscape = { [weak self] in self?.exit() }
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = true
        scroll.backgroundColor = p.desk

        statusLabel = statusBar.label()
        statusBar.add(statusLabel)
        statusBar.addSpacer()
        let hint = statusBar.label("\u{2191}\u{2193} choose   Return plays   Esc returns to the prompt")
        hint.textColor = p.dim
        statusBar.add(hint)

        for v in [topBar, scroll, statusBar] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            screen.addSubview(v)
        }
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: screen.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: screen.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: screen.trailingAnchor),
            topBar.heightAnchor.constraint(equalToConstant: 44),
            scroll.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            scroll.centerXAnchor.constraint(equalTo: screen.centerXAnchor),
            scroll.widthAnchor.constraint(equalTo: screen.widthAnchor, multiplier: 0.6),
            scroll.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            statusBar.leadingAnchor.constraint(equalTo: screen.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: screen.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: screen.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: 28),
        ])
    }

    private func reload() {
        games = GameLibrary.scan()
        table.reloadData()
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        let own = games.filter { if case .dos = $0.kind { return true }; if case .console = $0.kind { return true }; return false }.count
        statusLabel.stringValue = own == 0
            ? "Add your own DOS and console games with Add Games, or drop them in Documents/Minimalia/GAMES."
            : "\(own) of your games, plus BLOCKS and Classic Macintosh"
    }

    func numberOfRows(in tableView: NSTableView) -> Int { games.count }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { ShelfRowView() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let p = MonoPalette.current
        let cell = (tableView.makeView(withIdentifier: .init("cell"), owner: self) as? ShelfCell) ?? ShelfCell()
        cell.title.stringValue = games[row].title
        cell.title.textColor = p.ink
        cell.detail.stringValue = games[row].detail
        cell.detail.textColor = p.dim
        return cell
    }

    // MARK: Playing

    @objc private func playSelected(_ sender: Any?) {
        let r = table.selectedRow
        guard r >= 0, r < games.count else { return }
        play(games[r])
    }

    private func play(_ g: Game) {
        switch g.kind {
        case .blocks:
            let v = BlocksView(frame: screen.bounds)
            v.autoresizingMask = [.width, .height]
            v.onExit = { [weak self] in
                self?.blocks?.removeFromSuperview()
                self?.blocks = nil
                self?.screen.window?.makeFirstResponder(self?.table)
            }
            screen.addSubview(v)
            blocks = v
            screen.window?.makeFirstResponder(v)
        case .classicMac:
            let b = BrowseProgram(start: URL(string: "https://infinitemac.org"), greyscale: false)
            b.onExit = { [weak self] in
                self?.browse?.screen.removeFromSuperview()
                self?.browse = nil
                self?.screen.window?.makeFirstResponder(self?.table)
            }
            browse = b
            b.screen.frame = screen.bounds
            b.screen.autoresizingMask = [.width, .height]
            screen.addSubview(b.screen)
            screen.window?.makeFirstResponder(b.web)
        case .dos(let folder):
            guard FileManager.default.isExecutableFile(atPath: GameLibrary.dosbox.path) else {
                statusLabel.stringValue = "DOSBox Staging is not installed. Install it from dosbox-staging.github.io."
                return
            }
            let exes = GameLibrary.executable(in: folder)
            if exes.isEmpty { statusLabel.stringValue = "No program to start was found in \(folder.lastPathComponent)."; return }
            if exes.count == 1 { launchDOS(exes[0]); return }
            chooseExecutable(exes, folder: folder)
        case .console(let file, let core, let system):
            let corePath = GameLibrary.coresDir.appendingPathComponent("\(core)_libretro.dylib")
            guard FileManager.default.isExecutableFile(atPath: GameLibrary.retroarch.path),
                  FileManager.default.fileExists(atPath: corePath.path) else {
                statusLabel.stringValue = "RetroArch and its \(system) core are needed to play this."
                return
            }
            launch(GameLibrary.retroarch, ["-f", "-L", corePath.path, file.path], name: g.title)
        }
    }

    private func chooseExecutable(_ exes: [URL], folder: URL) {
        let m = NSMenu()
        m.appearance = MonoPalette.current.appearance
        let head = NSMenuItem(title: "Which program starts \(folder.lastPathComponent)?", action: nil, keyEquivalent: "")
        head.isEnabled = false
        m.addItem(head)
        for exe in exes.prefix(30) {
            m.addItem(ClosureMenuItem(title: exe.path.replacingOccurrences(of: folder.path + "/", with: "")) { [weak self] in
                GameLibrary.remember(exe, in: folder)
                self?.launchDOS(exe)
            })
        }
        let row = table.rect(ofRow: table.selectedRow)
        m.popUp(positioning: nil, at: NSPoint(x: row.minX + 24, y: row.maxY), in: table)
    }

    private func launchDOS(_ exe: URL) {
        launch(GameLibrary.dosbox, ["--set", "fullscreen=true", "--set", "output=opengl", exe.path], name: exe.deletingLastPathComponent().lastPathComponent)
    }

    /// Starts an emulator full screen, then brings Minimalia back when it closes.
    private func launch(_ app: URL, _ args: [String], name: String) {
        if FocusSession.shared.active {
            statusLabel.stringValue = "Games wait until the focus session ends at \(FocusSession.shared.endsText)."
            return
        }
        guard running == nil else { return }
        let p = Process()
        p.executableURL = app
        p.arguments = args
        p.terminationHandler = { _ in
            DispatchQueue.main.async { [weak self] in
                self?.running = nil
                self?.statusLabel.stringValue = "Welcome back."
                NSApp.activate()
                self?.screen.window?.makeKeyAndOrderFront(nil)
            }
        }
        do {
            try p.run()
            running = p
            statusLabel.stringValue = "Playing \(name). Quit the game to come back here."
        } catch {
            statusLabel.stringValue = "Could not start \(name): \(error.localizedDescription)"
        }
    }

    // MARK: Adding games

    private func addGames() {
        guard let window = screen.window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose DOS game folders or .zip files, or console game files (.md, .sfc, .nes, .gb, .gba and others)."
        panel.beginSheetModal(for: window) { [weak self] r in
            MainActor.assumeIsolated {
                guard r == .OK else { return }
                let fm = FileManager.default
                var added = 0
                for u in panel.urls {
                    let ext = u.pathExtension.lowercased()
                    let dest = GameLibrary.systems[ext] != nil ? GameLibrary.consoleFolder : GameLibrary.dosFolder
                    let target = dest.appendingPathComponent(u.lastPathComponent)
                    if fm.fileExists(atPath: target.path) { continue }
                    if (try? fm.copyItem(at: u, to: target)) != nil { added += 1 }
                }
                self?.reload()
                self?.statusLabel.stringValue = "Added \(added) \(added == 1 ? "game" : "games")."
            }
        }
    }

    private func exit() {
        let c = onExit
        onExit = nil
        c?()
    }

    @objc func closeGames(_ sender: Any?) {
        if blocks != nil { blocks?.onExit?(); return }
        if browse != nil { browse?.closeBrowser(nil); return }
        exit()
    }

    func makeMenus() -> [NSMenu] {
        let m = NSMenu(title: "Games")
        m.addItem(.mono("Close", #selector(closeGames(_:)), "w", target: self))
        m.appearance = MonoPalette.current.appearance
        return [m]
    }
}
