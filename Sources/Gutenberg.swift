import AppKit

/// A book in Project Gutenberg's catalogue.
struct Book: Codable, Hashable {
    let id: Int
    let title: String
    let author: String
    let language: String
    let shelves: [String]
    var subjects: String? = nil
}

/// One book kept on this Mac, with the reader's place in it.
struct ShelfEntry: Codable {
    var book: Book
    var position: Int
    var length: Int
    var lastRead: Date?
}

/// Project Gutenberg: the official catalogue, the most-read list, and book texts.
@MainActor
enum Gutenberg {
    static let catalogURL = URL(string: "https://www.gutenberg.org/cache/epub/feeds/pg_catalog.csv.gz")!
    static let topURL = URL(string: "https://www.gutenberg.org/browse/scores/top")!

    static var supportDir: URL {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Minimalia")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    static var catalogFile: URL { supportDir.appendingPathComponent("pg_catalog.csv") }
    static var hasCatalog: Bool { FileManager.default.fileExists(atPath: catalogFile.path) }

    static var booksDir: URL {
        let u = Paths.data.appendingPathComponent("BOOKS")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    static func textFile(_ id: Int) -> URL { booksDir.appendingPathComponent("\(id).txt") }

    // MARK: Catalogue

    static func downloadCatalog() async throws {
        let (data, resp) = try await Web.session.data(from: catalogURL)
        if let h = resp as? HTTPURLResponse, h.statusCode >= 400 { throw WebError.http(h.statusCode) }
        let gz = supportDir.appendingPathComponent("pg_catalog.csv.gz")
        try data.write(to: gz, options: .atomic)
        try await gunzip(gz, to: catalogFile)
        try? FileManager.default.removeItem(at: gz)
    }

    @concurrent
    nonisolated private static func gunzip(_ src: URL, to dst: URL) async throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        p.arguments = ["-dc", src.path]
        FileManager.default.createFile(atPath: dst.path, contents: nil)
        let out = try FileHandle(forWritingTo: dst)
        p.standardOutput = out
        try p.run()
        p.waitUntilExit()
        try out.close()
        if p.terminationStatus != 0 { throw DocError.unreadable }
    }

    private static var cached: [Book]?

    static func catalog() async -> [Book] {
        if let c = cached { return c }
        let books = await parse(catalogFile)
        cached = books
        return books
    }

    /// Reads the catalogue CSV (quoted fields may span lines) into books.
    @concurrent
    nonisolated private static func parse(_ url: URL) async -> [Book] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        var rows: [[String]] = []
        rows.reserveCapacity(80_000)
        var row: [String] = []
        var field: [UInt8] = []
        var inQuote = false
        data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            let b = buf.bindMemory(to: UInt8.self)
            var i = 0
            let n = b.count
            while i < n {
                let c = b[i]
                if inQuote {
                    if c == 34 {
                        if i + 1 < n && b[i + 1] == 34 { field.append(34); i += 1 } else { inQuote = false }
                    } else {
                        field.append(c)
                    }
                } else if c == 34 {
                    inQuote = true
                } else if c == 44 {
                    row.append(String(decoding: field, as: UTF8.self))
                    field.removeAll(keepingCapacity: true)
                } else if c == 10 {
                    row.append(String(decoding: field, as: UTF8.self))
                    field.removeAll(keepingCapacity: true)
                    rows.append(row)
                    row.removeAll(keepingCapacity: true)
                } else if c != 13 {
                    field.append(c)
                }
                i += 1
            }
        }
        var books: [Book] = []
        books.reserveCapacity(rows.count)
        for r in rows.dropFirst() where r.count >= 9 && r[1] == "Text" {
            guard let id = Int(r[0]) else { continue }
            let title = r[3].components(separatedBy: "\n").first?.trimmingCharacters(in: .whitespaces) ?? r[3]
            let shelves = r[8].split(separator: ";").compactMap { s -> String? in
                let t = s.trimmingCharacters(in: .whitespaces)
                return t.hasPrefix("Category: ") ? String(t.dropFirst(10)) : nil
            }
            books.append(Book(id: id, title: title, author: displayAuthor(r[5]),
                              language: r[4].split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? "",
                              shelves: shelves, subjects: r[6]))
        }
        return books
    }

    /// "Austen, Jane, 1775-1817; Someone Else" becomes "Jane Austen".
    nonisolated static func displayAuthor(_ raw: String) -> String {
        guard let first = raw.split(separator: ";").first else { return "" }
        let cleaned = first.replacingOccurrences(of: "\\[[^\\]]*\\]", with: "", options: .regularExpression)
        let parts = cleaned.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0.rangeOfCharacter(from: .decimalDigits) == nil && $0 != "BCE" }
        if parts.count >= 2 { return "\(parts[1]) \(parts[0])" }
        return parts.first ?? ""
    }

    // MARK: Most read

    private static var topCache: [Int]?

    /// The hundred most-downloaded books of the last thirty days.
    static func topIDs() async -> [Int] {
        if let t = topCache { return t }
        guard let (data, _) = try? await Web.get(topURL) else { return [] }
        let html = String(decoding: data, as: UTF8.self)
        guard let start = html.range(of: "id=\"books-last30\"") else { return [] }
        let section = html[start.upperBound...]
        let end = section.range(of: "</ol>")?.lowerBound ?? section.endIndex
        let chunk = String(section[..<end])
        let re = try! NSRegularExpression(pattern: "href=\"/ebooks/(\\d+)\"")
        let ns = chunk as NSString
        let ids = re.matches(in: chunk, range: NSRange(location: 0, length: ns.length)).compactMap { Int(ns.substring(with: $0.range(at: 1))) }
        topCache = ids
        return ids
    }

    // MARK: Live search

    /// Project Gutenberg's own search, which looks further than titles and authors.
    static func search(_ query: String, catalog: [Int: Book]) async -> [Book] {
        var c = URLComponents(string: "https://www.gutenberg.org/ebooks/search/")!
        c.queryItems = [URLQueryItem(name: "query", value: query), URLQueryItem(name: "submit_search", value: "Go!")]
        var results: [Book] = []
        var seen = Set<Int>()
        for start in [1, 26, 51] {
            var page = c
            if start > 1 { page.queryItems?.append(URLQueryItem(name: "start_index", value: "\(start)")) }
            guard let url = page.url, let (data, _) = try? await Web.get(url) else { break }
            let html = String(decoding: data, as: UTF8.self)
            let blocks = html.components(separatedBy: "<li class=\"booklink\">").dropFirst()
            if blocks.isEmpty { break }
            for b in blocks {
                guard let id = firstMatch(b, "href=\"/ebooks/(\\d+)\"").flatMap(Int.init), !seen.contains(id) else { continue }
                seen.insert(id)
                if let known = catalog[id] {
                    results.append(known)
                } else {
                    let title = HTMLText.decodeEntities(firstMatch(b, "<span class=\"title\">([^<]*)</span>") ?? "Untitled")
                    let author = HTMLText.decodeEntities(firstMatch(b, "<span class=\"subtitle\">([^<]*)</span>") ?? "")
                    results.append(Book(id: id, title: title, author: author, language: "", shelves: []))
                }
            }
            if blocks.count < 25 { break }
        }
        return results
    }

    private static func firstMatch(_ s: String, _ pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)), m.numberOfRanges > 1 else { return nil }
        return ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Books

    static func download(_ book: Book) async throws -> String {
        let local = textFile(book.id)
        if let s = try? String(contentsOf: local, encoding: .utf8) { return s }
        let url = URL(string: "https://www.gutenberg.org/cache/epub/\(book.id)/pg\(book.id).txt")!
        let (data, resp) = try await Web.get(url)
        guard resp.statusCode < 400 else { throw WebError.http(resp.statusCode) }
        let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        try text.write(to: local, atomically: true, encoding: .utf8)
        return text
    }
}

