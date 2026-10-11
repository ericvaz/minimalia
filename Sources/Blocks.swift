import AppKit

/// BLOCKS: falling blocks, drawn in Minimalia's greys. Written for Minimalia; not affiliated with any trademark.
final class BlocksView: NSView {
    private static let cols = 10
    private static let rows = 20

    // Each shape as rotation states of four (x, y) cells.
    private static let shapes: [[[(Int, Int)]]] = {
        let base: [[(Int, Int)]] = [
            [(0, 1), (1, 1), (2, 1), (3, 1)],   // I
            [(1, 0), (2, 0), (1, 1), (2, 1)],   // O
            [(1, 0), (0, 1), (1, 1), (2, 1)],   // T
            [(1, 0), (2, 0), (0, 1), (1, 1)],   // S
            [(0, 0), (1, 0), (1, 1), (2, 1)],   // Z
            [(0, 0), (0, 1), (1, 1), (2, 1)],   // J
            [(2, 0), (0, 1), (1, 1), (2, 1)],   // L
        ]
        return base.enumerated().map { i, cells in
            let size = i == 0 ? 4 : (i == 1 ? 2 : 3)
            var states = [cells]
            if i == 1 { return [cells, cells, cells, cells] }
            for _ in 1..<4 {
                states.append(states.last!.map { (x, y) in (size - 1 - y, x) })
            }
            return states
        }
    }()

    private var board = [[Int]](repeating: [Int](repeating: 0, count: cols), count: rows)
    private var piece = 0
    private var rotation = 0
    private var px = 3
    private var py = 0
    private var next = 0
    private var bag: [Int] = []
    private var score = 0
    private var lines = 0
    private var level = 1
    private var over = false
    private var paused = false
    private var timer: Timer?

    var onExit: (() -> Void)?

