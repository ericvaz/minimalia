import AppKit

/// A full-screen document the app must not lose on quit.
@MainActor
protocol DocumentController: AnyObject {
    var dirty: Bool { get }
    var name: String { get }
    func writeNow() -> Bool
    func saveFromMenu()
}

@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!
    let root = NSView()
    var console: ConsoleTextView!
    var consoleScreen: ScreenView!
    var shell: Shell!
    var editor: (any DocumentController)?
    var reader: ReaderController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let fonts = Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: "Fonts") {
            CTFontManagerRegisterFontURLs(fonts as CFArray, .process, true, nil)
        }
        buildMenu()
        console = ConsoleTextView()
        consoleScreen = ScreenView(textView: console, top: false, bottom: false)

        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        window = NSWindow(contentRect: screen.insetBy(dx: screen.width * 0.1, dy: screen.height * 0.08),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "Minimalia"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.collectionBehavior = [.fullScreenPrimary]
        window.delegate = self
        window.contentView = root
        window.minSize = NSSize(width: 640, height: 400)
        root.wantsLayer = true
        applyWindowTheme()
        NotificationCenter.default.addObserver(self, selector: #selector(applyWindowTheme), name: .minimaliaAppearance, object: nil)

        show(consoleScreen, focus: console)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        if Settings.shared.fullScreen {
            DispatchQueue.main.async { self.window.toggleFullScreen(nil) }
        }

        shell = Shell(console: console, app: self)
        Task { await self.shell.start() }
        Autotype.runIfRequested(window: window)
    }

    @objc func applyWindowTheme() {
        let t = Settings.shared.theme
        window.backgroundColor = t.bg
        window.appearance = NSAppearance(named: t.isDark ? .darkAqua : .aqua)
        root.layer?.backgroundColor = t.bg.cgColor
    }

    func showProgram(_ v: NSView, focus: NSView) { show(v, focus: focus) }

    func returnToConsole() {
        show(consoleScreen, focus: console)
        console.moveToEnd()
    }

    func makeAppMenu() -> NSMenu {
        let appMenu = NSMenu()
        let about = NSMenuItem(title: "About Minimalia", action: #selector(showAbout(_:)), keyEquivalent: "")
        about.target = self
        appMenu.addItem(about)
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Hide Minimalia", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        appMenu.addItem(NSMenuItem(title: "Quit Minimalia", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        return appMenu
    }

    private func show(_ v: NSView, focus: NSView) {
        root.subviews.forEach { $0.removeFromSuperview() }
        v.frame = root.bounds
        v.autoresizingMask = [.width, .height]
        root.addSubview(v)
        window.makeFirstResponder(focus)
    }

    func openEditor(url: URL, doc: LoadedDoc, typewriter: Bool, atEnd: Bool) async {
        let ed = EditorController(url: url, doc: doc, typewriter: typewriter, atEnd: atEnd)
        editor = ed
        show(ed.screen, focus: ed.tv)
        ed.focusAtStart()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            ed.onClose = { c.resume() }
        }
        editor = nil
        show(consoleScreen, focus: console)
        console.moveToEnd()
    }

    func openWord(url: URL, content: NSAttributedString, doc: LoadedDoc, existing: Bool) async {
        let wc = WordController(url: url, content: content, doc: doc, existing: existing)
        editor = wc
        show(wc.screen, focus: wc.tv)
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            wc.onClose = { c.resume() }
        }
        editor = nil
        show(consoleScreen, focus: console)
        console.moveToEnd()
    }

    func openReader(_ page: TextPage, shell: Shell) async {
        let r = ReaderController(page: page)
        r.onPage = { [weak shell] p in shell?.lastPage = p }
        reader = r
        show(r.screen, focus: r.tv)
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            r.onClose = { c.resume() }
        }
        reader = nil
        show(consoleScreen, focus: console)
        console.moveToEnd()
    }

    // MARK: Menu actions

    @objc func saveFile(_ sender: Any?) { editor?.saveFromMenu() }
    @objc func printFile(_ sender: Any?) { (editor as? WordController)?.printDocument() }

    @objc func biggerText(_ sender: Any?) { Settings.shared.fontSize = min(48, Settings.shared.fontSize + 1) }
    @objc func smallerText(_ sender: Any?) { Settings.shared.fontSize = max(9, Settings.shared.fontSize - 1) }
    @objc func actualSizeText(_ sender: Any?) { Settings.shared.fontSize = 16 }

    @objc func showAbout(_ sender: Any?) {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Minimalia",
            .applicationVersion: "1.0",
            .version: "",
            .credits: NSAttributedString(string: "A quiet computer: files, writing, a text-only web, and an assistant that stays on this Mac."),
        ])
    }

    private func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = makeAppMenu()
        appItem.submenu = appMenu
        main.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(NSMenuItem(title: "Save", action: #selector(saveFile(_:)), keyEquivalent: "s"))
        fileMenu.addItem(NSMenuItem(title: "Print\u{2026}", action: #selector(printFile(_:)), keyEquivalent: "p"))
        fileItem.submenu = fileMenu
        main.addItem(fileItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redo)
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editMenu.addItem(.separator())
        for (title, key, tag, shift) in [("Find\u{2026}", "f", 1, false), ("Find Next", "g", 2, false), ("Find Previous", "g", 3, true)] {
            let item = NSMenuItem(title: title, action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: key)
            item.tag = tag
            if shift { item.keyEquivalentModifierMask = [.command, .shift] }
            editMenu.addItem(item)
        }
        editItem.submenu = editMenu
        main.addItem(editItem)

        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(NSMenuItem(title: "Bigger Text", action: #selector(biggerText(_:)), keyEquivalent: "="))
        viewMenu.addItem(NSMenuItem(title: "Smaller Text", action: #selector(smallerText(_:)), keyEquivalent: "-"))
        viewMenu.addItem(NSMenuItem(title: "Actual Size", action: #selector(actualSizeText(_:)), keyEquivalent: "0"))
        viewMenu.addItem(.separator())
        let fs = NSMenuItem(title: "Toggle Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fs.keyEquivalentModifierMask = [.command, .control]
        viewMenu.addItem(fs)
        viewItem.submenu = viewMenu
        main.addItem(viewItem)

        for item in [appMenu, fileMenu, viewMenu].flatMap(\.items) where item.action == #selector(saveFile(_:)) || item.action == #selector(printFile(_:))
            || item.action == #selector(biggerText(_:)) || item.action == #selector(smallerText(_:))
            || item.action == #selector(actualSizeText(_:)) || item.action == #selector(showAbout(_:)) {
            item.target = self
        }
        NSApp.mainMenu = main
    }

    // MARK: Window and app

    func window(_ window: NSWindow, willUseFullScreenPresentationOptions proposedOptions: NSApplication.PresentationOptions = []) -> NSApplication.PresentationOptions {
        [.fullScreen, .autoHideDock, .autoHideMenuBar, .autoHideToolbar]
    }

    func windowDidEnterFullScreen(_ notification: Notification) { Settings.shared.fullScreen = true }
    func windowDidExitFullScreen(_ notification: Notification) { Settings.shared.fullScreen = false }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let ed = editor, ed.dirty else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Save changes to \(ed.name)?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return ed.writeNow() ? .terminateNow : .terminateCancel
        case .alertSecondButtonReturn: return .terminateNow
        default: return .terminateCancel
        }
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let controller = AppController()
    app.delegate = controller
    app.setActivationPolicy(.regular)
    app.run()
}
