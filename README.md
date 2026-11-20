# AgentX

A native macOS command center for Claude: your regular Claude chats (synced with the Claude app on your phone), Claude Code sessions you can run, approve and continue from your phone, a Mac assistant with a ⌥Space launcher, a system dashboard, GitHub, automations and desktop widgets. Powered by the Claude Agent SDK, using the Claude Code login on this Mac.

## Install it, and keep developing

There are two copies of AgentX, and they run side by side:

| | **AgentX** (installed) | **AgentX Dev** |
|---|---|---|
| Build it with | `scripts/install.sh` | `scripts/run-dev.sh` |
| Built from | a committed state (HEAD, or `--ref <tag>`), in a temporary git worktree | your working copy, edits included |
| Lives in | `/Applications/AgentX.app` | `build/AgentX Dev.app` |
| agent-core | embedded in the app bundle (production dependencies only) | runs from `agent-core/` in the repo |
| Data | `~/Library/Application Support/AgentX` | `~/Library/Application Support/AgentX Dev` |
| Hotkey, links | ⌥Space, `agentx://` | ⌃⌥Space, `agentx-dev://` |
| Automations | as you set them | paused by default, so nothing runs twice |

```bash
scripts/install.sh            # build HEAD, check it, install to /Applications, relaunch
```

```bash
scripts/install.sh --rollback # put the previous version back
```

`install.sh` refuses to build uncommitted changes (use `--allow-dirty` to test the script itself, or `--build-only` to check a build without installing). It runs `npm ci --omit=dev --ignore-scripts` and `npm audit` on agent-core, checks that the Claude Code engine is signed by Anthropic, builds with `Config/Stable.xcconfig`, and keeps the old app for `--rollback`.

**Signing (one-time, recommended):** builds are ad-hoc signed by default, so macOS forgets permissions like Accessibility and Screen Recording after every rebuild. Add your Apple ID in Xcode → Settings → Accounts (free), then copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig` and put your team id in it.

## Run the Dev copy

```bash
scripts/run-dev.sh
```

That generates the Xcode project, builds an optimized (Release) **AgentX Dev** and its widgets with `xcodebuild`, puts it at `build/AgentX Dev.app`, and opens it. Use `scripts/run-dev.sh --debug` for a Debug build to attach the debugger to. To work in Xcode instead (it builds AgentX Dev too):

```bash
xcodegen generate && open AgentX.xcodeproj
```

The first time, Xcode asks you to trust SwiftTerm's build plugin. Click **Trust & Enable**. `swift build --package-path AgentXKit` still builds and tests all the app code quickly, but without the widgets.

**Requirements:** macOS 26+, Xcode, XcodeGen (`brew install xcodegen`), Node 22.18+, and `npm ci` in `agent-core/`. You also need a Claude Code login: in AgentX, use **Sign In…**, then type `/login`.

## Security

AgentX lets Claude read your mail, calendar, notes and files and act on your Mac, so it treats everything Claude *reads* as possibly hostile. [SECURITY.md](SECURITY.md) has the threat model. In short:

- **Untrusted content.** Once a conversation has read a web page, email, note, calendar invite, clipboard or a file outside your projects, anything that could send data out (fetching a URL, opening a link, the clipboard) asks first, and "Always allow" isn't offered for sending or deleting. Scheduled runs start that way.
- **Protected files.** The assistant, tasks and automations can never read or change credentials, keys, cookies, the Keychain or browser profiles, even through a symlink or a shell command.
- **Stop everything** (menu bar, ⌃⌥⌘.) interrupts every session, denies what's waiting and pauses automations.
- **Activity log** (Settings → Activity): every action that changed something, every approval and every security decision, kept 30 days.
- Links that do something (`agentx://run/…`) need a secret token, so web pages can't trigger them. The app talks to agent-core only over pipes and opens no ports. The installed app runs only its own embedded, signed agent-core, and checks Anthropic's signature on the Claude Code engine before using it.

## How it fits together

```
AgentX.app (SwiftUI)  ── JSON lines over stdin/stdout ──  agent-core (Node + @anthropic-ai/claude-agent-sdk)  ──  Claude Code
```

