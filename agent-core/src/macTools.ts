// Mac tools for the assistant. The AgentX app defines them (name,
// description, parameters, risk) and runs them; this file only turns the
// definitions into an in-process MCP server ("agentx") whose handlers ask the
// app to do the work over `tool.invoke`. Claude sees them as mcp__agentx__<name>.

import { createSdkMcpServer, tool, type McpSdkServerConfigWithInstance } from "@anthropic-ai/claude-agent-sdk";
import { z } from "zod";
import { frameUntrusted } from "./policy.ts";
import { handle, request } from "./rpc.ts";

export type ToolRisk = "read" | "create" | "ask";

export type ParamDef = {
  name: string;
  type: "string" | "integer" | "number" | "boolean" | "string[]";
  description: string;
  required: boolean;
  enum?: string[];
};

export type ToolDef = {
  name: string;
  description: string;
  risk: ToolRisk;
  parameters: ParamDef[];
  /** Results are untrusted content (e.g. "your email"): framed as data and they taint the session. */
  untrusted?: string;
  /** Only for sessions someone is watching (screen, selection, other apps' UI). */
  attendedOnly?: boolean;
};

type ToolResult = { content: { type: "text"; text: string }[]; isError: boolean };

let definitions: ToolDef[] = [];

export function setToolDefinitions(defs: ToolDef[]): void {
  definitions = defs;
}

export function toolDefinitions(): ToolDef[] {
  return definitions;
}

/** zod shape for a tool's parameters. */
export function zodShape(params: ParamDef[]): Record<string, z.ZodType> {
  const shape: Record<string, z.ZodType> = {};
  for (const p of params) {
    let t: z.ZodType;
    switch (p.type) {
      case "integer": t = z.number().int(); break;
      case "number": t = z.number(); break;
      case "boolean": t = z.boolean(); break;
      case "string[]": t = z.array(z.string()); break;
      default: t = p.enum && p.enum.length > 0 ? z.enum(p.enum as [string, ...string[]]) : z.string();
    }
    t = t.describe(p.description);
    shape[p.name] = p.required ? t : t.optional();
  }
  return shape;
}

/** Ask the app to run a tool and turn its answer into an MCP result. */
export async function invokeInApp(name: string, args: Record<string, unknown>, sessionHandle?: string): Promise<ToolResult> {
  try {
    const result = await request<{ text: string; isError?: boolean }>("tool.invoke", { handle: sessionHandle, name, args });
    const source = definitions.find((d) => d.name === name)?.untrusted;
    const text = source && !result.isError ? frameUntrusted(source, result.text) : result.text;
    return { content: [{ type: "text", text }], isError: result.isError ?? false };
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    return { content: [{ type: "text", text: `AgentX couldn't run ${name}: ${message}` }], isError: true };
  }
}

/** The tools a session gets: unattended runs don't get the attended-only ones. */
export function toolsFor(opts: { unattended?: boolean } = {}): ToolDef[] {
  return definitions.filter((d) => !(opts.unattended && d.attendedOnly));
}

/** A fresh MCP server for one assistant session. */
export function macToolsServer(sessionHandle: string, opts: { unattended?: boolean } = {}): McpSdkServerConfigWithInstance {
  return createSdkMcpServer({
    name: "agentx",
    version: "0.1.0",
    // Load the tools up front instead of behind ToolSearch: saves a round
    // trip on every assistant request, which matters in the launcher.
    alwaysLoad: true,
    tools: toolsFor(opts).map((d) =>
      tool(d.name, d.description, zodShape(d.parameters) as any, (args: Record<string, unknown>) => invokeInApp(d.name, args, sessionHandle)),
    ),
  });
}

/** Tools Claude may use without asking: read and create tiers. "ask" tools go through canUseTool. */
export function autoAllowedTools(opts: { unattended?: boolean } = {}): string[] {
  return toolsFor(opts).filter((d) => d.risk !== "ask").map((d) => `mcp__agentx__${d.name}`);
}

/** mcp__agentx__ name → what its results are, for tools that return untrusted content. */
export function untrustedToolSources(): Record<string, string> {
  return Object.fromEntries(definitions.filter((d) => d.untrusted).map((d) => [`mcp__agentx__${d.name}`, d.untrusted!]));
}

/** mcp__agentx__ names of the tools that always ask. */
export function askTierTools(): Set<string> {
  return new Set(definitions.filter((d) => d.risk === "ask").map((d) => `mcp__agentx__${d.name}`));
}

export function registerMacToolHandlers(): void {
  handle("tools.register", (p: { tools: ToolDef[] }) => {
    setToolDefinitions(p.tools ?? []);
    return { count: definitions.length };
  });

  // Diagnostics: run a tool through the same path Claude's calls take.
  handle("tools.call", (p: { name: string; args?: Record<string, unknown> }) => {
    if (!definitions.some((d) => d.name === p.name)) throw new Error(`No tool named ${p.name}.`);
    return invokeInApp(p.name, p.args ?? {});
  });
}
