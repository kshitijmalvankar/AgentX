import CoreServices
import Foundation

/// Calls `handler` (on a background queue) whenever anything changes under
/// `path`. Used to refresh the session list when Claude Code writes to
/// ~/.claude/projects, whether from AgentX, Terminal or VS Code.
final class DirectoryWatcher: @unchecked Sendable {
    private let path: String
    private let latency: TimeInterval
    private let handler: @Sendable () -> Void
    private var stream: FSEventStreamRef?

    init(path: String, latency: TimeInterval = 1.5, handler: @escaping @Sendable () -> Void) {
        self.path = path
        self.latency = latency
        self.handler = handler
    }

    func start() {
        guard stream == nil else { return }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue().handler()
        }
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context, [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagFileEvents)
        ) else { return }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue(label: "agentx.fsevents", qos: .utility))
        FSEventStreamStart(stream)
        self.stream = stream
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stop() }
}
