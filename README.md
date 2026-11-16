# AgentX

A native macOS command center for Claude. It has your regular Claude chats (synced with the Claude app on your phone), plus Claude Code sessions you can run, approve and continue from your phone. Still to come: a Mac assistant, a system dashboard and automations. Powered by the Claude Agent SDK, using the Claude Code login on this Mac.

## Run it

```bash
scripts/run-dev.sh
```

That generates the Xcode project, builds an optimized (Release) AgentX and its desktop widgets with `xcodebuild`, installs the app at `build/AgentX.app`, and opens it. Use `scripts/run-dev.sh --debug` for a Debug build to attach the debugger to. To work in Xcode instead:

```bash
xcodegen generate && open AgentX.xcodeproj
```

The first time, Xcode asks you to trust SwiftTerm's build plugin. Click **Trust & Enable**. `swift build --package-path AgentXKit` still builds and tests all the app code quickly, but without the widgets.

**Requirements:** macOS 26+, Xcode, XcodeGen (`brew install xcodegen`), Node 22.18+, and `npm install` in `agent-core/`. You also need a Claude Code login: in AgentX, use **Sign In…**, then type `/login`.

## How it fits together

```
AgentX.app (SwiftUI)  ── JSON lines over stdin/stdout ──  agent-core (Node + @anthropic-ai/claude-agent-sdk)  ──  Claude Code
```

| Path | What |
|---|---|
| `AgentXKit/Sources/AgentXKit/App` | Scenes (window, menu bar, settings), dashboard, `AppModel` |
| `AgentXKit/Sources/AgentXKit/Chats` | Chats section: claude.ai in a web view, chat-only |
| `AgentXKit/Sources/AgentXKit/Sessions` | Session list, conversation view, tool cards, approvals, phone sync |
| `AgentXKit/Sources/AgentXKit/Core` | `AgentClient` (RPC to the sidecar), transcript parsing, models |
| `agent-core/src` | Sidecar: `sessions.ts` (query / resume / approvals), `rpc.ts` (wire format) |
| `App/` | Thin Xcode app target, Info.plist, entitlements |
| `Widgets/` | WidgetKit extension (Claude, Mac Vitals, GitHub Activity) |
| `AgentXKit/Sources/AgentXShared` | The widget snapshot format, shared by the app and the widgets |
| `project.yml` | XcodeGen spec (the `.xcodeproj` is generated, not committed) |

### Chats

Regular Claude chats have no public API, so the Chats section runs claude.ai itself. It's the same account and the same conversations as the Claude app on your phone: send a chat there and it's here (⌘R pulls it in right away). AgentX only hosts the page. It doesn't read or automate it. It keeps the section chat-only by hiding claude.ai's Code links, and it sends any Code page to Sessions.

To sign in, enter your email in the email field. Google doesn't allow its sign-in button inside apps, but a Google account can sign in with its email address: Claude sends a code or link. If you get a link, use **More › Open a Sign-in Link…** to open it inside AgentX. You only need to sign in once.

### Phone sync for Claude Code sessions

**Continue on phone** runs the session in the Terminal tab with Claude Code's Remote Control (`claude --resume <id> --remote-control`). The session then appears in the Claude app on your phone under **Code**. Messages you send from your phone run on your Mac and show up in AgentX. The first time, answer Remote Control's one-time prompt in that terminal. Remote Control needs a Pro or higher plan, and it doesn't work with API keys.

### Assistant and launcher

The **Assistant** section and the **⌥Space launcher** talk to Claude with Mac tools:

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

In the launcher, type a question, or `/code <project> <task>` to start a coding session in a recent project. The shortcut can be changed in **Settings › General**.

### Plan usage and widgets

AgentX shows your Claude plan's usage (the 5-hour session window, the weekly limit, and when each resets) on the dashboard and in the menu bar. The numbers come from the Agent SDK's usage call, the same data as `/usage`. It refreshes every 10 minutes and shortly after each Claude reply. Automations skip their runs when usage reaches 90%.

**Desktop widgets** (right-click the desktop, choose **Edit Widgets**, and search for AgentX):

| Widget | Shows |
|---|---|
| Claude | Plan usage, what's running, and approvals waiting for you |
| Mac Vitals | CPU, memory, disk and battery |
| GitHub Activity | Your contribution calendar and streak |

The widgets read a snapshot that AgentX writes to `~/Library/Application Support/AgentX/widget-snapshot.json` every 15 minutes and after important changes. The sandboxed extension can only read that folder. Clicking a widget opens the matching section (`agentx://dashboard`, `agentx://system`, `agentx://github`).

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
- The Chats web page is released after 15 minutes out of view. Your sign-in is kept.
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
