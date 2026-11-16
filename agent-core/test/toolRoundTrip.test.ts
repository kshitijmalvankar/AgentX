// Spawns the real sidecar and plays the AgentX app's side of the protocol:
// register tools, ask the sidecar to call one, answer its tool.invoke request.
import { test } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createInterface } from "node:readline";
import { fileURLToPath } from "node:url";

test("a tool call travels sidecar -> app -> sidecar", async () => {
  const entry = fileURLToPath(new URL("../src/index.ts", import.meta.url));
  const child = spawn(process.execPath, [entry], { stdio: ["pipe", "pipe", "ignore"] });
  const lines = createInterface({ input: child.stdout! });
  const send = (m: unknown) => child.stdin!.write(JSON.stringify(m) + "\n");
  const responses = new Map<number, (m: any) => void>();
  let invoked: any;

  lines.on("line", (line) => {
    const m = JSON.parse(line);
    if (m.method === "tool.invoke") {
      invoked = m.params;
      send({ id: m.id, result: { text: `ran ${m.params.name} with ${JSON.stringify(m.params.args)}`, isError: false } });
    } else if (typeof m.id === "number") {
      responses.get(m.id)?.(m);
    }
  });
  const call = (id: number, method: string, params: unknown) =>
    new Promise<any>((resolve) => { responses.set(id, resolve); send({ id, method, params }); });

  try {
    const reg = await call(1, "tools.register", { tools: [{ name: "notes_search", description: "Search notes", risk: "read",
      parameters: [{ name: "query", type: "string", description: "Text", required: true }] }] });
    assert.equal(reg.result.count, 1);

    const res = await call(2, "tools.call", { name: "notes_search", args: { query: "groceries" } });
    assert.equal(invoked.name, "notes_search");
    assert.deepEqual(invoked.args, { query: "groceries" });
    assert.equal(res.result.isError, false);
    assert.match(res.result.content[0].text, /ran notes_search/);

    const missing = await call(3, "tools.call", { name: "nope" });
    assert.match(missing.error.message, /No tool named nope/);
  } finally {
    child.kill();
  }
});
