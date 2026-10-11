import AppKit

final class WordAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = WordMenu.build()
        runTestHooks()
    }

    /// Test harness: MINIMALIA_OPEN opens a file, MINIMALIA_SNAP saves a picture of the window and quits.
    private func runTestHooks() {
        let env = ProcessInfo.processInfo.environment
        if let path = env["MINIMALIA_OPEN"] {
            NSDocumentController.shared.openDocument(withContentsOf: URL(fileURLWithPath: path), display: true) { _, _, _ in }
        }
        guard let snap = env["MINIMALIA_SNAP"] else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            if let w = NSApp.orderedWindows.first, let v = w.contentView?.superview,
               let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                v.cacheDisplay(in: v.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: snap))
            }
            NSApp.terminate(nil)
        }
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { true }
}

enum WordMenu {
    private static func item(_ title: String, _ action: Selector?, _ key: String = "",
                             _ mods: NSEvent.ModifierFlags = [.command], tag: Int = 0, target: AnyObject? = nil) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.keyEquivalentModifierMask = mods
        i.tag = tag
        i.target = target
        return i
    }

    private static func menu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let top = NSMenuItem()
        let m = NSMenu(title: title)
        items.forEach(m.addItem)
        top.submenu = m
        return top
    }

    private static func sub(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let m = NSMenu(title: title)
        items.forEach(m.addItem)
        i.submenu = m
        return i
    }

    static func build() -> NSMenu {
        let fm = NSFontManager.shared
        let main = NSMenu()

        main.addItem(menu("Minimalia Folio", [
            item("About Minimalia Folio", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            item("Hide Minimalia Folio", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            .separator(),
            item("Quit Minimalia Folio", #selector(NSApplication.terminate(_:)), "q"),
        ]))

        main.addItem(menu("File", [
            item("New", #selector(NSDocumentController.newDocument(_:)), "n"),
            item("Open\u{2026}", #selector(NSDocumentController.openDocument(_:)), "o"),
            sub("Open Recent", [item("Clear Menu", #selector(NSDocumentController.clearRecentDocuments(_:)), "", [])]),
            .separator(),
            item("Close", #selector(NSWindow.performClose(_:)), "w"),
            item("Save", #selector(NSDocument.save(_:)), "s"),
            item("Save As\u{2026}", #selector(NSDocument.saveAs(_:)), "s", [.command, .shift]),
            item("Revert to Saved", #selector(NSDocument.revertToSaved(_:))),
            .separator(),
            item("Export as PDF\u{2026}", #selector(WordDocument.exportPDF(_:)), "e", [.command, .shift]),
            item("Page Setup\u{2026}", #selector(NSDocument.runPageLayout(_:)), "p", [.command, .shift]),
            item("Print\u{2026}", #selector(NSDocument.printDocument(_:)), "p"),
        ]))

        main.addItem(menu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Paste and Match Style", #selector(NSTextView.pasteAsPlainText(_:)), "v", [.command, .option, .shift]),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
            .separator(),
            sub("Find", [
                item("Find\u{2026}", #selector(NSTextView.performFindPanelAction(_:)), "f", tag: 1),
                item("Find and Replace\u{2026}", #selector(NSTextView.performFindPanelAction(_:)), "f", [.command, .option], tag: 12),
                item("Find Next", #selector(NSTextView.performFindPanelAction(_:)), "g", tag: 2),
                item("Find Previous", #selector(NSTextView.performFindPanelAction(_:)), "g", [.command, .shift], tag: 3),
                item("Use Selection for Find", #selector(NSTextView.performFindPanelAction(_:)), "e", tag: 7),
            ]),
            sub("Spelling and Grammar", [
                item("Show Spelling and Grammar", #selector(NSText.showGuessPanel(_:)), ":"),
                item("Check Document Now", #selector(NSText.checkSpelling(_:)), ";"),
                .separator(),
                item("Check Spelling While Typing", #selector(NSTextView.toggleContinuousSpellChecking(_:))),
                item("Check Grammar With Spelling", #selector(NSTextView.toggleGrammarChecking(_:))),
                item("Correct Spelling Automatically", #selector(NSTextView.toggleAutomaticSpellingCorrection(_:))),
            ]),
            sub("Substitutions", [
                item("Smart Quotes", #selector(NSTextView.toggleAutomaticQuoteSubstitution(_:))),
                item("Smart Dashes", #selector(NSTextView.toggleAutomaticDashSubstitution(_:))),
                item("Text Replacement", #selector(NSTextView.toggleAutomaticTextReplacement(_:))),
            ]),
        ]))

        main.addItem(menu("Format", [
            sub("Font", [
                item("Show Fonts", #selector(NSFontManager.orderFrontFontPanel(_:)), "t", target: fm),
                item("Bold", #selector(WordWindowController.toggleBold(_:)), "b"),
                item("Italic", #selector(WordWindowController.toggleItalic(_:)), "i"),
                item("Underline", #selector(NSText.underline(_:)), "u"),
                .separator(),
                item("Bigger", #selector(NSFontManager.modifyFont(_:)), "+", tag: 3, target: fm),
                item("Smaller", #selector(NSFontManager.modifyFont(_:)), "-", [.command, .shift], tag: 4, target: fm),
                .separator(),
                item("Show Colours", #selector(NSApplication.orderFrontColorPanel(_:)), "c", [.command, .shift]),
            ]),
            sub("Style", WordStyles.Kind.allCases.enumerated().map { i, k in
                item(k.rawValue, #selector(WordWindowController.applyStyle(_:)), "\(i)", [.command, .option])
            }),
            sub("Text", [
                item("Align Left", #selector(NSText.alignLeft(_:)), "{"),
                item("Centre", #selector(NSText.alignCenter(_:)), "|"),
                item("Justify", #selector(NSTextView.alignJustified(_:))),
                item("Align Right", #selector(NSText.alignRight(_:)), "}"),
                .separator(),
                item("Show Ruler", #selector(NSText.toggleRuler(_:)), "r"),
            ]),
            item("Lists\u{2026}", #selector(NSTextView.orderFrontListPanel(_:))),
            item("Table\u{2026}", #selector(NSTextView.orderFrontTablePanel(_:))),
        ]))

        main.addItem(menu("View", [
            item("Actual Size", #selector(WordWindowController.actualSize(_:)), "0"),
            item("Zoom In", #selector(WordWindowController.zoomIn(_:)), "="),
            item("Zoom Out", #selector(WordWindowController.zoomOut(_:)), "-"),
            .separator(),
            item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ]))

        let window = menu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:))),
            .separator(),
            item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))),
        ])
        main.addItem(window)
        NSApp.windowsMenu = window.submenu
        return main
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = WordAppDelegate()
    app.delegate = delegate
    _ = NSDocumentController.shared
    app.setActivationPolicy(.regular)
    app.run()
}
