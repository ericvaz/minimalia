import AppKit
import PDFKit

enum DocKind {
    case plain(String.Encoding, crlf: Bool)
    case rich(NSAttributedString.DocumentType)
    case readOnly(String)

    var isRich: Bool { if case .rich = self { return true } else { return false } }
    var isReadOnly: Bool { if case .readOnly = self { return true } else { return false } }
}

struct LoadedDoc {
    var text: String
    var kind: DocKind
    var meta: [NSAttributedString.DocumentAttributeKey: Any] = [:]
}

enum DocError: LocalizedError {
    case binary
    case unsupported(String)
    case unreadable

    var errorDescription: String? {
        switch self {
        case .binary: return "This is not a text file."
        case .unsupported(let s): return s
        case .unreadable: return "The file could not be read."
        }
    }
}

enum DocumentIO {
    static let richTypes: [String: NSAttributedString.DocumentType] = [
        "doc": .docFormat,
        "docx": .officeOpenXML,
        "docm": .officeOpenXML,
        "dotx": .officeOpenXML,
        "rtf": .rtf,
        "rtfd": .rtfd,
        "odt": .openDocument,
        "wordml": .wordML,
        "webarchive": .webArchive,
    ]

    static let wordExtensions: Set<String> = ["doc", "docx", "docm", "dotx", "rtf", "rtfd", "odt", "wordml", "pages"]

    static func kindForNew(_ url: URL) -> DocKind {
        let ext = url.pathExtension.lowercased()
        if let t = richTypes[ext], ext != "webarchive" { return .rich(t) }
        return .plain(.utf8, crlf: false)
    }

    static func load(_ url: URL) throws -> LoadedDoc {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "pdf":
            guard let pdf = PDFDocument(url: url) else { throw DocError.unreadable }
            return LoadedDoc(text: pdf.string ?? "", kind: .readOnly("PDF"))
        case "pages", "numbers", "key":
            throw DocError.unsupported("iWork files cannot be read here. Use OPEN to view it in its own app.")
        default:
            break
        }
        if let type = richTypes[ext] {
            var attrs: NSDictionary?
            let s = try NSAttributedString(url: url, options: [.documentType: type], documentAttributes: &attrs)
            var text = s.string
                .replacingOccurrences(of: "\u{2028}", with: "\n")
                .replacingOccurrences(of: "\u{2029}", with: "\n")
                .replacingOccurrences(of: "\u{FFFC}", with: "")
            text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            let meta = attrs as? [NSAttributedString.DocumentAttributeKey: Any] ?? [:]
            let kind: DocKind = ext == "webarchive" ? .readOnly("web archive") : .rich(type)
            return LoadedDoc(text: text, kind: kind, meta: meta)
        }
        return try loadPlain(url)
    }

    static func loadPlain(_ url: URL) throws -> LoadedDoc {
        let data = try Data(contentsOf: url)
        var text: String?
        var encoding: String.Encoding = .utf8
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            text = String(data: data, encoding: .utf16)
            encoding = .utf16
        } else {
            if data.prefix(8192).contains(0) { throw DocError.binary }
            for enc in [String.Encoding.utf8, .windowsCP1252, .macOSRoman] {
                if let s = String(data: data, encoding: enc) {
                    text = s
                    encoding = enc
                    break
                }
            }
        }
        guard var t = text else { throw DocError.unreadable }
        if t.hasPrefix("\u{FEFF}") { t.removeFirst() }
        let crlf = t.contains("\r\n")
        t = t.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        return LoadedDoc(text: t, kind: .plain(encoding, crlf: crlf))
    }

    static func write(_ text: String, to url: URL, doc: LoadedDoc) throws {
        switch doc.kind {
        case .readOnly(let what):
            throw DocError.unsupported("A \(what) file cannot be saved here.")
        case .plain(let enc, let crlf):
            let out = crlf ? text.replacingOccurrences(of: "\n", with: "\r\n") : text
            let data = out.data(using: enc) ?? Data(out.utf8)
            try data.write(to: url, options: .atomic)
        case .rich(let type):
            let font = NSFont(name: "Times New Roman", size: 12) ?? NSFont.systemFont(ofSize: 12)
            let para = NSMutableParagraphStyle()
            para.paragraphSpacing = 6
            let attr = NSAttributedString(string: text, attributes: [.font: font, .paragraphStyle: para])
            try writeAttributed(attr, to: url, type: type, meta: doc.meta)
        }
    }

    static func writeAttributed(_ attr: NSAttributedString, to url: URL, type: NSAttributedString.DocumentType,
                                meta: [NSAttributedString.DocumentAttributeKey: Any]) throws {
        var da: [NSAttributedString.DocumentAttributeKey: Any] = [.documentType: type]
        for key in [NSAttributedString.DocumentAttributeKey.title, .subject, .keywords, .company, .copyright] {
            if let v = meta[key] { da[key] = v }
        }
        da[.author] = meta[.author] ?? NSFullUserName()
        let range = NSRange(location: 0, length: attr.length)
        if type == .rtfd {
            let wrapper = try attr.fileWrapper(from: range, documentAttributes: da)
            try wrapper.write(to: url, options: .atomic, originalContentsURL: nil)
        } else {
            let data = try attr.data(from: range, documentAttributes: da)
            try data.write(to: url, options: .atomic)
        }
    }

    /// Loads a document with its formatting, for WORD.
    static func loadAttributed(_ url: URL) throws -> (NSAttributedString, LoadedDoc) {
        let ext = url.pathExtension.lowercased()
        if let type = richTypes[ext], ext != "webarchive" {
            var attrs: NSDictionary?
            let s = try NSAttributedString(url: url, options: [.documentType: type], documentAttributes: &attrs)
            let meta = attrs as? [NSAttributedString.DocumentAttributeKey: Any] ?? [:]
            return (s, LoadedDoc(text: s.string, kind: .rich(type), meta: meta))
        }
        let doc = try load(url)
        if case .readOnly(let what) = doc.kind {
            throw DocError.unsupported("A \(what) file can only be read. Use VIEW \(url.lastPathComponent).")
        }
        return (NSAttributedString(string: doc.text), doc)
    }

    /// Text suitable for TYPE, VIEW and SUMMARIZE.
    static func readableText(_ url: URL) throws -> TextPage {
        let ext = url.pathExtension.lowercased()
        if ext == "html" || ext == "htm" {
            let doc = try loadPlain(url)
            var page = HTMLText.extract(doc.text, base: url)
            if page.title.isEmpty { page.title = url.lastPathComponent }
            return page
        }
        let doc = try load(url)
        return TextPage(title: url.lastPathComponent, text: doc.text, links: [], url: url)
    }
}

enum Library {
    static func save(_ page: TextPage) throws -> URL {
        let bad = CharacterSet(charactersIn: "/\\:?*\"<>|\n\r\t")
        var name = page.title.components(separatedBy: bad).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        if name.isEmpty { name = "Untitled" }
        name = String(name.prefix(60)).trimmingCharacters(in: .whitespaces)
        let dir = Paths.library
        var url = dir.appendingPathComponent(name + ".txt")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(name) \(n).txt")
            n += 1
        }
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm"
        var body = page.title + "\n"
        if let u = page.url, !u.isFileURL { body += u.absoluteString + "\n" }
        body += "Saved " + df.string(from: Date()) + "\n\n" + page.plainText + "\n"
        if !page.links.isEmpty {
            body += "\nLinks\n"
            for (i, l) in page.links.enumerated() { body += "[\(i + 1)] \(l.absoluteString)\n" }
        }
        try body.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