/// The books on this Mac and where the reader is in each, kept in BOOKS/shelf.json.
@MainActor
final class ShelfStore {
    static let shared = ShelfStore()
    private(set) var entries: [Int: ShelfEntry] = [:]
    private var file: URL { Gutenberg.booksDir.appendingPathComponent("shelf.json") }

    private init() {
        if let data = try? Data(contentsOf: file), let list = try? JSONDecoder().decode([ShelfEntry].self, from: data) {
            for e in list where FileManager.default.fileExists(atPath: Gutenberg.textFile(e.book.id).path) {
                entries[e.book.id] = e
            }
        }
    }

    var reading: [ShelfEntry] {
        entries.values.filter { $0.lastRead != nil && $0.position > 0 && $0.position < $0.length - 200 }
            .sorted { ($0.lastRead ?? .distantPast) > ($1.lastRead ?? .distantPast) }
    }

    var onThisMac: [ShelfEntry] {
        entries.values.sorted { $0.book.title.localizedStandardCompare($1.book.title) == .orderedAscending }
    }

    func add(_ book: Book, length: Int) {
        if entries[book.id] == nil { entries[book.id] = ShelfEntry(book: book, position: 0, length: length, lastRead: nil) }
        save()
    }

    func setPosition(_ id: Int, _ position: Int, length: Int) {
        guard var e = entries[id] else { return }
        e.position = position
        e.length = length
        e.lastRead = Date()
        entries[id] = e
        save()
    }

