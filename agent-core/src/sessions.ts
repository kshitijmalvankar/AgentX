// Claude Code sessions, driven through the Agent SDK.
//
// - History: listSessions / getSessionMessages read ~/.claude/projects, so
//   sessions started in Terminal, VS Code or the Claude app show up too.
// - Live sessions: one `query()` per open conversation, in streaming-input
//   mode, so follow-up messages go to the same Claude Code process.
// - Approvals: `canUseTool` asks the Swift app, which shows Allow / Deny /
//   Always allow.
// - One main line: resuming always continues the session itself (never a
//   fork). If another app (Terminal, the Claude app) adds messages while
//   AgentX's process is idle, `session.isStale` reports it so the app can
//   restart from the newest message instead of writing a side branch.
// - Security: assistant and unattended sessions run under policy.ts (taint,
//   egress guard, path guard, rate limit) through PreToolUse/PostToolUse hooks.

import { randomUUID } from "node:crypto";
import { homedir } from "node:os";
import {
  query,
  listSessions,
  getSessionMessages,
  getSessionInfo,
  type CanUseTool,
  type PermissionMode,
  type PermissionResult,
  type Query,
  type SDKMessage,
  type SDKUserMessage,
  type McpServerConfig,
  type HookCallbackMatcher,
  type HookEvent,
  type PreToolUseHookInput,
  type PostToolUseHookInput,
} from "@anthropic-ai/claude-agent-sdk";
import { AsyncQueue } from "./asyncQueue.ts";
import { askTierTools, autoAllowedTools, macToolsServer, toolDefinitions, untrustedToolSources } from "./macTools.ts";
import { isReadOnlyConnectorTool, POLICY_INSTRUCTIONS, SessionPolicy, untrustedReminder } from "./policy.ts";
import { handle, log, notify, request } from "./rpc.ts";

/** Load the same settings Claude Code uses: ~/.claude, project .claude/, and local overrides. */
const ALL_SETTINGS = ["user", "project", "local"] as const;

export type SessionState = "starting" | "running" | "waiting" | "idle" | "ended";

/** Read-only built-ins the assistant may use without asking (WebFetch asks once the session is tainted). */
const ASSISTANT_READ_TOOLS = ["Read", "Glob", "Grep", "WebSearch", "WebFetch"];

/** Built-ins worth an activity-log line when they run. */
const LOGGED_BUILTINS = new Set(["Write", "Edit", "MultiEdit", "NotebookEdit", "Bash", "WebFetch"]);

/** A picture attached to a message (e.g. a window you chose to share). */
export type ImageInput = { mediaType: string; data: string };

const IMAGE_TYPES = new Set(["image/png", "image/jpeg", "image/gif", "image/webp"]);
/** About 6 MB of picture per image, base64. */
const MAX_IMAGE_BASE64 = 8 * 1024 * 1024;

/** A user message's content: images first, then the text. */
/**
 * The app sends JSON null for options it leaves unset. The SDK fills in its
 * defaults only for missing ones (`allowedTools = []`), so a null reached
 * `allowedTools.filter` and every coding session failed to start. Drop them.
 */
export function withoutNulls<T extends object>(params: T): T {
  return Object.fromEntries(Object.entries(params).filter(([, value]) => value !== null)) as T;
}

export function userContent(text: string, images: ImageInput[] = []): string | unknown[] {
  if (images.length === 0) return text;
  if (images.length > 4) throw new Error("At most 4 images per message.");
  const blocks: unknown[] = images.map((image) => {
    if (!IMAGE_TYPES.has(image.mediaType)) throw new Error(`Unsupported image type ${image.mediaType}.`);
    if (typeof image.data !== "string" || image.data.length === 0 || image.data.length > MAX_IMAGE_BASE64) {
      throw new Error("Image is empty or too large.");
    }
    return { type: "image", source: { type: "base64", media_type: image.mediaType, data: image.data } };
  });
  blocks.push({ type: "text", text });
  return blocks;
}

