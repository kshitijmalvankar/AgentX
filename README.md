# AgentX

A native macOS command center for Claude: run and watch Claude Code sessions, approve what they do, and (coming soon) a Mac assistant, system dashboard and automations. Powered by the Claude Agent SDK, using the Claude Code login on this Mac.

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
| `AgentXKit/Sources/AgentXKit/Sessions` | Session list, conversation view, tool cards, approvals |
| `AgentXKit/Sources/AgentXKit/Core` | `AgentClient` (RPC to the sidecar), transcript parsing, models |
| `agent-core/src` | Sidecar: `sessions.ts` (query / resume / approvals), `rpc.ts` (wire format) |
| `App/` | Thin Xcode app target, Info.plist, entitlements |
| `project.yml` | XcodeGen spec (the `.xcodeproj` is generated, not committed) |

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
- [ ] M2: system dashboard
- [ ] M3: Mac assistant (Calendar, Files, Apps, Mail…) and ⌥Space launcher
- [ ] M4: automations
- [ ] M5: plan-usage meter, widgets
