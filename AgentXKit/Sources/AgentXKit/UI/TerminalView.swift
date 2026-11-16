import AppKit
import SwiftTerm
import SwiftUI

/// A real terminal (SwiftTerm) running one program, e.g. `claude --resume <id>`.
struct TerminalView: NSViewRepresentable {
    let executable: String
    let arguments: [String]
    let directory: String
    let environment: [String: String]
    var onExit: (@MainActor (Int32?) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(onExit: onExit) }

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        view.processDelegate = context.coordinator
        view.font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
        view.nativeBackgroundColor = NSColor.textBackgroundColor
        view.nativeForegroundColor = NSColor.textColor
        view.startProcess(
            executable: executable,
            args: arguments,
            environment: environment.map { "\($0.key)=\($0.value)" },
            execName: nil,
            currentDirectory: directory
        )
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }

    func updateNSView(_ view: LocalProcessTerminalView, context: Context) {}

    static func dismantleNSView(_ view: LocalProcessTerminalView, coordinator: Coordinator) {
        view.terminate()
    }

    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        let onExit: (@MainActor (Int32?) -> Void)?
        init(onExit: (@MainActor (Int32?) -> Void)?) { self.onExit = onExit }

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}
        func processTerminated(source: SwiftTerm.TerminalView, exitCode: Int32?) {
            let onExit = self.onExit
            Task { @MainActor in onExit?(exitCode) }
        }
    }
}
