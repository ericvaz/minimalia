import Foundation
import PDFKit

/// A page of text. Headings are wrapped in \u{1}...\u{2}; link n is marked \u{3}n\u{4}.
struct TextPage {
    var title: String
    var text: String
    var links: [URL]
    var url: URL?

    var plainText: String {
        var out = ""
        var inLink = false
        var num = ""
        for ch in text {
            switch ch {
            case "\u{1}", "\u{2}": continue
            case "\u{3}": inLink = true; num = ""
            case "\u{4}": inLink = false; out += "[\(num)]"
            default: if inLink { num.append(ch) } else { out.append(ch) }
            }
        }
        return out
    }

    /// Text with no link numbers, for reading aloud or the model.
    var bareText: String {
        plainText.replacingOccurrences(of: #" ?\[\d+\]"#, with: "", options: .regularExpression)
    }
}

struct SearchResult {
    let title: String
    let url: URL
    let snippet: String
}

enum WebError: LocalizedError {
    case http(Int)
    case notFound
    case badAddress
    case empty

    var errorDescription: String? {
        switch self {
        case .http(let c): return "The server answered with error \(c)."
        case .notFound: return "Nothing found."
        case .badAddress: return "That address is not valid."
        case .empty: return "The page has no readable text. It may need JavaScript."
        }
    }
}

enum Web {
    static let browserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
    static let ownAgent = "Minimalia/1.0 (personal text-mode reader for macOS)"

    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 20
        c.httpAdditionalHeaders = ["Accept-Language": "en-CA,en;q=0.9"]
        return URLSession(configuration: c)
    }()

