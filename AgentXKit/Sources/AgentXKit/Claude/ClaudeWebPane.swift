import SwiftUI
import WebKit

/// The Chats section's claude.ai side: your regular Claude chats, the same
/// ones as on your phone. It can't act on your Mac; "Continue on Mac" carries
/// a chat over to the other side.
struct ClaudeWebPane: View {
    @Environment(AppModel.self) private var model
    @State private var web = ClaudeWebController.shared
    @State private var showLinkSheet = false
    @State private var handoffError: String?

    var body: some View {
        WebViewHost(webView: web.webView)
            .overlay(alignment: .top) {
                if web.showGoogleSignInTip { GoogleSignInTip(dismiss: { web.showGoogleSignInTip = false }) }
            }
            .overlay(alignment: .bottomTrailing) {
                if web.isLoading { ProgressView().controlSize(.small).padding(12) }
            }
            .overlay(alignment: .bottom) {
                if model.webPasteHint {
                    PasteHint { model.webPasteHint = false }
                }
            }
            .task(id: model.webPasteHint) {
                guard model.webPasteHint else { return }
                try? await Task.sleep(for: .seconds(30))
                model.webPasteHint = false
            }
            .onAppear { web.didShow() }
            .onDisappear {
                web.didHide()
                model.webPasteHint = false
            }
            .navigationSubtitle("Synced with your phone · can't act on your Mac")
            .alert("Nothing to bring over", isPresented: .constant(handoffError != nil), presenting: handoffError) { _ in
                Button("OK") { handoffError = nil }
            } message: { Text($0) }
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
                    Button("Continue on Mac", systemImage: "desktopcomputer") { Task { await continueOnMac() } }
                        .help("Bring this chat (or the text you've selected in it) to a new conversation on this Mac, where Claude can use your Mac. Nothing is sent until you press Send.")
                    Menu("More", systemImage: "ellipsis.circle") {
                        Button("Open in Browser") { web.openInBrowser() }
                        Button("Open a Sign-in Link…") { showLinkSheet = true }
                    }
                }
            }
            .sheet(isPresented: $showLinkSheet) { SignInLinkSheet(web: web) }
    }

    private func continueOnMac() async {
        guard let text = await web.chatText() else {
            handoffError = "Open a chat (or select some of its text) first, then choose Continue on Mac."
            return
        }
        model.continueOnMac(text)
    }
}

/// After "Continue in claude.ai": the conversation is on the clipboard, ready to paste.
private struct PasteHint: View {
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.on.clipboard").foregroundStyle(.tint)
            Text("Your Mac conversation is on the clipboard. Click the message box and paste (⌘V) to continue here.")
                .font(.callout)
            Spacer(minLength: 0)
            Button("Dismiss", systemImage: "xmark", action: dismiss)
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
        }
        .padding(12)
        .glassEffect(.regular, in: .agentCard)
        .frame(maxWidth: 560)
        .padding(.bottom, 90)
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
