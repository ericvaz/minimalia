import AppKit

/// The window refuses to leave full screen while a focus session runs.
final class MinimaliaWindow: NSWindow {
    override func toggleFullScreen(_ sender: Any?) {
        if FocusSession.shared.active && styleMask.contains(.fullScreen) {
            FocusSession.shared.remind()
            return
        }
        super.toggleFullScreen(sender)
    }
}

/// A focus session: for a set time, Minimalia stays in front. Switching apps with Command-Tab,
/// hiding, leaving full screen and quitting are held back. Force Quit still works for emergencies.
@MainActor
final class FocusSession {
    static let shared = FocusSession()
    weak var window: NSWindow?
    private var timer: Timer?

    static let onShortcut = "Minimalia Focus On"
    static let offShortcut = "Minimalia Focus Off"

    private(set) var ends: Date? {
        get {
            let t = UserDefaults.standard.double(forKey: "focusEnds")
            return t > 0 ? Date(timeIntervalSince1970: t) : nil
        }
        set { UserDefaults.standard.set(newValue?.timeIntervalSince1970 ?? 0, forKey: "focusEnds") }
    }

    var active: Bool { (ends ?? .distantPast) > Date() }

    var minutesLeft: Int { max(1, Int(ceil((ends ?? Date()).timeIntervalSinceNow / 60))) }

    var endsText: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: ends ?? Date())
    }

    func start(minutes: Int) {
        ends = Date().addingTimeInterval(TimeInterval(minutes * 60))
        engage()
        runShortcut(Self.onShortcut)
    }

    /// Picks up a session that was running when Minimalia last closed.
    func resumeIfNeeded() {
        if active { engage() } else { ends = nil }
    }

    func end() {
        timer?.invalidate()
        timer = nil
        ends = nil
        applyOptions()
        runShortcut(Self.offShortcut)
    }

    private func engage() {
        if let w = window, !w.styleMask.contains(.fullScreen) { w.toggleFullScreen(nil) }
        applyOptions()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: max(1, (ends ?? Date()).timeIntervalSinceNow), repeats: false) { _ in
            MainActor.assumeIsolated { FocusSession.shared.finish() }
        }
    }

    /// Adds or removes the restrictions on the running presentation.
    func applyOptions() {
        var o = NSApp.presentationOptions
        if active {
            if !o.contains(.hideDock) && !o.contains(.autoHideDock) { o.insert(.autoHideDock) }
            o.insert(.disableProcessSwitching)
            o.insert(.disableHideApplication)
        } else {
            o.remove(.disableProcessSwitching)
            o.remove(.disableHideApplication)
        }
        NSApp.presentationOptions = o
    }

    /// The options to use when Minimalia enters full screen.
    func fullScreenOptions() -> NSApplication.PresentationOptions {
        var o: NSApplication.PresentationOptions = [.fullScreen, .autoHideDock, .autoHideMenuBar, .autoHideToolbar]
        if active { o.formUnion([.disableProcessSwitching, .disableHideApplication]) }
        return o
    }

    private func finish() {
        end()
        Sound.chime()
        guard let w = window else { return }
        let a = NSAlert()
        a.messageText = "Focus session complete"
        a.informativeText = "Well done. Minimalia is back to normal; you can switch apps again."
        a.addButton(withTitle: "OK")
        a.beginSheetModal(for: w)
    }

    /// A gentle note when something tries to leave during a session.
    func remind() {
        guard let w = window, w.attachedSheet == nil else { return }
        let a = NSAlert()
        a.messageText = "Focus session: \(minutesLeft) \(minutesLeft == 1 ? "minute" : "minutes") left"
        a.informativeText = "It ends at \(endsText). To finish early, type FOCUS END at the prompt."
        a.addButton(withTitle: "Keep Focusing")
        a.beginSheetModal(for: w)
    }

    // MARK: Notifications

    /// macOS does not let apps switch Focus on, but a Shortcut can. Runs it if the person made one.
    private func runShortcut(_ name: String) {
        Task.detached {
            guard FocusSession.shortcutExists(name) else { return }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
            p.arguments = ["run", name]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
        }
    }

    nonisolated static func shortcutExists(_ name: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        p.arguments = ["list"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        return out.split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces) == name }
    }
}
