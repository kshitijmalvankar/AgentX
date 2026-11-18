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
//
// Lines end at "\n" and nowhere else. (Node's readline also breaks lines at
// U+2028 and U+2029, which JSON allows unescaped inside strings: an email
// containing one used to cut a message in two and leave its request hanging.)

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

/** One JSON line, with U+2028/U+2029 escaped so no reader can mistake them for line ends. */
export function encodeLine(obj: unknown): string {
  return JSON.stringify(obj).replace(/\u2028/g, "\\u2028").replace(/\u2029/g, "\\u2029") + "\n";
}

/** Split a stream's text into lines at "\n" only. Returns the complete lines and keeps the rest. */
export function splitLines(buffer: string): { lines: string[]; rest: string } {
  const parts = buffer.split("\n");
  const rest = parts.pop() ?? "";
  return { lines: parts.map((l) => (l.endsWith("\r") ? l.slice(0, -1) : l)), rest };
}

function write(obj: unknown): void {
  process.stdout.write(encodeLine(obj));
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
 * `timeoutMs`: give up if no answer comes (a lost answer must never hang a conversation).
 */
export function request<T = unknown>(method: string, params: unknown, signal?: AbortSignal, timeoutMs?: number): Promise<T> {
  const id = `core-${nextId++}`;
  return new Promise<T>((resolve, reject) => {
    let timer: ReturnType<typeof setTimeout> | undefined;
    const onAbort = () => {
      if (!pending.has(id)) return;
      pending.delete(id);
      if (timer) clearTimeout(timer);
      notify("rpc.cancelled", { id });
      reject(new Error("cancelled"));
    };
    pending.set(id, {
      resolve: (v) => {
        signal?.removeEventListener("abort", onAbort);
        if (timer) clearTimeout(timer);
        resolve(v);
      },
      reject: (e) => {
        signal?.removeEventListener("abort", onAbort);
        if (timer) clearTimeout(timer);
        reject(e);
      },
    });
    if (timeoutMs) {
      timer = setTimeout(() => {
        if (!pending.has(id)) return;
        pending.delete(id);
        signal?.removeEventListener("abort", onAbort);
        notify("rpc.cancelled", { id });
        log(`no answer to ${method} within ${Math.round(timeoutMs / 1000)} s`);
        reject(new Error(`AgentX didn't answer within ${Math.round(timeoutMs / 60_000)} minutes.`));
      }, timeoutMs);
    }
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
  let buffer = "";
  process.stdin.setEncoding("utf8");
  process.stdin.on("data", (chunk: string) => {
    const { lines, rest } = splitLines(buffer + chunk);
    buffer = rest;
    for (const line of lines) {
      if (!line.trim()) continue;
      let msg: any;
      try {
        msg = JSON.parse(line);
      } catch {
        log(`ignoring a line that isn't JSON (${line.length} characters)`);
        continue;
      }
      void dispatch(msg);
    }
  });
  let closed = false;
  const close = () => {
    if (closed) return;
    closed = true;
    onClose();
  };
  process.stdin.on("end", close);
  process.stdin.on("close", close);
}
