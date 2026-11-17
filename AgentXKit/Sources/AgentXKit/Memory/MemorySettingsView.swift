import AppKit
import SwiftUI

/// Settings → Memory: everything AgentX remembers, editable.
struct MemorySettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var selection: String?
    @State private var adding = false

    private var memory: MemoryStore { model.memory }

    var body: some View {
        @Bindable var memory = memory
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Toggle("Use memory", isOn: Binding(get: { !memory.isPaused }, set: { memory.isPaused = !$0 }))
                    .toggleStyle(.switch)
                    .help("Off: Claude neither sees nor saves memories (your files stay as they are).")
                Spacer()
                Button("Open Folder") { NSWorkspace.shared.activateFileViewerSelecting([memory.folder.appendingPathComponent("MEMORY.md")]) }
                    .secondaryButton()
                Button("Add…", systemImage: "plus") { adding = true }
                    .secondaryButton()
            }
            Text("Things you tell the assistant to remember (or it notices are lasting) become notes here, one Markdown file each. Mac conversations, automations and messages from your iPhone use them. Claude won't save passwords, keys or card numbers, and asks first in a conversation that has read web pages or email.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HSplitView {
                VStack(spacing: 6) {
                    TextField("Search", text: $query).textFieldStyle(.roundedBorder)
                    List(selection: $selection) {
                        let found = memory.search(query)
                        if found.isEmpty {
                            Text(memory.items.isEmpty ? "Nothing yet. Tell the assistant \"remember that…\"." : "No matches.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(found) { item in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title).lineLimit(1)
                                    Text(item.kind.label).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if !item.reviewed {
                                    Text("New").font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(.tint.opacity(0.2), in: .capsule)
                                        .help("Claude saved this. Check it's right.")
                                }
                            }
                            .tag(item.id)
                        }
                    }
                    .listStyle(.inset)
                }
                .frame(minWidth: 220, idealWidth: 250)

                Group {
                    if let id = selection, let item = memory.items.first(where: { $0.id == id }) {
                        MemoryEditor(item: item).id(item.id)
                    } else {
                        ContentUnavailableView("Select a memory", systemImage: "brain",
                                               description: Text(memory.unreviewedCount > 0 ? "\(memory.unreviewedCount) new from Claude to check." : ""))
                    }
                }
                .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding()
        .onChange(of: selection) { _, id in if let id { memory.markReviewed(id) } }
        .sheet(isPresented: $adding) { NewMemorySheet { selection = $0 } }
    }
}

private struct MemoryEditor: View {
    @Environment(AppModel.self) private var model
    let item: MemoryItem
    @State private var title = ""
    @State private var kind = MemoryItem.Kind.other
    @State private var text = ""
    @State private var error: String?
    @State private var confirmDelete = false

    var body: some View {
        Form {
            TextField("Title", text: $title)
            Picker("Kind", selection: $kind) {
                ForEach(MemoryItem.Kind.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            Section("Text") {
                TextEditor(text: $text).font(.body).frame(minHeight: 120)
            }
            Section {
                if let source = item.source { LabeledContent("From", value: source) }
                LabeledContent("Updated", value: item.updated.formatted(.dateTime.day().month(.abbreviated).year().hour().minute()))
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
                HStack {
                    Button("Delete…", role: .destructive) { confirmDelete = true }.secondaryButton()
                    Spacer()
                    Button("Save") { save() }
                        .primaryButton()
                        .disabled(title == item.title && kind == item.kind && text == item.body)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            title = item.title
            kind = item.kind
            text = item.body
        }
        .confirmationDialog("Delete “\(item.title)”?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                do { try model.memory.forget(item.id) } catch { self.error = error.localizedDescription }
            }
        } message: {
            Text("Claude stops using it. The file moves to Memory/.trash, so you can put it back.")
        }
    }

    private func save() {
        var updated = item
        updated.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.kind = kind
        updated.body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !updated.title.isEmpty, !updated.body.isEmpty else { error = "A memory needs a title and some text."; return }
        do {
            try model.memory.update(updated)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct NewMemorySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let added: (String) -> Void
    @State private var title = ""
    @State private var kind = MemoryItem.Kind.preference
    @State private var text = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New memory").font(.title3.bold())
            TextField("Title (e.g. Prefers short replies)", text: $title).textFieldStyle(.roundedBorder)
            Picker("Kind", selection: $kind) {
                ForEach(MemoryItem.Kind.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            TextEditor(text: $text)
                .frame(height: 110)
                .overlay(RoundedRectangle(cornerRadius: Radius.inset).stroke(.quaternary))
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.secondaryButton().keyboardShortcut(.cancelAction)
                Button("Save") {
                    do {
                        try model.memory.save(title: title, body: text, kind: kind, source: "You, in Settings", reviewed: true)
                        if let item = model.memory.item(titled: title) { added(item.id) }
                        dismiss()
                    } catch {
                        self.error = error.localizedDescription
                    }
                }
                .primaryButton()
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}
