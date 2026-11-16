import SwiftUI

/// A line-by-line diff of two strings (used for Claude's Edit tool calls).
struct DiffView: View {
    let old: String
    let new: String
    var maxLines = 400

    private struct Row: Identifiable {
        enum Kind { case same, added, removed }
        let id: Int
        let kind: Kind
        let text: String
    }

    private var rows: [Row] {
        let a = old.components(separatedBy: "\n")
        let b = new.components(separatedBy: "\n")
        let diff = b.difference(from: a)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in diff {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var rows: [Row] = []
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count, removed.contains(i) {
                rows.append(Row(id: rows.count, kind: .removed, text: a[i])); i += 1
            } else if j < b.count, inserted.contains(j) {
                rows.append(Row(id: rows.count, kind: .added, text: b[j])); j += 1
            } else {
                if i < a.count { rows.append(Row(id: rows.count, kind: .same, text: a[i])) }
                i += 1; j += 1
            }
        }
        return Array(rows.prefix(maxLines))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(rows) { row in
                HStack(alignment: .top, spacing: 6) {
                    Text(marker(row.kind))
                        .foregroundStyle(color(row.kind))
                        .frame(width: 10)
                    Text(row.text.isEmpty ? " " : row.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.system(.caption, design: .monospaced))
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(color(row.kind).opacity(row.kind == .same ? 0 : 0.14))
            }
        }
        .textSelection(.enabled)
        .clipShape(.rect(cornerRadius: 6))
    }

    private func marker(_ kind: Row.Kind) -> String {
        switch kind { case .same: " "; case .added: "+"; case .removed: "−" }
    }

    private func color(_ kind: Row.Kind) -> Color {
        switch kind { case .same: .secondary; case .added: .green; case .removed: .red }
    }
}
