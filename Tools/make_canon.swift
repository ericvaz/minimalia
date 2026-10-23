// Builds the Pali Canon books for Minimalia Shelf from SuttaCentral's bilara-data.
//
// Bhikkhu Sujato's translations are dedicated to the public domain (CC0). Fetch the parts this
// needs once, then run the tool from the repository root:
//
//   git clone --depth 1 --filter=blob:none --sparse -b published \
//     https://github.com/suttacentral/bilara-data.git /tmp/bilara-data
//   git -C /tmp/bilara-data sparse-checkout set translation/en/sujato html/pli/ms/sutta
//   swift Tools/make_canon.swift /tmp/bilara-data Resources/Canon
//
// It writes one gzipped plain-text book per collection and index.json, which Shelf reads.
// In the books, "# " starts a chapter (a new page and an entry in Contents), "## " a smaller
// heading, and lines indented by two spaces are verse.

import Foundation

struct Collection {
    let code: String           // SuttaCentral's prefix: dn, mn, sn...
    let folder: String         // where its texts are, under translation/en/sujato/sutta
    let titles: [String]       // one title per book; SN is split into its five groups
    let pali: String
    let suttaChapters: Bool    // each sutta starts a chapter; otherwise each chapter (vagga) does
}

let collections = [
    Collection(code: "dn", folder: "dn", titles: ["Long Discourses"], pali: "Dīgha Nikāya", suttaChapters: true),
    Collection(code: "mn", folder: "mn", titles: ["Middle Discourses"], pali: "Majjhima Nikāya", suttaChapters: true),
    Collection(code: "sn", folder: "sn", titles: ["Linked Discourses 1: With Verses", "Linked Discourses 2: On Causation",
                                                  "Linked Discourses 3: On the Aggregates", "Linked Discourses 4: On the Six Sense Fields",
                                                  "Linked Discourses 5: On the Path"], pali: "Saṁyutta Nikāya", suttaChapters: false),
    Collection(code: "an", folder: "an", titles: ["Numbered Discourses"], pali: "Aṅguttara Nikāya", suttaChapters: false),
    Collection(code: "kp", folder: "kn/kp", titles: ["Basic Passages"], pali: "Khuddakapāṭha", suttaChapters: true),
    Collection(code: "dhp", folder: "kn/dhp", titles: ["Sayings of the Dhamma"], pali: "Dhammapada", suttaChapters: true),
    Collection(code: "ud", folder: "kn/ud", titles: ["Heartfelt Sayings"], pali: "Udāna", suttaChapters: true),
    Collection(code: "iti", folder: "kn/iti", titles: ["So It Was Said"], pali: "Itivuttaka", suttaChapters: true),
    Collection(code: "snp", folder: "kn/snp", titles: ["Anthology of Discourses"], pali: "Sutta Nipāta", suttaChapters: true),
    Collection(code: "thag", folder: "kn/thag", titles: ["Verses of the Senior Monks"], pali: "Theragāthā", suttaChapters: true),
    Collection(code: "thig", folder: "kn/thig", titles: ["Verses of the Senior Nuns"], pali: "Therīgāthā", suttaChapters: true),
    Collection(code: "cp", folder: "kn/cp", titles: ["Canon of Conduct"], pali: "Cariyāpiṭaka", suttaChapters: true),
]

/// Shelf looks for this line to keep these books away from SUMMARIZE and AI.
let frontMatter = """
Translated by Bhikkhu Sujato. Published by SuttaCentral (suttacentral.net) and dedicated to the public domain under CC0.

The translator asks that this work not be used to train or build artificial intelligence. Minimalia honours that request: SUMMARIZE and AI are not offered on these texts.
"""

let args = CommandLine.arguments
guard args.count == 3 else {
    print("Usage: swift Tools/make_canon.swift <bilara-data folder> <output folder>")
    exit(1)
}
let data = URL(fileURLWithPath: args[1])
let outDir = URL(fileURLWithPath: args[2])
let fm = FileManager.default
try fm.createDirectory(at: outDir, withIntermediateDirectories: true)

