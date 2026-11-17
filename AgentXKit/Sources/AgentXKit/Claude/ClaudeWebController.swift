import AppKit
import Observation
import WebKit

/// claude.ai, hosted in AgentX. Because this *is* Claude's own website, your
/// regular chats are the same ones you see on your phone: send a message
/// there and it's here, and the other way round.
///
/// AgentX doesn't read or automate the page. It only hosts it, keeps you
/// signed in (cookies live in AgentX's own web data store), and opens
/// non-Claude links in your default browser.
///
/// The claude.ai side is chat-only: Claude Code lives in AgentX's Sessions section. A small
/// stylesheet hides links into claude.ai/code, and if the page goes there
/// anyway, AgentX steps back and switches to Sessions.
@MainActor
@Observable
public final class ClaudeWebController: NSObject {
    public static let shared = ClaudeWebController()

    static let home = URL(string: "https://claude.ai/")!
    static let newChat = URL(string: "https://claude.ai/new")!

    public private(set) var canGoBack = false
    public private(set) var canGoForward = false
    public private(set) var isLoading = false
    public private(set) var currentURL: URL?
    /// Set when the page tried to open Google sign-in, which Google blocks in embedded web views.
    public var showGoogleSignInTip = false
    public private(set) var lastDownload: URL?

    @ObservationIgnored private(set) var webView: WKWebView
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var hasLoaded = false
    @ObservationIgnored private var unloadTask: Task<Void, Never>?
    /// claude.ai's web process uses a few hundred MB; it's released after the
    /// The claude.ai side has been out of sight this long (sign-in is kept).
    static let unloadAfter: Duration = .seconds(15 * 60)

    override private init() {
        webView = Self.makeWebView()
        super.init()
        attach()
    }

    private static func makeWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()  // persistent: sign in once
        config.applicationNameForUserAgent = "AgentX/0.1"
        config.preferences.isElementFullscreenEnabled = true
        config.userContentController.addUserScript(WKUserScript(
            source: Self.hideCodeLinksScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        return webView
    }

    private func attach() {
        webView.navigationDelegate = self
        webView.uiDelegate = self
        observations = [
            webView.observe(\.canGoBack) { [weak self] wv, _ in MainActor.assumeIsolated { self?.canGoBack = wv.canGoBack } },
            webView.observe(\.canGoForward) { [weak self] wv, _ in MainActor.assumeIsolated { self?.canGoForward = wv.canGoForward } },
            webView.observe(\.isLoading) { [weak self] wv, _ in MainActor.assumeIsolated { self?.isLoading = wv.isLoading } },
            webView.observe(\.url) { [weak self] wv, _ in
                MainActor.assumeIsolated {
                    self?.currentURL = wv.url
                    // claude.ai switches pages without a full load, so watch the URL too.
                    if let url = wv.url, Self.isCodePage(url) { self?.leaveCodePage() }
                }
            },
        ]
    }

    /// The claude.ai side came into view: cancel any pending unload and make sure the page is there.
    func didShow() {
        unloadTask?.cancel()
        unloadTask = nil
        loadIfNeeded()
    }

    /// The claude.ai side went out of view: release the web page if it stays hidden.
    func didHide() {
        unloadTask?.cancel()
        unloadTask = Task { [weak self] in
            try? await Task.sleep(for: Self.unloadAfter)
            guard !Task.isCancelled else { return }
            self?.unload()
        }
    }

    /// Swap in a fresh, empty web view so WebKit frees the old page's process.
    private func unload() {
        observations = []
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView = Self.makeWebView()
        attach()
        hasLoaded = false
        canGoBack = false
        canGoForward = false
        isLoading = false
    }

    /// Load claude.ai the first time its side of the Claude section is shown.
    func loadIfNeeded() {
        guard !hasLoaded else { return }
        hasLoaded = true
        webView.load(URLRequest(url: Self.home))
    }

    public func startNewChat() {
        hasLoaded = true
        webView.load(URLRequest(url: Self.newChat))
    }

    /// For "Continue on Mac": the text you selected in the chat, or else the
    /// conversation on screen, quoted. It's read from the page you're looking
    /// at (in a separate script world the page can't interfere with); nothing
    /// is fetched from claude.ai.
    func chatText(limit: Int = 12_000) async -> String? {
        let script = """
            const selected = (window.getSelection ? window.getSelection().toString() : '').trim();
            if (selected) return { selection: true, title: document.title, text: selected };
            const main = document.querySelector('main') || document.body;
            return { selection: false, title: document.title, text: (main.innerText || '').trim() };
            """
        guard let result = try? await webView.callAsyncJavaScript(script, contentWorld: .defaultClient) as? [String: Any],
              let text = result["text"] as? String, !text.isEmpty else { return nil }
        let title = (result["title"] as? String ?? "")
            .replacingOccurrences(of: " - Claude", with: "")
            .trimmingCharacters(in: .whitespaces)
        return Self.handoffText(text, title: title == "Claude" ? "" : title,
                                isSelection: result["selection"] as? Bool ?? false, limit: limit)
    }

    /// Quote chat text for a new conversation on the Mac.
    nonisolated static func handoffText(_ text: String, title: String, isSelection: Bool, limit: Int = 12_000) -> String {
        let clipped = text.count > limit ? "…" + text.suffix(limit) : Substring(text)
        let quoted = clipped.split(separator: "\n", omittingEmptySubsequences: false).map { "> " + $0 }.joined(separator: "\n")
        let what = isSelection ? "Here's part of a chat I had on claude.ai" : "Here's a chat I had on claude.ai"
        let named = title.isEmpty ? "" : " (\"\(title)\")"
        return "\(what)\(named):\n\n\(quoted)\n\n"
    }

    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }
    func reload() { webView.reload() }

