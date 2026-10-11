import AppKit
import AVFoundation
import AVKit
import CoreImage

/// A film found on this Mac.
struct Film: Hashable {
    let url: URL
    let title: String
    let series: String?
    let season: Int
    let episode: Int
    let added: Date
    let duration: Double
    let folder: String
}

/// Where each film was left off, kept between sessions.
@MainActor
enum FilmStore {
    private static let key = "filmPositions"

    static func position(_ url: URL) -> Double {
        (UserDefaults.standard.dictionary(forKey: key)?[url.path] as? Double) ?? 0
    }

    static func setPosition(_ url: URL, _ seconds: Double) {
        var d = UserDefaults.standard.dictionary(forKey: key) ?? [:]
        d[url.path] = seconds
        UserDefaults.standard.set(d, forKey: key)
    }

    /// Extra folders to look in, such as a movie folder on an external drive.
    static var folders: [URL] {
        get { (UserDefaults.standard.stringArray(forKey: "filmFolders") ?? []).map { URL(fileURLWithPath: $0) } }
        set { UserDefaults.standard.set(newValue.map(\.path), forKey: "filmFolders") }
    }

    static var searchHome: Bool {
        get { UserDefaults.standard.object(forKey: "filmSearchHome") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "filmSearchHome") }
    }

    static var thumbsDir: URL {
        let u = Gutenberg.supportDir.appendingPathComponent("FilmThumbs")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
}

enum FilmLibrary {
    static let playable: Set<String> = ["mp4", "m4v", "mov"]

    /// Every film over five minutes in your home folder, from Spotlight.
    @concurrent
    nonisolated static func scan(home: URL) async -> [Film] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        p.arguments = ["-onlyin", home.path, "kMDItemContentTypeTree == \"public.movie\" && kMDItemDurationSeconds > 300"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let paths = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
            .filter { !$0.contains("/Library/") && !$0.contains("/.") }
        var films: [Film] = []
        for path in paths {
            let url = URL(fileURLWithPath: path)
            guard playable.contains(url.pathExtension.lowercased()) else { continue }
            let item = MDItemCreate(nil, path as CFString)
            let duration = (item.flatMap { MDItemCopyAttribute($0, kMDItemDurationSeconds) as? Double }) ?? 0
            let added = (item.flatMap { MDItemCopyAttribute($0, kMDItemDateAdded) as? Date })
                ?? ((try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast)
            let (title, series, season, episode) = clean(url.deletingPathExtension().lastPathComponent)
            films.append(Film(url: url, title: title, series: series, season: season, episode: episode,
                              added: added, duration: duration, folder: url.deletingLastPathComponent().lastPathComponent))
        }
        return films
    }

    /// Every playable film in a chosen folder and below, found by walking the folder itself.
    /// External drives are often not in Spotlight's index, so this does not rely on it.
    @concurrent
    nonisolated static func scan(folder: URL) async -> [Film] {
        let keys: [URLResourceKey] = [.fileSizeKey, .addedToDirectoryDateKey, .contentModificationDateKey]
        guard let en = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys,
                                                      options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var films: [Film] = []
        while let url = en.nextObject() as? URL {
            if Task.isCancelled { break }
            guard playable.contains(url.pathExtension.lowercased()) else { continue }
            let v = try? url.resourceValues(forKeys: Set(keys))
            guard (v?.fileSize ?? 0) > 50_000_000 else { continue }
            let item = MDItemCreate(nil, url.path as CFString)
            let duration = (item.flatMap { MDItemCopyAttribute($0, kMDItemDurationSeconds) as? Double }) ?? 0
            let added = v?.addedToDirectoryDate ?? v?.contentModificationDate ?? .distantPast
            let (title, series, season, episode) = clean(url.deletingPathExtension().lastPathComponent)
            films.append(Film(url: url, title: title, series: series, season: season, episode: episode,
                              added: added, duration: duration, folder: url.deletingLastPathComponent().lastPathComponent))
        }
        return films
    }

    /// "The.Office.S02E03.720p.WEB-DL.mp4" becomes "The Office", season 2, episode 3.
    nonisolated static func clean(_ name: String) -> (String, String?, Int, Int) {
        var s = name.replacingOccurrences(of: "[._]", with: " ", options: .regularExpression)
        let junk = "(?i)\\b(1080p|720p|2160p|480p|4k|uhd|hdr|x264|x265|h264|h265|hevc|bluray|blu ray|brrip|bdrip|web dl|web-dl|webrip|web|hdrip|dvdrip|aac|ac3|dts|yify|yts|rarbg|proper|repack|extended|remastered)\\b.*$"
        s = s.replacingOccurrences(of: junk, with: "", options: .regularExpression)
        if let m = s.range(of: "(?i)\\bS(\\d{1,2})\\s?E(\\d{1,3})\\b|\\b(\\d{1,2})x(\\d{2})\\b", options: .regularExpression) {
            let tag = String(s[m])
            let nums = tag.components(separatedBy: CharacterSet.decimalDigits.inverted).compactMap(Int.init)
            let show = String(s[..<m.lowerBound]).trimmingCharacters(in: CharacterSet(charactersIn: " -"))
            var rest = String(s[m.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: " -"))
            if rest.isEmpty { rest = "Episode \(nums.count > 1 ? nums[1] : 0)" }
            if !show.isEmpty, nums.count >= 2 {
                return (rest.capitalized(with: nil), show.capitalized(with: nil), nums[0], nums[1])
            }
        }
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: CharacterSet(charactersIn: " -()[]"))
        return (s.isEmpty ? name : s, nil, 0, 0)
    }

