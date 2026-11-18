import { test } from "node:test";
import assert from "node:assert/strict";
import { request } from "../src/rpc.ts";

test("a request the app never answers fails instead of hanging", async () => {
  const written: string[] = [];
  const original = process.stdout.write.bind(process.stdout);
  (process.stdout as any).write = (s: string) => { written.push(s); return true; };
  try {
    await assert.rejects(request("tool.invoke", { name: "mail_recent" }, undefined, 50), /didn't answer/);
  } finally {
    (process.stdout as any).write = original;
  }
  assert.ok(written.some((l) => l.includes('"rpc.cancelled"')), "the app is told to stop waiting too");
});
