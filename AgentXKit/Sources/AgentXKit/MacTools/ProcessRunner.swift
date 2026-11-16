import Foundation

/// Runs a command-line program off the main thread with a clean environment
/// and a timeout, and returns its output.
enum ProcessRunner {
    struct Output: Sendable {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 30) async throws -> Output {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            var env = ToolLocator.baseEnvironment()
            env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
            process.environment = env
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            process.standardInput = FileHandle.nullDevice
            try process.run()

            // Drain both pipes while the program runs so a big output can't block it.
            async let stdoutData = Task.detached { out.fileHandleForReading.readDataToEndOfFile() }.value
            async let stderrData = Task.detached { err.fileHandleForReading.readDataToEndOfFile() }.value
            let watchdog = Task.detached {
                try? await Task.sleep(for: .seconds(timeout))
                if process.isRunning { process.terminate() }
            }
            let (o, e) = await (stdoutData, stderrData)
            process.waitUntilExit()
            watchdog.cancel()
            if process.terminationReason == .uncaughtSignal {
                throw ToolError("\((executable as NSString).lastPathComponent) took longer than \(Int(timeout)) seconds and was stopped.")
            }
            return Output(status: process.terminationStatus,
                          stdout: String(decoding: o, as: UTF8.self),
                          stderr: String(decoding: e, as: UTF8.self))
        }.value
    }
}

/// Runs AppleScript through osascript. Values are passed as `argv`, never
/// pasted into the script text, so nothing Claude writes can change the script.
enum AppleScript {
    static func run(_ source: String, arguments: [String] = [], timeout: TimeInterval = 45) async throws -> String {
        let result = try await ProcessRunner.run("/usr/bin/osascript", ["-e", source] + arguments, timeout: timeout)
        guard result.status == 0 else { throw ToolError(explain(result.stderr)) }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Turn osascript errors into something actionable.
    static func explain(_ stderr: String) -> String {
        let text = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.contains("-1743") || text.localizedCaseInsensitiveContains("not authorized") {
            let app = text.range(of: #"(?<=application ")[^"]+"#, options: .regularExpression).map { String(text[$0]) } ?? "that app"
            return "AgentX isn't allowed to control \(app). Allow it in System Settings › Privacy & Security › Automation › AgentX."
        }
        if text.contains("-600") { return "The app isn't running and couldn't be started." }
        if text.contains("-1728") { return "Couldn't find that item (\(text))." }
        return text.isEmpty ? "The script failed." : text
    }
}