/** Set by the app (`security.configure`); applies to sessions started afterwards. */
type SecurityConfig = {
  /** Paths the user allowed despite the path guard (Settings → Security). */
  pathExceptions: string[];
  /** Folders whose files don't taint a session (your projects). */
  trustedRoots: string[];
  /** The Claude Code binary AgentX verified (Anthropic's signature); used instead of the SDK's lookup. */
  claudePath?: string;
  /** Read-only connector tools allowed to run after untrusted content. Applies to running sessions too. */
  trustedTools: string[];
  /** All connector tools that only read run without asking. Applies to running sessions too. */
  trustConnectorReads: boolean;
};
const security: SecurityConfig = { pathExceptions: [], trustedRoots: [], trustedTools: [], trustConnectorReads: false };
let trustedToolSet: ReadonlySet<string> = new Set();

type StartParams = {
  /** "assistant" adds the Mac tools (mcp__agentx__*) and reads across your home folder. */
  kind?: "coding" | "assistant";
  cwd: string;
  prompt?: string;
  resume?: string;
  model?: string;
  permissionMode?: PermissionMode;
  /** Extra system-prompt text (used by the Mac assistant and automations). */
  appendSystemPrompt?: string;
  /** Extra MCP servers (the in-process "agentx" Mac tools server). */
  mcpServers?: Record<string, McpServerConfig>;
  allowedTools?: string[];
  /** Started by a schedule or trigger: starts tainted, no attended-only tools, rate-limited. */
  unattended?: boolean;
  /** Start as having read untrusted content (text carried over from claude.ai, a resumed tainted conversation). */
  taint?: string;
  /** Pictures sent with the first prompt. */
  images?: ImageInput[];
};

type PermissionAnswer = { behavior: "allow" | "allowAlways" | "deny"; message?: string };

class LiveSession {
  readonly handle = randomUUID();
  sessionId: string | undefined;
  state: SessionState = "starting";
  private readonly input = new AsyncQueue<SDKUserMessage>();
  private readonly abort = new AbortController();
  private readonly q: Query;
  readonly params: StartParams;
  /** Message ids this process knows about: the newest one when it resumed, plus everything it produced. */
  private readonly known = new Set<string>();
  private readonly baseline: Promise<void>;
  /** Security policy for assistant and unattended sessions (coding sessions keep Claude Code's own rules). */
  readonly policy: SessionPolicy | undefined;
  /** tool_use_id → why the policy asked, for the approval card. */
  private readonly askReasons = new Map<string, string>();

  constructor(params: StartParams) {
    this.params = params;
    this.sessionId = params.resume;
    this.baseline = params.resume ? this.rememberNewest(params.resume) : Promise.resolve();
    const assistant = params.kind === "assistant";
    const unattended = params.unattended ?? false;
    this.policy = assistant || unattended
      ? new SessionPolicy({
          home: homedir(),
          cwd: params.cwd,
          trustedRoots: security.trustedRoots,
          pathExceptions: security.pathExceptions,
          unattended,
          initialTaint: params.taint,
          untrustedTools: untrustedToolSources(),
          askTierTools: askTierTools(),
          trustedTools: () => trustedToolSet,
          trustConnectorReads: () => security.trustConnectorReads,
        })
      : undefined;
    const append = [params.appendSystemPrompt, this.policy ? POLICY_INSTRUCTIONS : undefined].filter(Boolean).join("\n\n") || undefined;
    this.q = query({
      prompt: this.input,
      options: {
        cwd: params.cwd,
        resume: params.resume,
        model: params.model,
        permissionMode: params.permissionMode ?? "default",
        settingSources: [...ALL_SETTINGS],
        systemPrompt: { type: "preset", preset: "claude_code", append },
        includePartialMessages: true,
        canUseTool: this.canUseTool,
        hooks: this.policy ? this.policyHooks(this.policy) : undefined,
        pathToClaudeCodeExecutable: security.claudePath,
        mcpServers: assistant ? { ...params.mcpServers, agentx: macToolsServer(this.handle, { unattended }) } : params.mcpServers,
        allowedTools: assistant ? [...(params.allowedTools ?? []), ...autoAllowedTools({ unattended }), ...ASSISTANT_READ_TOOLS] : params.allowedTools,
        additionalDirectories: assistant ? [homedir()] : undefined,
        abortController: this.abort,
        stderr: (data) => log(`[claude ${this.handle.slice(0, 8)}]`, data.trimEnd()),
      },
    });
    void this.pump();
  }

