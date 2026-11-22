import { test } from "node:test";
import assert from "node:assert/strict";
import { withoutNulls } from "../src/sessions.ts";

test("options the app leaves unset (JSON null) are dropped, so the SDK's defaults apply", () => {
  // What AgentX sends to continue a coding session.
  const fromApp = JSON.parse(`{"kind":"coding","cwd":"/Users/me/Projects/AgentX","prompt":"do I have any open commits?",
    "resume":"35051b69","allowedTools":null,"appendSystemPrompt":null,"taint":null,"model":null,
    "unattended":false,"images":[],"permissionMode":"default"}`);
  const p = withoutNulls(fromApp);
  for (const key of ["allowedTools", "appendSystemPrompt", "taint", "model"]) assert.equal(key in p, false, key);
  assert.equal(p.unattended, false, "false stays");
  assert.deepEqual(p.images, [], "empty lists stay");
  assert.equal(p.resume, "35051b69");
  assert.equal(p.permissionMode, "default");
});
