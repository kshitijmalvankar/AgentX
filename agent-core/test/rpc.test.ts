import { test } from "node:test";
import assert from "node:assert/strict";
import { encodeLine, splitLines } from "../src/rpc.ts";

test("a message with line separators inside stays one line", () => {
  // Emails can contain U+2028/U+2029; JSON allows them raw, Node's readline split on them.
  const line = encodeLine({ id: 1, result: { text: "Dear Kshitij, see below Enda" } });
  assert.equal(line.split("\n").length, 2, "one line plus the final newline");
  assert.ok(!line.includes(" ") && !line.includes(" "));
  assert.equal(JSON.parse(line).result.text, "Dear Kshitij, see below Enda", "escaped, not changed");
});

test("lines end at newlines only, and partial lines wait for the rest", () => {
  const raw = '{"a":"x y"}\n{"b":1}\r\n{"c":';
  const { lines, rest } = splitLines(raw);
  assert.deepEqual(lines, ['{"a":"x y"}', '{"b":1}']);
  assert.equal(rest, '{"c":');
  assert.deepEqual(JSON.parse(lines[0]), { a: "x y" });
});