| Path | What |
|---|---|
| `AgentXKit/Sources/AgentXKit/App` | Scenes (window, menu bar, settings), dashboard, `AppModel` |
| `AgentXKit/Sources/AgentXKit/Claude` | Chats section: Mac conversations and claude.ai (web view, chat-only) |
| `AgentXKit/Sources/AgentXKit/Sessions` | Session list, conversation view, tool cards, approvals, phone sync |
| `AgentXKit/Sources/AgentXKit/Core` | `AgentClient` (RPC to the sidecar), transcript parsing, models, `AppChannel` (installed vs Dev) |
| `AgentXKit/Sources/AgentXKit/Security` | Path guard, activity log, kill switch, link tokens, signature checks, Settings → Security |
| `agent-core/src` | Sidecar: `sessions.ts` (query / resume / approvals), `policy.ts` (security policy), `rpc.ts` (wire format) |
| `Config/` | `Base`, `Dev` and `Stable` build settings; your git-ignored `Local.xcconfig` for signing |
| `RemoteKit/` | The encrypted Mac ↔ iPhone link: handshake, pairing code, messages (shared by both apps) |
| `AgentXKit/Sources/AgentXKit/Phone` | The Mac side of the iPhone link and Settings → iPhone |
| `Phone/` | The iPhone app |
| `App/` | Thin Xcode app target, Info.plist, entitlements |
| `Widgets/` | WidgetKit extension (Claude, Mac Vitals, GitHub Activity) |
| `AgentXKit/Sources/AgentXShared` | The widget snapshot format, shared by the app and the widgets |
| `project.yml` | XcodeGen spec (the `.xcodeproj` is generated, not committed) |

### Chats: on this Mac, or claude.ai

The **Chats** section is the one place to talk to Claude. A switch at the top picks the side, and AgentX remembers the last one you used. **New Chat** (⇧⌘N) starts a chat on that side.

| | **On this Mac** | **claude.ai** |
|---|---|---|
| What it is | Claude Code with AgentX's Mac tools | claude.ai itself, in a web view |
| Can act on your Mac | Yes (see the table below) | No: it runs in Anthropic's cloud |
| History | Saved on your Mac as Claude Code sessions | Your claude.ai account, synced with the Claude app on your phone |
| Approvals and security policy | Yes | Handled by claude.ai |
| Also reachable from | ⌥Space launcher | Your phone and the web |

The two histories stay separate: claude.ai's conversations aren't available to apps, and AgentX doesn't use unofficial claude.ai APIs. Instead, you carry a chat across:

- **Continue on Mac** (claude.ai side): brings the chat, or just the text you selected in it, into a new conversation on this Mac, where Claude can use your Mac. It lands in the message box, and nothing is sent until you press Send. The text is read from the page you're looking at; nothing is fetched. Because a chat can quote web pages or files, that conversation starts as having read untrusted content (see [SECURITY.md](SECURITY.md)).
- **Continue in claude.ai** (⋯ menu of a Mac conversation): copies the conversation as Markdown and opens a new claude.ai chat to paste it into.
- **Delete** a Mac conversation with right-click → **Move to Trash…**, the Delete key, or the ⋯ menu. Its Claude Code transcript goes to the Trash, so you can put it back. Delete claude.ai chats in claude.ai's own menu.
- **Continue on phone** works for Mac conversations too, through Remote Control (see below). On your phone it continues as a plain Claude Code session, and AgentX's Mac tools stay on the Mac.

On the claude.ai side, a chat you send from your phone appears here; ⌘R pulls it in right away. AgentX only hosts the page. Apart from Continue on Mac, which reads the text on screen when you ask, it doesn't read or automate it. It keeps the side chat-only by hiding claude.ai's Code links, and it sends any Code page to Sessions. Old `agentx://chats` and `agentx://assistant` links open the matching side.

To sign in, enter your email in the email field. Google doesn't allow its sign-in button inside apps, but a Google account can sign in with its email address: Claude sends a code or link. If you get a link, use **More › Open a Sign-in Link…** to open it inside AgentX. You only need to sign in once.

### Phone sync for Claude Code sessions

