import AppKit
import WebKit

/// A web view that hands Esc back to Minimalia instead of to the page.
final class CalmWebView: WKWebView {
    var onEscape: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape?(); return }
        super.keyDown(with: event)
    }
}

/// A greyscale address field that matches the Minimalia bars.
final class AddressField: NSTextField {
    var onEscape: (() -> Void)?

    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

/// Minimalia Browse: the real web, calmed. Pages are shown in greyscale, ads and trackers are blocked,
/// nothing plays by itself, and any page can be turned into plain text.
@MainActor
final class BrowseProgram: NSObject, MinimaliaProgram, WKNavigationDelegate, WKUIDelegate {
    let screen = NSView()
    let web: CalmWebView
    private let topBar = MonoBar()
    private let statusBar = MonoBar(lineAtBottom: false)
    private let address = AddressField()
    private var backButton: MonoButton!
    private var forwardButton: MonoButton!
    private var reloadButton: MonoButton!
    private var textButton: MonoButton!
    private var statusLabel: NSTextField!
    private var zoomLabel: NSTextField!
    private var progressObservation: NSKeyValueObservation?
    private var reader: ReaderController?
    private let start: URL?
    private var message: String?

    var onExit: (() -> Void)?
    /// Tells the shell which page is open, for SAVE and SUMMARIZE.
    var onPage: ((URL) -> Void)?
    var focusView: NSView { start == nil ? address : web }

    static let homeLinks: [(String, String)] = [
        ("CBC News, text only", "https://www.cbc.ca/lite/news"),
        ("NPR, text only", "https://text.npr.org"),
        ("CNN Lite", "https://lite.cnn.com"),
        ("Wikipedia", "https://en.wikipedia.org"),
        ("Project Gutenberg, free books", "https://www.gutenberg.org"),
        ("Hacker News", "https://news.ycombinator.com"),
    ]

    private static let blockedHosts = [
        "doubleclick.net", "googlesyndication.com", "googleadservices.com", "adservice.google.com",
        "google-analytics.com", "googletagmanager.com", "googletagservices.com", "connect.facebook.net",
        "scorecardresearch.com", "taboola.com", "outbrain.com", "criteo.com", "criteo.net", "amazon-adsystem.com",
        "adnxs.com", "rubiconproject.com", "pubmatic.com", "moatads.com", "quantserve.com", "hotjar.com",
        "chartbeat.com", "doubleverify.com", "adsrvr.org", "openx.net", "casalemedia.com", "teads.tv",
        "smartadserver.com", "yieldmo.com", "sharethrough.com", "media.net", "zedo.com", "bidswitch.net",
        "3lift.com", "indexww.com", "sovrn.com", "lijit.com", "adform.net", "outbrainimg.com", "mgid.com",
    ]

    private static let hiddenSelectors = [
        "#onetrust-banner-sdk", "#onetrust-consent-sdk", ".fc-consent-root", "#CybotCookiebotDialog",
        ".cc-window", "#cookie-banner", ".cookie-banner", "#cookieConsent", ".qc-cmp2-container",
        "[id^='sp_message_container']", ".truste_box_overlay", "#truste-consent-track", ".adsbygoogle",
        "[id^='google_ads_iframe']", "[class*='newsletter-popup']",
    ]

    private static var ruleList: WKContentRuleList?

    private static func compileRules() async -> WKContentRuleList? {
        if let r = ruleList { return r }
        var rules: [[String: Any]] = blockedHosts.map { host in
            let escaped = host.replacingOccurrences(of: ".", with: "\\.")
            return ["trigger": ["url-filter": "^https?://([^/]*\\.)?\(escaped)[/:]"], "action": ["type": "block"]]
        }
        rules.append(["trigger": ["url-filter": ".*"],
                      "action": ["type": "css-display-none", "selector": hiddenSelectors.joined(separator: ", ")]])
        guard let data = try? JSONSerialization.data(withJSONObject: rules),
              let json = String(data: data, encoding: .utf8) else { return nil }
        ruleList = try? await WKContentRuleListStore.default()?.compileContentRuleList(forIdentifier: "MinimaliaCalm", encodedContentRuleList: json)
        return ruleList
    }