    static func get(_ url: URL) async throws -> (Data, HTTPURLResponse) {
        var req = URLRequest(url: url)
        let host = url.host ?? ""
        req.setValue(host.hasSuffix("wikipedia.org") ? ownAgent : browserAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,text/plain;q=0.8,*/*;q=0.5", forHTTPHeaderField: "Accept")
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw WebError.empty }
        return (data, http)
    }

    static func address(_ s: String) -> URL? {
        var t = s.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("\"") && t.hasSuffix("\"") && t.count > 1 { t = String(t.dropFirst().dropLast()) }
        guard !t.isEmpty, !t.contains(" ") else { return nil }
        if !t.lowercased().hasPrefix("http://") && !t.lowercased().hasPrefix("https://") { t = "https://" + t }
        guard let u = URL(string: t), u.host?.contains(".") == true else { return nil }
        return u
    }

    static func describe(_ error: Error) -> String {
        if let e = error as? URLError {
            switch e.code {
            case .notConnectedToInternet: return "No connection to the Internet."
            case .timedOut: return "The server took too long to answer."
            case .cannotFindHost: return "That address could not be found."
            default: return e.localizedDescription
            }
        }
        return error.localizedDescription
    }

    // MARK: Search

    static func search(_ q: String) async throws -> [SearchResult] {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#")
        let enc = q.addingPercentEncoding(withAllowedCharacters: allowed) ?? q
        if let r = try? await duckHTML(enc), !r.isEmpty { return r }
        try Task.checkCancellation()
        if let r = try? await duckLite(enc), !r.isEmpty { return r }
        try Task.checkCancellation()
        return try await wikiSearch(enc)
    }

    private static func strip(_ html: String) -> String {
        let noTags = html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        return HTMLText.decodeEntities(noTags)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    private static func matches(_ pattern: String, _ s: String) -> [NSTextCheckingResult] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        return re.matches(in: s, range: NSRange(location: 0, length: (s as NSString).length))
    }

    private static func group(_ m: NSTextCheckingResult, _ i: Int, _ s: String) -> String {
        let r = m.range(at: i)
        return r.location == NSNotFound ? "" : (s as NSString).substring(with: r)
    }

    private static func resultURL(_ raw: String) -> URL? {
        var href = HTMLText.decodeEntities(raw)
        if href.hasPrefix("//") { href = "https:" + href }
        guard let u = URL(string: href) else { return nil }
        if u.host?.contains("duckduckgo.com") == true {
            if u.path.hasPrefix("/y.js") { return nil }
            if let target = URLComponents(url: u, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "uddg" })?.value {
                return URL(string: target)
            }
            return nil
        }
        return u
    }

    private static func pair(_ html: String, titles: String, snippets: String) -> [SearchResult] {
        let ts = matches(titles, html)
        let ss = matches(snippets, html)
        var out: [SearchResult] = []
        for (i, m) in ts.enumerated() {
            let tag = group(m, 1, html)
            guard let href = HTMLText.attribute("href", in: tag), let url = resultURL(href) else { continue }
            let end = i + 1 < ts.count ? ts[i + 1].range.location : Int.max
            let snip = ss.first { $0.range.location > m.range.location && $0.range.location < end }
            let title = strip(group(m, 2, html))
            guard !title.isEmpty, !out.contains(where: { $0.url == url }) else { continue }
            out.append(SearchResult(title: title, url: url, snippet: snip.map { strip(group($0, 1, html)) } ?? ""))
        }
        return out
    }

    private static func duckHTML(_ q: String) async throws -> [SearchResult] {
        let (data, _) = try await get(URL(string: "https://html.duckduckgo.com/html/?q=\(q)")!)
        let html = String(decoding: data, as: UTF8.self)
        return pair(html,
                    titles: #"(<a[^>]*class="result__a"[^>]*>)([\s\S]*?)</a>"#,
                    snippets: #"class="result__snippet"[^>]*>([\s\S]*?)</(?:a|div|td)>"#)
    }

    private static func duckLite(_ q: String) async throws -> [SearchResult] {
        let (data, _) = try await get(URL(string: "https://lite.duckduckgo.com/lite/?q=\(q)")!)
        let html = String(decoding: data, as: UTF8.self)
        return pair(html,
                    titles: #"(<a[^>]*class=['"]result-link['"][^>]*>)([\s\S]*?)</a>"#,
                    snippets: #"class=['"]result-snippet['"][^>]*>([\s\S]*?)</td>"#)
    }

    private static func wikiSearch(_ q: String) async throws -> [SearchResult] {
        let u = URL(string: "https://en.wikipedia.org/w/api.php?action=opensearch&format=json&limit=10&namespace=0&search=\(q)")!
        let (data, _) = try await get(u)
        guard let arr = try JSONSerialization.jsonObject(with: data) as? [Any], arr.count > 3,
              let titles = arr[1] as? [String], let urls = arr[3] as? [String] else { throw WebError.notFound }
        return zip(titles, urls).compactMap { t, s in
            URL(string: s).map { SearchResult(title: t, url: $0, snippet: "Wikipedia") }
        }
    }

    // MARK: Pages

    static func wiki(_ topic: String) async throws -> TextPage {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#")
        let q = topic.addingPercentEncoding(withAllowedCharacters: allowed) ?? topic
        let u = URL(string: "https://en.wikipedia.org/w/api.php?action=opensearch&format=json&limit=1&namespace=0&search=\(q)")!
        let (data, _) = try await get(u)
        guard let arr = try JSONSerialization.jsonObject(with: data) as? [Any], arr.count > 1,
              let title = (arr[1] as? [String])?.first else { throw WebError.notFound }
        var pathAllowed = CharacterSet.urlPathAllowed
        pathAllowed.remove(charactersIn: "/?#")
        let path = title.replacingOccurrences(of: " ", with: "_").addingPercentEncoding(withAllowedCharacters: pathAllowed) ?? title
        guard let pageURL = URL(string: "https://en.wikipedia.org/api/rest_v1/page/html/\(path)") else { throw WebError.badAddress }
        var page = try await self.page(pageURL)
        page.title = title
        return page
    }

    static func page(_ url: URL) async throws -> TextPage {
        let (data, resp) = try await get(url)
        guard resp.statusCode < 400 else { throw WebError.http(resp.statusCode) }
        let finalURL = resp.url ?? url
        let mime = (resp.mimeType ?? "").lowercased()

        if mime.contains("pdf") {
            guard let pdf = PDFDocument(data: data), let s = pdf.string, !s.isEmpty else { throw WebError.empty }
            return TextPage(title: finalURL.lastPathComponent, text: s, links: [], url: finalURL)
        }
        let body = decode(data, resp)
        if mime.hasPrefix("text/plain") {
            return TextPage(title: finalURL.lastPathComponent, text: body, links: [], url: finalURL)
        }
        let head = body.prefix(1200).lowercased()
        if mime.contains("rss") || mime.contains("atom") || head.contains("<rss") || head.contains("<feed") || head.contains("<rdf:rdf") {
            if let feed = feed(data, url: finalURL) { return feed }
        }
        let page = HTMLText.extract(body, base: finalURL)
        if page.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw WebError.empty }
        return page
    }

    private static func decode(_ data: Data, _ resp: HTTPURLResponse) -> String {
        if let name = resp.textEncodingName {
            let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
            if cf != kCFStringEncodingInvalidId {
                let enc = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
                if let s = String(data: data, encoding: enc) { return s }
            }
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func feed(_ data: Data, url: URL) -> TextPage? {
        guard let doc = try? XMLDocument(data: data, options: []) else { return nil }
        func child(_ n: XMLNode, _ name: String) -> XMLNode? {
            (try? n.nodes(forXPath: "*[local-name()='\(name)']"))?.first
        }
        let feedTitle = (try? doc.nodes(forXPath: "//*[local-name()='channel']/*[local-name()='title'] | /*[local-name()='feed']/*[local-name()='title']"))?
            .first?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? (url.host ?? "Feed")
        var items = (try? doc.nodes(forXPath: "//*[local-name()='item']")) ?? []
        let isAtom = items.isEmpty
        if isAtom { items = (try? doc.nodes(forXPath: "//*[local-name()='entry']")) ?? [] }
        guard !items.isEmpty else { return nil }

        var text = "\u{1}\(feedTitle)\u{2}\n\n"
        var links: [URL] = []
        for item in items.prefix(60) {
            let title = child(item, "title")?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "(untitled)"
            var link: String?
            if isAtom {
                link = (child(item, "link") as? XMLElement)?.attribute(forName: "href")?.stringValue
            } else {
                link = child(item, "link")?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let date = (child(item, "pubDate") ?? child(item, "updated") ?? child(item, "published") ?? child(item, "date"))?
                .stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            text += HTMLText.decodeEntities(title)
            if let l = link, let u = URL(string: l, relativeTo: url)?.absoluteURL {
                links.append(u)
                text += " \u{3}\(links.count)\u{4}"
            }
            text += "\n"
            if let date, !date.isEmpty { text += "  \(date)\n" }
            text += "\n"
        }
        return TextPage(title: feedTitle, text: text, links: links, url: url)
    }
}

/// Turns HTML into calm plain text: no scripts, menus, ads or images.
enum HTMLText {
    static let skipTags: Set<String> = ["script", "style", "noscript", "svg", "nav", "footer", "aside", "button",
                                        "select", "iframe", "template", "canvas", "video", "audio", "object",
                                        "dialog", "head", "picture", "math"]
    static let rawTags: Set<String> = ["script", "style", "textarea", "title"]
    static let voidTags: Set<String> = ["br", "img", "hr", "meta", "link", "input", "source", "area", "base",
                                        "col", "embed", "param", "track", "wbr"]
    static let junkContainers: Set<String> = ["div", "section", "ul", "ol", "span", "sup", "table", "header",
                                              "figure", "details", "form", "p"]
    static let blockTags: Set<String> = ["div", "section", "article", "main", "table", "ul", "ol", "dl", "figure",
                                         "figcaption", "center", "address", "tr", "dd", "dt", "header", "form",
                                         "fieldset", "details", "summary", "caption"]

    private static let junkRegex = try! NSRegularExpression(pattern:
        "^(?:(?:site|global|main|page|top|bottom|primary|secondary|header|mobile|js|vector|mw)[-_])*" +
        "(?:nav|navbar|navigation|menu|footer|sidebar|cookie|cookies|consent|banner|share|sharing|social|" +
        "related|newsletter|subscribe|subscription|advert|advertisement|ad|ads|promo|breadcrumb|breadcrumbs|" +
        "popup|modal|comment|comments|infobox|navbox|vertical-navbox|metadata|mw-editsection|reference|" +
        "references|reflist|toc|noprint|ambox|skip-link|visually-hidden|sr-only|screen-reader-text|mw-ref|" +
        "toolbar|dropdown|interlanguage|languages|catlinks|printfooter|jump-link|indicators|sitenotice|" +
        "titlebar|hatnote|navigation-box|portlet)" +
        "(?:[-_][a-z0-9_-]*)?$")

    private static var attrRegexes: [String: NSRegularExpression] = [:]

    static func attribute(_ name: String, in tag: String) -> String? {
        let re: NSRegularExpression
        if let cached = attrRegexes[name] {
            re = cached
        } else {
            re = try! NSRegularExpression(pattern: "(?:^|\\s)" + name + "\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]+))",
                                          options: [.caseInsensitive])
            attrRegexes[name] = re
        }
        let ns = tag as NSString
        guard let m = re.firstMatch(in: tag, range: NSRange(location: 0, length: ns.length)) else { return nil }
        for i in 1...3 where m.range(at: i).location != NSNotFound {
            return ns.substring(with: m.range(at: i))
        }
        return nil
    }

    private static func isJunk(_ tag: String) -> Bool {
        let lower = tag.lowercased()
        if lower.contains("aria-hidden=\"true\"") { return true }
        if lower.range(of: #"\shidden(\s|$|=|/)"#, options: .regularExpression) != nil { return true }
        if let role = attribute("role", in: tag)?.lowercased(),
           ["navigation", "banner", "contentinfo", "complementary", "search", "dialog", "menu", "menubar"].contains(role) {
            return true
        }
        let tokens = ((attribute("class", in: tag) ?? "") + " " + (attribute("id", in: tag) ?? "")).lowercased()
            .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
        return tokens.contains { t in
            let s = String(t)
            return junkRegex.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil
        }
    }

    static func extract(_ html: String, base: URL) -> TextPage {
        var title = ""
        if let r = html.range(of: #"<title[^>]*>([\s\S]*?)</title>"#, options: [.regularExpression, .caseInsensitive]) {
            title = String(html[r])
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            title = decodeEntities(title).replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
        }
        let body = slice(html, open: "<body", close: nil) ?? html
        let focused = slice(html, open: "<main", close: "</main>") ?? slice(html, open: "<article", close: "</article>")

        var result = run(focused ?? body, base: base, junk: true, skipHeader: focused == nil)
        if result.text.count < 400 {
            let wide = run(body, base: base, junk: false, skipHeader: false)
            if wide.text.count > result.text.count { result = wide }
        }
        if title.isEmpty { title = base.host ?? base.lastPathComponent }
        return TextPage(title: title, text: result.text, links: result.links, url: base)
    }

    private static func slice(_ html: String, open: String, close: String?) -> String? {
        var searchFrom = html.startIndex
        var start: String.Index?
        while let r = html.range(of: open, options: .caseInsensitive, range: searchFrom..<html.endIndex) {
            if r.upperBound < html.endIndex {
                let next = html[r.upperBound]
                if next == ">" || next == " " || next == "\n" || next == "\t" || next == "\r" { start = r.lowerBound; break }
            }
            searchFrom = r.upperBound
        }
        guard let s = start else { return nil }
        guard let close else { return String(html[s...]) }
        guard let e = html.range(of: close, options: [.caseInsensitive, .backwards]), e.upperBound > s else { return nil }
        return String(html[s..<e.upperBound])
    }

    private struct Builder {
        var out = ""
        var links: [URL] = []
        var trailingNL = 0
        var atLineStart = true
        var lastSpace = false
        var visible = 0

        mutating func text(_ raw: String, pre: Bool) {
            if pre {
                guard !raw.isEmpty else { return }
                out += raw
                visible += raw.count
                trailingNL = raw.hasSuffix("\n") ? 1 : 0
                atLineStart = raw.hasSuffix("\n")
                lastSpace = false
                return
            }
            var pending = false
            for ch in raw {
                if ch.isWhitespace {
                    pending = true
                    continue
                }
                if pending && !atLineStart && !lastSpace { out.append(" ") }
                pending = false
                out.append(ch)
                visible += 1
                atLineStart = false
                lastSpace = false
                trailingNL = 0
            }
            if pending && !atLineStart && !lastSpace {
                out.append(" ")
                lastSpace = true
            }
        }

        mutating func raw(_ s: String) {
            out += s
            atLineStart = false
            lastSpace = false
            trailingNL = 0
        }

        mutating func newline(_ n: Int) {
            guard !out.isEmpty else { return }
            if lastSpace, out.last == " " { out.removeLast(); lastSpace = false }
            while trailingNL < n {
                out.append("\n")
                trailingNL += 1
            }
            atLineStart = true
        }
    }

    private static func run(_ html: String, base: URL, junk: Bool, skipHeader: Bool) -> (text: String, links: [URL]) {
        let b = Array(html.utf8)
        let n = b.count
        var bd = Builder()
        var skipTag: String?
        var skipDepth = 0
        var pre = 0
        var href: URL?
        var anchorVisible = 0
        var lists: [Int] = []
        var i = 0
        var textStart = 0

        func flush(_ end: Int) {
            guard skipTag == nil, end > textStart else { return }
            let s = String(decoding: b[textStart..<end], as: UTF8.self)
            bd.text(decodeEntities(s), pre: pre > 0)
        }

        func find(_ pattern: String, from: Int) -> Int? {
            let p = Array(pattern.utf8)
            var k = from
            while k + p.count <= n {
                var ok = true
                for j in 0..<p.count {
                    var c = b[k + j]
                    if c >= 65 && c <= 90 { c += 32 }
                    if c != p[j] { ok = false; break }
                }
                if ok { return k }
                k += 1
            }
            return nil
        }

        while i < n {
            guard b[i] == 60, i + 1 < n else { i += 1; continue }
            let c1 = b[i + 1]
            let isLetter = (c1 >= 65 && c1 <= 90) || (c1 >= 97 && c1 <= 122)
            guard isLetter || c1 == 47 || c1 == 33 else { i += 1; continue }
            flush(i)

            if c1 == 33 {
                if i + 3 < n, b[i + 2] == 45, b[i + 3] == 45 {
                    i = (find("-->", from: i + 4).map { $0 + 3 }) ?? n
                } else {
                    var j = i
                    while j < n && b[j] != 62 { j += 1 }
                    i = j + 1
                }
                textStart = i
                continue
            }

            var j = i + 1
            var quote: UInt8 = 0
            while j < n {
                let c = b[j]
                if quote != 0 {
                    if c == quote { quote = 0 }
                } else if c == 34 || c == 39 {
                    quote = c
                } else if c == 62 {
                    break
                }
                j += 1
                if j - i > 8000 && quote != 0 { quote = 0 }
            }
            let tag = String(decoding: b[(i + 1)..<min(j, n)], as: UTF8.self)
            i = min(j + 1, n)
            textStart = i

            let closing = tag.hasPrefix("/")
            let body = closing ? String(tag.dropFirst()) : tag
            let name = String(body.prefix { $0.isLetter || $0.isNumber }).lowercased()
            let selfClosing = tag.hasSuffix("/") || voidTags.contains(name)
            if name.isEmpty { continue }

            if !closing && rawTags.contains(name) {
                if let e = find("</" + name, from: i) {
                    var k = e
                    while k < n && b[k] != 62 { k += 1 }
                    if name == "textarea", skipTag == nil {
                        bd.text(decodeEntities(String(decoding: b[i..<e], as: UTF8.self)), pre: false)
                    }
                    i = min(k + 1, n)
                } else {
                    i = n
                }
                textStart = i
                continue
            }

            if let s = skipTag {
                if name == s && !selfClosing {
                    skipDepth += closing ? -1 : 1
                    if skipDepth == 0 { skipTag = nil }
                }
                continue
            }

            if !closing && !selfClosing {
                let skip = skipTags.contains(name)
                    || (skipHeader && name == "header")
                    || (junk && junkContainers.contains(name) && isJunk(body))
                if skip {
                    skipTag = name
                    skipDepth = 1
                    continue
                }
            }

            switch name {
            case "br":
                bd.newline(1)
                bd.trailingNL = 0
            case "p", "blockquote":
                bd.newline(2)
            case "h1", "h2", "h3", "h4", "h5", "h6":
                if closing {
                    bd.raw("\u{2}")
                    bd.newline(2)
                } else {
                    bd.newline(2)
                    bd.raw("\u{1}")
                }
            case "pre":
                bd.newline(2)
                pre = max(0, pre + (closing ? -1 : 1))
            case "hr":
                bd.newline(2)
                bd.raw("----")
                bd.newline(2)
            case "ul":
                bd.newline(1)
                if closing { _ = lists.popLast() } else { lists.append(-1) }
            case "ol":
                bd.newline(1)
                if closing { _ = lists.popLast() } else { lists.append(0) }
            case "li":
                bd.newline(1)
                if !closing {
                    let indent = String(repeating: "  ", count: max(1, lists.count))
                    if var last = lists.last, last >= 0 {
                        last += 1
                        lists[lists.count - 1] = last
                        bd.raw("\(indent)\(last). ")
                    } else {
                        bd.raw("\(indent)- ")
                    }
                    bd.atLineStart = true
                }
            case "td", "th":
                if !closing && !bd.atLineStart { bd.raw("   ") }
            case "a":
                if closing {
                    if let h = href, bd.visible > anchorVisible {
                        bd.links.append(h)
                        if bd.out.last == " " { bd.out.removeLast() }
                        bd.raw(" \u{3}\(bd.links.count)\u{4}")
                    }
                    href = nil
                } else if let raw = attribute("href", in: body) {
                    let h = decodeEntities(raw).trimmingCharacters(in: .whitespaces)
                    href = nil
                    if !h.hasPrefix("#"), !h.lowercased().hasPrefix("javascript:"), !h.lowercased().hasPrefix("mailto:"),
                       let u = URL(string: h, relativeTo: base)?.absoluteURL,
                       u.scheme == "http" || u.scheme == "https" {
                        href = u
                    }
                    anchorVisible = bd.visible
                }
            default:
                if blockTags.contains(name) { bd.newline(1) }
            }
        }
        flush(n)

        var text = bd.out.replacingOccurrences(of: "\u{1}\u{2}", with: "")
        text = text.components(separatedBy: "\n")
            .map { line -> String in
                var l = line
                while l.last == " " || l.last == "\t" { l.removeLast() }
                return l
            }
            .joined(separator: "\n")
        text = text.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (text, bd.links)
    }

    static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "ensp": " ", "emsp": " ",
        "thinsp": " ", "mdash": "\u{2014}", "ndash": "\u{2013}", "hellip": "\u{2026}", "lsquo": "\u{2018}",
        "rsquo": "\u{2019}", "ldquo": "\u{201C}", "rdquo": "\u{201D}", "laquo": "\u{00AB}", "raquo": "\u{00BB}",
        "copy": "\u{00A9}", "reg": "\u{00AE}", "trade": "\u{2122}", "deg": "\u{00B0}", "middot": "\u{00B7}",
        "bull": "\u{2022}", "times": "\u{00D7}", "divide": "\u{00F7}", "eacute": "\u{00E9}", "egrave": "\u{00E8}",
        "ecirc": "\u{00EA}", "aacute": "\u{00E1}", "agrave": "\u{00E0}", "acirc": "\u{00E2}", "atilde": "\u{00E3}",
        "oacute": "\u{00F3}", "ocirc": "\u{00F4}", "otilde": "\u{00F5}", "uacute": "\u{00FA}", "iacute": "\u{00ED}",
        "ccedil": "\u{00E7}", "ntilde": "\u{00F1}", "ouml": "\u{00F6}", "uuml": "\u{00FC}", "auml": "\u{00E4}",
        "szlig": "\u{00DF}", "euro": "\u{20AC}", "pound": "\u{00A3}", "yen": "\u{00A5}", "cent": "\u{00A2}",
        "sect": "\u{00A7}", "para": "\u{00B6}", "shy": "", "zwj": "", "zwnj": "", "lrm": "", "rlm": "",
        "minus": "\u{2212}", "frac12": "\u{00BD}", "frac14": "\u{00BC}", "frac34": "\u{00BE}", "prime": "\u{2032}",
        "Eacute": "\u{00C9}", "Agrave": "\u{00C0}", "Ccedil": "\u{00C7}", "iexcl": "\u{00A1}", "iquest": "\u{00BF}",
    ]

    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = ""
        out.reserveCapacity(s.utf8.count)
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if c == "&", let semi = s[i...].prefix(12).firstIndex(of: ";") {
                let name = String(s[s.index(after: i)..<semi])
                if let r = entity(name) {
                    out += r
                    i = s.index(after: semi)
                    continue
                }
            }
            out.append(c)
            i = s.index(after: i)
        }
        return out
    }

    private static func entity(_ n: String) -> String? {
        if n.hasPrefix("#x") || n.hasPrefix("#X") {
            return UInt32(n.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
        }
        if n.hasPrefix("#") {
            return UInt32(n.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
        }
        return named[n] ?? named[n.lowercased()]
    }
}
