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
/// Chats is chat-only: Claude Code lives in AgentX's Sessions section. A small
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

    @ObservationIgnored let webView: WKWebView
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var hasLoaded = false

    override private init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()  // persistent: sign in once
        config.applicationNameForUserAgent = "AgentX/0.1"
        config.preferences.isElementFullscreenEnabled = true
        config.userContentController.addUserScript(WKUserScript(
            source: Self.hideCodeLinksScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        super.init()
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

    /// Load claude.ai the first time the Chats section is shown.
    func loadIfNeeded() {
        guard !hasLoaded else { return }
        hasLoaded = true
        webView.load(URLRequest(url: Self.home))
    }

    public func startNewChat() {
        hasLoaded = true
        webView.load(URLRequest(url: Self.newChat))
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
    public func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                        initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType) async -> WKPermissionDecision {
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