**Continue on phone** runs the session in the Terminal tab with Claude Code's Remote Control (`claude --resume <id> --remote-control`). The session then appears in the Claude app on your phone under **Code**. Messages you send from your phone run on your Mac and show up in AgentX. The first time, answer Remote Control's one-time prompt in that terminal. Remote Control needs a Pro or higher plan, and it doesn't work with API keys.

### Mac tools and the launcher

Conversations **on this Mac** (in Chats) and the **⌥Space launcher** talk to Claude with Mac tools:

| Area | What it can do |
|---|---|
| Calendar | List events, create events |
| Reminders | List, create, complete reminders |
| Files | Spotlight search, show in Finder, move or rename, move to Trash |
| Apps | List open apps, open apps, files or URLs, quit apps |
| Shortcuts | List and run your Shortcuts |
| Settings | Dark mode, volume |
| Clipboard | Read and copy |
| Mail | Read recent mail, draft or send |
| Notes | Search and create notes |
| Messages | Send an iMessage |

Each tool is defined once in Swift (`AgentXKit/Sources/AgentXKit/MacTools`), with its parameters and a risk tier. AgentX sends the list to agent-core, which exposes it to Claude as an in-process MCP server (`mcp__agentx__*`) and hands each call back to the app. That way, macOS permission prompts name AgentX. Reading and creating run straight away and show up as cards in the chat. Sending, deleting, moving, quitting, running Shortcuts and reading the clipboard always ask first. **Settings › Assistant** lists every tool and its tier. AppleScript tools pass your text as arguments, never as script code.

In the launcher, type a question, or `/code <project> <task>` to start a coding session in a recent project. It opens empty each time; earlier launcher conversations are in **Chats › On this Mac**. The shortcut can be changed in **Settings › General**.

### Memory

Tell the assistant "remember that I prefer short replies" (or it notices something lasting) and it saves a note: one Markdown file per memory in `~/Library/Application Support/AgentX/Memory/`, plus a `MEMORY.md` index. Mac conversations, automations and messages from your iPhone get the notes in their instructions; coding sessions keep Claude Code's own CLAUDE.md memory.

- **Settings → Memory**: search, read, edit, add and delete memories. New ones Claude saved are marked **New** until you've looked. **Use memory** off means Claude neither sees nor saves them.
- Edit the files yourself if you like; AgentX picks up the changes. Deleting moves a file to `Memory/.trash`.
- Claude won't save passwords, keys, card or ID numbers (they're refused), and in a conversation that has read web pages or email, saving a memory asks you first.

### What's on your screen

When you press ⌥Space, AgentX looks at the app you were using: its window or document, your selected text (never a password field), the browser tab (Safari, Chrome, Edge, Brave, Arc, Vivaldi), or what's selected in Finder. Each shows as a chip under the launcher's field: click one to see exactly what it sends, or ✕ to leave it out. It goes with your message only when you ask about it ("summarize this", "what does this page say", "the selected text") or start from the **Ask** button; "what's my latest email?" goes on its own. In the conversation, your message notes what was shared ("Shared from Chrome: selected text …"). So "summarize this" or "reply to this" just works.

- Chrome and other Chromium browsers don't share selected text through Accessibility, so for them AgentX presses ⌘C in that app and puts your clipboard back right after. It never does this in password fields, Finder or password managers, and you can turn it off in Settings.
- **Look at Window** attaches a picture of that app's window to your next message, only when you click it. Claude can also ask to look (`screen_look`), and you approve each time.
- In a conversation, Claude can check what you're working on with `context_now`. Neither tool is available to scheduled runs.
- Screen context counts as untrusted content: a conversation that gets it asks before anything that could send data out.
- **Settings → Assistant → What's on your screen** chooses: include it, show it but include only when you click, or don't look. It also shows the two macOS permissions this uses, Accessibility (window titles and selections) and Screen Recording (pictures), and **Permissions** covers each browser and Finder.

### Launcher and pointer