    /// A still from a tenth of the way in, in greyscale.
    @concurrent
    nonisolated static func thumbnail(for film: Film, cache: URL) async -> NSImage? {
        let key = String(film.url.path.hashValue, radix: 16)
        let file = cache.appendingPathComponent("\(key).jpg")
        if let img = NSImage(contentsOf: file) { return img }
        let asset = AVURLAsset(url: film.url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 640, height: 360)
        let at = CMTime(seconds: max(5, film.duration * 0.1), preferredTimescale: 600)
        guard let cg = try? await gen.image(at: at).image else { return nil }
        let ci = CIImage(cgImage: cg).applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.0])
        let rep = NSBitmapImageRep(ciImage: ci)
        if let jpg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) {
            try? jpg.write(to: file)
        }
        let img = NSImage(size: rep.size)
        img.addRepresentation(rep)
        return img
    }
}

/// The opening screen while Film looks for films: the mark, a name, and a slow line.
final class FilmLoaderView: NSView {
    var progress: CGFloat = 0 { didSet { needsDisplay = true } }
    var message = "Looking for films on this Mac" { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let p = MonoPalette.current
        p.desk.setFill()
        bounds.fill()
        let w: CGFloat = 120
        let scale = w / 605
        let ox = bounds.midX - w / 2
        let oy = bounds.midY + 40
        p.ink.setFill()
        let mark = NSBezierPath()
        for (x, y, rw, rh) in LogoGlyphCell.rects {
            mark.appendRect(NSRect(x: ox + x * scale, y: oy + (468 - y - rh) * scale, width: rw * scale, height: rh * scale))
        }
        mark.fill()
        let title = NSAttributedString(string: "Film", attributes: [.font: NSFont.systemFont(ofSize: 22, weight: .medium), .foregroundColor: p.ink])
        title.draw(at: NSPoint(x: bounds.midX - title.size().width / 2, y: oy - 50))
        let msg = NSAttributedString(string: message, attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: p.dim])
        msg.draw(at: NSPoint(x: bounds.midX - msg.size().width / 2, y: oy - 82))
        let line = NSRect(x: bounds.midX - 120, y: oy - 106, width: 240, height: 2)
        p.edge.setFill()
        line.fill()
        p.ink.setFill()
        NSRect(x: line.minX, y: line.minY, width: line.width * min(1, progress), height: 2).fill()
    }
}