  /**
   * The policy's hooks. PreToolUse runs before Claude Code's own permission
   * rules, so "ask" and "deny" hold even if a settings file allows the tool.
   * It fails closed: if the hook itself breaks, the tool call is blocked.
   */
  private policyHooks(policy: SessionPolicy): Partial<Record<HookEvent, HookCallbackMatcher[]>> {
    return {
      PreToolUse: [{
        onFailure: "block",
        hooks: [async (input) => {
          const i = input as PreToolUseHookInput;
          const d = policy.beforeTool(i.tool_name, i.tool_input);
          if (d.decision === "allow-default") return {};
          // Trusted connector tool: allow outright, so Claude Code doesn't ask either.
          if (d.decision === "allow") {
            return { hookSpecificOutput: { hookEventName: "PreToolUse", permissionDecision: "allow", permissionDecisionReason: d.reason } };
          }
          this.activity({ kind: "policy", action: d.decision === "deny" ? "blocked" : "asked", tool: i.tool_name, detail: d.reason });
          if (d.decision === "ask") this.askReasons.set(i.tool_use_id, d.reason);
          return { hookSpecificOutput: { hookEventName: "PreToolUse", permissionDecision: d.decision, permissionDecisionReason: d.reason } };
        }],
      }],
      PostToolUse: [{
        hooks: [async (input) => {
          const i = input as PostToolUseHookInput;
          this.logTool(i.tool_name, i.tool_input);
          const source = policy.untrustedSource(i.tool_name, i.tool_input);
          const newTaint = policy.afterTool(i.tool_name, i.tool_input);
          if (newTaint) {
            notify("session.policy", { handle: this.handle, sessionId: this.sessionId, taint: newTaint });
            this.activity({ kind: "policy", action: "tainted", tool: i.tool_name, detail: newTaint });
          }
          // Mac tool results are framed as untrusted in macTools.ts; remind Claude about built-in ones.
          if (source && !i.tool_name.startsWith("mcp__")) {
            return { hookSpecificOutput: { hookEventName: "PostToolUse", additionalContext: untrustedReminder(source) } };
          }
          return {};
        }],
      }],
    };
  }

  /** One line for the app's activity log. */
  activity(entry: { kind: "tool" | "policy"; action: string; tool: string; detail?: string }): void {
    notify("activity", { ...entry, handle: this.handle, sessionId: this.sessionId, unattended: this.params.unattended ?? false });
  }

  /** Log tools that change something or reach the network (reads aren't logged). */
  private logTool(name: string, input: unknown): void {
    const mac = name.startsWith("mcp__agentx__") ? toolDefinitions().find((d) => `mcp__agentx__${d.name}` === name) : undefined;
    if (!(LOGGED_BUILTINS.has(name) || (mac && mac.risk !== "read"))) return;
    this.activity({ kind: "tool", action: "ran", tool: name, detail: summarizeInput(input) });
  }

  /** Forward every SDK message to the app and keep our state in sync. */
  private async pump(): Promise<void> {
    let error: string | undefined;
    try {
      for await (const message of this.q) {
        this.observe(message);
        notify("session.event", { handle: this.handle, message });
      }
    } catch (err) {
      error = err instanceof Error ? err.message : String(err);
      log(`session ${this.handle.slice(0, 8)} failed:`, error);
    } finally {
      this.setState("ended");
      live.delete(this.handle);
      notify("session.ended", { handle: this.handle, sessionId: this.sessionId, error });
    }
  }

