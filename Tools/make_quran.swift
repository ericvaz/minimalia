// Builds the Qur'an for Minimalia Shelf and FIND ISLAM from Project Gutenberg's eBook #16955.
//
// That edition sets three translations side by side, verse by verse. Only Marmaduke Pickthall's,
// The Meaning of the Glorious Koran (1930), is used: Pickthall died in 1936, so it is in the public
// domain. Run from the repository root:
//
//   curl -L -o /tmp/pg16955.txt https://www.gutenberg.org/cache/epub/16955/pg16955.txt
//   swift Tools/make_quran.swift /tmp/pg16955.txt Resources/Quran
//
// Each surah is a chapter ("# Surah 2  Al-Baqara (The Cow)") and each verse a paragraph that starts
// with its number ("153. O ye who believe!"), which FIND turns into a reference such as Qur'an 2:153.

import Foundation

let frontMatter = """
The Meaning of the Glorious Koran, translated by Marmaduke Pickthall and first published in 1930. Pickthall died in 1936, and the translation is now in the public domain. The text follows Project Gutenberg's edition, which was proofread against the printed translation.
"""

let args = CommandLine.arguments
guard args.count == 3 else {
    print("Usage: swift Tools/make_quran.swift <pg16955.txt> <output folder>")
    exit(1)
}
let source = try String(contentsOfFile: args[1], encoding: .utf8).replacingOccurrences(of: "\r\n", with: "\n")
let outDir = URL(fileURLWithPath: args[2])
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

/// "AL-I'MRAN (THE FAMILY OF IMRAN)" becomes "Al-I'mran (The Family of Imran)".
func titleCase(_ s: String) -> String {
    let small: Set<String> = ["of", "the", "and", "in", "a", "an", "to", "for", "by", "on", "or", "from", "with", "at"]
    var out: [String] = []
    for (i, word) in s.lowercased().split(separator: " ").enumerated() {
        let w = String(word)
        let open = w.hasPrefix("(")
        let bare = open ? String(w.dropFirst()) : w
        if i > 0 && !open && small.contains(bare) { out.append(w); continue }
        let parts = bare.split(separator: "-", omittingEmptySubsequences: false).map { p -> String in
            let lead = p.hasPrefix("'") ? "'" : ""
            let word = p.dropFirst(lead.count)
            guard let f = word.first else { return String(p) }
            return lead + String(f).uppercased() + word.dropFirst()
        }
        out.append((open ? "(" : "") + parts.joined(separator: "-"))
    }
    return out.joined(separator: " ")
}

let lines = source.components(separatedBy: "\n")
var paragraphs: [String] = []
var surahs = 0
var verses = 0
var stated: [Int] = []
var counted: [Int] = []
var i = 0
while i < lines.count {
    let line = lines[i].trimmingCharacters(in: .whitespaces)
    if let m = line.range(of: "^Chapter ([0-9]+):$", options: .regularExpression) {
        let number = Int(line[m].dropFirst(8).dropLast()) ?? 0
        // The surah's name is the next line with text.
        var j = i + 1
        while j < lines.count && lines[j].trimmingCharacters(in: .whitespaces).isEmpty { j += 1 }
        let name = titleCase(lines[j].trimmingCharacters(in: .whitespaces))
        paragraphs.append("# Surah \(number)  \(name)")
        surahs += 1
        let totals = lines[j...].prefix(4).compactMap { l -> Int? in
            guard let r = l.range(of: "Total Verses: [0-9]+", options: .regularExpression) else { return nil }
            return Int(l[r].split(separator: " ").last ?? "")
        }
        stated.append(totals.first ?? 0)
        counted.append(0)
        i = j + 1
        continue
    }
    // A verse: "017.032". A few headers in the source are misprinted ("0.033", "039.04"), so verses
    // are numbered in order within their surah, and the counts are checked against the edition below.
    if line.range(of: "^[0-9]{0,3}\\.[0-9]{1,3}$", options: .regularExpression) != nil {
        let verse = (counted.last ?? 0) + 1
        // Find Pickthall's rendering, "P: ...", which may run over several lines.
        var j = i + 1
        while j < lines.count && !lines[j].hasPrefix("P: ") && lines[j].range(of: "^[0-9]{0,3}\\.[0-9]{1,3}$", options: .regularExpression) == nil { j += 1 }
        guard j < lines.count, lines[j].hasPrefix("P: ") else { fatalError("No Pickthall text for \(line)") }
        var text = String(lines[j].dropFirst(3))
        j += 1
        while j < lines.count && !lines[j].trimmingCharacters(in: .whitespaces).isEmpty {
            text += " " + lines[j].trimmingCharacters(in: .whitespaces)
            j += 1
        }
        text = text.replacingOccurrences(of: "_", with: "").replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        paragraphs.append("\(verse). \(text.trimmingCharacters(in: .whitespaces))")
        verses += 1
        counted[counted.count - 1] += 1
        i = j
        continue
    }
    if line.hasPrefix("*** END OF") { break }
    i += 1
}
guard surahs == 114 else { fatalError("Found \(surahs) surahs, expected 114") }
for (k, n) in counted.enumerated() where n != stated[k] {
    fatalError("Surah \(k + 1): \(n) verses, the edition says \(stated[k])")
}

let body = ([frontMatter] + paragraphs).joined(separator: "\n\n") + "\n"
let txt = outDir.appendingPathComponent("quran.txt")
try body.write(to: txt, atomically: true, encoding: .utf8)
let gz = Process()
gz.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
gz.arguments = ["-9nf", txt.path]
try gz.run()
gz.waitUntilExit()

let index: [[String: Any]] = [[
    "id": 1_100_001, "file": "quran", "title": "The Qur'an (The Meaning of the Glorious Koran)",
    "author": "Marmaduke Pickthall", "subjects": "Islam; Qur'an; Quran; Koran; Holy Qur'an; scripture",
]]
let json = try JSONSerialization.data(withJSONObject: index, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
try json.write(to: outDir.appendingPathComponent("index.json"))
print("Wrote the Qur'an: \(surahs) surahs, \(verses) verses, \(body.count / 1000)K characters")
