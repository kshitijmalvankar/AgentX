import { test } from "node:test";
import assert from "node:assert/strict";
import { autoAllowedTools, setToolDefinitions, zodShape, type ToolDef } from "../src/macTools.ts";
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
