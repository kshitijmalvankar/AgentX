import AppKit
import Foundation
import IOKit.ps

/// Watches one kind of thing for TriggerEngine. Started only while an enabled
/// automation needs it, and stopped when none does.
@MainActor
protocol TriggerSource: AnyObject {
    func start(_ emit: @escaping @MainActor (TriggerSignal) -> Void)
    func stop()
}

// MARK: - Files

/// New files in folders (not in their subfolders). Partial downloads and hidden
/// files don't count; a file counts once it has been there for 2 seconds.
@MainActor
final class FolderSource: TriggerSource {
    private let folders: [String]
    private var known: [String: Set<String>] = [:]
    private var watcher: DirectoryWatcher?
    private var emit: (@MainActor (TriggerSignal) -> Void)?

    init(folders: [String]) { self.folders = folders }

    func start(_ emit: @escaping @MainActor (TriggerSignal) -> Void) {
        self.emit = emit
        for folder in folders { known[folder] = Self.names(in: folder) }
        let watcher = DirectoryWatcher(paths: folders, latency: 1) { [weak self] _ in
            Task { @MainActor in self?.changed() }
        }
        watcher.start()
        self.watcher = watcher
    }

    func stop() {
        watcher?.stop()
        watcher = nil
        emit = nil
    }

    private func changed() {
        for folder in folders {
            let now = Self.names(in: folder)
            let added = FileTriggers.added(before: known[folder] ?? [], now: now)
            known[folder] = now
            for name in added {
                let path = (folder as NSString).appendingPathComponent(name)
                Task { [weak self] in
                    // Still there a moment later (not a temporary file).
                    try? await Task.sleep(for: .seconds(2))
                    guard FileManager.default.fileExists(atPath: path) else { return }
                    self?.emit?(.fileAdded(folder: folder, path: path))
                }
            }
        }
    }

    private static func names(in folder: String) -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [])
    }
}

// MARK: - Calendar

/// Timed events starting soon, checked every minute (only with full Calendar access;
/// a trigger never asks for it).
@MainActor
final class CalendarSource: TriggerSource {
    private let lookAhead: TimeInterval
    private var loop: Task<Void, Never>?

    init(lookAheadMinutes: Int) { lookAhead = TimeInterval(lookAheadMinutes * 60 + 60) }

    func start(_ emit: @escaping @MainActor (TriggerSignal) -> Void) {
        loop = Task { [lookAhead] in
            while !Task.isCancelled {
                let now = Date()
                for event in await CalendarService.shared.upcomingTimedEvents(from: now, to: now.addingTimeInterval(lookAhead)) {
                    emit(.eventSoon(id: event.id, title: event.title, start: event.start, location: event.location,
                                    attendees: event.attendees))
                }
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }
}

// MARK: - Apps

@MainActor
final class AppLaunchSource: TriggerSource {
    private var observer: NSObjectProtocol?

    func start(_ emit: @escaping @MainActor (TriggerSignal) -> Void) {
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let id = app?.bundleIdentifier, name = app?.localizedName
            MainActor.assumeIsolated {
                if let id { emit(.appLaunched(bundleID: id, name: name ?? id)) }
            }
        }
    }

    func stop() {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observer = nil
    }
}

// MARK: - Wake and unlock

@MainActor
final class MacStateSource: TriggerSource {
    private var wake: NSObjectProtocol?
    private var unlock: NSObjectProtocol?

    func start(_ emit: @escaping @MainActor (TriggerSignal) -> Void) {
        wake = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { emit(.macWoke) } }
        unlock = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { emit(.unlocked) } }
    }

    func stop() {
        if let wake { NSWorkspace.shared.notificationCenter.removeObserver(wake) }
        if let unlock { DistributedNotificationCenter.default().removeObserver(unlock) }
        wake = nil
        unlock = nil
    }
}

// MARK: - Power

/// The power state when it changes (IOKit tells us), and once a minute as the battery drains.
@MainActor
final class PowerSource: TriggerSource {
    private static var current: PowerSource?
    private var emit: (@MainActor (TriggerSignal) -> Void)?
    private var runLoopSource: CFRunLoopSource?
    private var loop: Task<Void, Never>?

