import AppKit
import Observation

/// Samples the Mac's vitals every 2 seconds, but only while something is
/// showing them (System section, dashboard card, menu bar), so AgentX costs
/// nothing in the background.
@MainActor
@Observable
public final class SystemMonitor {
    public static let interval: Duration = .seconds(2)
    /// 3 minutes of history at 2-second samples.
    public static let historyLength = 90

    public private(set) var latest: SystemSnapshot?
    public private(set) var history: [SystemSnapshot] = []
    public let machine = MachineInfo.current()

    @ObservationIgnored private let sampler = SystemSampler()
    @ObservationIgnored private var viewers = 0
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var appInfo: [Int32: (name: String, icon: NSImage?)] = [:]

    public init() {}

    /// Call from `.onAppear`; pair with `endWatching()` in `.onDisappear`.
    public func beginWatching() {
        viewers += 1
        guard loop == nil else { return }
        loop = Task { [weak self] in
            guard let sampler = self?.sampler else { return }
            await sampler.reset()
            _ = await sampler.sample()                    // prime the counters
            try? await Task.sleep(for: .milliseconds(700))
            while !Task.isCancelled {
                let snapshot = await sampler.sample()
                guard let self, !Task.isCancelled else { return }
                self.record(snapshot)
                try? await Task.sleep(for: Self.interval)
            }
        }
    }

    public func endWatching() {
        viewers = max(0, viewers - 1)
        guard viewers == 0 else { return }
        loop?.cancel()
        loop = nil
        history.removeAll()   // a gap would make the sparklines lie
    }

    private func record(_ snapshot: SystemSnapshot) {
        latest = snapshot
        history.append(snapshot)
        if history.count > Self.historyLength { history.removeFirst(history.count - Self.historyLength) }
    }

    /// App name and icon for GUI apps; the process name otherwise.
    public func display(_ process: ProcessUsage) -> (name: String, icon: NSImage?) {
        if let cached = appInfo[process.pid], cached.name == process.name || cached.icon != nil { return cached }
        let app = NSRunningApplication(processIdentifier: process.pid)
        let info = (name: app?.localizedName ?? process.name, icon: app?.icon)
        if appInfo.count > 500 { appInfo.removeAll() }
        appInfo[process.pid] = info
        return info
    }
}
