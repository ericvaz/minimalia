import Foundation

/// A tradition's sacred texts, bundled in the app and searched with FIND, such as FIND BUDDHISM happiness.
///
/// Each one lives in its own folder of Resources: an index.json listing the books (id, file, title,
/// author, subjects) and one plain-text file per book. In the books, "# " starts a chapter, "## " a
/// smaller heading, lines indented by two spaces are verse, and anything before the first heading is
/// front matter that searches skip. Adding a tradition is a folder of books and a line in `all`.
final class Scripture {
    /// What FIND is followed by, such as "BUDDHISM", and other words that mean the same.
    let tradition: String
    let aliases: [String]
    /// The texts, as named in Shelf and in FIND's results, such as "Pali Canon".
    let shelf: String
    private let folder: String

    init(tradition: String, aliases: [String] = [], shelf: String, folder: String) {
        self.tradition = tradition
        self.aliases = aliases
        self.shelf = shelf
        self.folder = folder
    }

    private struct Entry: Decodable {
        let id: Int
        let file: String
        let title: String
        let author: String
        let subjects: String
    }

    private lazy var entries: [Entry] = {
        guard let url = Bundle.main.url(forResource: "index", withExtension: "json", subdirectory: folder),
              let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }()

    lazy var books: [Book] = entries.map {
        Book(id: $0.id, title: $0.title, author: $0.author, language: "en", shelves: [shelf], subjects: $0.subjects)
    }

    func contains(_ id: Int) -> Bool { entries.contains { $0.id == id } }

