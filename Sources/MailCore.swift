import Foundation
import Security

// MARK: Account

/// One mail account. The password lives in the Keychain, never here.
struct MailAccount: Codable {
    var name: String
    var email: String
    var imapHost: String
    var imapPort: Int
    var smtpHost: String
    var smtpPort: Int

    /// Server settings for the common providers, worked out from the address.
    static func preset(name: String, email: String) -> MailAccount {
        let domain = email.split(separator: "@").last.map { $0.lowercased() } ?? ""
        switch domain {
        case "gmail.com", "googlemail.com":
            return MailAccount(name: name, email: email, imapHost: "imap.gmail.com", imapPort: 993, smtpHost: "smtp.gmail.com", smtpPort: 465)
        case "icloud.com", "me.com", "mac.com":
            return MailAccount(name: name, email: email, imapHost: "imap.mail.me.com", imapPort: 993, smtpHost: "smtp.mail.me.com", smtpPort: 587)
        case "outlook.com", "hotmail.com", "live.com", "msn.com":
            return MailAccount(name: name, email: email, imapHost: "outlook.office365.com", imapPort: 993, smtpHost: "smtp-mail.outlook.com", smtpPort: 587)
        case "yahoo.com", "yahoo.ca":
            return MailAccount(name: name, email: email, imapHost: "imap.mail.yahoo.com", imapPort: 993, smtpHost: "smtp.mail.yahoo.com", smtpPort: 465)
        case "fastmail.com", "fastmail.fm":
            return MailAccount(name: name, email: email, imapHost: "imap.fastmail.com", imapPort: 993, smtpHost: "smtp.fastmail.com", smtpPort: 465)
        default:
            return MailAccount(name: name, email: email, imapHost: "imap.\(domain)", imapPort: 993, smtpHost: "smtp.\(domain)", smtpPort: 465)
        }
    }

    static var saved: MailAccount? {
        get {
            guard let d = UserDefaults.standard.data(forKey: "mailAccount") else { return nil }
            return try? JSONDecoder().decode(MailAccount.self, from: d)
        }
        set {
            if let v = newValue, let d = try? JSONEncoder().encode(v) {
                UserDefaults.standard.set(d, forKey: "mailAccount")
            } else {
                UserDefaults.standard.removeObject(forKey: "mailAccount")
            }
        }
    }

    var isGmail: Bool { imapHost == "imap.gmail.com" }
}

/// The account password, kept in the macOS Keychain.
enum MailKeychain {
    private static let service = "Minimalia Letters"

