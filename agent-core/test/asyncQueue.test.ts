import { test } from "node:test";
import assert from "node:assert/strict";
import { AsyncQueue } from "../src/asyncQueue.ts";

test("delivers pushed items in order, including ones pushed before iteration", async () => {
  const q = new AsyncQueue<number>();
  q.push(1);
  q.push(2);
  setTimeout(() => {
    q.push(3);
    q.close();
  }, 10);
  const seen: number[] = [];
  for await (const n of q) seen.push(n);
  assert.deepEqual(seen, [1, 2, 3]);
});

test("ignores pushes after close", async () => {
  const q = new AsyncQueue<string>();
  q.close();
  q.push("late");
  const seen: string[] = [];
  for await (const s of q) seen.push(s);
  assert.deepEqual(seen, []);
});