/// One film on the wall: a greyscale still, its title and length.
final class FilmTile: NSView {
    let film: Film
    var image: NSImage? { didSet { needsDisplay = true } }
    var isSelected = false { didSet { needsDisplay = true } }
    var onOpen: ((FilmTile) -> Void)?
    var onSelect: ((FilmTile) -> Void)?
    var subtitle = ""

    init(film: Film) {
        self.film = film
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(film.series.map { "\($0), \(film.title)" } ?? film.title)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let p = MonoPalette.current
        let pic = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.width * 9 / 16)
        let clip = NSBezierPath(roundedRect: pic, xRadius: 6, yRadius: 6)
        NSGraphicsContext.saveGraphicsState()
        clip.addClip()
        p.page.setFill()
        pic.fill()
        if let image {
            image.draw(in: pic, from: .zero, operation: .sourceOver, fraction: 0.92, respectFlipped: true, hints: nil)
        }
        let watched = FilmStore.position(film.url)
        if film.duration > 0, watched > 30 {
            p.edge.setFill()
            NSRect(x: 0, y: pic.maxY - 4, width: pic.width, height: 4).fill()
            p.ink.setFill()
            NSRect(x: 0, y: pic.maxY - 4, width: pic.width * min(1, watched / film.duration), height: 4).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        if isSelected {
            p.ink.setStroke()
            let ring = NSBezierPath(roundedRect: pic.insetBy(dx: -3, dy: -3), xRadius: 8, yRadius: 8)
            ring.lineWidth = 2
            ring.stroke()
        }
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        NSAttributedString(string: film.title, attributes: [.font: NSFont.systemFont(ofSize: 14, weight: .medium),
                                                            .foregroundColor: p.ink, .paragraphStyle: para])
            .draw(in: NSRect(x: 2, y: pic.maxY + 8, width: bounds.width - 4, height: 18))
        NSAttributedString(string: subtitle, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: p.dim, .paragraphStyle: para])
            .draw(in: NSRect(x: 2, y: pic.maxY + 27, width: bounds.width - 4, height: 16))
    }

    override func mouseDown(with event: NSEvent) {
        onSelect?(self)
        if event.clickCount >= 1 { onOpen?(self) }
    }
}

/// The wall of films, in rows. Arrow keys move, Return plays, Esc leaves.
final class FilmWallView: NSView {
    var tiles: [FilmTile] = []
    var selected = 0
    var onOpen: ((Film) -> Void)?
    var onExit: (() -> Void)?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    func select(_ i: Int) {
        guard !tiles.isEmpty else { return }
        tiles[safe: selected]?.isSelected = false
        selected = max(0, min(tiles.count - 1, i))
        let t = tiles[selected]
        t.isSelected = true
        scrollToVisible(t.frame.insetBy(dx: -20, dy: -60))
    }

    private func nearest(above: Bool) -> Int? {
        guard let cur = tiles[safe: selected] else { return nil }
        let candidates = tiles.enumerated().filter { above ? $0.element.frame.maxY < cur.frame.minY : $0.element.frame.minY > cur.frame.maxY }
        guard !candidates.isEmpty else { return nil }
        let rowY = above ? candidates.map(\.element.frame.minY).max()! : candidates.map(\.element.frame.minY).min()!
        return candidates.filter { $0.element.frame.minY == rowY }
            .min { abs($0.element.frame.midX - cur.frame.midX) < abs($1.element.frame.midX - cur.frame.midX) }?.offset
    }

    override func keyDown(with e: NSEvent) {
        NSCursor.setHiddenUntilMouseMoves(true)
        switch e.keyCode {
        case 123: select(selected - 1)
        case 124: select(selected + 1)
        case 126: if let i = nearest(above: true) { select(i) }
        case 125: if let i = nearest(above: false) { select(i) }
        case 36, 76, 49: if let t = tiles[safe: selected] { onOpen?(t.film) }
        case 53: onExit?()
        default: super.keyDown(with: e)
        }
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

/// The player: full screen, greyscale, Esc returns to the wall.
final class FilmPlayerView: AVPlayerView {
    var onExit: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onExit?(); return }
        super.keyDown(with: event)
    }
}