    static func set(_ password: String, for account: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(password.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ account: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func remove(_ account: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
    }
}

// MARK: Messages

struct MailAddress: Hashable {
    var name: String
    var email: String
    var display: String { name.isEmpty ? email : name }
    var full: String { name.isEmpty ? email : "\(name) <\(email)>" }

    /// "Ada Lovelace <ada@example.com>, bob@example.com" into addresses.
    static func parseList(_ s: String) -> [MailAddress] {
        s.split(separator: ",").compactMap { part in
            let t = part.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { return nil }
            if let lt = t.lastIndex(of: "<"), let gt = t.lastIndex(of: ">"), lt < gt {
                let name = t[..<lt].trimmingCharacters(in: CharacterSet(charactersIn: " \""))
                return MailAddress(name: name, email: String(t[t.index(after: lt)..<gt]))
            }
            return MailAddress(name: "", email: t)
        }
    }
}

struct MailMessage {
    let uid: Int
    var from: MailAddress
    var to: [MailAddress]
    var cc: [MailAddress]
    var replyTo: [MailAddress]
    var subject: String
    var date: Date
    var seen: Bool
    var flagged: Bool
    var messageID: String
    var references: String
    var preview: String
    var body: String?
    var attachments: [String] = []
}

enum MailError: LocalizedError {
    case closed
    case server(String)
    case timeout

    var errorDescription: String? {
        switch self {
        case .closed: return "The mail server closed the connection."
        case .server(let s): return s
        case .timeout: return "The mail server took too long to answer."
        }
    }
}

// MARK: Connection

/// A line-and-literal connection to a mail server, over TLS from the start or upgraded with STARTTLS.
final class MailConnection: @unchecked Sendable {
    private let task: URLSessionStreamTask
    private var buffer = Data()

    init(host: String, port: Int, tls: Bool) {
        task = URLSession.shared.streamTask(withHostName: host, port: port)
        if tls { task.startSecureConnection() }
        task.resume()
    }

    func startTLS() { task.startSecureConnection() }

    func send(_ s: String) async throws {
        try await task.write(Data(s.utf8), timeout: 60)
    }

    func sendData(_ d: Data) async throws {
        try await task.write(d, timeout: 120)
    }

    private func fill() async throws {
        let (data, eof) = try await task.readData(ofMinLength: 1, maxLength: 1 << 16, timeout: 60)
        if let data, !data.isEmpty {
            buffer.append(data)
        } else if eof {
            throw MailError.closed
        }
    }

    /// One line, without its CRLF.
    func readLine() async throws -> Data {
        while true {
            if let r = buffer.firstRange(of: Data([13, 10])) {
                let line = buffer[buffer.startIndex..<r.lowerBound]
                buffer.removeSubrange(buffer.startIndex..<r.upperBound)
                return Data(line)
            }
            try await fill()
        }
    }

    func read(count: Int) async throws -> Data {
        while buffer.count < count { try await fill() }
        let out = buffer.prefix(count)
        buffer.removeFirst(count)
        return Data(out)
    }

    func close() { task.cancel() }
}

// MARK: IMAP

/// A value in an IMAP response.
indirect enum IMAPValue {
    case atom(String)
    case string(Data)
    case list([IMAPValue])
    case none

    var text: String? {
        switch self {
        case .atom(let s): return s
        case .string(let d): return String(data: d, encoding: .utf8) ?? String(decoding: d, as: UTF8.self)
        default: return nil
        }
    }

    var data: Data? {
        switch self {
        case .string(let d): return d
        case .atom(let s): return Data(s.utf8)
        default: return nil
        }
    }

    var items: [IMAPValue] { if case .list(let l) = self { return l } else { return [] } }
}

final class IMAPClient: @unchecked Sendable {
    private let conn: MailConnection
    private var tag = 0
    private(set) var capabilities: Set<String> = []

    private init(_ conn: MailConnection) { self.conn = conn }

    static func connect(_ account: MailAccount, credential: MailCredential) async throws -> IMAPClient {
        let c = IMAPClient(MailConnection(host: account.imapHost, port: account.imapPort, tls: true))
        _ = try await c.readResponse()
        switch credential {
        case .password(let password):
            _ = try await c.command("LOGIN \(quote(account.email)) \(quote(password))")
        case .google(let refresh):
            let token = try await GoogleSignIn.accessToken(refresh: refresh)
            _ = try await c.command("AUTHENTICATE XOAUTH2 \(MailCredential.xoauth2(email: account.email, token: token))")
        }
        let caps = try await c.command("CAPABILITY")
        for r in caps where r.first?.text?.uppercased() == "CAPABILITY" {
            c.capabilities = Set(r.dropFirst().compactMap { $0.text?.uppercased() })
        }
        return c
    }

    static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Reads one response, joining any literals into it.
    private func readResponse() async throws -> [IMAPValue] {
        var segments: [(Data, Data?)] = []
        while true {
            let line = try await conn.readLine()
            if let open = line.lastIndex(of: UInt8(ascii: "{")), line.last == UInt8(ascii: "}"),
               let n = Int(String(decoding: line[(open + 1)..<(line.endIndex - 1)], as: UTF8.self).replacingOccurrences(of: "+", with: "")) {
                let literal = try await conn.read(count: n)
                segments.append((Data(line[..<open]), literal))
            } else {
                segments.append((line, nil))
                break
            }
        }
        var p = IMAPParser(segments: segments)
        return p.parseAll()
    }

    /// Sends a command and returns its untagged responses; throws if the server says NO or BAD.
    @discardableResult
    func command(_ cmd: String) async throws -> [[IMAPValue]] {
        tag += 1
        let t = "M\(tag)"
        try await conn.send("\(t) \(cmd)\r\n")
        var untagged: [[IMAPValue]] = []
        while true {
            let r = try await readResponse()
            guard let first = r.first?.text else { continue }
            if first == "+" {
                // The server wants more; for a failed sign-in it sends an explanation and waits.
                try await conn.send("\r\n")
                continue
            }
            if first == "*" {
                untagged.append(Array(r.dropFirst()))
            } else if first == t {
                let status = r.dropFirst().first?.text?.uppercased() ?? ""
                if status != "OK" {
                    let msg = r.dropFirst(2).compactMap(\.text).joined(separator: " ")
                    throw MailError.server(msg.isEmpty ? "The mail server refused: \(cmd.split(separator: " ").first ?? "")" : msg)
                }
                return untagged
            }
        }
    }

    /// Mailboxes by role: inbox, sent, flagged, all, archive.
    func specialMailboxes() async throws -> [String: String] {
        var out = ["inbox": "INBOX"]
        for r in try await command("LIST \"\" \"*\"") where r.first?.text?.uppercased() == "LIST" {
            let attrs = r.dropFirst().first?.items.compactMap { $0.text?.lowercased() } ?? []
            guard let name = r.last?.text else { continue }
            for (attr, role) in [("\\sent", "sent"), ("\\flagged", "flagged"), ("\\all", "all"), ("\\archive", "archive")] where attrs.contains(attr) {
                out[role] = name
            }
        }
        return out
    }

    /// The newest messages in a mailbox, without their bodies but with a short preview.
    func recent(_ mailbox: String, count: Int = 60) async throws -> [MailMessage] {
        var exists = 0
        for r in try await command("SELECT \(Self.quote(mailbox))") where r.count >= 2 && r[1].text?.uppercased() == "EXISTS" {
            exists = Int(r[0].text ?? "") ?? 0
        }
        guard exists > 0 else { return [] }
        let lo = max(1, exists - count + 1)
        let fields = "BODY.PEEK[HEADER.FIELDS (REFERENCES CONTENT-TYPE CONTENT-TRANSFER-ENCODING)]"
        let resp = try await command("FETCH \(lo):\(exists) (UID FLAGS ENVELOPE \(fields) BODY.PEEK[TEXT]<0.3000>)")
        var out: [MailMessage] = []
        for r in resp where r.count >= 3 && r[1].text?.uppercased() == "FETCH" {
            if let m = Self.message(from: r[2].items) { out.append(m) }
        }
        return out.sorted { $0.date > $1.date }
    }

    private static func message(from kv: [IMAPValue]) -> MailMessage? {
        var uid = 0
        var flags: [String] = []
        var env: [IMAPValue] = []
        var header = Data()
        var text = Data()
        var i = 0
        while i + 1 < kv.count {
            let key = kv[i].text?.uppercased() ?? ""
            let v = kv[i + 1]
            if key == "UID" { uid = Int(v.text ?? "") ?? 0 }
            else if key == "FLAGS" { flags = v.items.compactMap { $0.text?.lowercased() } }
            else if key == "ENVELOPE" { env = v.items }
            else if key.hasPrefix("BODY[HEADER") { header = v.data ?? Data() }
            else if key.hasPrefix("BODY[TEXT]") { text = v.data ?? Data() }
            i += 2
        }
        guard uid > 0, env.count >= 10 else { return nil }
        func addrs(_ v: IMAPValue) -> [MailAddress] {
            v.items.map { a in
                let f = a.items
                let name = MIME.decodeWords(f[safe: 0]?.text ?? "")
                let user = f[safe: 2]?.text ?? ""
                let host = f[safe: 3]?.text ?? ""
                return MailAddress(name: name, email: host.isEmpty ? user : "\(user)@\(host)")
            }
        }
        let headers = MIME.headers(header)
        let preview = MIME.preview(headers: headers, body: text)
        return MailMessage(
            uid: uid,
            from: addrs(env[2]).first ?? MailAddress(name: "", email: ""),
            to: addrs(env[5]), cc: addrs(env[6]), replyTo: addrs(env[4]),
            subject: MIME.decodeWords(env[1].text ?? ""),
            date: MIME.date(env[0].text ?? "") ?? .distantPast,
            seen: flags.contains("\\seen"), flagged: flags.contains("\\flagged"),
            messageID: env[9].text ?? "", references: headers["references"] ?? "",
            preview: preview)
    }

    /// The whole message, decoded to readable text. Marks it as read.
    func body(uid: Int) async throws -> (String, [String]) {
        let resp = try await command("UID FETCH \(uid) (BODY.PEEK[])")
        for r in resp where r.count >= 3 && r[1].text?.uppercased() == "FETCH" {
            let kv = r[2].items
            var i = 0
            while i + 1 < kv.count {
                if kv[i].text?.uppercased().hasPrefix("BODY[") == true, let d = kv[i + 1].data {
                    try? await command("UID STORE \(uid) +FLAGS.SILENT (\\Seen)")
                    return MIME.readable(d)
                }
                i += 2
            }
        }
        return ("", [])
    }

    func setFlag(uid: Int, _ flag: String, on: Bool) async throws {
        try await command("UID STORE \(uid) \(on ? "+" : "-")FLAGS.SILENT (\(flag))")
    }

    /// Takes a message out of the inbox, keeping it in the archive (All Mail on Gmail).
    func archive(uid: Int, to mailbox: String) async throws {
        if capabilities.contains("MOVE") {
            try await command("UID MOVE \(uid) \(Self.quote(mailbox))")
        } else {
            try await command("UID COPY \(uid) \(Self.quote(mailbox))")
            try await command("UID STORE \(uid) +FLAGS.SILENT (\\Deleted)")
            try await command("EXPUNGE")
        }
    }

    func logout() async {
        _ = try? await command("LOGOUT")
        conn.close()
    }
}

/// Parses an IMAP response, made of text segments and literals, into values.
struct IMAPParser {
    private var bytes: [UInt8] = []
    private var literals: [Int: Data] = [:]
    private var i = 0

    init(segments: [(Data, Data?)]) {
        for (text, lit) in segments {
            bytes += text
            if let lit {
                literals[bytes.count] = lit
                bytes.append(0)
            }
        }
    }

    mutating func parseAll() -> [IMAPValue] {
        var out: [IMAPValue] = []
        while let v = next() { out.append(v) }
        return out
    }

    private mutating func next() -> IMAPValue? {
        while i < bytes.count && bytes[i] == 32 { i += 1 }
        guard i < bytes.count else { return nil }
        if let lit = literals[i] { i += 1; return .string(lit) }
        let c = bytes[i]
        if c == 40 {
            i += 1
            var items: [IMAPValue] = []
            while true {
                while i < bytes.count && bytes[i] == 32 { i += 1 }
                if i >= bytes.count { break }
                if bytes[i] == 41 { i += 1; break }
                guard let v = next() else { break }
                items.append(v)
            }
            return .list(items)
        }
        if c == 41 { i += 1; return next() }
        if c == 34 {
            i += 1
            var s: [UInt8] = []
            while i < bytes.count && bytes[i] != 34 {
                if bytes[i] == 92 && i + 1 < bytes.count { i += 1 }
                s.append(bytes[i])
                i += 1
            }
            i += 1
            return .string(Data(s))
        }
        var s: [UInt8] = []
        var depth = 0
        while i < bytes.count {
            let b = bytes[i]
            if depth == 0 && (b == 32 || b == 40 || b == 41) { break }
            if b == 91 { depth += 1 }
            if b == 93 { depth = max(0, depth - 1) }
            s.append(b)
            i += 1
        }
        let atom = String(decoding: s, as: UTF8.self)
        return atom.uppercased() == "NIL" ? IMAPValue.none : .atom(atom)
    }
}

// MARK: MIME

enum MIME {
    /// Header fields, unfolded, with lower-case names.
    static func headers(_ d: Data) -> [String: String] {
        let s = String(data: d, encoding: .utf8) ?? String(data: d, encoding: .isoLatin1) ?? ""
        var out: [String: String] = [:]
        var last: String?
        for raw in s.components(separatedBy: "\n") {
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            if line.isEmpty { break }
            if line.first == " " || line.first == "\t", let k = last {
                out[k, default: ""] += " " + line.trimmingCharacters(in: .whitespaces)
            } else if let colon = line.firstIndex(of: ":") {
                let k = line[..<colon].lowercased()
                out[k] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                last = k
            }
        }
        return out
    }

    /// Splits raw message bytes at the blank line between header and body.
    static func split(_ d: Data) -> (Data, Data) {
        if let r = d.firstRange(of: Data([13, 10, 13, 10])) { return (d[..<r.lowerBound], d[r.upperBound...]) }
        if let r = d.firstRange(of: Data([10, 10])) { return (d[..<r.lowerBound], d[r.upperBound...]) }
        return (d, Data())
    }

    /// "text/plain; charset=utf-8" into ("text/plain", ["charset": "utf-8"]).
    static func params(_ value: String?) -> (String, [String: String]) {
        guard let value else { return ("text/plain", [:]) }
        let parts = value.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        var p: [String: String] = [:]
        for part in parts.dropFirst() {
            guard let eq = part.firstIndex(of: "=") else { continue }
            p[part[..<eq].lowercased().trimmingCharacters(in: .whitespaces)] =
                part[part.index(after: eq)...].trimmingCharacters(in: CharacterSet(charactersIn: " \""))
        }
        return ((parts.first ?? "text/plain").lowercased(), p)
    }

    static func transferDecode(_ d: Data, _ encoding: String?) -> Data {
        switch (encoding ?? "").lowercased() {
        case "base64":
            let clean = String(decoding: d, as: UTF8.self).components(separatedBy: .whitespacesAndNewlines).joined()
            let usable = String(clean.prefix(clean.count / 4 * 4))
            return Data(base64Encoded: usable) ?? Data()
        case "quoted-printable":
            var out = Data()
            let b = [UInt8](d)
            var i = 0
            while i < b.count {
                if b[i] == 61 {
                    if i + 2 < b.count, let v = UInt8(String(decoding: b[(i + 1)...(i + 2)], as: UTF8.self), radix: 16) {
                        out.append(v); i += 3; continue
                    }
                    // A soft line break.
                    var j = i + 1
                    if j < b.count && b[j] == 13 { j += 1 }
                    if j < b.count && b[j] == 10 { i = j + 1; continue }
                }
                out.append(b[i])
                i += 1
            }
            return out
        default:
            return d
        }
    }

    static func decodeText(_ d: Data, charset: String?) -> String {
        if let cs = charset {
            let cf = CFStringConvertIANACharSetNameToEncoding(cs as CFString)
            if cf != kCFStringEncodingInvalidId,
               let s = String(data: d, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))) {
                return s
            }
        }
        return String(data: d, encoding: .utf8) ?? String(data: d, encoding: .windowsCP1252) ?? String(decoding: d, as: UTF8.self)
    }