    func start(_ emit: @escaping @MainActor (TriggerSignal) -> Void) {
        self.emit = emit
        Self.current = self
        if let source = IOPSNotificationCreateRunLoopSource({ _ in
            Task { @MainActor in PowerSource.current?.report() }
        }, nil)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            runLoopSource = source
        }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                self?.report()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    func stop() {
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .defaultMode) }
        runLoopSource = nil
        loop?.cancel()
        loop = nil
        emit = nil
        if Self.current === self { Self.current = nil }
    }

    private func report() {
        let state = Self.read()
        emit?(.power(onAC: state.onAC, percent: state.percent))
    }

    /// On power or battery, and the battery's level (nil: no battery).
    static func read() -> (onAC: Bool, percent: Int?) {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return (true, nil) }
        for source in list {
            guard let d = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            let current = d[kIOPSCurrentCapacityKey] as? Int ?? 0
            let max = d[kIOPSMaxCapacityKey] as? Int ?? 100
            let onAC = d[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            return (onAC, max > 0 ? Int((Double(current) / Double(max) * 100).rounded()) : nil)
        }
        return (true, nil)
    }
}

// MARK: - Mail

/// New unread mail in Mail's inbox, checked every 5 minutes, only while Mail is
/// open (a trigger never opens Mail). Mail that was already there doesn't count.
@MainActor
final class MailSource: TriggerSource {
    private var loop: Task<Void, Never>?

    /// Unread inbox messages received in the last `seconds`: id, sender, subject (tab-separated lines).
    static let script = """
        on run argv
          set cutoff to (current date) - (item 1 of argv as integer)
          set out to ""
          tell application "Mail"
            repeat with m in (messages of inbox whose read status is false and date received > cutoff)
              set out to out & (message id of m) & tab & (sender of m) & tab & (subject of m) & linefeed
            end repeat
          end tell
          return out
        end run
        """

    func start(_ emit: @escaping @MainActor (TriggerSignal) -> Void) {
        let startedAt = Date()
        loop = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                guard !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.mail").isEmpty else { continue }
                // A little overlap between checks; the trigger's key keeps each message to one run.
                let window = Int(min(Date().timeIntervalSince(startedAt), 420))
                guard let output = try? await AppleScript.run(Self.script, arguments: [String(window)], timeout: 30) else { continue }
                for message in Self.parse(output) {
                    emit(.mail(id: message.id, sender: message.sender, subject: message.subject))
                }
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    nonisolated static func parse(_ output: String) -> [(id: String, sender: String, subject: String)] {
        output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 3, !parts[0].isEmpty else { return nil }
            return (parts[0], parts[1], parts[2])
        }
    }
}

// MARK: - GitHub

/// New review requests and newly failing checks, from the pull requests AgentX
/// already loads for the dashboard (refreshed at least every 10 minutes while needed).
/// What's there when it starts doesn't count.
@MainActor
final class GitHubSource: TriggerSource {
    private weak var store: GitHubStore?
    private var previous: GitHubPullRequests?
    private var loop: Task<Void, Never>?
    private var emit: (@MainActor (TriggerSignal) -> Void)?

    init(store: GitHubStore?) { self.store = store }

    func start(_ emit: @escaping @MainActor (TriggerSignal) -> Void) {
        self.emit = emit
        previous = store?.pullRequests
        store?.pullRequestsChanged = { [weak self] in self?.changed($0) }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                self?.store?.refreshIfStale(maxAge: 600)
                try? await Task.sleep(for: .seconds(300))
            }
        }
    }

    func stop() {
        store?.pullRequestsChanged = nil
        loop?.cancel()
        loop = nil
        emit = nil
    }

    private func changed(_ now: GitHubPullRequests) {
        defer { previous = now }
        guard let before = previous else { return }
        for signal in Self.signals(before: before, now: now) { emit?(signal) }
    }

    /// What's new between two loads (tested).
    nonisolated static func signals(before: GitHubPullRequests, now: GitHubPullRequests) -> [TriggerSignal] {
        let known = Set(before.toReview.map(\.id))
        let wasFailing = Set(before.mine.filter { $0.checks == .failing }.map(\.id))
        return now.toReview.filter { !known.contains($0.id) }.map(TriggerSignal.reviewRequested)
            + now.mine.filter { $0.checks == .failing && !wasFailing.contains($0.id) }.map(TriggerSignal.checksFailed)
    }
}