    func text(of book: Book) -> String? {
        guard let e = entries.first(where: { $0.id == book.id }),
              let url = Bundle.main.url(forResource: e.file, withExtension: "txt", subdirectory: folder) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    // MARK: Search

    private struct Paragraph {
        let book: Int
        let reference: String
        let foldedReference: String
        let text: String
        let verse: Bool
        let folded: String
        let words: Int
        let start: String
    }

    /// Every paragraph of every book, read on the first search.
    private lazy var paragraphs: [Paragraph] = {
        var out: [Paragraph] = []
        for (i, b) in books.enumerated() {
            guard let text = text(of: b) else { continue }
            var reference = ""
            var chapter = ""
            for p in text.components(separatedBy: "\n\n") {
                let lines = p.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                guard let first = lines.first else { continue }
                if first.hasPrefix("# ") {
                    chapter = lines.count > 1 ? lines.last! : String(first.dropFirst(2))
                    reference = chapter
                    continue
                }
                if first.hasPrefix("## ") {
                    // A numbered text ("SN 12.1  Dependent Origination") becomes the reference; a section
                    // heading inside one keeps the chapter as its reference.
                    let minor = String(first.dropFirst(3))
                    reference = minor.range(of: "^[A-Za-z]+ [0-9]", options: .regularExpression) != nil ? minor : chapter
                    continue
                }
                guard !reference.isEmpty else { continue }
                let verse = p.hasPrefix("  ")
                let joined = lines.joined(separator: verse ? " / " : " ")
                out.append(Paragraph(book: i, reference: reference, foldedReference: Self.fold(reference), text: joined,
                                     verse: verse, folded: Self.fold(joined), words: joined.split(separator: " ").count,
                                     start: String(first.prefix(60))))
            }
        }
        return out
    }()

    private lazy var averageWords: Double = Double(paragraphs.reduce(0) { $0 + $1.words }) / Double(max(1, paragraphs.count))

    /// Passages containing every word, the most fitting first. Rare words count for more than common
    /// ones, a text whose title holds the words ranks higher, and a paragraph repeated word for word
    /// appears once.
    func search(_ query: String) -> [Passage] {
        let ts = Self.terms(query)
        guard !ts.isEmpty else { return [] }
        var found = [Int](repeating: 0, count: ts.count)
        var hits: [(Int, [Int])] = []
        for (i, p) in paragraphs.enumerated() {
            var counts = [Int](repeating: 0, count: ts.count)
            let range = NSRange(location: 0, length: (p.folded as NSString).length)
            for (t, term) in ts.enumerated() where p.folded.contains(term.stem) {
                counts[t] = term.pattern.numberOfMatches(in: p.folded, range: range)
                if counts[t] > 0 { found[t] += 1 }
            }
            if counts.allSatisfy({ $0 > 0 }) { hits.append((i, counts)) }
        }
        let n = Double(paragraphs.count)
        let weights = found.map { log(1 + (n - Double($0) + 0.5) / (Double($0) + 0.5)) }
        let average = averageWords
        func score(_ i: Int, _ counts: [Int]) -> Double {
            let p = paragraphs[i]
            let length = 0.25 + 0.75 * Double(p.words) / average
            let title = NSRange(location: 0, length: (p.foldedReference as NSString).length)
            var s = 0.0
            for (t, c) in counts.enumerated() {
                let tf = Double(c)
                s += weights[t] * tf * 2.2 / (tf + 1.2 * length)
                if ts[t].pattern.firstMatch(in: p.foldedReference, range: title) != nil { s += weights[t] / 2 }
            }
            // A short line says little on its own; a full paragraph or verse is what a reader wants.
            return s * min(1, Double(p.words) / 25)
        }
        let ranked = hits.map { ($0.0, score($0.0, $0.1)) }.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
        var out: [Passage] = []
        var seen: [String: Int] = [:]
        for (i, _) in ranked {
            let p = paragraphs[i]
            if let k = seen[p.folded] { out[k].repeats += 1; continue }
            seen[p.folded] = out.count
            out.append(Passage(scripture: shelf, book: books[p.book], reference: p.reference, text: p.text, verse: p.verse, start: p.start))
        }
        return out
    }

    /// The chapter or text a passage belongs to, on its own, for opening quickly: the book's front
    /// matter, then everything from the passage's heading to the next heading of the same kind.
    func excerpt(_ p: Passage) -> String? {
        guard let text = text(of: p.book) else { return nil }
        let ns = text as NSString
        let all = NSRange(location: 0, length: ns.length)
        let front = ns.range(of: "\n\n# ")
        guard front.location != NSNotFound else { return nil }
        var start: Int
        var stops: [String]
        let minor = ns.range(of: "\n\n## " + p.reference + "\n", range: all)
        if minor.location != NSNotFound {
            start = minor.location + 2
            stops = ["\n\n## ", "\n\n# "]
        } else {
            let line = ns.range(of: p.reference + "\n\n", range: all)
            guard line.location != NSNotFound else { return nil }
            let head = ns.range(of: "\n\n# ", options: .backwards, range: NSRange(location: 0, length: line.location))
            start = head.location == NSNotFound ? line.location : head.location + 2
            stops = ["\n\n# "]
        }
        var end = ns.length
        for s in stops {
            let r = ns.range(of: s, range: NSRange(location: start + 3, length: ns.length - start - 3))
            if r.location != NSNotFound { end = min(end, r.location) }
        }
        // A sutta in SN or AN is short; keep the chapter around it so reading on is natural.
        if minor.location != NSNotFound, end - start < 4000 {
            let r = ns.range(of: "\n\n# ", range: NSRange(location: end, length: ns.length - end))
            end = r.location == NSNotFound ? ns.length : r.location
        }
        return ns.substring(to: front.location) + "\n\n" + ns.substring(with: NSRange(location: start, length: end - start))
    }

    // MARK: Words

    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    private static let suffixes = ["fulness", "iness", "ness", "ments", "ment", "fully", "ful", "less", "ings", "ing",
                                   "ied", "ies", "ily", "ed", "es", "ly", "s"]

    /// The words of a search, each with the pattern that finds it. A word also finds its other forms:
    /// "happiness" finds happy and happily, "craving" finds crave and craved, while "raft" finds rafts
    /// but not rafters. A word ending in * finds anything that starts with it, and words in quotes are
    /// found exactly, as one phrase.
    static func terms(_ query: String) -> [(stem: String, pattern: NSRegularExpression)] {
        let q = fold(query.trimmingCharacters(in: .whitespaces))
        if q.count > 2, q.hasPrefix("\""), q.hasSuffix("\"") {
            let phrase = String(q.dropFirst().dropLast())
            let p = "\\b" + NSRegularExpression.escapedPattern(for: phrase) + "\\b"
            return (try? NSRegularExpression(pattern: p)).map { [(phrase, $0)] } ?? []
        }
        let words = q.split(separator: " ").map { $0.replacingOccurrences(of: "\"", with: "") }.filter { !$0.isEmpty }
        return words.compactMap { w in
            var pattern: String
            var stem: String
            if w.hasSuffix("*") {
                stem = String(w.dropLast())
                pattern = "\\b" + NSRegularExpression.escapedPattern(for: stem)
            } else {
                stem = w
                if let s = suffixes.first(where: { w.hasSuffix($0) && w.count - $0.count >= 3 }) { stem = String(w.dropLast(s.count)) }
                if let last = stem.last, "eiy".contains(last), stem.count > 3 { stem = String(stem.dropLast()) }
                if stem.count < 3 { stem = w }
                pattern = "\\b" + NSRegularExpression.escapedPattern(for: stem)
                    + "(e|i|y)?(" + suffixes.joined(separator: "|") + "|d)?\\b"
            }
            guard !stem.isEmpty, let re = try? NSRegularExpression(pattern: pattern) else { return nil }
            return (stem, re)
        }
    }

    /// Where the words searched for appear in a line, for highlighting.
    static func matches(in line: String, for query: String) -> [NSRange] {
        let folded = fold(line) as NSString
        guard folded.length == (line as NSString).length else { return [] }
        return terms(query).flatMap { $0.pattern.matches(in: folded as String, range: NSRange(location: 0, length: folded.length)).map(\.range) }
            .sorted { $0.location < $1.location }
    }

    // MARK: Traditions

    /// Every tradition in Minimalia. Islam and Christianity follow the same pattern.
    static let all: [Scripture] = [PaliCanon.scripture].filter { !$0.books.isEmpty }

    static func named(_ word: String) -> Scripture? {
        let w = word.uppercased()
        return all.first { $0.tradition == w || $0.aliases.contains(w) }
    }

    static var books: [Book] { all.flatMap(\.books) }

    static func contains(_ id: Int) -> Bool { all.contains { $0.contains(id) } }

    static func text(of book: Book) -> String? {
        all.first { $0.contains(book.id) }?.text(of: book)
    }

    static func shelf(of book: Book) -> String? { all.first { $0.contains(book.id) }?.shelf }
}

/// A paragraph or verse found by FIND, and where it sits.
struct Passage {
    /// The shelf it comes from, such as "Pali Canon".
    let scripture: String
    let book: Book
    /// The text or chapter, such as "MN 1  The Root of All Things".
    let reference: String
    /// The paragraph, with verse lines joined by slashes.
    let text: String
    let verse: Bool
    /// Its first words, which the reader looks for after the reference to open at the right page.
    let start: String
    /// How many other places repeat this paragraph word for word.
    var repeats = 0
}