    /// "=?UTF-8?B?...?=" encoded words in headers.
    static func decodeWords(_ s: String) -> String {
        guard s.contains("=?") else { return s }
        let re = try! NSRegularExpression(pattern: "=\\?([^?]+)\\?([BbQq])\\?([^?]*)\\?=(\\s+(?==\\?))?")
        let ns = s as NSString
        var out = ""
        var last = 0
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let charset = ns.substring(with: m.range(at: 1))
            let kind = ns.substring(with: m.range(at: 2)).uppercased()
            let text = ns.substring(with: m.range(at: 3))
            let data = kind == "B"
                ? (Data(base64Encoded: text) ?? Data())
                : transferDecode(Data(text.replacingOccurrences(of: "_", with: " ").utf8), "quoted-printable")
            out += decodeText(data, charset: charset)
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }

    static func date(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        let cleaned = s.replacingOccurrences(of: "\\s*\\([^)]*\\)\\s*$", with: "", options: .regularExpression)
        for fmt in ["EEE, d MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm Z", "EEE, d MMM yy HH:mm:ss Z"] {
            f.dateFormat = fmt
            if let d = f.date(from: cleaned) { return d }
        }
        return nil
    }

    /// Readable text and attachment names from a whole message.
    static func readable(_ raw: Data) -> (String, [String]) {
        let (h, b) = split(raw)
        var attachments: [String] = []
        let text = partText(headers: headers(h), body: b, attachments: &attachments)
        return (tidy(text), attachments)
    }