func load(_ url: URL) -> [String: String] {
    guard let d = try? Data(contentsOf: url),
          let j = try? JSONSerialization.jsonObject(with: d) as? [String: String] else {
        fatalError("Cannot read \(url.path)")
    }
    return j
}

/// SuttaCentral's files are in natural order: mn1:2.1 before mn1:10.1.
func ordered(_ dict: [String: String]) -> [(String, String)] {
    dict.sorted { $0.key.compare($1.key, options: .numeric) == .orderedAscending }
}

/// Files by text id, such as mn1 or an1.1-10.
func files(in folder: URL, suffix: String) -> [String: URL] {
    var out: [String: URL] = [:]
    let e = fm.enumerator(at: folder, includingPropertiesForKeys: nil)
    while let u = e?.nextObject() as? URL {
        let name = u.lastPathComponent
        if name.hasSuffix(suffix) { out[String(name.dropLast(suffix.count))] = u }
    }
    return out
}

/// mn1 becomes MN 1, dhp1-20 becomes Dhp 1–20.
func display(_ uid: String) -> String {
    guard let r = uid.range(of: "^[a-z]+", options: .regularExpression) else { return uid }
    let prefix = String(uid[r])
    let rest = uid[r.upperBound...].replacingOccurrences(of: "-", with: "\u{2013}")
    let name = ["dn", "mn", "sn", "an"].contains(prefix) ? prefix.uppercased() : prefix.prefix(1).uppercased() + prefix.dropFirst()
    return rest.isEmpty ? name : "\(name) \(rest)"
}

func clean(_ s: String) -> String {
    s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        .replacingOccurrences(of: "_", with: "")
        .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespaces)
}

/// Writes one book at a time, paragraph by paragraph.
final class Book {
    var paragraphs: [String] = []
    var lines: [String] = []
    var current = ""
    var pendingGroups: [String] = []

    func flushLine() {
        let t = current.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty { lines.append(t) }
        current = ""
    }

    func flushParagraph(verse: Bool) {
        flushLine()
        if !lines.isEmpty { paragraphs.append(verse ? lines.map { "  " + $0 }.joined(separator: "\n") : lines.joined(separator: " ")) }
        lines = []
    }

    func chapter(_ heading: [String]) {
        let all = pendingGroups + heading
        pendingGroups = []
        guard !all.isEmpty else { return }
        paragraphs.append("# " + all.joined(separator: "\n"))
    }

    func minor(_ heading: String) {
        if !pendingGroups.isEmpty { chapter([]) }
        paragraphs.append("## " + heading)
    }
}

var index: [[String: Any]] = []
var nextID = 1_000_001
let translations = data.appendingPathComponent("translation/en/sujato/sutta")
let templates = data.appendingPathComponent("html/pli/ms/sutta")

