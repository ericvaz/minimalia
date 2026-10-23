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

    static func isCanon(_ url: URL?) -> Bool { url?.host?.hasSuffix("suttacentral.net") == true }
}