    private static func partText(headers h: [String: String], body: Data, attachments: inout [String]) -> String {
        let (type, p) = params(h["content-type"])
        let disposition = params(h["content-disposition"])
        if disposition.0 == "attachment" || (!type.hasPrefix("text/") && !type.hasPrefix("multipart/")) {
            let name = disposition.1["filename"] ?? p["name"]
            if let name { attachments.append(decodeWords(name)) }
            return ""
        }
        if type.hasPrefix("multipart/"), let boundary = p["boundary"] {
            let parts = multipart(body, boundary: boundary)
            if type == "multipart/alternative" {
                let plain = parts.first { params(MIME.headers($0.0)["content-type"]).0 == "text/plain" }
                let pick = plain ?? parts.last
                if let pick { return partText(headers: MIME.headers(pick.0), body: pick.1, attachments: &attachments) }
                return ""
            }
            return parts.map { partText(headers: MIME.headers($0.0), body: $0.1, attachments: &attachments) }
                .filter { !$0.isEmpty }.joined(separator: "\n\n")
        }
        let decoded = decodeText(transferDecode(body, h["content-transfer-encoding"]), charset: p["charset"])
        if type == "text/html" {
            return HTMLText.extract(decoded, base: URL(string: "about:blank")!).plainText
        }
        return decoded
    }