for c in collections {
    let texts = files(in: translations.appendingPathComponent(c.folder), suffix: "_translation-en-sujato.json")
    let htmls = files(in: templates.appendingPathComponent(c.folder), suffix: "_html.json")
    let names = ordered(load(data.appendingPathComponent("translation/en/sujato/name/sutta/\(c.code)-name_translation-en-sujato.json")))

    var books: [Book] = []
    var book = Book()

    for (key, value) in names {
        let uid = String(key.split(separator: ".", maxSplits: 1).last ?? "")
        guard let textFile = texts[uid] else {
            // A group: a chapter, a saṁyutta, or one of SN's five books.
            let name = clean(value)
            if c.code == "sn" && uid.range(of: "[0-9]", options: .regularExpression) == nil {
                if !book.paragraphs.isEmpty { books.append(book); book = Book() }
                continue
            }
            if uid.range(of: "^[a-z]+[0-9]+$", options: .regularExpression) != nil {
                book.pendingGroups.append("\(display(uid))  \(name)")
            } else if !name.isEmpty {
                book.pendingGroups.append(name)
            }
            continue
        }
        guard let htmlFile = htmls[uid] else { fatalError("No layout for \(uid)") }
        let text = load(textFile)
        let html = ordered(load(htmlFile))
        var article = uid
        var titled = false
        var inVerse = false

        func heading(_ title: String) {
            titled = true
            // The Dhammapada's verses run on under their chapter, without a heading each.
            if c.code == "dhp" { return }
            let code = display(article)
            let t = title.range(of: "^[0-9]+$", options: .regularExpression) != nil ? "" : title
            let line = t.isEmpty ? code : "\(code)  \(t)"
            if c.suttaChapters { book.chapter([line]) } else { book.minor(line) }
            titled = true
        }

        for (seg, template) in html {
            let s = clean(text[seg] ?? "")
            if let m = template.range(of: "<(article|section)[^>]* id='([^']+)'", options: .regularExpression) {
                let tag = String(template[m])
                if let idr = tag.range(of: "id='[^']+'", options: .regularExpression) {
                    article = String(tag[idr].dropFirst(4).dropLast())
                    titled = false
                }
            }
            if template.contains("<li") { continue }
            if template.contains("range-title") {
                // The Dhammapada's chapters; elsewhere the same name comes from the groups above.
                if c.code == "dhp" {
                    let name = s.replacingOccurrences(of: "^[0-9]+\\. ", with: "", options: .regularExpression)
                    book.chapter(["\(display(uid))  \(name)"])
                }
                continue
            }
            if template.contains("sutta-title") {
                if c.code == "dhp" { titled = true; continue }
                heading(s)
                continue
            }
            if template.range(of: "<h[1-6]", options: .regularExpression) != nil {
                if !titled { heading("") }
                if !s.isEmpty { book.minor(s) }
                continue
            }
            if !titled && !s.isEmpty { heading("") }
            if template.contains("<p") || template.contains("<blockquote") {
                book.flushParagraph(verse: inVerse)
                inVerse = template.contains("verse-line")
            }
            if template.contains("verse-line") {
                inVerse = true
                book.flushLine()
                book.current = s
                book.flushLine()
            } else if !s.isEmpty {
                book.current += (book.current.isEmpty ? "" : " ") + s
            }
            if template.contains("<br") { book.flushLine() }
            if template.contains("</p>") || template.contains("</blockquote>") {
                book.flushParagraph(verse: inVerse)
                inVerse = false
            }
        }
        book.flushParagraph(verse: inVerse)
    }
    if !book.paragraphs.isEmpty { books.append(book) }
    guard books.count == c.titles.count else { fatalError("\(c.code): \(books.count) books, expected \(c.titles.count)") }

    for (i, b) in books.enumerated() {
        let slug = books.count > 1 ? "\(c.code)\(i + 1)" : c.code
        let body = ([frontMatter] + b.paragraphs).joined(separator: "\n\n") + "\n"
        let txt = outDir.appendingPathComponent("\(slug).txt")
        try body.write(to: txt, atomically: true, encoding: .utf8)
        let gz = Process()
        gz.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        gz.arguments = ["-9nf", txt.path]
        try gz.run()
        gz.waitUntilExit()
        let chapters = b.paragraphs.filter { $0.hasPrefix("# ") }.count
        index.append(["id": nextID, "file": slug, "title": "\(c.titles[i]) (\(c.pali))", "author": "Bhikkhu Sujato",
                      "subjects": "Buddhism; Pali Canon; Tipiṭaka; Sutta Piṭaka; \(c.pali); \(c.titles[i])"])
        print("\(slug): \(c.titles[i]), \(body.count / 1000)K characters, \(chapters) chapters")
        nextID += 1
    }
}

let json = try JSONSerialization.data(withJSONObject: index, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
try json.write(to: outDir.appendingPathComponent("index.json"))
print("Wrote \(index.count) books to \(outDir.path)")
