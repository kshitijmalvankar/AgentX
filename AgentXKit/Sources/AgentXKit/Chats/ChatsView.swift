import SwiftUI
import WebKit

/// Chats section: your regular Claude chats (claude.ai), the same ones as on your phone.
struct ChatsView: View {
    @State private var web = ClaudeWebController.shared
    @State private var showLinkSheet = false

    var body: some View {
        WebViewHost(webView: web.webView)
            .overlay(alignment: .top) {
                if web.showGoogleSignInTip { GoogleSignInTip(dismiss: { web.showGoogleSignInTip = false }) }
            }
            .overlay(alignment: .bottomTrailing) {
                if web.isLoading { ProgressView().controlSize(.small).padding(12) }
            }
            .onAppear { web.didShow() }
            .onDisappear { web.didHide() }
            .navigationTitle("Chats")
            .toolbar {
                ToolbarItemGroup(placement: .navigation) {
                    Button("Back", systemImage: "chevron.left") { web.goBack() }
                        .disabled(!web.canGoBack)
                    Button("Forward", systemImage: "chevron.right") { web.goForward() }
                        .disabled(!web.canGoForward)
                }
                ToolbarItemGroup {
                    Button("Reload", systemImage: "arrow.clockwise") { web.reload() }
                        .keyboardShortcut("r")
                        .help("Reload (⌘R) to pull in messages you just sent from your phone")
                    Button("New Chat", systemImage: "square.and.pencil") { web.startNewChat() }
                        .keyboardShortcut("n", modifiers: [.command, .shift])
                    Menu("More", systemImage: "ellipsis.circle") {
                        Button("Open in Browser") { web.openInBrowser() }
                        Button("Open a Sign-in Link…") { showLinkSheet = true }
                    }
                }
            }
            .sheet(isPresented: $showLinkSheet) { SignInLinkSheet(web: web) }
    }
}

private struct WebViewHost: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ view: WKWebView, context: Context) {}
}

/// Google refuses to sign in inside apps' embedded web views. The same
/// account works with an email code.
private struct GoogleSignInTip: View {
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "envelope.badge").font(.title2).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("Use your email instead of the Google button").fontWeight(.semibold)
                Text("Google doesn't allow its sign-in inside apps. Type your Google account's email address in the email field and choose Continue with email. Claude sends you a code or link for the same account. If you get a link, copy it and use More › Open a Sign-in Link… so it opens here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Dismiss", systemImage: "xmark", action: dismiss)
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
        }
        .padding(14)
        .glassEffect(.regular.tint(.orange.opacity(0.12)), in: .agentCard)
        .padding(12)
        .frame(maxWidth: 640)
    }
}

/// Paste a claude.ai sign-in link from an email so it opens inside AgentX
/// (clicking it in Mail would sign in your browser instead).
private struct SignInLinkSheet: View {
    let web: ClaudeWebController
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""
    @State private var invalid = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Open a Sign-in Link").font(.title3.bold())
            Text("In the email from Claude, right-click the sign-in button, choose Copy Link, and paste it here.")
                .foregroundStyle(.secondary)
            TextField("https://claude.ai/…", text: $link)
                .textFieldStyle(.roundedBorder)
                .onSubmit(openLink)
            if invalid {
                Text("That isn't a claude.ai link.").font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.secondaryButton()
                Button("Open", action: openLink)
                    .primaryButton()
                    .keyboardShortcut(.defaultAction)
                    .disabled(link.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private func openLink() {
        if web.open(link: link) { dismiss() } else { invalid = true }
    }
}
