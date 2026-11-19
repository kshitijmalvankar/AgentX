import CoreServices
import Foundation

/// Calls `handler` (on a background queue) whenever anything changes under
/// the watched folders, with the paths that changed. Used to refresh the
/// session list when Claude Code writes to ~/.claude/projects (whether from
/// AgentX, Terminal or VS Code), memories, and your repos' git state.
final class DirectoryWatcher: @unchecked Sendable {
    private let paths: [String]
    private let latency: TimeInterval
    private let handler: @Sendable ([String]) -> Void
    private var stream: FSEventStreamRef?

    init(paths: [String], latency: TimeInterval = 1.5, onChange handler: @escaping @Sendable ([String]) -> Void) {
        self.paths = paths
        self.latency = latency
        self.handler = handler
    }

    convenience init(path: String, latency: TimeInterval = 1.5, handler: @escaping @Sendable () -> Void) {
        self.init(paths: [path], latency: latency) { _ in handler() }
    }

    func start() {
        guard stream == nil, !paths.isEmpty else { return }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, eventPaths, _, _ in
            guard let info else { return }
            let changed = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as? [String] ?? []
            Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue().handler(changed)
        }
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context, paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
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