    /// The parts of a multipart body, each as (header, body).
    static func multipart(_ body: Data, boundary: String) -> [(Data, Data)] {
        let latin = String(data: body, encoding: .isoLatin1) ?? ""
        let pieces = latin.components(separatedBy: "--" + boundary)
        return pieces.dropFirst().compactMap { piece in
            if piece.hasPrefix("--") { return nil }
            let trimmed = piece.hasPrefix("\r\n") ? String(piece.dropFirst(2)) : (piece.hasPrefix("\n") ? String(piece.dropFirst()) : piece)
            guard let d = trimmed.data(using: .isoLatin1) else { return nil }
            let (h, b) = split(d)
            return (h, b)
        }
    }

    /// A one-line taste of the message, from its first few kilobytes.
    static func preview(headers h: [String: String], body: Data) -> String {
        var attachments: [String] = []
        let text = partText(headers: h, body: body, attachments: &attachments)
        let flat = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\[\\d+\\]", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return String(flat.prefix(180))
    }

    private static func tidy(_ s: String) -> String {
        s.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "[ \\t]+\n", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Writing

    static func encodeWord(_ s: String) -> String {
        s.allSatisfy { $0.isASCII } ? s : "=?UTF-8?B?\(Data(s.utf8).base64EncodedString())?="
    }

    static func encodeAddress(_ a: MailAddress) -> String {
        a.name.isEmpty ? a.email : "\(encodeWord(a.name)) <\(a.email)>"
    }

    static func quotedPrintable(_ s: String) -> String {
        var out = ""
        for line in s.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            var current = ""
            for byte in Array(line.utf8) {
                let piece: String
                if (byte >= 33 && byte <= 126 && byte != 61) || byte == 32 {
                    piece = String(UnicodeScalar(byte))
                } else {
                    piece = String(format: "=%02X", byte)
                }
                if current.count + piece.count > 75 {
                    out += current + "=\r\n"
                    current = ""
                }
                current += piece
            }
            if current.hasSuffix(" ") { current = String(current.dropLast()) + "=20" }
            out += current + "\r\n"
        }
        return out
    }
}

