import { test } from "node:test";
import assert from "node:assert/strict";
import { askTierTools, autoAllowedTools, setToolDefinitions, toolsFor, untrustedToolSources, zodShape, type ToolDef } from "../src/macTools.ts";
import { z } from "zod";

const defs: ToolDef[] = [
  { name: "calendar_events", description: "List events", risk: "read", parameters: [
    { name: "start", type: "string", description: "Start", required: false },
    { name: "limit", type: "integer", description: "Max", required: false },
  ] },
  { name: "notes_create", description: "Create a note", risk: "create", parameters: [
    { name: "title", type: "string", description: "Title", required: true },
  ] },
  { name: "mail_send", description: "Send mail", risk: "ask", parameters: [
    { name: "to", type: "string[]", description: "Recipients", required: true },
    { name: "mode", type: "string", description: "Mode", required: false, enum: ["dark", "light"] },
  ] },
];

test("only read and create tools are pre-approved", () => {
  setToolDefinitions(defs);
  assert.deepEqual(autoAllowedTools(), ["mcp__agentx__calendar_events", "mcp__agentx__notes_create"]);
});

test("parameters become zod schemas with required/optional and types", () => {
  const schema = z.object(zodShape(defs[2].parameters));
  assert.equal(schema.safeParse({ to: ["a@example.com"] }).success, true);
  assert.equal(schema.safeParse({ to: "a@example.com" }).success, false);
  assert.equal(schema.safeParse({ to: [], mode: "sepia" }).success, false);
  assert.equal(schema.safeParse({}).success, false);
  const optional = z.object(zodShape(defs[0].parameters));
  assert.equal(optional.safeParse({}).success, true);
  assert.equal(optional.safeParse({ limit: 2.5 }).success, false);
});

test("attended-only tools are left out of unattended runs", () => {
  setToolDefinitions([
    ...defs,
    { name: "screen_look", description: "See the screen", risk: "ask", parameters: [], attendedOnly: true },
    { name: "context_now", description: "What's in front", risk: "read", parameters: [], attendedOnly: true },
  ]);
  assert.ok(autoAllowedTools().includes("mcp__agentx__context_now"));
  assert.ok(!autoAllowedTools({ unattended: true }).includes("mcp__agentx__context_now"));
  assert.deepEqual(toolsFor({ unattended: true }).map((d) => d.name), ["calendar_events", "notes_create", "mail_send"]);
});

test("untrusted sources and ask-tier names are exposed for the policy", () => {
  setToolDefinitions([...defs, { name: "mail_recent", description: "Read mail", risk: "read", parameters: [], untrusted: "your email" }]);
  assert.deepEqual(untrustedToolSources(), { mcp__agentx__mail_recent: "your email" });
  assert.deepEqual([...askTierTools()], ["mcp__agentx__mail_send"]);
});