/// Minimalia Film: the films on this Mac, arranged like a quiet cinema, played in greyscale.
@MainActor
final class FilmProgram: NSObject, MinimaliaProgram {
    let screen = NSView()
    private let loader = FilmLoaderView()
    private let topBar = MonoBar()
    private let scroll = NSScrollView()
    private var countLabel: NSTextField!
    private let wall = FilmWallView()
    private var player: FilmPlayerView?
    private var timeObserver: Any?
    private var playing: Film?
    private var films: [Film] = []
    private let home: URL

    var onExit: (() -> Void)?
    var focusView: NSView { wall }

    init(home: URL) {
        self.home = home
        super.init()
        screen.wantsLayer = true
        screen.layer?.backgroundColor = MonoPalette.current.desk.cgColor
        screen.appearance = MonoPalette.current.appearance
        scroll.documentView = wall
        scroll.drawsBackground = true
        scroll.backgroundColor = MonoPalette.current.desk
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.isHidden = true
        wall.onOpen = { [weak self] f in self?.play(f) }
        wall.onExit = { [weak self] in self?.exit() }

        let title = topBar.label("Film")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        topBar.add(title)
        topBar.addSpacer()
        countLabel = topBar.label("")
        countLabel.textColor = MonoPalette.current.dim
        topBar.add(countLabel)
        topBar.add(MonoButton("Folders", symbol: "folder", dropdown: true, help: "Where Film looks for films") { [weak self] b in
            self?.popFolders(b)
        })
        topBar.isHidden = true

        for v in [topBar, scroll, loader] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            screen.addSubview(v)
        }
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: screen.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: screen.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: screen.trailingAnchor),
            topBar.heightAnchor.constraint(equalToConstant: 42),
            scroll.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            scroll.bottomAnchor.constraint(equalTo: screen.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: screen.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: screen.trailingAnchor),
            loader.topAnchor.constraint(equalTo: screen.topAnchor),
            loader.bottomAnchor.constraint(equalTo: screen.bottomAnchor),
            loader.leadingAnchor.constraint(equalTo: screen.leadingAnchor),
            loader.trailingAnchor.constraint(equalTo: screen.trailingAnchor),
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(relayout), name: NSView.frameDidChangeNotification, object: scroll)
        scroll.postsFrameChangedNotifications = true
        Task { @MainActor in await self.load() }
    }

    private func load() async {
        let started = Date()
        loader.progress = 0.15
        let ticker = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 120_000_000)
                self.loader.progress = min(0.85, self.loader.progress + 0.03)
            }
        }
        var found: [Film] = FilmStore.searchHome ? await FilmLibrary.scan(home: home) : []
        for folder in FilmStore.folders where FileManager.default.fileExists(atPath: folder.path) {
            loader.message = "Looking in \(folder.lastPathComponent)"
            found += await FilmLibrary.scan(folder: folder)
        }
        var seen = Set<String>()
        films = found.filter { seen.insert($0.url.path).inserted }
        ticker.cancel()
        loader.progress = 1
        loader.message = films.isEmpty ? "No films found" : "\(films.count) \(films.count == 1 ? "film" : "films")"
        // Let the opening breathe for a moment, as a cinema does.
        let wait = max(0, 1.6 - Date().timeIntervalSince(started))
        try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
        loader.progress = 1
        loader.isHidden = true
        scroll.isHidden = false
        topBar.isHidden = false
        countLabel.stringValue = films.isEmpty ? "No films found yet. Add the folder where you keep them." : "\(films.count) \(films.count == 1 ? "film" : "films")"
        if films.isEmpty {
            wall.subviews.forEach { $0.removeFromSuperview() }
            wall.tiles = []
            screen.window?.makeFirstResponder(wall)
            return
        }
        buildWall()
        screen.window?.makeFirstResponder(wall)
    }

    // MARK: The wall

    private var sections: [(String, [Film])] {
        var out: [(String, [Film])] = []
        let started = films.filter { f in
            let p = FilmStore.position(f.url)
            return p > 30 && (f.duration == 0 || p < f.duration * 0.95)
        }
        if !started.isEmpty { out.append(("Continue watching", started)) }
        out.append(("Recently added", Array(films.sorted { $0.added > $1.added }.prefix(12))))
        let series = Dictionary(grouping: films.filter { $0.series != nil }, by: { $0.series! })
        for name in series.keys.sorted() {
            out.append((name, series[name]!.sorted { ($0.season, $0.episode) < ($1.season, $1.episode) }))
        }
        let byFolder = Dictionary(grouping: films.filter { $0.series == nil }, by: \.folder)
        for name in byFolder.keys.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
            out.append((name, byFolder[name]!.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }))
        }
        return out
    }

    private var headings: [NSTextField] = []

    private func buildWall() {
        wall.subviews.forEach { $0.removeFromSuperview() }
        wall.tiles = []
        headings = []
        let p = MonoPalette.current
        for (name, list) in sections {
            let h = NSTextField(labelWithString: name)
            h.font = .systemFont(ofSize: 18, weight: .semibold)
            h.textColor = p.ink
            wall.addSubview(h)
            headings.append(h)
            for f in list {
                let t = FilmTile(film: f)
                t.subtitle = subtitle(for: f)
                t.onOpen = { [weak self] tile in self?.play(tile.film) }
                t.onSelect = { [weak self] tile in
                    guard let self, let i = self.wall.tiles.firstIndex(where: { $0 === tile }) else { return }
                    self.wall.select(i)
                }
                h.tag = h.tag + 1
                wall.addSubview(t)
                wall.tiles.append(t)
                let cache = FilmStore.thumbsDir
                Task { @MainActor in t.image = await FilmLibrary.thumbnail(for: f, cache: cache) }
            }
        }
        relayout()
        wall.select(0)
    }

    private func subtitle(for f: Film) -> String {
        var parts: [String] = []
        if f.series != nil { parts.append("S\(f.season) E\(f.episode)") }
        if f.duration > 0 {
            let m = Int(f.duration / 60)
            parts.append(m >= 60 ? "\(m / 60) h \(m % 60) min" : "\(m) min")
        }
        let watched = FilmStore.position(f.url)
        if watched > 30, f.duration > 0 { parts.append("\(Int(watched / f.duration * 100))% watched") }
        return parts.joined(separator: "   \u{00B7}   ")
    }

    @objc private func relayout() {
        guard !wall.tiles.isEmpty else { return }
        let width = scroll.contentSize.width
        let margin: CGFloat = max(40, width * 0.05)
        let tileW: CGFloat = min(300, max(220, (width - margin * 2) / 5 - 24))
        let tileH = tileW * 9 / 16 + 52
        let perRow = max(1, Int((width - margin * 2 + 24) / (tileW + 24)))
        var y: CGFloat = 48
        var tileIndex = 0
        for (s, (_, list)) in sections.enumerated() {
            guard s < headings.count else { break }
            headings[s].frame = NSRect(x: margin, y: y, width: width - margin * 2, height: 26)
            y += 40
            for (i, _) in list.enumerated() {
                let col = i % perRow
                if col == 0 && i > 0 { y += tileH + 24 }
                guard tileIndex < wall.tiles.count else { break }
                wall.tiles[tileIndex].frame = NSRect(x: margin + CGFloat(col) * (tileW + 24), y: y, width: tileW, height: tileH)
                tileIndex += 1
            }
            y += tileH + 44
        }
        wall.frame = NSRect(x: 0, y: 0, width: width, height: max(y, scroll.contentSize.height))
    }

    // MARK: Playing

    private func play(_ film: Film) {
        let asset = AVURLAsset(url: film.url)
        Task { @MainActor in
            let item = AVPlayerItem(asset: asset)
            if let comp = try? await AVVideoComposition.videoComposition(with: asset, applyingCIFiltersWithHandler: { request in
                let grey = request.sourceImage.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.0])
                request.finish(with: grey, context: nil)
            }) {
                item.videoComposition = comp
            }
            let player = AVPlayer(playerItem: item)
            let view = FilmPlayerView()
            view.player = player
            view.controlsStyle = .floating
            view.showsFullScreenToggleButton = false
            view.onExit = { [weak self] in self?.stop() }
            view.translatesAutoresizingMaskIntoConstraints = false
            self.screen.addSubview(view)
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: self.screen.topAnchor),
                view.bottomAnchor.constraint(equalTo: self.screen.bottomAnchor),
                view.leadingAnchor.constraint(equalTo: self.screen.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: self.screen.trailingAnchor),
            ])
            self.player = view
            self.playing = film
            let resume = FilmStore.position(film.url)
            if resume > 30, film.duration == 0 || resume < film.duration * 0.95 {
                await player.seek(to: CMTime(seconds: resume, preferredTimescale: 600))
            }
            self.timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 5, preferredTimescale: 1), queue: .main) { t in
                MainActor.assumeIsolated { FilmStore.setPosition(film.url, t.seconds) }
            }
            player.play()
            self.screen.window?.makeFirstResponder(view)
        }
    }

    private func stop() {
        guard let view = player, let p = view.player else { return }
        p.pause()
        if let f = playing { FilmStore.setPosition(f.url, p.currentTime().seconds) }
        if let o = timeObserver { p.removeTimeObserver(o) }
        timeObserver = nil
        view.removeFromSuperview()
        player = nil
        playing = nil
        let keep = wall.selected
        buildWall()
        wall.select(keep)
        screen.window?.makeFirstResponder(wall)
    }

    // MARK: Folders

    private func popFolders(_ b: MonoButton) {
        let m = NSMenu()
        for f in FilmStore.folders {
            let online = FileManager.default.fileExists(atPath: f.path)
            let sub = NSMenu()
            sub.addItem(ClosureMenuItem(title: "Stop looking here") { [weak self] in
                FilmStore.folders.removeAll { $0 == f }
                self?.rescan()
            })
            let item = NSMenuItem(title: f.path + (online ? "" : "  (not connected)"), action: nil, keyEquivalent: "")
            item.submenu = sub
            m.addItem(item)
        }
        if !FilmStore.folders.isEmpty { m.addItem(.separator()) }
        m.addItem(ClosureMenuItem(title: "Add a Folder\u{2026}") { [weak self] in self?.addFolder() })
        let home = ClosureMenuItem(title: "Also Look in My Home Folder") { [weak self] in
            FilmStore.searchHome.toggle()
            self?.rescan()
        }
        home.state = FilmStore.searchHome ? .on : .off
        m.addItem(home)
        b.popUp(m)
    }

    private func addFolder() {
        guard let window = screen.window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Look Here"
        panel.message = "Choose the folders where you keep films, such as one on an external drive."
        panel.directoryURL = URL(fileURLWithPath: "/Volumes")
        panel.beginSheetModal(for: window) { [weak self] r in
            MainActor.assumeIsolated {
                guard r == .OK else { return }
                FilmStore.folders = Array(Set(FilmStore.folders + panel.urls)).sorted { $0.path < $1.path }
                self?.rescan()
            }
        }
    }

    private func rescan() {
        scroll.isHidden = true
        topBar.isHidden = true
        loader.isHidden = false
        loader.progress = 0
        loader.message = "Looking for films"
        Task { @MainActor in await self.load() }
    }

    private func exit() {
        let c = onExit
        onExit = nil
        c?()
    }

    @objc func closeFilm(_ sender: Any?) { if player != nil { stop() } else { exit() } }

    func makeMenus() -> [NSMenu] {
        let m = NSMenu(title: "Film")
        m.addItem(.mono("Close", #selector(closeFilm(_:)), "w", target: self))
        m.appearance = MonoPalette.current.appearance
        return [m]
    }
}
