import Foundation
import Observation

public enum AgentError: LocalizedError {
    case notRunning(String)
    case remote(String)
    case missingTool(String)

    public var errorDescription: String? {
        switch self {
        case .notRunning(let why): "The agent engine isn't running. \(why)"
        case .remote(let message): message
        case .missingTool(let message): message
        }
    }
}

/// Talks to the agent-core sidecar (Node + Claude Agent SDK) over JSON lines.
///
/// - `call(_:_:)` sends a request and awaits the answer.
/// - `notificationHandler` receives events (`session.event`, `session.state`, ...).
/// - `requestHandler` answers questions the sidecar asks us
///   (`permission.request`, later `tool.invoke` for Mac tools).
@MainActor
@Observable
public final class AgentClient {
    public enum Status: Equatable, Sendable {
        case stopped
        case starting
        case ready
        case failed(String)
    }

    public private(set) var status: Status = .stopped
    public private(set) var sdkVersion: String?
    public private(set) var paths: ToolPaths?
    /// Last lines the sidecar wrote to stderr, shown in Settings > Diagnostics.
    public private(set) var recentLog: [String] = []

    @ObservationIgnored public var notificationHandler: ((String, JSONValue) -> Void)?
    @ObservationIgnored public var requestHandler: ((String, JSONValue, JSONValue) async throws -> JSONValue)?

    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var stdin: FileHandle?
    @ObservationIgnored private var nextID = 1
    @ObservationIgnored private var pending: [Int: CheckedContinuation<JSONValue, any Error>] = [:]
    @ObservationIgnored private var readyWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var readers: [Task<Void, Never>] = []

    public init() {}

    // MARK: Lifecycle

    public func start() async {
        guard process == nil else { return }
        status = .starting
        let paths = await ToolLocator.resolve()
        self.paths = paths

        guard let node = paths.node else {
            status = .failed("Node.js wasn't found. Install it (brew install node) or set its path in Settings.")
            return
        }
        guard let core = paths.agentCore else {
            status = .failed("The agent-core folder wasn't found. Set its path in Settings.")
            return
        }
        guard FileManager.default.fileExists(atPath: "\(core)/node_modules/@anthropic-ai/claude-agent-sdk") else {
            status = .failed("agent-core dependencies are missing. Run `npm install` in \(core).")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: node)
        process.arguments = ["\(core)/src/index.ts"]
        process.currentDirectoryURL = URL(fileURLWithPath: core)
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = paths.shellPath
        env["AGENTX"] = "1"
        process.environment = env

        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = errPipe

        process.terminationHandler = { [weak self] p in
            let code = p.terminationStatus
            Task { @MainActor in self?.didTerminate(code: code) }
        }

        do {
            try process.run()
        } catch {
            status = .failed("Couldn't start Node: \(error.localizedDescription)")
            return
        }
        self.process = process
        self.stdin = inPipe.fileHandleForWriting

        readers = [
            readLines(from: outPipe.fileHandleForReading) { [weak self] line in self?.handleLine(line) },
            readLines(from: errPipe.fileHandleForReading) { [weak self] line in self?.appendLog(line) },
        ]
    }

    public func stop() {
        stdin?.closeFile()
        process?.terminate()
    }

    public func restart() async {
        stop()
        while process != nil { try? await Task.sleep(for: .milliseconds(50)) }
        await start()
    }

    /// Wait until the sidecar says it's ready (or failed).
    public func waitUntilReady() async {
        if status == .ready { return }
        if case .failed = status { return }
        await withCheckedContinuation { readyWaiters.append($0) }
    }

    private func didTerminate(code: Int32) {
        process = nil
        stdin = nil
        readers.forEach { $0.cancel() }
        readers = []
        let reason = "agent-core exited (code \(code))."
        for (_, cont) in pending { cont.resume(throwing: AgentError.notRunning(reason)) }
        pending.removeAll()
        if status != .stopped { status = .failed(reason + " See Settings > Diagnostics.") }
        resumeReadyWaiters()
        notificationHandler?("core.exited", ["code": .number(Double(code))])
    }

    private func resumeReadyWaiters() {
        let waiters = readyWaiters
        readyWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    // MARK: Requests

    @discardableResult
    public func call(_ method: String, _ params: JSONValue = [:]) async throws -> JSONValue {
        await waitUntilReady()
        guard status == .ready else { throw AgentError.notRunning(statusMessage) }
        let id = nextID
        nextID += 1
        return try await withCheckedThrowingContinuation { cont in
            pending[id] = cont
            send(["id": .number(Double(id)), "method": .string(method), "params": params])
        }
    }

    public func call<T: Decodable>(_ method: String, _ params: JSONValue = [:], as type: T.Type) async throws -> T {
        try await call(method, params).decode(T.self)
    }

    public var statusMessage: String {
        switch status {
        case .stopped: "Stopped."
        case .starting: "Starting…"
        case .ready: "Ready."
        case .failed(let why): why
        }
    }

    private func send(_ message: JSONValue) {
        guard let stdin, var data = try? JSONEncoder().encode(message) else { return }
        data.append(0x0A)
        stdin.write(data)
    }

    // MARK: Incoming

    private func handleLine(_ line: Data) {
        guard let msg = try? JSONDecoder().decode(JSONValue.self, from: line) else { return }
        let method = msg["method"]?.string
        let params = msg["params"] ?? .null

        switch (method, msg["id"]) {
        case (nil, .number(let n)?):
            // Response to one of our requests.
            guard let cont = pending.removeValue(forKey: Int(n)) else { return }
            if let error = msg["error"], !error.isNull {
                cont.resume(throwing: AgentError.remote(error["message"]?.string ?? "Request failed"))
            } else {
                cont.resume(returning: msg["result"] ?? .null)
            }

        case (let method?, let id?):
            // The sidecar is asking us something.
            Task {
                do {
                    let result = try await requestHandler?(method, params, id) ?? .null
                    send(["id": id, "result": result])
                } catch {
                    send(["id": id, "error": ["message": .string(error.localizedDescription)]])
                }
            }

        case (let method?, nil):
            if method == "core.ready" {
                sdkVersion = params["sdkVersion"]?.string
                status = .ready
                resumeReadyWaiters()
            }
            notificationHandler?(method, params)

        default:
            break
        }
    }

    private func appendLog(_ line: Data) {
        guard let text = String(data: line, encoding: .utf8) else { return }
        recentLog.append(text)
        if recentLog.count > 300 { recentLog.removeFirst(recentLog.count - 300) }
    }

    /// Read a pipe line by line, delivering each line on the main actor in order.
    private func readLines(from handle: FileHandle, _ onLine: @escaping @MainActor (Data) -> Void) -> Task<Void, Never> {
        let (chunks, continuation) = AsyncStream<Data>.makeStream()
        handle.readabilityHandler = { h in
            let data = h.availableData
            if data.isEmpty {
                h.readabilityHandler = nil
                continuation.finish()
            } else {
                continuation.yield(data)
            }
        }
        return Task { @MainActor in
            var buffer = Data()
            for await chunk in chunks {
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = buffer[buffer.startIndex..<newline]
                    buffer.removeSubrange(buffer.startIndex...newline)
                    if !line.isEmpty { onLine(Data(line)) }
                }
            }
        }
    }
}
