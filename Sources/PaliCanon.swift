import Foundation

/// The Pali Canon's discourses in Bhikkhu Sujato's translation, from SuttaCentral (CC0), bundled in
/// the app. Tools/make_canon.swift builds the books and build.sh copies them into Resources/Canon.
enum PaliCanon {
    static let shelf = "Pali Canon"

    /// Every book starts with this line. The translator asks that the work not be used with AI,
    /// so SUMMARIZE refuses any text that carries it.
    static let marker = "Published by SuttaCentral (suttacentral.net)"

    private struct Entry: Decodable {
        let id: Int
        let file: String
        let title: String
        let author: String
        let subjects: String
    }

    private static let entries: [Entry] = {
        guard let url = Bundle.main.url(forResource: "index", withExtension: "json", subdirectory: "Canon"),
              let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }()

    static let books: [Book] = entries.map {
        Book(id: $0.id, title: $0.title, author: $0.author, language: "en", shelves: [shelf], subjects: $0.subjects)
    }

    static func contains(_ id: Int) -> Bool { entries.contains { $0.id == id } }

    /// The text of a bundled book, or nil for a Project Gutenberg book.
    static func text(of book: Book) -> String? {
        guard let e = entries.first(where: { $0.id == book.id }),
              let url = Bundle.main.url(forResource: e.file, withExtension: "txt", subdirectory: "Canon") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    static func isCanon(_ text: String) -> Bool { text.contains(marker) }

    // MARK: Search

    /// A paragraph or verse found by FIND, and where it sits.
    struct Passage {
        let book: Book
        /// The sutta or chapter, such as "MN 1  The Root of All Things".
        let reference: String
        /// The paragraph, with verse lines joined by slashes.
        let text: String
        /// Its first words, which the reader looks for after the reference to open at the right page.
        let start: String
    }

    private struct Paragraph {
        let book: Int
        let reference: String
        let text: String
        let folded: String
        let start: String
    }

    private static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// Every paragraph of every book, read once on the first search.
    private static let paragraphs: [Paragraph] = {
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
                    // A sutta in SN and AN ("SN 12.1  Dependent Origination"); elsewhere a section inside one,
                    // which keeps the sutta as its reference.
                    let minor = String(first.dropFirst(3))
                    reference = minor.range(of: "^[A-Za-z]+ [0-9]", options: .regularExpression) != nil ? minor : chapter
                    continue
                }
                // The front matter comes before the first heading.
                guard !reference.isEmpty else { continue }
                let joined = lines.joined(separator: p.hasPrefix("  ") ? " / " : " ")
                out.append(Paragraph(book: i, reference: reference, text: joined, folded: fold(joined), start: String(first.prefix(60))))
            }
        }
        return out
    }()

    /// Passages containing every word, in the order of the canon. Words in quotes are found as a phrase.
    static func search(_ query: String) -> [Passage] {
        let q = fold(query.trimmingCharacters(in: .whitespaces))
        let terms: [String]
        if q.count > 2, q.hasPrefix("\""), q.hasSuffix("\"") {
            terms = [String(q.dropFirst().dropLast())]
        } else {
            terms = q.split(separator: " ").map(String.init)
        }
        guard !terms.isEmpty else { return [] }
        // Whole words, plurals included: "raft" finds "rafts" but not "rafters".
        // A word ending in * also finds longer forms: "attach*" finds "attachment".
        let stems = terms.map { $0.hasSuffix("*") ? String($0.dropLast()) : $0 }
        let patterns = terms.map { t in
            t.hasSuffix("*") ? "\\b" + NSRegularExpression.escapedPattern(for: String(t.dropLast()))
                : "\\b" + NSRegularExpression.escapedPattern(for: t) + "(s|es)?\\b"
        }
        return paragraphs.filter { p in
            stems.allSatisfy { p.folded.contains($0) }
                && patterns.allSatisfy { p.folded.range(of: $0, options: .regularExpression) != nil }
        }.map { Passage(book: books[$0.book], reference: $0.reference, text: $0.text, start: $0.start) }
    }

    /// A stretch of the passage around the first word searched for.
    static func snippet(_ p: Passage, for query: String, width: Int) -> String {
        let text = p.text
        guard text.count > width else { return text }
        let word = fold(query.replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "*", with: ""))
            .split(separator: " ").first.map(String.init) ?? ""
        let folded = fold(text)
        var start = 0
        if let r = folded.range(of: word) {
            start = max(0, folded.distance(from: folded.startIndex, to: r.lowerBound) - width / 3)
        }
        start = min(start, text.count - width + 1)
        var s = String(text.dropFirst(start).prefix(width - 2))
        if start > 0 { s = "\u{2026}" + s }
        if start + width - 2 < text.count { s += "\u{2026}" }
        return s
    }

    static func isCanon(_ url: URL?) -> Bool { url?.host?.hasSuffix("suttacentral.net") == true }
}
