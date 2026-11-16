// agent-core entry point. The AgentX app launches this with Node and talks to
// it over stdin/stdout (see rpc.ts for the wire format).

import { readFileSync } from "node:fs";
import { handle, listen, log, notify } from "./rpc.ts";
import { closeAllSessions, registerSessionHandlers } from "./sessions.ts";

// The SDK doesn't export its package.json, so read it from disk.
const sdkPackage = new URL("../node_modules/@anthropic-ai/claude-agent-sdk/package.json", import.meta.url);
const sdkVersion: string = JSON.parse(readFileSync(sdkPackage, "utf8")).version;
const VERSION = "0.1.0";

handle("core.hello", () => ({ version: VERSION, sdkVersion, node: process.version, pid: process.pid }));
registerSessionHandlers();

function shutdown(): void {
  closeAllSessions();
  process.exit(0);
}

listen(shutdown);
process.on("SIGTERM", shutdown);
process.on("SIGINT", shutdown);
process.on("unhandledRejection", (err) => log("unhandled rejection:", err instanceof Error ? err.message : String(err)));

notify("core.ready", { version: VERSION, sdkVersion });
log(`ready (sdk ${sdkVersion}, node ${process.version})`);