    /// No smooth-scroll tricks.
    private static let calmCSS = """
    html { scroll-behavior: auto !important; }
    """

    init(start: URL?) {
        self.start = start
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.mediaTypesRequiringUserActionForPlayback = .all
        let css = (try? String(data: JSONSerialization.data(withJSONObject: [Self.calmCSS]), encoding: .utf8)) ?? "[\"\"]"
        // Greyscale is set through the page's style object, which site security policies do not block.
        let js = "(function(){var h=document.documentElement;h.style.setProperty('filter','grayscale(1) brightness(0.94) contrast(0.96)','important');"
            + "try{var s=document.createElement('style');s.textContent=\(css)[0];(document.head||h).appendChild(s);}catch(e){}})();"
        config.userContentController.addUserScript(WKUserScript(source: js, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        web = CalmWebView(frame: .zero, configuration: config)
        super.init()
        web.navigationDelegate = self
        web.uiDelegate = self
        web.allowsBackForwardNavigationGestures = true
        web.allowsMagnification = true
        let z = UserDefaults.standard.double(forKey: "browseZoom")
        web.pageZoom = z > 0 ? CGFloat(z) : 1.2
        web.onEscape = { [weak self] in self?.closeBrowser(nil) }

        buildScreen()
        progressObservation = web.observe(\.estimatedProgress) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.updateStatus() }
        }
        Task { @MainActor in
            if let rules = await Self.compileRules() { self.web.configuration.userContentController.add(rules) }
            if let start { self.web.load(URLRequest(url: start)) } else { self.goHome(nil) }
        }
    }

    // MARK: Building