    func remove(_ id: Int) {
        entries[id] = nil
        try? FileManager.default.trashItem(at: Gutenberg.textFile(id), resultingItemURL: nil)
        save()
    }

    private func save() {
        let list = Array(entries.values)
        if let data = try? JSONEncoder().encode(list) { try? data.write(to: file, options: .atomic) }
    }
}

/// Turns a Gutenberg plain-text book into typeset pages: paragraphs rejoined, italics restored,
/// chapters starting on a fresh page.
/// How a reader likes books set: typeface, size, spacing, margins, pages and page colour.
struct ReaderPrefs {
    var font: String
    var size: CGFloat
    var spacing: CGFloat
    var margin: Int
    var justify: Bool
    var pages: Int
    var page: String

    static let fonts = ["New York", "Georgia", "Palatino", "Baskerville", "Charter", "Iowan Old Style",
                        "Avenir Next", "Helvetica Neue", "Atkinson Hyperlegible Mono"]
    static let pageColours = ["Minimalia", "Night", "Dusk", "Paper", "White"]

    static func load() -> ReaderPrefs {
        let d = UserDefaults.standard
        let s = d.double(forKey: "bookFontSize")
        let h = NSScreen.main?.frame.height ?? 1000
        return ReaderPrefs(
            font: d.string(forKey: "reader.font") ?? "New York",
            size: s > 0 ? CGFloat(s) : min(28, max(18, (h / 48).rounded())),
            spacing: d.object(forKey: "reader.spacing") as? CGFloat ?? 1.32,
            margin: d.object(forKey: "reader.margin") as? Int ?? 1,
            justify: d.object(forKey: "reader.justify") as? Bool ?? true,
            pages: d.object(forKey: "reader.pages") as? Int ?? 0,
            page: d.string(forKey: "reader.page") ?? "Minimalia")
    }

    func save() {
        let d = UserDefaults.standard
        d.set(font, forKey: "reader.font")
        d.set(Double(size), forKey: "bookFontSize")
        d.set(Double(spacing), forKey: "reader.spacing")
        d.set(margin, forKey: "reader.margin")
        d.set(justify, forKey: "reader.justify")
        d.set(pages, forKey: "reader.pages")
        d.set(page, forKey: "reader.page")
    }

