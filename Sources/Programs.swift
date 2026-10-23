import AppKit

/// A program that runs inside Minimalia: it takes over the screen, brings its own menus,
/// and hands control back to the prompt when it exits.
@MainActor
protocol MinimaliaProgram: AnyObject {
    /// The full-screen view the program draws into.
    var screen: NSView { get }
    /// The view that should receive the keyboard when the program starts.
    var focusView: NSView { get }
    /// Menus for the menu bar, built fresh each time they are asked for.
    func makeMenus() -> [NSMenu]
    /// Called by the program when it is finished.
    var onExit: (() -> Void)? { get set }
}

/// Programs that come with Minimalia. New programs are added here and given a command in the shell.
enum ProgramRegistry {
    struct Entry {
        let command: String
        let name: String
        let summary: String
        /// How to start it: (what to type, what happens).
        let usage: [(String, String)]
        /// Keys and habits inside the program.
        let keys: [String]
    }

    static let installed: [Entry] = core + extras

    private static let core: [Entry] = [
        Entry(command: "WRITE", name: "Write", summary: "One page a day, cursor held in the middle",
              usage: [("WRITE", "Today's page, cursor held in the middle")],
              keys: ["Ctrl+S saves, Esc returns to the prompt."]),
        Entry(command: "FOLIO", name: "Minimalia Folio", summary: "Word processor for .docx, .doc, .odt, .rtf and .txt",
              usage: [("FOLIO", "Word processor, new document"),
                      ("FOLIO name", "Open or create name.docx"),
                      ("FOLIO n", "Open document n from DOCS")],
              keys: ["Menus at the top: File, Edit, Format, View. The mouse works everywhere.",
                     "\u{2318}S saves, \u{2318}P prints, \u{2318}= and \u{2318}- zoom.",
                     "\u{2318}B bold, \u{2318}I italic, \u{2318}U underline, \u{2325}\u{2318}1 to 3 headings.",
                     "Esc returns to the prompt and asks before losing changes."]),
        Entry(command: "SHELF", name: "Minimalia Shelf", summary: "Project Gutenberg's 75,000 free books, the Pali Canon and the Qur'an, read a page at a time",
              usage: [("SHELF", "Free books, read a page at a time"),
                      ("SHELF words", "Find a book by title or author")],
              keys: ["Shelves on the left, books on the right. Type to search, Return to read.",
                     "In a book: \u{2190} \u{2192} or a click turns the page; T shows the contents.",
                     "+ and - change the text size. Your place in every book is kept.",
                     "Esc goes back to the shelf, then to the prompt."]),
        Entry(command: "BROWSE", name: "Minimalia Browse", summary: "The web, calmed: greyscale, no ads or trackers, nothing plays by itself",
              usage: [("BROWSE", "The web, calmed; start page"),
                      ("BROWSE address", "Open a site, or search Google")],
              keys: ["Type words or an address in the bar at the top. \u{2318}L jumps to it.",
                     "\u{2318}[ back, \u{2318}] forward, \u{2318}R reload, \u{2318}= and \u{2318}- size.",
                     "Text, or \u{2318}T, shows the page as plain text; S saves it to the library.",
                     "Esc returns to the prompt."]),
        Entry(command: "PAD", name: "Minimalia Pad", summary: "Formatted writing in the prompt's colours, keyboard only",
              usage: [("PAD file", "Bold, italic and headings, keyboard only")],
              keys: ["Ctrl+B bold, Ctrl+I italic, Ctrl+U underline, Ctrl+1 to 3 headings, Ctrl+0 text.",
                     "Ctrl+E centre, Ctrl+8 bullets, Ctrl+P print, Ctrl+S save, Esc returns."]),
        Entry(command: "EDIT", name: "Minimalia Edit", summary: "Plain full-screen text editor",
              usage: [("EDIT file", "Plain text editor; Word files as plain text")],
              keys: ["Ctrl+S saves, \u{2318}F finds, Esc returns to the prompt."]),
        Entry(command: "VIEW", name: "Reader", summary: "Read files and web pages a screen at a time",
              usage: [("VIEW file", "Read a file one screen at a time")],
              keys: ["Space next, B back, a link number and Return follows it.",
                     "S saves to the library, R reads aloud, Esc returns."]),
        Entry(command: "AI", name: "Intelligence", summary: "On-device assistant; nothing leaves this Mac",
              usage: [("AI [question]", "Chat with the on-device assistant until EXIT")],
              keys: ["AI opens a conversation; AI followed by a question starts it with that question.",
                     "NEW starts a fresh conversation, EXIT returns to the prompt."]),
    ]

    /// Mail, films and games, left out of the release edition. ./build.sh full puts them back.
    #if MINIMALIA_EXTRAS
    private static let extras: [Entry] = [
        Entry(command: "LETTERS", name: "Minimalia Letters", summary: "Your mail, one letter at a time: Gmail and most other accounts",
              usage: [("LETTERS", "Your mail, one letter at a time")],
              keys: ["c write, r reply, a reply all, f forward, e archive, s star, j and k move.",
                     "Letters arrive as calm text; pictures and tracking images are never loaded.",
                     "\u{2318}Return sends. Esc returns to the prompt.",
                     "Gmail needs an app password: myaccount.google.com/apppasswords."]),
        Entry(command: "FILM", name: "Minimalia Film", summary: "The films on this Mac, arranged like a quiet cinema, in greyscale",
              usage: [("FILM", "Your films, played in greyscale"),
                      ("FILM folder", "Also look in a folder, such as an external drive")],
              keys: ["Arrow keys choose, Return plays. Space pauses, \u{2190} \u{2192} skip.",
                     "Films resume where you stopped. Esc goes back, then to the prompt.",
                     "Folders, at the top right, adds places to look, such as an external drive.",
                     "Plays .mp4, .m4v and .mov files longer than five minutes."]),
        Entry(command: "GAMES", name: "Minimalia Games", summary: "BLOCKS, your DOS and console games, and classic Macintosh",
              usage: [("GAMES", "BLOCKS, DOS, consoles and classic Mac"),
                      ("BLOCKS", "Falling blocks, straight away")],
              keys: ["Return plays. Add Games copies DOS folders or console game files in.",
                     "DOS games run in DOSBox Staging; Mega Drive, SNES, NES and Game Boy in RetroArch.",
                     "Quit the game to come back. Games wait until a focus session ends.",
                     "BLOCKS: \u{2190} \u{2192} move, \u{2191} turn, \u{2193} faster, Space drops, P pauses."]),
    ]
    #else
    private static let extras: [Entry] = []
    #endif
}

extension AppController {
    /// Runs a program inside the Minimalia window and returns when it exits.
    func run(_ program: MinimaliaProgram) async {
        let savedMenu = NSApp.mainMenu
        let bar = NSMenu()
        let appItem = NSMenuItem()
        appItem.submenu = makeAppMenu()
        bar.addItem(appItem)
        for m in program.makeMenus() {
            let item = NSMenuItem()
            item.submenu = m
            bar.addItem(item)
        }
        NSApp.mainMenu = bar
        if let doc = program as? DocumentController { editor = doc }
        showProgram(program.screen, focus: program.focusView)
        if let word = program as? WordProgram {
            DispatchQueue.main.async { word.applyStartZoom() }
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            program.onExit = { c.resume() }
        }
        editor = nil
        NSApp.mainMenu = savedMenu
        returnToConsole()
    }
}
