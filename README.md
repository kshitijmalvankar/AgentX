# AgentX

A native macOS command center for Claude. It has your regular Claude chats (synced with the Claude app on your phone), plus Claude Code sessions you can run, approve and continue from your phone. Still to come: a Mac assistant, a system dashboard and automations. Powered by the Claude Agent SDK, using the Claude Code login on this Mac.

## Run it

```bash
scripts/run-dev.sh
```

That builds with SwiftPM, wraps the binary in `build/AgentX.app`, and opens it. Or use Xcode:

```bash
xcodegen generate && open AgentX.xcodeproj
```

The first time, Xcode asks you to trust SwiftTerm's build plugin. Click **Trust & Enable**.

**Requirements:** macOS 26+, Xcode (its toolchain has the SwiftUI macros), Node 22.18+ and `npm install` in `agent-core/`. You also need a Claude Code login: in AgentX, use **Sign In…**, then type `/login`.

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

### GitHub

The **GitHub** section and a dashboard card show your contribution calendar (the green squares), streaks, and every repository: language, stars, open issues and PRs, last push, and, for repos cloned on this Mac, uncommitted changes and unpushed commits. AgentX reads GitHub through the GitHub CLI (`gh`) you're already signed in to, so it never sees or stores a token. Local status comes from `git` in your project folders (`~/Projects`, `~/Developer`, … and folders you've used with Claude Code). Double-click a repo to open it on GitHub. Right-click it for Show in Finder, New Session Here or Copy URL. Data refreshes when shown, at most every 10 minutes, or with the refresh button.

### System

The System section reads the same kernel counters Activity Monitor uses: CPU ticks per core, VM statistics (memory used = app + wired + compressed), swap, memory pressure, IOKit battery data, interface byte counters and libproc per-process usage. It samples every 2 seconds, but only while the System section, the dashboard card or the menu bar is showing. **Ask Claude** starts a Claude Code session in your home folder with the current snapshot. Claude asks before running any command.

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
- [ ] M4: automations
- [ ] M5: plan-usage meter, widgets