  private observe(message: SDKMessage): void {
    if ((message.type === "assistant" || message.type === "user" || message.type === "system") && "uuid" in message && typeof message.uuid === "string") {
      this.known.add(message.uuid);
    }
    if (message.type === "system" && message.subtype === "init") {
      this.sessionId = message.session_id;
      notify("session.started", { handle: this.handle, sessionId: message.session_id, model: message.model, permissionMode: message.permissionMode });
    } else if (message.type === "result") {
      this.setState("idle");
    }
  }

  private setState(state: SessionState): void {
    if (this.state === state) return;
    this.state = state;
    notify("session.state", { handle: this.handle, sessionId: this.sessionId, state });
  }

  private async newestMessageId(sessionId: string): Promise<string | undefined> {
    const messages = await getSessionMessages(sessionId, { dir: this.params.cwd });
    return messages.at(-1)?.uuid;
  }

  private async rememberNewest(sessionId: string): Promise<void> {
    try {
      const newest = await this.newestMessageId(sessionId);
      if (newest) this.known.add(newest);
    } catch {
      // History unreadable: staleness checks will simply report "not stale".
    }
  }

  /**
   * True when the session's newest message came from somewhere else (another
   * app continued it while this process sat idle). Only checked between turns.
   */
  async isStale(): Promise<boolean> {
    if (!this.sessionId || this.state !== "idle") return false;
    await this.baseline;
    if (this.known.size === 0) return false;
    const newest = await this.newestMessageId(this.sessionId);
    const stale = !!newest && !this.known.has(newest);
    if (stale) log(`session ${this.handle.slice(0, 8)}: newest message ${newest!.slice(0, 8)} came from another app`);
    return stale;
  }

  send(text: string, images: ImageInput[] = []): void {
    const content = userContent(text, images);
    this.input.push({
      type: "user",
      message: { role: "user", content },
      parent_tool_use_id: null,
      origin: { kind: "human" },
    } as SDKUserMessage);
    this.setState("running");
  }

  /** The app attached something untrusted mid-conversation (what's on screen): guard egress from now on. */
  markTainted(reason: string): void {
    if (!this.policy || this.policy.taint || !reason.trim()) return;
    this.policy.taint = reason.trim();
    notify("session.policy", { handle: this.handle, sessionId: this.sessionId, taint: this.policy.taint });
    this.activity({ kind: "policy", action: "tainted", tool: "context", detail: this.policy.taint });
  }

  /** Plan usage through this session's own process (no extra process needed). */
  usage() {
    return this.q.usage_EXPERIMENTAL_MAY_CHANGE_DO_NOT_RELY_ON_THIS_API_YET({ skipBehaviors: true });
  }

  async interrupt(): Promise<void> {
    await this.q.interrupt();
  }

  async setModel(model?: string): Promise<void> {
    await this.q.setModel(model);
  }

  async setPermissionMode(mode: PermissionMode): Promise<void> {
    await this.q.setPermissionMode(mode);
  }

  close(): void {
    this.input.close();
    this.q.close();
  }