- **Search like Spotlight:** as you type, the launcher shows the one thing you most likely mean: an app ("open safari", "quit mail"), a System Settings page, a sum ("12*4.5"), a web address, or a short list of apps and files when you're searching (Spotlight's index of your home folder). Return does it (or ⌘1–⌘9 for a row); ⌘Return sends what you typed to Claude instead. It looks like Spotlight: a floating search bar, with a panel under it only when there's something to show. Commands and questions show a single row; which engine handles them doesn't matter, and isn't shown.
- **Commands on this Mac, without Claude:** "add lunch with Enda tomorrow at 1", "remind me to call mum at 6", "volume 30", "dark mode", "what's on tomorrow". Apple's on-device model (Apple Intelligence) works out what you mean, macOS reads the date, and AgentX's own Mac tools do it, so nothing goes to Claude or uses your plan. Adding something, quitting an app or running a Shortcut waits for Return. Spoken commands work the same way. Needs Apple Intelligence turned on; questions and anything else go to Claude.
- **More commands on this Mac:** "latest PDF in downloads", "screenshots from this week", "invoice pdf" (straight from Spotlight, newest first, no AI; macOS asks once before AgentX can see your Desktop, Documents or Downloads folder), "email Enda saying I'll be 10 minutes late" (opens a Mail draft), "text mum I'm on my way" (asks before sending), "open safari new window", "new tab in chrome" (⌘N/⌘T in that app), "where's the share button?" (points at it, reading the window with Vision for web pages), and "add this to my calendar" with text selected. Names are looked up in Contacts.
- **After an answer** the launcher keeps working normally: apps, commands and files are still handled on your Mac, and only a question goes on to Claude as a follow-up.
- **Selected text, on this Mac:** the Ask button's Summarize, Explain, Fix the Writing, Make It Shorter, Reply and Translate are done by Apple's on-device model and Apple's Translation, as are questions you type about a selection. A question about the window in front ("what does this error say?") reads the window's text with Vision and answers here too. Each answer has Copy, Replace Selection and Read Aloud, plus **Ask Claude** if you want more.
- **Elsewhere without Claude:** new Mac conversations get short titles written on your Mac, the Today card sums up your day in a line, and Automations can run a **Briefing on this Mac** (your calendar, what's due and unread mail, written by Apple Intelligence and shown as a notification). Settings → Assistant counts what the launcher did on your Mac and what went to Claude.
- **Talk instead of typing:** hold the launcher shortcut, speak, and let go to send (or click the microphone). Speech is recognized on your Mac; only the words go to Claude. What's on screen goes along only when you ask about it ("summarize this"). Turn on **Read answers aloud** in Settings to hear replies.
- **Select text, then click Ask:** select text in any app and a small **Ask** button appears by the pointer. It opens the launcher right there with your selection and quick actions: Explain, Summarize, Fix the Writing, Make It Shorter, Reply.
- **Use the answer:** under an answer, **Copy** it, **Replace Selection** (pastes it over the text you selected, in that app), or **Read Aloud**.
- **Connected tools:** your claude.ai connectors (Google Calendar, Gmail, Drive…) work in Mac conversations too. Tools that only read run without asking; ones that send, create or delete ask first (Settings → Security).
- **Claude points at things:** ask "where's the export button?" and AgentX moves a pointer onto it and rings it (`screen_point`). It finds things by their label through Accessibility, or by a spot in a picture of the window for web pages. It never clicks.
- **Settings → Assistant → Launcher and pointer** sets where the launcher opens (the middle of the screen or next to the pointer) and turns each of these on or off.

### Reach it from anywhere

- **Siri, Shortcuts and Spotlight:** AgentX's actions are in the Shortcuts app and in Spotlight, and Siri knows these phrases: "Ask AgentX", "Run Morning brief in AgentX" (any automation), "Ask Claude in AgentX", "Open AgentX", "Stop everything in AgentX".
  - **Ask AgentX** does a request as if you'd typed it in the launcher and pressed Return: on your Mac when it can, Claude when it needs to.
  - **Get an Answer from Claude** returns the answer as text, for Shortcuts that use it. Text from a Shortcut counts as untrusted, so sending data out asks first.
  - The others: **Open the AgentX Launcher**, **Run Automation**, **Start a Coding Session**, **Open AgentX** and **Stop Everything**.
- **Right-click → Services** in any app:
  - **Ask AgentX** opens the launcher with the selected text and the quick actions.
  - **Summarize with AgentX** summarizes on your Mac.
  - **Ask AgentX About These Files** works in Finder.
- **Control Center** (Edit Controls → AgentX): **Ask AgentX**, **Run Automation** (you pick which), **Approvals** (how many are waiting) and **Stop Everything**. They can go in the menu bar too.
- **Links:** `agentx://launcher?q=…` opens the launcher over the app you're in, with the text typed in (never sent). Links that do something (`agentx://run/<id>`, `agentx://stop`) need AgentX's secret token, which only its own widgets and controls have.

### iPhone companion

The AgentX iPhone app watches and controls your Mac:

- **Mac:** vitals, plan usage, what's running, today's events and reminders (tap the circle or swipe to tick one off; tap for details), automations, and **Stop Everything**.
- **Approvals:** what's waiting for your OK, with the full details. Allow and Deny need Face ID.
- **Chats:** your Mac conversations (and running coding sessions, view-only). Message Claude on your Mac and watch the reply stream in.
- **Activity:** the Mac's activity log.

To set it up:

1. Set your team in `Config/Local.xcconfig` (see the Signing note above).
2. Connect your iPhone by cable once, turn on **Developer Mode** (Settings → Privacy & Security), and run `scripts/run-phone.sh`. The first time, trust your developer certificate on the iPhone (Settings → General → VPN & Device Management).
3. On the Mac: **Settings → iPhone → Pair an iPhone**. On the iPhone: **Scan Pairing Code**. Then click **Allow** on the Mac.

The phone finds the Mac on your Wi-Fi. Away from home, use Tailscale on both; the pairing code includes the Mac's Tailscale address. With a free Apple account, iOS stops the app after 7 days (run `scripts/run-phone.sh` again), and there are no push notifications: approvals show up when you open the app. [SECURITY.md](SECURITY.md) (row 11) covers how the link is protected.

### Plan usage and widgets

AgentX shows your Claude plan's usage (the 5-hour session window, the weekly limit, and when each resets) on the dashboard and in the menu bar. The numbers come from the Agent SDK's usage call, the same data as `/usage`. It refreshes every 10 minutes and shortly after each Claude reply. Automations skip their runs when usage reaches 90%.

**Desktop widgets** (right-click the desktop, choose **Edit Widgets**, and search for AgentX):

| Widget | Shows |
|---|---|
| Claude | Plan usage, what's running, and approvals waiting for you |
| Mac Vitals | CPU, memory, disk and battery |
| GitHub Activity | Your contribution calendar and streak |

The widgets read a snapshot that AgentX writes to `~/Library/Application Support/AgentX/widget-snapshot.json` every 15 minutes and after important changes. The sandboxed extension can only read that folder. Clicking a widget opens the matching section (`agentx://dashboard`, `agentx://system`, `agentx://github`). AgentX Dev's widgets and controls use its own folder and `agentx-dev://`.

### Automations

**Automations** are Claude tasks that run on a schedule: daily at a time, on chosen weekdays, or every few hours. Each one runs either as the Assistant (with the Mac tools) or as a coding session in a folder. Three starters come turned off:

| Starter | When | What it does |
|---|---|---|
| Morning brief | Weekdays 8:00 | Today's calendar, reminders and unread mail |
| Repo check | Daily 18:00 | Uses `repos_status` to list local repos with uncommitted or unpushed work |
| Tidy Downloads | Sundays 10:00 | Proposes moves, and each one needs your OK |

How runs behave:
- The scheduler runs inside AgentX. It checks every 30 seconds and again after the Mac wakes. **Open AgentX at login** keeps it available.
- A run missed in the last 12 hours happens once on wake. Older misses are recorded as skipped.
- Unattended runs never approve risky steps. They send a notification with Allow and Deny buttons, and deny the step after 10 minutes without an answer.
- Each run ends with a short summary, shown as a notification, on the dashboard and in the run history, with its full conversation one click away.
- Runs stop after 20 minutes, and are skipped when your plan usage is at 90% or more.
- Automations and run history are stored in `~/Library/Application Support/AgentX/`.

### GitHub

The **GitHub** section and a dashboard card show your contribution calendar (the green squares), streaks, and every repository: language, stars, open issues and PRs, last push, and, for repos cloned on this Mac, uncommitted changes and unpushed commits. AgentX reads GitHub through the GitHub CLI (`gh`) you're already signed in to, so it never sees or stores a token. Local status comes from `git` in your project folders (`~/Projects`, `~/Developer`, … and folders you've used with Claude Code). Double-click a repo to open it on GitHub. Right-click it for Show in Finder, New Session Here or Copy URL. Data refreshes when shown, at most every 10 minutes, or with the refresh button.

