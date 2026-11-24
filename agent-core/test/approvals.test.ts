import { test } from "node:test";
import assert from "node:assert/strict";
import { describeAlwaysAllow, toPermissionResult } from "../src/sessions.ts";

test("Always Allow says what it allows", () => {
  assert.equal(describeAlwaysAllow(undefined), undefined);
  assert.equal(describeAlwaysAllow([{ type: "setMode", mode: "acceptEdits", destination: "session" }])?.label, "Allow All Edits");
  const bash = describeAlwaysAllow([{ type: "addRules", behavior: "allow", destination: "localSettings",
    rules: [{ toolName: "Bash", ruleContent: "npm test:*" }] }]);
  assert.equal(bash?.detail, "Don't ask again in this project for Bash(npm test:*)");
});

test("approving a plan can switch the session's mode", () => {
  const result = toPermissionResult({ behavior: "allow", mode: "acceptEdits" }, undefined);
  assert.deepEqual(result, { behavior: "allow", updatedInput: undefined, decisionClassification: "user_temporary",
    updatedPermissions: [{ type: "setMode", mode: "acceptEdits", destination: "session" }] });
});

test("an answered question goes back as the tool's input", () => {
  const input = { questions: [{ question: "Which focus?", header: "Focus", multiSelect: false, options: [] }],
    answers: { "Which focus?": "Simple mode" } };
  const result = toPermissionResult({ behavior: "allow", updatedInput: input }, undefined);
  assert.equal(result.behavior, "allow");
  assert.deepEqual(result.behavior === "allow" ? result.updatedInput : undefined, input);
});