  /** Called by Claude Code only when a tool call needs the user's OK. */
  private canUseTool: CanUseTool = async (toolName, input, opts) => {
    const policyReason = this.askReasons.get(opts.toolUseID);
    this.askReasons.delete(opts.toolUseID);
    if (!policyReason && this.policy?.isTrusted(toolName)) {
      return { behavior: "allow", decisionClassification: "user_permanent" };
    }
    let recentRiskyActions = 0;
    if (this.policy) {
      const over = this.policy.noteRiskyAction();
      recentRiskyActions = this.policy.recentRiskyActions();
      if (over && this.params.unattended) {
        notify("session.policy", { handle: this.handle, sessionId: this.sessionId, rateLimited: true });
        this.activity({ kind: "policy", action: "rateLimited", tool: toolName, detail: `${recentRiskyActions} risky actions in 10 minutes` });
        return {
          behavior: "deny",
          message: "AgentX stopped this run: it asked for too many risky actions in a short time. The user will review it.",
          interrupt: true,
        };
      }
    }
    this.setState("waiting");
    try {
      const answer = await request<PermissionAnswer>(
        "permission.request",
        {
          handle: this.handle,
          sessionId: this.sessionId,
          cwd: this.params.cwd,
          toolName,
          input,
          toolUseID: opts.toolUseID,
          title: opts.title,
          displayName: opts.displayName,
          description: opts.description,
          decisionReason: opts.decisionReason,
          blockedPath: opts.blockedPath,
          defaultToNo: opts.defaultToNo ?? false,
          canAlwaysAllow: (opts.suggestions?.length ?? 0) > 0 && !opts.suppressAlwaysAllowRule && !policyReason
            && (this.policy?.mayAlwaysAllow(toolName) ?? true),
          // A read-only connector tool the policy asked about: the app can trust it from now on.
          canTrustTool: policyReason !== undefined && (this.policy?.mayTrust(toolName) ?? false),
          policyReason,
          taint: this.policy?.taint,
          recentRiskyActions,
          unattended: this.params.unattended ?? false,
        },
        opts.signal,
      );
      return toPermissionResult(answer, opts.suggestions);
    } catch {
      return { behavior: "deny", message: "The permission prompt was cancelled." };
    } finally {
      // Either way Claude carries on with the turn (running the tool or reacting to the denial).
      if (this.state === "waiting") this.setState("running");
    }
  };
}

/** A short, single-line version of a tool's input for the activity log. */
function summarizeInput(input: unknown): string {
  if (!input || typeof input !== "object") return "";
  const r = input as Record<string, unknown>;
  const main = r.command ?? r.file_path ?? r.url ?? r.path ?? r.notebook_path;
  const text = typeof main === "string" ? main : JSON.stringify(input);
  return text.replace(/\s+/g, " ").slice(0, 300);
}

function toPermissionResult(answer: PermissionAnswer, suggestions: Parameters<CanUseTool>[2]["suggestions"]): PermissionResult {
  switch (answer.behavior) {
    case "allow":
      return { behavior: "allow", decisionClassification: "user_temporary" };
    case "allowAlways":
      return { behavior: "allow", updatedPermissions: suggestions, decisionClassification: "user_permanent" };
    default:
      return {
        behavior: "deny",
        message: answer.message?.trim() || "The user declined this action.",
        decisionClassification: "user_reject",
      };
  }
}

const live = new Map<string, LiveSession>();

function getLive(handleId: string): LiveSession {
  const s = live.get(handleId);
  if (!s) throw new Error("That session is no longer running.");
  return s;
}

export function closeAllSessions(): void {
  for (const s of live.values()) s.close();
  live.clear();
}

/**
 * Start a throwaway Claude Code process just long enough to read account and
 * model info. No prompt is sent, so this uses no plan quota.
 */
async function withProbe<T>(fn: (q: Query) => Promise<T>): Promise<T> {
  const input = new AsyncQueue<SDKUserMessage>();
  const q = query({
    prompt: input,
    options: { cwd: homedir(), settingSources: [...ALL_SETTINGS], persistSession: false },
  });
  try {
    return await fn(q);
  } finally {
    input.close();
    q.close();
  }
}