### System

The System section reads the same kernel counters Activity Monitor uses: CPU ticks per core, VM statistics (memory used = app + wired + compressed), swap, memory pressure, IOKit battery data, interface byte counters and libproc per-process usage. It samples every 2 seconds, but only while the System section, the dashboard card or the menu bar is showing. **Ask Claude** starts a Claude Code session in your home folder with the current snapshot. Claude asks before running any command.

### Keeping it light

AgentX keeps idle costs low and gives memory back when it isn't needed:
- A Claude Code process uses about 300 MB. One that has been idle for 10 minutes is closed, and your next message resumes the session.
- The claude.ai page is released after 15 minutes out of view. Your sign-in is kept.
- Only the 6 most recently viewed transcripts stay in memory. Tool output over 40 KB keeps its first 20,000 characters in memory (the full text stays in the session file).
- When another app adds to a session you're viewing, only the new messages are fetched.
- Messages from agent-core are parsed with `JSONSerialization`, off the main thread. That's 4.6× faster than the earlier `Codable` path on an 11 MB transcript.
- Tool paths are cached between launches, so the engine is ready in about 170 ms instead of 700 ms. One short-lived Claude Code process reads both your account and your plan usage at startup.
- The Mac vitals are sampled only while something shows them.

### Sessions open in other apps

