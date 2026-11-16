import AppKit
import Observation
import SwiftTerm
import SwiftUI

/// One terminal running one program (usually the real `claude` CLI). It lives
/// in `TerminalStore`, not in a view, so it keeps running when you switch tabs
/// or sessions: important for phone sync, which needs the process alive.
@MainActor
@Observable
public final class TerminalSession: Identifiable {
    public let id: String
    public let remoteControl: Bool
    /// nil while running; set (possibly to nil inside) when the program exits.
    public private(set) var exitCode: Int32??
    public var isRunning: Bool { exitCode == nil }

    @ObservationIgnored let view: LocalProcessTerminalView
    @ObservationIgnored private var delegate: Delegate?

    init(id: String, executable: String, arguments: [String], directory: String, environment: [String: String], remoteControl: Bool) {
        self.id = id
        self.remoteControl = remoteControl
        view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        view.font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
        view.nativeBackgroundColor = NSColor.textBackgroundColor
        view.nativeForegroundColor = NSColor.textColor
        let delegate = Delegate { [weak self] code in self?.exitCode = .some(code) }
        self.delegate = delegate
        view.processDelegate = delegate
        view.startProcess(
            executable: executable,
            args: arguments,
            environment: environment.map { "\($0.key)=\($0.value)" },
            execName: nil,
            currentDirectory: directory
        )
    }

    func terminate() {
        if isRunning { view.terminate() }
    }

    private final class Delegate: NSObject, LocalProcessTerminalViewDelegate {
        let onExit: @MainActor (Int32?) -> Void
        init(onExit: @escaping @MainActor (Int32?) -> Void) { self.onExit = onExit }

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}
        func processTerminated(source: SwiftTerm.TerminalView, exitCode: Int32?) {
            let onExit = self.onExit
            Task { @MainActor in onExit(exitCode) }
        }
    }
}

/// All terminals AgentX is running, keyed by conversation id (or "login").
@MainActor
@Observable
public final class TerminalStore {
    public private(set) var sessions: [String: TerminalSession] = [:]

    public init() {}

    public func session(for id: String) -> TerminalSession? { sessions[id] }

    /// Running terminals that have phone sync (Remote Control) on.
    public var remoteControlled: [TerminalSession] {
        sessions.values.filter { $0.remoteControl && $0.isRunning }.sorted { $0.id < $1.id }
    }

    @discardableResult
    public func start(id: String, executable: String, arguments: [String], directory: String,
                      environment: [String: String], remoteControl: Bool = false) -> TerminalSession {
        sessions[id]?.terminate()
        let session = TerminalSession(id: id, executable: executable, arguments: arguments, directory: directory,
                                      environment: environment, remoteControl: remoteControl)
        sessions[id] = session
        return session
    }

    public func stop(_ id: String) {
        sessions[id]?.terminate()
        sessions[id] = nil
    }

    public func stopAll() {
        sessions.values.forEach { $0.terminate() }
        sessions.removeAll()
    }
}

/// Shows a `TerminalSession`'s terminal. Removing this view doesn't stop the program.
struct TerminalView: NSViewRepresentable {
    let session: TerminalSession

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let view = session.view
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }

    func updateNSView(_ view: LocalProcessTerminalView, context: Context) {}
}