export function registerSessionHandlers(): void {
  // Security settings from the app (path exceptions, trusted folders, the verified Claude Code binary).
  handle("security.configure", (p: Partial<SecurityConfig>) => {
    if (Array.isArray(p.pathExceptions)) security.pathExceptions = p.pathExceptions.filter((x) => typeof x === "string");
    if (Array.isArray(p.trustedRoots)) security.trustedRoots = p.trustedRoots.filter((x) => typeof x === "string");
    if (typeof p.claudePath === "string" || p.claudePath === null) security.claudePath = p.claudePath ?? undefined;
    if (Array.isArray(p.trustedTools)) {
      security.trustedTools = p.trustedTools.filter((x) => typeof x === "string" && isReadOnlyConnectorTool(x));
      trustedToolSet = new Set(security.trustedTools);
    }
    if (typeof p.trustConnectorReads === "boolean") security.trustConnectorReads = p.trustConnectorReads;
    return { ...security };
  });

  handle("account.info", () =>
    withProbe(async (q) => {
      const init = await q.initializationResult();
      return { account: init.account, models: init.models };
    }),
  );

  // Account and plan usage from one short-lived Claude Code process (startup).
  handle("account.snapshot", () =>
    withProbe(async (q) => {
      const init = await q.initializationResult();
      let usage: unknown = null;
      try {
        usage = await q.usage_EXPERIMENTAL_MAY_CHANGE_DO_NOT_RELY_ON_THIS_API_YET({ skipBehaviors: true });
      } catch (err) {
        log("usage unavailable:", err instanceof Error ? err.message : String(err));
      }
      return { account: init.account, models: init.models, usage };
    }),
  );

  // Plan usage: ask a running session if there is one, otherwise start a short probe.
  handle("account.usage", () => {
    const running = [...live.values()].find((s) => s.state === "idle" || s.state === "running" || s.state === "waiting");
    return running ? running.usage() : withProbe((q) => q.usage_EXPERIMENTAL_MAY_CHANGE_DO_NOT_RELY_ON_THIS_API_YET({ skipBehaviors: true }));
  });

  handle("sessions.list", async (p: { dir?: string; limit?: number; offset?: number }) => {
    const sessions = await listSessions({ dir: p.dir, limit: p.limit, offset: p.offset });
    const running = new Map([...live.values()].filter((s) => s.sessionId).map((s) => [s.sessionId!, s]));
    return sessions.map((s) => ({ ...s, liveHandle: running.get(s.sessionId)?.handle, liveState: running.get(s.sessionId)?.state }));
  });

  handle("sessions.info", (p: { sessionId: string; dir?: string }) => getSessionInfo(p.sessionId, { dir: p.dir }));

  handle("sessions.messages", (p: { sessionId: string; dir?: string; limit?: number; offset?: number }) =>
    getSessionMessages(p.sessionId, { dir: p.dir, limit: p.limit, offset: p.offset }),
  );

  handle("session.start", (raw: StartParams) => {
    const p = withoutNulls(raw);
    if (!p.cwd) throw new Error("A working folder is required.");
    const s = new LiveSession(p);
    live.set(s.handle, s);
    if (p.prompt?.trim()) s.send(p.prompt, p.images ?? []);
    return { handle: s.handle, sessionId: s.sessionId };
  });

  handle("session.send", (p: { handle: string; text: string; images?: ImageInput[]; taint?: string }) => {
    const s = getLive(p.handle);
    if (p.taint) s.markTainted(p.taint);
    s.send(p.text, p.images ?? []);
  });
  handle("session.isStale", async (p: { handle: string }) => ({ stale: await getLive(p.handle).isStale() }));
  handle("session.interrupt", (p: { handle: string }) => getLive(p.handle).interrupt());
  handle("session.setModel", (p: { handle: string; model?: string }) => getLive(p.handle).setModel(p.model));
  handle("session.setPermissionMode", (p: { handle: string; mode: PermissionMode }) => getLive(p.handle).setPermissionMode(p.mode));
  handle("session.close", (p: { handle: string }) => {
    live.get(p.handle)?.close();
  });
  handle("session.live", () => [...live.values()].map((s) => ({ handle: s.handle, sessionId: s.sessionId, state: s.state, cwd: s.params.cwd })));
}
