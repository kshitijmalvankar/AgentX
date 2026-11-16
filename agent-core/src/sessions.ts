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
} from "@anthropic-ai/claude-agent-sdk";
import { AsyncQueue } from "./asyncQueue.ts";
import { handle, log, notify, request } from "./rpc.ts";

/** Load the same settings Claude Code uses: ~/.claude, project .claude/, and local overrides. */
const ALL_SETTINGS = ["user", "project", "local"] as const;

export type SessionState = "starting" | "running" | "waiting" | "idle" | "ended";

type StartParams = {
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

  constructor(params: StartParams) {
    this.params = params;
    this.sessionId = params.resume;
    this.baseline = params.resume ? this.rememberNewest(params.resume) : Promise.resolve();
    this.q = query({
      prompt: this.input,
      options: {
        cwd: params.cwd,
        resume: params.resume,
        model: params.model,
        permissionMode: params.permissionMode ?? "default",
        settingSources: [...ALL_SETTINGS],
        systemPrompt: { type: "preset", preset: "claude_code", append: params.appendSystemPrompt },
        includePartialMessages: true,
        canUseTool: this.canUseTool,
        mcpServers: params.mcpServers,
        allowedTools: params.allowedTools,
        abortController: this.abort,
        stderr: (data) => log(`[claude ${this.handle.slice(0, 8)}]`, data.trimEnd()),
      },
    });
    void this.pump();
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

  send(text: string): void {
    this.input.push({
      type: "user",
      message: { role: "user", content: text },
      parent_tool_use_id: null,
      origin: { kind: "human" },
    } as SDKUserMessage);
    this.setState("running");
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
          canAlwaysAllow: (opts.suggestions?.length ?? 0) > 0 && !opts.suppressAlwaysAllowRule,
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
  handle("account.info", () =>
    withProbe(async (q) => {
      const init = await q.initializationResult();
      return { account: init.account, models: init.models };
    }),
  );

  handle("account.usage", () =>
    withProbe((q) => q.usage_EXPERIMENTAL_MAY_CHANGE_DO_NOT_RELY_ON_THIS_API_YET({ skipBehaviors: true })),
  );

  handle("sessions.list", async (p: { dir?: string; limit?: number; offset?: number }) => {
    const sessions = await listSessions({ dir: p.dir, limit: p.limit, offset: p.offset });
    const running = new Map([...live.values()].filter((s) => s.sessionId).map((s) => [s.sessionId!, s]));
    return sessions.map((s) => ({ ...s, liveHandle: running.get(s.sessionId)?.handle, liveState: running.get(s.sessionId)?.state }));
  });

  handle("sessions.info", (p: { sessionId: string; dir?: string }) => getSessionInfo(p.sessionId, { dir: p.dir }));

  handle("sessions.messages", (p: { sessionId: string; dir?: string; limit?: number; offset?: number }) =>
    getSessionMessages(p.sessionId, { dir: p.dir, limit: p.limit, offset: p.offset }),
  );

  handle("session.start", (p: StartParams) => {
    if (!p.cwd) throw new Error("A working folder is required.");
    const s = new LiveSession(p);
    live.set(s.handle, s);
    if (p.prompt?.trim()) s.send(p.prompt);
    return { handle: s.handle, sessionId: s.sessionId };
  });

  handle("session.send", (p: { handle: string; text: string }) => getLive(p.handle).send(p.text));
  handle("session.isStale", async (p: { handle: string }) => ({ stale: await getLive(p.handle).isStale() }));
  handle("session.interrupt", (p: { handle: string }) => getLive(p.handle).interrupt());
  handle("session.setModel", (p: { handle: string; model?: string }) => getLive(p.handle).setModel(p.model));
  handle("session.setPermissionMode", (p: { handle: string; mode: PermissionMode }) => getLive(p.handle).setPermissionMode(p.mode));
  handle("session.close", (p: { handle: string }) => {
    live.get(p.handle)?.close();
  });
  handle("session.live", () => [...live.values()].map((s) => ({ handle: s.handle, sessionId: s.sessionId, state: s.state, cwd: s.params.cwd })));
}