AgentX continues a session in place, never as a fork, and always from its newest message, whichever app wrote it. Before it sends, it checks whether the session has moved on, for example because you kept going in Terminal or the Claude app. If it has, AgentX reloads and resumes from there.

A banner shows when another app has the session open, using Claude Code's registry of running sessions in `~/.claude/sessions`. That app keeps its own copy of the conversation in memory, so it won't show messages sent from AgentX until you reopen the session there. Use one app at a time; whichever one sends last becomes the newest point.

Every process AgentX starts (agent-core, Claude Code, the Terminal tab) gets a short allowlist of environment variables plus your login shell's PATH. Nothing inherited from whatever launched AgentX gets through, such as another Claude Code session's id, API proxy or sockets.

## Tests

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path AgentXKit
```

```bash
cd agent-core && npm test && npx tsc --noEmit
```

```bash
node agent-core/scripts/smoke.ts   # read-only check against the real SDK, no quota used
```

## Roadmap

- [x] M0: app shell, menu bar, settings, agent engine
- [x] M1: all Claude Code sessions, live chat, approvals, diffs, terminal tab
- [x] Chats (claude.ai, synced with your phone) and phone sync for sessions
- [x] GitHub: contribution calendar, repos, and local clone status
- [x] M2: system dashboard (CPU, memory, disk, battery, network, top processes, Ask Claude)
- [x] M3: Mac assistant (Calendar, Files, Apps, Mail…) and ⌥Space launcher
- [x] M4: automations (scheduled Claude tasks with notifications)
- [x] M5: plan-usage meter, desktop widgets
- [x] M6: installable app next to AgentX Dev, security policy (untrusted content, protected files, kill switch, activity log)
- [x] One Chats section: Mac conversations and claude.ai side by side, with hand-off both ways
- [x] iPhone companion: monitor, approve with Face ID, Stop Everything, message Claude on your Mac (encrypted link, QR pairing)
- [x] M7: memory (Settings → Memory) and context (what's on screen, selection, browser tab, Look at Window)
- [x] M8: Siri, Shortcuts, Spotlight, right-click Services, voice, Control Center
- [ ] M9: proactive triggers (files, calendar, apps, battery, mail, GitHub)
- [ ] M10: long-running tasks with check-ins
- [ ] M11: operating other apps through Accessibility
