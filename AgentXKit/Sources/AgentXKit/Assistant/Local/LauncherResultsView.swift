import AppKit
import SwiftUI

/// The rows under the launcher's field: ↑/↓ to pick, Return to do it, click works too.
struct LauncherResultsList: View {
    @State private var launcher = LauncherController.shared
    @State private var lastPointer: CGPoint?
    /// The highlight glides from row to row instead of jumping.
    @Namespace private var highlight

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(Array(launcher.results.enumerated()), id: \.element.id) { index, result in
                        row(result, index: index, selected: index == launcher.selectedResult)
                            .id(result.id)
                            .transition(.opacity.combined(with: .offset(y: -4)))
                            .contentShape(.rect)
                            .onTapGesture {
                                launcher.selectedResult = index
                                launcher.perform(result)
                            }
                            // Follow the mouse only when it moves (not when the launcher opens under it).
                            .onContinuousHover { phase in
                                // The mouse's place on screen, not in the row: rows sliding in under a
                                // resting pointer isn't the mouse moving.
                                guard case .active = phase else { return }
                                let mouse = NSEvent.mouseLocation
                                if let last = lastPointer, last != mouse, launcher.selectedResult != index {
                                    launcher.selectedResult = index
                                }
                                lastPointer = mouse
                            }
                    }
                }
            }
            .frame(maxHeight: launcher.compact ? 300 : 380)
            .fixedSize(horizontal: false, vertical: true)
            .animation(Motion.quick, value: launcher.selectedResult)
            .animation(Motion.quick, value: launcher.results.map(\.id))
            .onChange(of: launcher.selectedResult) { _, i in
                if launcher.results.indices.contains(i) { proxy.scrollTo(launcher.results[i].id) }
            }
        }
    }

    private func row(_ result: LauncherResult, index: Int, selected: Bool) -> some View {
        HStack(spacing: 14) {
            icon(result.icon)
            VStack(alignment: .leading, spacing: 1) {
                Text(result.title).font(.system(size: 16)).lineLimit(1).truncationMode(.middle)
                if let subtitle = result.subtitle {
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                }
            }
            Spacer(minLength: 8)
            if selected {
                Text("\(result.verb) ↩")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.primary.opacity(0.08), in: .capsule)
            } else if index < 9 {
                Text("⌘\(index + 1)").font(.system(size: 14)).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: 14)
                    .fill(.primary.opacity(0.1))
                    .matchedGeometryEffect(id: "selection", in: highlight)
            }
        }
    }

    @ViewBuilder private func icon(_ icon: LauncherResult.Icon) -> some View {
        switch icon {
        case .image(let image):
            Image(nsImage: image).resizable().frame(width: 32, height: 32)
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: 20))
                .foregroundStyle(.primary)
                .frame(width: 32, height: 32)
        }
    }
}

/// A command on this Mac: being worked out, waiting for your OK, done, or not possible.
struct LocalCommandCard: View {
    let state: LocalState
    @State private var launcher = LauncherController.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch state {
            case .thinking:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Working on it…").foregroundStyle(.secondary)
                }
            case .confirm(let plan):
                header(plan.headline, icon: icon(for: plan.action))
                ForEach(plan.details, id: \.self) { Text($0).font(.callout) }
                HStack {
                    Button("Cancel") { launcher.escape() }.secondaryButton()
                    Spacer()
                    Button(confirmVerb(plan.action)) { Task { await launcher.execute(plan) } }
                        .primaryButton()
                }
            case .working(let plan):
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(plan.headline).foregroundStyle(.secondary)
                }
            case .done(let text):
                Label(text, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.primary)
                    .symbolRenderingMode(.multicolor)
                    .textSelection(.enabled)
            case .info(let title, let text):
                header(title, icon: "calendar")
                ScrollView {
                    Text(text).font(.callout).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }
                .frame(maxHeight: 260)
                .fixedSize(horizontal: false, vertical: true)
            case .failed(let message, let text):
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Ask Claude ↩") { launcher.submit(text) }.secondaryButton()
                }
            case .text(let written):
                WrittenCard(written: written)
            case .blockedFolder(let name):
                Label("macOS doesn't let AgentX see your \(name) folder, so files there can't be found.", systemImage: "lock.fill")
                    .foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Open Settings ↩") { FolderAccess.openSettings() }.primaryButton()
                }
            case .notACommand:
                HStack {
                    Spacer()
                    Button("Ask ↩") { launcher.askClaude() }.primaryButton()
                }
            }
        }
        .controlSize(.small)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func header(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon).font(.headline)
    }

    private func confirmVerb(_ action: LocalPlan.Action) -> String {
        switch action {
        case .createEvent, .createReminder: "Add ↩"
        case .createNote: "Create ↩"
        case .quitApp: "Quit ↩"
        case .runShortcut: "Run ↩"
        default: "Do ↩"
        }
    }

    private func icon(for action: LocalPlan.Action) -> String {
        switch action {
        case .createEvent, .showCalendar: "calendar.badge.plus"
        case .createReminder, .showReminders: "checklist"
        case .createNote: "note.text"
        case .quitApp: "xmark.app"
        case .runShortcut: "square.stack.3d.up"
        default: "wand.and.stars"
        }
    }
}


/// Text written on this Mac: read it, copy it, paste it over your selection, hear it, or ask Claude instead.
private struct WrittenCard: View {
    let written: LocalText
    @State private var launcher = LauncherController.shared
    @State private var copied = false

    private var canReplace: Bool { written.replaces && launcher.contextApp != nil && launcher.context?.selectedText != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(written.title, systemImage: written.isTranslation ? "character.bubble" : "text.quote").font(.headline)
                Spacer()
                if written.isTranslation {
                    Menu(written.language.map { "Into \(LocalWriter.name(of: $0))" } ?? "Choose a language") {
                        ForEach(LocalWriter.languages, id: \.code) { language in
                            Button(language.name) { launcher.translate(written.source, to: language.code) }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }
            if written.text.isEmpty {
                Text("It's already in your language. Choose one to translate it into.").foregroundStyle(.secondary)
            } else {
                ScrollView {
                    Text(written.text).font(.system(size: 14)).lineSpacing(2)
                        .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }
                .frame(maxHeight: 300)
                .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    if canReplace {
                        Button("Replace Selection ↩") { launcher.replaceSelection(with: written.text) }.primaryButton()
                    }
                    Button(copied ? "Copied" : canReplace ? "Copy" : "Copy ↩") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(written.text, forType: .string)
                        copied = true
                    }
                    .secondaryButton()
                    Button("Read Aloud", systemImage: "speaker.wave.2") { SpeechOutput.shared.speak(written.text) }
                        .labelStyle(.iconOnly)
                        .secondaryButton()
                    Spacer()
                    Button("Ask Claude") { launcher.submit(written.claudePrompt) }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("Send this to Claude instead (uses your Claude plan)")
                }
            }
        }
    }
}
