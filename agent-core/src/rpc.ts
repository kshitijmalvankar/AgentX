// JSON-lines RPC over stdin/stdout.
//
// Every line is one JSON object:
//   request       {"id": 1, "method": "sessions.list", "params": {...}}
//   response      {"id": 1, "result": ...}  or  {"id": 1, "error": {"message": "..."}}
//   notification  {"method": "session.event", "params": {...}}            (no id)
//
// Both sides can send requests. The Swift app uses numeric ids; this sidecar
// uses string ids ("core-1", "core-2", ...) so the two never collide.
//
// stdout is reserved for the protocol. Log with `log()` (stderr) only.

import { createInterface } from "node:readline";

export type RequestHandler = (params: any) => Promise<unknown> | unknown;

type Pending = { resolve: (v: any) => void; reject: (e: Error) => void };

const handlers = new Map<string, RequestHandler>();
const pending = new Map<string, Pending>();
let nextId = 1;

export function log(...parts: unknown[]): void {
  const line = parts
    .map((p) => (typeof p === "string" ? p : JSON.stringify(p)))
    .join(" ");
  process.stderr.write(`[agent-core] ${line}\n`);
}

function write(obj: unknown): void {
  process.stdout.write(JSON.stringify(obj) + "\n");
}

/** Register a handler for requests coming from the Swift app. */
export function handle(method: string, fn: RequestHandler): void {
  handlers.set(method, fn);
}

/** Fire-and-forget message to the Swift app. */
export function notify(method: string, params: unknown): void {
  write({ method, params });
}

/**
 * Ask the Swift app something and wait for its answer.
 * If `signal` aborts first (e.g. the SDK gave up on a permission prompt),
 * the promise rejects and the app gets `rpc.cancelled` so it can close its UI.
 */
export function request<T = unknown>(method: string, params: unknown, signal?: AbortSignal): Promise<T> {
  const id = `core-${nextId++}`;
  return new Promise<T>((resolve, reject) => {
    const onAbort = () => {
      if (!pending.has(id)) return;
      pending.delete(id);
      notify("rpc.cancelled", { id });
      reject(new Error("cancelled"));
    };
    pending.set(id, {
      resolve: (v) => {
        signal?.removeEventListener("abort", onAbort);
        resolve(v);
      },
      reject: (e) => {
        signal?.removeEventListener("abort", onAbort);
        reject(e);
      },
    });
    if (signal?.aborted) return onAbort();
    signal?.addEventListener("abort", onAbort, { once: true });
    write({ id, method, params });
  });
}

async function dispatch(msg: any): Promise<void> {
  // A response to one of our requests.
  if (msg.id !== undefined && msg.method === undefined) {
    const p = pending.get(String(msg.id));
    if (!p) return;
    pending.delete(String(msg.id));
    if (msg.error) p.reject(new Error(msg.error.message ?? "Request failed"));
    else p.resolve(msg.result);
    return;
  }

  const fn = handlers.get(msg.method);
  if (!fn) {
    if (msg.id !== undefined) write({ id: msg.id, error: { message: `Unknown method ${msg.method}` } });
    return;
  }
  try {
    const result = await fn(msg.params ?? {});
    if (msg.id !== undefined) write({ id: msg.id, result: result ?? null });
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    log(`error in ${msg.method}:`, message);
    if (msg.id !== undefined) write({ id: msg.id, error: { message } });
  }
}

/** Start reading stdin. Exits the process when the app closes the pipe. */
export function listen(onClose: () => void): void {
  const rl = createInterface({ input: process.stdin });
  rl.on("line", (line) => {
    if (!line.trim()) return;
    let msg: any;
    try {
      msg = JSON.parse(line);
    } catch {
      log("ignoring non-JSON line");
      return;
    }
    void dispatch(msg);
  });
  rl.on("close", onClose);
}