    private var best: Int {
        get { UserDefaults.standard.integer(forKey: "blocksBest") }
        set { UserDefaults.standard.set(newValue, forKey: "blocksBest") }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        restart()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    // MARK: Rules

    private func draw() -> Int {
        if bag.isEmpty { bag = Array(0..<7).shuffled() }
        return bag.removeLast()
    }

    private func restart() {
        board = [[Int]](repeating: [Int](repeating: 0, count: Self.cols), count: Self.rows)
        score = 0; lines = 0; level = 1; over = false; paused = false
        bag = []
        next = draw()
        spawn()
        schedule()
        needsDisplay = true
    }

    private func spawn() {
        piece = next
        next = draw()
        rotation = 0
        px = piece == 1 ? 4 : 3
        py = 0
        if !fits(px, py, rotation) {
            over = true
            timer?.invalidate()
            if score > best { best = score }
        }
    }

    private func cells(_ x: Int, _ y: Int, _ r: Int) -> [(Int, Int)] {
        Self.shapes[piece][r].map { (x + $0.0, y + $0.1) }
    }

    private func fits(_ x: Int, _ y: Int, _ r: Int) -> Bool {
        cells(x, y, r).allSatisfy { cx, cy in
            cx >= 0 && cx < Self.cols && cy < Self.rows && (cy < 0 || board[cy][cx] == 0)
        }
    }

    private func schedule() {
        timer?.invalidate()
        let interval = max(0.07, 0.8 - Double(level - 1) * 0.07)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        guard !over, !paused else { return }
        if fits(px, py + 1, rotation) { py += 1 } else { lock() }
        needsDisplay = true
    }

    private func lock() {
        for (x, y) in cells(px, py, rotation) where y >= 0 { board[y][x] = piece + 1 }
        let full = board.indices.filter { board[$0].allSatisfy { $0 != 0 } }
        if !full.isEmpty {
            board.removeAll { $0.allSatisfy { $0 != 0 } }
            board.insert(contentsOf: [[Int]](repeating: [Int](repeating: 0, count: Self.cols), count: full.count), at: 0)
            score += [0, 40, 100, 300, 1200][full.count] * level
            lines += full.count
            let newLevel = lines / 10 + 1
            if newLevel != level { level = newLevel; schedule() }
        }
        spawn()
    }

    private func move(_ dx: Int) {
        if fits(px + dx, py, rotation) { px += dx }
    }

    private func rotate(_ d: Int) {
        let r = (rotation + d + 4) % 4
        for kick in [0, -1, 1, -2, 2] where fits(px + kick, py, r) {
            px += kick
            rotation = r
            return
        }
    }

    private func drop() {
        var d = 0
        while fits(px, py + 1, rotation) { py += 1; d += 1 }
        score += d * 2
        lock()
    }

    private var ghostY: Int {
        var y = py
        while fits(px, y + 1, rotation) { y += 1 }
        return y
    }

    // MARK: Input

    override func keyDown(with e: NSEvent) {
        NSCursor.setHiddenUntilMouseMoves(true)
        if e.keyCode == 53 { timer?.invalidate(); onExit?(); return }
        let key = e.charactersIgnoringModifiers?.lowercased() ?? ""
        if over {
            if key == "r" || e.keyCode == 36 || e.keyCode == 49 { restart() }
            return
        }
        if key == "p" { paused.toggle(); needsDisplay = true; return }
        guard !paused else { return }
        switch e.keyCode {
        case 123: move(-1)
        case 124: move(1)
        case 125: if fits(px, py + 1, rotation) { py += 1; score += 1 } else { lock() }
        case 126: rotate(1)
        case 49: drop()
        default:
            if key == "x" { rotate(1) } else if key == "z" { rotate(-1) }
        }
        needsDisplay = true
    }

    // MARK: Drawing

    /// A distinct grey for each shape, between the page ink and the desk.
    private func shade(_ kind: Int) -> NSColor {
        let p = MonoPalette.current
        let t = CGFloat([0, 0.0, 0.18, 0.32, 0.45, 0.58, 0.7, 0.82][kind])
        return p.ink.blended(withFraction: t * 0.75, of: p.desk) ?? p.ink
    }

    private func cell(_ r: NSRect, _ kind: Int, ghost: Bool = false) {
        let path = NSBezierPath(roundedRect: r.insetBy(dx: 1.5, dy: 1.5), xRadius: 3, yRadius: 3)
        if ghost {
            MonoPalette.current.edge.setStroke()
            path.lineWidth = 1.5
            path.stroke()
        } else {
            shade(kind).setFill()
            path.fill()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let p = MonoPalette.current
        p.desk.setFill()
        bounds.fill()
        let size = floor(min((bounds.height - 120) / CGFloat(Self.rows), (bounds.width - 420) / CGFloat(Self.cols)))
        let w = size * CGFloat(Self.cols)
        let h = size * CGFloat(Self.rows)
        let ox = floor((bounds.width - w) / 2)
        let oy = floor((bounds.height - h) / 2)
        let well = NSRect(x: ox, y: oy, width: w, height: h)
        p.page.setFill()
        well.fill()
        p.edge.setStroke()
        NSBezierPath(rect: well.insetBy(dx: -1, dy: -1)).stroke()

        func rect(_ x: Int, _ y: Int) -> NSRect { NSRect(x: ox + CGFloat(x) * size, y: oy + CGFloat(y) * size, width: size, height: size) }
        for y in 0..<Self.rows { for x in 0..<Self.cols where board[y][x] != 0 { cell(rect(x, y), board[y][x]) } }
        if !over {
            for (x, y) in cells(px, ghostY, rotation) where y >= 0 { cell(rect(x, y), 0, ghost: true) }
            for (x, y) in cells(px, py, rotation) where y >= 0 { cell(rect(x, y), piece + 1) }
        }

        // Next piece and the numbers, to the right of the well.
        let side = ox + w + 48
        func text(_ s: String, _ y: CGFloat, size fs: CGFloat = 15, dim: Bool = false) {
            NSAttributedString(string: s, attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: fs, weight: dim ? .regular : .medium),
                                                      .foregroundColor: dim ? p.dim : p.ink]).draw(at: NSPoint(x: side, y: y))
        }
        text("NEXT", oy, size: 12, dim: true)
        for (x, y) in Self.shapes[next][0] {
            cell(NSRect(x: side + CGFloat(x) * size * 0.8, y: oy + 28 + CGFloat(y) * size * 0.8, width: size * 0.8, height: size * 0.8), next + 1)
        }
        text("SCORE", oy + 150, size: 12, dim: true); text("\(score)", oy + 168, size: 24)
        text("LINES", oy + 220, size: 12, dim: true); text("\(lines)", oy + 238, size: 20)
        text("LEVEL", oy + 284, size: 12, dim: true); text("\(level)", oy + 302, size: 20)
        text("BEST", oy + 348, size: 12, dim: true); text("\(max(best, score))", oy + 366, size: 20)
        text("\u{2190} \u{2192} move   \u{2191} turn   \u{2193} faster", oy + h - 60, size: 12, dim: true)
        text("Space drop   P pause   Esc leave", oy + h - 40, size: 12, dim: true)

        let title = NSAttributedString(string: "BLOCKS", attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: p.dim])
        title.draw(at: NSPoint(x: ox, y: oy - 28))

        if over || paused {
            p.desk.withAlphaComponent(0.82).setFill()
            well.fill()
            let msg = over ? "Game over\n\nScore \(score)\n\nReturn plays again" : "Paused\n\nP carries on"
            let para = NSMutableParagraphStyle()
            para.alignment = .center
            let s = NSAttributedString(string: msg, attributes: [.font: NSFont.systemFont(ofSize: 18, weight: .medium),
                                                                .foregroundColor: p.ink, .paragraphStyle: para])
            let sz = s.boundingRect(with: NSSize(width: w, height: h), options: [.usesLineFragmentOrigin])
            s.draw(in: NSRect(x: ox, y: oy + (h - sz.height) / 2, width: w, height: sz.height))
        }
    }
}

/// BLOCKS on its own, straight from the prompt.
@MainActor
final class BlocksProgram: NSObject, MinimaliaProgram {
    let screen: NSView
    private let game: BlocksView
    var onExit: (() -> Void)?
    var focusView: NSView { game }

    override init() {
        game = BlocksView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
        game.autoresizingMask = [.width, .height]
        screen = game
        super.init()
        game.onExit = { [weak self] in
            let c = self?.onExit
            self?.onExit = nil
            c?()
        }
    }

    func makeMenus() -> [NSMenu] { [] }
}
