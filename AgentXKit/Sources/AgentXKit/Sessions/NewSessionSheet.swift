import AppKit
import SwiftUI

/// Pick a project folder, write a prompt, start a Claude Code session.
struct NewSessionSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var folder: String = ""
    @State private var prompt = ""
    @State private var modelChoice: String = ""
    @State private var mode: PermissionModeOption = .default
    @State private var starting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Session").font(.title2.bold())

            VStack(alignment: .leading, spacing: 6) {
                Text("Project folder").font(.headline)
                HStack {
                    Picker("Project folder", selection: $folder) {
                        if folder.isEmpty { Text("Choose a folder…").tag("") }
                        if !folder.isEmpty && !model.sessions.recentProjects.contains(folder) {
                            Text(folder.abbreviatingHome).tag(folder)
                        }
                        ForEach(model.sessions.recentProjects.prefix(15), id: \.self) { path in
                            Text(path.abbreviatingHome).tag(path)
                        }
                    }
                    .labelsHidden()
                    Button("Choose…", action: chooseFolder).secondaryButton()
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("What should Claude do?").font(.headline)
                TextEditor(text: $prompt)
                    .font(.body)
                    .frame(minHeight: 120)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: Radius.field))
            }

            HStack(spacing: 16) {
                Picker("Model", selection: $modelChoice) {
                    Text("Default").tag("")
                    ForEach(model.models) { Text($0.displayName).tag($0.value) }
                }
                Picker("Permissions", selection: $mode) {
                    ForEach(PermissionModeOption.allCases) { Text($0.label).tag($0) }
                }
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.secondaryButton()
                    .keyboardShortcut(.cancelAction)
                Button("Start", action: start)
                    .primaryButton()
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(folder.isEmpty || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || starting)
            }
        }
        .padding(24)
        .frame(width: 560)
        .onAppear {
            if let preset = model.pendingNewSessionFolder {
                folder = preset
                model.pendingNewSessionFolder = nil
            }
            if folder.isEmpty { folder = model.sessions.recentProjects.first ?? "" }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use Folder"
        if panel.runModal() == .OK, let url = panel.url { folder = url.path }
    }

    private func start() {
        starting = true
        let (folder, prompt, choice, mode) = (folder, prompt, modelChoice, mode)
        model.sidebar = .sessions
        dismiss()
        Task { await model.sessions.startNew(cwd: folder, prompt: prompt, model: choice.isEmpty ? nil : choice, mode: mode) }
    }
}