    func openInBrowser() {
        NSWorkspace.shared.open(currentURL ?? Self.home)
    }

    /// Open a claude.ai link (e.g. a sign-in link from an email) inside AgentX.
    /// Returns false for anything that isn't a Claude URL.
    @discardableResult
    func open(link: String) -> Bool {
        guard let url = URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "https", let host = url.host, Self.isClaude(host) else { return false }
        hasLoaded = true
        webView.load(URLRequest(url: url))
        return true
    }

    nonisolated static func isClaude(_ host: String) -> Bool {
        let h = host.lowercased()
        return ["claude.ai", "claude.com", "anthropic.com"].contains { h == $0 || h.hasSuffix("." + $0) }
    }

    /// claude.ai/code and anything under it: Claude Code, which belongs in Sessions.
    nonisolated static func isCodePage(_ url: URL) -> Bool {
        guard let host = url.host, isClaude(host) else { return false }
        return url.path == "/code" || url.path.hasPrefix("/code/")
    }

    /// Hides links into claude.ai/code (the sidebar's Code switch and similar).
    /// Only adds a stylesheet; nothing on the page is read or changed otherwise.
    static let hideCodeLinksScript = """
    (() => {
      const css = 'a[href="/code"], a[href^="/code/"], a[href^="/code?"], a[href^="https://claude.ai/code"] { display: none !important; }';
      const add = () => {
        if (document.getElementById('agentx-chat-only')) return;
        const style = document.createElement('style');
        style.id = 'agentx-chat-only';
        style.textContent = css;
        (document.head || document.documentElement).appendChild(style);
      };
      if (document.documentElement) add(); else document.addEventListener('DOMContentLoaded', add);
    })();
    """

    /// The page went to Claude Code: go back to chats and show Sessions instead.
    private func leaveCodePage() {
        if webView.canGoBack { webView.goBack() } else { webView.load(URLRequest(url: Self.newChat)) }
        AppModel.shared.sidebar = .sessions
    }

    nonisolated static func isGoogleSignIn(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "accounts.google.com" || (host.hasSuffix(".google.com") && url.path.contains("oauth"))
    }

    /// Hosts the page may navigate to inside AgentX besides Claude's own
    /// (Sign in with Apple, Cloudflare's bot check).
    nonisolated static func isAllowedInApp(_ host: String) -> Bool {
        let h = host.lowercased()
        return isClaude(h) || h == "appleid.apple.com" || h == "challenges.cloudflare.com"
    }
}

extension ClaudeWebController: WKNavigationDelegate {
    public func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        if action.shouldPerformDownload { return .download }
        guard let url = action.request.url else { return .allow }
        if ["about", "blob", "data"].contains(url.scheme ?? "") { return .allow }
        if Self.isGoogleSignIn(url) {
            showGoogleSignInTip = true
            return .cancel
        }
        if action.targetFrame?.isMainFrame != false, Self.isCodePage(url) {
            AppModel.shared.sidebar = .sessions
            return .cancel
        }
        // Embedded content (iframes) can load from anywhere, like in a browser.
        if action.targetFrame?.isMainFrame == false { return .allow }
        if let host = url.host, Self.isAllowedInApp(host) { return .allow }
        // Everything else (links inside chats, docs, ...) opens in your browser.
        NSWorkspace.shared.open(url)
        return .cancel
    }

    public func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        response.canShowMIMEType ? .allow : .download
    }

    public func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    public func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let host = webView.url?.host, Self.isClaude(host), !(webView.url?.path.hasPrefix("/login") ?? false) {
            showGoogleSignInTip = false
        }
    }
}

extension ClaudeWebController: WKUIDelegate {
    /// Links that open a new window: Claude pages load here, others go to the browser.
    public func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                        for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url {
            if Self.isCodePage(url) { AppModel.shared.sidebar = .sessions }
            else if let host = url.host, Self.isClaude(host) { webView.load(URLRequest(url: url)) }
            else if Self.isGoogleSignIn(url) { showGoogleSignInTip = true }
            else { NSWorkspace.shared.open(url) }
        }
        return nil
    }

    /// File attachments.
    public func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                        initiatedByFrame frame: WKFrameInfo) async -> [URL]? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        return panel.runModal() == .OK ? panel.urls : nil
    }

    /// Voice mode asks for the microphone; macOS shows its own permission prompt.
    public func webView(_ webView: WKWebView, decideMediaCapturePermissionsFor origin: WKSecurityOrigin,
                        initiatedBy frame: WKFrameInfo, type: WKMediaCaptureType) async -> WKPermissionDecision {
        guard Self.isClaude(origin.host) else { return .deny }
        return type == .microphone ? .prompt : .deny
    }

    public func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                        initiatedByFrame frame: WKFrameInfo) async {
        let alert = NSAlert()
        alert.messageText = message
        alert.runModal()
    }

    public func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                        initiatedByFrame frame: WKFrameInfo) async -> Bool {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

extension ClaudeWebController: WKDownloadDelegate {
    /// Downloads (artifacts, exported files) go to ~/Downloads, without overwriting.
    public func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                         suggestedFilename: String) async -> URL? {
        let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let name = (suggestedFilename as NSString).lastPathComponent
        var target = folder.appendingPathComponent(name.isEmpty ? "Download" : name)
        let base = target.deletingPathExtension().lastPathComponent, ext = target.pathExtension
        var n = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        lastDownload = target
        return target
    }

    public func downloadDidFinish(_ download: WKDownload) {
        if let file = lastDownload { NSWorkspace.shared.activateFileViewerSelecting([file]) }
    }
}