    /// Page colour, ink and the quieter ink for headers, all greys.
    @MainActor var colours: (bg: NSColor, ink: NSColor, dim: NSColor) {
        switch page {
        case "Night": return (NSColor(hex: 0x121212), NSColor(hex: 0xC9C6C0), NSColor(hex: 0x7D7A75))
        case "Dusk": return (NSColor(hex: 0x2B2C2F), NSColor(hex: 0xDAD6CE), NSColor(hex: 0x99958E))
        case "Paper": return (NSColor(hex: 0xEEEAE1), NSColor(hex: 0x2E2C29), NSColor(hex: 0x77736B))
        case "White": return (NSColor(hex: 0xFFFFFF), NSColor(hex: 0x111111), NSColor(hex: 0x666666))
        default:
            let p = MonoPalette.current
            return (p.desk, p.ink, p.dim)
        }
    }
}

enum BookFormatter {
    static func body(_ size: CGFloat, family: String = "New York") -> NSFont {
        if family != "New York", let f = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size) {
            return f
        }
        let base = NSFont.systemFont(ofSize: size)
        if let d = base.fontDescriptor.withDesign(.serif), let f = NSFont(descriptor: d, size: size) { return f }
        return NSFont(name: "Georgia", size: size) ?? base
    }

    /// Strips Project Gutenberg's licence header and footer.
    static func strip(_ raw: String) -> String {
        var t = raw.replacingOccurrences(of: "\r\n", with: "\n")
        if let r = t.range(of: "*** START OF"), let nl = t[r.upperBound...].firstIndex(of: "\n") {
            t = String(t[t.index(after: nl)...])
        }
        if let r = t.range(of: "*** END OF") { t = String(t[..<r.lowerBound]) }
        return t
    }

    static func format(_ raw: String, book: Book, prefs: ReaderPrefs, ink: NSColor, dim: NSColor) -> (NSAttributedString, [(String, Int)]) {
        let fm = NSFontManager.shared
        let size = prefs.size
        let family = prefs.font
        func body(_ s: CGFloat) -> NSFont { BookFormatter.body(s, family: family) }
        let font = body(size)
        let italic = fm.convert(font, toHaveTrait: .italicFontMask)
        let headingFont = fm.convert(body(round(size * 1.3)), toHaveTrait: .boldFontMask)

        let bodyPara = NSMutableParagraphStyle()
        bodyPara.lineHeightMultiple = prefs.spacing
        bodyPara.firstLineHeadIndent = round(size * 1.4)
        bodyPara.paragraphSpacing = round(size * 0.2)
        bodyPara.alignment = prefs.justify ? .justified : .natural
        bodyPara.hyphenationFactor = prefs.justify ? 0.8 : 0.3

        let firstPara = bodyPara.mutableCopy() as! NSMutableParagraphStyle
        firstPara.firstLineHeadIndent = 0

        let versePara = NSMutableParagraphStyle()
        versePara.lineHeightMultiple = prefs.spacing
        versePara.headIndent = round(size * 1.4)
        versePara.firstLineHeadIndent = round(size * 1.4)
        versePara.paragraphSpacing = round(size * 0.6)

        let headPara = NSMutableParagraphStyle()
        headPara.alignment = .center
        headPara.paragraphSpacingBefore = round(size * 2)
        headPara.paragraphSpacing = round(size * 1.2)
        headPara.lineHeightMultiple = 1.2

        let titlePara = NSMutableParagraphStyle()
        titlePara.alignment = .center
        titlePara.paragraphSpacingBefore = round(size * 6)
        titlePara.paragraphSpacing = round(size * 1.5)

        let out = NSMutableAttributedString()
        out.append(NSAttributedString(string: book.title + "\n", attributes: [
            .font: fm.convert(body(round(size * 1.8)), toHaveTrait: .boldFontMask), .foregroundColor: ink, .paragraphStyle: titlePara]))
        let byPara = titlePara.mutableCopy() as! NSMutableParagraphStyle
        byPara.paragraphSpacingBefore = 0
        out.append(NSAttributedString(string: book.author + "\n\u{0C}", attributes: [
            .font: body(round(size * 1.1)), .foregroundColor: dim, .paragraphStyle: byPara]))

        var chapters: [(String, Int)] = []
        var lastBreak = 0
        var afterHeading = true
        let paragraphs = strip(raw).components(separatedBy: "\n\n")
        let headingStart = try! NSRegularExpression(pattern: "^(CHAPTER|Chapter|BOOK|Book|PART|Part|ACT|Act|VOLUME|Volume|LETTER|Letter|STAVE|Stave|CANTO|Canto)\\b|^[IVXLC]+\\.?$")

        for p in paragraphs {
            var lines = p.components(separatedBy: "\n").map { $0.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }
            lines = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            guard !lines.isEmpty else { continue }
            let joined = lines.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
            if joined.hasPrefix("[Illustration") { continue }

            let letters = joined.filter { $0.isLetter }
            let upper = !letters.isEmpty && letters == letters.uppercased()
            let ns = joined as NSString
            let isHeading = lines.count <= 3 && joined.count < 70
                && (headingStart.firstMatch(in: joined, range: NSRange(location: 0, length: ns.length)) != nil || (upper && letters.count > 1))
            let avg = lines.map(\.count).reduce(0, +) / lines.count
            // Verse lines start with capitals; wrapped prose continues in lower case.
            let rest = lines.dropFirst().map { $0.trimmingCharacters(in: .whitespaces) }
            let capitalStarts = rest.filter { $0.first.map { !$0.isLowercase } ?? true }.count
            let looksLikeVerse = !rest.isEmpty && Double(capitalStarts) / Double(rest.count) >= 0.7 && avg < 52
            let isVerse = !isHeading && lines.count > 1 && (looksLikeVerse || lines.allSatisfy { $0.hasPrefix(" ") })
            // In plays a speaker's name sits on its own line above the speech.
            let firstLine = lines[0].trimmingCharacters(in: .whitespaces)
            let firstLetters = firstLine.filter { $0.isLetter }
            let speaker = !isHeading && lines.count > 1 && firstLine.count < 30 && firstLine.hasSuffix(".")
                && !firstLetters.isEmpty && firstLetters == firstLetters.uppercased()

            if isHeading {
                // A new chapter starts a new page, unless it comes right after another (a contents list).
                if out.length - lastBreak > 1500 {
                    out.append(NSAttributedString(string: "\u{0C}", attributes: [.font: font]))
                    lastBreak = out.length
                    chapters.append((joined, out.length))
                } else if chapters.isEmpty && out.length - lastBreak > 0 {
                    chapters.append((joined, out.length))
                }
                out.append(NSAttributedString(string: lines.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n") + "\n",
                                              attributes: [.font: headingFont, .foregroundColor: ink, .paragraphStyle: headPara]))
                afterHeading = true
                continue
            }

            var text: String
            if speaker && !isVerse {
                text = firstLine + "\u{2028}" + rest.joined(separator: " ")
            } else {
                text = isVerse ? lines.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\u{2028}") : joined
            }
            text = text.replacingOccurrences(of: "--", with: "\u{2014}")
            let para = isVerse ? versePara : (afterHeading ? firstPara : bodyPara)
            let piece = NSMutableAttributedString(string: text + "\n", attributes: [.font: font, .foregroundColor: ink, .paragraphStyle: para])
            // Gutenberg marks italics as _words_.
            let pns = piece.string as NSString
            let re = try! NSRegularExpression(pattern: "_([^_\\n]{1,200})_")
            for m in re.matches(in: piece.string, range: NSRange(location: 0, length: pns.length)).reversed() {
                let inner = pns.substring(with: m.range(at: 1))
                piece.replaceCharacters(in: m.range, with: NSAttributedString(string: inner, attributes: [
                    .font: italic, .foregroundColor: ink, .paragraphStyle: para]))
            }
            // Italics that span paragraphs leave lone underscores behind.
            piece.mutableString.replaceOccurrences(of: "_", with: "", options: [], range: NSRange(location: 0, length: piece.length))
            out.append(piece)
            afterHeading = false
        }
        return (out, chapters)
    }
}