// MARK: SMTP

enum SMTP {
    struct Outgoing {
        var to: [MailAddress]
        var cc: [MailAddress]
        var subject: String
        var body: String
        var inReplyTo: String?
        var references: String?
    }

    private static func reply(_ c: MailConnection) async throws -> (Int, String) {
        var lines: [String] = []
        while true {
            let line = String(decoding: try await c.readLine(), as: UTF8.self)
            lines.append(line)
            if line.count < 4 || line[line.index(line.startIndex, offsetBy: 3)] != "-" { break }
        }
        let code = Int(lines.last?.prefix(3) ?? "") ?? 0
        return (code, lines.joined(separator: " "))
    }

    private static func expect(_ c: MailConnection, _ ok: ClosedRange<Int>) async throws {
        let (code, text) = try await reply(c)
        if !ok.contains(code) { throw MailError.server(text) }
    }

    static func send(_ m: Outgoing, account: MailAccount, credential: MailCredential) async throws {
        let implicit = account.smtpPort == 465
        let c = MailConnection(host: account.smtpHost, port: account.smtpPort, tls: implicit)
        defer { c.close() }
        try await expect(c, 220...220)
        try await c.send("EHLO minimalia\r\n")
        try await expect(c, 250...250)
        if !implicit {
            try await c.send("STARTTLS\r\n")
            try await expect(c, 220...220)
            c.startTLS()
            try await c.send("EHLO minimalia\r\n")
            try await expect(c, 250...250)
        }
        switch credential {
        case .password(let password):
            let auth = Data("\u{0}\(account.email)\u{0}\(password)".utf8).base64EncodedString()
            try await c.send("AUTH PLAIN \(auth)\r\n")
        case .google(let refresh):
            let token = try await GoogleSignIn.accessToken(refresh: refresh)
            try await c.send("AUTH XOAUTH2 \(MailCredential.xoauth2(email: account.email, token: token))\r\n")
        }
        try await expect(c, 235...235)
        try await c.send("MAIL FROM:<\(account.email)>\r\n")
        try await expect(c, 250...250)
        for r in m.to + m.cc {
            try await c.send("RCPT TO:<\(r.email)>\r\n")
            try await expect(c, 250...251)
        }
        try await c.send("DATA\r\n")
        try await expect(c, 354...354)

        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        let domain = account.email.split(separator: "@").last.map(String.init) ?? "minimalia.local"
        var head = [
            "From: \(MIME.encodeAddress(MailAddress(name: account.name, email: account.email)))",
            "To: \(m.to.map(MIME.encodeAddress).joined(separator: ", "))",
        ]
        if !m.cc.isEmpty { head.append("Cc: \(m.cc.map(MIME.encodeAddress).joined(separator: ", "))") }
        head += [
            "Subject: \(MIME.encodeWord(m.subject))",
            "Date: \(df.string(from: Date()))",
            "Message-ID: <\(UUID().uuidString.lowercased())@\(domain)>",
        ]
        if let r = m.inReplyTo, !r.isEmpty { head.append("In-Reply-To: \(r)") }
        if let r = m.references, !r.isEmpty { head.append("References: \(r)") }
        head += ["MIME-Version: 1.0", "Content-Type: text/plain; charset=utf-8", "Content-Transfer-Encoding: quoted-printable"]
        var body = MIME.quotedPrintable(m.body)
        // Lines that start with a dot are doubled, as SMTP requires.
        body = body.components(separatedBy: "\r\n").map { $0.hasPrefix(".") ? "." + $0 : $0 }.joined(separator: "\r\n")
        try await c.sendData(Data((head.joined(separator: "\r\n") + "\r\n\r\n" + body + "\r\n.\r\n").utf8))
        try await expect(c, 250...250)
        try? await c.send("QUIT\r\n")
    }
}
