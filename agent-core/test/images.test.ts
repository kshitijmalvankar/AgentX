import { test } from "node:test";
import assert from "node:assert/strict";
import { userContent } from "../src/sessions.ts";

test("text alone stays a plain string", () => {
  assert.equal(userContent("hello"), "hello");
});

test("images come first, then the text", () => {
  const content = userContent("what's this?", [{ mediaType: "image/png", data: "iVBORw0KGgo=" }]) as any[];
  assert.equal(content.length, 2);
  assert.deepEqual(content[0], { type: "image", source: { type: "base64", media_type: "image/png", data: "iVBORw0KGgo=" } });
  assert.deepEqual(content[1], { type: "text", text: "what's this?" });
});

test("odd or oversized images are refused", () => {
  assert.throws(() => userContent("x", [{ mediaType: "image/svg+xml", data: "PHN2Zz4=" }]), /Unsupported image type/);
  assert.throws(() => userContent("x", [{ mediaType: "image/png", data: "" }]), /empty or too large/);
  assert.throws(() => userContent("x", [{ mediaType: "image/png", data: "A".repeat(9 * 1024 * 1024) }]), /empty or too large/);
  const five = Array.from({ length: 5 }, () => ({ mediaType: "image/png", data: "AA==" }));
  assert.throws(() => userContent("x", five), /At most 4/);
});
