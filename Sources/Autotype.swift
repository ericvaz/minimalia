import AppKit
import WebKit

/// Test harness: set MINIMALIA_SCRIPT to a file of lines to replay as keystrokes.
/// Lines: plain text is typed and followed by Return; {WAIT n} pauses; {SNAP name} saves a PNG of the
/// window to MINIMALIA_SNAPDIR; {KEY name} presses ESC, ENTER, SPACE, BACK, LEFT, DOWN, CTRL-S or TYPE:text.
@MainActor
enum Autotype {
    static func runIfRequested(window: NSWindow) {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["MINIMALIA_SCRIPT"], let script = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        let snapDir = env["MINIMALIA_SNAPDIR"] ?? NSTemporaryDirectory()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 800_000_000)
            for raw in script.components(separatedBy: "\n") {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.isEmpty { continue }
                if line.hasPrefix("{WAIT ") {
                    let s = Double(line.dropFirst(6).dropLast()) ?? 1
                    try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000))
                } else if line.hasPrefix("{WEBSNAP ") {
                    let path = "\(snapDir)/\(line.dropFirst(9).dropLast()).png"
                    if let web = findWeb(window.contentView) {
                        web.takeSnapshot(with: nil) { image, _ in
                            if let tiff = image?.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                            }
                        }
                    }
                } else if line.hasPrefix("{SNAP ") {
                    snap(window, to: "\(snapDir)/\(line.dropFirst(6).dropLast()).png")
                } else if line.hasPrefix("{KEY ") {
                    let k = String(line.dropFirst(5).dropLast())
                    if k.hasPrefix("TYPE:") { type(String(k.dropFirst(5)), window) } else { press(k, window) }
                } else if line == "{QUIT}" {
                    NSApp.terminate(nil)
                } else {
                    type(line, window)
                    press("ENTER", window)
                }
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
        }
    }

    private static func send(_ chars: String, code: UInt16, flags: NSEvent.ModifierFlags = [], _ window: NSWindow) {
        guard let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                       windowNumber: window.windowNumber, context: nil, characters: chars,
                                       charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) else { return }
        window.firstResponder?.keyDown(with: e)
    }

    private static func type(_ s: String, _ window: NSWindow) {
        for ch in s {
            if ch == " " { send(" ", code: 49, window) } else { send(String(ch), code: 0, window) }
        }
    }

    private static func press(_ k: String, _ window: NSWindow) {
        switch k {
        case "ESC": send("\u{1b}", code: 53, window)
        case "ENTER": send("\r", code: 36, window)
        case "SPACE": send(" ", code: 49, window)
        case "BACK": send("\u{7f}", code: 51, window)
        case "LEFT": send("\u{f702}", code: 123, window)
        case "RIGHTARROW": send("\u{f703}", code: 124, window)
        case "DOWN": send("\u{f701}", code: 125, window)
        case "UP": send("\u{f700}", code: 126, window)
        case "TAB": send("\t", code: 48, window)
        case "CTRL-C": send("c", code: 8, flags: .control, window)
        default:
            if k.hasPrefix("CTRL-") { send(String(k.dropFirst(5)).lowercased(), code: 0, flags: .control, window) }
        }
    }

    private static func findWeb(_ v: NSView?) -> WKWebView? {
        guard let v else { return nil }
        if let w = v as? WKWebView { return w }
        for s in v.subviews { if let w = findWeb(s) { return w } }
        return nil
    }

    static func snap(_ window: NSWindow, to path: String) {
        guard let v = window.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