    private func buildScreen() {
        let p = MonoPalette.current
        screen.wantsLayer = true
        screen.layer?.backgroundColor = p.desk.cgColor
        screen.appearance = p.appearance

        backButton = MonoButton("", symbol: "chevron.left", help: "Back") { [weak self] _ in self?.goBack(nil) }
        forwardButton = MonoButton("", symbol: "chevron.right", help: "Forward") { [weak self] _ in self?.goForward(nil) }
        reloadButton = MonoButton("", symbol: "arrow.clockwise", help: "Reload") { [weak self] _ in self?.reload(nil) }
        let home = MonoButton("", symbol: "house", help: "Start page") { [weak self] _ in self?.goHome(nil) }
        textButton = MonoButton("Text", symbol: "doc.plaintext", help: "Show this page as plain text") { [weak self] _ in self?.toggleText(nil) }
        [backButton, forwardButton, reloadButton, home].forEach { topBar.add($0!) }

        address.placeholderString = "Search Google or type an address"
        address.isBordered = false
        address.isBezeled = false
        address.drawsBackground = true
        address.backgroundColor = p.page
        address.textColor = p.ink
        address.font = .systemFont(ofSize: 14)
        address.focusRingType = .none
        address.lineBreakMode = .byTruncatingTail
        address.usesSingleLineMode = true
        address.target = self
        address.action = #selector(addressEntered(_:))
        address.onEscape = { [weak self] in
            guard let self else { return }
            self.address.stringValue = self.web.url?.absoluteString ?? ""
            self.screen.window?.makeFirstResponder(self.web)
        }
        let field = NSView()
        field.wantsLayer = true
        field.layer?.backgroundColor = p.page.cgColor
        field.layer?.borderColor = p.edge.cgColor
        field.layer?.borderWidth = 1
        field.layer?.cornerRadius = 4
        address.translatesAutoresizingMaskIntoConstraints = false
        field.addSubview(address)
        NSLayoutConstraint.activate([
            address.leadingAnchor.constraint(equalTo: field.leadingAnchor, constant: 10),
            address.trailingAnchor.constraint(equalTo: field.trailingAnchor, constant: -10),
            address.centerYAnchor.constraint(equalTo: field.centerYAnchor),
            field.heightAnchor.constraint(equalToConstant: 28),
        ])
        field.setContentHuggingPriority(.init(1), for: .horizontal)
        topBar.add(field)
        topBar.add(textButton)

        statusLabel = statusBar.label()
        statusBar.add(statusLabel)
        statusBar.addSpacer()
        let hint = statusBar.label("Esc returns to the prompt")
        hint.textColor = p.dim
        statusBar.add(hint)
        statusBar.addDivider()
        zoomLabel = statusBar.label("")
        statusBar.add(MonoButton("", symbol: "minus.magnifyingglass", help: "Smaller") { [weak self] _ in self?.zoomOut(nil) })
        statusBar.add(zoomLabel)
        statusBar.add(MonoButton("", symbol: "plus.magnifyingglass", help: "Larger") { [weak self] _ in self?.zoomIn(nil) })
        zoomLabel.stringValue = "\(Int((web.pageZoom * 100).rounded()))%"

        for v in [topBar, web, statusBar] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            screen.addSubview(v)
        }
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: screen.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: screen.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: screen.trailingAnchor),
            topBar.heightAnchor.constraint(equalToConstant: 44),
            web.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            web.leadingAnchor.constraint(equalTo: screen.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: screen.trailingAnchor),
            statusBar.topAnchor.constraint(equalTo: web.bottomAnchor),
            statusBar.leadingAnchor.constraint(equalTo: screen.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: screen.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: screen.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: 28),
        ])
        updateButtons()
    }

    // MARK: Navigation

    static func searchURL(_ words: String) -> URL? {
        var c = URLComponents(string: "https://www.google.com/search")
        c?.queryItems = [URLQueryItem(name: "q", value: words)]
        return c?.url
    }

    /// Words go to Google; anything that looks like an address is opened.
    static func destination(for input: String) -> URL? {
        let t = input.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        if !t.contains(" "), let u = Web.address(t) { return u }
        return searchURL(t)
    }

    @objc private func addressEntered(_ sender: Any?) {
        guard let u = Self.destination(for: address.stringValue) else { return }
        closeReader()
        web.load(URLRequest(url: u))
        screen.window?.makeFirstResponder(web)
    }

    @objc func goBack(_ sender: Any?) { closeReader(); web.goBack() }
    @objc func goForward(_ sender: Any?) { closeReader(); web.goForward() }

    @objc func reload(_ sender: Any?) {
        if web.isLoading { web.stopLoading() } else { web.reload() }
    }

    @objc func openLocation(_ sender: Any?) {
        screen.window?.makeFirstResponder(address)
        address.selectText(nil)
    }

    @objc func goHome(_ sender: Any?) {
        closeReader()
        let p = MonoPalette.current
        func hex(_ c: NSColor) -> String {
            let s = c.usingColorSpace(.sRGB) ?? c
            return String(format: "#%02X%02X%02X", Int(s.redComponent * 255), Int(s.greenComponent * 255), Int(s.blueComponent * 255))
        }
        let links = Self.homeLinks.map { "<li><a href=\"\($0.1)\">\($0.0)</a></li>" }.joined()
        let html = """
        <!doctype html><html><head><meta charset="utf-8"><title>Minimalia</title><style>
        body { background:\(hex(p.desk)); color:\(hex(p.ink)); font: 17px -apple-system, "Helvetica Neue", sans-serif;
               margin:0; display:flex; justify-content:center; }
        main { width: min(640px, 90vw); margin-top: 14vh; }
        h1 { font-weight: 600; font-size: 28px; letter-spacing: .02em; margin: 0 0 28px; }
        form { display:flex; gap:10px; margin-bottom: 44px; }
        input { flex:1; font: inherit; padding: 12px 14px; background:\(hex(p.page)); color:\(hex(p.ink));
                border:1px solid \(hex(p.edge)); border-radius:6px; outline:none; }
        button { font: inherit; padding: 0 18px; background:\(hex(p.bar)); color:\(hex(p.ink));
                 border:1px solid \(hex(p.edge)); border-radius:6px; }
        h2 { font-size: 13px; font-weight:600; text-transform: uppercase; letter-spacing:.08em; color:\(hex(p.dim)); }
        ul { list-style:none; padding:0; margin:0; }
        li { padding: 9px 0; border-bottom: 1px solid \(hex(p.edge)); }
        a { color:\(hex(p.ink)); text-decoration:none; } a:hover { text-decoration: underline; }
        </style></head><body><main>
        <h1>Minimalia</h1>
        <form action="https://www.google.com/search" method="get">
        <input name="q" autofocus placeholder="Search Google"><button>Search</button></form>
        <h2>Quiet places</h2><ul>\(links)</ul>
        </main></body></html>
        """
        web.loadHTMLString(html, baseURL: nil)
        address.stringValue = ""
    }

    // MARK: Text mode

    @objc func toggleText(_ sender: Any?) {
        if reader != nil { closeReader(); return }
        guard let url = web.url, url.scheme?.hasPrefix("http") == true else {
            flash("The start page has no text view.")
            return
        }
        web.evaluateJavaScript("document.documentElement.outerHTML") { [weak self] result, _ in
            MainActor.assumeIsolated {
                guard let self, let html = result as? String else { return }
                var page = HTMLText.extract(html, base: url)
                if let t = self.web.title, !t.isEmpty { page.title = t }
                self.showReader(page)
            }
        }
    }

    private func showReader(_ page: TextPage) {
        let r = ReaderController(page: page)
        r.onClose = { [weak self] in self?.closeReader() }
        reader = r
        let v = r.screen
        v.translatesAutoresizingMaskIntoConstraints = false
        screen.addSubview(v)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: web.topAnchor),
            v.bottomAnchor.constraint(equalTo: web.bottomAnchor),
            v.leadingAnchor.constraint(equalTo: web.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: web.trailingAnchor),
        ])
        textButton.isOn = true
        screen.window?.makeFirstResponder(r.tv)
    }

    private func closeReader() {
        guard let r = reader else { return }
        r.screen.removeFromSuperview()
        reader = nil
        textButton.isOn = false
        screen.window?.makeFirstResponder(web)
    }

    @objc func savePageAsText(_ sender: Any?) {
        guard let url = web.url, url.scheme?.hasPrefix("http") == true else { return }
        web.evaluateJavaScript("document.documentElement.outerHTML") { [weak self] result, _ in
            MainActor.assumeIsolated {
                guard let self, let html = result as? String else { return }
                var page = HTMLText.extract(html, base: url)
                if let t = self.web.title, !t.isEmpty { page.title = t }
                if let saved = try? Library.save(page) { self.flash("Saved to LIBRARY as \(saved.lastPathComponent)") }
            }
        }
    }

    // MARK: Zoom

    private func setZoom(_ z: CGFloat) {
        let z = min(3, max(0.5, (z * 10).rounded() / 10))
        web.pageZoom = z
        zoomLabel.stringValue = "\(Int((z * 100).rounded()))%"
        UserDefaults.standard.set(Double(z), forKey: "browseZoom")
    }

    @objc func zoomIn(_ sender: Any?) { setZoom(web.pageZoom + 0.1) }
    @objc func zoomOut(_ sender: Any?) { setZoom(web.pageZoom - 0.1) }
    @objc func actualSize(_ sender: Any?) { setZoom(1.2) }

    @objc func printPage(_ sender: Any?) {
        guard let window = screen.window else { return }
        let op = web.printOperation(with: NSPrintInfo.shared)
        op.view?.frame = web.bounds
        op.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    @objc func closeBrowser(_ sender: Any?) {
        if reader != nil { closeReader(); return }
        web.stopLoading()
        progressObservation = nil
        let c = onExit
        onExit = nil
        c?()
    }

    // MARK: Status

    private func updateButtons() {
        backButton.alphaValue = web.canGoBack ? 1 : 0.35
        forwardButton.alphaValue = web.canGoForward ? 1 : 0.35
        reloadButton.symbol = web.isLoading ? "xmark" : "arrow.clockwise"
        reloadButton.needsDisplay = true
    }

    private func updateStatus() {
        updateButtons()
        if let message { statusLabel.stringValue = message; return }
        if web.isLoading {
            statusLabel.stringValue = "Loading \(web.url?.host ?? "")  \(Int(web.estimatedProgress * 100))%"
        } else {
            statusLabel.stringValue = web.title ?? ""
        }
    }

    private func flash(_ text: String) {
        message = text
        updateStatus()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.message == text else { return }
            self.message = nil
            self.updateStatus()
        }
    }

    // MARK: WebKit delegates

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        updateStatus()
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        if let u = webView.url, u.scheme?.hasPrefix("http") == true {
            if screen.window?.firstResponder != address.currentEditor() { address.stringValue = u.absoluteString }
            onPage?(u)
        }
        updateStatus()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        updateStatus()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        showError(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        showError(error)
    }

    private func showError(_ error: Error) {
        if (error as NSError).code == NSURLErrorCancelled { updateStatus(); return }
        flash("Unable to open the page: \(Web.describe(error))")
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        if navigationResponse.canShowMIMEType { return .allow }
        flash("This is a file to download. Minimalia does not download from the web.")
        return .cancel
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // Links that would open a new window open here instead.
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async {
        flash(message)
    }

    // MARK: Menus

    func makeMenus() -> [NSMenu] {
        func menu(_ title: String, _ items: [NSMenuItem]) -> NSMenu {
            let m = NSMenu(title: title)
            items.forEach(m.addItem)
            m.appearance = MonoPalette.current.appearance
            return m
        }
        let me: AnyObject = self
        return [
            menu("File", [
                .mono("Open Location", #selector(openLocation(_:)), "l", target: me),
                .mono("Save Page as Text", #selector(savePageAsText(_:)), "s", [.command, .shift], target: me),
                .mono("Print\u{2026}", #selector(printPage(_:)), "p", target: me),
                .separator(),
                .mono("Close Browser", #selector(closeBrowser(_:)), "w", target: me),
            ]),
            menu("Edit", [
                .mono("Undo", Selector(("undo:")), "z"),
                .mono("Redo", Selector(("redo:")), "z", [.command, .shift]),
                .separator(),
                .mono("Cut", #selector(NSText.cut(_:)), "x"),
                .mono("Copy", #selector(NSText.copy(_:)), "c"),
                .mono("Paste", #selector(NSText.paste(_:)), "v"),
                .mono("Select All", #selector(NSText.selectAll(_:)), "a"),
            ]),
            menu("View", [
                .mono("Plain Text", #selector(toggleText(_:)), "t", target: me),
                .mono("Reload", #selector(reload(_:)), "r", target: me),
                .separator(),
                .mono("Larger", #selector(zoomIn(_:)), "=", target: me),
                .mono("Smaller", #selector(zoomOut(_:)), "-", target: me),
                .mono("Reading Size", #selector(actualSize(_:)), "0", target: me),
            ]),
            menu("Go", [
                .mono("Back", #selector(goBack(_:)), "[", target: me),
                .mono("Forward", #selector(goForward(_:)), "]", target: me),
                .mono("Start Page", #selector(goHome(_:)), "h", [.command, .shift], target: me),
            ]),
        ]
    }
}
