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
      const image = m.params.name === "screen_look" ? { data: "iVBORw0KGgo=", mimeType: "image/png" } : undefined;
      send({ id: m.id, result: { text: `ran ${m.params.name} with ${JSON.stringify(m.params.args)}`, isError: false, image } });
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

    // Untrusted tools come back framed as data.
    await call(4, "tools.register", { tools: [{ name: "mail_recent", description: "Read mail", risk: "read", parameters: [], untrusted: "your email" }] });
    const mail = await call(5, "tools.call", { name: "mail_recent", args: {} });
    assert.match(mail.result.content[0].text, /^<untrusted source="your email">\n[\s\S]*\n<\/untrusted>$/);

    // A picture from the app comes back as an MCP image, before the text.
    await call(7, "tools.register", { tools: [{ name: "screen_look", description: "See a window", risk: "ask", parameters: [], untrusted: "a screenshot of your screen" }] });
    const look = await call(8, "tools.call", { name: "screen_look", args: {} });
    assert.deepEqual(look.result.content[0], { type: "image", data: "iVBORw0KGgo=", mimeType: "image/png" });
    assert.match(look.result.content[1].text, /^<untrusted source="a screenshot of your screen">/);

    // Security settings round-trip.
    const sec = await call(6, "security.configure", { pathExceptions: ["~/.config/gh"], trustedRoots: ["/tmp/project"] });
    assert.deepEqual(sec.result.pathExceptions, ["~/.config/gh"]);
    assert.deepEqual(sec.result.trustedRoots, ["/tmp/project"]);

    // The sidecar only talks over its pipes: no listening sockets.
    const { execFileSync } = await import("node:child_process");
    let listening = "";
    try {
      listening = execFileSync("lsof", ["-a", "-p", String(child.pid), "-iTCP", "-sTCP:LISTEN", "-Fn"], { encoding: "utf8" });
    } catch {
      listening = ""; // lsof exits 1 when nothing matches
    }
    assert.equal(listening.trim(), "", "agent-core must not listen on any port");
  } finally {
    child.kill();
  }
});
