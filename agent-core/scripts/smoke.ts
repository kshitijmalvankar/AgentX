// Smoke test: spawn the sidecar, call a few read-only methods, print results.
// Usage: node scripts/smoke.ts     (uses no plan quota: no prompt is sent)

import { spawn } from "node:child_process";
import { createInterface } from "node:readline";
import { fileURLToPath } from "node:url";

const entry = fileURLToPath(new URL("../src/index.ts", import.meta.url));
const child = spawn(process.execPath, [entry], { stdio: ["pipe", "pipe", "inherit"] });
const rl = createInterface({ input: child.stdout! });
const waiting = new Map<number, (m: any) => void>();
let id = 0;

rl.on("line", (line) => {
  const msg = JSON.parse(line);
  if (typeof msg.id === "number") waiting.get(msg.id)?.(msg);
});

function call(method: string, params: unknown = {}): Promise<any> {
  const myId = ++id;
  return new Promise((resolve) => {
    waiting.set(myId, resolve);
    child.stdin!.write(JSON.stringify({ id: myId, method, params }) + "\n");
  });
}

const kill = setTimeout(() => {
  console.error("timed out");
  child.kill();
  process.exit(1);
}, 60_000);

const hello = await call("core.hello");
console.log("core.hello      ", hello.result);

const list = await call("sessions.list", { limit: 5 });
if (list.error) console.log("sessions.list    error:", list.error.message);
else for (const s of list.result) console.log("sessions.list    ", new Date(s.lastModified).toISOString().slice(0, 16), "|", s.cwd, "|", String(s.summary).slice(0, 50));

const acct = await call("account.info");
if (acct.error) console.log("account.info     error:", acct.error.message);
else {
  const a = acct.result.account;
  console.log("account.info     subscription:", a.subscriptionType, "| provider:", a.apiProvider, "| tokenSource:", a.tokenSource, "| apiKeySource:", a.apiKeySource);
  console.log("models          ", acct.result.models.map((m: any) => `${m.value} (${m.displayName})`).join(", "));
}

clearTimeout(kill);
child.stdin!.end();
