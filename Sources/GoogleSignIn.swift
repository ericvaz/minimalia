import AppKit
import AuthenticationServices
import CryptoKit

/// Signing in with Google, so Gmail works without an app password.
/// Needs a Google OAuth client ID of the iOS type, set as MinimaliaGoogleClientID in Info.plist.
@MainActor
final class GoogleSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
    private weak var window: NSWindow?
    private var session: ASWebAuthenticationSession?

    static var clientID: String? {
        let id = (Bundle.main.object(forInfoDictionaryKey: "MinimaliaGoogleClientID") as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        return id.hasSuffix(".apps.googleusercontent.com") ? id : nil
    }

    /// "123-abc.apps.googleusercontent.com" becomes "com.googleusercontent.apps.123-abc".
    private static func scheme(_ id: String) -> String {
        "com.googleusercontent.apps." + id.replacingOccurrences(of: ".apps.googleusercontent.com", with: "")
    }

    init(window: NSWindow?) {
        self.window = window
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated { window ?? NSApp.keyWindow ?? NSWindow() }
    }

    struct Tokens {
        let email: String
        let refresh: String
    }

    func signIn() async throws -> Tokens {
        guard let id = Self.clientID else { throw MailError.server("Google sign-in is not set up in this copy of Minimalia.") }
        let scheme = Self.scheme(id)
        let redirect = "\(scheme):/oauth2redirect"
        let verifier = Self.randomVerifier()
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL

        var c = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        c.queryItems = [
            URLQueryItem(name: "client_id", value: id),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "https://mail.google.com/ openid email"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
        ]
        let callback: URL = try await withCheckedThrowingContinuation { cont in
            let s = ASWebAuthenticationSession(url: c.url!, callbackURLScheme: scheme) { url, error in
                if let url { cont.resume(returning: url) } else { cont.resume(throwing: error ?? MailError.server("Sign-in was cancelled.")) }
            }
            s.presentationContextProvider = self
            session = s
            s.start()
        }
        guard let code = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "code" })?.value else {
            throw MailError.server("Google did not return a sign-in code.")
        }
        let json = try await Self.token([
            "code": code, "client_id": id, "redirect_uri": redirect,
            "grant_type": "authorization_code", "code_verifier": verifier,
        ])
        guard let refresh = json["refresh_token"] as? String else { throw MailError.server("Google did not grant offline access.") }
        let email = (json["id_token"] as? String).flatMap(Self.emailFromIDToken) ?? ""
        return Tokens(email: email, refresh: refresh)
    }

    /// A fresh access token for IMAP and SMTP, from the stored refresh token.
    static func accessToken(refresh: String) async throws -> String {
        guard let id = clientID else { throw MailError.server("Google sign-in is not set up in this copy of Minimalia.") }
        let json = try await token(["refresh_token": refresh, "client_id": id, "grant_type": "refresh_token"])
        guard let access = json["access_token"] as? String else {
            throw MailError.server("Google sign-in has expired. Sign in again from Letters.")
        }
        return access
    }

    private static func token(_ form: [String: String]) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?/:")
        req.httpBody = form.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.value)" }
            .joined(separator: "&").data(using: .utf8)
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw MailError.server("Google sent an unreadable answer.") }
        if let err = json["error_description"] as? String ?? json["error"] as? String { throw MailError.server("Google: \(err)") }
        return json
    }

    private static func randomVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 48)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URL
    }

    private static func emailFromIDToken(_ jwt: String) -> String? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let d = Data(base64Encoded: b64), let json = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        return json["email"] as? String
    }
}

extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// How Letters proves who you are: an app password, or a Google sign-in.
enum MailCredential {
    case password(String)
    case google(String)

    static let googlePrefix = "google-refresh:"

    /// What is kept in the Keychain.
    var stored: String {
        switch self {
        case .password(let p): return p
        case .google(let r): return Self.googlePrefix + r
        }
    }

    static func from(stored s: String) -> MailCredential {
        s.hasPrefix(googlePrefix) ? .google(String(s.dropFirst(googlePrefix.count))) : .password(s)
    }

    /// The SASL XOAUTH2 string for IMAP and SMTP.
    static func xoauth2(email: String, token: String) -> String {
        Data("user=\(email)\u{1}auth=Bearer \(token)\u{1}\u{1}".utf8).base64EncodedString()
    }

    /// Turns a server's refusal into a sentence a person can act on.
    static func explain(_ error: Error, account: MailAccount?) -> String {
        let raw = error.localizedDescription
        let lower = raw.lowercased()
        if lower.contains("authenticationfailed") || lower.contains("invalid credentials") || lower.contains("application-specific")
            || lower.contains("username and password not accepted") || lower.contains("535") {
            if account?.isGmail == true {
                return "Gmail did not accept that password. Gmail needs an app password: a 16-letter code you create in your Google account, not your usual password."
            }
            return "The mail server did not accept that address and password."
        }
        if lower.contains("could not be found") || lower.contains("cannot find host") {
            return "Letters could not find the mail server for that address. Check the spelling of the address."
        }
        if lower.contains("offline") || lower.contains("not connected") {
            return "There is no Internet connection right now."
        }
        return raw
    }
}
